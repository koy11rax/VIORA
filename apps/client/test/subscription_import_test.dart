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

void main() {
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
