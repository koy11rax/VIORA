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

  /// Prepares the selected profile for native background tile connections.
  /// Null explicitly clears it. Completion means the native cache acknowledged
  /// the operation; validation or storage failures must reach the caller.
  static Future<void> prepareProfile(Map<String, dynamic>? profile) =>
      channel.invokeMethod<void>('prepareProfile', profile);

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
