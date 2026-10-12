import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/main.dart';

void main() {
  testWidgets('phone navigation and expanded settings fit the screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const VioraApp());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final page in ['Серверы', 'Подписка', 'Правила', 'Настройки']) {
      await tester.tap(find.text(page).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: page);
    }
    for (final section in [
      'Соединение и защита',
      'DNS и IPv6',
      'Приложения',
      'Внешний вид',
    ]) {
      await tester.ensureVisible(find.text(section));
      await tester.pumpAndSettle();
      await tester.tap(find.text(section));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: section);
      await tester.tap(find.text('Настройки').last);
      await tester.pumpAndSettle();
    }
  });
}
