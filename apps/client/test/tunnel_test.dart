import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/domain/routing.dart';
import 'package:viora_client/domain/tunnel_config.dart';
import 'package:viora_client/platform/tunnel.dart';

const link =
    'vless://00000000-0000-4000-8000-000000000001@example.invalid:443?type=ws&security=tls&path=%2Fvpn&host=cdn.example.invalid#Test';
TunnelConfig config() => TunnelConfig.build(profile: VlessProfile.parse(link));

class TestEngine implements TunnelEngine {
  @override
  bool supported = true;
  bool permission = true, fail = false;
  bool acknowledgeStop = true;
  int starts = 0, stops = 0, requests = 0;
  final controller = StreamController<TunnelStats>.broadcast(sync: true);
  @override
  Stream<TunnelStats> get events => controller.stream;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> requestPermission() async {
    requests++;
    return permission;
  }

  @override
  Future<void> start(TunnelConfig config, String name) async {
    starts++;
    if (fail) throw StateError('native secret details');
  }

  @override
  Future<void> stop() async {
    stops++;
    if (acknowledgeStop) controller.add(const TunnelStats('DISCONNECTED'));
  }
}

void main() {
  test(
    'Android legacy and extended status preserve traffic and protection',
    () {
      final legacy = AndroidXrayEngine.decodeStatus([
        '00:00:07',
        '1',
        '2',
        '30',
        '40',
        'CONNECTED',
      ]);
      expect(legacy.upload, 30);
      expect(legacy.download, 40);
      expect(legacy.lockdown, isFalse);
      final protected = AndroidXrayEngine.decodeStatus([
        '00:00:08',
        '1',
        '2',
        '31',
        '41',
        'CONNECTED',
        '',
        'true',
        'true',
      ]);
      expect(protected.lockdown, isTrue);
      expect(protected.alwaysOn, isTrue);
      expect(protected.errorCode, isNull);
      final failure = AndroidXrayEngine.decodeStatus([
        '00:00:00',
        '0',
        '0',
        '0',
        '0',
        'FAILED',
        'lockdown_required',
        'false',
        'false',
      ]);
      expect(failure.errorCode, 'lockdown_required');
      expect(
        () => AndroidXrayEngine.decodeStatus(['CONNECTED']),
        throwsFormatException,
      );
    },
  );
  test('recovery options stay out of core JSON and validate retry limits', () {
    final configured = TunnelConfig.build(
      profile: VlessProfile.parse(link),
      reconnect: false,
      retries: 5,
    );
    expect(configured.reconnect, isFalse);
    expect(configured.retries, 5);
    expect(configured.json.containsKey('reconnect'), isFalse);
    for (final retries in [0, 6]) {
      expect(
        () => TunnelConfig.build(
          profile: VlessProfile.parse(link),
          retries: retries,
        ),
        throwsFormatException,
      );
    }
  });

  test('switch waits for native stop before starting the new server', () async {
    final engine = TestEngine()..acknowledgeStop = false;
    final tunnel = TunnelController(engine);
    await tunnel.connect(config(), 'First');
    engine.controller.add(const TunnelStats('CONNECTED'));
    final switched = tunnel.switchServer(config(), 'Second');
    await Future<void>.delayed(Duration.zero);
    expect(tunnel.busy, isTrue);
    expect(engine.starts, 1);
    await tunnel.switchServer(config(), 'Third');
    engine.controller.add(const TunnelStats('DISCONNECTED'));
    await switched;
    expect(engine.starts, 2);
    expect(tunnel.activeProfile, 'Second');
    expect(tunnel.phase, TunnelPhase.connecting);
    engine.controller.add(const TunnelStats('CONNECTED'));
    expect(tunnel.phase, TunnelPhase.active);
    tunnel.dispose();
    await engine.controller.close();
  });
  test(
    'switch does not start another tunnel when native stop is unconfirmed',
    () async {
      final engine = TestEngine()..acknowledgeStop = false;
      final tunnel = TunnelController(engine);
      await tunnel.connect(config(), 'First');
      engine.controller.add(const TunnelStats('CONNECTED'));
      await tunnel.switchServer(
        config(),
        'Second',
        stopTimeout: const Duration(milliseconds: 10),
      );
      expect(engine.starts, 1);
      expect(tunnel.phase, TunnelPhase.failed);
      tunnel.dispose();
      await engine.controller.close();
    },
  );
  test(
    'Russian direct preset defaults on, can be disabled, preserves custom rule priority',
    () {
      final enabled = config().json['routing']['rules'] as List;
      final direct = enabled.last as Map;
      expect(direct['outboundTag'], 'direct');
      expect(
        direct['domain'],
        containsAll([
          'domain:ru',
          'domain:xn--p1ai',
          'domain:vk.com',
          'domain:userapi.com',
        ]),
      );
      final disabled =
          TunnelConfig.build(
                profile: VlessProfile.parse(link),
                russianServicesDirect: false,
              ).json['routing']['rules']
              as List;
      expect(
        disabled.any(
          (r) =>
              r['domain'] is List &&
              (r['domain'] as List).contains('domain:vk.com'),
        ),
        isFalse,
      );
      final custom =
          TunnelConfig.build(
                profile: VlessProfile.parse(link),
                rules: [
                  RoutingRule.parse(
                    RuleKind.domain,
                    'vk.com',
                    RuleAction.block,
                  ),
                ],
              ).json['routing']['rules']
              as List;
      final customBlock = custom.indexWhere(
        (rule) =>
            rule['domain'] is List &&
            (rule['domain'] as List).contains('domain:vk.com') &&
            rule['outboundTag'] == 'block',
      );
      final presetDirect = custom.indexWhere(
        (rule) =>
            rule['domain'] is List &&
            (rule['domain'] as List).contains('domain:vk.com') &&
            rule['outboundTag'] == 'direct',
      );
      expect(customBlock, greaterThanOrEqualTo(0));
      expect(customBlock, lessThan(presetDirect));
    },
  );
  test(
    'config keeps TLS verification, credentials stay out of display and DNS inside VPN',
    () {
      final c = TunnelConfig.build(
        profile: VlessProfile.parse(link),
        russianServicesDirect: false,
        rules: [
          RoutingRule.parse(RuleKind.domain, 'example.org', RuleAction.block),
          RoutingRule.parse(RuleKind.port, '53', RuleAction.direct),
          RoutingRule.parse(
            RuleKind.subnet,
            '10.0.0.0/8',
            RuleAction.direct,
            enabled: false,
          ),
        ],
      );
      final outbound = (c.json['outbounds'] as List).first as Map;
      expect(
        outbound['streamSettings']['tlsSettings']['serverName'],
        'cdn.example.invalid',
      );
      expect(
        outbound['streamSettings']['tlsSettings'].containsKey('allowInsecure'),
        false,
      );
      final rules = c.json['routing']['rules'] as List;
      expect(rules[0]['outboundTag'], 'block');
      expect(rules[0]['ip'], ['::/0']);
      expect(rules[1]['inboundTag'], ['dns-internal']);
      expect(rules[1]['outboundTag'], 'proxy');
      expect(rules[2]['port'], '53');
      expect(rules[2]['outboundTag'], 'dns-out');
      expect(rules[3]['ip'], ['26.26.26.2']);
      expect(rules[3]['port'], '853');
      expect(rules[3]['outboundTag'], 'block');
      expect(rules[4]['port'], '853');
      expect(rules[4]['outboundTag'], 'proxy');
      expect(rules[5]['domain'], ['domain:example.org']);
      expect(rules.length, 7);
      expect(c.json['dns']['servers'], ['https://1.1.1.1/dns-query']);
      expect(c.json['dns']['queryStrategy'], 'UseIPv4');
      final dnsOutbound = (c.json['outbounds'] as List).singleWhere(
        (outbound) => outbound['tag'] == 'dns-out',
      );
      expect(dnsOutbound['protocol'], 'dns');
      expect(dnsOutbound['settings']['rules'], [
        {'action': 'return', 'qType': 28, 'rCode': 0},
      ]);
      final customDns = TunnelConfig.build(
        profile: VlessProfile.parse(link),
        dns: '9.9.9.9',
      );
      expect(customDns.json['dns']['servers'], ['9.9.9.9']);
      expect(c.toString(), isNot(contains('00000000')));
      expect(
        VlessProfile.parse(
          VlessProfile.parse(link).toShareLink(),
        ).parameters['path'],
        '/vpn',
      );
    },
  );
  test('native app modes do not widen an empty allow-list', () {
    expect(
      () => TunnelConfig.build(
        profile: VlessProfile.parse(link),
        appMode: 'only',
      ),
      throwsFormatException,
    );
    final c = TunnelConfig.build(
      profile: VlessProfile.parse(link),
      appMode: 'only',
      applications: {'com.example.browser'},
      mtu: 1280,
    );
    expect(c.allowedApps, ['com.example.browser']);
    expect(c.excludedApps, isEmpty);
    expect(c.json['inbounds'][0]['settings']['MTU'], 1280);
    final except = TunnelConfig.build(
      profile: VlessProfile.parse(link),
      appMode: 'except',
      applications: {'com.example.browser'},
    );
    expect(except.allowedApps, isNull);
    expect(except.excludedApps, ['com.example.browser']);
    expect(
      () => TunnelConfig.build(profile: VlessProfile.parse(link), strict: true),
      throwsFormatException,
    );
    expect(
      () => TunnelConfig.build(
        profile: VlessProfile.parse(link),
        dns: 'dns.example.org',
      ),
      throwsFormatException,
    );
  });
  test('REALITY and XHTTP generate distinct encrypted transports', () {
    final reality = VlessProfile.parse(
      'vless://00000000-0000-4000-8000-000000000001@example.invalid:443?type=tcp&security=reality&flow=xtls-rprx-vision&sni=example.org&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=abcd',
    );
    final stream = TunnelConfig.build(
      profile: reality,
    ).json['outbounds'][0]['streamSettings'];
    expect(stream['network'], 'raw');
    expect(stream['realitySettings']['shortId'], 'abcd');
    expect(stream['realitySettings']['password'], hasLength(43));
    final xhttp = VlessProfile.parse(
      link.replaceFirst('type=ws', 'type=xhttp&mode=stream-up'),
    );
    expect(
      TunnelConfig.build(
        profile: xhttp,
      ).json['outbounds'][0]['streamSettings']['xhttpSettings']['mode'],
      'stream-up',
    );
  });
  test(
    'start acknowledgement is never presented as native connection success',
    () async {
      final engine = TestEngine();
      final controller = TunnelController(engine);
      addTearDown(controller.dispose);
      await controller.connect(config(), 'Test');
      expect(controller.phase, TunnelPhase.connecting);
      engine.controller.add(
        const TunnelStats('CONNECTED', duration: '00:00:05', upload: 1024),
      );
      expect(controller.phase, TunnelPhase.active);
      expect(controller.stats.upload, 1024);
      engine.controller.add(const TunnelStats('DISCONNECTED'));
      expect(controller.phase, TunnelPhase.disconnected);
    },
  );
  test(
    'permission denial never starts a service; unavailable desktop never asks permission',
    () async {
      final engine = TestEngine()..permission = false;
      final controller = TunnelController(engine);
      addTearDown(controller.dispose);
      await controller.connect(config(), 'Test');
      expect(engine.starts, 0);
      expect(controller.phase, TunnelPhase.disconnected);
      final desktop = TestEngine()..supported = false;
      final other = TunnelController(desktop);
      addTearDown(other.dispose);
      await other.connect(config(), 'Test');
      expect(desktop.requests, 0);
      expect(other.phase, TunnelPhase.unavailable);
    },
  );
  test('failure is sanitized and retry can start another session', () async {
    final engine = TestEngine()..fail = true;
    final controller = TunnelController(engine);
    addTearDown(controller.dispose);
    await controller.connect(config(), 'Test');
    expect(controller.phase, TunnelPhase.failed);
    expect(controller.error, isNot(contains('secret')));
    engine.fail = false;
    await controller.connect(config(), 'Test');
    expect(engine.starts, 2);
    expect(controller.phase, TunnelPhase.connecting);
  });
  testWidgets(
    'timeout stops service; late connected event cannot turn failure into success',
    (tester) async {
      final engine = TestEngine();
      final controller = TunnelController(engine);
      addTearDown(controller.dispose);
      await controller.connect(
        config(),
        'Test',
        timeout: const Duration(seconds: 1),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(controller.phase, TunnelPhase.failed);
      expect(engine.stops, 1);
      engine.controller.add(const TunnelStats('CONNECTED'));
      await tester.pump();
      expect(controller.phase, TunnelPhase.failed);
      expect(engine.stops, 2);
    },
  );
}
