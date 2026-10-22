import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/features/client/approved_content.dart';
import 'package:viora_client/features/client/client_page.dart';
import 'package:viora_client/platform/tunnel.dart';
import 'package:viora_client/ui/design.dart';

void main() {
  testWidgets('power follows connection and shutdown with reduced motion', (
    tester,
  ) async {
    var presses = 0;
    Widget power({
      bool active = false,
      bool connecting = false,
      bool stopping = false,
      bool reduced = false,
    }) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Scaffold(
          body: PowerOrbit(
            active: active,
            connecting: connecting,
            stopping: stopping,
            onPressed: () => presses++,
          ),
        ),
      ),
    );
    await tester.pumpWidget(power());
    await tester.tap(find.byTooltip('Подключить VPN'));
    expect(presses, 1);
    await tester.pumpWidget(power(connecting: true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.tap(find.byTooltip('Отменить подключение'));
    expect(presses, 2);
    await tester.pumpWidget(power(active: true));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Отключить VPN'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpWidget(power(stopping: true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.hasRunningAnimations, isTrue);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton && widget.tooltip == 'Отключаем VPN',
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(power(connecting: true, reduced: true));
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'home shows real errors and stats, server clicks use existing callback',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = ClientState();
      addTearDown(state.tunnel.dispose);
      addTearDown(state.account.dispose);
      state.profiles.add(
        VlessProfile.parse(
          'vless://11111111-1111-4111-8111-111111111111@example.org:443?security=tls&type=ws#Fixture',
        ),
      );
      state.selectedProfile = 0;
      var selected = -1;
      Widget page() => MaterialApp(
        home: Scaffold(
          body: ApprovedContent(
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
            onRefresh: () {},
            onPing: () {},
            onSelectServer: (value) => selected = value,
          ),
        ),
      );
      await tester.pumpWidget(page());
      expect(find.text('VPN включён'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('home-server-0')));
      expect(selected, 0);
      state.tunnel.phase = TunnelPhase.failed;
      state.tunnel.error = 'Fixture endpoint unavailable';
      await tester.pumpWidget(page());
      expect(find.byKey(const Key('home-tunnel-error')), findsOneWidget);
      expect(find.text('VPN включён'), findsNothing);
      state.tunnel.phase = TunnelPhase.active;
      state.tunnel.error = null;
      state.tunnel.stats = const TunnelStats(
        'CONNECTED',
        duration: '00:12:34',
        upload: 1048576,
        download: 2097152,
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.text('VPN включён'), findsOneWidget);
      expect(find.text('00:12:34'), findsOneWidget);
      expect(find.text('1.0 МБ'), findsOneWidget);
      expect(find.text('2.0 МБ'), findsOneWidget);
      state.tunnel.phase = TunnelPhase.stopping;
      await tester.pumpWidget(page());
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester
            .widget<FilledButton>(
              find.ancestor(
                of: find.text('Отключаем…'),
                matching: find.byWidgetPredicate(
                  (widget) => widget is FilledButton,
                ),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
