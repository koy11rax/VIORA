import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/main.dart';
import 'package:viora_client/features/client/client_page.dart';
import 'package:viora_client/domain/profile.dart';

void main() {
  testWidgets(
    'capture own subscription grouping on a phone',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final bytes = ByteData.sublistView(
          await File('C:/Windows/Fonts/segoeui.ttf').readAsBytes(),
        );
        await (FontLoader('Roboto')..addFont(Future.value(bytes))).load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      await tester.pumpWidget(
        const RepaintBoundary(key: Key('capture-account'), child: VioraApp()),
      );
      await tester.pumpAndSettle();
      final state = tester.widget<ClientPage>(find.byType(ClientPage)).state;
      const link =
          'vless://00000000-0000-4000-8000-000000000001@example.invalid:443?type=ws&security=tls';
      state.profiles.addAll([
        VlessProfile.parse('$link#Пример · Основной'),
        VlessProfile.parse('$link#Пример · Личный'),
        VlessProfile.parse('$link#Пример · Резервный'),
      ]);
      state.subscriptions['https://vpnfn2345.duckdns.org/sub/example'] = [
        state.profiles[0].toShareLink(),
        state.profiles[2].toShareLink(),
      ];
      state.selectedProfile = 0;
      state.onChanged?.call();
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final home = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('capture-account')),
        );
        final image = await home.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '../../artifacts/android-home-0.3.1.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('Серверы').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('capture-account')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '../../artifacts/android-viora-servers-0.3.0.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    },
    skip: !const bool.fromEnvironment('VIORA_CAPTURE'),
  );
}
