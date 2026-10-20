import 'dart:io';
import 'package:flutter/services.dart';

class DesktopProtection {
  static Future<bool> change(String action) async {
    if (!{'enable', 'disable', 'status'}.contains(action)) {
      throw const FormatException('Неверная команда защиты');
    }
    String reply;
    if (Platform.isWindows) {
      reply =
          await const MethodChannel(
            'dev.viora/platform',
          ).invokeMethod<String>('desktopProtection', {'action': action}) ??
          'ERROR';
    } else if (Platform.isLinux) {
      final result = await Process.run(
        '/usr/bin/pkexec',
        ['/usr/lib/viora/viora_tunnel', '--protection', action],
        includeParentEnvironment: false,
        environment: {
          for (final key in [
            'DISPLAY',
            'WAYLAND_DISPLAY',
            'XAUTHORITY',
            'DBUS_SESSION_BUS_ADDRESS',
            'XDG_RUNTIME_DIR',
          ])
            if (Platform.environment[key] != null)
              key: Platform.environment[key]!,
        },
      );
      reply = result.exitCode == 0 ? (result.stdout as String).trim() : 'ERROR';
    } else {
      throw const FormatException('Эта настройка доступна на ПК');
    }
    return switch (reply.trim()) {
      'ON' => true,
      'OFF' => false,
      'BUSY' => throw const FormatException(
        'Сначала отключи VPN и дождись остановки',
      ),
      'UNAVAILABLE' => throw const FormatException(
        'Служба VIORA недоступна. Установи новую версию установщиком',
      ),
      _ => throw const FormatException(
        'Не удалось подтвердить системную защиту. Проверь разрешение администратора и установку VIORA',
      ),
    };
  }
}
