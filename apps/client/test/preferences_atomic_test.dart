import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/data/preferences.dart';

void main() {
  test(
    'oversize UTF-8 settings preserve last valid state and allow retry',
    () async {
      final directory = await Directory.systemTemp.createTemp('viora-atomic-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/preferences.json');
      final preferences = DesktopPreferences(file);
      await preferences.save({'theme': 'dark', 'protection': 'strict'});
      final prior = await file.readAsBytes();
      await expectLater(
        preferences.save({'label': List.filled(140000, 'Я').join()}),
        throwsStateError,
      );
      expect(await file.readAsBytes(), prior);
      await preferences.save({'theme': 'light', 'protection': 'strict'});
      expect((await preferences.load())['protection'], 'strict');
      expect((await preferences.load())['theme'], 'light');
      expect(await directory.list().length, 1);
    },
  );

  test('readers never observe a partially written replacement', () async {
    final directory = await Directory.systemTemp.createTemp('viora-readers-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/preferences.json');
    final preferences = DesktopPreferences(file);
    await preferences.save({'sequence': -1});
    var finished = false;
    final readers = () async {
      while (!finished) {
        final data = await DesktopPreferences(file).load();
        expect(data['version'], 1);
        expect(data['sequence'], isA<int>());
      }
    }();
    try {
      await Future.wait([
        for (var i = 0; i < 30; i++)
          preferences.save({
            'sequence': i,
            'label': List.filled(10000, 'Я').join(),
          }),
      ]);
    } finally {
      finished = true;
      await readers;
    }
    expect((await preferences.load())['sequence'], 29);
    expect(await directory.list().length, 1);
  });

  test(
    'a retained Windows handle cannot destroy the previous snapshot',
    () async {
      final directory = await Directory.systemTemp.createTemp('viora-held-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/preferences.json');
      final preferences = DesktopPreferences(file);
      await preferences.save({'sequence': 1, 'protection': 'strict'});
      final held = await file.open();
      try {
        await expectLater(
          preferences.save({'sequence': 2}),
          throwsA(isA<FileSystemException>()),
        );
        expect((await preferences.load())['sequence'], 1);
        expect((await preferences.load())['protection'], 'strict');
      } finally {
        await held.close();
      }
      await preferences.save({'sequence': 3, 'protection': 'strict'});
      expect((await preferences.load())['sequence'], 3);
      expect(await directory.list().length, 1);
    },
    skip: !Platform.isWindows,
  );
}
