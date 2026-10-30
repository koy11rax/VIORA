import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/domain/tunnel_config.dart';

void main() {
  test(
    'Hysteria2 retains verified TLS, credentials and salamander in native DTO',
    () {
      final profile = VlessProfile.parse(
        'hy2://fixture-password@example.org:443?sni=example.org&obfs=salamander&obfs-password=fixture-mask#HY2',
      );
      final config = TunnelConfig.build(
        profile: profile,
        russianServicesDirect: false,
      );
      final outbound = (config.json['outbounds'] as List).first as Map;
      expect(outbound['protocol'], 'hysteria');
      expect(outbound['settings'], {
        'version': 2,
        'address': 'example.org',
        'port': 443,
      });
      final stream = outbound['streamSettings'] as Map;
      expect(stream['network'], 'hysteria');
      expect((stream['tlsSettings'] as Map)['serverName'], 'example.org');
      expect((stream['tlsSettings'] as Map)['allowInsecure'], isNot(true));
      expect((stream['hysteriaSettings'] as Map)['auth'], 'fixture-password');
      expect(((stream['finalmask'] as Map)['udp'] as List).single, {
        'type': 'salamander',
        'settings': {'password': 'fixture-mask'},
      });
      expect(config.toString(), isNot(contains('fixture-password')));
    },
  );

  test('new protocols preserve application and routing options', () {
    final profile = VlessProfile.parse(
      'trojan://fixture@example.org:443?sni=example.org',
    );
    final config = TunnelConfig.build(
      profile: profile,
      appMode: 'only',
      applications: {'org.example.browser'},
      strict: true,
      mtu: 1280,
    );
    expect(config.allowedApps, ['org.example.browser']);
    expect(config.requireLockdown, true);
    expect(config.mtu, 1280);
    final outbound = (config.json['outbounds'] as List).first as Map;
    expect(outbound['protocol'], 'trojan');
    expect(((outbound['settings'] as Map)['servers'] as List).single, {
      'address': 'example.org',
      'port': 443,
      'password': 'fixture',
      'level': 8,
    });
  });
}
