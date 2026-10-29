import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/domain/control.dart';
import 'package:viora_client/domain/desktop_applications.dart';
import 'package:viora_client/domain/tunnel_config.dart';
import 'package:viora_client/features/client/client_page.dart';
import 'package:viora_client/features/client/desktop_application_picker.dart';
import 'package:viora_client/features/client/import_dialog.dart';
import 'package:viora_client/main.dart';
import 'package:viora_client/platform/desktop_tray.dart';
import 'package:viora_client/platform/native_bridge.dart';
import 'package:viora_client/platform/tunnel.dart';

// Presentation and method channels only. These fixtures never start pkexec,
// access the system keyring, resolve domains or create a VPN interface.
class _IdleEngine implements TunnelEngine {
  @override
  bool get supported => true;
  @override
  Stream<TunnelStats> get events => const Stream.empty();
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> start(TunnelConfig config, String name) async =>
      throw StateError('VPN startup is forbidden in the UI fixture');
  @override
  Future<void> stop() async {}
}

void main() {
  Future<void> mountShell(WidgetTester tester, {bool owner = false}) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = ClientState(tunnel: TunnelController(_IdleEngine()));
    addTearDown(state.tunnel.dispose);
    addTearDown(state.account.dispose);
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DesktopTray.channel, (call) async {
      expect(call.method, 'update');
      expect((call.arguments as Map)['running'], isFalse);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(DesktopTray.channel, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: VioraShell(
          repository: owner ? DevelopmentControl() : null,
          clientState: state,
          mode: ThemeMode.dark,
          onTheme: (_) {},
          onAccent: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Linux uses approved desktop navigation and import',
    (tester) async {
      await mountShell(tester);
      expect(find.byKey(const Key('approved-sidebar')), findsOneWidget);
      expect(find.text('Администрирование'), findsNothing);
      expect(find.text('VPN включён'), findsNothing);
      for (final page in [
        'Серверы',
        'Моя подписка',
        'Маршрутизация',
        'Приложения',
        'Внешний вид',
        'Настройки',
      ]) {
        await tester.tap(find.text(page).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: page);
      }
      await tester.tap(find.text('Импорт').first);
      await tester.pumpAndSettle();
      expect(find.byType(ImportDialog), findsOneWidget);
      expect(find.text('QR с камеры'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({TargetPlatform.linux}),
  );

  testWidgets(
    'Linux owner can leave administration through desktop import',
    (tester) async {
      await mountShell(tester, owner: true);
      await tester.tap(find.text('Администрирование'));
      await tester.pumpAndSettle();
      expect(find.text('Пользователи'), findsWidgets);
      expect(
        find.text('Демонстрационные данные · Без реальных подключений и оплат'),
        findsOneWidget,
      );
      await tester.tap(find.text('Импорт').first);
      await tester.pumpAndSettle();
      expect(find.byType(ImportDialog), findsOneWidget);
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      expect(find.byType(ClientPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({TargetPlatform.linux}),
  );

  testWidgets(
    'Linux program picker sorts selected paths first and imports clipboard',
    (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(NativeBridge.channel, (call) async {
        expect(call.method, 'applications');
        return [
          {'id': 'linux:/usr/bin/firefox', 'name': 'Firefox'},
          {'id': 'linux:/usr/bin/telegram-desktop', 'name': 'Telegram'},
        ];
      });
      var clipboard = DesktopApplications.encode({
        'linux:/usr/bin/firefox',
      }, 'linux');
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': clipboard};
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final selected = {'linux:/usr/bin/telegram-desktop'};
      var saves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DesktopApplicationPicker(
                selected: selected,
                onChanged: () => saves++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .map((tile) => (tile.title! as Text).data),
        ['Telegram', 'Firefox'],
      );
      await tester.tap(find.text('Импорт'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Добавить'));
      await tester.pumpAndSettle();
      expect(selected, {
        'linux:/usr/bin/firefox',
        'linux:/usr/bin/telegram-desktop',
      });
      expect(saves, 1);
      await tester.tap(find.text('Экспорт'));
      await tester.pumpAndSettle();
      expect(DesktopApplications.parse(clipboard, 'linux'), selected);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    // dart:io paths intentionally use the real platform. This case runs in the
    // Linux build VM, while the presentation cases above also run on Windows.
    skip: !Platform.isLinux,
    variant: TargetPlatformVariant({TargetPlatform.linux}),
  );
}
