import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../platform/native_bridge.dart';
import 'subscription_import.dart';
import 'control_api.dart';

class AccountError implements Exception {
  final String message;
  final int status;
  const AccountError(this.message, [this.status = 0]);
}

class LoginChallenge {
  final String id, secret, code;
  final Uri botUrl;
  final DateTime expires;
  LoginChallenge.fromJson(Map<String, dynamic> data)
    : id = data['id'] as String,
      secret = data['poll_secret'] as String,
      code = data['code'] as String,
      botUrl = Uri.parse(data['bot_url'] as String),
      expires = DateTime.fromMillisecondsSinceEpoch(
        (data['expires_at'] as int) * 1000,
      ) {
    if (!RegExp(r'^[A-Za-z0-9_-]{24}$').hasMatch(id) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(secret) ||
        !RegExp(r'^\d{6}$').hasMatch(code) ||
        botUrl.scheme != 'https' ||
        botUrl.host != 't.me' ||
        botUrl.port != 443 ||
        botUrl.userInfo.isNotEmpty ||
        botUrl.hasFragment ||
        !RegExp(r'^/[A-Za-z][A-Za-z0-9_]{4,31}$').hasMatch(botUrl.path) ||
        botUrl.queryParameters.length != 1 ||
        botUrl.queryParametersAll['start']?.length != 1 ||
        botUrl.queryParameters['start'] != 'viora_$id' ||
        expires.isBefore(DateTime.now()) ||
        expires.isAfter(DateTime.now().add(const Duration(minutes: 10)))) {
      throw const AccountError('Сервер вернул некорректный запрос входа');
    }
  }
  Map<String, String> get payload => {'id': id, 'poll_secret': secret};
  @override
  String toString() => 'LoginChallenge(credentials:redacted)';
}

class AccountDevice {
  final int? id;
  final String name, platform;
  final DateTime? lastSeen;
  AccountDevice.fromJson(Map data)
    : id = data['id'] as int?,
      name = data['name'] as String? ?? 'Устройство',
      platform = data['platform'] as String? ?? '',
      lastSeen = DateTime.tryParse(data['last_seen'] as String? ?? '');
}

class VioraAccount {
  final int id;
  final String name;
  final bool owner;
  final DateTime? expires;
  final String? subscriptionUrl;
  final Uri? botUrl;
  final List<String> devices;
  final List<AccountDevice> deviceRecords;
  final int deviceLimit;
  VioraAccount.fromJson(Map<String, dynamic> data)
    : id = data['id'] as int,
      name = data['first_name'] as String? ?? 'Пользователь',
      owner = data['owner'] == true,
      expires = DateTime.tryParse(data['expires_at'] as String? ?? ''),
      subscriptionUrl = data['subscription_url'] as String?,
      botUrl = data['bot_url'] == null
          ? null
          : Uri.parse(data['bot_url'] as String),
      devices = (data['devices'] as List? ?? [])
          .map((d) => (d as Map)['name'] as String)
          .toList(),
      deviceRecords = (data['devices'] as List? ?? [])
          .map((d) => AccountDevice.fromJson(d as Map))
          .toList(),
      deviceLimit = data['device_limit'] as int? ?? 3 {
    if (botUrl != null &&
        (botUrl!.scheme != 'https' ||
            botUrl!.host != 't.me' ||
            botUrl!.port != 443 ||
            botUrl!.userInfo.isNotEmpty ||
            botUrl!.hasQuery ||
            botUrl!.hasFragment ||
            !RegExp(r'^/[A-Za-z][A-Za-z0-9_]{4,31}$').hasMatch(botUrl!.path))) {
      throw const AccountError('Некорректная ссылка бота');
    }
    if (id <= 0 ||
        name.length > 200 ||
        devices.length > 100 ||
        (subscriptionUrl != null &&
            !isVioraSubscription(subscriptionUri(subscriptionUrl!)))) {
      throw const AccountError('Сервер вернул некорректные данные аккаунта');
    }
  }
}

class AccountApi {
  final Uri base;
  final HttpClient Function() createClient;
  AccountApi({Uri? base, HttpClient Function()? createClient})
    : base = base ?? Uri.parse('https://vpnfn2345.duckdns.org'),
      createClient = createClient ?? HttpClient.new {
    if (this.base.scheme != 'https' ||
        this.base.userInfo.isNotEmpty ||
        this.base.hasQuery ||
        this.base.hasFragment) {
      throw ArgumentError('Требуется HTTPS для аккаунта');
    }
  }
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    String? session,
    Map<String, dynamic>? body,
  }) async {
    final client = createClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      return await (() async {
        final request = await client.openUrl(method, base.resolve(path));
        request.followRedirects = false;
        if (session != null) {
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer $session',
          );
        }
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        if ((response.statusCode == 404 || response.statusCode == 501) &&
            path.startsWith('/v1/app/auth/')) {
          throw const AccountError(
            'Вход через Telegram ещё не включён на сервере. Импорт подписки и VPN продолжают работать.',
            404,
          );
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length >
              (path == '/v1/app/admin/tools/photo' ? 850000 : 131072)) {
            throw const AccountError('Ответ аккаунта слишком большой');
          }
          bytes.addAll(chunk);
        }
        final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        if (response.statusCode != 200) {
          final explanation = data['message'];
          if ((response.statusCode == 400 ||
                  response.statusCode == 409 ||
                  response.statusCode == 413) &&
              explanation is String &&
              explanation.isNotEmpty &&
              explanation.length <= 300) {
            throw AccountError(explanation, response.statusCode);
          }
          throw AccountError(
            response.statusCode == 410
                ? 'Код входа истёк. Нажми «Начать заново».'
                : response.statusCode == 429
                ? 'Слишком много попыток. Подожди минуту.'
                : response.statusCode == 401
                ? 'Сеанс истёк. Войди через Telegram снова.'
                : response.statusCode == 403
                ? 'У этого аккаунта нет доступа к действию.'
                : response.statusCode == 404
                ? 'Запись не найдена. Обнови данные и повтори.'
                : response.statusCode == 409
                ? 'Данные уже изменились. Обнови список.'
                : 'Не удалось выполнить запрос аккаунта. Повтори позже.',
            response.statusCode,
          );
        }
        return data;
      })().timeout(const Duration(seconds: 25));
    } on AccountError {
      rethrow;
    } catch (_) {
      throw const AccountError(
        'Не удалось связаться с аккаунтом Viora. Проверь интернет и повтори.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<LoginChallenge> start() async => LoginChallenge.fromJson(
    await request('POST', '/v1/app/auth/start', body: {}),
  );
  Future<String?> poll(LoginChallenge challenge) async {
    final result = await request(
      'POST',
      '/v1/app/auth/poll',
      body: challenge.payload,
    );
    if (result['status'] == 'pending') return null;
    final token = result['session'];
    if (result['status'] != 'approved' ||
        token is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      throw const AccountError('Сервер не подтвердил вход');
    }
    return token;
  }

  Future<VioraAccount> account(String session) async => VioraAccount.fromJson(
    await request('GET', '/v1/app/account', session: session),
  );
  Future<void> logout(String session) async {
    await request('POST', '/v1/app/auth/logout', session: session, body: {});
  }

  Future<void> cancel(LoginChallenge challenge) async {
    await request('POST', '/v1/app/auth/cancel', body: challenge.payload);
  }
}

class AccountController extends ChangeNotifier {
  final AccountApi api;
  final Future<String?> Function() read;
  final Future<void> Function(String) write;
  final Future<void> Function() clear;
  VioraAccount? value;
  String? _session;
  bool _disposed = false;
  int _revision = 0;
  AccountController({
    AccountApi? api,
    Future<String?> Function()? read,
    Future<void> Function(String)? write,
    Future<void> Function()? clear,
  }) : api = api ?? AccountApi(),
       read = read ?? NativeBridge.readSession,
       write = write ?? NativeBridge.saveSession,
       clear = clear ?? NativeBridge.clearSession;
  bool get hasSession => _session != null;
  ControlApi? get controlRepository => value?.owner == true && _session != null
      ? ControlApi(api.base, _session!, prefix: '/v1/app')
      : null;
  Future<Map<String, dynamic>> features(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final session = _session;
    if (session == null) throw const AccountError('Войди через Telegram', 401);
    try {
      return await api.request(
        body == null ? 'GET' : 'POST',
        '/v1/app/$path',
        session: session,
        body: body,
      );
    } on AccountError catch (error) {
      if (error.status == 401) await logout();
      rethrow;
    }
  }

  Future<void> restore() async {
    final revision = _revision;
    final session = _session ?? await read();
    if (revision != _revision || _disposed || session == null) return;
    _session = session;
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(session)) {
      await clear();
      if (revision != _revision || _disposed) return;
      _session = null;
      value = null;
      notifyListeners();
      throw const AccountError(
        'Сохранённый сеанс недействителен. Войди заново.',
        401,
      );
    }
    try {
      final restored = await api.account(session);
      if (revision == _revision && !_disposed) value = restored;
    } on AccountError catch (error) {
      if (revision != _revision || _disposed) return;
      if (error.status == 401) {
        await clear();
        if (revision != _revision || _disposed) return;
        _session = null;
        value = null;
      }
      rethrow;
    } finally {
      if (revision == _revision && !_disposed) notifyListeners();
    }
  }

  Future<void> complete(String session) async {
    final revision = ++_revision;
    await write(session);
    if (revision != _revision || _disposed) return;
    _session = session;
    await restore();
  }

  Future<void> logout() async {
    final revision = ++_revision;
    final session = _session;
    if (session != null) {
      try {
        await api.logout(session);
      } on AccountError catch (error) {
        if (error.status != 401) {
          rethrow;
        }
      }
    }
    if (revision != _revision || _disposed) return;
    await clear();
    if (revision != _revision || _disposed) return;
    _session = null;
    value = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
