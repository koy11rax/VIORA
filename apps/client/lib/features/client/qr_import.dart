import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// Runs locally, in a worker isolate. Never sends the image or link anywhere.
String decodeQrImage(Uint8List bytes) {
  if (bytes.length > 12 * 1024 * 1024) {
    throw const FormatException('Выбери изображение меньше 12 МБ.');
  }
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null || info.width * info.height > 16000000) {
    throw const FormatException('Не удалось открыть изображение.');
  }
  final decoded = decoder!.decodeFrame(0);
  if (decoded == null) throw const FormatException('Изображение повреждено.');
  var image = img.bakeOrientation(decoded);
  if (image.width > 2000 || image.height > 2000) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? 2000 : null,
      height: image.height > image.width ? 2000 : null,
    );
  }
  for (var turn = 0; turn < 4; turn++) {
    final pixels = image
        .convert(numChannels: 4)
        .getBytes(order: img.ChannelOrder.abgr);
    final source = RGBLuminanceSource(
      image.width,
      image.height,
      pixels.buffer.asInt32List(
        pixels.offsetInBytes,
        pixels.lengthInBytes ~/ 4,
      ),
    );
    try {
      return QRCodeReader().decode(BinaryBitmap(HybridBinarizer(source))).text;
    } on ReaderException {
      image = img.copyRotate(image, angle: 90);
    }
  }
  throw const FormatException(
    'QR-код не найден. Выбери более чёткое изображение.',
  );
}
