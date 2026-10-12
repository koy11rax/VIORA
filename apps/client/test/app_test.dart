import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/domain/control.dart';
import 'package:viora_client/main.dart';

void main() {
  testWidgets('ordinary client has no administrative entry', (tester) async {
    await tester.pumpWidget(const VioraApp());
    await tester.pumpAndSettle();
    expect(find.byTooltip('Администрирование'), findsNothing);
    expect(find.text('Админ'), findsNothing);
    await tester.ensureVisible(find.text('Подключиться'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Подключиться'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Сначала импортируй и выбери свой сервер'),
      findsOneWidget,
    );
  });
  testWidgets('owner can preview and confirm group grant', (tester) async {
    final repo = DevelopmentControl();
    await tester.pumpWidget(VioraApp(repository: repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Администрирование'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выдать дни группе'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Активные'));
    await tester.pumpAndSettle();
    final reason = find.widgetWithText(TextField, 'Причина');
    await tester.scrollUntilVisible(
      reason,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(reason, 'Подарок группе');
    await tester.ensureVisible(find.text('Проверить получателей'));
    await tester.tap(find.text('Проверить получателей'));
    await tester.pumpAndSettle();
    expect(find.text('Предпросмотр · 2 получателей'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Подтвердить выдачу').hitTestable(),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Подтвердить выдачу'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выдать дни'));
    await tester.pumpAndSettle();
    expect((await repo.audit()).length, 2);
    expect(
      find.textContaining('Только локальные данные разработки.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
