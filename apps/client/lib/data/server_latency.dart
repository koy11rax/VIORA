import 'dart:io';

/// TCP connection time, including DNS; no credentials or payload are sent.
Future<int> measureServerLatency(String host, int port) async {
  final watch = Stopwatch()..start();
  final socket = await Socket.connect(
    host,
    port,
    timeout: const Duration(seconds: 5),
  );
  try {
    return watch.elapsedMilliseconds;
  } finally {
    socket.destroy();
  }
}
