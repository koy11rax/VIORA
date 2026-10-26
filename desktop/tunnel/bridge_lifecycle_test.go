package main

import (
	"context"
	"errors"
	"reflect"
	"sync"
	"testing"
	"time"
)

// The supervisor tests use only channels and callbacks. They never create a
// process, listener, adapter, service or route on the test machine.
type lifecycleBridgeLog struct {
	mu     sync.Mutex
	events []string
}

func (l *lifecycleBridgeLog) add(event string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.events = append(l.events, event)
}

func (l *lifecycleBridgeLog) snapshot() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]string{}, l.events...)
}

type lifecycleBridgeProcess struct {
	stage     string
	log       *lifecycleBridgeLog
	done      chan struct{}
	exitOnce  sync.Once
	stopOnce  sync.Once
	readyFunc func(context.Context) error
}

func lifecycleProcess(stage string, log *lifecycleBridgeLog) *lifecycleBridgeProcess {
	return &lifecycleBridgeProcess{stage: stage, log: log, done: make(chan struct{})}
}

func (p *lifecycleBridgeProcess) Ready(ctx context.Context) error {
	p.log.add("ready:" + p.stage)
	if p.readyFunc != nil {
		return p.readyFunc(ctx)
	}
	return nil
}

func (p *lifecycleBridgeProcess) Done() <-chan struct{} { return p.done }
func (p *lifecycleBridgeProcess) exit()                 { p.exitOnce.Do(func() { close(p.done) }) }
func (p *lifecycleBridgeProcess) Stop() {
	p.stopOnce.Do(func() {
		p.log.add("stop:" + p.stage)
		p.exit()
	})
}

func awaitBridgeResult(t *testing.T, result <-chan string) string {
	t.Helper()
	select {
	case code := <-result:
		return code
	case <-time.After(2 * time.Second):
		t.Fatal("isolated supervisor did not finish")
		return ""
	}
}

func awaitBridgeSignal(t *testing.T, signal <-chan struct{}) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(2 * time.Second):
		t.Fatal("isolated supervisor did not reach the expected stage")
	}
}

func TestBridgeLifecycleFailureCleanup(t *testing.T) {
	tests := []struct {
		name, failingStage, operation, code string
		want                                []string
	}{
		{"backend start", "backend", "start", "backend_start_failed", []string{"start:backend"}},
		{"backend ready", "backend", "ready", "backend_not_ready", []string{"start:backend", "ready:backend", "stop:backend"}},
		{"frontend start", "frontend", "start", "frontend_start_failed", []string{"start:backend", "ready:backend", "start:frontend", "stop:backend"}},
		{"frontend ready", "frontend", "ready", "frontend_not_ready", []string{"start:backend", "ready:backend", "start:frontend", "ready:frontend", "stop:frontend", "stop:backend"}},
		{"protection callback", "", "callback", "protection_failed", []string{"start:backend", "ready:backend", "start:frontend", "ready:frontend", "callback", "stop:frontend", "stop:backend"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			log := &lifecycleBridgeLog{}
			start := func(_ context.Context, stage string) (bridgeProcess, error) {
				log.add("start:" + stage)
				if stage == tt.failingStage && tt.operation == "start" {
					return nil, errors.New("private child/config detail must not escape")
				}
				p := lifecycleProcess(stage, log)
				if stage == tt.failingStage && tt.operation == "ready" {
					p.readyFunc = func(context.Context) error { return errors.New("private readiness detail") }
				}
				return p, nil
			}
			code := superviseBridge(context.Background(), start, func() string {
				log.add("callback")
				if tt.operation != "callback" {
					t.Error("connected/protection callback ran after a failed stage")
				}
				return "protection_failed"
			})
			if code != tt.code || !reflect.DeepEqual(log.snapshot(), tt.want) {
				t.Fatalf("code=%q events=%v; want code=%q events=%v", code, log.snapshot(), tt.code, tt.want)
			}
		})
	}
}

func TestBridgeLifecycleCancelledBeforeStart(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	code := superviseBridge(ctx, func(context.Context, string) (bridgeProcess, error) {
		t.Fatal("cancelled connection started a child")
		return nil, nil
	}, func() string { t.Fatal("cancelled connection became ready"); return "" })
	if code != "" {
		t.Fatalf("cancel must be a disconnected outcome, got %q", code)
	}
}

func TestBridgeLifecycleDoesNotConnectBeforeFrontendReady(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	log := &lifecycleBridgeLog{}
	frontendWaiting, allowFrontend := make(chan struct{}), make(chan struct{})
	connected := make(chan struct{})
	start := func(_ context.Context, stage string) (bridgeProcess, error) {
		log.add("start:" + stage)
		p := lifecycleProcess(stage, log)
		if stage == "frontend" {
			p.readyFunc = func(ctx context.Context) error {
				close(frontendWaiting)
				select {
				case <-allowFrontend:
					return nil
				case <-ctx.Done():
					return ctx.Err()
				}
			}
		}
		return p, nil
	}
	result := make(chan string, 1)
	go func() { result <- superviseBridge(ctx, start, func() string { close(connected); return "" }) }()
	awaitBridgeSignal(t, frontendWaiting)
	select {
	case <-connected:
		t.Fatal("frontend not ready, but connection was announced")
	default:
	}
	close(allowFrontend)
	awaitBridgeSignal(t, connected)
	cancel()
	if code := awaitBridgeResult(t, result); code != "" {
		t.Fatalf("cancel returned %q", code)
	}
	want := []string{"start:backend", "ready:backend", "start:frontend", "ready:frontend", "stop:frontend", "stop:backend"}
	if !reflect.DeepEqual(log.snapshot(), want) {
		t.Fatalf("events=%v; want %v", log.snapshot(), want)
	}
}

func TestBridgeLifecycleActiveChildExitStopsPeer(t *testing.T) {
	for _, exiting := range []string{"backend", "frontend"} {
		t.Run(exiting, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			log := &lifecycleBridgeLog{}
			processes := map[string]*lifecycleBridgeProcess{}
			connected := make(chan struct{})
			result := make(chan string, 1)
			go func() {
				result <- superviseBridge(ctx, func(_ context.Context, stage string) (bridgeProcess, error) {
					p := lifecycleProcess(stage, log)
					processes[stage] = p
					return p, nil
				}, func() string { close(connected); return "" })
			}()
			awaitBridgeSignal(t, connected)
			processes[exiting].exit()
			if code := awaitBridgeResult(t, result); code != exiting+"_exited" {
				t.Fatalf("child exit returned %q", code)
			}
			want := []string{"ready:backend", "ready:frontend", "stop:frontend", "stop:backend"}
			if !reflect.DeepEqual(log.snapshot(), want) {
				t.Fatalf("events=%v; want reverse cleanup %v", log.snapshot(), want)
			}
		})
	}
}

func TestBridgeLifecycleCancellationDuringStages(t *testing.T) {
	for _, stage := range []string{"backend", "frontend"} {
		for _, operation := range []string{"start", "ready"} {
			t.Run(stage+" "+operation, func(t *testing.T) {
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				log := &lifecycleBridgeLog{}
				blocked := make(chan struct{})
				result := make(chan string, 1)
				go func() {
					result <- superviseBridge(ctx, func(childCtx context.Context, current string) (bridgeProcess, error) {
						log.add("start:" + current)
						if current == stage && operation == "start" {
							close(blocked)
							<-childCtx.Done()
							return nil, childCtx.Err()
						}
						p := lifecycleProcess(current, log)
						if current == stage && operation == "ready" {
							p.readyFunc = func(readyCtx context.Context) error {
								close(blocked)
								<-readyCtx.Done()
								return readyCtx.Err()
							}
						}
						return p, nil
					}, func() string { t.Error("cancelled startup became connected"); return "" })
				}()
				awaitBridgeSignal(t, blocked)
				cancel()
				if code := awaitBridgeResult(t, result); code != "" {
					t.Fatalf("cancel during %s %s returned failure %q", stage, operation, code)
				}
				events := log.snapshot()
				if stage == "frontend" && operation == "ready" {
					if !reflect.DeepEqual(events[len(events)-2:], []string{"stop:frontend", "stop:backend"}) {
						t.Fatalf("missing reverse cleanup: %v", events)
					}
				} else if !(stage == "backend" && operation == "start") && events[len(events)-1] != "stop:backend" {
					t.Fatalf("backend was not stopped: %v", events)
				}
			})
		}
	}
}

func TestBridgeLifecycleStartupDeadlineDoesNotLimitChildLifetime(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	log := &lifecycleBridgeLog{}
	var deadlines []time.Time
	var children []context.Context
	code := superviseBridge(ctx, func(childCtx context.Context, stage string) (bridgeProcess, error) {
		if _, hasDeadline := childCtx.Deadline(); hasDeadline {
			t.Error("child lifetime incorrectly limited by startup deadline")
		}
		children = append(children, childCtx)
		p := lifecycleProcess(stage, log)
		p.readyFunc = func(readyCtx context.Context) error {
			deadline, ok := readyCtx.Deadline()
			if !ok || time.Until(deadline) <= 0 || time.Until(deadline) > 21*time.Second {
				t.Error("readiness did not get a bounded startup context")
			}
			deadlines = append(deadlines, deadline)
			return nil
		}
		return p, nil
	}, func() string {
		for _, childCtx := range children {
			if childCtx.Err() != nil {
				t.Error("live child was cancelled when readiness finished")
			}
		}
		return "protection_failed"
	})
	if code != "protection_failed" || len(deadlines) != 2 || !deadlines[0].Equal(deadlines[1]) {
		t.Fatalf("code=%q, readiness deadlines=%v; must share one startup budget", code, deadlines)
	}
}

func TestBridgeLifecycleExitedBeforeConnectionIsNeverReady(t *testing.T) {
	for _, exiting := range []string{"backend", "frontend"} {
		t.Run(exiting, func(t *testing.T) {
			log := &lifecycleBridgeLog{}
			connected := false
			code := superviseBridge(context.Background(), func(_ context.Context, stage string) (bridgeProcess, error) {
				log.add("start:" + stage)
				p := lifecycleProcess(stage, log)
				if stage == exiting {
					p.readyFunc = func(context.Context) error { p.exit(); return nil }
				}
				return p, nil
			}, func() string { connected = true; return "protection_failed" })
			if code != exiting+"_exited" || connected {
				t.Fatalf("dead child was announced ready: code=%q callback=%v events=%v", code, connected, log.snapshot())
			}
		})
	}
}

func TestBridgeLifecycleSlowReadinessTimesOutAndCleansUp(t *testing.T) {
	for _, slow := range []string{"backend", "frontend"} {
		t.Run(slow, func(t *testing.T) {
			log := &lifecycleBridgeLog{}
			code := superviseBridgeWithTimeout(context.Background(), func(_ context.Context, stage string) (bridgeProcess, error) {
				p := lifecycleProcess(stage, log)
				if stage == slow {
					p.readyFunc = func(ctx context.Context) error { <-ctx.Done(); return ctx.Err() }
				}
				return p, nil
			}, func() string { t.Error("timed-out startup became connected"); return "" }, 5*time.Millisecond)
			if code != slow+"_not_ready" {
				t.Fatalf("slow readiness returned %q", code)
			}
			events := log.snapshot()
			if events[len(events)-1] != "stop:backend" || (slow == "frontend" && events[len(events)-2] != "stop:frontend") {
				t.Fatalf("timeout did not reap children in reverse order: %v", events)
			}
		})
	}
}

func TestBridgeLifecycleWorkingChildrenOutliveStartupDeadline(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	log := &lifecycleBridgeLog{}
	var readiness context.Context
	var lifetime context.Context
	connected := make(chan struct{})
	result := make(chan string, 1)
	go func() {
		result <- superviseBridgeWithTimeout(ctx, func(childCtx context.Context, stage string) (bridgeProcess, error) {
			lifetime = childCtx
			p := lifecycleProcess(stage, log)
			p.readyFunc = func(readyCtx context.Context) error { readiness = readyCtx; return nil }
			return p, nil
		}, func() string { close(connected); return "" }, 10*time.Millisecond)
	}()
	awaitBridgeSignal(t, connected)
	awaitBridgeSignal(t, readiness.Done())
	if lifetime.Err() != nil {
		t.Fatal("startup budget expiry cancelled a working child")
	}
	select {
	case code := <-result:
		t.Fatalf("working session ended with startup timer: %q", code)
	default:
	}
	cancel()
	if code := awaitBridgeResult(t, result); code != "" {
		t.Fatalf("cancel returned %q", code)
	}
}

func TestBridgeLifecyclePartiallyStartedChildIsNotLeaked(t *testing.T) {
	log := &lifecycleBridgeLog{}
	code := superviseBridge(context.Background(), func(_ context.Context, stage string) (bridgeProcess, error) {
		p := lifecycleProcess(stage, log)
		if stage == "frontend" {
			return p, errors.New("post-start containment failure")
		}
		return p, nil
	}, nil)
	if code != "frontend_start_failed" || !reflect.DeepEqual(log.snapshot(), []string{"ready:backend", "stop:frontend", "stop:backend"}) {
		t.Fatalf("partially started child leaked: code=%q events=%v", code, log.snapshot())
	}
}

func TestBridgeLifecycleCancellationWinsConcurrentExit(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	log := &lifecycleBridgeLog{}
	var backend *lifecycleBridgeProcess
	code := superviseBridge(ctx, func(_ context.Context, stage string) (bridgeProcess, error) {
		p := lifecycleProcess(stage, log)
		if stage == "backend" {
			backend = p
		}
		return p, nil
	}, func() string { cancel(); backend.exit(); return "" })
	if code != "" {
		t.Fatalf("explicit cancellation was replaced by stale child failure %q", code)
	}
}

func TestBridgeLifecycleIndependentSessionsDoNotShareCleanup(t *testing.T) {
	type session struct {
		cancel    context.CancelFunc
		connected chan struct{}
		result    chan string
		log       *lifecycleBridgeLog
	}
	sessions := make([]session, 2)
	for index := range sessions {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		sessions[index] = session{cancel, make(chan struct{}), make(chan string, 1), &lifecycleBridgeLog{}}
		s := &sessions[index]
		go func() {
			s.result <- superviseBridge(ctx, func(_ context.Context, stage string) (bridgeProcess, error) {
				return lifecycleProcess(stage, s.log), nil
			}, func() string { close(s.connected); return "" })
		}()
	}
	for _, s := range sessions {
		awaitBridgeSignal(t, s.connected)
	}
	sessions[0].cancel()
	if code := awaitBridgeResult(t, sessions[0].result); code != "" {
		t.Fatalf("first session cancellation returned %q", code)
	}
	select {
	case code := <-sessions[1].result:
		t.Fatalf("first session stopped an unrelated session: %q", code)
	default:
	}
	if !reflect.DeepEqual(sessions[1].log.snapshot(), []string{"ready:backend", "ready:frontend"}) {
		t.Fatal("first session cleaned up another session's children")
	}
	sessions[1].cancel()
	if code := awaitBridgeResult(t, sessions[1].result); code != "" {
		t.Fatalf("second session cancellation returned %q", code)
	}
}
