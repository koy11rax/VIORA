import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/data/account_api.dart';
import 'subscription_import_test.dart' show Headers, Response;
import 'account_test.dart' show challengeData;

class ApiHeaders extends Headers {
  ContentType? _type;
  @override
  ContentType? get contentType => _type;
  @override
  set contentType(ContentType? value) {
    _type = value;
  }
}

class ApiRequest implements HttpClientRequest {
  final Response response;
  @override
  final ApiHeaders headers = ApiHeaders();
  @override
  bool followRedirects = true;
  String body = '';
  ApiRequest(this.response);
  @override
  void write(Object? object) {
    body += object.toString();
  }

  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ApiClient implements HttpClient {
  final ApiRequest request;
  Uri? uri;
  bool closed = false;
  @override
  Duration? connectionTimeout;
  ApiClient(String body, {int status = 200})
    : request = ApiRequest(Response(body, statusCode: status));
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    uri = url;
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
    'account transport keeps sessions in headers and refuses redirects',
    () async {
      final client = ApiClient(
        jsonEncode({
          'id': 88,
          'first_name': 'Test',
          'owner': false,
          'devices': [],
        }),
      );
      final account = await AccountApi(
        createClient: () => client,
      ).account('s' * 43);
      expect(account.id, 88);
      expect(client.uri.toString(), isNot(contains('s' * 43)));
      expect(
        client.request.headers.value('authorization'),
        'Bearer ${'s' * 43}',
      );
      expect(client.request.followRedirects, isFalse);
      expect(client.closed, isTrue);
      final redirect = ApiClient('{}', status: 302);
      await expectLater(
        AccountApi(createClient: () => redirect).account('s' * 43),
        throwsA(isA<AccountError>()),
      );
      expect(redirect.request.followRedirects, isFalse);
    },
  );
  test(
    'start supplies no actor/role and missing server is explained',
    () async {
      final client = ApiClient(jsonEncode(challengeData()));
      final challenge = await AccountApi(createClient: () => client).start();
      expect(challenge.code, '123456');
      expect(client.request.body, '{}');
      for (final status in [404, 401, 503]) {
        final failed = ApiClient('{}', status: status);
        await expectLater(
          AccountApi(createClient: () => failed).start(),
          throwsA(
            isA<AccountError>().having((e) => e.status, 'status', status),
          ),
        );
        expect(failed.closed, isTrue);
      }
    },
  );
}
