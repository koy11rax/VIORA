import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/data/account_api.dart';
import 'package:viora_client/data/subscription_import.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/domain/tunnel_config.dart';
import 'package:viora_client/features/client/client_page.dart';
import 'package:viora_client/features/client/subscription_management.dart';
import 'package:viora_client/platform/tunnel.dart';

const first =
    'https://first.example.invalid/sub/private-one?token=private-query';
const second = 'https://second.example.invalid/sub/private-two';
const changed = 'https://new.example.invalid/sub/private-new';

VlessProfile server(
  String name, {
  String uuid = '00000000-0000-4000-8000-000000000001',
}) => VlessProfile.parse(
  'vless://$uuid@$name.example.invalid:443?type=ws&security=tls#$name',
);

class Engine implements TunnelEngine {
  final stream = StreamController<TunnelStats>.broadcast(sync: true);
  final starts = <TunnelConfig>[];
  int stops = 0;
  bool acknowledge = true, acknowledgeBeforeGate = false;
  Completer<void>? stopGate;
  @override
  bool get supported => true;
  @override
  Stream<TunnelStats> get events => stream.stream;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> start(TunnelConfig config, String name) async {
    starts.add(config);
    stream.add(const TunnelStats('CONNECTED'));
  }

  @override
  Future<void> stop() async {
    stops++;
    if (acknowledgeBeforeGate) stream.add(const TunnelStats('DISCONNECTED'));
    final gate = stopGate;
    stopGate = null;
    if (gate != null) await gate.future;
    if (acknowledge && !acknowledgeBeforeGate) {
      stream.add(const TunnelStats('DISCONNECTED'));
    }
  }
}

class Harness {
  final Engine engine = Engine();
  late final ClientState state = ClientState(tunnel: TunnelController(engine));
  final key = GlobalKey<ClientPageState>();
  Future<ImportedConnection> Function(String) load = (source) async =>
      ImportedConnection([server('updated')], source: source);
  int saves = 0;
  Harness() {
    state.profiles.addAll([server('old'), server('shared'), server('manual')]);
    state.subscriptions[first] = [
      state.profiles[0].toShareLink(),
      state.profiles[1].toShareLink(),
    ];
    state.subscriptions[second] = [state.profiles[1].toShareLink()];
    state.selectedProfile = 0;
    state.onChanged = () => saves++;
  }
  Widget ui({int index = 1, bool desktop = true, ClientState? value}) =>
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ClientPage(
              key: key,
              index: index,
              desktop: desktop,
              state: value ?? state,
              mode: ThemeMode.dark,
              onTheme: (_) {},
              onAccent: (_) {},
              onNavigate: (_) {},
              onRepository: (_) async {},
              loadSubscription: (source) => load(source),
            ),
          ),
        ),
      );
  Future<void> mount(
    WidgetTester tester, {
    double width = 1360,
    int index = 1,
  }) async {
    tester.view.physicalSize = Size(width, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      state.tunnel.dispose();
      state.account.dispose();
      await engine.stream.close();
    });
    await tester.pumpWidget(ui(index: index, desktop: width > 600));
  }

  Future<void> connect() => state.tunnel.connect(
    state.selectedTunnelConfig(),
    state.profiles[state.selectedProfile].name,
  );
  List<Object?> snapshot() => [
    state.profiles.map((profile) => profile.toShareLink()).toList(),
    {
      for (final entry in state.subscriptions.entries)
        entry.key: List<String>.of(entry.value),
    },
    state.selectedProfile,
  ];
}

Future<void> openManagement(WidgetTester tester, Harness h) async {
  await tester.ensureVisible(
    find.byKey(const ValueKey('manage-subscriptions')),
  );
  await tester.tap(find.byKey(const ValueKey('manage-subscriptions')));
  await tester.pumpAndSettle();
}

void main() {
  for (final operation in ['edit', 'refresh', 'account']) {
    testWidgets('late $operation ignores a replacement ClientState', (
      tester,
    ) async {
      final h = Harness();
      final response = Completer<ImportedConnection>();
      h.load = (_) => response.future;
      await h.mount(tester);
      final before = h.snapshot();
      final page = h.key.currentState!;
      final future = switch (operation) {
        'edit' =>
          page
              .editSubscription(first, changed)
              .then<void>((applied) => expect(applied, false)),
        'refresh' => page.refreshSubscriptions(silent: true),
        _ => page.importAccountSubscription(first),
      };
      final engine = Engine();
      final other = ClientState(tunnel: TunnelController(engine));
      addTearDown(() async {
        other.tunnel.dispose();
        other.account.dispose();
        await engine.stream.close();
      });
      var writes = 0;
      other.onChanged = () => writes++;
      await tester.pumpWidget(h.ui(value: other));
      response.complete(
        ImportedConnection([
          server('stale'),
        ], source: operation == 'edit' ? changed : first),
      );
      await future;
      expect(h.snapshot(), before);
      expect(other.profiles, isEmpty);
      expect(other.subscriptions, isEmpty);
      expect(writes, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets(
    'edit loads first then atomically renames source and retains shared/manual profiles',
    (tester) async {
      final h = Harness();
      final response = Completer<ImportedConnection>();
      h.load = (_) => response.future;
      await h.mount(tester);
      final before = h.snapshot();
      final edit = h.key.currentState!.editSubscription(first, changed);
      expect(h.snapshot(), before);
      expect(h.saves, 0);
      response.complete(
        ImportedConnection([server('replacement')], source: changed),
      );
      expect(await edit, true);
      expect(h.state.subscriptions.containsKey(first), false);
      expect(h.state.subscriptions.containsKey(changed), true);
      expect(h.state.subscriptions[second], [server('shared').toShareLink()]);
      expect(h.state.profiles.map((p) => p.name), [
        'shared',
        'manual',
        'replacement',
      ]);
      expect(h.state.profiles[h.state.selectedProfile].name, 'replacement');
      expect(h.saves, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed edit keeps all data and never surfaces provider URL or exception text',
    (tester) async {
      final h = Harness();
      h.load = (_) async => throw const FormatException('secret $changed');
      await h.mount(tester);
      final before = h.snapshot();
      expect(await h.key.currentState!.editSubscription(first, changed), false);
      expect(h.snapshot(), before);
      expect(h.saves, 0);
      expect(h.key.currentState!.message, isNot(contains('private-new')));
      expect(h.key.currentState!.message, contains('сохранены'));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('existing target and HTTP URL are refused before loading', (
    tester,
  ) async {
    final h = Harness();
    var loads = 0;
    h.load = (_) async {
      loads++;
      return ImportedConnection([server('new')]);
    };
    await h.mount(tester);
    final before = h.snapshot();
    expect(await h.key.currentState!.editSubscription(first, second), false);
    expect(
      await h.key.currentState!.editSubscription(
        first,
        'http://unsafe.example.invalid/secret',
      ),
      false,
    );
    expect(loads, 0);
    expect(h.snapshot(), before);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'rename at 200 sources replaces one slot instead of requiring 201',
    (tester) async {
      final h = Harness();
      for (var i = 0; i < 198; i++) {
        h.state.subscriptions['https://provider$i.example.invalid/sub/synthetic'] =
            [];
      }
      await h.mount(tester);
      expect(await h.key.currentState!.editSubscription(first, changed), true);
      expect(h.state.subscriptions.length, 200);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'shared lock blocks refresh/import/delete and maintenance timestamp while edit is loading',
    (tester) async {
      final h = Harness();
      final response = Completer<ImportedConnection>();
      var loads = 0;
      h.load = (_) {
        loads++;
        return response.future;
      };
      h.state.profilesLoaded = true;
      await h.mount(tester);
      final timestamp = h.state.lastSubscriptionRefresh;
      final edit = h.key.currentState!.editSubscription(first, changed);
      await h.key.currentState!.refreshSubscriptions(silent: true);
      expect(
        h.key.currentState!.applyImport(
          ImportedConnection([server('late-manual')]),
        ),
        false,
      );
      expect(await h.key.currentState!.deleteSubscription(second), false);
      await expectLater(
        h.key.currentState!.importAccountSubscription(second),
        throwsA(isA<AccountError>()),
      );
      await tester.pump(const Duration(seconds: 35));
      expect(loads, 1);
      expect(h.state.lastSubscriptionRefresh, timestamp);
      response.complete(
        ImportedConnection([server('replacement')], source: changed),
      );
      expect(await edit, true);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'late edit response cannot resurrect an externally removed source',
    (tester) async {
      final h = Harness();
      final response = Completer<ImportedConnection>();
      h.load = (_) => response.future;
      await h.mount(tester);
      final edit = h.key.currentState!.editSubscription(first, changed);
      h.state.subscriptions.remove(first);
      response.complete(ImportedConnection([server('late')], source: changed));
      expect(await edit, false);
      expect(h.state.subscriptions.containsKey(changed), false);
      expect(h.state.profiles.any((p) => p.name == 'late'), false);
      expect(h.saves, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('late refresh response cannot recreate a removed source', (
    tester,
  ) async {
    final h = Harness();
    final response = Completer<ImportedConnection>();
    h.load = (source) => source == first
        ? response.future
        : Future.value(ImportedConnection([server('shared')], source: source));
    await h.mount(tester);
    final refresh = h.key.currentState!.refreshSubscriptions(silent: true);
    h.state.subscriptions.remove(first);
    response.complete(ImportedConnection([server('late')], source: first));
    await refresh;
    expect(h.state.subscriptions.containsKey(first), false);
    expect(h.state.profiles.any((p) => p.name == 'late'), false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('account load holds the same lock until its response finishes', (
    tester,
  ) async {
    final h = Harness();
    final response = Completer<ImportedConnection>();
    h.load = (_) => response.future;
    await h.mount(tester);
    final accountLoad = h.key.currentState!.importAccountSubscription(first);
    expect(await h.key.currentState!.deleteSubscription(first), false);
    response.complete(ImportedConnection([server('account')], source: first));
    await accountLoad;
    expect(await h.key.currentState!.deleteSubscription(first), true);
    expect(h.state.subscriptions.containsKey(first), false);
    expect(h.state.profiles.any((p) => p.name == 'account'), false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'active edit reconnects to updated parameters and preserves routing settings',
    (tester) async {
      final h = Harness();
      await h.mount(tester);
      await h.connect();
      h.load = (source) async => ImportedConnection([
        server('old', uuid: '00000000-0000-4000-8000-000000000002'),
      ], source: source);
      expect(await h.key.currentState!.editSubscription(first, changed), true);
      expect(h.engine.starts.length, 2);
      expect(h.engine.stops, 1);
      expect(h.state.tunnel.phase, TunnelPhase.active);
      expect(
        h
            .engine
            .starts
            .last
            .json['outbounds'][0]['settings']['vnext'][0]['users'][0]['id'],
        '00000000-0000-4000-8000-000000000002',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'manual disconnect during edit load does not reconnect afterwards',
    (tester) async {
      final h = Harness();
      final response = Completer<ImportedConnection>();
      h.load = (_) => response.future;
      await h.mount(tester);
      await h.connect();
      final edit = h.key.currentState!.editSubscription(first, changed);
      await h.state.tunnel.disconnect();
      response.complete(
        ImportedConnection([server('replacement')], source: changed),
      );
      expect(await edit, true);
      expect(h.engine.starts.length, 1);
      expect(h.state.tunnel.phase, TunnelPhase.disconnected);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('deleting a shared selected server preserves active connection', (
    tester,
  ) async {
    final h = Harness();
    h.state.selectedProfile = 1;
    await h.mount(tester);
    await h.connect();
    expect(await h.key.currentState!.deleteSubscription(first), true);
    expect(h.engine.stops, 0);
    expect(h.state.tunnel.phase, TunnelPhase.active);
    expect(h.state.profiles.map((p) => p.name), ['shared', 'manual']);
    expect(h.state.profiles[h.state.selectedProfile].name, 'shared');
    expect(h.state.subscriptions.keys, [second]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'active removal waits for confirmed stop and never picks another server automatically',
    (tester) async {
      final h = Harness();
      await h.mount(tester);
      await h.connect();
      final gate = Completer<void>();
      h.engine.stopGate = gate;
      final removal = h.key.currentState!.deleteSubscription(first);
      await tester.pump();
      expect(h.state.subscriptions.containsKey(first), true);
      gate.complete();
      expect(await removal, true);
      expect(h.state.selectedProfile, -1);
      expect(h.engine.starts.length, 1);
      expect(h.state.tunnel.phase, TunnelPhase.disconnected);
      expect(h.state.profiles.map((p) => p.name), ['shared', 'manual']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'early DISCONNECTED acknowledgement still waits for native stop method completion',
    (tester) async {
      final h = Harness();
      await h.mount(tester);
      await h.connect();
      final gate = Completer<void>();
      h.engine.acknowledgeBeforeGate = true;
      h.engine.stopGate = gate;
      var completed = false;
      final removal = h.key.currentState!.deleteSubscription(first).then((
        value,
      ) {
        completed = true;
        return value;
      });
      await tester.pump(const Duration(milliseconds: 20));
      expect(completed, false);
      expect(h.state.subscriptions.containsKey(first), true);
      gate.complete();
      expect(await removal, true);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('missing stop acknowledgement preserves the complete graph', (
    tester,
  ) async {
    final h = Harness();
    await h.mount(tester);
    await h.connect();
    h.engine.acknowledge = false;
    final before = h.snapshot();
    final removal = h.key.currentState!.deleteSubscription(first);
    await tester.pump(const Duration(seconds: 6));
    expect(await removal, false);
    expect(h.snapshot(), before);
    expect(h.saves, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a never-completing native stop does not trap management lock forever',
    (tester) async {
      final h = Harness();
      await h.mount(tester);
      await h.connect();
      final gate = Completer<void>();
      h.engine.stopGate = gate;
      final before = h.snapshot();
      final removal = h.key.currentState!.deleteSubscription(first);
      await tester.pump(const Duration(seconds: 6));
      expect(await removal, false);
      expect(h.snapshot(), before);
      expect(
        h.key.currentState!.applyImport(
          ImportedConnection([server('after-timeout')]),
          silent: true,
        ),
        true,
      );
      gate.complete();
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'standalone edit deduplicates an existing server without changing subscriptions',
    (tester) async {
      final h = Harness();
      await h.mount(tester);
      final sources = h.snapshot()[1];
      final selected = h.state.profiles[0].toShareLink();
      expect(
        await h.key.currentState!.editStandaloneProfile(
          server('manual').toShareLink(),
          server('shared').toShareLink(),
        ),
        true,
      );
      expect(h.state.profiles.map((p) => p.name), ['old', 'shared']);
      expect(h.state.profiles[h.state.selectedProfile].toShareLink(), selected);
      expect(h.snapshot()[1], sources);
      expect(
        await h.key.currentState!.deleteStandaloneProfile(
          server('shared').toShareLink(),
        ),
        false,
      );
      expect(
        await h.key.currentState!.editStandaloneProfile(
          server('old').toShareLink(),
          server('other').toShareLink(),
        ),
        false,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'standalone active edit switches safely and deletion disconnects first',
    (tester) async {
      final h = Harness();
      h.state.selectedProfile = 2;
      await h.mount(tester);
      await h.connect();
      expect(
        await h.key.currentState!.editStandaloneProfile(
          server('manual').toShareLink(),
          server('changed-manual').toShareLink(),
        ),
        true,
      );
      expect(h.engine.starts.length, 2);
      expect(h.state.tunnel.phase, TunnelPhase.active);
      expect(
        await h.key.currentState!.deleteStandaloneProfile(
          server('changed-manual').toShareLink(),
        ),
        true,
      );
      expect(h.engine.stops, 2);
      expect(h.state.selectedProfile, -1);
      expect(h.state.subscriptions.length, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final width in [320.0, 1360.0]) {
    for (final index in [1, 2]) {
      testWidgets(
        'management is reachable without overflow at width $width page $index',
        (tester) async {
          final h = Harness();
          await h.mount(tester, width: width, index: index);
          await openManagement(tester, h);
          expect(find.text('Сохранённые подключения'), findsOneWidget);
          expect(tester.takeException(), isNull);
          expect(find.text(first), findsNothing);
          expect(
            find.text(server('manual').toShareLink()),
            findsNothing,
          ); // Names are public; credential-bearing URIs stay hidden.
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'editor hides secret URL, supports paste/reveal, and cancel makes no request',
    (tester) async {
      final h = Harness();
      var loads = 0;
      h.load = (_) async {
        loads++;
        return ImportedConnection([server('unused')]);
      };
      await h.mount(tester);
      await openManagement(tester, h);
      expect(
        SavedSubscription(first, 2).toString(),
        isNot(contains('private-one')),
      );
      await tester.tap(find.text('Изменить ссылку').first);
      await tester.pumpAndSettle();
      final input = tester.widget<TextField>(
        find.byKey(const ValueKey('subscription-url-editor')),
      );
      expect(input.obscureText, true);
      expect(input.enableIMEPersonalizedLearning, false);
      expect(input.enableSuggestions, false);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': changed} : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.text('Вставить из буфера'));
      await tester.pumpAndSettle();
      expect(input.controller!.text, changed);
      await tester.tap(find.byTooltip('Показать ссылку'));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('subscription-url-editor')),
            )
            .obscureText,
        false,
      );
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(loads, 0);
      expect(h.state.subscriptions.containsKey(first), true);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('saving editor blocks back/cancel until atomic update finishes', (
    tester,
  ) async {
    final h = Harness();
    final response = Completer<ImportedConnection>();
    h.load = (_) => response.future;
    await h.mount(tester, width: 320);
    await openManagement(tester, h);
    await tester.tap(find.text('Изменить ссылку').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('subscription-url-editor')),
      changed,
    );
    await tester.tap(find.byKey(const ValueKey('save-subscription-url')));
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Отмена'))
          .onPressed,
      isNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('Изменить ссылку подписки'), findsOneWidget);
    expect(h.state.subscriptions.containsKey(first), true);
    response.complete(
      ImportedConnection([server('replacement')], source: changed),
    );
    await tester.pumpAndSettle();
    expect(find.text('Изменить ссылку подписки'), findsNothing);
    expect(h.state.subscriptions.containsKey(changed), true);
    expect(find.text(changed), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'deletion confirmation can be cancelled and then deletes only selected source',
    (tester) async {
      final h = Harness();
      await h.mount(tester);
      await openManagement(tester, h);
      await tester.tap(find.text('Удалить').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Оставить'));
      await tester.pumpAndSettle();
      expect(h.saves, 0);
      await tester.tap(find.text('Удалить').first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('confirm-delete-subscription')),
      );
      await tester.pumpAndSettle();
      expect(h.state.subscriptions.keys, [second]);
      expect(h.state.profiles.map((p) => p.name), ['shared', 'manual']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
