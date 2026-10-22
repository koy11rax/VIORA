import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/main.dart';

void main() {
  testWidgets(
    'capture actual client with explicitly disconnected native fixture',
    (tester) async {
      // Screenshot-only fixture: no vault records, no profiles and no native
      // VPN invocation. DISCONNECTED exercises the genuine idle UI; never
      // supply CONNECTED or fake traffic for a presentation screenshot.
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('dev.viora/platform'), (
            call,
          ) async {
            calls.add(call.method);
            return switch (call.method) {
              'desktopTunnelPoll' => '{"state":"DISCONNECTED"}\n',
              'readProfiles' || 'readSession' => null,
              _ => throw MissingPluginException(
                'Not enabled by idle screenshot fixture',
              ),
            };
          });
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.runAsync(() async {
        final font = File('C:/Windows/Fonts/segoeui.ttf');
        if (await font.exists()) {
          final bytes = ByteData.sublistView(await font.readAsBytes());
          for (final family in ['Roboto', 'Ahem']) {
            await (FontLoader(family)..addFont(Future.value(bytes))).load();
          }
        }
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      for (final size in [
        const Size(1280, 900),
        const Size(390, 844),
        const Size(360, 800),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(const SizedBox.shrink());
        const captureKey = Key('updated-client-capture');
        await tester.pumpWidget(
          const RepaintBoundary(key: captureKey, child: VioraApp()),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$size');
        expect(find.text('Не подключено'), findsOneWidget);
        expect(find.text('VPN включён'), findsNothing);
        expect(find.text('Не удалось включить VPN'), findsNothing);
        await tester.runAsync(() async {
          await precacheImage(
            const AssetImage('assets/viora.png'),
            tester.element(find.byType(VioraShell)),
          );
        });
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(captureKey),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '../../artifacts/audit-2026-10-22/client-${size.width.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(calls, isNot(contains('desktopTunnelStart')));
      expect(calls, isNot(contains('desktopTunnelStop')));
    },
    skip: !const bool.fromEnvironment('VIORA_CAPTURE_UPDATED'),
  );
}
