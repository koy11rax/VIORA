import 'package:flutter/services.dart';
import '../domain/profile.dart';

/// Opaque session IDs keep stale menus from selecting a replacement profile.
/// Only display names and local IDs cross the native tray channel.
class DesktopTray {
  static const channel = MethodChannel('dev.viora/tray');
  final _ids = Expando<int>();
  int _nextId = 0;
  Map<int, VlessProfile> _current = {};
  DateTime? _lastTick;
  int _uploaded = 0, _downloaded = 0;
  String _speed = '';

  static String _bytes(num value) {
    if (value >= 1073741824) {
      return '${(value / 1073741824).toStringAsFixed(1)} ГБ';
    }
    if (value >= 1048576) {
      return '${(value / 1048576).toStringAsFixed(1)} МБ';
    }
    if (value >= 1024) {
      return '${(value / 1024).toStringAsFixed(1)} КБ';
    }
    return '${value.toInt()} Б';
  }

  Map<String, Object> snapshot({
    required List<VlessProfile> profiles,
    required int selected,
    required bool running,
    required bool busy,
    required bool supported,
    required bool subscriptions,
    required String status,
    String duration = '00:00:00',
    int upload = 0,
    int download = 0,
  }) {
    final now = DateTime.now();
    if (running && _lastTick != null) {
      final milliseconds = now.difference(_lastTick!).inMilliseconds;
      if (milliseconds >= 500) {
        final up = upload >= _uploaded
            ? (upload - _uploaded) * 1000 / milliseconds
            : 0;
        final down = download >= _downloaded
            ? (download - _downloaded) * 1000 / milliseconds
            : 0;
        _speed = '↑ ${_bytes(up)}/с · ↓ ${_bytes(down)}/с';
        _lastTick = now;
        _uploaded = upload;
        _downloaded = download;
      }
    } else {
      _lastTick = running ? now : null;
      _uploaded = upload;
      _downloaded = download;
      _speed = '';
    }
    _current = {};
    final servers = <Map<String, Object>>[];
    for (var i = 0; i < profiles.length; i++) {
      final profile = profiles[i];
      final id = _ids[profile] ??= ++_nextId;
      _current[id] = profile;
      servers.add({'id': id, 'name': profile.name, 'selected': i == selected});
    }
    return {
      'servers': servers,
      'running': running,
      'busy': busy,
      'canConnect': supported && selected >= 0 && selected < profiles.length,
      'subscriptions': subscriptions,
      'status': status,
      'details': running
          ? '$duration · ↑ ${_bytes(upload)} · ↓ ${_bytes(download)}'
          : '',
      'speed': running ? _speed : '',
    };
  }

  int? serverIndex(Object? id, List<VlessProfile> profiles) {
    final profile = _current[id];
    if (profile == null) return null;
    final index = profiles.indexWhere((p) => identical(p, profile));
    return index < 0 ? null : index;
  }
}
