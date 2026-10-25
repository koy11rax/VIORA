package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestProtectionBlocksEveryDirectOutbound(t *testing.T) {
	f := fixture()
	raw, _ := json.Marshal(f)
	config, err := sanitizeConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	restrictDirect(config)
	for _, item := range config["outbounds"].([]any) {
		row := item.(map[string]any)
		if row["protocol"] == "freedom" {
			t.Fatal("cleartext outbound survived")
		}
		if row["tag"] == "direct" && row["protocol"] != "blackhole" {
			t.Fatal("direct exception bypassed protection")
		}
	}
	proxy := proxyMap(config)
	if proxy["protocol"] != "vless" {
		t.Fatal("VPN outbound changed")
	}
	server := proxy["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)
	if server["address"] != "example.invalid" {
		t.Fatal("policy rewrite changed endpoint")
	}
}

func endpointFixture(t *testing.T) map[string]any {
	t.Helper()
	data, _ := json.Marshal(fixture())
	config, err := sanitizeConfig(data)
	if err != nil {
		t.Fatal(err)
	}
	proxyMap(config) // Normalize the validated struct before testing mutation.
	return config
}

func endpointAddress(config map[string]any) any {
	return proxyMap(config)["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)["address"]
}

func endpointSuccess(t *testing.T, body string) endpointDependencies {
	t.Helper()
	return endpointDependencies{
		doHTTP: func(request *http.Request) (*http.Response, error) {
			if request.URL.Scheme != "https" || request.URL.Host != "1.1.1.1" || request.URL.Path != "/dns-query" ||
				request.URL.Query().Get("type") != "A" || request.URL.Query().Get("name") != "example.invalid" ||
				request.Header.Get("Accept") != "application/dns-json" {
				t.Fatal("bootstrap destination or query changed")
			}
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
		},
		lookup: func(context.Context, string, string) ([]net.IP, error) {
			t.Fatal("unexpected system DNS fallback")
			return nil, errors.New("unexpected")
		},
	}
}

func TestEndpointPreservesTransportIdentity(t *testing.T) {
	for _, test := range []struct{ name, network, sni, headerKey, explicit, expected string }{
		{"ws default uses SNI", "ws", "front.example.invalid", "", "", "front.example.invalid"},
		{"ws explicit", "ws", "front.example.invalid", "Host", "explicit.example.invalid", "explicit.example.invalid"},
		{"ws lowercase explicit", "ws", "front.example.invalid", "host", "explicit.example.invalid", "explicit.example.invalid"},
		{"ws empty header", "ws", "front.example.invalid", "HOST", "", "front.example.invalid"},
		{"ws no SNI", "ws", "", "", "", "example.invalid"},
		{"xhttp default uses SNI", "xhttp", "front.example.invalid", "", "", "front.example.invalid"},
		{"xhttp explicit", "xhttp", "front.example.invalid", "", "explicit.example.invalid", "explicit.example.invalid"},
		{"xhttp no SNI", "xhttp", "", "", "", "example.invalid"},
	} {
		t.Run(test.name, func(t *testing.T) {
			config := endpointFixture(t)
			proxy := proxyMap(config)
			stream := proxy["streamSettings"].(map[string]any)
			tls := stream["tlsSettings"].(map[string]any)
			tls["serverName"] = test.sni
			tlsBefore, _ := json.Marshal(tls)
			stream["network"] = test.network
			if test.network == "ws" {
				if test.headerKey != "" {
					stream["wsSettings"].(map[string]any)["headers"] = map[string]any{test.headerKey: test.explicit}
				}
			} else {
				delete(stream, "wsSettings")
				stream["xhttpSettings"] = map[string]any{"path": "/vpn", "mode": "auto", "host": test.explicit}
			}
			settings := proxy["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)
			usersBefore, _ := json.Marshal(settings["users"])
			if err := resolveEndpointWith(context.Background(), config, false, endpointSuccess(t, `{"Status":0,"Answer":[{"type":5,"data":"alias.example.invalid"},{"type":1,"data":"203.0.113.10"}]}`)); err != nil {
				t.Fatal(err)
			}
			if endpointAddress(config) != "203.0.113.10" {
				t.Fatal("endpoint was not pinned to IPv4")
			}
			tlsAfter, _ := json.Marshal(tls)
			usersAfter, _ := json.Marshal(settings["users"])
			if string(tlsBefore) != string(tlsAfter) || string(usersBefore) != string(usersAfter) || settings["port"] != float64(443) {
				t.Fatal("TLS identity or VLESS credentials changed")
			}
			var host string
			if test.network == "ws" {
				headers := stream["wsSettings"].(map[string]any)["headers"].(map[string]any)
				for name, value := range headers {
					if strings.EqualFold(name, "Host") {
						host, _ = value.(string)
					}
				}
				if len(headers) != 1 || stream["wsSettings"].(map[string]any)["path"] != "/vpn" {
					t.Fatal("WS metadata changed")
				}
			} else {
				host, _ = stream["xhttpSettings"].(map[string]any)["host"].(string)
			}
			if host != test.expected {
				t.Fatalf("Host = %q, want %q", host, test.expected)
			}
		})
	}
	t.Run("REALITY unchanged", func(t *testing.T) {
		config := endpointFixture(t)
		stream := proxyMap(config)["streamSettings"].(map[string]any)
		delete(stream, "tlsSettings")
		delete(stream, "wsSettings")
		stream["network"], stream["security"] = "raw", "reality"
		reality := map[string]any{"serverName": "front.example.invalid", "fingerprint": "chrome", "password": strings.Repeat("A", 43), "shortId": "abcd"}
		stream["realitySettings"] = reality
		before, _ := json.Marshal(reality)
		if err := resolveEndpointWith(context.Background(), config, false, endpointSuccess(t, `{"Status":0,"Answer":[{"type":1,"data":"203.0.113.10"}]}`)); err != nil {
			t.Fatal(err)
		}
		after, _ := json.Marshal(reality)
		if string(before) != string(after) || endpointAddress(config) != "203.0.113.10" {
			t.Fatal("REALITY identity changed")
		}
	})
	t.Run("REALITY ignores redundant TLS Host", func(t *testing.T) {
		config := endpointFixture(t)
		stream := proxyMap(config)["streamSettings"].(map[string]any)
		stream["security"] = "reality"
		stream["tlsSettings"].(map[string]any)["serverName"] = "inactive-tls.example.invalid"
		stream["realitySettings"] = map[string]any{"serverName": "active-reality.example.invalid"}
		if err := resolveEndpointWith(context.Background(), config, false, endpointSuccess(t, `{"Status":0,"Answer":[{"type":1,"data":"203.0.113.10"}]}`)); err != nil {
			t.Fatal(err)
		}
		headers := stream["wsSettings"].(map[string]any)["headers"].(map[string]any)
		if headers["Host"] != "active-reality.example.invalid" {
			t.Fatal("inactive TLS settings replaced REALITY virtual host")
		}
	})
}

type endpointBody struct {
	io.Reader
	read   int
	closed bool
}

func (b *endpointBody) Read(data []byte) (int, error) {
	n, err := b.Reader.Read(data)
	b.read += n
	return n, err
}
func (b *endpointBody) Close() error { b.closed = true; return nil }

func TestEndpointRejectsBadDoHWithoutMutation(t *testing.T) {
	for _, test := range []struct {
		name, body string
		status     int
	}{
		{"HTTP error", `{"Status":0,"Answer":[{"type":1,"data":"203.0.113.10"}]}`, 503},
		{"malformed", `{`, 200},
		{"missing status", `{"Answer":[{"type":1,"data":"203.0.113.10"}]}`, 200},
		{"NXDOMAIN", `{"Status":3}`, 200},
		{"no A records", `{"Status":0,"Answer":[{"type":28,"data":"2001:db8::1"}]}`, 200},
		{"invalid A", `{"Status":0,"Answer":[{"type":1,"data":"not an IP"}]}`, 200},
		{"oversized", `{"Status":0,"Answer":[{"type":1,"data":"203.0.113.10"}]}` + strings.Repeat(" ", 32768), 200},
		{"extra document", `{"Status":0,"Answer":[{"type":1,"data":"203.0.113.10"}]}{}`, 200},
	} {
		t.Run(test.name, func(t *testing.T) {
			config := endpointFixture(t)
			before, _ := json.Marshal(config)
			body := &endpointBody{Reader: strings.NewReader(test.body)}
			dependencies := endpointSuccess(t, "")
			dependencies.doHTTP = func(*http.Request) (*http.Response, error) {
				return &http.Response{StatusCode: test.status, Body: body}, nil
			}
			if err := resolveEndpointWith(context.Background(), config, false, dependencies); err == nil {
				t.Fatal("invalid response accepted")
			}
			after, _ := json.Marshal(config)
			if string(before) != string(after) || !body.closed || body.read > 32769 {
				t.Fatal("failure mutated config, leaked body, or exceeded body bound")
			}
		})
	}
}

func TestEndpointLiteralIPsDoNotUseResolvers(t *testing.T) {
	for _, address := range []string{"203.0.113.1", "2001:db8::1"} {
		config := endpointFixture(t)
		proxyMap(config)["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)["address"] = address
		err := resolveEndpointWith(context.Background(), config, true, endpointDependencies{})
		if (err != nil) != (address == "2001:db8::1") || endpointAddress(config) != address {
			t.Fatal("literal endpoint behavior changed")
		}
	}
}

func TestEndpointSystemFallbackOnlyForOrdinarySession(t *testing.T) {
	for _, ordinary := range []bool{false, true} {
		config := endpointFixture(t)
		calls := 0
		dependencies := endpointDependencies{
			doHTTP: func(*http.Request) (*http.Response, error) { return nil, errors.New("offline fixture") },
			lookup: func(ctx context.Context, network, host string) ([]net.IP, error) {
				calls++
				if network != "ip4" || host != "example.invalid" {
					t.Fatal("unbounded or wrong fallback query")
				}
				if deadline, ok := ctx.Deadline(); !ok || time.Until(deadline) > 10*time.Second {
					t.Fatal("missing shared deadline")
				}
				return []net.IP{net.ParseIP("2001:db8::1"), net.ParseIP("203.0.113.20")}, nil
			},
		}
		err := resolveEndpointWith(context.Background(), config, ordinary, dependencies)
		if ordinary {
			if err != nil || calls != 1 || endpointAddress(config) != "203.0.113.20" {
				t.Fatal("ordinary fallback failed")
			}
		} else if err == nil || calls != 0 || endpointAddress(config) != "example.invalid" {
			t.Fatal("protected resolver used system DNS")
		}
	}
}

func TestEndpointResolutionSharesDeadlineAndHonorsCancellation(t *testing.T) {
	config := endpointFixture(t)
	var dohDeadline, fallbackDeadline time.Time
	dependencies := endpointDependencies{
		doHTTP: func(request *http.Request) (*http.Response, error) {
			dohDeadline, _ = request.Context().Deadline()
			return nil, errors.New("offline fixture")
		},
		lookup: func(ctx context.Context, _, _ string) ([]net.IP, error) {
			fallbackDeadline, _ = ctx.Deadline()
			return []net.IP{net.ParseIP("203.0.113.5")}, nil
		},
	}
	if err := resolveEndpointWith(context.Background(), config, true, dependencies); err != nil {
		t.Fatal(err)
	}
	if dohDeadline.IsZero() || fallbackDeadline.IsZero() || !dohDeadline.Before(fallbackDeadline) || fallbackDeadline.Sub(dohDeadline) > 2*time.Second || time.Until(fallbackDeadline) > 10*time.Second {
		t.Fatal("resolver stages did not share bounded budget")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	config = endpointFixture(t)
	before, _ := json.Marshal(config)
	dependencies.doHTTP = func(request *http.Request) (*http.Response, error) {
		if !errors.Is(request.Context().Err(), context.Canceled) {
			t.Fatal("cancellation not inherited")
		}
		return nil, request.Context().Err()
	}
	dependencies.lookup = func(context.Context, string, string) ([]net.IP, error) {
		t.Fatal("fallback after cancellation")
		return nil, nil
	}
	if err := resolveEndpointWith(ctx, config, true, dependencies); err == nil {
		t.Fatal("cancelled resolution succeeded")
	}
	after, _ := json.Marshal(config)
	if !reflect.DeepEqual(before, after) {
		t.Fatal("cancelled resolution mutated endpoint")
	}
}

func TestEndpointSystemFallbackWithoutIPv4FailsClosed(t *testing.T) {
	for _, lookupErr := range []error{nil, errors.New("fixture private DNS failure")} {
		config := endpointFixture(t)
		dependencies := endpointDependencies{
			doHTTP: func(*http.Request) (*http.Response, error) { return nil, errors.New("offline fixture") },
			lookup: func(context.Context, string, string) ([]net.IP, error) {
				return []net.IP{net.ParseIP("2001:db8::1")}, lookupErr
			},
		}
		if err := resolveEndpointWith(context.Background(), config, true, dependencies); err == nil || strings.Contains(err.Error(), "private") || endpointAddress(config) != "example.invalid" {
			t.Fatal("failed fallback was accepted or leaked raw error")
		}
	}
}

func TestEndpointExpiredDeadlineDoesNotFallbackOrMutate(t *testing.T) {
	config := endpointFixture(t)
	before, _ := json.Marshal(config)
	ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancel()
	dependencies := endpointDependencies{
		doHTTP: func(request *http.Request) (*http.Response, error) {
			if !errors.Is(request.Context().Err(), context.DeadlineExceeded) {
				t.Fatal("deadline was not inherited")
			}
			return nil, request.Context().Err()
		},
		lookup: func(context.Context, string, string) ([]net.IP, error) {
			t.Fatal("fallback after timeout")
			return nil, nil
		},
	}
	if err := resolveEndpointWith(ctx, config, true, dependencies); err == nil {
		t.Fatal("expired deadline accepted")
	}
	after, _ := json.Marshal(config)
	if string(before) != string(after) {
		t.Fatal("expired request mutated endpoint")
	}
}
func TestProtectionRejectsMalformedIntent(t *testing.T) {
	f := fixture()
	f["desktop"] = map[string]any{"appMode": "all", "retries": 3, "strict": "yes"}
	data, _ := json.Marshal(f)
	if _, err := sanitizeConfig(data); err == nil {
		t.Fatal("accepted non-boolean protection")
	}
	for _, text := range []string{`{}`, `{"desktop":{"strict":false}}`, `{"desktop":{"strict":"yes"}}`} {
		if strictRequested([]byte(text)) {
			t.Fatal("invalid request armed protection")
		}
	}
	if !strictRequested([]byte(`{"desktop":{"strict":true}}`)) {
		t.Fatal("strict intent lost")
	}
}
