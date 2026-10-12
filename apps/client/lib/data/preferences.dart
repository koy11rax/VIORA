import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

/// Only non-secret preferences. Never put server credentials or sessions here.
class DesktopPreferences {
  final File file;
  Future<void> _pending = Future.value();
  DesktopPreferences(this.file);
  Future<void> get settled => _pending;
  static Future<DesktopPreferences?> forPlatform() async {
    final env = Platform.environment;
    String? base;
    if (Platform.isAndroid) {
      base = await const MethodChannel(
        'dev.viora/platform',
      ).invokeMethod<String>('preferencesDirectory');
    }
    if (Platform.isWindows) base = env['LOCALAPPDATA'];
    if (Platform.isLinux) {
      base = env['XDG_CONFIG_HOME'];
      if (base == null && env['HOME'] != null) base = '${env['HOME']}/.config';
    }
    if (base == null || base.isEmpty || !Directory(base).isAbsolute) {
      return null;
    }
    return DesktopPreferences(File('$base/viora/preferences.json'));
  }

  Future<Map<String, dynamic>> load() async {
    if (!await file.exists()) return {};
    if (await file.length() > 262144) {
      throw const FormatException('Настройки слишком велики');
    }
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (data['version'] != 1) {
      throw const FormatException('Неизвестная версия настроек');
    }
    return data;
  }

  Future<void> save(Map<String, dynamic> data) {
    final encoded = jsonEncode({...data, 'version': 1});
    if (encoded.length > 262144) {
      return Future.error(StateError('Слишком много настроек'));
    }
    final operation = _pending.then((_) async {
      await file.parent.create(recursive: true);
      await file.writeAsString(encoded, flush: true);
    });
    // A failed write must not prevent subsequent retries.
    _pending = operation.then<void>((_) {}, onError: (Object e) {});
    return operation;
  }
}
