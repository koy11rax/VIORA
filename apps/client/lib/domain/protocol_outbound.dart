import 'profile.dart';

/// Builds only application-owned outbound fields from a validated profile.
Map<String, dynamic> protocolOutbound(VlessProfile profile) {
  final p = profile.parameters;
  if (profile.protocol == 'hysteria2') {
    return {
      'tag': 'proxy',
      'protocol': 'hysteria',
      'settings': {'version': 2, 'address': profile.host, 'port': profile.port},
      'streamSettings': {
        'network': 'hysteria',
        'security': 'tls',
        'tlsSettings': {
          'serverName': p['sni'] ?? profile.host,
          'alpn': ['h3'],
        },
        'hysteriaSettings': {'version': 2, 'auth': profile.uuid},
        if (p['obfs'] == 'salamander')
          'finalmask': {
            'udp': [
              {
                'type': 'salamander',
                'settings': {'password': p['obfs-password']},
              },
            ],
          },
      },
    };
  }
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
  } else if (profile.security == 'tls') {
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
  final settings = switch (profile.protocol) {
    'vless' || 'vmess' => {
      'vnext': [
        {
          'address': profile.host,
          'port': profile.port,
          'users': [
            {
              'id': profile.uuid,
              'level': 8,
              if (profile.protocol == 'vless') 'encryption': 'none',
              if (profile.protocol == 'vmess') ...{
                'security': p['encryption'] ?? 'auto',
                'alterId': 0,
              },
              if ((p['flow'] ?? '').isNotEmpty) 'flow': p['flow'],
            },
          ],
        },
      ],
    },
    'trojan' || 'shadowsocks' => {
      'servers': [
        {
          'address': profile.host,
          'port': profile.port,
          'password': profile.uuid,
          'level': 8,
          if (profile.protocol == 'shadowsocks') 'method': p['method'],
        },
      ],
    },
    _ => throw const FormatException('Протокол не поддерживается'),
  };
  return {
    'tag': 'proxy',
    'protocol': profile.protocol,
    'settings': settings,
    if (profile.protocol != 'shadowsocks') 'streamSettings': stream,
  };
}
