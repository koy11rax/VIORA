import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/data/profile_storage.dart';
import 'package:viora_client/data/subscription_import.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/features/client/client_page.dart';
import 'package:viora_client/main.dart';

void main() {
  final profile = VlessProfile.parse(
    'vless://00000000-0000-4000-8000-000000000001@example.invalid:443?type=ws&security=tls#Saved',
  );
  const source = 'https://example.invalid/sub/fixture';
  final payload = jsonEncode({
    'version': 2,
    'profiles': [profile.toShareLink()],
    'subscriptions': {
      source: [profile.toShareLink()],
    },
    'selected': 0,
  });

  for (final resume in [false, true]) {
    testWidgets(
      'failed local restore recovers ${resume ? 'on resume' : 'automatically'} without importing or overwriting',
      (tester) async {
        var reads = 0, writes = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ProfileStorage.channel, (call) async {
              if (call.method == 'readProfiles') {
                if (++reads == 1) {
                  throw PlatformException(code: 'platform_unavailable');
                }
                return payload;
              }
              if (call.method == 'saveProfiles') writes++;
              if (call.method == 'readSession') return null;
              throw MissingPluginException();
            });
        await tester.pumpWidget(const VioraApp());
        await tester.pump();
        final state = tester
            .widget<VioraShell>(find.byType(VioraShell))
            .clientState;
        expect(state.profiles, isEmpty);
        if (resume) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        } else {
          await tester.pump(const Duration(seconds: 1));
        }
        await tester.pump();
        await tester.pump();
        expect(state.profiles.map((p) => p.toShareLink()), [
          profile.toShareLink(),
        ]);
        expect(state.subscriptions, {
          source: [profile.toShareLink()],
        });
        expect(state.selectedProfile, 0);
        expect(state.profilesLoaded, isTrue);
        expect(writes, 0);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('import cannot replace a vault that is still being restored', (
    tester,
  ) async {
    final read = Completer<String?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ProfileStorage.channel, (call) async {
          if (call.method == 'readProfiles') return read.future;
          if (call.method == 'readSession') return null;
          throw MissingPluginException();
        });
    await tester.pumpWidget(const VioraApp());
    await tester.pump();
    final page = tester.state<ClientPageState>(find.byType(ClientPage));
    final state = tester
        .widget<VioraShell>(find.byType(VioraShell))
        .clientState;
    expect(
      page.applyImport(ImportedConnection([profile], source: source)),
      isFalse,
    );
    expect(state.profiles, isEmpty);
    read.complete(payload);
    await tester.pump();
    await tester.pump();
    expect(state.profiles, hasLength(1));
    expect(state.subscriptions.keys, [source]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'persistent restore failures are bounded and resume can retry later',
    (tester) async {
      var reads = 0, writes = 0;
      var readable = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ProfileStorage.channel, (call) async {
            if (call.method == 'readProfiles') {
              reads++;
              if (!readable) throw PlatformException(code: 'vault_unavailable');
              return payload;
            }
            if (call.method == 'saveProfiles') writes++;
            if (call.method == 'readSession') return null;
            throw MissingPluginException();
          });
      await tester.pumpWidget(const VioraApp());
      await tester.pump();
      for (final seconds in [1, 3, 10, 60]) {
        await tester.pump(Duration(seconds: seconds));
        await tester.pump();
      }
      expect(reads, 4);
      final state = tester
          .widget<VioraShell>(find.byType(VioraShell))
          .clientState;
      expect(state.profilesRestoring, isTrue);
      expect(writes, 0);
      readable = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(reads, 5);
      expect(state.profilesRestoring, isFalse);
      expect(state.subscriptions.keys, [source]);
      expect(writes, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'returning after network loss never clears or duplicates a restored server list',
    (tester) async {
      var reads = 0, writes = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ProfileStorage.channel, (call) async {
            if (call.method == 'readProfiles') {
              reads++;
              return payload;
            }
            if (call.method == 'saveProfiles') writes++;
            if (call.method == 'readSession') return null;
            throw MissingPluginException();
          });
      await tester.pumpWidget(const VioraApp());
      await tester.pump();
      final state = tester
          .widget<VioraShell>(find.byType(VioraShell))
          .clientState;
      expect(state.profilesLoaded, isTrue);
      for (var i = 0; i < 5; i++) {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
      }
      expect(state.profiles.map((p) => p.toShareLink()), [
        profile.toShareLink(),
      ]);
      expect(state.subscriptions, {
        source: [profile.toShareLink()],
      });
      expect(state.selectedProfile, 0);
      expect(reads, 1);
      expect(writes, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
