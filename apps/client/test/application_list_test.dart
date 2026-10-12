import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/domain/application_list.dart';

void main() {
  test('clipboard application list round trips and accepts plain lines', () {
    final ids = {'org.telegram.messenger', 'com.example.browser'};
    expect(ApplicationList.parse(ApplicationList.encode(ids)), ids);
    expect(
      ApplicationList.parse(
        ' org.telegram.messenger\r\ncom.example.browser\norg.telegram.messenger ',
      ),
      ids,
    );
  });
  test('reject malformed clipboard payloads without partial import', () {
    for (final text in [
      '',
      'https://example.com',
      'org.telegram.messenger\nbad',
      'dev.viora.viora_client',
      '{"format":"viora-applications","version":2,"packages":["com.example.app"]}',
      '["com.example.app", 1]',
      'x' * 262145,
      List.filled(1001, 'com.example.app').join('\n'),
    ]) {
      expect(() => ApplicationList.parse(text), throwsFormatException);
    }
  });
}
