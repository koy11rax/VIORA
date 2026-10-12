class VlessProfile {
  final String name, host, uuid, transport, security;
  final int port;
  final Map<String, String> parameters;
  VlessProfile._(
    this.name,
    this.host,
    this.port,
    this.uuid,
    this.transport,
    this.security,
    this.parameters,
  );
  factory VlessProfile.parse(String input) {
    if (input.length > 16384) {
      throw const FormatException('Ссылка слишком длинная');
    }
    final uri = Uri.parse(input.trim());
    if (uri.scheme != 'vless' ||
        uri.host.isEmpty ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw const FormatException('Нужна ссылка VLESS с адресом и портом');
    }
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(uri.userInfo)) {
      throw const FormatException('Некорректный идентификатор VLESS');
    }
    const allowed = {
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
    };
    if (uri.queryParameters.keys.any((key) => !allowed.contains(key)) ||
        uri.queryParametersAll.values.any((values) => values.length != 1)) {
      throw const FormatException(
        'Есть неподдерживаемые или повторяющиеся параметры',
      );
    }
    final p = uri.queryParameters,
        type = p['type'] ?? 'tcp',
        security = p['security'] ?? '';
    if (!['tcp', 'ws', 'xhttp'].contains(type) ||
        !['tls', 'reality'].contains(security) ||
        (p['encryption'] ?? 'none') != 'none') {
      throw const FormatException('Поддерживаются WS/XHTTP TLS и TCP REALITY');
    }
    if (security == 'reality' &&
        (type != 'tcp' ||
            (p['pbk'] ?? '').isEmpty ||
            (p['sni'] ?? '').isEmpty ||
            (p['flow'] ?? '') != 'xtls-rprx-vision')) {
      throw const FormatException('Нужны параметры TCP REALITY Vision');
    }
    if (security == 'tls' && type == 'tcp') {
      throw const FormatException(
        'Этот TCP TLS профиль пока не поддерживается',
      );
    }
    return VlessProfile._(
      uri.fragment.isEmpty ? 'Мой сервер' : Uri.decodeComponent(uri.fragment),
      uri.host,
      uri.port,
      uri.userInfo,
      type,
      security,
      Map.unmodifiable(p),
    );
  }
  @override
  String toString() =>
      'VlessProfile($transport, $security, credentials:redacted)';

  /// Secret material: only use for encrypted storage, never for logs or diagnostics.
  String toShareLink() => Uri(
    scheme: 'vless',
    userInfo: uuid,
    host: host,
    port: port,
    queryParameters: parameters,
    fragment: name,
  ).toString();
}
