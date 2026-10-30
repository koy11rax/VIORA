import 'dart:convert';

/// The historical name is retained for existing encrypted stores and callers.
class VlessProfile {
  final String protocol, name, host, uuid, transport, security;
  final int port;
  final Map<String, String> parameters;
  VlessProfile._(
    this.protocol,
    this.name,
    this.host,
    this.port,
    this.uuid,
    this.transport,
    this.security,
    Map<String, String> parameters,
  ) : parameters = Map.unmodifiable(parameters);

  static const protocols = {
    'vless',
    'vmess',
    'trojan',
    'shadowsocks',
    'hysteria2',
  };
  static const shadowsocksMethods = {
    'aes-128-gcm',
    'aes-256-gcm',
    'chacha20-ietf-poly1305',
  };
  String get password => uuid;
  String? get method => parameters['method'];
  String get displayLabel {
    final label = switch (protocol) {
      'vmess' => 'VMess',
      'trojan' => 'Trojan',
      'shadowsocks' => 'Shadowsocks',
      'hysteria2' => 'Hysteria2',
      _ => 'VLESS',
    };
    final network = transport == 'udp' ? 'QUIC' : transport.toUpperCase();
    return '$label · $network${security == 'none' ? '' : ' · ${security.toUpperCase()}'}';
  }

  factory VlessProfile.parse(String input) {
    if (input.length > 16384) {
      throw const FormatException('Ссылка слишком длинная');
    }
    try {
      final value = input.trim();
      if (value.startsWith('vmess://')) return _parseVmess(value);
      if (value.startsWith('ss://')) return _parseShadowsocks(value);
      final uri = Uri.parse(value);
      final protocol = switch (uri.scheme) {
        'hy2' || 'hysteria2' => 'hysteria2',
        'vless' || 'trojan' => uri.scheme,
        _ => throw const FormatException(
          'Поддерживаются VLESS, VMess, Trojan, Shadowsocks и Hysteria2',
        ),
      };
      if (uri.queryParametersAll.values.any((values) => values.length != 1)) {
        throw const FormatException('В ссылке повторяются параметры');
      }
      if (uri.path.isNotEmpty && uri.path != '/') {
        throw const FormatException('Неподдерживаемый путь в ссылке сервера');
      }
      return VlessProfile.fromFields(
        protocol: protocol,
        name: uri.fragment.isEmpty
            ? 'Мой сервер'
            : Uri.decodeComponent(uri.fragment),
        host: uri.host,
        port: uri.hasPort ? uri.port : (protocol == 'vless' ? 0 : 443),
        credential: Uri.decodeComponent(uri.userInfo),
        parameters: uri.queryParameters,
      );
    } on FormatException catch (error) {
      // Parser exceptions can include the whole credential-bearing input.
      if (error.source != null) {
        throw const FormatException('Некорректный формат ссылки сервера');
      }
      rethrow;
    } catch (_) {
      throw const FormatException('Некорректный формат ссылки сервера');
    }
  }

  factory VlessProfile.fromFields({
    required String protocol,
    required String name,
    required String host,
    required int port,
    required String credential,
    Map<String, String> parameters = const {},
  }) {
    if (!protocols.contains(protocol)) {
      throw const FormatException('Этот протокол пока не поддерживается');
    }
    if (host.isEmpty ||
        host.length > 253 ||
        RegExp(r'[\s/\\@?#\x00-\x1f\x7f]').hasMatch(host) ||
        port < 1 ||
        port > 65535) {
      throw const FormatException('Проверь адрес и порт сервера');
    }
    if (credential.isEmpty ||
        credential.length > 2048 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(credential) ||
        name.length > 512 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const FormatException('Некорректные данные профиля');
    }
    if (parameters.length > 24 ||
        parameters.entries.any(
          (entry) =>
              entry.key.length > 64 ||
              entry.value.length > 4096 ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(entry.value),
        )) {
      throw const FormatException('Некорректные параметры профиля');
    }
    final p = Map<String, String>.from(parameters);
    for (final key in ['insecure', 'allowInsecure', 'skip-cert-verify']) {
      final value = p.remove(key);
      if (value != null && value != '0' && value.toLowerCase() != 'false') {
        throw const FormatException(
          'Профиль отключает проверку сертификата TLS. Получи безопасную ссылку у провайдера.',
        );
      }
    }
    String type;
    String security;
    if (protocol == 'hysteria2') {
      _allowed(p, {'sni', 'alpn', 'obfs', 'obfs-password'});
      final obfs = p['obfs'] ?? '';
      if ((obfs.isNotEmpty && obfs != 'salamander') ||
          (obfs == 'salamander' && (p['obfs-password'] ?? '').isEmpty) ||
          (obfs.isEmpty && (p['obfs-password'] ?? '').isNotEmpty)) {
        throw const FormatException(
          'Поддерживается Hysteria2 с обфускацией Salamander или без неё',
        );
      }
      if (p.containsKey('alpn') && p['alpn'] != 'h3') {
        throw const FormatException('Для Hysteria2 поддерживается ALPN h3');
      }
      type = 'udp';
      security = 'tls';
    } else if (protocol == 'shadowsocks') {
      _allowed(p, {'method'});
      if (!shadowsocksMethods.contains(p['method'])) {
        throw const FormatException(
          'Поддерживаются AEAD-методы Shadowsocks AES-GCM и ChaCha20-Poly1305; плагины пока не поддерживаются',
        );
      }
      type = 'tcp';
      security = 'none';
    } else {
      _allowed(p, {
        'type',
        'security',
        'encryption',
        'sni',
        'fp',
        'pbk',
        'sid',
        'flow',
        'path',
        'host',
        'mode',
        'alpn',
        'spx',
      });
      type = p['type'] ?? 'tcp';
      security =
          p['security'] ??
          (protocol == 'trojan'
              ? 'tls'
              : protocol == 'vmess'
              ? 'none'
              : '');
      if (!['tcp', 'ws', if (protocol == 'vless') 'xhttp'].contains(type)) {
        throw const FormatException(
          'Этот транспорт пока не поддерживается. Используй TCP или WebSocket.',
        );
      }
      if (protocol == 'vless' || protocol == 'vmess') {
        if (!RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(credential)) {
          throw const FormatException('Некорректный UUID сервера');
        }
      }
      if (protocol == 'vless') {
        if (!['tls', 'reality'].contains(security) ||
            (p['encryption'] ?? 'none') != 'none') {
          throw const FormatException('Для VLESS требуется TLS или REALITY');
        }
        if (security == 'reality' &&
            (type != 'tcp' ||
                (p['pbk'] ?? '').isEmpty ||
                (p['sni'] ?? '').isEmpty ||
                (p['flow'] ?? '') != 'xtls-rprx-vision')) {
          throw const FormatException('Нужны параметры TCP REALITY Vision');
        }
        if (security == 'tls' && (p['flow'] ?? '').isNotEmpty) {
          throw const FormatException(
            'Этот режим VLESS Flow пока не поддерживается',
          );
        }
      } else if (protocol == 'trojan') {
        if (security != 'tls') {
          throw const FormatException('Для Trojan требуется проверяемый TLS');
        }
      } else if (!['tls', 'none'].contains(security) ||
          ![
            'auto',
            'aes-128-gcm',
            'chacha20-poly1305',
          ].contains(p['encryption'] ?? 'auto')) {
        throw const FormatException(
          'Поддерживается только VMess AEAD с TCP или WebSocket',
        );
      }
      if (protocol != 'vless' &&
          ['pbk', 'sid', 'flow', 'spx', 'mode'].any(p.containsKey)) {
        throw const FormatException('Параметры не соответствуют протоколу');
      }
      if (type == 'xhttp' &&
          ![
            'auto',
            'packet-up',
            'stream-up',
            'stream-one',
          ].contains(p['mode'] ?? 'auto')) {
        throw const FormatException('Неподдерживаемый режим XHTTP');
      }
    }
    for (final key in ['sni', 'host']) {
      final value = p[key];
      if (value != null &&
          (value.length > 253 || RegExp(r'[\s/\\@?#]').hasMatch(value))) {
        throw const FormatException('Некорректное имя TLS или WebSocket');
      }
    }
    if ((p['path'] ?? '/').isNotEmpty && !(p['path'] ?? '/').startsWith('/')) {
      throw const FormatException('Путь транспорта должен начинаться с /');
    }
    if (p.containsKey('alpn') &&
        (p['alpn']!.isEmpty ||
            p['alpn']!
                .split(',')
                .any(
                  (value) =>
                      !RegExp(r'^[A-Za-z0-9./_-]{1,32}$').hasMatch(value),
                ))) {
      throw const FormatException('Некорректный ALPN');
    }
    return VlessProfile._(
      protocol,
      name.isEmpty ? 'Мой сервер' : name,
      host,
      port,
      credential,
      type,
      security,
      p,
    );
  }

  static void _allowed(Map<String, String> values, Set<String> allowed) {
    if (values.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('В профиле есть неподдерживаемые параметры');
    }
  }

  static VlessProfile _parseShadowsocks(String value) {
    var uri = Uri.parse(value);
    String? legacyInfo;
    if (!uri.hasAuthority || uri.userInfo.isEmpty) {
      final payload = value.substring(5).split('#').first;
      final decoded = utf8.decode(base64.decode(base64.normalize(payload)));
      final separator = decoded.lastIndexOf('@');
      if (separator < 1) {
        throw const FormatException('Некорректные данные Shadowsocks');
      }
      legacyInfo = decoded.substring(0, separator);
      final fragment = value.contains('#')
          ? value.substring(value.indexOf('#'))
          : '';
      uri = Uri.parse('ss://${decoded.substring(separator + 1)}$fragment');
    }
    if (uri.queryParameters.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException('Плагины Shadowsocks пока не поддерживаются');
    }
    var info = legacyInfo ?? Uri.decodeComponent(uri.userInfo);
    if (!info.contains(':')) {
      info = utf8.decode(base64.decode(base64.normalize(info)));
    }
    final colon = info.indexOf(':');
    if (colon < 1) {
      throw const FormatException('Некорректные данные Shadowsocks');
    }
    return VlessProfile.fromFields(
      protocol: 'shadowsocks',
      name: uri.fragment.isEmpty
          ? 'Мой сервер'
          : Uri.decodeComponent(uri.fragment),
      host: uri.host,
      port: uri.hasPort ? uri.port : 0,
      credential: info.substring(colon + 1),
      parameters: {'method': info.substring(0, colon)},
    );
  }

  static VlessProfile _parseVmess(String value) {
    final decoded = jsonDecode(
      utf8.decode(base64.decode(base64.normalize(value.substring(8)))),
    );
    if (decoded is! Map<String, dynamic> || decoded.length > 30) {
      throw const FormatException('Некорректный профиль VMess');
    }
    const allowed = {
      'v',
      'ps',
      'add',
      'port',
      'id',
      'aid',
      'scy',
      'net',
      'type',
      'host',
      'path',
      'tls',
      'sni',
      'alpn',
      'fp',
      'allowInsecure',
      'insecure',
    };
    if (decoded.keys.any((key) => !allowed.contains(key)) ||
        !['0', ''].contains('${decoded['aid'] ?? 0}') ||
        !['none', ''].contains('${decoded['type'] ?? ''}')) {
      throw const FormatException(
        'Поддерживается только VMess AEAD без дополнительной маскировки',
      );
    }
    String string(String key, [String fallback = '']) {
      final value = decoded[key];
      if (value == null) return fallback;
      if (value is bool && (key == 'allowInsecure' || key == 'insecure')) {
        return '$value';
      }
      if (value is! String && value is! int) {
        throw const FormatException('Некорректные поля VMess');
      }
      return '$value';
    }

    return VlessProfile.fromFields(
      protocol: 'vmess',
      name: string('ps', 'Мой сервер'),
      host: string('add'),
      port: int.tryParse(string('port')) ?? 0,
      credential: string('id'),
      parameters: {
        'type': string('net', 'tcp'),
        'security': string('tls').isEmpty ? 'none' : string('tls'),
        'encryption': string('scy', 'auto'),
        for (final key in [
          'host',
          'path',
          'sni',
          'alpn',
          'fp',
          'allowInsecure',
          'insecure',
        ])
          if (decoded.containsKey(key) && string(key).isNotEmpty)
            key: string(key),
      },
    );
  }

  @override
  String toString() =>
      'VlessProfile($protocol, $transport, $security, credentials:redacted)';

  /// Secret material: only use for encrypted storage, never for diagnostics.
  String toShareLink() {
    if (protocol == 'vmess') {
      return 'vmess://${base64.encode(utf8.encode(jsonEncode({
        'v': '2',
        'ps': name,
        'add': host,
        'port': '$port',
        'id': uuid,
        'aid': '0',
        'net': transport,
        'type': 'none',
        'tls': security == 'none' ? '' : security,
        'scy': parameters['encryption'] ?? 'auto',
        for (final key in ['host', 'path', 'sni', 'alpn', 'fp'])
          if (parameters.containsKey(key)) key: parameters[key],
      })))}';
    }
    return Uri(
      scheme: protocol == 'shadowsocks' ? 'ss' : protocol,
      userInfo: protocol == 'shadowsocks'
          ? base64Url
                .encode(utf8.encode('${method!}:$password'))
                .replaceAll('=', '')
          : Uri.encodeComponent(uuid),
      host: host,
      port: port,
      queryParameters: protocol == 'shadowsocks' || parameters.isEmpty
          ? null
          : parameters,
      fragment: name,
    ).toString();
  }
}
