import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/features/client/approved_content.dart';
import 'package:viora_client/features/client/client_page.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/platform/tunnel.dart';

void main() {
  testWidgets('home and servers hide cached TCP timings while VPN intercepts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = ClientState();
    addTearDown(state.tunnel.dispose);
    addTearDown(state.account.dispose);
    final profile = VlessProfile.parse(
      'vless://00000000-0000-4000-8000-000000000001@sample.example.invalid:443?type=ws&security=tls#Sample',
    );
    state.profiles.add(profile);
    state.selectedProfile = 0;
    state.latency[profile.toShareLink()] = 71;
    Widget page(int index) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ApprovedContent(
            index: index,
            state: state,
            mode: ThemeMode.dark,
            demo: false,
            onTheme: (_) {},
            onAccent: (_) {},
            onNavigate: (_) {},
            onImport: () {},
            onLogin: () {},
            onConnect: () {},
            onRefresh: () {},
            onChanged: () {},
            onNotice: (_) {},
          ),
        ),
      ),
    );
    for (final index in [0, 1]) {
      state.tunnel.phase = TunnelPhase.disconnected;
      await tester.pumpWidget(page(index));
      expect(find.text('TCP · 71 мс'), findsWidgets);
      for (final phase in [
        TunnelPhase.active,
        TunnelPhase.connecting,
        TunnelPhase.permission,
        TunnelPhase.stopping,
      ]) {
        state.tunnel.phase = phase;
        await tester.pumpWidget(page(index));
        expect(find.textContaining('71 мс'), findsNothing);
        expect(state.tcpConnectTime(profile), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
            matching: find.byWidgetPredicate(
              (widget) => widget is OutlinedButton,
            ),
          ),
        );
        expect(button.onPressed, isNull);
      }
    },
  );
}
