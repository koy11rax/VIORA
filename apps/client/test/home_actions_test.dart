import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/features/client/approved_content.dart';
import 'package:viora_client/features/client/client_page.dart';

void main() {
  testWidgets(
    'home exposes refresh and latency actions and disables busy actions',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = ClientState();
      addTearDown(state.tunnel.dispose);
      addTearDown(state.account.dispose);
      var refreshes = 0, pings = 0;
      Widget page({bool busy = false}) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ApprovedContent(
              index: 0,
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
              onNotice: (_) {},
              onRefresh: () {
                refreshes++;
              },
              onPing: () {
                pings++;
              },
              refreshing: busy,
              measuring: busy,
            ),
          ),
        ),
      );
      await tester.pumpWidget(page());
      await tester.tap(find.text('Обновить подписку'));
      await tester.tap(find.text('Проверить пинг'));
      expect(refreshes, 1);
      expect(pings, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(page(busy: true));
      for (final text in ['Обновляем…', 'Проверяем…']) {
        final button = tester.widget<OutlinedButton>(
          find.ancestor(
            of: find.text(text),
          matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
          ),
        );
        expect(button.onPressed, isNull);
      }
    },
  );
}
