import 'package:flutter/services.dart';

class NativeBridge {
  static const channel = MethodChannel('dev.viora/platform');
  static Future<String> installationId() async {
    final id = await channel.invokeMethod<String>('installationId');
    if (id == null || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw StateError('Не удалось получить идентификатор установки');
    }
    return id;
  }

  static Future<void> openTelegram(Uri url) async {
    if (url.scheme != 'https' ||
        url.host != 't.me' ||
        url.userInfo.isNotEmpty ||
        url.port != 443) {
      throw ArgumentError('Недопустимая ссылка Telegram');
    }
    await channel.invokeMethod<void>('openTelegram', {'url': url.toString()});
  }

  static Future<void> saveSession(String value) =>
      channel.invokeMethod<void>('saveSession', {'value': value});
  static Future<String?> readSession() =>
      channel.invokeMethod<String>('readSession');
  static Future<void> clearSession() =>
      channel.invokeMethod<void>('clearSession');
  static Future<List<Map<String, dynamic>>> applications() async {
    final values = await channel.invokeListMethod<Map>('applications') ?? [];
    return values.map((e) => Map<String, dynamic>.from(e)).toList();
  }
}
