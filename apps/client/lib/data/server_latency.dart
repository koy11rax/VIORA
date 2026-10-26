import 'dart:io';

/// TCP connection time, including DNS; no credentials or payload are sent.
///
/// Run only without an active tunnel. A TUN TCP stack can acknowledge a local
/// connection before the remote port has answered, so this is not remote RTT.
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

/// Cached TCP timings must not look like current remote delay inside a tunnel.
int? visibleTcpConnectTime(
  int? milliseconds, {
  required bool tunnelIntercepts,
}) {
  if (tunnelIntercepts || milliseconds == null || milliseconds < 0) {
    return null;
  }
  return milliseconds;
}
