import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keeps the native caption in the application's selected theme.
class NativeWindowTheme extends StatefulWidget {
  final Widget child;
  const NativeWindowTheme({super.key, required this.child});

  @override
  State<NativeWindowTheme> createState() => _NativeWindowThemeState();
}

class _NativeWindowThemeState extends State<NativeWindowTheme> {
  static const channel = MethodChannel('dev.viora/window');
  bool? lastDark;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (lastDark == dark) return;
    lastDark = dark;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || lastDark != dark) return;
      try {
        await channel.invokeMethod<void>('setDark', dark);
      } on MissingPluginException {
        // Widget tests and older runners have no native caption channel.
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
