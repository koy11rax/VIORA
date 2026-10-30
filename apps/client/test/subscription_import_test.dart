import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/data/subscription_import.dart';

const link =
    'vless://00000000-0000-4000-8000-000000000001@example.invalid:443?type=ws&security=tls#Test';

class Headers implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Response extends Stream<List<int>> implements HttpClientResponse {
  final List<List<int>> chunks;
  @override
  final int statusCode;
  @override
  final Headers headers = Headers();
  Response(String text, {this.statusCode = 200}) : chunks = [utf8.encode(text)];
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.fromIterable(chunks).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Request implements HttpClientRequest {
  final Response response;
  @override
  bool followRedirects = true;
  @override
  final Headers headers = Headers();
  Request(this.response);
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Client implements HttpClient {
  final Request request;
  var closed = false;
  @override
  Duration? connectionTimeout;
  Client(Response response) : request = Request(response);
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => request;
  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RedirectClient implements HttpClient {
  final List<Response> responses;
  final requests = <Request>[];
  final urls = <Uri>[];
  bool closed = false;
  @override
  Duration? connectionTimeout;
  RedirectClient(this.responses);
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    final request = Request(responses[requests.length]);
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'HTTPS redirect uses a new request without forwarding device identity',
    () async {
      final redirect = Response('', statusCode: 302);
      redirect.headers.set(
        'location',
        'https://cdn.example.invalid/sub/fixture',
      );
      final client = RedirectClient([redirect, Response(link)]);
      final result = await SubscriptionImporter(
        createClient: () => client,
        operatingSystem: 'android',
        identity: () async => 'fixture-device',
      ).load('https://vpnfn2345.duckdns.org/sub/fixture');
      expect(client.urls.map((uri) => uri.host), [
        'vpnfn2345.duckdns.org',
        'cdn.example.invalid',
      ]);
      expect(client.requests.first.headers.value('x-hwid'), 'fixture-device');
      expect(client.requests.last.headers.value('x-hwid'), isNull);
      expect(client.requests.last.headers.value('x-device-os'), isNull);
      expect(
        client.requests.every((request) => !request.followRedirects),
        isTrue,
      );
      expect(result.source, 'https://vpnfn2345.duckdns.org/sub/fixture');
      expect(client.closed, isTrue);
    },
  );
  test(
    'foreign subscriptions cannot trigger identity reads by redirecting to Viora',
    () async {
      final redirect = Response('', statusCode: 302);
      redirect.headers.set(
        'location',
        'https://vpnfn2345.duckdns.org/sub/fixture',
      );
      final client = RedirectClient([redirect, Response(link)]);
      var reads = 0;
      await SubscriptionImporter(
        createClient: () => client,
        operatingSystem: 'android',
        identity: () async {
          reads++;
          return 'fixture';
        },
      ).load('https://example.invalid/sub/fixture');
      expect(reads, 0);
      expect(
        client.requests.every(
          (request) => request.headers.value('x-hwid') == null,
        ),
        isTrue,
      );
    },
  );
  test(
    'redirects reject HTTPS downgrades, embedded credentials, loops and excess hops',
    () async {
      for (final target in [
        'http://example.invalid/sub/fixture',
        'https://user:private-secret@example.invalid/sub/fixture',
        '/sub/fixture',
      ]) {
        final redirect = Response('', statusCode: 302);
        redirect.headers.set('location', target);
        final client = RedirectClient([redirect]);
        await expectLater(
          SubscriptionImporter(
            createClient: () => client,
          ).load('https://example.invalid/sub/fixture'),
          throwsA(
            isA<FormatException>()
                .having((error) => error.source, 'source', isNull)
                .having(
                  (error) => error.toString(),
                  'public error',
                  isNot(contains('private-secret')),
                ),
          ),
        );
        expect(client.requests, hasLength(1));
        expect(client.closed, isTrue);
      }
      final client = RedirectClient(
        List.generate(4, (index) {
          final response = Response('', statusCode: 307);
          response.headers.set('location', '/sub/hop${index + 1}');
          return response;
        }),
      );
      await expectLater(
        SubscriptionImporter(
          createClient: () => client,
        ).load('https://example.invalid/sub/fixture'),
        throwsFormatException,
      );
      expect(client.requests, hasLength(4));
      expect(client.closed, isTrue);
    },
  );
  test(
    'foreign mixed-protocol responses report omissions and retain the original refresh URL',
    () async {
      final client = Client(
        Response(
          '$link\nhy2://fixture@example.invalid:443\ntuic://fixture@example.invalid:443',
        ),
      );
      final result = await SubscriptionImporter(
        createClient: () => client,
      ).load('https://example.invalid/sub/fixture');
      expect(result.profiles.map((profile) => profile.protocol), [
        'vless',
        'hysteria2',
      ]);
      expect(result.unsupportedCount, 1);
      expect(result.warnings, hasLength(1));
      expect(result.source, 'https://example.invalid/sub/fixture');
    },
  );
  test(
    'known percent-encoded revoked placeholders have a fixed actionable reason',
    () {
      for (final label in [
        'Устройство отвязано · обратитесь в поддержку через бота',
        'DEVICE REVOKED',
        'Device is revoked',
        'revoked',
      ]) {
        final placeholder =
            'vless://00000000-0000-4000-8000-000000000000@127.0.0.1:1?security=none&type=tcp#${Uri.encodeComponent(label)}';
        for (final body in [
          placeholder,
          base64.encode(utf8.encode(placeholder)),
        ]) {
          expect(
            () => decodeSubscription(body),
            throwsA(
              isA<SubscriptionImportException>()
                  .having(
                    (error) => error.reason,
                    'reason',
                    SubscriptionImportReason.deviceRevoked,
                  )
                  .having(
                    (error) => error.message,
                    'message',
                    contains('Включи существующее устройство в боте'),
                  )
                  .having((error) => error.source, 'source', isNull),
            ),
          );
        }
      }
    },
  );

  test('unknown placeholders never expose their server label or embedded URL', () {
    const privateLabel =
        'Unknown provider error https://private.example.invalid/sub/private-token';
    for (final host in ['127.0.0.1', '0.0.0.0', 'localhost']) {
      final placeholder =
          'vless://00000000-0000-4000-8000-000000000000@$host:1?security=none&type=tcp#${Uri.encodeComponent(privateLabel)}';
      expect(
        () => decodeSubscription(placeholder),
        throwsA(
          isA<SubscriptionImportException>()
              .having(
                (error) => error.reason,
                'reason',
                SubscriptionImportReason.providerPlaceholder,
              )
              .having(
                (error) => error.message,
                'message',
                isNot(contains('private-token')),
              )
              .having(
                (error) => error.message,
                'message',
                isNot(contains('Unknown provider error')),
              )
              .having((error) => error.source, 'source', isNull),
        ),
      );
    }
    expect(
      decodeSubscription(
        link.replaceFirst(
          '#Test',
          '#${Uri.encodeComponent('Устройство отвязано')}',
        ),
      ).single.host,
      'example.invalid',
    );
  });

  test(
    'HTTP 200 revoked subscription preserves the typed reason and closes the client',
    () async {
      final placeholder =
          'vless://00000000-0000-4000-8000-000000000000@127.0.0.1:1?security=none&type=tcp#${Uri.encodeComponent('Устройство отвязано')}';
      final client = Client(Response(placeholder));
      await expectLater(
        SubscriptionImporter(
          createClient: () => client,
        ).load('https://example.invalid/sub/private-token'),
        throwsA(
          isA<SubscriptionImportException>()
              .having(
                (error) => error.reason,
                'reason',
                SubscriptionImportReason.deviceRevoked,
              )
              .having(
                (error) => error.message,
                'message',
                isNot(contains('private-token')),
              ),
        ),
      );
      expect(client.closed, isTrue);
    },
  );

  for (final platform in ['android', 'windows', 'linux']) {
    test('$platform sends identity only to the trusted subscription', () async {
      var reads = 0;
      final client = Client(Response(link));
      final importer = SubscriptionImporter(
        operatingSystem: platform,
        createClient: () => client,
        identity: () async {
          reads++;
          return 'fixture-device';
        },
      );
      await importer.load('https://vpnfn2345.duckdns.org/sub/test');
      expect(reads, 1);
      expect(client.request.headers.value('x-hwid'), 'fixture-device');
      expect(
        client.request.headers.value('x-device-os'),
        {
          'android': 'Android',
          'windows': 'Windows',
          'linux': 'Linux',
        }[platform],
      );
      await importer.load('https://example.invalid/sub/test');
      expect(reads, 1);
    });
  }
  test('plain/base64 subscriptions deduplicate profiles and keep names', () {
    expect(decodeSubscription('$link\n$link').length, 1);
    expect(
      decodeSubscription(base64.encode(utf8.encode(link))).single.name,
      'Test',
    );
    expect(() => decodeSubscription(''), throwsFormatException);
    expect(
      () => decodeSubscription('<html>Error</html>'),
      throwsFormatException,
    );
    expect(
      () => decodeSubscription(
        'vless://00000000-0000-4000-8000-000000000000@127.0.0.1:1?security=none&type=tcp',
      ),
      throwsFormatException,
    );
    expect(
      () => subscriptionUri('http://example.invalid/sub/token'),
      throwsFormatException,
    );
    expect(
      () => subscriptionUri('https://user:secret@example.invalid/sub/token'),
      throwsFormatException,
    );
  });
  test('HWID policy trusts only the exact Viora HTTPS subscription origin', () {
    expect(
      isVioraSubscription(
        subscriptionUri('https://vpnfn2345.duckdns.org/sub/test'),
      ),
      isTrue,
    );
    for (final value in [
      'https://vpnfn2345.duckdns.org.evil.invalid/sub/test',
      'https://vpnfn2345.duckdns.org:8443/sub/test',
      'https://example.invalid/sub/test',
      'https://vpnfn2345.duckdns.org/other',
    ]) {
      expect(isVioraSubscription(subscriptionUri(value)), isFalse);
    }
  });
  test(
    'fetch loads profiles, refuses redirects and does not request identity for foreign origins',
    () async {
      var identityReads = 0;
      final client = Client(Response(base64.encode(utf8.encode(link))));
      final importer = SubscriptionImporter(
        createClient: () => client,
        identity: () async {
          identityReads++;
          return 'fake';
        },
      );
      final result = await importer.load('https://example.invalid/sub/test');
      expect(result.profiles.single.name, 'Test');
      expect(result.source, 'https://example.invalid/sub/test');
      expect(identityReads, 0);
      expect(client.request.headers.value('x-hwid'), isNull);
      expect(client.request.followRedirects, isFalse);
      expect(client.closed, isTrue);
      for (final status in [302, 403, 404, 503]) {
        final failed = Client(Response('', statusCode: status));
        await expectLater(
          SubscriptionImporter(
            createClient: () => failed,
          ).load('https://example.invalid/sub/test'),
          throwsFormatException,
        );
        expect(failed.closed, isTrue);
      }
      final expired = Client(Response(link));
      expired.request.response.headers.set(
        'subscription-userinfo',
        'upload=0; expire=1',
      );
      await expectLater(
        SubscriptionImporter(
          createClient: () => expired,
        ).load('https://example.invalid/sub/test'),
        throwsFormatException,
      );
    },
  );
}
