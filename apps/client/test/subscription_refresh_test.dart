import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/data/subscription_import.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/features/client/client_page.dart';

const failedSource = 'https://first.example.invalid/sub/private-token-one';
const validSource = 'https://second.example.invalid/sub/private-token-two';
VlessProfile profile(String name) => VlessProfile.parse(
  'vless://00000000-0000-4000-8000-000000000001@$name.example.invalid:443?type=ws&security=tls#$name',
);

ClientState savedState() {
  final state = ClientState();
  final oldFirst = profile('old-first'), oldSecond = profile('old-second');
  state.profiles.addAll([oldFirst, oldSecond]);
  state.selectedProfile = 0;
  state.subscriptions[failedSource] = [oldFirst.toShareLink()];
  state.subscriptions[validSource] = [oldSecond.toShareLink()];
  return state;
}

Future<GlobalKey<ClientPageState>> mount(
  WidgetTester tester,
  ClientState state,
  Future<ImportedConnection> Function(String) load,
) async {
  tester.view.physicalSize = const Size(1440, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(state.tunnel.dispose);
  addTearDown(state.account.dispose);
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
  return key;
}

void main() {
  testWidgets(
    'manual revoked refresh explains existing-device recovery and retains all profiles',
    (tester) async {
      final state = savedState();
      final original = state.profiles
          .map((profile) => profile.toShareLink())
          .toList();
      var saves = 0;
      state.onChanged = () => saves++;
      final key = await mount(tester, state, (source) async {
        if (source == failedSource) {
          return ImportedConnection(
            decodeSubscription(
              'vless://00000000-0000-4000-8000-000000000000@127.0.0.1:1?security=none&type=tcp#${Uri.encodeComponent('Устройство отвязано · arbitrary-private-detail')}',
            ),
            source: source,
          );
        }
        throw const FormatException('secret $validSource');
      });
      await key.currentState!.refreshSubscriptions();
      expect(state.profiles.map((profile) => profile.toShareLink()), original);
      expect(state.selectedProfile, 0);
      expect(saves, 0);
      expect(
        key.currentState!.message,
        contains('Включи существующее устройство в боте'),
      );
      expect(key.currentState!.message, contains('Прежние серверы сохранены'));
      expect(
        key.currentState!.message,
        isNot(contains('arbitrary-private-detail')),
      );
      expect(key.currentState!.message, isNot(contains('private-token')));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'partial typed failure retains summary counts and updates the healthy source',
    (tester) async {
      final state = savedState();
      final key = await mount(tester, state, (source) async {
        if (source == failedSource) {
          throw const SubscriptionImportException(
            SubscriptionImportReason.deviceRevoked,
          );
        }
        return ImportedConnection([profile('updated')], source: source);
      });
      await key.currentState!.refreshSubscriptions();
      expect(state.profiles.map((profile) => profile.name), [
        'old-first',
        'updated',
      ]);
      expect(key.currentState!.message, contains('Обновлено подписок: 1'));
      expect(key.currentState!.message, contains('Не удалось обновить: 1'));
      expect(
        key.currentState!.message,
        contains('Включи существующее устройство в боте'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('silent revoked refresh preserves data without notification', (
    tester,
  ) async {
    final state = savedState();
    final original = state.profiles
        .map((profile) => profile.toShareLink())
        .toList();
    final key = await mount(tester, state, (_) async {
      throw const SubscriptionImportException(
        SubscriptionImportReason.deviceRevoked,
      );
    });
    await key.currentState!.refreshSubscriptions(silent: true);
    await tester.pump();
    expect(state.profiles.map((profile) => profile.toShareLink()), original);
    expect(key.currentState!.message, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'revoked reason takes priority over a generic provider placeholder',
    (tester) async {
      final state = savedState();
      final key = await mount(tester, state, (source) async {
        throw SubscriptionImportException(
          source == failedSource
              ? SubscriptionImportReason.providerPlaceholder
              : SubscriptionImportReason.deviceRevoked,
        );
      });
      await key.currentState!.refreshSubscriptions();
      expect(key.currentState!.message, contains('Это устройство отвязано'));
      expect(key.currentState!.message, isNot(contains('private-token')));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a failed first provider does not block later valid subscriptions',
    (tester) async {
      final state = savedState();
      final calls = <String>[];
      var saves = 0;
      state.onChanged = () => saves++;
      final key = await mount(tester, state, (source) async {
        calls.add(source);
        if (source == failedSource) {
          throw const FormatException('secret $failedSource');
        }
        return ImportedConnection([profile('updated')], source: source);
      });
      await key.currentState!.refreshSubscriptions();
      expect(calls, [failedSource, validSource]);
      expect(state.profiles.map((p) => p.name), ['old-first', 'updated']);
      expect(state.subscriptions[failedSource], [
        profile('old-first').toShareLink(),
      ]);
      expect(state.subscriptions[validSource], [
        profile('updated').toShareLink(),
      ]);
      expect(state.selectedProfile, 0);
      expect(saves, 1);
      expect(key.currentState!.message, contains('Обновлено подписок: 1'));
      expect(key.currentState!.message, contains('Не удалось обновить: 1'));
      expect(key.currentState!.message, isNot(contains('private-token')));
      expect(key.currentState!.refreshing, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('silent refresh updates healthy sources without a snackbar', (
    tester,
  ) async {
    final state = savedState();
    final key = await mount(tester, state, (source) async {
      if (source == failedSource) {
        throw StateError('secret $failedSource');
      }
      return ImportedConnection([profile('updated')], source: source);
    });
    await key.currentState!.refreshSubscriptions(silent: true);
    await tester.pump();
    expect(state.profiles.map((p) => p.name), ['old-first', 'updated']);
    expect(key.currentState!.message, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'all failed providers retain their previous servers and hide raw errors',
    (tester) async {
      final state = savedState();
      final originalLinks = state.profiles.map((p) => p.toShareLink()).toList();
      final calls = <String>[];
      final key = await mount(tester, state, (source) async {
        calls.add(source);
        throw const FormatException('secret $failedSource');
      });
      await key.currentState!.refreshSubscriptions();
      expect(calls.length, 2);
      expect(state.profiles.map((p) => p.toShareLink()), originalLinks);
      expect(
        key.currentState!.message,
        'Не удалось обновить подписки. Прежние серверы сохранены.',
      );
      expect(key.currentState!.message, isNot(contains('private-token')));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a silent capacity rejection preserves data and remains silent', (
    tester,
  ) async {
    final state = savedState();
    state.profiles.removeLast();
    state.profiles.addAll(List.generate(199, (i) => profile('existing-$i')));
    state.subscriptions[validSource] = [];
    final key = await mount(tester, state, (source) async {
      if (source == failedSource) {
        throw const FormatException('offline');
      }
      return ImportedConnection([profile('new-server')], source: source);
    });
    await key.currentState!.refreshSubscriptions(silent: true);
    await tester.pump();
    expect(state.profiles.length, 200);
    expect(state.profiles.any((p) => p.name == 'new-server'), isFalse);
    expect(state.subscriptions[validSource], isEmpty);
    expect(key.currentState!.message, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'overlapping refresh is ignored and a late response cannot mutate an unmounted page',
    (tester) async {
      final state = savedState();
      final response = Completer<ImportedConnection>();
      var calls = 0;
      final key = await mount(tester, state, (source) {
        calls++;
        return response.future;
      });
      final page = key.currentState!;
      final pending = page.refreshSubscriptions(silent: true);
      await page.refreshSubscriptions(silent: true);
      expect(calls, 1);
      expect(page.refreshing, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      response.complete(
        ImportedConnection([profile('updated')], source: failedSource),
      );
      await pending;
      expect(calls, 1);
      expect(state.profiles.map((p) => p.name), ['old-first', 'old-second']);
      expect(tester.takeException(), isNull);
    },
  );
}
