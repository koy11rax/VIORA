import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/domain/tunnel_config.dart';
import 'package:viora_client/platform/quick_settings.dart';
import 'package:viora_client/platform/tunnel.dart';

// All native observations and commands are fixtures. These tests never start a
// real engine, ask Android for permission, change routes, or contact a server.
class _SnapshotEngine implements TunnelEngine, TunnelStatusReader {
  final _events = StreamController<TunnelStats>.broadcast(sync: true);
  Future<TunnelStats?> Function() snapshot = () async => null;
  Future<void> Function()? onStart;
  var initializations = 0;
  var reads = 0;
  var permissions = 0;
  var starts = 0;
  var stops = 0;

  @override
  bool get supported => true;

  @override
  Stream<TunnelStats> get events => _events.stream;

  @override
  Future<void> initialize() async {
    initializations++;
  }

  @override
  Future<TunnelStats?> readStatus() {
    reads++;
    return snapshot();
  }

  @override
  Future<bool> requestPermission() async {
    permissions++;
    return true;
  }

  @override
  Future<void> start(TunnelConfig config, String name) async {
    starts++;
    await onStart?.call();
  }

  @override
  Future<void> stop() async {
    stops++;
    _events.add(const TunnelStats('DISCONNECTED'));
  }

  void emit(TunnelStats value) => _events.add(value);
  Future<void> close() => _events.close();
}

TunnelController _controller(_SnapshotEngine engine) {
  final controller = TunnelController(engine);
  addTearDown(() async {
    controller.dispose();
    await engine.close();
  });
  return controller;
}

TunnelConfig _config() => TunnelConfig.build(
  profile: VlessProfile.parse(
    'vless://00000000-0000-4000-8000-000000000001@example.invalid:443?type=ws&security=tls',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('tile status synchronization', () {
    test(
      'cold native CONNECTED is adopted without starting another tunnel',
      () async {
        const observed = TunnelStats(
          'CONNECTED',
          duration: '00:03:14',
          upload: 123,
          download: 456,
        );
        final engine = _SnapshotEngine()..snapshot = () async => observed;
        final controller = _controller(engine);

        expect(await controller.synchronizeNativeStatus(), isTrue);
        expect(controller.phase, TunnelPhase.active);
        expect(controller.stats, same(observed));
        expect(controller.error, isNull);
        await controller.connect(_config(), 'Tile request');

        expect(engine.initializations, 1);
        expect(engine.reads, 1);
        expect(engine.permissions, 0);
        expect(engine.starts, 0);
        expect(engine.stops, 0);
        expect(controller.phase, TunnelPhase.active);
      },
    );

    test(
      'cold native CONNECTING prevents a duplicate explicit start',
      () async {
        final engine = _SnapshotEngine()
          ..snapshot = () async => const TunnelStats('CONNECTING');
        final controller = _controller(engine);

        expect(await controller.synchronizeNativeStatus(), isTrue);
        expect(controller.phase, TunnelPhase.connecting);
        await controller.connect(_config(), 'Tile request');

        expect(engine.permissions, 0);
        expect(engine.starts, 0);
        expect(engine.stops, 0);
        expect(controller.phase, TunnelPhase.connecting);
      },
    );

    for (final state in ['UNKNOWN', '', 'connected', 'STOPPED']) {
      test(
        'unrecognized native state "$state" is not permission to connect',
        () async {
          final engine = _SnapshotEngine()
            ..snapshot = () async => TunnelStats(state);
          final controller = _controller(engine);
          final originalStats = controller.stats;

          expect(await controller.synchronizeNativeStatus(), isFalse);
          expect(controller.phase, TunnelPhase.disconnected);
          expect(controller.stats, same(originalStats));
          expect(engine.permissions, 0);
          expect(engine.starts, 0);
          expect(engine.stops, 0);
        },
      );
    }

    test(
      'null snapshot refuses the tile request without changing native state',
      () async {
        final engine = _SnapshotEngine();
        final controller = _controller(engine);

        expect(await controller.synchronizeNativeStatus(), isFalse);
        expect(engine.reads, 1);
        expect(engine.permissions, 0);
        expect(engine.starts, 0);
        expect(engine.stops, 0);
        expect(controller.phase, TunnelPhase.disconnected);
      },
    );

    test(
      'failed snapshot refuses the request instead of assuming stopped',
      () async {
        final engine = _SnapshotEngine()
          ..snapshot = () async => throw StateError('fixture IPC unavailable');
        final controller = _controller(engine);

        expect(await controller.synchronizeNativeStatus(), isFalse);
        expect(controller.phase, TunnelPhase.disconnected);
        expect(engine.permissions, 0);
        expect(engine.starts, 0);
        expect(engine.stops, 0);
      },
    );

    test(
      'native DISCONNECTED permits one explicit connection and waits for an event',
      () async {
        final engine = _SnapshotEngine()
          ..snapshot = () async => const TunnelStats('DISCONNECTED');
        final controller = _controller(engine);

        expect(await controller.synchronizeNativeStatus(), isTrue);
        expect(controller.phase, TunnelPhase.disconnected);
        expect(engine.starts, 0);
        await controller.connect(_config(), 'Selected profile');

        expect(engine.permissions, 1);
        expect(engine.starts, 1);
        expect(engine.stops, 0);
        expect(controller.phase, TunnelPhase.connecting);
        expect(controller.activeProfile, 'Selected profile');
        engine.emit(const TunnelStats('CONNECTED'));
        expect(controller.phase, TunnelPhase.active);
      },
    );

    test('in-flight UI connect wins a delayed DISCONNECTED snapshot', () async {
      final readEntered = Completer<void>();
      final snapshot = Completer<TunnelStats?>();
      final startEntered = Completer<void>();
      final startFinished = Completer<void>();
      final engine = _SnapshotEngine()
        ..snapshot = () {
          readEntered.complete();
          return snapshot.future;
        }
        ..onStart = () {
          startEntered.complete();
          return startFinished.future;
        };
      final controller = _controller(engine);

      final synchronization = controller.synchronizeNativeStatus();
      await readEntered.future;
      final connecting = controller.connect(_config(), 'UI selected profile');
      await startEntered.future;
      final currentStats = controller.stats;
      snapshot.complete(const TunnelStats('DISCONNECTED'));

      expect(await synchronization, isTrue);
      expect(controller.phase, TunnelPhase.connecting);
      expect(controller.stats, same(currentStats));
      expect(controller.activeProfile, 'UI selected profile');
      expect(engine.permissions, 1);
      expect(engine.starts, 1);
      expect(engine.stops, 0);
      startFinished.complete();
      await connecting;
      engine.emit(const TunnelStats('CONNECTED'));
      expect(controller.phase, TunnelPhase.active);
    });

    test(
      'initialization alone never substitutes for a fresh native snapshot',
      () async {
        final engine = _SnapshotEngine();
        final controller = _controller(engine);
        await controller.initialize();

        expect(engine.initializations, 1);
        expect(engine.reads, 0);
        expect(controller.phase, TunnelPhase.disconnected);
        expect(await controller.synchronizeNativeStatus(), isFalse);
        expect(engine.reads, 1);
        expect(engine.starts, 0);
        expect(engine.stops, 0);
      },
    );
  });

  group('AndroidXrayEngine authoritative snapshot bridge', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final engineCalls = <String>[];
    setUp(() {
      engineCalls.clear();
      messenger.setMockMethodCallHandler(AndroidXrayEngine.channel, (
        call,
      ) async {
        engineCalls.add(call.method);
        throw StateError('Snapshot must not mutate the native VPN');
      });
    });
    tearDown(() {
      messenger.setMockMethodCallHandler(QuickSettings.channel, null);
      messenger.setMockMethodCallHandler(AndroidXrayEngine.channel, null);
    });

    for (final state in ['CONNECTED', 'CONNECTING', 'DISCONNECTED', 'FAILED']) {
      test(
        '$state reads the quick tile snapshot without engine commands',
        () async {
          final methods = <String>[];
          messenger.setMockMethodCallHandler(QuickSettings.channel, (
            call,
          ) async {
            methods.add(call.method);
            return state;
          });

          final result = await AndroidXrayEngine().readStatus();

          expect(result, isNotNull);
          expect(result!.state, state == 'FAILED' ? 'DISCONNECTED' : state);
          expect(methods, ['snapshot']);
          expect(engineCalls, isEmpty);
        },
      );
    }

    for (final state in <String?>[null, 'UNKNOWN', '', 'connected']) {
      test(
        'snapshot $state stays unknown rather than becoming disconnected',
        () async {
          messenger.setMockMethodCallHandler(QuickSettings.channel, (
            call,
          ) async {
            expect(call.method, 'snapshot');
            return state;
          });

          expect(await AndroidXrayEngine().readStatus(), isNull);
          expect(engineCalls, isEmpty);
        },
      );
    }

    test('a native snapshot error stays unknown', () async {
      messenger.setMockMethodCallHandler(QuickSettings.channel, (call) async {
        expect(call.method, 'snapshot');
        throw PlatformException(code: 'fixture_snapshot_unavailable');
      });

      expect(await AndroidXrayEngine().readStatus(), isNull);
      expect(engineCalls, isEmpty);
    });

    test(
      'a missing bridge stays unknown without a fallback engine start',
      () async {
        messenger.setMockMethodCallHandler(QuickSettings.channel, null);

        expect(await AndroidXrayEngine().readStatus(), isNull);
        expect(engineCalls, isEmpty);
      },
    );
  });
}
