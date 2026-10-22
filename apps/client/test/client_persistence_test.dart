import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/domain/desktop_applications.dart';
import 'package:viora_client/domain/routing.dart';
import 'package:viora_client/features/client/client_page.dart';

void disposeState(ClientState state) {
  state.tunnel.dispose();
  state.account.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('desktop executable formats remain platform specific', () {
    expect(
      DesktopApplications.valid(
        'windows:C:/Program Files/Browser/app.exe',
        'windows',
      ),
      isTrue,
    );
    expect(
      DesktopApplications.valid('linux:/usr/bin/firefox', 'linux'),
      isTrue,
    );
    expect(
      DesktopApplications.valid('linux:/usr/bin/firefox', 'windows'),
      isFalse,
    );
    expect(
      DesktopApplications.valid('windows:C:/Browser/app.exe', 'linux'),
      isFalse,
    );
  });

  test(
    'desktop split tunneling and strict preferences survive settings round trip',
    () {
      final state = ClientState();
      final restored = ClientState();
      addTearDown(() => disposeState(state));
      addTearDown(() => disposeState(restored));
      final executable = Platform.isWindows
          ? 'windows:C:/Program Files/Browser/browser.exe'
          : 'linux:/usr/bin/firefox';
      state.appMode = 'only';
      state.applications.add(executable);
      state.options['protection'] = 'strict';
      state.options['russianServicesDirect'] = false;
      state.rules.add(
        RoutingRule.parse(RuleKind.domain, 'example.org', RuleAction.vpn),
      );

      restored.restore(state.toJson());

      expect(restored.appMode, 'only');
      expect(restored.applications, {executable});
      expect(restored.options['protection'], 'strict');
      expect(restored.options['russianServicesDirect'], isFalse);
      expect(restored.rules.single.toJson(), state.rules.single.toJson());
    },
    skip: !(Platform.isWindows || Platform.isLinux),
  );

  test(
    'foreign or malformed desktop lists cannot partially replace safety preferences',
    () {
      final state = ClientState();
      addTearDown(() => disposeState(state));
      state.options['protection'] = 'strict';
      state.options['russianServicesDirect'] = false;
      final previous = state.toJson();
      final foreign = Platform.isWindows
          ? 'linux:/usr/bin/firefox'
          : 'windows:C:/Browser/browser.exe';
      for (final invalid in [
        foreign,
        'org.telegram.messenger',
        'windows:relative.exe',
        'linux:../firefox',
      ]) {
        expect(
          () => state.restore({
            ...previous,
            'appMode': 'only',
            'applications': [invalid],
            'options': {'protection': 'session', 'russianServicesDirect': true},
          }),
          throwsFormatException,
        );
        expect(state.toJson(), previous);
      }
    },
    skip: !(Platform.isWindows || Platform.isLinux),
  );
}
