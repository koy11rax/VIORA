import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/data/subscription_import.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/domain/tunnel_config.dart';
import 'package:viora_client/features/client/client_page.dart';
import 'package:viora_client/platform/tunnel.dart';

const _firstSource = 'https://first.example.invalid/sub/fixture';
const _secondSource = 'https://second.example.invalid/sub/fixture';

VlessProfile _profile(String name) => VlessProfile.parse(
  'vless://00000000-0000-4000-8000-000000000001@$name.example.invalid:443?type=ws&security=tls#$name',
);

VlessProfile _transport(
  String transport,
  String name, {
  String host = 'node.example.invalid',
  String uuid = '00000000-0000-4000-8000-000000000001',
  String path = '/original',
  bool reversed = false,
}) {
  final query = transport == 'tcp'
      ? 'type=tcp&security=reality&flow=xtls-rprx-vision&sni=example.invalid&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=abcd'
      : reversed
      ? 'sni=example.invalid&path=${Uri.encodeQueryComponent(path)}&security=tls&type=$transport'
      : 'type=$transport&security=tls&path=${Uri.encodeQueryComponent(path)}&sni=example.invalid';
  return VlessProfile.parse(
    'vless://$uuid@$host:443?$query#${Uri.encodeComponent(name)}',
  );
}

class _Engine implements TunnelEngine {
  final eventsController = StreamController<TunnelStats>.broadcast(sync: true);
  final starts = <TunnelConfig>[];
  final names = <String>[];
  int stops = 0;
  bool acknowledgeStop = true;
  Completer<void>? startGate;
  Completer<void>? stopGate;

  @override
  bool get supported => true;
  @override
  Stream<TunnelStats> get events => eventsController.stream;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> start(TunnelConfig config, String name) async {
    starts.add(config);
    names.add(name);
    final gate = startGate;
    startGate = null;
    if (gate != null) await gate.future;
    eventsController.add(const TunnelStats('CONNECTED'));
  }

  @override
  Future<void> stop() async {
    stops++;
    final gate = stopGate;
    stopGate = null;
    if (gate != null) await gate.future;
    if (acknowledgeStop) {
      eventsController.add(const TunnelStats('DISCONNECTED'));
    }
  }
}

Future<(ClientState, _Engine, GlobalKey<ClientPageState>)> _mount(
  WidgetTester tester,
  Future<ImportedConnection> Function(String) load, {
  List<VlessProfile>? initialProfiles,
  Map<String, List<String>>? initialSources,
  int selected = 0,
}) async {
  tester.view.physicalSize = const Size(1440, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final engine = _Engine();
  final tunnel = TunnelController(engine);
  final state = ClientState(tunnel: tunnel);
  addTearDown(() async {
    tunnel.dispose();
    state.account.dispose();
    await engine.eventsController.close();
  });
  state.profiles.addAll(
    initialProfiles ?? [_profile('old-active'), _profile('user-choice')],
  );
  state.selectedProfile = selected;
  state.subscriptions.addAll(
    initialSources ??
        {
          _firstSource: [state.profiles[0].toShareLink()],
          _secondSource: [state.profiles[1].toShareLink()],
        },
  );
  final key = GlobalKey<ClientPageState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ClientPage(
            key: key,
            index: 1,
            desktop: true,
            state: state,
            mode: ThemeMode.dark,
            onTheme: (_) {},
            onAccent: (_) {},
            onNavigate: (_) {},
            onRepository: (_) async {},
            loadSubscription: load,
          ),
        ),
      ),
    ),
  );
  return (state, engine, key);
}

Future<void> _connect(ClientState state) => state.tunnel.connect(
  state.selectedTunnelConfig(),
  state.profiles[state.selectedProfile].name,
);

String _endpoint(TunnelConfig config) =>
    config.json['outbounds'][0]['settings']['vnext'][0]['address'] as String;

void main() {
  testWidgets(
    'an exact existing link wins over ambiguous replacement candidates',
    (tester) async {
      final previous = _transport('xhttp', 'Chosen');
      final alternative = _transport('xhttp', 'Chosen', path: '/different');
      final imported = [_transport('ws', 'WS'), alternative, previous];
      final (state, engine, key) = await _mount(
        tester,
        (source) async => ImportedConnection(imported, source: source),
        initialProfiles: [previous],
        initialSources: {
          _firstSource: [previous.toShareLink()],
        },
      );
      await _connect(state);
      await key.currentState!.refreshSubscriptions(silent: true);
      expect(
        state.profiles[state.selectedProfile].toShareLink(),
        previous.toShareLink(),
      );
      expect(engine.stops, 0);
      expect(engine.starts, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'selected XHTTP survives UUID, settings and name rotation among all three transports',
    (tester) async {
      final original = [
        _transport('ws', 'WS'),
        _transport('xhttp', 'XHTTP'),
        _transport('tcp', 'REALITY'),
      ];
      final changed = [
        original[0],
        _transport(
          'xhttp',
          'Renamed XHTTP',
          host: 'NODE.EXAMPLE.INVALID',
          uuid: '00000000-0000-4000-8000-000000000002',
          path: '/rotated',
        ),
        original[2],
      ];
      final (state, engine, key) = await _mount(
        tester,
        (source) async => ImportedConnection(changed, source: source),
        initialProfiles: original,
        selected: 1,
        initialSources: {
          _firstSource: original
              .map((profile) => profile.toShareLink())
              .toList(),
        },
      );
      await _connect(state);
      await key.currentState!.refreshSubscriptions(silent: true);
      expect(
        state.profiles[state.selectedProfile].toShareLink(),
        changed[1].toShareLink(),
      );
      expect(state.profiles[state.selectedProfile].transport, 'xhttp');
      expect(engine.starts, hasLength(2));
      final outbound = engine.starts.last.json['outbounds'][0];
      expect(
        outbound['settings']['vnext'][0]['users'][0]['id'],
        changed[1].uuid,
      );
      expect(outbound['streamSettings']['xhttpSettings']['path'], '/rotated');
      expect(outbound['streamSettings']['network'], 'xhttp');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'query parameter order changes do not reset XHTTP selection to first WS',
    (tester) async {
      final original = [
        _transport('ws', 'WS'),
        _transport('xhttp', 'XHTTP'),
        _transport('tcp', 'REALITY'),
      ];
      final reordered = _transport('xhttp', 'XHTTP', reversed: true);
      expect(reordered.toShareLink(), isNot(original[1].toShareLink()));
      final (state, _, key) = await _mount(
        tester,
        (source) async => ImportedConnection([
          original[0],
          reordered,
          original[2],
        ], source: source),
        initialProfiles: original,
        selected: 1,
        initialSources: {
          _firstSource: original
              .map((profile) => profile.toShareLink())
              .toList(),
        },
      );
      await key.currentState!.refreshSubscriptions(silent: true);
      expect(
        state.profiles[state.selectedProfile].toShareLink(),
        reordered.toShareLink(),
      );
      expect(state.selectedProfile, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('unique endpoint takes priority over a same-name alternative', (
    tester,
  ) async {
    final previous = _transport('xhttp', 'Chosen');
    final endpointMatch = _transport('xhttp', 'Renamed', path: '/new');
    final nameMatch = _transport(
      'xhttp',
      'Chosen',
      host: 'other.example.invalid',
    );
    final imported = [_transport('ws', 'WS'), endpointMatch, nameMatch];
    final (state, _, key) = await _mount(
      tester,
      (source) async => ImportedConnection(imported, source: source),
      initialProfiles: [previous],
      initialSources: {
        _firstSource: [previous.toShareLink()],
      },
    );
    await key.currentState!.refreshSubscriptions(silent: true);
    expect(
      state.profiles[state.selectedProfile].toShareLink(),
      endpointMatch.toShareLink(),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'unique name preserves selection after endpoint rotation among multiple XHTTP servers',
    (tester) async {
      final previous = _transport('xhttp', 'Chosen');
      final nameMatch = _transport(
        'xhttp',
        'Chosen',
        host: 'new.example.invalid',
      );
      final imported = [
        _transport('ws', 'WS'),
        _transport('xhttp', 'Other', host: 'other.example.invalid'),
        nameMatch,
      ];
      final (state, _, key) = await _mount(
        tester,
        (source) async => ImportedConnection(imported, source: source),
        initialProfiles: [previous],
        initialSources: {
          _firstSource: [previous.toShareLink()],
        },
      );
      await key.currentState!.refreshSubscriptions(silent: true);
      expect(
        state.profiles[state.selectedProfile].toShareLink(),
        nameMatch.toShareLink(),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'unique transport and security preserve selection when both endpoint and name rotate',
    (tester) async {
      final previous = _transport('xhttp', 'Chosen');
      final replacement = _transport(
        'xhttp',
        'Renamed',
        host: 'new.example.invalid',
      );
      final imported = [
        _transport('ws', 'WS'),
        replacement,
        _transport('tcp', 'REALITY'),
      ];
      final (state, _, key) = await _mount(
        tester,
        (source) async => ImportedConnection(imported, source: source),
        initialProfiles: [previous],
        initialSources: {
          _firstSource: [previous.toShareLink()],
        },
      );
      await key.currentState!.refreshSubscriptions(silent: true);
      expect(
        state.profiles[state.selectedProfile].toShareLink(),
        replacement.toShareLink(),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'replacement never matches another provider and a new source never steals selection',
    (tester) async {
      final previous = _transport('xhttp', 'Chosen');
      final foreign = _transport('xhttp', 'Foreign', path: '/foreign');
      final fallback = _transport('ws', 'WS');
      final (state, engine, key) = await _mount(
        tester,
        (source) async => ImportedConnection(
          source == _firstSource ? [fallback] : [foreign],
          source: source,
        ),
        initialProfiles: [previous, foreign],
        initialSources: {
          _firstSource: [previous.toShareLink()],
          _secondSource: [foreign.toShareLink()],
        },
      );
      await _connect(state);
      await key.currentState!.refreshSubscriptions(silent: true);
      expect(
        state.profiles[state.selectedProfile].toShareLink(),
        fallback.toShareLink(),
      );
      expect(
        engine.starts.last.json['outbounds'][0]['streamSettings']['network'],
        'ws',
      );
      final current = state.profiles[state.selectedProfile].toShareLink();
      key.currentState!.applyImport(
        ImportedConnection([
          _transport('ws', 'New provider'),
        ], source: 'https://third.example.invalid/sub/fixture'),
        silent: true,
      );
      expect(state.profiles[state.selectedProfile].toShareLink(), current);
      key.currentState!.applyImport(
        ImportedConnection([_transport('ws', 'Manual')]),
        silent: true,
      );
      expect(state.profiles[state.selectedProfile].toShareLink(), current);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'ambiguous incoming replacements retain the first incoming fallback',
    (tester) async {
      final previous = _transport('xhttp', 'Chosen');
      final imported = [
        _transport('ws', 'Fallback'),
        _transport('xhttp', 'Chosen', host: 'one.example.invalid'),
        _transport('xhttp', 'Chosen', host: 'two.example.invalid'),
      ];
      final (state, _, key) = await _mount(
        tester,
        (source) async => ImportedConnection(imported, source: source),
        initialProfiles: [previous],
        initialSources: {
          _firstSource: [previous.toShareLink()],
        },
      );
      await key.currentState!.refreshSubscriptions(silent: true);
      expect(
        state.profiles[state.selectedProfile].toShareLink(),
        imported.first.toShareLink(),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'refresh during delayed reconciliation is rejected and cannot replace the captured config',
    (tester) async {
      var requests = 0, firstProviderRequests = 0;
      final (state, engine, key) = await _mount(tester, (source) async {
        requests++;
        if (source == _firstSource) {
          firstProviderRequests++;
          return ImportedConnection([
            _profile(
              firstProviderRequests == 1 ? 'updated-active' : 'newest-active',
            ),
          ], source: source);
        }
        return ImportedConnection([_profile('user-choice')], source: source);
      });
      await _connect(state);
      final stopped = Completer<void>();
      engine.stopGate = stopped;
      final refreshed = key.currentState!.refreshSubscriptions(silent: true);
      await tester.pump();
      expect(engine.stops, 1);
      expect(engine.starts, hasLength(1));
      expect(state.tunnel.phase, TunnelPhase.stopping);
      expect(state.profiles[state.selectedProfile].name, 'updated-active');
      await key.currentState!.refreshSubscriptions(silent: true);
      expect(requests, 2);
      expect(firstProviderRequests, 1);
      expect(state.profiles[state.selectedProfile].name, 'updated-active');
      stopped.complete();
      await refreshed;
      expect(engine.starts, hasLength(2));
      expect(
        _endpoint(engine.starts.last),
        state.profiles[state.selectedProfile].host,
      );
      expect(_endpoint(engine.starts.last), 'updated-active.example.invalid');
      // A later request is allowed after reconciliation has actually finished.
      await key.currentState!.refreshSubscriptions(silent: true);
      expect(requests, 4);
      expect(firstProviderRequests, 2);
      expect(engine.starts, hasLength(3));
      expect(
        _endpoint(engine.starts.last),
        state.profiles[state.selectedProfile].host,
      );
      expect(_endpoint(engine.starts.last), 'newest-active.example.invalid');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'rotation reconnects once after all sources and native stop acknowledgement',
    (tester) async {
      final (state, engine, key) = await _mount(tester, (source) async {
        return ImportedConnection([
          _profile(source == _firstSource ? 'updated-active' : 'updated-other'),
        ], source: source);
      });
      await _connect(state);
      engine.acknowledgeStop = false;
      final refreshed = key.currentState!.refreshSubscriptions(silent: true);
      await tester.pump();
      expect(engine.stops, 1);
      expect(engine.starts, hasLength(1));
      expect(state.subscriptions[_secondSource], [
        _profile('updated-other').toShareLink(),
      ]);
      engine.eventsController.add(const TunnelStats('DISCONNECTED'));
      await refreshed;
      expect(engine.starts, hasLength(2));
      expect(_endpoint(engine.starts.last), 'updated-active.example.invalid');
      expect(state.profiles[state.selectedProfile].name, 'updated-active');
      expect(state.tunnel.phase, TunnelPhase.active);
      expect(key.currentState!.message, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'unchanged active profile and unrelated provider updates keep the connection',
    (tester) async {
      final (state, engine, key) = await _mount(tester, (source) async {
        return ImportedConnection([
          _profile(source == _firstSource ? 'old-active' : 'updated-other'),
        ], source: source);
      });
      await _connect(state);
      await key.currentState!.refreshSubscriptions(silent: true);
      expect(engine.starts, hasLength(1));
      expect(engine.stops, 0);
      expect(state.profiles[state.selectedProfile].name, 'old-active');
      expect(state.subscriptions[_secondSource], [
        _profile('updated-other').toShareLink(),
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'rotation while start is busy retains data and reconnects once it settles',
    (tester) async {
      final (state, engine, key) = await _mount(tester, (source) async {
        return ImportedConnection([
          _profile(source == _firstSource ? 'updated-active' : 'user-choice'),
        ], source: source);
      });
      final gate = Completer<void>();
      engine.startGate = gate;
      final started = _connect(state);
      await tester.pump();
      expect(state.tunnel.busy, isTrue);
      await key.currentState!.refreshSubscriptions(silent: true);
      expect(engine.stops, 0);
      expect(state.profiles[state.selectedProfile].name, 'updated-active');
      gate.complete();
      await started;
      await tester.pump();
      expect(engine.stops, 1);
      expect(engine.starts, hasLength(2));
      expect(_endpoint(engine.starts.last), 'updated-active.example.invalid');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('manual disconnect during refresh cancels deferred reconnect', (
    tester,
  ) async {
    final second = Completer<ImportedConnection>();
    final (state, engine, key) = await _mount(tester, (source) async {
      if (source == _secondSource) return second.future;
      return ImportedConnection([_profile('updated-active')], source: source);
    });
    await _connect(state);
    final refreshed = key.currentState!.refreshSubscriptions(silent: true);
    await tester.pump();
    await key.currentState!.toggleTunnel();
    second.complete(
      ImportedConnection([_profile('user-choice')], source: _secondSource),
    );
    await refreshed;
    await tester.pump();
    expect(engine.stops, 1);
    expect(engine.starts, hasLength(1));
    expect(state.tunnel.phase, TunnelPhase.disconnected);
    expect(state.profiles[state.selectedProfile].name, 'updated-active');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'explicit server selection wins over an earlier refresh replacement',
    (tester) async {
      final second = Completer<ImportedConnection>();
      final (state, engine, key) = await _mount(tester, (source) async {
        if (source == _secondSource) return second.future;
        return ImportedConnection([_profile('updated-active')], source: source);
      });
      await _connect(state);
      final refreshed = key.currentState!.refreshSubscriptions(silent: true);
      await tester.pump();
      final chosen = state.profiles.indexWhere(
        (profile) => profile.name == 'user-choice',
      );
      await key.currentState!.selectServer(chosen);
      second.complete(
        ImportedConnection([_profile('user-choice')], source: _secondSource),
      );
      await refreshed;
      await tester.pump();
      expect(engine.starts, hasLength(2));
      expect(engine.stops, 1);
      expect(_endpoint(engine.starts.last), 'user-choice.example.invalid');
      expect(state.profiles[state.selectedProfile].name, 'user-choice');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed subscriptions retain the active config and never reconnect',
    (tester) async {
      final (state, engine, key) = await _mount(tester, (_) async {
        throw const FormatException('fixture unavailable');
      });
      await _connect(state);
      final original = state.profiles
          .map((profile) => profile.toShareLink())
          .toList();
      await key.currentState!.refreshSubscriptions(silent: true);
      expect(state.profiles.map((profile) => profile.toShareLink()), original);
      expect(engine.starts, hasLength(1));
      expect(engine.stops, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('unmount cancels deferred refresh reconciliation', (
    tester,
  ) async {
    final (state, engine, key) = await _mount(tester, (source) async {
      return ImportedConnection([
        _profile(source == _firstSource ? 'updated-active' : 'user-choice'),
      ], source: source);
    });
    final gate = Completer<void>();
    engine.startGate = gate;
    final started = _connect(state);
    await tester.pump();
    await key.currentState!.refreshSubscriptions(silent: true);
    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete();
    await started;
    await tester.pump();
    expect(engine.starts, hasLength(1));
    expect(engine.stops, 0);
    expect(tester.takeException(), isNull);
  });
}
