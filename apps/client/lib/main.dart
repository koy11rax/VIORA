import 'platform/desktop_tray.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'domain/control.dart';
import 'features/admin/admin_page.dart';
import 'features/admin/live_admin_page.dart';
import 'features/client/client_page.dart';
import 'data/preferences.dart';
import 'ui/desktop_frame.dart';
import 'ui/native_window_theme.dart';
import 'dart:async';
import 'dart:io';
import 'data/profile_storage.dart';
import 'platform/tunnel.dart';
import 'package:flutter/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final entry in {
      'AndroidLibXrayLite': 'AndroidLibXrayLite-LGPL-3.0.txt',
      'Xray-core': 'Xray-MPL-2.0.txt',
      'GNU GPL (LGPL supplement)': 'GPL-3.0.txt',
      'flutter_v2ray_client': 'flutter_v2ray_client-MIT.txt',
    }.entries) {
      yield LicenseEntryWithLineBreaks([
        entry.key,
      ], await rootBundle.loadString('assets/licenses/${entry.value}'));
    }
  });
  DesktopPreferences? storage;
  Map<String, dynamic> preferences = {};
  String? warning;
  try {
    storage = await DesktopPreferences.forPlatform();
    preferences = await storage?.load() ?? {};
  } catch (_) {
    warning =
        'Не удалось прочитать настройки. Используются стандартные значения.';
  }
  runApp(
    VioraApp(
      storage: storage,
      preferences: preferences,
      startupWarning: warning,
      repository: const bool.fromEnvironment('VIORA_DEMO') && !kReleaseMode
          ? DevelopmentControl()
          : null,
    ),
  );
}

class VioraApp extends StatefulWidget {
  final ControlRepository? repository;
  final DesktopPreferences? storage;
  final Map<String, dynamic> preferences;
  final String? startupWarning;
  const VioraApp({
    super.key,
    this.repository,
    this.storage,
    this.preferences = const {},
    this.startupWarning,
  });
  @override
  State<VioraApp> createState() => _VioraAppState();
}

class _VioraAppState extends State<VioraApp> {
  ThemeMode mode = ThemeMode.dark;
  Color accent = const Color(0xffc6a7ff);
  final clientState = ClientState();
  final profileStorage = ProfileStorage();
  bool get _nativeStorage =>
      Platform.isAndroid || Platform.isWindows || Platform.isLinux;
  bool _profilesLoaded = false;
  bool _tunnelWasActive = false;
  String? warning;
  @override
  void initState() {
    super.initState();
    warning = widget.startupWarning;
    try {
      final data = widget.preferences;
      mode = ThemeMode.values.byName(data['theme'] as String? ?? 'dark');
      final color = data['accent'] as int? ?? 0xffc6a7ff;
      if (color < 0xff000000 || color > 0xffffffff) {
        throw const FormatException('Цвет');
      }
      accent = Color(color == 0xffbfa0ff ? 0xffc6a7ff : color);
      clientState.restore(data);
    } catch (_) {
      warning = 'Настройки повреждены. Проверь выбранные параметры.';
    }
    clientState.onChanged = () {
      setState(() {});
      save();
    };
    clientState.tunnel.addListener(_tunnelChanged);
    clientState.account.addListener(_runtimeChanged);
    if (_nativeStorage) {
      unawaited(clientState.account.restore().catchError((Object _) {}));
    }
    unawaited(clientState.tunnel.initialize());
    if (_nativeStorage) unawaited(loadProfiles());
  }

  void _runtimeChanged() {
    if (mounted) setState(() {});
  }

  void _tunnelChanged() {
    final active = clientState.tunnel.phase == TunnelPhase.active;
    final becameActive = active && !_tunnelWasActive;
    _tunnelWasActive = active;
    _runtimeChanged();
    if (becameActive && _nativeStorage) {
      unawaited(clientState.account.restore().catchError((Object _) {}));
    }
  }

  Future<void> loadProfiles() async {
    try {
      final saved = await profileStorage.load();
      if (!mounted) return;
      setState(() {
        _profilesLoaded = true;
        clientState.profilesLoaded = true;
        final hadProfiles = clientState.profiles.isNotEmpty;
        clientState.profiles.addAll(saved.$1);
        clientState.subscriptions.addAll(profileStorage.subscriptions);
        if (!hadProfiles) clientState.selectedProfile = saved.$2;
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => warning =
              error is PlatformException && error.code == 'vault_unavailable'
              ? 'Разблокируй системное хранилище и перезапусти Viora, чтобы загрузить серверы.'
              : 'Не удалось прочитать защищённое хранилище серверов',
        );
      }
    }
  }

  @override
  void dispose() {
    clientState.tunnel.removeListener(_tunnelChanged);
    clientState.tunnel.dispose();
    clientState.account.removeListener(_runtimeChanged);
    clientState.account.dispose();
    super.dispose();
  }

  Future<void> save() async {
    try {
      if (_nativeStorage && _profilesLoaded) {
        await profileStorage.save(
          clientState.profiles,
          clientState.selectedProfile,
          sources: clientState.subscriptions,
        );
      }
      await widget.storage?.save({
        ...clientState.toJson(),
        'theme': mode.name,
        'accent': accent.toARGB32(),
      });
      if (mounted && warning != null && _profilesLoaded) {
        setState(() => warning = null);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => warning =
              'Не удалось сохранить настройки. Изменения действуют до закрытия приложения.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Viora',
    debugShowCheckedModeBanner: false,
    themeMode: mode,
    theme: theme(Brightness.light),
    darkTheme: theme(Brightness.dark),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations:
            !clientState.motion || MediaQuery.disableAnimationsOf(context),
      ),
      child: NativeWindowTheme(child: child!),
    ),
    themeAnimationDuration: clientState.motion
        ? const Duration(milliseconds: 180)
        : Duration.zero,
    home: VioraShell(
      repository: widget.repository,
      mode: mode,
      clientState: clientState,
      warning: warning,
      onTheme: (v) {
        setState(() => mode = v);
        save();
      },
      onAccent: (v) {
        setState(() => accent = v);
        save();
      },
    ),
  );
  ThemeData theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final primary = dark
        ? accent
        : accent.toARGB32() == 0xffc6a7ff
        ? const Color(0xff7040d6)
        : Color.lerp(accent, const Color(0xff221c35), .48)!;
    final ink = dark ? const Color(0xfff4f1fc) : const Color(0xff221c35);
    final line = dark ? const Color(0xff3c354b) : const Color(0xffded8e9);
    final soft = accent.toARGB32() == 0xffc6a7ff
        ? (dark ? const Color(0xff34264c) : const Color(0xffe9ddff))
        : Color.lerp(
            accent,
            dark ? const Color(0xff111016) : Colors.white,
            dark ? .80 : .88,
          )!;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
        ).copyWith(
          primary: primary,
          onPrimary: dark ? const Color(0xff24113e) : Colors.white,
          primaryContainer: soft,
          onPrimaryContainer: primary,
          surface: dark ? const Color(0xff1d1b25) : Colors.white,
          onSurface: ink,
          onSurfaceVariant: dark
              ? const Color(0xffb4abc5)
              : const Color(0xff655c76),
          outline: line,
          outlineVariant: line,
        );
    final base = ThemeData(brightness: brightness, useMaterial3: true);
    final font = defaultTargetPlatform == TargetPlatform.windows
        ? 'Segoe UI'
        : 'Roboto';
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: font,
      textTheme: base.textTheme
          .apply(bodyColor: ink, displayColor: ink)
          .copyWith(
            bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: ink),
            titleMedium: TextStyle(
              fontSize: 17,
              height: 1.35,
              fontWeight: FontWeight.w500,
              color: ink,
            ),
            headlineMedium: TextStyle(
              fontSize: 36,
              height: 1.08,
              letterSpacing: -1.3,
              fontWeight: FontWeight.w500,
              color: ink,
            ),
            labelLarge: TextStyle(
              fontFamily: font,
              fontSize: 14,
              fontWeight: FontWeight.w400,
            ),
          ),
      scaffoldBackgroundColor: dark
          ? Color(clientState.neutral ? 0xff111115 : 0xff111016)
          : Color(clientState.neutral ? 0xfff4f4f6 : 0xfff4f2fa),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: dark ? const Color(0xff1d1b25) : Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(clientState.radius),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xff272431) : Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          foregroundColor: ink,
          backgroundColor: scheme.surface,
          side: BorderSide(color: line),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surface,
        selectedColor: soft,
        side: BorderSide(color: line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        labelStyle: TextStyle(fontSize: 13, color: ink, fontFamily: font),
        padding: const EdgeInsets.all(8),
      ),
      visualDensity: clientState.compact
          ? VisualDensity.compact
          : VisualDensity.standard,
    );
  }
}

class VioraShell extends StatefulWidget {
  final ClientState clientState;
  final String? warning;
  final ControlRepository? repository;
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onTheme;
  final ValueChanged<Color> onAccent;
  const VioraShell({
    super.key,
    required this.repository,
    required this.clientState,
    this.warning,
    required this.mode,
    required this.onTheme,
    required this.onAccent,
  });
  @override
  State<VioraShell> createState() => _VioraShellState();
}

class _VioraShellState extends State<VioraShell> {
  final clientKey = GlobalKey<ClientPageState>();
  final tray = DesktopTray();
  bool get hasTray =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  Future<Object?> _trayCall(MethodCall call) async {
    if (call.method != 'action' || !mounted) return null;
    final args = Map<Object?, Object?>.from(call.arguments as Map);
    final command = args['command'];
    if (command == 'settings') {
      setState(() => index = 4);
      return null;
    }
    // Admin replaces the client widget. Recreate it before invoking the same
    // commands used by the main screen, keeping the shared tunnel alive.
    if (clientKey.currentState == null) {
      setState(() => index = 0);
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted) return null;
    final page = clientKey.currentState;
    if (page == null) return null;
    if (command == 'toggle') await page.toggleTunnel();
    if (command == 'server') {
      final target = tray.serverIndex(args['id'], widget.clientState.profiles);
      if (target != null) await page.selectServer(target);
    }
    if (command == 'refresh' && widget.clientState.subscriptions.isNotEmpty) {
      await page.refreshSubscriptions();
    }
    if (command == 'ping') await page.checkLatency();
    return null;
  }

  void _publishTray() {
    if (!hasTray) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final state = widget.clientState, tunnel = widget.clientState.tunnel;
      try {
        await DesktopTray.channel.invokeMethod<void>(
          'update',
          tray.snapshot(
            profiles: state.profiles,
            selected: state.selectedProfile,
            running: tunnel.running,
            busy: tunnel.busy,
            supported: tunnel.engine.supported,
            subscriptions: state.subscriptions.isNotEmpty,
            status: tunnel.label,
          ),
        );
      } on MissingPluginException {
        // Older runners and widget tests have no tray channel.
      } on PlatformException {
        // The native runner may already be shutting down.
      }
    });
  }

  int index = 0;
  bool owner = false;
  ControlRepository? repository;
  @override
  void initState() {
    super.initState();
    if (hasTray) DesktopTray.channel.setMethodCallHandler(_trayCall);
    repository = widget.repository;
    widget.clientState.account.addListener(_accountChanged);
    _authorize();
    _accountChanged();
  }

  void _accountChanged() {
    if (!mounted || widget.repository != null) return;
    setState(() {
      repository = widget.clientState.account.controlRepository;
      owner = repository != null;
      if (!owner && index == 5) index = 0;
    });
  }

  @override
  void dispose() {
    if (hasTray) DesktopTray.channel.setMethodCallHandler(null);
    widget.clientState.account.removeListener(_accountChanged);
    super.dispose();
  }

  Future<void> _authorize() async {
    final source = repository;
    if (source == null) return;
    try {
      final allowed = await source.isOwner();
      if (mounted && identical(repository, source)) {
        setState(() => owner = allowed);
      }
    } catch (_) {
      if (mounted && identical(repository, source)) {
        setState(() => owner = false);
      }
    }
  }

  static const titles = [
    'Главная',
    'Серверы',
    'Подписка',
    'Правила',
    'Настройки',
  ];
  static const icons = [
    Icons.power_settings_new,
    Icons.dns_outlined,
    Icons.confirmation_number_outlined,
    Icons.route_outlined,
    Icons.tune,
  ];
  void _openAccount() {
    if (index == 5) {
      setState(() => index = 2);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => clientKey.currentState?.loginTelegram(),
      );
    } else {
      clientKey.currentState?.loginTelegram();
    }
  }

  @override
  Widget build(BuildContext context) {
    _publishTray();
    final wide = MediaQuery.sizeOf(context).width >= 850;
    final desktopPages = [0, 1, 2, 3, 6, 7, 4, if (owner) 5];
    String desktopTitle(int page) => switch (page) {
      5 => 'Администрирование',
      6 => 'Приложения',
      7 => 'Внешний вид',
      _ => titles[page],
    };
    IconData desktopIcon(int page) => switch (page) {
      5 => Icons.admin_panel_settings_outlined,
      6 => Icons.apps,
      7 => Icons.palette_outlined,
      _ => icons[page],
    };
    final page = index == 5 && owner && repository != null
        ? repository!.isDevelopment
              ? AdminPage(repository: repository!)
              : LiveAdminPage(
                  account: widget.clientState.account,
                  repository: repository!,
                )
        : ClientPage(
            key: clientKey,
            desktop: wide,
            demo: repository?.isDevelopment ?? false,
            index: index,
            state: widget.clientState,
            mode: widget.mode,
            onTheme: widget.onTheme,
            onAccent: widget.onAccent,
            onNavigate: (i) => setState(() => index = i),
            onRepository: (r) async {
              final allowed = await r.isOwner();
              if (!mounted) return;
              setState(() {
                repository = r;
                owner = allowed;
              });
            },
          );
    if (wide) {
      return DesktopFrame(
        onTrayMenu: hasTray
            ? () => DesktopTray.channel.invokeMethod<void>('showMenu')
            : null,
        index: index,
        owner: owner,
        demo: repository?.isDevelopment ?? false,
        warning: widget.warning,
        onNavigate: (i) => setState(() => index = i),
        onImport: () {
          if (index == 5) {
            setState(() => index = 1);
          }
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => clientKey.currentState?.import(),
          );
          WidgetsBinding.instance.scheduleFrame();
        },
        onAccount: _openAccount,
        child: page,
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset('assets/viora.png', width: 34, height: 34),
            ),
            const SizedBox(width: 10),
            const Text('viora'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Мой аккаунт',
            onPressed: _openAccount,
            icon: Icon(
              widget.clientState.account.value == null
                  ? Icons.account_circle_outlined
                  : Icons.account_circle,
            ),
          ),
          if (owner)
            IconButton(
              tooltip: 'Администрирование',
              onPressed: () => setState(() => index = 5),
              icon: const Icon(Icons.admin_panel_settings_outlined),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          if (widget.warning != null)
            MaterialBanner(
              content: Text(widget.warning!),
              actions: const [SizedBox.shrink()],
            ),
          if (repository?.isDevelopment ?? false)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.secondaryContainer,
              padding: const EdgeInsets.all(10),
              child: const Text(
                'Сборка разработки · вымышленные данные · без реальных оплат',
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: Row(
              children: [
                if (wide)
                  NavigationRail(
                    extended: true,
                    selectedIndex: desktopPages.indexOf(index),
                    onDestinationSelected: (i) =>
                        setState(() => index = desktopPages[i]),
                    destinations: [
                      for (final page in desktopPages)
                        NavigationRailDestination(
                          icon: Icon(desktopIcon(page)),
                          label: Text(desktopTitle(page)),
                        ),
                    ],
                  ),
                Expanded(child: page),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: index == 5 && owner
                  ? 5
                  : index < 5
                  ? index
                  : 4,
              onDestinationSelected: (i) => setState(() => index = i),
              destinations: [
                for (var i = 0; i < 5; i++)
                  NavigationDestination(icon: Icon(icons[i]), label: titles[i]),
                if (owner)
                  const NavigationDestination(
                    icon: Icon(Icons.admin_panel_settings_outlined),
                    label: 'Админ',
                  ),
              ],
            ),
    );
  }
}

class VioraPanel extends StatelessWidget {
  final Widget child;
  const VioraPanel({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 14),
    child: Padding(padding: const EdgeInsets.all(20), child: child),
  );
}
