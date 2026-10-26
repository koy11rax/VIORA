import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/data/server_latency.dart';

void main() {
  test(
    'an active or transitioning tunnel cannot expose local TCP ACK time',
    () {
      expect(visibleTcpConnectTime(6, tunnelIntercepts: true), isNull);
      expect(visibleTcpConnectTime(71, tunnelIntercepts: false), 71);
      expect(visibleTcpConnectTime(null, tunnelIntercepts: false), isNull);
      expect(visibleTcpConnectTime(-1, tunnelIntercepts: false), isNull);
    },
  );
  test(
    'measures a real local connection and closes it without sending data',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first;
      final delay = await measureServerLatency(
        server.address.address,
        server.port,
      );
      final peer = await accepted;
      expect(delay, greaterThanOrEqualTo(0));
      expect(
        await peer.fold<int>(0, (count, bytes) => count + bytes.length),
        0,
      );
      peer.destroy();
      await server.close();
    },
  );
  test('a closed port fails instead of inventing latency', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    await expectLater(
      measureServerLatency('127.0.0.1', port),
      throwsA(isA<SocketException>()),
    );
  });
}
