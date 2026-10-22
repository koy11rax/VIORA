import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/features/client/client_page.dart';
import 'package:viora_client/features/client/settings_detail.dart';
import 'package:viora_client/platform/quick_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.viora/quick_settings');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'tile bridge preserves every Android result without inventing success',
    () async {
      for (final result in [
        'added',
        'already_added',
        'not_added',
        'manual',
        'unavailable',
      ]) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'requestAddTile');
          expect(call.arguments, isNull);
          return result;
        });
        expect(await QuickSettings.requestAddTile(), result);
      }
      messenger.setMockMethodCallHandler(channel, (_) async => 'unknown');
      expect(await QuickSettings.requestAddTile(), 'unavailable');
      messenger.setMockMethodCallHandler(channel, null);
      expect(await QuickSettings.requestAddTile(), 'unavailable');
    },
  );

  test(
    'profile bridge preserves configuration and explicit cache clear',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final profile = <String, dynamic>{
        'version': 1,
        'config': '{"inbounds":[],"outbounds":[]}',
        'name': 'Regression fixture',
        'mtu': 1420,
        'reconnect': true,
        'retries': 3,
        'strict': false,
        'allowed': ['org.example.allowed'],
        'blocked': <String>[],
      };
      await QuickSettings.prepareProfile(profile);
      expect(calls.single.method, 'prepareProfile');
      expect(calls.single.arguments, profile);
      final excludedApplications = <String, dynamic>{
        ...profile,
        'allowed': null,
        'blocked': ['org.example.blocked'],
      };
      await QuickSettings.prepareProfile(excludedApplications);
      expect(calls[1].arguments, excludedApplications);
      final allApplications = <String, dynamic>{...profile, 'allowed': null};
      await QuickSettings.prepareProfile(allApplications);
      expect(calls[2].arguments, allApplications);
      await QuickSettings.prepareProfile(null);
      expect(calls[3].method, 'prepareProfile');
      expect(calls[3].arguments, isNull);
      expect(calls, hasLength(4));
    },
  );

  test('profile preparation waits for native acknowledgement', () async {
    final acknowledgement = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (_) async {
      await acknowledgement.future;
      return null;
    });
    var finished = false;
    final pending = QuickSettings.prepareProfile(
      null,
    ).then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    acknowledgement.complete();
    await pending;
    expect(finished, isTrue);
  });

  test(
    'profile preparation propagates native and missing bridge failures',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'profile_invalid');
      });
      await expectLater(
        QuickSettings.prepareProfile({'config': 'invalid fixture'}),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'profile_invalid',
          ),
        ),
      );
      messenger.setMockMethodCallHandler(channel, null);
      await expectLater(
        QuickSettings.prepareProfile(null),
        throwsA(isA<MissingPluginException>()),
      );
    },
  );

  test('snapshot bridge only accepts actual native service phases', () async {
    for (final phase in ['CONNECTED', 'CONNECTING', 'DISCONNECTED', 'FAILED']) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'snapshot');
        expect(call.arguments, isNull);
        return phase;
      });
      expect(await QuickSettings.readStatus(), phase);
    }
    for (final unsupported in ['UNKNOWN', 'STOPPING', '', null]) {
      messenger.setMockMethodCallHandler(channel, (_) async => unsupported);
      expect(await QuickSettings.readStatus(), isNull);
    }
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'unavailable');
    });
    expect(await QuickSettings.readStatus(), isNull);
    messenger.setMockMethodCallHandler(channel, null);
    expect(await QuickSettings.readStatus(), isNull);
  });

  Future<void> showSettings(
    WidgetTester tester,
    List<String> notices, {
    bool supported = true,
  }) async {
    final state = ClientState();
    addTearDown(state.tunnel.dispose);
    addTearDown(state.account.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SettingsDetail(
              index: 12,
              state: state,
              onChanged: () {},
              onNavigate: (_) {},
              onNotice: notices.add,
              quickSettingsSupported: supported,
            ),
          ),
        ),
      ),
    );
  }

  const button = Key('quick-settings-add-tile');
  testWidgets(
    'desktop settings hide Android tile controls without invoking native',
    (tester) async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return 'added';
      });
      await showSettings(tester, [], supported: false);
      expect(find.byKey(button), findsNothing);
      expect(calls, 0);
    },
  );

  for (final entry in {
    'added': 'Плитка VIORA добавлена в быстрые настройки',
    'already_added': 'Плитка VIORA уже есть в быстрых настройках',
    'not_added': 'Добавление отменено. Плитку можно добавить вручную',
    'manual': 'На этой версии Android добавь плитку вручную по инструкции ниже',
    'unavailable':
        'Системное добавление недоступно. Добавь плитку вручную по инструкции ниже',
  }.entries) {
    testWidgets(
      'tile UI truthfully reports ${entry.key} and always offers manual fallback',
      (tester) async {
        messenger.setMockMethodCallHandler(channel, (_) async => entry.key);
        final notices = <String>[];
        await showSettings(tester, notices);
        await tester.ensureVisible(find.byKey(button));
        await tester.tap(find.byKey(button));
        await tester.pumpAndSettle();
        expect(notices, [entry.value]);
        expect(find.text(entry.value), findsOneWidget);
        expect(find.textContaining('Вручную: раскрой шторку'), findsOneWidget);
        expect(
          tester.widget<FilledButton>(find.byKey(button)).onPressed,
          isNotNull,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'pending system dialog prevents double submission and late callback after disposal',
    (tester) async {
      final reply = Completer<String>();
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) {
        calls++;
        return reply.future;
      });
      final notices = <String>[];
      await showSettings(tester, notices);
      await tester.ensureVisible(find.byKey(button));
      await tester.tap(find.byKey(button));
      await tester.pump();
      expect(tester.widget<FilledButton>(find.byKey(button)).onPressed, isNull);
      await tester.tap(find.byKey(button));
      await tester.pump();
      expect(calls, 1);
      expect(find.text('Ожидаем Android…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      reply.complete('added');
      await tester.pump();
      expect(notices, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final code in ['busy', 'not_foreground', 'unavailable']) {
    testWidgets('native $code failure leaves retry available without success', (
      tester,
    ) async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: code,
          message: 'Native diagnostic detail',
        );
      });
      final notices = <String>[];
      await showSettings(tester, notices);
      await tester.ensureVisible(find.byKey(button));
      await tester.tap(find.byKey(button));
      await tester.pumpAndSettle();
      expect(notices, hasLength(1));
      expect(notices.single, isNot(contains('добавлена')));
      expect(notices.single, isNot(contains('Native diagnostic detail')));
      expect(
        tester.widget<FilledButton>(find.byKey(button)).onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
