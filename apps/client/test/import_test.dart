import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';
import 'package:viora_client/features/client/import_dialog.dart';
import 'package:viora_client/features/client/qr_import.dart';
import 'package:viora_client/main.dart';
import 'package:viora_client/data/subscription_import.dart';
import 'package:viora_client/domain/profile.dart';

const link =
    'vless://00000000-0000-4000-8000-000000000001@example.org:443?type=ws&security=tls&sni=example.org#Test';

Uint8List qrFixture(String text, {bool rotated = false}) {
  final matrix = Encoder.encode(text, ErrorCorrectionLevel.m).matrix!;
  final image = img.Image(
    width: (matrix.width + 8) * 5,
    height: (matrix.height + 8) * 5,
  );
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  for (var y = 0; y < matrix.height; y++) {
    for (var x = 0; x < matrix.width; x++) {
      if (matrix.get(x, y) == 1) {
        img.fillRect(
          image,
          x1: (x + 4) * 5,
          y1: (y + 4) * 5,
          x2: (x + 5) * 5 - 1,
          y2: (y + 5) * 5 - 1,
          color: img.ColorRgb8(0, 0, 0),
        );
      }
    }
  }
  return img.encodePng(rotated ? img.copyRotate(image, angle: 90) : image);
}

void main() {
  testWidgets('HTTPS subscription can retry a failure without Telegram login', (
    tester,
  ) async {
    var attempts = 0;
    ImportedConnection? imported;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('Импорт'),
              onPressed: () async {
                imported = await showDialog<ImportedConnection>(
                  context: context,
                  builder: (_) => ImportDialog(
                    loadSubscription: (source) async {
                      expect(source, 'https://example.invalid/sub/test');
                      if (++attempts == 1) {
                        throw const FormatException('Бот временно недоступен');
                      }
                      return ImportedConnection([
                        VlessProfile.parse(link),
                      ], source: source);
                    },
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Импорт'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://example.invalid/sub/test',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Загрузить подписку'));
    await tester.tap(find.text('Загрузить подписку'));
    await tester.pumpAndSettle();
    expect(find.text('Бот временно недоступен'), findsOneWidget);
    expect(imported, isNull);
    await tester.ensureVisible(find.text('Загрузить подписку'));
    await tester.tap(find.text('Загрузить подписку'));
    await tester.pumpAndSettle();
    expect(imported!.profiles.single.name, 'Test');
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });
  test('QR image decoder reads an actual generated and rotated QR', () {
    expect(decodeQrImage(qrFixture(link)), link);
    expect(decodeQrImage(qrFixture(link, rotated: true)), link);
    expect(
      () => decodeQrImage(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
    expect(
      () => decodeQrImage(img.encodePng(img.Image(width: 64, height: 64))),
      throwsFormatException,
    );
    expect(
      () => decodeQrImage(Uint8List(12 * 1024 * 1024 + 1)),
      throwsFormatException,
    );
  });

  testWidgets('import reads clipboard on request and validates before adding', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String clipboard = '';
    ImportedConnection? imported;
    var reads = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          reads++;
          return {'text': clipboard};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('Открыть импорт'),
              onPressed: () async {
                imported = await showDialog<ImportedConnection>(
                  context: context,
                  builder: (_) => const ImportDialog(),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть импорт'));
    await tester.pumpAndSettle();
    expect(reads, 0);
    expect(find.text('Сканировать QR-код'), findsOneWidget);
    expect(find.text('QR из изображения'), findsOneWidget);
    await tester.tap(find.text('Вставить из буфера'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Здесь пока нет ссылки'), findsOneWidget);
    clipboard = 'http://example.org';
    await tester.tap(find.text('Вставить из буфера'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.byWidgetPredicate((w) => w is FilledButton),
          )
          .onPressed,
      isNull,
    );
    clipboard = link;
    await tester.tap(find.text('Вставить из буфера'));
    await tester.pumpAndSettle();
    expect(find.text('Test'), findsOneWidget);
    await tester.ensureVisible(find.text('Добавить подключение'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Добавить подключение'));
    await tester.pumpAndSettle();
    expect(imported!.profiles.single.toShareLink(), link);
    expect(reads, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('app header retains its color after scrolling', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const VioraApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Настройки').last);
    await tester.pumpAndSettle();
    Color? color() => tester
        .widget<Material>(
          find
              .descendant(
                of: find.byType(AppBar),
                matching: find.byType(Material),
              )
              .first,
        )
        .color;
    final before = color();
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -450),
    );
    await tester.pumpAndSettle();
    expect(color(), before);
    expect(tester.takeException(), isNull);
  });
}
