import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/data/account_api.dart';
import 'package:viora_client/features/client/renewal_page.dart';

class FixtureRenewalApi extends AccountApi {
  int submits = 0;
  final orders = <Map<String, dynamic>>[];
  @override
  Future<VioraAccount> account(String session) async => VioraAccount.fromJson({
    'id': 2,
    'first_name': 'Fixture',
    'owner': false,
    'devices': [],
  });
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? session,
    Map<String, dynamic>? body,
  }) async {
    expect(session, 's' * 43);
    if (path.endsWith('/renewal')) {
      return {
        'tariffs': [
          {'id': 'fixture', 'name': 'Тестовый месяц', 'days': 30, 'rub': 100},
        ],
        'orders': orders,
        'requisites': {
          'phone': 'fixture-phone',
          'bank': 'fixture-bank',
          'name': 'fixture-name',
        },
      };
    }
    if (path.endsWith('/orders')) {
      expect(body!['tariff'], 'fixture');
      expect(body.containsKey('amount'), isFalse);
      orders.add({
        'id': 1,
        'tariff': 'fixture',
        'amount': 100,
        'status': 'pending',
        'submitted': 0,
      });
      return {'id': 1};
    }
    if (path.endsWith('/orders/submit')) {
      submits++;
      orders[0]['submitted'] = 1;
      return {'status': 'submitted'};
    }
    throw StateError('Unexpected fixture route');
  }
}

void main() {
  testWidgets(
    'renewal stays in app and submits only after explicit confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = FixtureRenewalApi();
      final account = AccountController(
        api: api,
        read: () async => null,
        write: (_) async {},
        clear: () async {},
      );
      addTearDown(account.dispose);
      await account.complete('s' * 43);
      await tester.pumpWidget(MaterialApp(home: RenewalPage(account: account)));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.currency_ruble), findsWidgets);
      await tester.tap(find.text('Тестовый месяц'));
      await tester.pumpAndSettle();
      expect(find.textContaining('fixture-phone'), findsOneWidget);
      expect(api.submits, 0);
      await tester.ensureVisible(find.text('Я оплатил'));
      await tester.tap(find.text('Я оплатил'));
      await tester.pumpAndSettle();
      expect(find.text('Перевод уже выполнен?'), findsOneWidget);
      expect(api.submits, 0);
      await tester.tap(find.text('Я оплатил').last);
      await tester.pumpAndSettle();
      expect(api.submits, 1);
      expect(
        find.textContaining('Заявка передана на проверку.'),
        findsOneWidget,
      );
    },
  );
}
