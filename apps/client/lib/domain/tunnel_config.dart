import 'dart:io';
import 'profile.dart';
import 'routing.dart';
import 'russian_services.dart';

/// Only validated, structured profiles enter the core; arbitrary JSON is never imported.
class TunnelConfig {
  final Map<String, dynamic> json;
  final List<String>? allowedApps;
  final List<String> excludedApps;
  final int mtu, retries;
  final bool reconnect, requireLockdown;
  TunnelConfig._(
    this.json,
    this.allowedApps,
    this.excludedApps,
    this.mtu,
    this.reconnect,
    this.retries,
    this.requireLockdown,
  );

  factory TunnelConfig.build({
    required VlessProfile profile,
    List<RoutingRule> rules = const [],
    String appMode = 'all',
    Set<String> applications = const {},
    bool localNetwork = false,
    bool russianServicesDirect = true,
    String? dns,
    int mtu = 1500,
    bool strict = false,
    bool reconnect = true,
    int retries = 3,
  }) {
    if (strict && !Platform.isAndroid) {
      throw const FormatException(
        'Строгая защита ещё не готова. Выбери защиту в пределах VPN-сессии.',
      );
    }
    if (retries < 1 || retries > 5) {
      throw const FormatException('Некорректное число попыток');
    }
    if (!['all', 'only', 'except'].contains(appMode) ||
        (appMode != 'all' && applications.isEmpty)) {
      throw const FormatException('Выбери приложения для этого режима VPN');
    }
    if (applications.any(
      (id) =>
          !RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$').hasMatch(id) ||
          id == 'dev.viora.viora_client',
    )) {
      throw const FormatException('Некорректный список приложений');
    }
    final dnsIp = dns == null ? null : InternetAddress.tryParse(dns);
    if (dns != null &&
        (dnsIp == null || dnsIp.type != InternetAddressType.IPv4)) {
      throw const FormatException('Для этой версии укажи DNS по IPv4');
    }
    if (![1280, 1420, 1500].contains(mtu)) {
      throw const FormatException('Некорректный MTU');
    }
    final p = profile.parameters;
    final stream = <String, dynamic>{
      'network': profile.transport == 'tcp' ? 'raw' : profile.transport,
      'security': profile.security,
    };
    if (profile.security == 'reality') {
      if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(p['pbk'] ?? '') ||
          !RegExp(r'^(?:[a-fA-F0-9]{2}){0,8}$').hasMatch(p['sid'] ?? '')) {
        throw const FormatException('Проверь ключ REALITY и Short ID');
      }
      stream['realitySettings'] = {
        'serverName': p['sni'],
        'fingerprint': p['fp'] ?? 'chrome',
        'password': p['pbk'],
        'shortId': p['sid'] ?? '',
        if ((p['spx'] ?? '').isNotEmpty) 'spiderX': p['spx'],
      };
    } else {
      stream['tlsSettings'] = {
        'serverName': p['sni'] ?? p['host'] ?? profile.host,
        'fingerprint': p['fp'] ?? 'chrome',
        if ((p['alpn'] ?? '').isNotEmpty) 'alpn': p['alpn']!.split(','),
      };
    }
    if (profile.transport == 'ws') {
      stream['wsSettings'] = {
        'path': p['path'] ?? '/',
        if ((p['host'] ?? '').isNotEmpty) 'headers': {'Host': p['host']},
      };
    } else if (profile.transport == 'xhttp') {
      if (![
        'auto',
        'packet-up',
        'stream-up',
        'stream-one',
      ].contains(p['mode'] ?? 'auto')) {
        throw const FormatException('Неподдерживаемый режим XHTTP');
      }
      stream['xhttpSettings'] = {
        'path': p['path'] ?? '/',
        'mode': p['mode'] ?? 'auto',
        if ((p['host'] ?? '').isNotEmpty) 'host': p['host'],
      };
    }
    final routing = <Map<String, dynamic>>[
      // Defense in depth: Android blocks the unsupported IPv6 family as well.
      {
        'type': 'field',
        'ip': ['::/0'],
        'outboundTag': 'block',
      },
      // Internal resolver traffic must not re-enter the DNS handler. This
      // includes custom plain DNS; standard DNS uses HTTPS over the proxy.
      {
        'type': 'field',
        'inboundTag': ['dns-internal'],
        'outboundTag': 'proxy',
      },
      {'type': 'field', 'port': '53', 'outboundTag': 'dns-out'},
      // Android's opportunistic DoT probe must not send the virtual resolver
      // address to the remote server. Fail it promptly and allow plain DNS to
      // the local handler; the handler itself uses encrypted DNS over VPN.
      {
        'type': 'field',
        'ip': ['26.26.26.2'],
        'port': '853',
        'outboundTag': 'block',
      },
      {'type': 'field', 'port': '853', 'outboundTag': 'proxy'},
      for (final rule in rules.where((r) => r.enabled))
        {
          'type': 'field',
          switch (rule.kind) {
            RuleKind.domain => 'domain',
            RuleKind.subnet => 'ip',
            RuleKind.port => 'port',
          }: rule.kind == RuleKind.port
              ? rule.value
              : [
                  rule.kind == RuleKind.domain
                      ? 'domain:${rule.value}'
                      : rule.value,
                ],
          'outboundTag': switch (rule.action) {
            RuleAction.vpn => 'proxy',
            RuleAction.direct => 'direct',
            RuleAction.block => 'block',
          },
        },
      if (russianServicesDirect)
        {
          'type': 'field',
          'domain': russianServiceDomains.map((d) => 'domain:$d').toList(),
          'outboundTag': 'direct',
        },
      if (localNetwork)
        {
          'type': 'field',
          'ip': ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'],
          'outboundTag': 'direct',
        },
    ];
    return TunnelConfig._(
      {
        'log': {'loglevel': 'none'},
        'dns': {
          'servers': [dns ?? 'https://1.1.1.1/dns-query'],
          'queryStrategy': 'UseIPv4',
          'tag': 'dns-internal',
        },
        'inbounds': [
          {
            'tag': 'tun',
            'protocol': 'tun',
            'settings': {'name': 'viora0', 'MTU': mtu, 'userLevel': 8},
            'sniffing': {
              'enabled': true,
              'destOverride': ['http', 'tls', 'quic'],
              'routeOnly': true,
            },
          },
        ],
        'outbounds': [
          {
            'tag': 'proxy',
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': profile.host,
                  'port': profile.port,
                  'users': [
                    {
                      'id': profile.uuid,
                      'encryption': 'none',
                      'level': 8,
                      if ((p['flow'] ?? '').isNotEmpty) 'flow': p['flow'],
                    },
                  ],
                },
              ],
            },
            'streamSettings': stream,
          },
          {
            'tag': 'direct',
            'protocol': 'freedom',
            'settings': {},
            'streamSettings': {
              'sockopt': {'domainStrategy': 'UseIPv4'},
            },
          },
          {'tag': 'block', 'protocol': 'blackhole', 'settings': {}},
          {
            'tag': 'dns-out',
            'protocol': 'dns',
            'settings': {
              'userLevel': 8,
              // IPv6 is blocked in this release; do not advertise IPv6
              // destinations which browsers cannot connect to.
              'rules': [
                {'action': 'return', 'qType': 28, 'rCode': 0},
              ],
            },
          },
        ],
        'routing': {'domainStrategy': 'IPIfNonMatch', 'rules': routing},
      },
      appMode == 'only' ? applications.toList() : null,
      appMode == 'except' ? applications.toList() : [],
      mtu,
      reconnect,
      retries,
      strict,
    );
  }

  @override
  String toString() => 'TunnelConfig(credentials:redacted)';
}
