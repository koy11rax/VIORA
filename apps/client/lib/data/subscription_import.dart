import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../domain/profile.dart';
import '../platform/native_bridge.dart';

class ImportedConnection {
  final List<VlessProfile> profiles;
  final String? source;
  final int? expires;
  const ImportedConnection(this.profiles, {this.source, this.expires});
}

Uri subscriptionUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (value.length > 16384 ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw const FormatException(
      'Вставь ссылку подписки https://… или сервера vless://…',
    );
  }
  return uri;
}

bool isVioraSubscription(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host == 'vpnfn2345.duckdns.org' &&
    uri.port == 443 &&
    RegExp(r'^/sub/[^/]+$').hasMatch(uri.path);

List<VlessProfile> decodeSubscription(String body) {
  var text = body.trim().replaceFirst('\uFEFF', '');
  if (text.length > 1048576) {
    throw const FormatException('Подписка слишком большая');
  }
  if (!text.contains('://') && text.isNotEmpty) {
    try {
      text = utf8.decode(
        base64.decode(base64.normalize(text.replaceAll(RegExp(r'\s'), ''))),
      );
    } catch (_) {
      throw const FormatException(
        'Бот вернул неподдерживаемый формат подписки',
      );
    }
  }
  final profiles = <String, VlessProfile>{};
  var unsupported = 0;
  for (final line in const LineSplitter().convert(text)) {
    final value = line.trim();
    if (value.isEmpty || value.startsWith('#')) continue;
    final hint = Uri.tryParse(value);
    if (hint?.host == '127.0.0.1' && hint?.port == 1) {
      throw const FormatException(
        'Бот не выдал рабочие серверы. Проверь срок подписки и лимит устройств в боте.',
      );
    }
    if (!value.startsWith('vless://')) {
      unsupported++;
      continue;
    }
    try {
      final profile = VlessProfile.parse(value);
      // A bot may return a placeholder profile explaining HWID/device limits.
      if (profile.host == '127.0.0.1' ||
          profile.host == '0.0.0.0' ||
          profile.port == 1) {
        throw const FormatException(
          'Бот не выдал рабочие серверы. Проверь срок подписки и лимит устройств в боте.',
        );
      }
      profiles[profile.toShareLink()] = profile;
    } on FormatException {
      rethrow;
    }
    if (profiles.length > 200) {
      throw const FormatException('В подписке больше 200 серверов');
    }
  }
  if (profiles.isEmpty) {
    throw FormatException(
      unsupported > 0
          ? 'В подписке нет поддерживаемых серверов VLESS'
          : 'Подписка пустая. Проверь её срок и статус в боте.',
    );
  }
  return profiles.values.toList();
}

class SubscriptionImporter {
  final HttpClient Function() createClient;
  final Future<String> Function() identity;
  final String operatingSystem;
  SubscriptionImporter({
    HttpClient Function()? createClient,
    Future<String> Function()? identity,
    String? operatingSystem,
  }) : createClient = createClient ?? HttpClient.new,
       identity = identity ?? NativeBridge.installationId,
       operatingSystem = operatingSystem ?? Platform.operatingSystem;

  Future<ImportedConnection> load(String value) async {
    final uri = subscriptionUri(value);
    final client = createClient();
    client.connectionTimeout = const Duration(seconds: 15);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, 'Viora/0.5.0');
        request.headers.set(HttpHeaders.acceptHeader, 'text/plain');
        final deviceOs = const {
          'android': 'Android',
          'windows': 'Windows',
          'linux': 'Linux',
        }[operatingSystem];
        if (isVioraSubscription(uri) && deviceOs != null) {
          request.headers.set('x-hwid', await identity());
          request.headers.set('x-device-os', deviceOs);
          request.headers.set('x-device-model', 'Viora $deviceOs');
        }
        final response = await request.close();
        if (response.statusCode >= 300 && response.statusCode < 400) {
          throw const FormatException(
            'Ссылка перенаправляет на другой адрес. Скопируй прямую ссылку подписки из бота.',
          );
        }
        if (response.statusCode != 200) {
          throw FormatException(
            response.statusCode == 404 || response.statusCode == 403
                ? 'Ссылка недействительна или доступ закрыт. Получи новую ссылку в боте.'
                : 'Бот временно недоступен. Попробуй позже.',
          );
        }
        final info = response.headers.value('subscription-userinfo') ?? '';
        final seconds = int.tryParse(
          RegExp(r'(?:^|;)\s*expire=(\d+)').firstMatch(info)?.group(1) ?? '',
        );
        if (seconds != null &&
            seconds * 1000 <= DateTime.now().millisecondsSinceEpoch) {
          throw const FormatException(
            'Подписка закончилась. Продли её в боте и повтори импорт.',
          );
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 1048576) {
            throw const FormatException('Подписка слишком большая');
          }
          bytes.addAll(chunk);
        }
        return ImportedConnection(
          decodeSubscription(utf8.decode(bytes)),
          source: uri.toString(),
          expires: seconds,
        );
      })().timeout(const Duration(seconds: 30));
    } on FormatException {
      rethrow;
    } on TimeoutException {
      throw const FormatException(
        'Бот не ответил за 30 секунд. Проверь интернет и повтори.',
      );
    } catch (_) {
      throw const FormatException(
        'Не удалось загрузить подписку. Проверь интернет и ссылку из бота.',
      );
    } finally {
      client.close(force: true);
    }
  }
}
