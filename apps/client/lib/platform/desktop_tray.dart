import 'package:flutter/services.dart';
import '../domain/profile.dart';

/// Opaque session IDs keep stale menus from selecting a replacement profile.
/// Only display names and local IDs cross the native tray channel.
class DesktopTray {
  static const channel = MethodChannel('dev.viora/tray');
  final _ids = Expando<int>();
  int _nextId = 0;
  Map<int, VlessProfile> _current = {};

  Map<String, Object> snapshot({
    required List<VlessProfile> profiles,
    required int selected,
    required bool running,
    required bool busy,
    required bool supported,
    required bool subscriptions,
    required String status,
  }) {
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
    };
  }

  int? serverIndex(Object? id, List<VlessProfile> profiles) {
    final profile = _current[id];
    if (profile == null) return null;
    final index = profiles.indexWhere((p) => identical(p, profile));
    return index < 0 ? null : index;
  }
}
