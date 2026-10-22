import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/domain/tunnel_config.dart';
import 'package:viora_client/platform/tunnel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = DesktopXrayEngine.channel;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  testWidgets(
    'native polling continues after a transient failure and allows an explicit retry',
    (tester) async {
      // Every native call is mocked. No installed service, network or VPN is used.
      var polls = 0, starts = 0;
      var nativeState = 'DISCONNECTED';
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'desktopTunnelPoll':
            polls++;
            if (polls == 1) {
              throw PlatformException(code: 'temporary_ipc_failure');
            }
            return jsonEncode({'state': nativeState});
          case 'desktopTunnelStart':
            starts++;
            nativeState = 'CONNECTED';
            return null;
          case 'desktopTunnelStop':
            nativeState = 'DISCONNECTED';
            return null;
          default:
            throw StateError('Unexpected fixture method ${call.method}');
        }
      });
      final engine = DesktopXrayEngine();
      final tunnel = TunnelController(engine);
      final config = TunnelConfig.build(
        profile: VlessProfile.parse(
          'vless://00000000-0000-4000-8000-000000000001@example.invalid:443?type=ws&security=tls',
        ),
      );
      await tunnel.connect(config, 'First');
      await tester.pump(const Duration(milliseconds: 200));
      expect(tunnel.phase, TunnelPhase.failed);
      expect(polls, 1);

      final retry = tunnel.connect(config, 'Retry');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await retry;
      expect(starts, 2);
      expect(tunnel.phase, TunnelPhase.connecting);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tunnel.phase, TunnelPhase.active);
      expect(polls, 3);

      tunnel.dispose();
      await engine.dispose();
      await tester.pump(const Duration(seconds: 1));
      expect(polls, 3);
    },
    skip: !Platform.isWindows,
  );

  test(
    'a sustained IPC outage reports uncertainty once and keeps checking',
    () async {
      var polls = 0;
      final observed = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'desktopTunnelPoll');
        polls++;
        if (polls == 3) observed.complete();
        throw PlatformException(code: 'temporary_ipc_failure');
      });
      final engine = DesktopXrayEngine();
      final statuses = <TunnelStats>[];
      final subscription = engine.events.listen(statuses.add);
      try {
        await engine.initialize();
        await observed.future.timeout(const Duration(seconds: 3));
        expect(polls, 3);
        expect(statuses.map((s) => s.state), ['FAILED']);
        expect(statuses.single.errorCode, 'ipc_failed');
      } finally {
        await subscription.cancel();
        await engine.dispose();
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'polls never overlap and late native replies are ignored after disposal',
    () async {
      var polls = 0;
      final reply = Completer<String>();
      final observed = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'desktopTunnelPoll');
        polls++;
        observed.complete();
        return reply.future;
      });
      final engine = DesktopXrayEngine();
      final statuses = <TunnelStats>[];
      final subscription = engine.events.listen(statuses.add);
      try {
        await engine.initialize();
        await observed.future.timeout(const Duration(seconds: 3));
        await Future<void>.delayed(const Duration(milliseconds: 450));
        expect(polls, 1);
        await engine.dispose();
        reply.complete('{"state":"CONNECTED"}');
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(statuses, isEmpty);
        expect(polls, 1);
      } finally {
        await subscription.cancel();
        await engine.dispose();
      }
    },
    skip: !Platform.isWindows,
  );
}
