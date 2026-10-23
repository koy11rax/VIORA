import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/domain/tunnel_config.dart';
import 'package:viora_client/features/client/client_page.dart';
import 'package:viora_client/platform/tunnel.dart';

class _Engine implements TunnelEngine {
  @override
  bool get supported => true;
  @override
  Stream<TunnelStats> get events => const Stream.empty();
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> start(TunnelConfig config, String name) async {}
  @override
  Future<void> stop() async {}
}

Future<(ClientState, GlobalKey<ClientPageState>)> _mount(
  WidgetTester tester, {
  Future<int?> Function()? probe,
  Future<int> Function(String, int)? tcp,
  TunnelPhase phase = TunnelPhase.active,
}) async {
  tester.view.physicalSize = const Size(1440, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final tunnel = TunnelController(_Engine())..phase = phase;
  final state = ClientState(tunnel: tunnel);
  addTearDown(tunnel.dispose);
  addTearDown(state.account.dispose);
  state.profiles.addAll([
    for (final name in ['first', 'second'])
      VlessProfile.parse(
        'vless://00000000-0000-4000-8000-000000000001@$name.example.invalid:443?type=ws&security=tls#$name',
      ),
  ]);
  state.selectedProfile = 0;
  final key = GlobalKey<ClientPageState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ClientPage(
            key: key,
            index: 0,
            desktop: true,
            state: state,
            mode: ThemeMode.dark,
            onTheme: (_) {},
            onAccent: (_) {},
            onNavigate: (_) {},
            onRepository: (_) async {},
            connectedProbe: probe,
            measureLatency: tcp ?? (_, _) async => 71,
          ),
        ),
      ),
    ),
  );
  return (state, key);
}

void main() {
  testWidgets(
    'active connection reports port reachability and core response separately',
    (tester) async {
      var probes = 0;
      final (state, key) = await _mount(
        tester,
        probe: () async {
          probes++;
          return 234;
        },
      );
      await key.currentState!.checkLatency();
      expect(probes, 1);
      expect(state.latency[state.profiles[0].toShareLink()], 71);
      expect(key.currentState!.message, contains('TCP-порт доступен: 71 мс'));
      expect(
        key.currentState!.message,
        contains('через VPN ответил за 234 мс'),
      );
      expect(state.tunnel.phase, TunnelPhase.active);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final throwsError in [false, true]) {
    testWidgets(
      'unconfirmed core response keeps TCP result and avoids general outage claim ($throwsError)',
      (tester) async {
        final (state, key) = await _mount(
          tester,
          probe: () async {
            if (throwsError) throw StateError('Native detail');
            return null;
          },
        );
        await key.currentState!.checkLatency();
        expect(state.latency[state.profiles[0].toShareLink()], 71);
        expect(
          key.currentState!.message,
          contains(
            'TCP-порт доступен, но нет ответа тестового сайта через VPN',
          ),
        );
        expect(
          key.currentState!.message,
          contains('может быть недоступен отдельно'),
        );
        expect(key.currentState!.message, isNot(contains('Native detail')));
        expect(
          key.currentState!.message,
          isNot(contains('TCP-порт сервера не ответил')),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'disconnected VPN tests TCP only and never invokes the core probe',
    (tester) async {
      var probes = 0;
      final (_, key) = await _mount(
        tester,
        phase: TunnelPhase.disconnected,
        probe: () async {
          probes++;
          return 2;
        },
      );
      await key.currentState!.checkLatency();
      expect(probes, 0);
      expect(
        key.currentState!.message,
        contains('не подтверждает передачу данных через VPN'),
      );
      expect(key.currentState!.message, isNot(contains('текущий маршрут')));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('busy VPN rejects measurement before any network work', (
    tester,
  ) async {
    var tcpCalls = 0, probes = 0;
    final (_, key) = await _mount(
      tester,
      phase: TunnelPhase.permission,
      tcp: (_, _) async {
        tcpCalls++;
        return 71;
      },
      probe: () async {
        probes++;
        return 2;
      },
    );
    await key.currentState!.checkLatency();
    expect(tcpCalls, 0);
    expect(probes, 0);
    expect(key.currentState!.message, contains('Дождись завершения'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('selection change during TCP suppresses probe and late notice', (
    tester,
  ) async {
    final tcp = Completer<int>();
    var probes = 0;
    final (state, key) = await _mount(
      tester,
      tcp: (_, _) => tcp.future,
      probe: () async {
        probes++;
        return 2;
      },
    );
    final pending = key.currentState!.checkLatency();
    state.selectedProfile = 1;
    tcp.complete(71);
    await pending;
    expect(probes, 0);
    expect(key.currentState!.message, isEmpty);
    expect(state.latency[state.profiles[0].toShareLink()], 71);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('selection change during core probe suppresses late success', (
    tester,
  ) async {
    final reply = Completer<int?>();
    final (state, key) = await _mount(tester, probe: () => reply.future);
    final pending = key.currentState!.checkLatency();
    await tester.pump();
    state.selectedProfile = 1;
    reply.complete(2);
    await pending;
    expect(key.currentState!.message, isEmpty);
    expect(key.currentState!.measuring, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disconnect during core probe suppresses stale tunnel response', (
    tester,
  ) async {
    final reply = Completer<int?>();
    final (state, key) = await _mount(tester, probe: () => reply.future);
    final pending = key.currentState!.checkLatency();
    await tester.pump();
    state.tunnel.phase = TunnelPhase.disconnected;
    reply.complete(2);
    await pending;
    expect(key.currentState!.message, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'duplicate tap and unmounted page never issue extra probes or notices',
    (tester) async {
      final reply = Completer<int?>();
      var probes = 0;
      final (_, key) = await _mount(
        tester,
        probe: () {
          probes++;
          return reply.future;
        },
      );
      final page = key.currentState!;
      final pending = page.checkLatency();
      await tester.pump();
      await page.checkLatency();
      expect(probes, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      reply.complete(2);
      await pending;
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TCP error never invokes a core probe and stays distinct', (
    tester,
  ) async {
    var probes = 0;
    final (_, key) = await _mount(
      tester,
      tcp: (_, _) async {
        throw StateError('TCP fixture failure');
      },
      probe: () async {
        probes++;
        return 2;
      },
    );
    await key.currentState!.checkLatency();
    expect(probes, 0);
    expect(key.currentState!.message, contains('TCP-порт сервера не ответил'));
    expect(key.currentState!.message, isNot(contains('fixture')));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
