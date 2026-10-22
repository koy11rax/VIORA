import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/platform/desktop_protection.dart';

void main() {
  // These fixtures intercept the Windows method channel only. The Linux
  // implementation invokes pkexec, so it must never run under these mocks.
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.viora/platform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'Windows protection reports only the broker-confirmed state',
    () async {
      // Mock IPC only: never invoke the installed service or real firewall.
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'desktopProtection');
        return call.arguments['action'] == 'disable' ? 'OFF' : 'ON';
      });
      expect(await DesktopProtection.change('enable'), isTrue);
      expect(await DesktopProtection.change('disable'), isFalse);
    },
    skip: !Platform.isWindows,
  );
  test(
    'An unavailable Windows broker or busy tunnel never becomes success',
    () async {
      for (final reply in ['BUSY', 'UNAVAILABLE', 'ERROR', '']) {
        messenger.setMockMethodCallHandler(channel, (_) async => reply);
        await expectLater(
          DesktopProtection.change('enable'),
          throwsFormatException,
        );
      }
      await expectLater(
        DesktopProtection.change('other'),
        throwsFormatException,
      );
    },
    skip: !Platform.isWindows,
  );
}
