import 'dart:convert';
import 'package:flutter/services.dart';
import '../domain/profile.dart';

class ProfileStorage {
  static const channel = MethodChannel('dev.viora/platform');
  Map<String, List<String>> subscriptions = {};
  Future<void> _pending = Future.value();
  Future<(List<VlessProfile>, int)> load() async {
    final raw = await channel.invokeMethod<String>('readProfiles');
    if (raw == null) return (<VlessProfile>[], -1);
    if (raw.length > 1048576) throw const FormatException('Profiles too large');
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if (data['version'] != 1 && data['version'] != 2) {
      throw const FormatException('Profiles version');
    }
    final values = data['profiles'] as List;
    if (values.length > 200) throw const FormatException('Too many profiles');
    final profiles = values
        .map((p) => VlessProfile.parse(p as String))
        .toList();
    final selected = data['selected'] as int;
    final sources = data['subscriptions'] as Map? ?? {};
    if (sources.length > 200) {
      throw const FormatException('Too many subscriptions');
    }
    subscriptions = sources.map((key, value) {
      final uri = Uri.parse(key as String);
      if (uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException('Subscription URL');
      }
      final links = (value as List).cast<String>();
      if (links.length > 200 || links.any((link) => !values.contains(link))) {
        throw const FormatException('Subscription profiles');
      }
      return MapEntry(key, links);
    });
    return (
      profiles,
      selected >= 0 && selected < profiles.length ? selected : -1,
    );
  }

  Future<void> save(
    List<VlessProfile> profiles,
    int selected, {
    Map<String, List<String>> sources = const {},
  }) {
    final value = jsonEncode({
      'version': 2,
      'subscriptions': sources,
      'profiles': profiles.map((p) => p.toShareLink()).toList(),
      'selected': selected,
    });
    if (profiles.length > 200 ||
        sources.length > 200 ||
        value.length > 1048576) {
      throw const FormatException('Слишком много серверов');
    }
    final write = _pending.then(
      (_) => channel.invokeMethod<void>('saveProfiles', {'value': value}),
    );
    _pending = write.catchError((Object _) {});
    return write;
  }
}
