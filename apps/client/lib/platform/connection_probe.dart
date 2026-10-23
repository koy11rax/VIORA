import 'dart:async';

import 'package:flutter/services.dart';

/// A response through the current native core is separate from TCP port reachability.
/// No reply means this test endpoint was not confirmed, not that all sites are down.
class AndroidConnectionProbe {
  static const channel = MethodChannel('flutter_v2ray_client');

  static Future<int?> measure({
    Duration timeout = const Duration(seconds: 18),
  }) async {
    try {
      final result = await channel
          .invokeMethod<Object?>('getConnectedServerDelay', {
            'url': 'https://www.gstatic.com/generate_204',
          })
          .timeout(timeout);
      return result is int && result >= 0 ? result : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    } on TimeoutException {
      return null;
    }
  }
}
