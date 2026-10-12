import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/data/account_api.dart';
import 'package:viora_client/features/client/account_page.dart';
import 'package:viora_client/features/client/approved_content.dart';
import 'package:viora_client/features/client/client_page.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/main.dart';

const ownLink =
    'vless://00000000-0000-4000-8000-000000000001@example.invalid:443?type=ws&security=tls#Own';
const foreignLink =
    'vless://00000000-0000-4000-8000-000000000002@example.invalid:443?type=ws&security=tls#Foreign';
Map<String, dynamic> challengeData() {
  final id = 'a' * 24;
  return {
    'id': id,
    'poll_secret': 'b' * 43,
    'code': '123456',
    'bot_url': 'https://t.me/ExampleVioraBot?start=viora_$id',
    'expires_at':
        DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/
        1000,
  };
}

class TestAccountApi extends AccountApi {
  bool owner = false;
  bool approved = false, revoked = false, offline = false;
  Completer<VioraAccount>? delayed;
  @override
  Future<LoginChallenge> start() async =>
      LoginChallenge.fromJson(challengeData());
  @override
  Future<String?> poll(LoginChallenge challenge) async =>
      approved ? 's' * 43 : null;
  @override
  Future<VioraAccount> account(String session) async {
    if (delayed != null) return delayed!.future;
    if (offline) throw const AccountError('Сеть недоступна');
    if (revoked) throw const AccountError('Сеанс истёк', 401);
    return VioraAccount.fromJson({
      'id': 88,
      'first_name': 'Test User',
      'owner': owner,
      'devices': [],
    });
  }

  @override
  Future<void> cancel(LoginChallenge challenge) async {}
  @override
  Future<void> logout(String session) async {
    revoked = true;
  }
}

void main() {
  testWidgets(
    'admin tab appears after verified owner restore and disappears on demotion',
    (tester) async {
      tester.view.physicalSize = const Size(700, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = TestAccountApi();
      final controller = AccountController(
        api: api,
        read: () async => null,
        write: (_) async {},
        clear: () async {},
      );
      final state = ClientState(account: controller);
      addTearDown(state.tunnel.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: VioraShell(
            repository: null,
            clientState: state,
            mode: ThemeMode.dark,
            onTheme: (_) {},
            onAccent: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Админ'), findsNothing);
      await controller.complete('s' * 43);
      await tester.pumpAndSettle();
      expect(find.text('Админ'), findsNothing);
      api.owner = true;
      await controller.restore();
      await tester.pumpAndSettle();
      expect(find.text('Админ'), findsOneWidget);
      api.owner = false;
      await controller.restore();
      await tester.pumpAndSettle();
      expect(find.text('Админ'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'server owner role supplies a session repository and logout removes it',
    () async {
      final api = TestAccountApi()..owner = true;
      final account = AccountController(
        api: api,
        read: () async => null,
        write: (_) async {},
        clear: () async {},
      );
      addTearDown(account.dispose);
      expect(account.controlRepository, isNull);
      await account.complete('s' * 43);
      expect(account.controlRepository, isNotNull);
      expect(account.controlRepository!.prefix, '/v1/app');
      api.owner = false;
      await account.restore();
      expect(account.controlRepository, isNull);
      api.owner = true;
      await account.restore();
      await account.logout();
      expect(account.controlRepository, isNull);
    },
  );
  test(
    'login URL cannot redirect to another service or include a poll secret',
    () {
      final data = challengeData();
      final c = LoginChallenge.fromJson(data);
      expect(c.botUrl.toString(), isNot(contains(c.secret)));
      expect(c.toString(), isNot(contains(c.secret)));
      for (final url in [
        'https://t.me.evil.invalid/ExampleVioraBot?start=viora_${c.id}',
        'https://t.me/ExampleVioraBot?start=wrong',
        'https://t.me/ExampleVioraBot?start=viora_${c.id}&start=other',
        'http://t.me/ExampleVioraBot?start=viora_${c.id}',
      ]) {
        expect(
          () => LoginChallenge.fromJson({...data, 'bot_url': url}),
          throwsA(isA<AccountError>()),
        );
      }
    },
  );
  test(
    'sessions persist only through protected storage and expire on server rejection',
    () async {
      String? vault;
      final api = TestAccountApi();
      final controller = AccountController(
        api: api,
        read: () async => vault,
        write: (value) async {
          vault = value;
        },
        clear: () async {
          vault = null;
        },
      );
      addTearDown(controller.dispose);
      await controller.complete('s' * 43);
      expect(vault, 's' * 43);
      expect(controller.value!.owner, isFalse);
      api.offline = true;
      await expectLater(controller.restore(), throwsA(isA<AccountError>()));
      expect(vault, isNotNull);
      api.offline = false;
      api.revoked = true;
      await expectLater(controller.restore(), throwsA(isA<AccountError>()));
      expect(vault, isNull);
      expect(controller.value, isNull);
    },
  );
  test(
    'late account response cannot restore an account after logout',
    () async {
      String? vault;
      final api = TestAccountApi();
      final controller = AccountController(
        api: api,
        read: () async => vault,
        write: (value) async {
          vault = value;
        },
        clear: () async {
          vault = null;
        },
      );
      addTearDown(controller.dispose);
      await controller.complete('s' * 43);
      final old = controller.value!;
      api.delayed = Completer<VioraAccount>();
      final pending = controller.restore();
      await controller.logout();
      api.delayed!.complete(old);
      await pending;
      expect(controller.value, isNull);
      expect(controller.hasSession, isFalse);
      expect(vault, isNull);
    },
  );
  testWidgets(
    'own subscription stays in Viora section with original server selection',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = ClientState();
      addTearDown(state.tunnel.dispose);
      addTearDown(state.account.dispose);
      state.profiles.addAll([
        VlessProfile.parse(foreignLink),
        VlessProfile.parse(ownLink),
      ]);
      state.subscriptions['https://vpnfn2345.duckdns.org/sub/example'] = [
        state.profiles[1].toShareLink(),
      ];
      state.subscriptions['https://provider.invalid/sub/example'] = [
        state.profiles[0].toShareLink(),
      ];
      expect(state.vioraProfileIndices, [1]);
      expect(state.otherProfileIndices, [0]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ApprovedContent(
                index: 1,
                state: state,
                mode: ThemeMode.dark,
                demo: false,
                onTheme: (_) {},
                onAccent: (_) {},
                onNavigate: (_) {},
                onImport: () {},
                onLogin: () {},
                onConnect: () {},
                onChanged: () {},
                onRefresh: () {},
                onNotice: (_) {},
              ),
            ),
          ),
        ),
      );
      final ownY = tester.getTopLeft(find.text('Own')).dy;
      final dividerY = tester.getTopLeft(find.text('Другие серверы')).dy;
      final foreignY = tester.getTopLeft(find.text('Foreign')).dy;
      expect(ownY, lessThan(dividerY));
      expect(foreignY, greaterThan(dividerY));
      await tester.tap(find.text('Own'));
      expect(state.selectedProfile, 1);
      await tester.tap(find.text('Foreign'));
      expect(state.selectedProfile, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'account page needs explicit bot confirmation before storing a session',
    (tester) async {
      final api = TestAccountApi();
      String? session;
      final controller = AccountController(
        api: api,
        read: () async => session,
        write: (value) async {
          session = value;
        },
        clear: () async {
          session = null;
        },
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: AccountPage(
            account: controller,
            importSubscription: (_) async {},
          ),
        ),
      );
      await tester.tap(find.text('Связать Telegram'));
      await tester.pumpAndSettle();
      expect(find.text('123456'), findsOneWidget);
      await tester.ensureVisible(find.text('Проверить подтверждение'));
      await tester.tap(find.text('Проверить подтверждение'));
      await tester.pumpAndSettle();
      expect(session, isNull);
      expect(
        find.textContaining('Подтверждение ещё не получено'),
        findsOneWidget,
      );
      api.approved = true;
      await tester.tap(find.text('Проверить подтверждение'));
      await tester.pumpAndSettle();
      expect(find.text('Test User'), findsOneWidget);
      expect(session, isNotNull);
      await tester.scrollUntilVisible(
        find.text('Выйти из аккаунта'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Выйти из аккаунта'));
      await tester.pumpAndSettle();
      expect(session, isNull);
      expect(api.revoked, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
