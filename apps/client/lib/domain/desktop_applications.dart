import 'dart:convert';

class DesktopApplications {
  static bool valid(String id, String platform) {
    if (!['windows', 'linux'].contains(platform) ||
        !id.startsWith('$platform:')) {
      return false;
    }
    final path = id.substring(platform.length + 1);
    if (path.isEmpty ||
        path.length > 4096 ||
        RegExp(r'[\x00-\x1f*?"<>|]').hasMatch(path) ||
        path.endsWith('/') ||
        path.endsWith(r'\')) {
      return false;
    }
    return platform == 'windows'
        ? RegExp(r'^[A-Za-z]:[/\\]').hasMatch(path) &&
              path.toLowerCase().endsWith('.exe')
        : path.startsWith('/') &&
              !path.contains('/../') &&
              !path.endsWith('/..');
  }

  static String encode(Set<String> ids, String platform) {
    final sorted = ids.toList()..sort();
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'viora-desktop-applications',
      'version': 1,
      'platform': platform,
      'executables': sorted,
    });
  }

  static Set<String> parse(String value, String platform) {
    if (value.length > 262144) {
      throw const FormatException('Список слишком большой');
    }
    final dynamic data;
    try {
      data = jsonDecode(value);
    } catch (_) {
      throw const FormatException(
        'Скопируй список, экспортированный из VIORA для этой системы',
      );
    }
    if (data is! Map ||
        data['format'] != 'viora-desktop-applications' ||
        data['version'] != 1 ||
        data['platform'] != platform ||
        data['executables'] is! List) {
      throw const FormatException(
        'Нужен список программ для этой системы. Android и ПК используют разные списки',
      );
    }
    final list = data['executables'] as List;
    if (list.isEmpty ||
        list.length > 1000 ||
        list.any((id) => id is! String || !valid(id, platform))) {
      throw const FormatException('В списке есть неверные пути программ');
    }
    return list.cast<String>().toSet();
  }
}
