import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:yaml/yaml.dart';
import '../domain/profile.dart';
import '../platform/native_bridge.dart';

enum SubscriptionImportReason { deviceRevoked, providerPlaceholder }

/// Only fixed public explanations may cross from a provider response to UI.
final class SubscriptionImportException extends FormatException {
  final SubscriptionImportReason reason;
  const SubscriptionImportException(this.reason)
    : super(
        reason == SubscriptionImportReason.deviceRevoked
            ? 'Это устройство отвязано от подписки. Включи существующее устройство в боте и обнови подписку.'
            : 'Бот не выдал рабочие серверы. Проверь срок подписки и лимит устройств в боте.',
      );
}

SubscriptionImportException _placeholderFailure(Uri? uri) {
  var label = '';
  try {
    label = Uri.decodeComponent(uri?.fragment ?? '').toLowerCase();
  } on FormatException {
    /* Provider text never enters the public error. */
  }
  final revoked =
      label.contains('устройство отвязано') ||
      label.contains('device revoked') ||
      label.contains('device is revoked') ||
      RegExp(r'^\s*revoked(?:\b|[\s·:;,.!-])').hasMatch(label);
  return SubscriptionImportException(
    revoked
        ? SubscriptionImportReason.deviceRevoked
        : SubscriptionImportReason.providerPlaceholder,
  );
}

class ImportedConnection {
  final List<VlessProfile> profiles;
  final String? source;
  final int? expires;
  final int unsupportedCount;
  const ImportedConnection(
    this.profiles, {
    this.source,
    this.expires,
    this.unsupportedCount = 0,
  });
  List<String> get warnings => unsupportedCount == 0
      ? const []
      : const [
          'Часть серверов пропущена: протокол, транспорт или параметры безопасности пока не поддерживаются.',
        ];
}

class DecodedSubscription {
  final List<VlessProfile> profiles;
  final int unsupportedCount;
  const DecodedSubscription(this.profiles, {this.unsupportedCount = 0});
  List<String> get warnings => unsupportedCount == 0
      ? const []
      : const [
          'Часть серверов пропущена: протокол, транспорт или параметры безопасности пока не поддерживаются.',
        ];
}

Uri subscriptionUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (value.length > 16384 ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw const FormatException(
      'Вставь HTTPS-ссылку подписки или ссылку VLESS, VMess, Trojan, Shadowsocks, Hysteria2',
    );
  }
  return uri;
}

bool isVioraSubscription(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host == 'vpnfn2345.duckdns.org' &&
    uri.port == 443 &&
    RegExp(r'^/sub/[^/]+$').hasMatch(uri.path);

List<VlessProfile> decodeSubscription(String body) =>
    decodeSubscriptionDetailed(body).profiles;

DecodedSubscription decodeSubscriptionDetailed(String body) {
  var text = body.trim().replaceFirst('\uFEFF', '');
  if (text.length > 1048576) {
    throw const FormatException('Подписка слишком большая');
  }
  if (text.isEmpty) {
    throw const FormatException(
      'Подписка пустая. Проверь её срок и статус у провайдера.',
    );
  }
  // Decode only one subscription envelope. Nested envelopes are not formats.
  if (!text.contains('://') &&
      !text.startsWith('{') &&
      !text.startsWith('[') &&
      !RegExp(r'(?:^|\n)\s*proxies\s*:').hasMatch(text)) {
    try {
      text = utf8.decode(
        base64.decode(base64.normalize(text.replaceAll(RegExp(r'\s'), ''))),
      );
    } catch (_) {
      throw const FormatException(
        'Неподдерживаемый формат подписки. Нужен список ссылок, Clash YAML или sing-box JSON.',
      );
    }
  }
  if (text.length > 1048576) {
    throw const FormatException('Подписка слишком большая');
  }
  final profiles = <String, VlessProfile>{};
  var unsupported = 0;
  var candidates = 0;
  void add(VlessProfile Function() parse) {
    if (++candidates > 2000) {
      throw const FormatException('В подписке слишком много записей');
    }
    try {
      final profile = parse();
      if ((const {'127.0.0.1', '0.0.0.0', 'localhost'}.contains(profile.host) &&
          profile.port == 1)) {
        throw _placeholderFailure(null);
      }
      profiles[profile.toShareLink()] = profile;
      if (profiles.length > 200) throw const _TooManyProfiles();
    } on SubscriptionImportException {
      rethrow;
    } on _TooManyProfiles {
      rethrow;
    } on FormatException {
      unsupported++;
    }
  }

  try {
    if (text.trimLeft().startsWith('{') || text.trimLeft().startsWith('[')) {
      dynamic document;
      try {
        document = jsonDecode(text);
      } catch (_) {
        throw const FormatException('Некорректный JSON подписки');
      }
      final clash = document is Map && document['proxies'] is List;
      final entries = document is Map
          ? document[clash ? 'proxies' : 'outbounds']
          : document;
      if (entries is! List) {
        throw const FormatException(
          'В sing-box JSON не найден список outbounds',
        );
      }
      if (entries.length > 2000) {
        throw const FormatException('В подписке слишком много записей');
      }
      for (final entry in entries) {
        // Selectors/direct/DNS are policy entries, never imported as servers.
        if (entry is Map &&
            const {
              'direct',
              'block',
              'dns',
              'selector',
              'urltest',
            }.contains(entry['type'])) {
          continue;
        }
        add(
          () => clash
              ? _clashProfile(_mapping(entry))
              : _singBoxProfile(_mapping(entry)),
        );
      }
    } else if (RegExp(r'(?:^|\n)\s*proxies\s*:').hasMatch(text)) {
      dynamic document;
      try {
        document = loadYaml(text);
      } catch (_) {
        throw const FormatException('Некорректный Clash YAML подписки');
      }
      final entries = document is Map ? document['proxies'] : null;
      if (entries is! List) {
        throw const FormatException('В Clash YAML не найден список proxies');
      }
      if (entries.length > 2000) {
        throw const FormatException('В подписке слишком много записей');
      }
      for (final entry in entries) {
        add(() => _clashProfile(_mapping(entry)));
      }
    } else {
      final lines = const LineSplitter().convert(text);
      if (lines.length > 4000) {
        throw const FormatException('В подписке слишком много строк');
      }
      for (final line in lines) {
        final value = line.trim();
        if (value.isEmpty || value.startsWith('#')) continue;
        Uri? hint;
        var placeholder = false;
        try {
          hint = Uri.tryParse(value);
          placeholder =
              hint != null &&
              const {'127.0.0.1', '0.0.0.0', 'localhost'}.contains(hint.host) &&
              hint.port == 1;
        } catch (_) {
          /* Count below. */
        }
        if (placeholder) {
          throw _placeholderFailure(hint);
        }
        add(() => VlessProfile.parse(value));
      }
    }
  } on _TooManyProfiles {
    throw const FormatException('В подписке больше 200 серверов');
  }
  if (profiles.isEmpty) {
    throw FormatException(
      unsupported > 0
          ? 'В подписке нет поддерживаемых серверов. Поддерживаются VLESS, VMess, Trojan, Shadowsocks и Hysteria2; проверка TLS должна быть включена.'
          : 'Подписка пустая. Проверь её срок и статус у провайдера.',
    );
  }
  return DecodedSubscription(
    List.unmodifiable(profiles.values),
    unsupportedCount: unsupported,
  );
}

class _TooManyProfiles implements Exception {
  const _TooManyProfiles();
}

Map<String, dynamic> _mapping(dynamic input) {
  if (input is! Map ||
      input.length > 40 ||
      input.keys.any((key) => key is! String)) {
    throw const FormatException('Некорректные поля сервера');
  }
  return Map<String, dynamic>.from(input);
}

String _string(
  Map<String, dynamic> fields,
  String key, [
  String fallback = '',
]) {
  final value = fields[key];
  if (value == null) return fallback;
  if (value is! String && value is! int) {
    throw const FormatException('Некорректное поле сервера');
  }
  return '$value';
}

void _keys(Map<String, dynamic> value, Set<String> allowed) {
  if (value.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('Неподдерживаемые параметры сервера');
  }
}

void _falseOrAbsent(Map<String, dynamic> fields, String key) {
  final value = fields[key];
  if (value != null &&
      value != false &&
      value != 0 &&
      value != 'false' &&
      value != '0') {
    throw const FormatException(
      'Неподдерживаемая или небезопасная настройка сервера',
    );
  }
}

String _alpn(dynamic value) {
  if (value is String) return value;
  if (value is List &&
      value.length <= 16 &&
      value.every((item) => item is String)) {
    return value.join(',');
  }
  throw const FormatException('Некорректный ALPN');
}

VlessProfile _clashProfile(Map<String, dynamic> node) {
  final rawType = _string(node, 'type');
  final protocol = rawType == 'ss'
      ? 'shadowsocks'
      : rawType == 'hy2'
      ? 'hysteria2'
      : rawType;
  if (!VlessProfile.protocols.contains(protocol)) {
    throw const FormatException('Неподдерживаемый протокол Clash');
  }
  _keys(node, {
    'name',
    'type',
    'server',
    'port',
    'udp',
    'tfo',
    if (protocol == 'vless' || protocol == 'vmess') 'uuid' else 'password',
    if (protocol == 'shadowsocks' || protocol == 'vmess') 'cipher',
    if (protocol == 'vmess') 'alterId',
    if (protocol != 'hysteria2' && protocol != 'shadowsocks') ...{
      'network',
      'ws-opts',
      'client-fingerprint',
    },
    if (protocol != 'shadowsocks') ...{
      'tls',
      'servername',
      'sni',
      'skip-cert-verify',
      'alpn',
    },
    if (protocol == 'vless') ...{'reality-opts', 'flow'},
    if (protocol == 'hysteria2') ...{'obfs', 'obfs-password'},
  });
  _falseOrAbsent(node, 'skip-cert-verify');
  if ((protocol == 'hysteria2' || protocol == 'trojan') &&
      node.containsKey('tls') &&
      node['tls'] != true) {
    throw const FormatException(
      'Для этого протокола требуется проверяемый TLS',
    );
  }
  if (node.containsKey('alterId') && _string(node, 'alterId') != '0') {
    throw const FormatException('Устаревший VMess не поддерживается');
  }
  final parameters = <String, String>{};
  if (protocol == 'hysteria2') {
    for (final key in ['obfs', 'obfs-password']) {
      if (node.containsKey(key)) parameters[key] = _string(node, key);
    }
  } else if (protocol == 'shadowsocks') {
    parameters['method'] = _string(node, 'cipher');
  } else {
    parameters['type'] = _string(node, 'network', 'tcp');
    if (node.containsKey('tls') && node['tls'] is! bool) {
      throw const FormatException('Некорректная настройка TLS');
    }
    parameters['security'] = node['tls'] == true || protocol == 'trojan'
        ? 'tls'
        : 'none';
    if (protocol == 'vmess') {
      parameters['encryption'] = _string(node, 'cipher', 'auto');
    }
    if (node.containsKey('flow')) parameters['flow'] = _string(node, 'flow');
    if (node.containsKey('client-fingerprint')) {
      parameters['fp'] = _string(node, 'client-fingerprint');
    }
    if (node.containsKey('ws-opts')) {
      if (parameters['type'] != 'ws') {
        throw const FormatException('Транспорт не соответствует настройкам');
      }
      final ws = _mapping(node['ws-opts']);
      _keys(ws, {'path', 'headers'});
      if (ws.containsKey('path')) parameters['path'] = _string(ws, 'path');
      if (ws.containsKey('headers')) {
        final headers = _mapping(ws['headers']);
        _keys(headers, {'Host', 'host'});
        if (headers.length != 1) {
          throw const FormatException('Некорректные заголовки WebSocket');
        }
        parameters['host'] = _string(headers, headers.keys.single);
      }
    }
    if (node.containsKey('reality-opts')) {
      if (protocol != 'vless') {
        throw const FormatException('REALITY поддерживается только с VLESS');
      }
      final reality = _mapping(node['reality-opts']);
      _keys(reality, {'public-key', 'short-id'});
      parameters['security'] = 'reality';
      parameters['pbk'] = _string(reality, 'public-key');
      parameters['sid'] = _string(reality, 'short-id');
    }
  }
  final sni = _string(node, 'sni', _string(node, 'servername'));
  if (sni.isNotEmpty) parameters['sni'] = sni;
  if (node.containsKey('alpn')) parameters['alpn'] = _alpn(node['alpn']);
  return VlessProfile.fromFields(
    protocol: protocol,
    name: _string(node, 'name', 'Мой сервер'),
    host: _string(node, 'server'),
    port: int.tryParse(_string(node, 'port')) ?? 0,
    credential: _string(
      node,
      protocol == 'vless' || protocol == 'vmess' ? 'uuid' : 'password',
    ),
    parameters: parameters,
  );
}

VlessProfile _singBoxProfile(Map<String, dynamic> node) {
  final protocol = _string(node, 'type');
  if (!VlessProfile.protocols.contains(protocol)) {
    throw const FormatException('Неподдерживаемый протокол sing-box');
  }
  _keys(node, {
    'type',
    'tag',
    'server',
    'server_port',
    if (protocol == 'vless' || protocol == 'vmess') 'uuid' else 'password',
    if (protocol == 'shadowsocks') 'method',
    if (protocol == 'vmess') ...{'security', 'alter_id'},
    if (protocol == 'vless') 'flow',
    if (protocol != 'shadowsocks') 'tls',
    if (protocol != 'shadowsocks' && protocol != 'hysteria2') 'transport',
    if (protocol == 'hysteria2') 'obfs',
  });
  if (node.containsKey('alter_id') && _string(node, 'alter_id') != '0') {
    throw const FormatException('Устаревший VMess не поддерживается');
  }
  final p = <String, String>{};
  if (protocol == 'shadowsocks') {
    p['method'] = _string(node, 'method');
  } else if (protocol == 'hysteria2') {
    if (node.containsKey('obfs')) {
      final obfs = _mapping(node['obfs']);
      _keys(obfs, {'type', 'password'});
      p['obfs'] = _string(obfs, 'type');
      p['obfs-password'] = _string(obfs, 'password');
    }
  } else {
    p['type'] = 'tcp';
    p['security'] = 'none';
    if (protocol == 'vmess') {
      p['encryption'] = _string(node, 'security', 'auto');
    }
    if (node.containsKey('flow')) p['flow'] = _string(node, 'flow');
  }
  if (node.containsKey('tls')) {
    final tls = _mapping(node['tls']);
    _keys(tls, {
      'enabled',
      'server_name',
      'insecure',
      'alpn',
      'utls',
      'reality',
    });
    _falseOrAbsent(tls, 'insecure');
    if (tls['enabled'] != true) {
      throw const FormatException('Для этого профиля требуется TLS');
    }
    if (protocol == 'shadowsocks') {
      throw const FormatException('Shadowsocks TLS не поддерживается');
    }
    if (protocol != 'hysteria2') p['security'] = 'tls';
    if (tls.containsKey('server_name')) p['sni'] = _string(tls, 'server_name');
    if (tls.containsKey('alpn')) p['alpn'] = _alpn(tls['alpn']);
    if (tls.containsKey('utls')) {
      if (protocol == 'hysteria2') {
        throw const FormatException('uTLS не поддерживается с Hysteria2');
      }
      final utls = _mapping(tls['utls']);
      _keys(utls, {'enabled', 'fingerprint'});
      if (utls['enabled'] == true) {
        p['fp'] = _string(utls, 'fingerprint', 'chrome');
      } else {
        _falseOrAbsent(utls, 'enabled');
      }
    }
    if (tls.containsKey('reality')) {
      if (protocol != 'vless') {
        throw const FormatException('REALITY поддерживается только с VLESS');
      }
      final reality = _mapping(tls['reality']);
      _keys(reality, {'enabled', 'public_key', 'short_id'});
      if (reality['enabled'] != true) {
        throw const FormatException('Некорректная настройка REALITY');
      }
      p['security'] = 'reality';
      p['pbk'] = _string(reality, 'public_key');
      p['sid'] = _string(reality, 'short_id');
    }
  } else if (protocol == 'hysteria2' || protocol == 'trojan') {
    throw const FormatException('В профиле отсутствует проверяемый TLS');
  }
  if (node.containsKey('transport')) {
    if (protocol == 'hysteria2' || protocol == 'shadowsocks') {
      throw const FormatException('Неподдерживаемый транспорт');
    }
    final transport = _mapping(node['transport']);
    _keys(transport, {'type', 'path', 'headers'});
    if (_string(transport, 'type') != 'ws') {
      throw const FormatException('Неподдерживаемый транспорт');
    }
    p['type'] = 'ws';
    if (transport.containsKey('path')) p['path'] = _string(transport, 'path');
    if (transport.containsKey('headers')) {
      final headers = _mapping(transport['headers']);
      _keys(headers, {'Host', 'host'});
      if (headers.length != 1) {
        throw const FormatException('Некорректные заголовки WebSocket');
      }
      p['host'] = _string(headers, headers.keys.single);
    }
  }
  return VlessProfile.fromFields(
    protocol: protocol,
    name: _string(node, 'tag', 'Мой сервер'),
    host: _string(node, 'server'),
    port: int.tryParse(_string(node, 'server_port')) ?? 0,
    credential: _string(
      node,
      protocol == 'vless' || protocol == 'vmess' ? 'uuid' : 'password',
    ),
    parameters: p,
  );
}

class SubscriptionImporter {
  final HttpClient Function() createClient;
  final Future<String> Function() identity;
  final String operatingSystem;
  SubscriptionImporter({
    HttpClient Function()? createClient,
    Future<String> Function()? identity,
    String? operatingSystem,
  }) : createClient = createClient ?? HttpClient.new,
       identity = identity ?? NativeBridge.installationId,
       operatingSystem = operatingSystem ?? Platform.operatingSystem;

  Future<ImportedConnection> load(String value) async {
    final initial = subscriptionUri(value);
    final client = createClient();
    client.connectionTimeout = const Duration(seconds: 15);
    try {
      return await (() async {
        var uri = initial;
        final visited = <String>{};
        for (var redirect = 0; redirect <= 3; redirect++) {
          if (!visited.add(uri.toString())) {
            throw const FormatException(
              'Подписка содержит цикл перенаправлений',
            );
          }
          final request = await client.getUrl(uri);
          request.followRedirects = false;
          request.headers.set(HttpHeaders.userAgentHeader, 'Viora/1.0.6');
          request.headers.set(
            HttpHeaders.acceptHeader,
            'text/plain, application/json, application/yaml',
          );
          final deviceOs = const {
            'android': 'Android',
            'windows': 'Windows',
            'linux': 'Linux',
          }[operatingSystem];
          // Every redirect gets a fresh request. No device headers go to a new origin.
          if (isVioraSubscription(initial) &&
              isVioraSubscription(uri) &&
              deviceOs != null) {
            request.headers.set('x-hwid', await identity());
            request.headers.set('x-device-os', deviceOs);
            request.headers.set('x-device-model', 'Viora $deviceOs');
          }
          final response = await request.close();
          if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            if (location == null || redirect == 3) {
              throw const FormatException(
                'Не удалось получить прямую ссылку подписки',
              );
            }
            // Abort rather than consume an unbounded redirect body.
            await response.listen((_) {}).cancel();
            try {
              uri = subscriptionUri(uri.resolve(location).toString());
            } catch (_) {
              throw const FormatException(
                'Небезопасное перенаправление подписки: требуется HTTPS',
              );
            }
            continue;
          }
          if (response.statusCode != 200) {
            throw FormatException(
              response.statusCode == 403 || response.statusCode == 404
                  ? 'Подписка недействительна или доступ закрыт. Обнови ссылку у провайдера.'
                  : 'Провайдер подписки временно недоступен. Попробуй позже.',
            );
          }
          final info = response.headers.value('subscription-userinfo') ?? '';
          final seconds = int.tryParse(
            RegExp(r'(?:^|;)\s*expire=(\d+)').firstMatch(info)?.group(1) ?? '',
          );
          if (seconds != null &&
              seconds * 1000 <= DateTime.now().millisecondsSinceEpoch) {
            throw const FormatException(
              'Подписка закончилась. Продли её у провайдера и повтори импорт.',
            );
          }
          final bytes = <int>[];
          await for (final chunk in response) {
            if (bytes.length + chunk.length > 1048576) {
              throw const FormatException('Подписка слишком большая');
            }
            bytes.addAll(chunk);
          }
          final result = decodeSubscriptionDetailed(utf8.decode(bytes));
          return ImportedConnection(
            result.profiles,
            source: initial.toString(),
            expires: seconds,
            unsupportedCount: result.unsupportedCount,
          );
        }
        throw const FormatException('Не удалось загрузить подписку');
      })().timeout(const Duration(seconds: 30));
    } on FormatException catch (error) {
      if (error.source != null) {
        throw const FormatException(
          'Провайдер вернул некорректный формат подписки',
        );
      }
      rethrow;
    } on TimeoutException {
      throw const FormatException(
        'Подписка не загрузилась за 30 секунд. Проверь интернет и повтори.',
      );
    } catch (_) {
      throw const FormatException(
        'Не удалось загрузить подписку. Проверь интернет и ссылку провайдера.',
      );
    } finally {
      client.close(force: true);
    }
  }
}
