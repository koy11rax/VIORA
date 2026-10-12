import 'dart:convert';
import 'dart:io';
import '../domain/control.dart';

class ControlApi implements ControlRepository {
  final Uri base;
  final String token;
  final String prefix;
  ControlApi(this.base, this.token, {this.prefix = '/v1'}) {
    if (base.scheme != 'https' &&
        !(base.scheme == 'http' &&
            ['127.0.0.1', '10.0.2.2', 'localhost'].contains(base.host))) {
      throw ArgumentError('Требуется HTTPS или локальный сервер разработки');
    }
    if (base.userInfo.isNotEmpty || base.hasQuery || base.hasFragment) {
      throw ArgumentError('Некорректный адрес сервера');
    }
  }
  @override
  bool get isDevelopment => base.scheme == 'http';
  Future<dynamic> _request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .openUrl(method, base.resolve('$prefix/${path.substring(4)}'))
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        bytes.addAll(chunk);
        if (bytes.length > 2 * 1024 * 1024) {
          throw StateError('Ответ слишком большой');
        }
      }
      final data = jsonDecode(utf8.decode(bytes));
      if (response.statusCode != 200) {
        throw StateError(
          data is Map ? data['message'] ?? 'Ошибка сервера' : 'Ошибка сервера',
        );
      }
      return data;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<bool> isOwner() async =>
      (await _request('GET', '/v1/me'))['owner'] == true;
  @override
  Future<List<VioraUser>> users() async =>
      (await _request('GET', '/v1/admin/users') as List)
          .map((e) => VioraUser.fromJson(Map<String, dynamic>.from(e)))
          .toList();
  @override
  Future<List<VioraGroup>> groups() async =>
      (await _request('GET', '/v1/admin/groups') as List)
          .map((e) => VioraGroup(e['id'], e['name'], e['count']))
          .toList();
  @override
  Future<VioraGroup> createGroup(String name, Set<int> ids) async {
    final g = await _request('POST', '/v1/admin/groups', {
      'name': name,
      'user_ids': ids.toList(),
    });
    return VioraGroup(g['id'], g['name'], g['count']);
  }

  @override
  Future<GrantPreview> preview(
    int days,
    String reason,
    Set<int> ids,
    Set<String> groups,
  ) async {
    final p = await _request('POST', '/v1/admin/grants/preview', {
      'days': days,
      'reason': reason,
      'user_ids': ids.toList(),
      'group_ids': groups.toList(),
    });
    return GrantPreview(
      p['preview_id'],
      p['days'],
      p['reason'],
      (p['recipients'] as List)
          .map(
            (r) => GrantRecipient(
              r['tg_id'],
              r['first_name'] ?? 'Пользователь',
              DateTime.tryParse(r['expires_at'] ?? ''),
              DateTime.parse(r['after_expiry']),
            ),
          )
          .toList(),
      DateTime.parse(p['expires_at']),
    );
  }

  @override
  Future<String> commit(GrantPreview p) async {
    final result = await _request('POST', '/v1/admin/grants/commit', {
      'preview_id': p.id,
    });
    return 'Срок зачислен: ${result['count']} получателей. Синхронизация VPN-доступа: ${result['access_sync']}.';
  }

  @override
  Future<List<String>> audit() async =>
      (await _request('GET', '/v1/admin/audit') as List)
          .map((e) => 'ID ${e['user_id']}: +${e['days']} дней · ${e['reason']}')
          .toList();
}
