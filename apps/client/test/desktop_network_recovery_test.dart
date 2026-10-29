import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/domain/tunnel_config.dart';
import 'package:viora_client/platform/tunnel.dart';

TunnelConfig _config({
  bool reconnect = true,
  int retries = 1,
}) => TunnelConfig.build(
  profile: VlessProfile.parse(
    'vless://00000000-0000-4000-8000-000000000001@example.invalid:443?type=ws&security=tls',
  ),
  reconnect: reconnect,
  retries: retries,
);

class _Engine implements TunnelEngine {
  final statuses = StreamController<TunnelStats>.broadcast(sync: true);
  @override
  bool get supported => true;
  @override
  Stream<TunnelStats> get events => statuses.stream;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> start(TunnelConfig config, String name) async {}
  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = DesktopXrayEngine.channel;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final failure in ['backend_exited', 'frontend_exited']) {
    testWidgets(
      '$failure allows only three retries, each after a fresh stop acknowledgement',
      (tester) async {
        final frames = <String>[];
        var starts = 0, stops = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'desktopTunnelPoll':
              final reply = frames.join('\n');
              frames.clear();
              return reply;
            case 'desktopTunnelStart':
              starts++;
              frames.add('{"state":"CONNECTED"}');
              return null;
            case 'desktopTunnelStop':
              stops++;
              return null;
            default:
              throw StateError('Unexpected mocked method');
          }
        });
        final engine = DesktopXrayEngine();
        final tunnel = TunnelController(engine);
        await tunnel.connect(_config(retries: 3), 'Test');
        await tester.pump(const Duration(milliseconds: 200));
        for (var attempt = 1; attempt <= 3; attempt++) {
          frames.add(jsonEncode({'state': 'FAILED', 'code': failure}));
          await tester.pump(const Duration(milliseconds: 200));
          expect(tunnel.phase, TunnelPhase.connecting);
          await tester.pump(Duration(seconds: 1 << attempt));
          expect(stops, attempt);
          expect(starts, attempt);
          await tester.pump(const Duration(milliseconds: 200));
          expect(
            starts,
            attempt,
            reason: 'old child has not acknowledged stop',
          );
          frames.add('{"state":"DISCONNECTED"}');
          await tester.pump(const Duration(milliseconds: 200));
          expect(starts, attempt + 1);
          await tester.pump(const Duration(milliseconds: 200));
          expect(tunnel.phase, TunnelPhase.active);
        }
        frames.add(jsonEncode({'state': 'FAILED', 'code': failure}));
        await tester.pump(const Duration(milliseconds: 200));
        expect(tunnel.phase, TunnelPhase.failed);
        expect(tunnel.stats.errorCode, 'reconnect_exhausted');
        await tester.pump(const Duration(seconds: 20));
        expect(starts, 4);
        expect(stops, 3);
        tunnel.dispose();
        await engine.dispose();
      },
      skip: !Platform.isWindows,
    );
  }

  testWidgets(
    'network loss restarts only after stop acknowledgement and obeys retry cap',
    (tester) async {
      // Native IPC is fully mocked. No service, interface or VPN is started.
      final frames = <String>[];
      final commands = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'desktopTunnelPoll':
            final reply = frames.join('\n');
            frames.clear();
            return reply;
          case 'desktopTunnelStart':
            commands.add('start');
            frames.add('{"state":"CONNECTED"}');
            return null;
          case 'desktopTunnelStop':
            commands.add('stop');
            return null;
          default:
            throw StateError('Unexpected mocked method');
        }
      });
      final engine = DesktopXrayEngine();
      final tunnel = TunnelController(engine);
      await tunnel.connect(_config(), 'Test');
      await tester.pump(const Duration(milliseconds: 200));
      expect(tunnel.phase, TunnelPhase.active);

      frames.add(jsonEncode({'state': 'FAILED', 'code': 'network_changed'}));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tunnel.phase, TunnelPhase.connecting);
      await tester.pump(const Duration(seconds: 2));
      expect(commands, ['start', 'stop']);
      await tester.pump(const Duration(milliseconds: 200));
      expect(commands, ['start', 'stop']);

      frames.add('{"state":"DISCONNECTED"}');
      await tester.pump(const Duration(milliseconds: 200));
      expect(commands, ['start', 'stop', 'start']);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tunnel.phase, TunnelPhase.active);

      frames.add(jsonEncode({'state': 'FAILED', 'code': 'network_changed'}));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tunnel.phase, TunnelPhase.failed);
      expect(tunnel.stats.errorCode, 'reconnect_exhausted');
      await tester.pump(const Duration(seconds: 5));
      expect(commands, ['start', 'stop', 'start']);
      tunnel.dispose();
      await engine.dispose();
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'network loss respects disabled reconnect without issuing native stop',
    (tester) async {
      final frames = <String>[];
      var starts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'desktopTunnelPoll':
            final reply = frames.join('\n');
            frames.clear();
            return reply;
          case 'desktopTunnelStart':
            starts++;
            return null;
          default:
            throw StateError('Unexpected mocked method');
        }
      });
      final engine = DesktopXrayEngine();
      final tunnel = TunnelController(engine);
      await tunnel.connect(_config(reconnect: false), 'Test');
      frames.add(jsonEncode({'state': 'FAILED', 'code': 'network_changed'}));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tunnel.phase, TunnelPhase.failed);
      expect(tunnel.error, contains('Сетевое подключение изменилось'));
      await tester.pump(const Duration(seconds: 5));
      expect(starts, 1);
      tunnel.dispose();
      await engine.dispose();
    },
    skip: !Platform.isWindows,
  );

  for (final code in ['network_changed', 'outbound_interface_unavailable']) {
    test('network errors expose a fixed explanation for $code', () async {
      final engine = _Engine();
      final tunnel = TunnelController(engine);
      await tunnel.connect(_config(), 'Test');
      engine.statuses.add(TunnelStats('FAILED', errorCode: code));
      expect(tunnel.phase, TunnelPhase.failed);
      expect(tunnel.error?.toLowerCase(), contains('сетевое подключение'));
      expect(tunnel.error, isNot(contains(code)));
      tunnel.dispose();
      await engine.statuses.close();
    });
  }

  const bridgeMessages = {
    'backend_start_failed': 'Не удалось запустить VPN-движок.',
    'backend_not_ready': 'Не удалось запустить VPN-движок.',
    'frontend_start_failed': 'Не удалось подготовить сетевой адаптер VPN.',
    'frontend_not_ready': 'Не удалось подготовить сетевой адаптер VPN.',
    'backend_exited': 'VPN-компонент неожиданно остановился.',
    'frontend_exited': 'VPN-компонент неожиданно остановился.',
    'frontend_integrity': 'Сетевой компонент VPN отсутствует или повреждён.',
    'bridge_config_failed': 'Не удалось подготовить конфигурацию VPN.',
    'system_dns_failed': 'Не удалось настроить системный DNS для VPN.',
    'routing_setup_failed': 'Не удалось подготовить маршрутизацию Linux.',
    'routing_cleanup_failed': 'Не удалось полностью очистить маршруты VIORA.',
  };
  for (final entry in bridgeMessages.entries) {
    final code = entry.key;
    test(
      'bridge failure $code has a fixed explanation without native detail',
      () async {
        final engine = _Engine();
        final tunnel = TunnelController(engine);
        await tunnel.connect(_config(), 'Test');
        engine.statuses.add(TunnelStats('FAILED', errorCode: code));
        expect(tunnel.phase, TunnelPhase.failed);
        expect(tunnel.error, startsWith(entry.value));
        expect(tunnel.error, isNot(contains(code)));
        tunnel.dispose();
        await engine.statuses.close();
      },
    );
  }
}
