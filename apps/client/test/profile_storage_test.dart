import 'dart:async';
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
  test('identical queued snapshots avoid redundant protected writes', () async {
    final profile = VlessProfile.parse(link);
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ProfileStorage.channel, (call) async {
          expect(call.method, 'saveProfiles');
          calls++;
          return null;
        });

    // Reproduce the old serialized save path with identical payloads. These
    // elapsed times measure fixture overhead, not disk/crypto or VPN speed.
    final beforeWatch = Stopwatch()..start();
    Future<void> pending = Future.value();
    final beforeWrites = <Future<void>>[];
    for (var i = 0; i < 100; i++) {
      final value = jsonEncode({
        'version': 2,
        'subscriptions': <String, List<String>>{},
        'profiles': [profile.toShareLink()],
        'selected': 0,
      });
      final write = pending.then(
        (_) => ProfileStorage.channel.invokeMethod<void>('saveProfiles', {
          'value': value,
        }),
      );
      pending = write.catchError((Object _) {});
      beforeWrites.add(write);
    }
    await Future.wait(beforeWrites);
    beforeWatch.stop();
    expect(calls, 100);
    final beforeCalls = calls;
    calls = 0;
    final storage = ProfileStorage();
    final afterWatch = Stopwatch()..start();
    await Future.wait(List.generate(100, (_) => storage.save([profile], 0)));
    afterWatch.stop();
    expect(calls, 1);
    // Sanitized and reproducible evidence: no configuration or identifiers.
    // ignore: avoid_print
    print(
      'PROFILE_STORAGE_BENCHMARK ${jsonEncode({'snapshots': 100, 'before_native_writes': beforeCalls, 'after_native_writes': calls, 'before_fixture_microseconds': beforeWatch.elapsedMicroseconds, 'after_fixture_microseconds': afterWatch.elapsedMicroseconds, 'measurement': 'mock_method_channel_overhead_only'})}',
    );
  });

  test(
    'queued change then reversion preserves every acknowledged ordering',
    () async {
      final writes = <int>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ProfileStorage.channel, (call) async {
            final payload =
                jsonDecode((call.arguments as Map)['value'] as String) as Map;
            writes.add(payload['selected'] as int);
            return null;
          });
      final storage = ProfileStorage();
      final profiles = [VlessProfile.parse(link)];
      await storage.save(profiles, 0);
      await Future.wait([
        storage.save(profiles, -1),
        storage.save(profiles, 0),
        storage.save(profiles, 0),
      ]);
      expect(writes, [0, -1, 0]);
    },
  );

  test(
    'failed queued snapshots report original error and retry before deduplication',
    () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ProfileStorage.channel, (call) async {
            calls++;
            if (calls == 1) throw PlatformException(code: 'storage_error');
            return null;
          });
      final storage = ProfileStorage();
      final profiles = [VlessProfile.parse(link)];
      final failed = expectLater(
        storage.save(profiles, 0),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'storage_error',
          ),
        ),
      );
      final retried = storage.save(profiles, 0);
      final duplicate = storage.save(profiles, 0);
      await Future.wait([failed, retried, duplicate]);
      expect(calls, 2);
    },
  );

  test(
    'load observes pending writes and invalidates the deduplication cache',
    () async {
      String? vault;
      var writes = 0;
      final firstWrite = Completer<void>();
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ProfileStorage.channel, (call) async {
            methods.add(call.method);
            if (call.method == 'readProfiles') return vault;
            writes++;
            if (writes == 1) await firstWrite.future;
            vault = (call.arguments as Map)['value'] as String;
            return null;
          });
      final storage = ProfileStorage();
      final profiles = [VlessProfile.parse(link)];
      final saving = storage.save(profiles, 0);
      final loading = storage.load();
      await Future<void>.delayed(Duration.zero);
      expect(methods, ['saveProfiles']);
      firstWrite.complete();
      await saving;
      expect((await loading).$2, 0);
      vault = jsonEncode({
        'version': 1,
        'profiles': [link],
        'selected': -1,
      });
      expect((await storage.load()).$2, -1);
      await storage.save(profiles, 0);
      expect(writes, 2);
      expect(jsonDecode(vault!)['version'], 2);
      expect(jsonDecode(vault!)['selected'], 0);
    },
  );
}
