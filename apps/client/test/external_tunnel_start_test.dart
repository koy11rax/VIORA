import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/domain/tunnel_config.dart';
import 'package:viora_client/platform/tunnel.dart';

// This engine only emits fixture events. No Android service, permission dialog,
// native channel, real profile, network or VPN is used by these regressions.
class _ExternalStartEngine implements TunnelEngine {
  final stream = StreamController<TunnelStats>.broadcast(sync: true);
  Completer<void>? startGate;
  Completer<void>? stopGate;
  var starts = 0;
  var stops = 0;

  @override
  bool get supported => true;
  @override
  Stream<TunnelStats> get events => stream.stream;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> start(TunnelConfig config, String name) async {
    starts++;
    await startGate?.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    await stopGate?.future;
    stream.add(const TunnelStats('DISCONNECTED'));
  }
}

TunnelController _controller(_ExternalStartEngine engine) {
  final controller = TunnelController(engine);
  addTearDown(() async {
    controller.dispose();
    await engine.stream.close();
  });
  return controller;
}

TunnelConfig _config() => TunnelConfig.build(
  profile: VlessProfile.parse(
    'vless://00000000-0000-4000-8000-000000000001@example.invalid:443?type=ws&security=tls',
  ),
);

List<Object?> _frame(String state, {Object? externalStart = 'true'}) => [
  '00:01:23',
  '10',
  '20',
  '1024',
  '2048',
  state,
  '',
  'true',
  'true',
  externalStart,
];

void main() {
  group('external start and expired UI attempts', () {
    testWidgets(
      'late unmarked CONNECTING then CONNECTED cannot revive a timeout',
      (tester) async {
        final engine = _ExternalStartEngine();
        final controller = _controller(engine);
        await controller.connect(
          _config(),
          'Expired UI attempt',
          timeout: const Duration(seconds: 1),
        );
        await tester.pump(const Duration(seconds: 2));
        expect(controller.phase, TunnelPhase.failed);
        expect(engine.stops, 1);
        final failure = controller.error;

        engine.stream.add(const TunnelStats('CONNECTING'));
        expect(controller.phase, TunnelPhase.failed);
        expect(controller.error, failure);
        expect(engine.stops, 1);
        engine.stream.add(const TunnelStats('CONNECTED'));
        await tester.pump();

        expect(controller.phase, TunnelPhase.failed);
        expect(controller.error, failure);
        expect(engine.starts, 1);
        expect(engine.stops, 2);
        expect(controller.busy, isFalse);
      },
    );

    testWidgets(
      'a tagged CONNECTED alone cannot bypass the fresh CONNECTING boundary',
      (tester) async {
        final engine = _ExternalStartEngine();
        final controller = _controller(engine);
        await controller.connect(
          _config(),
          'Expired UI attempt',
          timeout: const Duration(seconds: 1),
        );
        await tester.pump(const Duration(seconds: 2));
        expect(controller.phase, TunnelPhase.failed);

        engine.stream.add(const TunnelStats('CONNECTED', externalStart: true));
        await tester.pump();

        expect(controller.phase, TunnelPhase.failed);
        expect(engine.starts, 1);
        expect(engine.stops, 2);
      },
    );

    testWidgets(
      'fresh external CONNECTING after a timeout accepts native CONNECTED without stopping it',
      (tester) async {
        final engine = _ExternalStartEngine();
        final controller = _controller(engine);
        await controller.connect(
          _config(),
          'Expired UI attempt',
          timeout: const Duration(seconds: 1),
        );
        await tester.pump(const Duration(seconds: 2));
        expect(controller.phase, TunnelPhase.failed);
        expect(engine.stops, 1);
        expect(controller.error, isNotNull);

        engine.stream.add(const TunnelStats('CONNECTING', externalStart: true));
        expect(controller.phase, TunnelPhase.connecting);
        expect(controller.error, isNull);
        engine.stream.add(const TunnelStats('CONNECTED', upload: 1024));
        await tester.pump();

        expect(controller.phase, TunnelPhase.active);
        expect(controller.stats.upload, 1024);
        expect(controller.error, isNull);
        expect(engine.starts, 1); // Only the old UI command was issued by Dart.
        expect(engine.stops, 1); // The fresh native session was not stopped.
      },
    );

    test(
      'fresh external CONNECTING also recovers an observed native failure',
      () async {
        final engine = _ExternalStartEngine();
        final controller = _controller(engine);
        await controller.initialize();
        engine.stream.add(
          const TunnelStats('FAILED', errorCode: 'reconnect_exhausted'),
        );
        expect(controller.phase, TunnelPhase.failed);

        engine.stream.add(const TunnelStats('CONNECTING', externalStart: true));
        engine.stream.add(const TunnelStats('CONNECTED'));

        expect(controller.phase, TunnelPhase.active);
        expect(controller.error, isNull);
        expect(engine.starts, 0);
        expect(engine.stops, 0);
      },
    );

    testWidgets(
      'external start events do not cancel an explicit in-flight disconnect',
      (tester) async {
        final engine = _ExternalStartEngine();
        final controller = _controller(engine);
        await controller.connect(_config(), 'UI attempt');
        engine.stream.add(const TunnelStats('CONNECTED'));
        engine.stopGate = Completer<void>();
        final disconnecting = controller.disconnect();
        await tester.pump();
        expect(controller.phase, TunnelPhase.stopping);

        engine.stream.add(const TunnelStats('CONNECTING', externalStart: true));
        engine.stream.add(const TunnelStats('CONNECTED'));
        expect(controller.phase, TunnelPhase.stopping);
        engine.stopGate!.complete();
        await disconnecting;

        expect(controller.phase, TunnelPhase.disconnected);
        expect(engine.stops, 1);
      },
    );

    testWidgets(
      'listeners are notified when the final start operation clears busy',
      (tester) async {
        final engine = _ExternalStartEngine()..startGate = Completer<void>();
        final controller = _controller(engine);
        final observedBusy = <bool>[];
        controller.addListener(() => observedBusy.add(controller.busy));
        final connecting = controller.connect(_config(), 'UI attempt');
        await tester.pump();
        expect(engine.starts, 1);
        engine.stream.add(const TunnelStats('CONNECTED'));
        expect(controller.phase, TunnelPhase.active);
        expect(controller.busy, isTrue);
        expect(observedBusy.last, isTrue);

        engine.startGate!.complete();
        await connecting;

        expect(controller.busy, isFalse);
        // A queued refresh depends on the notification, not just the getter.
        expect(observedBusy.last, isFalse);
        expect(engine.stops, 0);
      },
    );
  });

  group('Android external-start frame compatibility', () {
    for (final length in [6, 7, 8, 9]) {
      test('legacy $length-field frame defaults externalStart to false', () {
        final stats = AndroidXrayEngine.decodeStatus(
          _frame('CONNECTING').take(length).toList(),
        );

        expect(stats.state, 'CONNECTING');
        expect(stats.duration, '00:01:23');
        expect(stats.upload, 1024);
        expect(stats.download, 2048);
        expect(stats.externalStart, isFalse);
        expect(stats.alwaysOn, length >= 8);
        expect(stats.lockdown, length >= 9);
      });
    }

    test(
      'the tenth literal true field carries an explicit new native start',
      () {
        final stats = AndroidXrayEngine.decodeStatus(_frame('CONNECTING'));

        expect(stats.externalStart, isTrue);
        expect(stats.alwaysOn, isTrue);
        expect(stats.lockdown, isTrue);
        expect(stats.errorCode, isNull);
        expect(stats.state, 'CONNECTING');
      },
    );

    test(
      'false or non-contract external-start values cannot grant the marker',
      () {
        for (final value in <Object?>[
          'false',
          '',
          'TRUE',
          '1',
          true,
          false,
          null,
        ]) {
          final stats = AndroidXrayEngine.decodeStatus(
            _frame('CONNECTING', externalStart: value),
          );
          expect(
            stats.externalStart,
            isFalse,
            reason: 'Only the native boolean-string true is accepted',
          );
        }
        expect(const TunnelStats('CONNECTING').externalStart, isFalse);
      },
    );

    test('out-of-contract frame lengths are still rejected', () {
      expect(
        () => AndroidXrayEngine.decodeStatus(
          _frame('CONNECTING').take(5).toList(),
        ),
        throwsFormatException,
      );
      expect(
        () =>
            AndroidXrayEngine.decodeStatus([..._frame('CONNECTING'), 'extra']),
        throwsFormatException,
      );
    });
  });
}
