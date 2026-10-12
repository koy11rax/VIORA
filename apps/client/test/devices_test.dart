import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/data/account_api.dart';
import 'package:viora_client/features/client/devices_page.dart';

class DeviceFixtureApi extends AccountApi {
  int revokes = 0;
  @override
  Future<VioraAccount> account(String session) async =>
      VioraAccount.fromJson({'id': 2, 'first_name': 'Fixture', 'devices': []});
  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? session,
    Map<String, dynamic>? body,
  }) async {
    expect(session, 's' * 43);
    if (path.endsWith('/revoke')) {
      expect(body, {'id': 22});
      revokes++;
      return {'devices': [], 'limit': 3, 'access_sync': 'pending'};
    }
    expect(path, '/v1/app/devices');
    return {
      'limit': 3,
      'devices': [
        {
          'id': 22,
          'name': 'Fixture Android',
          'platform': 'Android',
          'last_seen': '2026-01-01T12:00:00',
        },
      ],
    };
  }
}

void main() {
  testWidgets(
    'device revocation requires explicit confirmation and refreshes slots',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = DeviceFixtureApi();
      final account = AccountController(
        api: api,
        read: () async => null,
        write: (_) async {},
        clear: () async {},
      );
      addTearDown(account.dispose);
      await account.complete('s' * 43);
      await tester.pumpWidget(MaterialApp(home: DevicesPage(account: account)));
      await tester.pumpAndSettle();
      expect(find.text('Занято 1 из 3'), findsOneWidget);
      await tester.tap(find.text('Отвязать устройство'));
      await tester.pumpAndSettle();
      expect(api.revokes, 0);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(api.revokes, 0);
      await tester.tap(find.text('Отвязать устройство'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отвязать'));
      await tester.pumpAndSettle();
      expect(api.revokes, 1);
      expect(find.text('Занято 0 из 3'), findsOneWidget);
      expect(find.textContaining('в течение минуты'), findsOneWidget);
    },
  );
}
