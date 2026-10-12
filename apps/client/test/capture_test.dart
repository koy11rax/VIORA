import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/domain/control.dart';
import 'package:viora_client/main.dart';

void main() {
  testWidgets(
    'capture Android-size group grant UI',
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
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });
      tester.view.physicalSize = const Size(390, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const capture = Key('capture');
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: VioraApp(repository: DevelopmentControl()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/viora.png'),
          tester.element(find.byType(VioraShell)),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> save(String name) async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('../../artifacts/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await save('android-home-preview-01');
      await tester.tap(find.text('Настройки').last);
      await tester.pumpAndSettle();
      await save('android-settings-preview-01');
      await tester.tap(find.byTooltip('Кабинет владельца'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Выдать дни группе'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Активные'));
      await tester.pumpAndSettle();
      await save('android-grant-selection');
      final reason = find.widgetWithText(TextField, 'Причина');
      await tester.scrollUntilVisible(
        reason,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(reason, 'Подарок активным пользователям');
      await tester.ensureVisible(find.text('Проверить получателей'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Проверить получателей'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Подтвердить выдачу').hitTestable(),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await save('android-grant-preview');
      expect(tester.takeException(), isNull);
    },
    skip: !const bool.fromEnvironment('VIORA_CAPTURE'),
  );
}
