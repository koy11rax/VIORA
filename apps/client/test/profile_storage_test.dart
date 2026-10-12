import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/data/profile_storage.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/features/client/client_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const link =
      'vless://00000000-0000-4000-8000-000000000001@example.invalid:443?type=ws&security=tls#Test';
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ProfileStorage.channel, null),
  );
  test(
    'version 1 profiles migrate and oversized source sets are rejected before writing',
    () async {
      var writes = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ProfileStorage.channel, (call) async {
            if (call.method == 'readProfiles') {
              return jsonEncode({
                'version': 1,
                'profiles': [link],
                'selected': 0,
              });
            }
            writes++;
            return null;
          });
      final storage = ProfileStorage();
      final saved = await storage.load();
      expect(saved.$1.single.name, 'Test');
      expect(storage.subscriptions, isEmpty);
      final sources = {
        for (var i = 0; i < 201; i++) 'https://example.invalid/sub/$i': [link],
      };
      expect(
        () => storage.save(saved.$1, 0, sources: sources),
        throwsFormatException,
      );
      expect(writes, 0);
    },
  );
  test(
    'profiles use only the protected native channel; preferences never contain credentials',
    () async {
      String? encryptedPayload;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ProfileStorage.channel, (call) async {
            if (call.method == 'saveProfiles') {
              encryptedPayload = call.arguments['value'] as String;
              return null;
            }
            if (call.method == 'readProfiles') return encryptedPayload;
            throw PlatformException(code: 'unexpected');
          });
      final state = ClientState()
        ..profiles.add(VlessProfile.parse(link))
        ..selectedProfile = 0;
      addTearDown(state.tunnel.dispose);
      final storage = ProfileStorage();
      state.subscriptions['https://example.invalid/sub/secret'] = [
        state.profiles.single.toShareLink(),
      ];
      await storage.save(
        state.profiles,
        state.selectedProfile,
        sources: state.subscriptions,
      );
      final restored = await storage.load();
      expect(restored.$1.single.host, 'example.invalid');
      expect(restored.$2, 0);
      expect(
        storage.subscriptions.keys.single,
        'https://example.invalid/sub/secret',
      );
      expect(jsonEncode(state.toJson()), isNot(contains('secret')));
      expect(jsonEncode(state.toJson()), isNot(contains('00000000')));
      expect(jsonEncode(state.toJson()), isNot(contains('vless://')));
      final percentName = VlessProfile.parse(
        link.replaceFirst('#Test', '#Test%20100%25'),
      );
      expect(VlessProfile.parse(percentName.toShareLink()).name, 'Test 100%');
    },
  );
  test(
    'failed encrypted write is reported and does not prevent a later save',
    () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ProfileStorage.channel, (call) async {
            calls++;
            if (calls == 1) throw PlatformException(code: 'storage_error');
            return null;
          });
      final storage = ProfileStorage();
      await expectLater(
        storage.save([VlessProfile.parse(link)], 0),
        throwsA(isA<PlatformException>()),
      );
      await storage.save([VlessProfile.parse(link)], 0);
      expect(calls, 2);
    },
  );
}
