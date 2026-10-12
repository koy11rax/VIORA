import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/main.dart';
import 'package:viora_client/domain/control.dart';

void main() {
  testWidgets(
    'capture approved desktop screens',
    (tester) async {
      await tester.runAsync(() async {
        final font = FontLoader('Roboto')
          ..addFont(
            Future.value(
              ByteData.sublistView(
                await File('C:/Windows/Fonts/segoeui.ttf').readAsBytes(),
              ),
            ),
          );
        await font.load();
        await (FontLoader('Ahem')..addFont(
              Future.value(
                ByteData.sublistView(
                  await File('C:/Windows/Fonts/segoeui.ttf').readAsBytes(),
                ),
              ),
            ))
            .load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      tester.view.physicalSize = const Size(1280, 798);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const boundaryKey = Key('desktop-capture');
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: VioraApp(
            repository: DevelopmentControl(),
            preferences: {
              'rules': [
                {
                  'kind': 'domain',
                  'value': 'example.org',
                  'action': 'vpn',
                  'enabled': true,
                },
                {
                  'kind': 'subnet',
                  'value': '192.168.0.0/16',
                  'action': 'direct',
                  'enabled': true,
                },
                {
                  'kind': 'port',
                  'value': '8000-9000',
                  'action': 'block',
                  'enabled': false,
                },
              ],
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/viora.png'),
          tester.element(find.byType(VioraShell)),
        ),
      );
      Future<void> capture(String name) async {
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('../../artifacts/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        expect(tester.takeException(), isNull);
      }

      await capture('desktop-home-approved');
      for (final item in [
        ('Серверы', 'servers'),
        ('Моя подписка', 'subscription'),
        ('Маршрутизация', 'routing'),
        ('Настройки', 'settings'),
        ('Внешний вид', 'appearance'),
      ]) {
        await tester.tap(find.text(item.$1).first);
        await capture('desktop-${item.$2}-approved');
      }
      await tester.tap(find.text('Светлая'));
      await capture('desktop-appearance-light-approved');
      await tester.tap(find.text('Главная'));
      await capture('desktop-home-light-approved');
      await tester.tap(find.text('Администрирование'));
      await capture('desktop-admin-approved');
      await tester.tap(find.text('Настройки').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Соединение и защита'));
      await capture('desktop-network-approved');
    },
    skip: !const bool.fromEnvironment('VIORA_CAPTURE_DESKTOP'),
  );
}
