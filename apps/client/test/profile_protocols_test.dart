import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/data/subscription_import.dart';

const uuid = '00000000-0000-4000-8000-000000000001';
const vless =
    'vless://$uuid@example.invalid:443?type=ws&security=tls&path=%2Fvpn#VLESS';
const hy2 =
    'hy2://fixture%3Aauth%40word@example.invalid:443/?sni=example.invalid&obfs=salamander&obfs-password=fixture-obfs#HY2';
String vmess([Map<String, dynamic> extra = const {}]) =>
    'vmess://${base64.encode(utf8.encode(jsonEncode({'v': '2', 'ps': 'VMess', 'add': 'example.invalid', 'port': '443', 'id': uuid, 'aid': '0', 'net': 'ws', 'tls': 'tls', 'path': '/socket', 'scy': 'auto', ...extra})))}';
String ss(String method, String password) =>
    'ss://${base64Url.encode(utf8.encode('$method:$password')).replaceAll('=', '')}@example.invalid:8388#SS';

void main() {
  final links = [
    vless,
    vmess(),
    'trojan://fixture%3Apa%40ss@example.invalid:443?sni=example.invalid#Trojan',
    ss('aes-128-gcm', 'fixture:p@ss%word'),
    hy2,
  ];
  test(
    'all supported schemes roundtrip through the existing encrypted-store representation',
    () {
      for (final link in links) {
        final profile = VlessProfile.parse(link);
        final restored = VlessProfile.parse(profile.toShareLink());
        expect(restored.protocol, profile.protocol);
        expect(restored.name, profile.name);
        expect(restored.host, profile.host);
        expect(restored.port, profile.port);
        expect(restored.uuid, profile.uuid);
        expect(restored.transport, profile.transport);
        expect(restored.security, profile.security);
        expect(restored.parameters, profile.parameters);
        expect(profile.displayLabel, isNot(contains(profile.uuid)));
        expect(profile.toString(), isNot(contains(profile.uuid)));
      }
    },
  );
  test(
    'Hysteria2 aliases, defaults and percent-encoded credentials are preserved',
    () {
      final profile = VlessProfile.parse(hy2);
      expect(profile.protocol, 'hysteria2');
      expect(profile.password, 'fixture:auth@word');
      expect(profile.transport, 'udp');
      expect(profile.displayLabel, 'Hysteria2 · QUIC · TLS');
      expect(
        VlessProfile.parse('hysteria2://fixture@example.invalid').port,
        443,
      );
      expect(profile.parameters['obfs-password'], 'fixture-obfs');
    },
  );
  test(
    'SIP002 supports raw and legacy base64 credentials including colon and at-sign',
    () {
      const password = 'fixture:with@and%characters';
      final raw =
          'ss://aes-256-gcm:${Uri.encodeComponent(password)}@example.invalid:8388#Raw';
      final legacy =
          'ss://${base64.encode(utf8.encode('aes-256-gcm:$password@example.invalid:8388'))}#Legacy';
      for (final link in [raw, legacy]) {
        final profile = VlessProfile.parse(link);
        expect(profile.method, 'aes-256-gcm');
        expect(profile.password, password);
        expect(VlessProfile.parse(profile.toShareLink()).password, password);
      }
    },
  );
  test('VLESS TCP TLS is accepted and insecure VLESS remains rejected', () {
    expect(
      VlessProfile.parse(
        'vless://$uuid@example.invalid:443?type=tcp&security=tls',
      ).security,
      'tls',
    );
    expect(
      () => VlessProfile.parse(
        'vless://$uuid@example.invalid:443?type=tcp&security=none',
      ),
      throwsFormatException,
    );
  });
  test('VMess supports AEAD only and safe boolean certificate flags', () {
    expect(
      VlessProfile.parse(vmess({'allowInsecure': false})).protocol,
      'vmess',
    );
    for (final extra in [
      {'aid': '64'},
      {'scy': 'none'},
      {'type': 'http'},
      {'net': 'grpc'},
      {'allowInsecure': true},
    ]) {
      expect(() => VlessProfile.parse(vmess(extra)), throwsFormatException);
    }
  });
  test(
    'unsupported transport, plugins, pinning and unimplemented HY2 options are refused',
    () {
      for (final link in [
        '$hy2&insecure=1',
        'hy2://fixture@example.invalid:443?insecure=1',
        'hy2://fixture@example.invalid:443?obfs=gecko&obfs-password=fixture',
        'hy2://fixture@example.invalid:443?obfs=salamander',
        'hy2://fixture@example.invalid:443?pinSHA256=fixture',
        'hy2://fixture@example.invalid:443?mport=443,8443',
        'hy2://fixture@example.invalid:443?upmbps=100',
        'hy2://fixture@example.invalid:443?alpn=http%2F1.1',
        'trojan://fixture@example.invalid:443?allowInsecure=true',
        '${ss('aes-128-gcm', 'fixture').split('#').first}/?plugin=obfs-local',
        ss('rc4-md5', 'fixture'),
        'wireguard://fixture@example.invalid:443',
      ]) {
        // A suffix after a fragment is a name, not a security parameter.
        if (link == '$hy2&insecure=1') continue;
        expect(
          () => VlessProfile.parse(link),
          throwsFormatException,
          reason: link.split('://').first,
        );
      }
    },
  );
  test('URI parser failures never expose secret source text', () {
    for (final link in [
      'hy2://private-secret@[invalid:443',
      'vmess://private-secret%%%',
      'ss://private-secret%%%',
    ]) {
      try {
        VlessProfile.parse(link);
        fail('malformed link accepted');
      } on FormatException catch (error) {
        expect(error.source, isNull);
        expect(error.toString(), isNot(contains('private-secret')));
      }
    }
  });
  test(
    'mixed plain and base64 subscriptions retain supported nodes and report omissions',
    () {
      final body = [
        ...links,
        'tuic://fixture@example.invalid:443',
        'hy2://fixture@example.invalid?insecure=1',
        vless,
      ].join('\n');
      for (final input in [body, base64.encode(utf8.encode(body))]) {
        final result = decodeSubscriptionDetailed(input);
        expect(
          result.profiles.map((p) => p.protocol).toSet(),
          VlessProfile.protocols,
        );
        expect(result.profiles, hasLength(5));
        expect(result.unsupportedCount, 2);
        expect(result.warnings.single, isNot(contains('fixture')));
      }
    },
  );
  test('common Clash YAML and JSON convert only explicit server fields', () {
    const yaml = '''
proxies:
  - {name: HY2, type: hysteria2, server: example.invalid, port: 443, password: fixture, sni: example.invalid, obfs: salamander, obfs-password: fixture-obfs, skip-cert-verify: false}
  - name: WS
    type: vless
    server: example.invalid
    port: 443
    uuid: 00000000-0000-4000-8000-000000000001
    tls: true
    network: ws
    ws-opts:
      path: /vpn
      headers: {Host: example.invalid}
  - {name: SS, type: ss, server: example.invalid, port: 8388, cipher: aes-256-gcm, password: fixture}
  - {name: unsupported, type: tuic, server: example.invalid, port: 443}
rules: [MATCH,DIRECT]
external-controller: 0.0.0.0:9090
''';
    final result = decodeSubscriptionDetailed(yaml);
    expect(result.profiles.map((p) => p.protocol), [
      'hysteria2',
      'vless',
      'shadowsocks',
    ]);
    expect(result.profiles[1].parameters['path'], '/vpn');
    expect(result.unsupportedCount, 1);
    final json = jsonEncode({
      'proxies': [
        {
          'name': 'Trojan',
          'type': 'trojan',
          'server': 'example.invalid',
          'port': 443,
          'password': 'fixture',
        },
      ],
    });
    expect(decodeSubscription(json).single.protocol, 'trojan');
  });
  test(
    'sing-box JSON ignores global policy and imports authenticated outbounds only',
    () {
      final body = jsonEncode({
        'inbounds': [
          {'type': 'http', 'listen': '0.0.0.0', 'listen_port': 1234},
        ],
        'route': {'final': 'direct'},
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
          {
            'type': 'selector',
            'tag': 'select',
            'outbounds': ['hy'],
          },
          {
            'type': 'hysteria2',
            'tag': 'hy',
            'server': 'example.invalid',
            'server_port': 443,
            'password': 'fixture',
            'tls': {
              'enabled': true,
              'server_name': 'example.invalid',
              'insecure': false,
            },
            'obfs': {'type': 'salamander', 'password': 'fixture-obfs'},
          },
          {
            'type': 'vmess',
            'tag': 'vm',
            'server': 'example.invalid',
            'server_port': 443,
            'uuid': uuid,
            'security': 'auto',
            'tls': {'enabled': true},
            'transport': {
              'type': 'ws',
              'path': '/vpn',
              'headers': {'Host': 'example.invalid'},
            },
          },
          {
            'type': 'trojan',
            'tag': 'tr',
            'server': 'example.invalid',
            'server_port': 443,
            'password': 'fixture',
            'tls': {'enabled': true},
          },
          {
            'type': 'shadowsocks',
            'server': 'example.invalid',
            'server_port': 8388,
            'method': 'chacha20-ietf-poly1305',
            'password': 'fixture',
          },
        ],
      });
      final result = decodeSubscriptionDetailed(body);
      expect(result.profiles.map((p) => p.protocol), [
        'hysteria2',
        'vmess',
        'trojan',
        'shadowsocks',
      ]);
      expect(result.unsupportedCount, 0);
    },
  );
  test(
    'structured nodes with unsafe TLS or unknown routing/socket controls are omitted explicitly',
    () {
      final body = jsonEncode({
        'outbounds': [
          {
            'type': 'hysteria2',
            'server': 'example.invalid',
            'server_port': 443,
            'password': 'fixture',
            'tls': {'enabled': true, 'insecure': true},
          },
          {
            'type': 'hysteria2',
            'server': 'example.invalid',
            'server_port': 443,
            'password': 'fixture',
            'tls': {'enabled': true},
            'detour': 'direct',
          },
          {
            'type': 'hysteria2',
            'server': 'example.invalid',
            'server_port': 443,
            'password': 'fixture',
            'tls': {'enabled': true, 'certificate_path': '/private.pem'},
          },
          {
            'type': 'trojan',
            'server': 'example.invalid',
            'server_port': 443,
            'password': 'fixture',
            'tls': {'enabled': true},
          },
        ],
      });
      final result = decodeSubscriptionDetailed(body);
      expect(result.profiles.single.protocol, 'trojan');
      expect(result.unsupportedCount, 3);
    },
  );
  test(
    'malformed structured errors and all-unsupported lists do not expose source',
    () {
      for (final body in [
        'proxies: [private-secret',
        '{"outbounds":[private-secret}',
        'trojan://private-secret@example.invalid:443?allowInsecure=1',
      ]) {
        try {
          decodeSubscriptionDetailed(body);
          fail('bad format accepted');
        } on FormatException catch (error) {
          expect(error.source, isNull);
          expect(error.toString(), isNot(contains('private-secret')));
        }
      }
    },
  );
  test('size, candidate and deduplicated server count remain bounded', () {
    expect(
      () => decodeSubscriptionDetailed('a' * 1048577),
      throwsFormatException,
    );
    expect(
      () => decodeSubscriptionDetailed(List.filled(2001, vless).join('\n')),
      throwsFormatException,
    );
    final links = List.generate(
      201,
      (i) => vless.replaceFirst('#VLESS', '#Server$i'),
    ).join('\n');
    expect(() => decodeSubscriptionDetailed(links), throwsFormatException);
  });
}
