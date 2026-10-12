import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/features/client/application_picker.dart';
import 'package:viora_client/domain/application_list.dart';

void main() {
  testWidgets(
    'clipboard import previews absent apps, preserves on cancel, merges and replaces',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('dev.viora/platform'),
        (call) async => [
          {'id': 'com.example.old', 'name': 'Old'},
          {'id': 'org.telegram.messenger', 'name': 'Telegram'},
        ],
      );
      var clipboard = 'org.telegram.messenger\ncom.example.missing';
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': clipboard};
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final selected = {'com.example.old'};
      var saves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ApplicationPicker(
                selected: selected,
                onChanged: () => saves++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Из буфера'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Найдено на телефоне: 1'), findsOneWidget);
      expect(find.textContaining('Не найдено: 1'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(selected, {'com.example.old'});
      expect(saves, 0);
      await tester.tap(find.text('Из буфера'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Дополнить'));
      await tester.pumpAndSettle();
      expect(selected, {'com.example.old', 'org.telegram.messenger'});
      await tester.tap(find.text('Из буфера'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Заменить список'));
      await tester.pumpAndSettle();
      expect(selected, {'org.telegram.messenger'});
      expect(saves, 2);
      expect(
        tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .map((tile) => (tile.title! as Text).data),
        ['Telegram', 'Old'],
      );
      await tester.enterText(find.byType(TextField), 'old');
      await tester.pumpAndSettle();
      expect(find.text('Old'), findsOneWidget);
      expect(find.text('Telegram'), findsNothing);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Скопировать список'));
      await tester.pumpAndSettle();
      expect(ApplicationList.parse(clipboard), selected);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
