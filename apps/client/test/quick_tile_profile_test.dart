import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/domain/routing.dart';
import 'package:viora_client/domain/tunnel_config.dart';
import 'package:viora_client/features/client/client_page.dart';

// Only domain objects are exercised. No engine initialization, platform call,
// real profile, permission prompt, account request or VPN connection is used.
final _first = VlessProfile.parse(
  'vless://00000000-0000-4000-8000-000000000001@first.example.invalid:443?type=ws&security=tls&path=%2Ffirst#First%20profile',
);
final _second = VlessProfile.parse(
  'vless://00000000-0000-4000-8000-000000000002@second.example.invalid:8443?type=xhttp&security=tls&path=%2Fsecond&mode=packet-up#Second%20profile',
);

ClientState _state() {
  final state = ClientState()
    ..selectedProfile = 0
    ..profiles.addAll([_first, _second]);
  addTearDown(() {
    state.tunnel.dispose();
    state.account.dispose();
  });
  return state;
}

Map<String, dynamic> _cache(ClientState state) {
  final result = state.quickTileProfile();
  expect(result, isNotNull);
  return result!;
}

Map<String, dynamic> _decoded(Map<String, dynamic> profile) =>
    jsonDecode(profile['config'] as String) as Map<String, dynamic>;

void _refused(ClientState state) {
  expect(state.selectedTunnelConfig, throwsFormatException);
  expect(state.quickTileProfile(), isNull);
}

void main() {
  group('current selected profile for background quick tile', () {
    test(
      'cache matches the exact domain configuration including security policy',
      () {
        final state = _state()
          ..appMode = 'only'
          ..applications.addAll([
            'org.telegram.messenger',
            'com.example.browser',
          ])
          ..lan = true
          ..reconnect = false
          ..rules.addAll([
            RoutingRule.parse(
              RuleKind.domain,
              'blocked.example.org',
              RuleAction.block,
            ),
            RoutingRule.parse(
              RuleKind.subnet,
              '203.0.113.0/24',
              RuleAction.direct,
            ),
            RoutingRule.parse(RuleKind.port, '8443', RuleAction.vpn),
            RoutingRule.parse(
              RuleKind.domain,
              'disabled.example.org',
              RuleAction.direct,
              enabled: false,
            ),
          ]);
        state.options.addAll({
          'dns': 'custom',
          'dnsAddress': '9.9.9.9',
          'mtu': '1420',
          'retry': '5',
          'protection': 'strict',
          'russianServicesDirect': false,
        });
        final expected = TunnelConfig.build(
          profile: _first,
          rules: state.rules,
          appMode: 'only',
          applications: state.applications,
          localNetwork: true,
          russianServicesDirect: false,
          dns: '9.9.9.9',
          mtu: 1420,
          strict: true,
          reconnect: false,
          retries: 5,
        );

        final cached = _cache(state);
        final decoded = _decoded(cached);

        expect(
          cached.keys,
          unorderedEquals([
            'version',
            'name',
            'config',
            'allowed',
            'blocked',
            'mtu',
            'reconnect',
            'retries',
            'strict',
          ]),
        );
        expect(cached['version'], 1);
        expect(cached['name'], 'First profile');
        expect(decoded, expected.json);
        expect(state.selectedTunnelConfig().json, expected.json);
        expect(cached['allowed'], unorderedEquals(state.applications));
        expect(cached['blocked'], isEmpty);
        expect(cached['mtu'], 1420);
        expect(cached['reconnect'], isFalse);
        expect(cached['retries'], 5);
        expect(cached['strict'], isTrue);
        expect(decoded['dns']['servers'], ['9.9.9.9']);
        final routing = decoded['routing']['rules'] as List;
        expect(
          routing,
          contains(containsPair('domain', ['domain:blocked.example.org'])),
        );
        expect(routing, contains(containsPair('ip', ['203.0.113.0/24'])));
        expect(routing, contains(containsPair('port', '8443')));
        expect(
          routing,
          contains(
            containsPair('ip', [
              '10.0.0.0/8',
              '172.16.0.0/12',
              '192.168.0.0/16',
            ]),
          ),
        );
        expect(
          routing,
          isNot(
            contains(containsPair('domain', ['domain:disabled.example.org'])),
          ),
        );
        expect(
          routing.expand((r) => (r as Map)['domain'] as List? ?? []),
          isNot(contains('domain:ru')),
        );
      },
    );

    test(
      'changing the selected server replaces both its label and connection payload',
      () {
        final state = _state();
        final firstCache = _cache(state);
        state.selectedProfile = 1;

        final secondCache = _cache(state);
        final decoded = _decoded(secondCache);
        final proxy = (decoded['outbounds'] as List).first as Map;
        final endpoint = proxy['settings']['vnext'][0];

        expect(secondCache['name'], 'Second profile');
        expect(secondCache['config'], isNot(firstCache['config']));
        expect(endpoint['address'], 'second.example.invalid');
        expect(endpoint['port'], 8443);
        expect(endpoint['users'][0]['id'], _second.uuid);
        expect(proxy['streamSettings']['network'], 'xhttp');
        expect(proxy['streamSettings']['xhttpSettings']['path'], '/second');
        expect(firstCache['name'], 'First profile');
      },
    );

    test(
      'only, except and all app policies never retain a previous routing list',
      () {
        final state = _state()
          ..appMode = 'only'
          ..applications.add('org.telegram.messenger');
        final only = _cache(state);
        expect(only['allowed'], ['org.telegram.messenger']);
        expect(only['blocked'], isEmpty);

        state.appMode = 'except';
        final except = _cache(state);
        expect(except['allowed'], isNull);
        expect(except['blocked'], ['org.telegram.messenger']);

        state.appMode = 'all';
        final all = _cache(state);
        expect(all['allowed'], isNull);
        expect(all['blocked'], isEmpty);
        expect(only['allowed'], ['org.telegram.messenger']);
        expect(except['blocked'], ['org.telegram.messenger']);
      },
    );

    test('cache is rebuilt after app, DNS, rule and strict-mode changes', () {
      final state = _state()
        ..appMode = 'only'
        ..applications.add('org.telegram.messenger');
      final previous = _cache(state);
      state.applications
        ..clear()
        ..add('com.example.browser');
      state.rules.add(
        RoutingRule.parse(RuleKind.domain, 'new.example.org', RuleAction.block),
      );
      state.options.addAll({
        'dns': 'custom',
        'dnsAddress': '1.0.0.1',
        'mtu': '1280',
        'retry': '5',
        'protection': 'strict',
      });
      state.reconnect = false;

      final current = _cache(state);

      expect(current['allowed'], ['com.example.browser']);
      expect(current['config'], isNot(previous['config']));
      expect(_decoded(current), state.selectedTunnelConfig().json);
      expect(_decoded(current)['dns']['servers'], ['1.0.0.1']);
      expect(current['strict'], isTrue);
      expect(current['mtu'], 1280);
      expect(current['retries'], 5);
      expect(current['reconnect'], isFalse);
      expect(previous['allowed'], ['org.telegram.messenger']);
      expect(previous['strict'], isFalse);
      expect(previous['mtu'], 1500);
      expect(previous['retries'], 3);
      expect(previous['reconnect'], isTrue);
    });

    test(
      'no selection, removed selection and empty profile list explicitly clear old cache',
      () {
        final state = _state();
        expect(state.quickTileProfile(), isNotNull);
        for (final index in [-1, state.profiles.length, 100]) {
          state.selectedProfile = index;
          _refused(state);
        }
        state.selectedProfile = 0;
        expect(state.quickTileProfile(), isNotNull);
        state.profiles.clear();
        _refused(state);
      },
    );

    test(
      'an invalid selected profile clears the valid predecessor instead of falling back',
      () {
        final state = _state();
        expect(state.quickTileProfile(), isNotNull);
        // Parsing identifies a REALITY profile, but the domain builder rejects
        // this deliberately invalid public-key length before it can be cached.
        state.profiles.add(
          VlessProfile.parse(
            'vless://00000000-0000-4000-8000-000000000003@invalid.example.invalid:443?type=tcp&security=reality&sni=example.invalid&pbk=invalid&flow=xtls-rprx-vision',
          ),
        );
        state.selectedProfile = 2;

        _refused(state);
      },
    );

    test(
      'invalid or empty app selection clears cache instead of widening to all apps',
      () {
        final state = _state();
        expect(state.quickTileProfile(), isNotNull);
        for (final mode in ['only', 'except']) {
          state.appMode = mode;
          state.applications.clear();
          _refused(state);
          for (final invalid in [
            'invalid',
            '../outside',
            'dev.viora.viora_client',
          ]) {
            state.applications
              ..clear()
              ..add(invalid);
            _refused(state);
          }
        }
        state.appMode = 'unsupported';
        _refused(state);
      },
    );

    test('invalid custom DNS cannot keep an earlier working profile', () {
      final state = _state();
      expect(state.quickTileProfile(), isNotNull);
      state.options['dns'] = 'custom';
      for (final address in ['', 'not-an-address', '2001:db8::1']) {
        state.options['dnsAddress'] = address;
        _refused(state);
      }
    });

    test('invalid MTU and retry values clear the background profile', () {
      final state = _state();
      expect(state.quickTileProfile(), isNotNull);
      for (final mtu in ['9000', 'not-a-number']) {
        state.options['mtu'] = mtu;
        _refused(state);
      }
      state.options['mtu'] = 'auto';
      for (final retries in ['0', '6', 'not-a-number']) {
        state.options['retry'] = retries;
        _refused(state);
      }
    });

    test(
      'returning from invalid state creates the new valid selection, not old cache',
      () {
        final state = _state();
        final oldCache = _cache(state);
        state.appMode = 'only';
        _refused(state);
        state.selectedProfile = 1;
        state.applications.add('com.example.browser');
        state.options['protection'] = 'strict';

        final recovered = _cache(state);

        expect(recovered['name'], 'Second profile');
        expect(recovered['config'], isNot(oldCache['config']));
        expect(recovered['allowed'], ['com.example.browser']);
        expect(recovered['strict'], isTrue);
        expect(_decoded(recovered), state.selectedTunnelConfig().json);
      },
    );
  });
}
