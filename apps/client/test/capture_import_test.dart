import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/features/client/import_dialog.dart';
import 'package:viora_client/main.dart';

void main() {
  testWidgets(
    'capture mobile and desktop import',
    (tester) async {
      await tester.runAsync(() async {
        final data = ByteData.sublistView(
          await File('C:/Windows/Fonts/segoeui.ttf').readAsBytes(),
        );
        for (final name in ['Roboto', 'Segoe UI']) {
          await (FontLoader(name)..addFont(Future.value(data))).load();
        }
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = platform;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = platform == TargetPlatform.android
            ? const Size(390, 844)
            : const Size(1100, 800);
        await tester.pumpWidget(
          const RepaintBoundary(key: Key('capture'), child: VioraApp()),
        );
        await tester.pumpAndSettle();
        unawaited(
          showDialog<void>(
            context: tester.element(find.byType(VioraShell)),
            builder: (_) => const ImportDialog(),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Сканировать QR-код'),
          platform == TargetPlatform.android ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '../../artifacts/${platform.name}-import-preview.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      debugDefaultTargetPlatformOverride = null;
    },
    skip: !const bool.fromEnvironment('VIORA_CAPTURE'),
  );
}
