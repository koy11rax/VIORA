import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/platform/connection_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_v2ray_client');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'native probe passes the HTTPS endpoint and preserves measured delay',
    () async {
      for (final value in [0, 71, 12000]) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getConnectedServerDelay');
          expect(call.arguments, {
            'url': 'https://www.gstatic.com/generate_204',
          });
          return value;
        });
        expect(await AndroidConnectionProbe.measure(), value);
      }
    },
  );

  test(
    'negative, absent and malformed native values never confirm a response',
    () async {
      for (final value in [-1, -100, null, '71', 71.5]) {
        messenger.setMockMethodCallHandler(channel, (_) async => value);
        expect(await AndroidConnectionProbe.measure(), isNull);
      }
    },
  );

  test(
    'cancel, native errors and unavailable plugin return an unknown result',
    () async {
      for (final code in ['cancelled', 'unavailable', 'measurement_failed']) {
        messenger.setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(
            code: code,
            message: 'Native diagnostic detail',
          );
        });
        expect(await AndroidConnectionProbe.measure(), isNull);
      }
      messenger.setMockMethodCallHandler(channel, null);
      expect(await AndroidConnectionProbe.measure(), isNull);
    },
  );

  test(
    'deadline bounds a missing native callback and ignores a late reply',
    () async {
      final reply = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => reply.future);
      expect(
        await AndroidConnectionProbe.measure(
          timeout: const Duration(milliseconds: 1),
        ),
        isNull,
      );
      reply.complete(71);
      await Future<void>.delayed(Duration.zero);
    },
  );
}
