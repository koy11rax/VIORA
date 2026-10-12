import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() main) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final fixtureVault = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dev.viora/platform'), (
          call,
        ) async {
          switch (call.method) {
            case 'readProfiles':
              return fixtureVault['profiles'];
            case 'readSession':
              return fixtureVault['session'];
            case 'saveProfiles':
              fixtureVault['profiles'] =
                  (call.arguments as Map)['value'] as String;
              return null;
            case 'saveSession':
              fixtureVault['session'] =
                  (call.arguments as Map)['value'] as String;
              return null;
            case 'clearSession':
              fixtureVault.remove('session');
              return null;
            case 'installationId':
              return '1' * 32;
            default:
              throw MissingPluginException('Not enabled by this fixture');
          }
        });
  });
  await main();
}
