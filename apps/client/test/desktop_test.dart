import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/data/preferences.dart';
import 'package:viora_client/domain/routing.dart';
import 'package:viora_client/main.dart';

class MemoryPreferences extends DesktopPreferences {
  Map<String, dynamic> data = {};
  MemoryPreferences() : super(File('unused'));
  @override
  Future<void> save(Map<String, dynamic> value) async {
    data = Map.of(value);
  }

  @override
  Future<Map<String, dynamic>> load() async => data;
}

void main() {
  test('routing rejects malformed domains, subnets and ports', () {
    for (final value in [
      'https://example.org',
      '*.example.org',
      '-bad.org',
      'a..org',
      '192.168.1.1',
    ]) {
      expect(
        () => RoutingRule.parse(RuleKind.domain, value, RuleAction.vpn),
        throwsFormatException,
      );
    }
    for (final value in ['192.168.1.1/33', '::1/129', 'example.org/24']) {
      expect(
        () => RoutingRule.parse(RuleKind.subnet, value, RuleAction.direct),
        throwsFormatException,
      );
    }
    for (final value in ['0', '65536', '9000-8000', '1-2-3']) {
      expect(
        () => RoutingRule.parse(RuleKind.port, value, RuleAction.block),
        throwsFormatException,
      );
    }
    expect(
      RoutingRule.parse(RuleKind.domain, 'Example.ORG.', RuleAction.vpn).value,
      'example.org',
    );
    expect(
      RoutingRule.parse(
        RuleKind.subnet,
        '2001:db8::/32',
        RuleAction.direct,
      ).kind,
      RuleKind.subnet,
    );
  });
  test(
    'desktop preferences survive restart and serialize overlapping writes',
    () async {
      final temp = await Directory.systemTemp.createTemp('viora-test-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/preferences.json');
      final store = DesktopPreferences(file);
      await Future.wait([
        store.save({'theme': 'light'}),
        store.save({
          'theme': 'dark',
          'rules': [
            RoutingRule.parse(RuleKind.port, '443', RuleAction.direct).toJson(),
          ],
        }),
      ]);
      final data = await DesktopPreferences(file).load();
      expect(data['theme'], 'dark');
      expect(
        RoutingRule.fromJson(
          Map<String, dynamic>.from((data['rules'] as List).single),
        ).action,
        RuleAction.direct,
      );
      await file.writeAsString('{broken');
      await expectLater(store.load(), throwsFormatException);
    },
  );
  testWidgets('desktop editor persists a rule and restores after restart', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryPreferences();
    await tester.pumpWidget(VioraApp(storage: store));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('approved-sidebar')), findsOneWidget);
    await tester.tap(find.text('Маршрутизация'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Добавить правило'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Значение'),
      'example.org',
    );
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    final data = await store.load();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(VioraApp(storage: store, preferences: data));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Маршрутизация'));
    await tester.pumpAndSettle();
    expect(find.text('example.org'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
