import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/ui/native_window_theme.dart';

void main() {
  testWidgets(
    'native caption follows resolved app theme without duplicate calls',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      const channel = MethodChannel('dev.viora/window');
      final calls = <bool>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'setDark');
        calls.add(call.arguments as bool);
        return null;
      });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });
      Widget app(Brightness brightness) => MaterialApp(
        theme: ThemeData(brightness: brightness),
        themeAnimationDuration: Duration.zero,
        builder: (context, child) => NativeWindowTheme(child: child!),
        home: const SizedBox(),
      );
      await tester.pumpWidget(app(Brightness.dark));
      await tester.pumpAndSettle();
      expect(calls, [true]);
      await tester.pumpWidget(app(Brightness.light));
      await tester.pumpAndSettle();
      expect(calls, [true, false]);
      await tester.pumpWidget(app(Brightness.light));
      await tester.pumpAndSettle();
      expect(calls, [true, false]);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
