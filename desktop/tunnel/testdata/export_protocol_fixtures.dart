import 'dart:convert';
import 'dart:io';

import '../../../apps/client/lib/domain/profile.dart';
import '../../../apps/client/lib/domain/tunnel_config.dart';

// Synthetic fixtures only. This runs the production Dart model and complete
// TunnelConfig builder, so native tests cannot accidentally validate a hand-
// written DTO which differs from the application (for example SS omission of
// streamSettings). No real provider URL or credential belongs in this file.
void main(List<String> arguments) {
  if (arguments.length != 1) {
    throw ArgumentError('Specify one synthetic fixture output path');
  }
  const id = '00000000-0000-4000-8000-000000000001';
  final entries = <String, VlessProfile>{
    'vless_tcp_tls': VlessProfile.parse(
      'vless://$id@fixture.invalid:443?security=tls&type=tcp&sni=fixture.invalid',
    ),
    'vless_ws_tls': VlessProfile.parse(
      'vless://$id@fixture.invalid:443?security=tls&type=ws&sni=fixture.invalid&path=%2Ffixture',
    ),
    for (final transport in ['tcp', 'ws'])
      for (final tls in [true, false])
        'vmess_${transport}_${tls ? 'tls' : 'aead'}': VlessProfile.fromFields(
          protocol: 'vmess',
          name: 'synthetic fixture',
          host: 'fixture.invalid',
          port: 443,
          credential: id,
          parameters: {
            'type': transport,
            'security': tls ? 'tls' : 'none',
            'encryption': 'auto',
            if (transport == 'ws') 'path': '/fixture',
          },
        ),
    for (final transport in ['tcp', 'ws'])
      'trojan_$transport': VlessProfile.parse(
        'trojan://fixture-password@fixture.invalid:443?type=$transport&sni=fixture.invalid&path=%2Ffixture',
      ),
    for (final method in VlessProfile.shadowsocksMethods)
      'shadowsocks_$method': VlessProfile.fromFields(
        protocol: 'shadowsocks',
        name: 'synthetic fixture',
        host: 'fixture.invalid',
        port: 443,
        credential: 'fixture-password',
        parameters: {'method': method},
      ),
    'hysteria2': VlessProfile.parse(
      'hy2://fixture-password@fixture.invalid:443?sni=fixture.invalid',
    ),
    'hysteria2_salamander': VlessProfile.parse(
      'hy2://fixture-password@fixture.invalid:443?sni=fixture.invalid&obfs=salamander&obfs-password=fixture-obfuscation',
    ),
  };
  File(arguments.single).writeAsStringSync(
    jsonEncode([
      for (final entry in entries.entries)
        {
          'name': entry.key,
          'config': TunnelConfig.build(
            profile: entry.value,
            russianServicesDirect: false,
          ).json,
        },
    ]),
  );
}
