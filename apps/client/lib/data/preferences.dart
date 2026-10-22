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
    for (var attempt = 0; ; attempt++) {
      try {
        return await _loadSnapshot();
      } on FileSystemException catch (error) {
        // Windows may briefly deny an open during an atomic replacement.
        // Retry sharing/lock violations only, never mask corrupt data or ACLs.
        if (!Platform.isWindows ||
            ![32, 33].contains(error.osError?.errorCode) ||
            attempt >= 3) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  }

  Future<Map<String, dynamic>> _loadSnapshot() async {
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
    final encoded = utf8.encode(jsonEncode({...data, 'version': 1}));
    if (encoded.length > 262144) {
      return Future.error(StateError('Слишком много настроек'));
    }
    final operation = _pending.then((_) async {
      await file.parent.create(recursive: true);
      // Write beside the destination, then replace it on the same filesystem.
      // A failed or interrupted write must not truncate the last valid settings.
      final temporary = await file.parent.createTemp('.viora-write-');
      final candidate = File('${temporary.path}/preferences.json');
      try {
        await candidate.writeAsBytes(encoded, flush: true);
        for (var attempt = 0; ; attempt++) {
          try {
            await candidate.rename(file.path);
            break;
          } on FileSystemException catch (error) {
            if (!Platform.isWindows ||
                ![5, 32, 33].contains(error.osError?.errorCode) ||
                attempt >= 10) {
              rethrow;
            }
            // Readers and antivirus can retain the old Windows file handle
            // beyond 100 ms. Back off for at most 1.8 seconds in total; an
            // actual ACL failure still propagates with the prior file intact.
            final delay = (20 * (1 << attempt)).clamp(20, 250);
            await Future<void>.delayed(Duration(milliseconds: delay));
          }
        }
      } finally {
        if (await candidate.exists()) await candidate.delete();
        await temporary.delete();
      }
    });
    // A failed write must not prevent subsequent retries.
    _pending = operation.then<void>((_) {}, onError: (Object e) {});
    return operation;
  }
}
