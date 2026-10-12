import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/data/account_api.dart';
import 'package:viora_client/features/admin/admin_tools_page.dart';

class FixtureAdminApi extends AccountApi {
  int prepares = 0, commits = 0;
  @override
  Future<VioraAccount> account(String session) async => VioraAccount.fromJson({
    'id': 1,
    'first_name': 'Fixture owner',
    'owner': true,
    'devices': [],
  });
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? session,
    Map<String, dynamic>? body,
  }) async {
    if (path.endsWith('/prepare')) {
      prepares++;
      return {
        'id': 'fixture-preview',
        'title': 'Рассылка',
        'summary': ['2 получателя', body!['text']],
        'reason': body['reason'],
      };
    }
    if (path.endsWith('/commit')) {
      commits++;
      return {'id': 'fixture-preview'};
    }
    if (path.endsWith('/stats')) {
      return {
        'stats': {'total': 2, 'rub_today': 150, 'stars_today': 1},
      };
    }
    if (path.endsWith('/funnel')) {
      return {
        'funnel': {'start': 2, 'buy_menu': 1},
      };
    }
    return {'rows': [], 'more': false};
  }
}

void main() {
  testWidgets('all owner tools fit a phone without automatic mutations', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FixtureAdminApi();
    final account = AccountController(
      api: api,
      read: () async => null,
      write: (_) async {},
      clear: () async {},
    );
    addTearDown(account.dispose);
    await account.complete('s' * 43);
    for (final tool in adminTools) {
      await tester.pumpWidget(
        MaterialApp(
          home: AdminToolsPage(
            key: ValueKey(tool.$1),
            account: account,
            section: tool.$1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: tool.$1);
    }
    expect(api.prepares, 0);
    expect(api.commits, 0);
  });
  testWidgets(
    'broadcast preview can be cancelled and requires separate confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = FixtureAdminApi();
      final account = AccountController(
        api: api,
        read: () async => null,
        write: (_) async {},
        clear: () async {},
      );
      addTearDown(account.dispose);
      await account.complete('s' * 43);
      await tester.pumpWidget(
        MaterialApp(
          home: AdminToolsPage(account: account, section: 'broadcast'),
        ),
      );
      await tester.enterText(
        find.byType(TextField).first,
        'Fixture announcement',
      );
      await tester.enterText(find.byType(TextField).last, 'Fixture reason');
      await tester.ensureVisible(find.text('Предпросмотр рассылки'));
      await tester.tap(find.text('Предпросмотр рассылки'));
      await tester.pumpAndSettle();
      expect(api.prepares, 1);
      expect(api.commits, 0);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(api.commits, 0);
      await tester.tap(find.text('Предпросмотр рассылки'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отправить рассылку'));
      await tester.pumpAndSettle();
      expect(api.commits, 1);
      expect(find.text('Журнал операций'), findsOneWidget);
    },
  );
}
