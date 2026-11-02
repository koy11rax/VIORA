import 'dart:convert';
import 'package:flutter/services.dart';
import '../domain/profile.dart';

class ProfileStorage {
  static const channel = MethodChannel('dev.viora/platform');
  Map<String, List<String>> subscriptions = {};
  Future<void> _pending = Future.value();
  String? _persistedValue;

  Future<(List<VlessProfile>, int)> load() {
    final read = _pending.then((_) => _load());
    _pending = read.then<void>((_) {}, onError: (Object _) {});
    return read;
  }

  Future<(List<VlessProfile>, int)> _load() async {
    // A read may observe a vault changed outside this instance. Never reuse
    // a remembered write after reading it, including a failed/migrated read.
    _persistedValue = null;
    final raw = await channel.invokeMethod<String>('readProfiles');
    if (raw == null) {
      subscriptions = {};
      return (<VlessProfile>[], -1);
    }
    if (raw.length > 1048576) throw const FormatException('Profiles too large');
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException {
      throw const FormatException('Profiles JSON');
    }
    if (data['version'] != 1 && data['version'] != 2) {
      throw const FormatException('Profiles version');
    }
    final values = data['profiles'] as List;
    if (values.length > 200) throw const FormatException('Too many profiles');
    final profiles = values
        .map((p) => _parseStoredProfile(p as String))
        .toList();
    final selected = data['selected'] as int;
    final sources = data['subscriptions'] as Map? ?? {};
    if (sources.length > 200) {
      throw const FormatException('Too many subscriptions');
    }
    final canonical = profiles.map((p) => p.toShareLink()).toList();
    final aliases = <String, String>{
      for (var i = 0; i < values.length; i++) values[i] as String: canonical[i],
    };
    subscriptions = _normalizeSources(sources, canonical.toSet(), aliases);
    return (
      profiles,
      selected >= 0 && selected < profiles.length ? selected : -1,
    );
  }

  /// URI spelling may change between serializers (e.g. hy2/hysteria2,
  /// VMess JSON or legacy false TLS flags). Recover ownership only when the
  /// fully validated canonical profile already exists. Never invent servers
  /// from metadata, match by endpoint alone, or relax protocol/TLS validation.
  static Map<String, List<String>> _normalizeSources(
    Map<dynamic, dynamic> sources,
    Set<String> canonical,
    Map<String, String> aliases,
  ) {
    if (sources.length > 200) {
      throw const FormatException('Too many subscriptions');
    }
    return sources.map((key, value) {
      final uri = Uri.parse(key as String);
      if (uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException('Subscription URL');
      }
      final links = (value as List).cast<String>();
      if (links.length > 200) {
        throw const FormatException('Subscription profiles');
      }
      final normalized = <String>[];
      for (final link in links) {
        final known = aliases.putIfAbsent(
          link,
          () => _parseStoredProfile(link).toShareLink(),
        );
        if (!canonical.contains(known)) {
          throw const FormatException('Subscription profiles');
        }
        normalized.add(known);
      }
      return MapEntry(key, normalized);
    });
  }

  static VlessProfile _parseStoredProfile(String link) {
    try {
      return VlessProfile.parse(link);
    } on ProfileFieldException catch (error) {
      if (error.issue != ProfileFieldIssue.displayName) rethrow;
      final uri = Uri.parse(link);
      // Pre-1.1 VLESS storage allowed controls/long display names. Repair only
      // that display metadata, then rerun every normal security validation.
      // Credentials, transport, server address and TLS settings stay intact.
      if (uri.scheme != 'vless') rethrow;
      final name = Uri.decodeComponent(
        uri.fragment,
      ).replaceAll(RegExp(r'[\x00-\x1f\x7f]+'), ' ').trim();
      final label = StringBuffer();
      var units = 0;
      for (final rune in name.runes) {
        final width = rune > 0xffff ? 2 : 1;
        if (units + width > 512) break;
        label.writeCharCode(rune);
        units += width;
      }
      return VlessProfile.parse(
        uri
            .replace(fragment: label.isEmpty ? 'Мой сервер' : label.toString())
            .toString(),
      );
    }
  }

  Future<void> save(
    List<VlessProfile> profiles,
    int selected, {
    Map<String, List<String>> sources = const {},
  }) {
    if (profiles.length > 200 || sources.length > 200) {
      throw const FormatException('Слишком много серверов');
    }
    final links = profiles.map((p) => p.toShareLink()).toList();
    final normalizedSources = _normalizeSources(sources, links.toSet(), {
      for (final link in links) link: link,
    });
    final value = jsonEncode({
      'version': 2,
      'subscriptions': normalizedSources,
      'profiles': links,
      'selected': selected,
    });
    if (profiles.length > 200 ||
        sources.length > 200 ||
        value.length > 1048576) {
      throw const FormatException('Слишком много серверов');
    }
    final write = _pending.then((_) async {
      // Compare at execution time: queued A -> B -> A must persist the final
      // A. Remember only acknowledged writes so an error remains retryable.
      if (_persistedValue == value) return;
      await channel.invokeMethod<void>('saveProfiles', {'value': value});
      _persistedValue = value;
    });
    _pending = write.catchError((Object _) {});
    return write;
  }
}
