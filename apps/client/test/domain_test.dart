import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/domain/control.dart';
import 'package:viora_client/domain/profile.dart';
import 'package:viora_client/features/client/client_page.dart';

void main() {
  test(
    'Russian direct preference migrates on and preserves an explicit opt-out',
    () {
      final state = ClientState();
      final restored = ClientState();
      addTearDown(state.account.dispose);
      addTearDown(state.tunnel.dispose);
      addTearDown(restored.account.dispose);
      addTearDown(restored.tunnel.dispose);
      state.restore({
        'options': {'notify': true},
      });
      expect(state.options['russianServicesDirect'], isTrue);
      state.options['russianServicesDirect'] = false;
      restored.restore(state.toJson());
      expect(restored.options['russianServicesDirect'], isFalse);
    },
  );
  test('group and individual recipients overlap only once', () async {
    final repo = DevelopmentControl();
    final group = await repo.createGroup('Друзья', {1001, 1003});
    final preview = await repo.preview(
      7,
      'Подарок',
      {1001, 1002},
      {group.id, 'active'},
    );
    expect(preview.recipients.length, 3);
    await repo.commit(preview);
    await repo.commit(preview);
    expect((await repo.audit()).length, 3);
  });
  test('stale preview cannot overwrite another grant', () async {
    final repo = DevelopmentControl();
    final p = await repo.preview(7, 'Подарок', {1001}, {});
    final other = await repo.preview(3, 'Компенсация', {1001}, {});
    await repo.commit(other);
    expect(() => repo.commit(p), throwsStateError);
  });
  test('empty selection and invalid days rejected', () async {
    final repo = DevelopmentControl();
    expect(() => repo.preview(7, 'Подарок', {}, {}), throwsStateError);
    expect(() => repo.preview(-1, 'Подарок', {1001}, {}), throwsStateError);
  });
  const uuid = '00000000-0000-4000-8000-000000000001';
  test('VLESS WS TLS keeps credentials out of display text', () {
    final p = VlessProfile.parse(
      'vless://$uuid@example.invalid:443?type=ws&security=tls&path=%2Fvpn#My%20server',
    );
    expect(p.transport, 'ws');
    expect(p.name, 'My server');
    expect(p.toString(), isNot(contains(uuid)));
  });
  test('REALITY requires complete Vision settings', () {
    expect(
      () => VlessProfile.parse(
        'vless://$uuid@example.invalid:8443?type=tcp&security=reality',
      ),
      throwsFormatException,
    );
    expect(
      VlessProfile.parse(
        'vless://$uuid@example.invalid:8443?type=tcp&security=reality&flow=xtls-rprx-vision&pbk=sample&sni=example.invalid',
      ).security,
      'reality',
    );
  });
  test('unsafe transport and duplicate parameters rejected', () {
    for (final query in [
      'type=ws&security=none',
      'type=ws&security=tls&security=none',
      'type=ws&security=tls&allowInsecure=1',
    ]) {
      expect(
        () => VlessProfile.parse('vless://$uuid@example.invalid:443?$query'),
        throwsFormatException,
      );
    }
  });
}
