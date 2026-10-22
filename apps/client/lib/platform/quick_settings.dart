import 'package:flutter/services.dart';

/// Android owns the tile and the system confirmation dialog. A cancelled or
/// unsupported request must never be presented as a successfully added tile.
class QuickSettings {
  static const channel = MethodChannel('dev.viora/quick_settings');
  static const _results = {
    'added',
    'already_added',
    'not_added',
    'manual',
    'unavailable',
  };

  static Future<String> requestAddTile() async {
    try {
      final result = await channel.invokeMethod<String>('requestAddTile');
      return _results.contains(result) ? result! : 'unavailable';
    } on MissingPluginException {
      return 'unavailable';
    }
  }

  /// Consumes a queued tile action after Flutter and the account/profile state
  /// are ready. A missing bridge on desktop or an older installation is benign.
  static Future<String?> takeAction() async {
    try {
      final result = await channel.invokeMethod<String>('takeAction');
      return result == 'connect' ? result : null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Reads service state without changing the tunnel. A failed observation is
  /// unknown, not disconnected, and cannot be used as permission to start again.
  static Future<String?> readStatus() async {
    try {
      final result = await channel.invokeMethod<String>('snapshot');
      return const {
            'CONNECTED',
            'CONNECTING',
            'DISCONNECTED',
            'FAILED',
          }.contains(result)
          ? result
          : null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
