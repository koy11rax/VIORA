import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/platform/desktop_tray.dart';

void main() {
  VlessProfile profile(String name) => VlessProfile.parse(
    'vless://00000000-0000-4000-8000-000000000001@example.com:443?security=tls&type=ws#$name',
  );
  Map<String, Object> snapshot(
    DesktopTray tray,
    List<VlessProfile> profiles, {
    int selected = 0,
    bool running = false,
    bool busy = false,
  }) => tray.snapshot(
    profiles: profiles,
    selected: selected,
    running: running,
    busy: busy,
    supported: true,
    subscriptions: false,
    status: 'test',
  );
  test('tray IDs survive reorder and never select a replaced profile', () {
    final tray = DesktopTray();
    final a = profile('A'), b = profile('B');
    final first = snapshot(tray, [a, b]);
    final id = ((first['servers'] as List).first as Map)['id'];
    snapshot(tray, [b, a]);
    expect(tray.serverIndex(id, [b, a]), 1);
    final replacement = profile('A');
    expect(tray.serverIndex(id, [b, replacement]), isNull);
    snapshot(tray, [replacement]);
    expect(tray.serverIndex(id, [replacement]), isNull);
    expect(tray.serverIndex(9999, [replacement]), isNull);
  });
  test('snapshot exposes display data only and real operation state', () {
    final state = snapshot(
      DesktopTray(),
      [profile('A')],
      running: true,
      busy: true,
    );
    expect(state['running'], isTrue);
    expect(state['busy'], isTrue);
    expect(state['canConnect'], isTrue);
    final server = (state['servers'] as List).single as Map;
    expect(server.keys, unorderedEquals(['id', 'name', 'selected']));
    expect(server['selected'], isTrue);
    expect(state.toString(), isNot(contains('example.com')));
    expect(state.toString(), isNot(contains('00000000')));
    expect(snapshot(DesktopTray(), [], selected: -1)['canConnect'], isFalse);
  });
}

