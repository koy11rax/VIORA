import 'dart:convert';

class ApplicationList {
  static Set<String> parse(String text) {
    if (text.length > 262144 || text.trim().isEmpty) {
      throw const FormatException(
        'В буфере нет списка приложений или он слишком большой',
      );
    }
    final source = text.trim();
    Iterable<Object?> items;
    if (source.startsWith('{') || source.startsWith('[')) {
      final value = jsonDecode(source);
      if (value is List) {
        items = value;
      } else if (value is Map &&
          value['format'] == 'viora-applications' &&
          value['version'] == 1 &&
          value['packages'] is List) {
        items = value['packages'] as List;
      } else {
        throw const FormatException(
          'Неподдерживаемый формат списка приложений',
        );
      }
    } else {
      items = const LineSplitter()
          .convert(source)
          .where((s) => s.trim().isNotEmpty);
    }
    if (items.isEmpty || items.length > 1000) {
      throw const FormatException('Нужен список от 1 до 1000 приложений');
    }
    final result = <String>{};
    for (final item in items) {
      if (item is! String ||
          !RegExp(
            r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$',
          ).hasMatch(item.trim()) ||
          item.trim() == 'dev.viora.viora_client' ||
          item.length > 255) {
        throw const FormatException(
          'В списке есть неверное имя пакета приложения',
        );
      }
      result.add(item.trim());
    }
    return result;
  }

  static String encode(Set<String> packages) {
    final sorted = packages.toList()..sort();
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'viora-applications',
      'version': 1,
      'packages': sorted,
    });
  }
}
