import 'dart:async';
import 'dart:io';
import 'dart:convert';
import '../../data/account_api.dart';
import 'account_page.dart';
import '../../data/subscription_import.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../../domain/routing.dart';
import 'routing_page.dart';
import '../../data/control_api.dart';
import '../../domain/control.dart';
import '../../domain/profile.dart';
import '../../domain/desktop_applications.dart';
import '../../main.dart' show VioraPanel;
import 'approved_content.dart';
import 'import_dialog.dart';
import '../../platform/tunnel.dart';
import '../../platform/connection_probe.dart';
import '../../domain/tunnel_config.dart';
import '../../data/server_latency.dart';

class ClientState {
  final AccountController account;
  ClientState({AccountController? account, TunnelController? tunnel})
    : account = account ?? AccountController(),
      tunnel = tunnel ?? TunnelController(platformTunnelEngine());
  final TunnelController tunnel;
  final applications = <String>{};
  final profiles = <VlessProfile>[];
  final rules = <RoutingRule>[];
  final subscriptions = <String, List<String>>{};
  final latency = <String, int>{};
  VoidCallback? onChanged;
  int selectedProfile = -1, demoProfile = 0;
  bool profilesLoaded = false, startupHandled = false;
  bool protectionBusy = false;
  String protectionStatus = 'unknown';
  DateTime lastSubscriptionRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  double radius = 24;
  bool compact = false, neutral = false, motion = true;
  static const optionDefaults = <String, Object>{
    'timeout': '15',
    'retry': '3',
    'protection': 'session',
    'mtu': 'auto',
    'fallback': true,
    'dns': 'profile',
    'dnsAddress': '',
    'ipv6': 'auto',
    'autoconnect': false,
    'notify': true,
    'russianServicesDirect': true,
    'updateInterval': '60',
  };
  final options = Map<String, Object>.of(optionDefaults);
  String appMode = 'all';
  bool reconnect = true, lan = false, autoConnect = false, notifications = true;
  TunnelConfig selectedTunnelConfig() {
    if (selectedProfile < 0 || selectedProfile >= profiles.length) {
      throw const FormatException('Сначала импортируй и выбери свой сервер');
    }
    return TunnelConfig.build(
      profile: profiles[selectedProfile],
      rules: rules,
      appMode: appMode,
      applications: applications,
      localNetwork: lan,
      russianServicesDirect: options['russianServicesDirect'] as bool,
      dns: options['dns'] == 'custom' ? options['dnsAddress'] as String : null,
      mtu: options['mtu'] == 'auto'
          ? 1500
          : int.parse(options['mtu'] as String),
      strict: options['protection'] == 'strict',
      reconnect: reconnect,
      retries: int.parse(options['retry'] as String),
    );
  }

  /// Invalid/absent selections explicitly clear the native tile cache, so an
  /// earlier server or a broader app-routing policy cannot be started instead.
  Map<String, dynamic>? quickTileProfile() {
    try {
      final config = selectedTunnelConfig();
      return {
        'version': 1,
        'name': profiles[selectedProfile].name,
        'config': jsonEncode(config.json),
        'allowed': config.allowedApps,
        'blocked': config.excludedApps,
        'mtu': config.mtu,
        'reconnect': config.reconnect,
        'retries': config.retries,
        'strict': config.requireLockdown,
      };
    } on FormatException {
      return null;
    }
  }

  bool get hasVioraSubscription => subscriptions.keys.any(
    (source) => isVioraSubscription(Uri.parse(source)),
  );
  bool isVioraProfile(int index) {
    if (index < 0 || index >= profiles.length) return false;
    final link = profiles[index].toShareLink();
    return subscriptions.entries.any(
      (entry) =>
          isVioraSubscription(Uri.parse(entry.key)) &&
          entry.value.contains(link),
    );
  }

  List<int> get vioraProfileIndices => [
    for (var i = 0; i < profiles.length; i++)
      if (isVioraProfile(i)) i,
  ];
  List<int> get otherProfileIndices => [
    for (var i = 0; i < profiles.length; i++)
      if (!isVioraProfile(i)) i,
  ];
  Map<String, dynamic> toJson() => {
    'rules': rules.map((r) => r.toJson()).toList(),
    'appMode': appMode,
    'applications': applications.toList(),
    'reconnect': reconnect,
    'lan': lan,
    'options': Map<String, Object>.of(options),
    'radius': radius,
    'compact': compact,
    'neutral': neutral,
    'motion': motion,
  };
  void restore(Map<String, dynamic> data) {
    final parsed = (data['rules'] as List? ?? [])
        .map((r) => RoutingRule.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList();
    if (parsed.length > 200) {
      throw const FormatException('Слишком много правил');
    }
    final mode = data['appMode'] as String? ?? 'all';
    if (!['all', 'only', 'except'].contains(mode)) {
      throw const FormatException('Неверный режим приложений');
    }
    final savedReconnect = data['reconnect'] as bool? ?? true;
    final savedApps = (data['applications'] as List? ?? [])
        .cast<String>()
        .toSet();
    if (savedApps.length > 1000 ||
        savedApps.any(
          (id) => Platform.isWindows || Platform.isLinux
              ? !DesktopApplications.valid(id, Platform.operatingSystem)
              : !RegExp(
                  r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$',
                ).hasMatch(id),
        )) {
      throw const FormatException('Список приложений');
    }
    final savedLan = data['lan'] as bool? ?? false;
    final savedRadius = (data['radius'] as num? ?? 24).toDouble();
    if (![12.0, 24.0, 32.0].contains(savedRadius)) {
      throw const FormatException('Форма карточек');
    }
    final savedCompact = data['compact'] as bool? ?? false;
    final savedNeutral = data['neutral'] as bool? ?? false;
    final savedMotion = data['motion'] as bool? ?? true;
    final savedOptions = Map<String, Object>.of(optionDefaults);
    final incomingOptions = data['options'] as Map? ?? {};
    for (final key in optionDefaults.keys) {
      if (!incomingOptions.containsKey(key)) continue;
      final value = incomingOptions[key];
      if ((optionDefaults[key] is bool && value is! bool) ||
          (optionDefaults[key] is String && value is! String)) {
        throw const FormatException('Параметры');
      }
      savedOptions[key] = value as Object;
    }
    for (final entry in <String, List<String>>{
      'timeout': ['10', '15', '30'],
      'retry': ['3', '5'],
      'protection': ['session', 'strict'],
      'mtu': ['auto', '1280', '1420'],
      'dns': ['profile', 'custom'],
      'ipv6': ['auto', 'block'],
      'updateInterval': ['manual', '60', '360'],
    }.entries) {
      if (!entry.value.contains(savedOptions[entry.key])) {
        throw const FormatException('Параметры');
      }
    }
    if ((savedOptions['dnsAddress'] as String).length > 64) {
      throw const FormatException('DNS');
    }
    rules.clear();
    rules.addAll(parsed);
    appMode = mode;
    applications.clear();
    applications.addAll(savedApps);
    reconnect = savedReconnect;
    lan = savedLan;
    radius = savedRadius;
    compact = savedCompact;
    neutral = savedNeutral;
    motion = savedMotion;
    options.addAll(savedOptions);
  }
}

class ClientPage extends StatefulWidget {
  final bool desktop, demo;
  final int index;
  final ClientState state;
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onTheme;
  final ValueChanged<Color> onAccent;
  final ValueChanged<int> onNavigate;
  final Future<void> Function(ControlRepository) onRepository;
  final Future<ImportedConnection> Function(String)? loadSubscription;
  final Future<int?> Function()? connectedProbe;
  final Future<int> Function(String, int)? measureLatency;
  const ClientPage({
    super.key,
    required this.index,
    required this.state,
    required this.mode,
    required this.onTheme,
    required this.onAccent,
    required this.onNavigate,
    required this.onRepository,
    this.loadSubscription,
    this.connectedProbe,
    this.measureLatency,
    this.desktop = false,
    this.demo = false,
  });
  @override
  State<ClientPage> createState() => ClientPageState();
}

class ClientPageState extends State<ClientPage> with WidgetsBindingObserver {
  Timer? _maintenanceTimer;
  Timer? _startupMaintenance;
  bool _maintenanceBusy = false;
  String? _refreshedSelection;
  bool _reconcilingRefresh = false, _refreshReconnectSilent = true;

  String? get _selectedLink {
    final state = widget.state, selected = widget.state.selectedProfile;
    return selected >= 0 && selected < state.profiles.length
        ? state.profiles[selected].toShareLink()
        : null;
  }

  void _subscriptionTunnelChanged() {
    if (_refreshedSelection == null) return;
    // Native callbacks can run inside another controller operation. Drain after
    // that operation has unwound, and never restart a manually stopped session.
    if (widget.state.tunnel.phase == TunnelPhase.stopping) {
      _refreshedSelection = null;
      return;
    }
    scheduleMicrotask(() {
      if (mounted) unawaited(_reconcileRefreshedSelection());
    });
  }

  Future<void> _reconcileRefreshedSelection() async {
    if (!mounted || refreshing || _reconcilingRefresh) return;
    final target = _refreshedSelection;
    if (target == null) return;
    final tunnel = widget.state.tunnel;
    if (_selectedLink != target) {
      _refreshedSelection = null;
      return;
    }
    if (tunnel.busy) return;
    _refreshedSelection = null;
    if (!tunnel.running) return;
    _reconcilingRefresh = true;
    final silent = _refreshReconnectSilent;
    try {
      final state = widget.state;
      final config = state.selectedTunnelConfig();
      await tunnel.switchServer(
        config,
        state.profiles[state.selectedProfile].name,
        timeout: Duration(
          seconds: int.parse(state.options['timeout'] as String),
        ),
      );
      if (mounted && !silent && tunnel.error != null) notice(tunnel.error!);
    } on FormatException catch (error) {
      if (mounted && !silent) notice(error.message.toString());
    } finally {
      _reconcilingRefresh = false;
      if (mounted && _refreshedSelection != null) _subscriptionTunnelChanged();
    }
  }

  @override
  void initState() {
    super.initState();
    widget.state.tunnel.addListener(_subscriptionTunnelChanged);
    if (Platform.isAndroid || Platform.isWindows || Platform.isLinux) {
      WidgetsBinding.instance.addObserver(this);
      _maintenanceTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _maintain(),
      );
      _startupMaintenance = Timer(
        const Duration(seconds: 2),
        () => unawaited(_maintain()),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_maintain());
  }

  @override
  void didUpdateWidget(covariant ClientPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state)) {
      oldWidget.state.tunnel.removeListener(_subscriptionTunnelChanged);
      _refreshedSelection = null;
      widget.state.tunnel.addListener(_subscriptionTunnelChanged);
    }
  }

  Future<void> _maintain() async {
    if (!mounted ||
        _maintenanceBusy ||
        !widget.state.profilesLoaded ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _maintenanceBusy = true;
    try {
      final state = widget.state;
      await state.tunnel.initialize();
      if (state.tunnel.engine is TunnelStatusReader &&
          !await state.tunnel.synchronizeNativeStatus()) {
        return;
      }
      if (!mounted) return;
      if (!state.startupHandled) {
        state.startupHandled = true;
        if (state.options['autoconnect'] == true &&
            state.selectedProfile >= 0 &&
            state.tunnel.phase == TunnelPhase.disconnected) {
          await toggleTunnel();
        }
      }
      final interval = int.tryParse(state.options['updateInterval'] as String);
      if (interval != null &&
          state.subscriptions.isNotEmpty &&
          !state.tunnel.busy &&
          DateTime.now().difference(state.lastSubscriptionRefresh) >=
              Duration(minutes: interval)) {
        state.lastSubscriptionRefresh = DateTime.now();
        await refreshSubscriptions(silent: true);
      }
    } finally {
      _maintenanceBusy = false;
    }
  }

  @override
  void dispose() {
    _maintenanceTimer?.cancel();
    _startupMaintenance?.cancel();
    widget.state.tunnel.removeListener(_subscriptionTunnelChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String message = '';
  void notice(String value) {
    setState(() => message = value);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> import() async {
    final value = await showDialog<ImportedConnection>(
      context: context,
      builder: (context) => const ImportDialog(),
    );
    if (value == null || !mounted) return;
    applyImport(value);
  }

  VlessProfile? _subscriptionReplacement(
    VlessProfile previous,
    List<VlessProfile> imported,
  ) {
    final compatible = <String, VlessProfile>{
      for (final profile in imported)
        if (profile.transport == previous.transport &&
            profile.security == previous.security)
          profile.toShareLink(): profile,
    }.values.toList();
    final endpoint = compatible
        .where(
          (profile) =>
              profile.host.toLowerCase() == previous.host.toLowerCase() &&
              profile.port == previous.port,
        )
        .toList();
    if (endpoint.length == 1) return endpoint.single;
    final name = compatible
        .where((profile) => profile.name == previous.name)
        .toList();
    if (name.length == 1) return name.single;
    return compatible.length == 1 ? compatible.single : null;
  }

  bool applyImport(ImportedConnection value, {bool silent = false}) {
    final state = widget.state;
    if (value.profiles.isEmpty) {
      if (!silent) notice('В подписке нет поддерживаемых серверов');
      return false;
    }
    if (value.source != null &&
        !state.subscriptions.containsKey(value.source) &&
        state.subscriptions.length >= 200) {
      if (!silent) notice('Можно сохранить до 200 подписок');
      return false;
    }
    final oldLinks = state.subscriptions[value.source] ?? <String>[];
    final otherLinks = state.subscriptions.entries
        .where((e) => e.key != value.source)
        .expand((e) => e.value)
        .toSet();
    final remaining = state.profiles
        .where(
          (p) =>
              !oldLinks.contains(p.toShareLink()) ||
              otherLinks.contains(p.toShareLink()),
        )
        .toList();
    final links = remaining.map((p) => p.toShareLink()).toSet();
    for (final p in value.profiles) {
      if (links.add(p.toShareLink())) remaining.add(p);
    }
    if (remaining.length > 200) {
      if (!silent) notice('Можно сохранить до 200 серверов');
      return false;
    }
    final currentProfile =
        state.selectedProfile >= 0 &&
            state.selectedProfile < state.profiles.length
        ? state.profiles[state.selectedProfile]
        : null;
    final current = currentProfile?.toShareLink();
    final previousIndex = remaining.indexWhere(
      (profile) => profile.toShareLink() == current,
    );
    // Match replacements only inside the provider that owned the removed
    // selection. Another provider or a manual import must not steal selection.
    final replacement =
        previousIndex < 0 &&
            currentProfile != null &&
            value.source != null &&
            oldLinks.contains(current)
        ? _subscriptionReplacement(currentProfile, value.profiles)
        : null;
    // If no criterion identifies one candidate, retain the existing first
    // incoming fallback instead of guessing between ambiguous servers.
    final fallback = (replacement ?? value.profiles.first).toShareLink();
    final selected = previousIndex >= 0
        ? previousIndex
        : remaining.indexWhere((profile) => profile.toShareLink() == fallback);
    setState(() {
      state.profiles
        ..clear()
        ..addAll(remaining);
      state.selectedProfile = selected;
      if (value.source != null) {
        state.subscriptions[value.source!] = value.profiles
            .map((p) => p.toShareLink())
            .toList();
      }
    });
    state.onChanged?.call();
    if (!silent) {
      notice(
        'Добавлено серверов: ${value.profiles.length}. Можно включать VPN.',
      );
    }
    return true;
  }

  bool refreshing = false;
  bool measuring = false;
  Future<void> checkLatency() async {
    final state = widget.state;
    if (measuring) return;
    if (state.tunnel.busy) {
      notice('Дождись завершения подключения или отключения VPN');
      return;
    }
    if (state.selectedProfile < 0 ||
        state.selectedProfile >= state.profiles.length) {
      notice('Сначала выбери сервер');
      return;
    }
    final profile = state.profiles[state.selectedProfile];
    final key = profile.toShareLink();
    bool selected() =>
        mounted && identical(widget.state, state) && _selectedLink == key;
    setState(() {
      measuring = true;
      state.latency.remove(key);
    });
    try {
      final value = await (widget.measureLatency ?? measureServerLatency)(
        profile.host,
        profile.port,
      );
      if (!mounted || !identical(widget.state, state)) return;
      setState(() {
        state.latency[key] = value;
      });
      if (!selected() || state.tunnel.busy) return;
      final probe =
          widget.connectedProbe ??
          (Platform.isAndroid ? () => AndroidConnectionProbe.measure() : null);
      if (probe != null && state.tunnel.running) {
        int? delay;
        try {
          delay = await probe();
        } catch (_) {
          // Keep the confirmed TCP result separate from a failed core probe.
        }
        if (!selected() || !state.tunnel.running || state.tunnel.busy) return;
        notice(
          delay != null && delay >= 0
              ? 'TCP-порт доступен: $value мс; тестовый сайт через VPN ответил за $delay мс.'
              : 'TCP-порт доступен, но нет ответа тестового сайта через VPN. Проверь другой сервер; этот сайт также может быть недоступен отдельно.',
        );
      } else {
        notice(
          'TCP-порт доступен: $value мс. Это проверка порта, она не подтверждает передачу данных через VPN.',
        );
      }
    } catch (_) {
      if (selected()) {
        notice(
          'TCP-порт сервера не ответил за 5 секунд. Проверь сеть и повтори.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          measuring = false;
        });
      }
    }
  }

  Future<void> refreshSubscriptions({bool silent = false}) async {
    if (refreshing || _reconcilingRefresh) return;
    if (widget.state.subscriptions.isEmpty) {
      if (!silent) await import();
      return;
    }
    setState(() {
      refreshing = true;
    });
    if (!silent) notice('Обновляем подписки…');
    widget.state.lastSubscriptionRefresh = DateTime.now();
    try {
      var updated = 0, failed = 0;
      final load = widget.loadSubscription ?? SubscriptionImporter().load;
      for (final source in widget.state.subscriptions.keys.toList()) {
        try {
          final result = await load(source);
          if (!mounted) return;
          final selectedBefore = _selectedLink;
          final tunnel = widget.state.tunnel;
          if (result.source == source && applyImport(result, silent: true)) {
            updated++;
            final selectedAfter = _selectedLink;
            if (selectedBefore != null &&
                selectedAfter != selectedBefore &&
                (tunnel.running || tunnel.busy)) {
              _refreshedSelection = selectedAfter;
              _refreshReconnectSilent = silent;
            }
          } else {
            failed++;
          }
        } catch (_) {
          if (!mounted) return;
          // One expired or unreachable provider must not block the others.
          // Do not surface exception text: it may contain a secret URL.
          failed++;
        }
      }
      if (!silent) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        notice(
          failed == 0
              ? 'Подписки обновлены: $updated.'
              : updated == 0
              ? 'Не удалось обновить подписки. Прежние серверы сохранены.'
              : 'Обновлено подписок: $updated. Не удалось обновить: $failed. Прежние серверы этих подписок сохранены.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          refreshing = false;
        });
      }
    }
    if (mounted) await _reconcileRefreshedSelection();
  }

  Future<void> toggleTunnel() async {
    final tunnel = widget.state.tunnel;
    if (tunnel.busy) return;
    if (tunnel.running) {
      _refreshedSelection = null;
      await tunnel.disconnect();
      return;
    }
    await connectTunnel();
  }

  /// Quick Settings requests a desired state, not an ambiguous toggle. This
  /// remains safe when a native event or auto-connect wins the startup race.
  Future<void> connectTunnel() async {
    final state = widget.state, tunnel = widget.state.tunnel;
    if (tunnel.busy || tunnel.running) return;
    if (!tunnel.engine.supported) {
      notice('VPN недоступен на этой платформе.');
      return;
    }
    if (state.selectedProfile < 0 ||
        state.selectedProfile >= state.profiles.length) {
      notice('Сначала импортируй и выбери свой сервер');
      return;
    }
    try {
      final profile = state.profiles[state.selectedProfile];
      final config = state.selectedTunnelConfig();
      await tunnel.connect(
        config,
        profile.name,
        timeout: Duration(
          seconds: int.parse(state.options['timeout'] as String),
        ),
      );
      if (mounted && tunnel.error != null) notice(tunnel.error!);
    } on FormatException catch (e) {
      notice(e.message.toString());
    }
  }

  Future<void> selectServer(int index) async {
    final state = widget.state, tunnel = widget.state.tunnel;
    if (index == state.selectedProfile ||
        index < 0 ||
        index >= state.profiles.length) {
      return;
    }
    if (tunnel.busy) {
      notice('Дождись завершения переключения VPN');
      return;
    }
    _refreshedSelection = null;
    final profile = state.profiles[index];
    try {
      final config = tunnel.running
          ? TunnelConfig.build(
              profile: profile,
              rules: state.rules,
              appMode: state.appMode,
              applications: state.applications,
              localNetwork: state.lan,
              russianServicesDirect:
                  state.options['russianServicesDirect'] as bool,
              dns: state.options['dns'] == 'custom'
                  ? state.options['dnsAddress'] as String
                  : null,
              mtu: state.options['mtu'] == 'auto'
                  ? 1500
                  : int.parse(state.options['mtu'] as String),
              strict: state.options['protection'] == 'strict',
              reconnect: state.reconnect,
              retries: int.parse(state.options['retry'] as String),
            )
          : null;
      setState(() => state.selectedProfile = index);
      state.onChanged?.call();
      if (config != null) {
        notice('Переключаем VPN на ${profile.name}…');
        await tunnel.switchServer(
          config,
          profile.name,
          timeout: Duration(
            seconds: int.parse(state.options['timeout'] as String),
          ),
        );
        if (mounted && tunnel.error != null) notice(tunnel.error!);
      }
    } on FormatException catch (e) {
      if (mounted) notice(e.message.toString());
    }
  }

  Future<void> loginTelegram() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AccountPage(
          account: widget.state.account,
          importSubscription: (source) async {
            try {
              final result = await SubscriptionImporter().load(source);
              if (mounted) applyImport(result);
            } on FormatException catch (e) {
              throw AccountError(e.message.toString());
            }
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> loginDevelopment() async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (context) => const _SessionDialog(),
    );
    if (result == null || !mounted) return;
    try {
      final api = ControlApi(Uri.parse(result.$1), result.$2);
      await widget.onRepository(api);
      notice('Сеанс проверен сервером. Права определяются сервером.');
    } catch (_) {
      notice('Не удалось проверить сеанс. Проверь адрес сервера и доступ.');
    }
  }

  @override
  Widget build(BuildContext context) =>
      (widget.desktop ||
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux)
      ? Padding(
          padding: widget.desktop ? EdgeInsets.zero : const EdgeInsets.all(16),
          child: ApprovedContent(
            index: widget.index,
            state: widget.state,
            mode: widget.mode,
            demo: widget.demo,
            onTheme: widget.onTheme,
            onAccent: widget.onAccent,
            onNavigate: widget.onNavigate,
            onImport: import,
            onLogin: loginTelegram,
            onRefresh: refreshSubscriptions,
            onPing: checkLatency,
            onSelectServer: selectServer,
            refreshing: refreshing,
            measuring: measuring,
            onNotice: notice,
            onConnect: toggleTunnel,
            onChanged: () {
              setState(() {});
              widget.state.onChanged?.call();
            },
          ),
        )
      : ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (widget.index == 0) ...[
              Text(
                'На своей\nволне.',
                style: Theme.of(
                  context,
                ).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 10),
              const Text('Твой интернет. Твои правила.'),
              const SizedBox(height: 30),
              Center(
                child: Container(
                  width: 156,
                  height: 156,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(40),
                  ),
                  child: Icon(
                    Icons.power_settings_new,
                    size: 64,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Center(
                child: Text(
                  'Не подключено',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => notice(
                  'VPN-движок ещё не интегрирован. Соединение не установлено; системные маршруты не изменялись.',
                ),
                child: const Text('Подключиться'),
              ),
              const SizedBox(height: 20),
              VioraPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Viora VPN',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Подключи свой аккаунт, чтобы получить подписку и управлять продлением.',
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton(
                      onPressed: () => widget.onNavigate(2),
                      child: const Text('Моя подписка'),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: import,
                icon: const Icon(Icons.add),
                label: const Text('Импортировать сервер'),
              ),
            ] else if (widget.index == 1) ...[
              Text(
                'Серверы',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 18),
              for (final p in widget.state.profiles)
                VioraPanel(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.dns_outlined),
                    title: Text(p.name),
                    subtitle: Text(
                      'VLESS · ${p.transport.toUpperCase()} · ${p.security.toUpperCase()}',
                    ),
                  ),
                ),
              if (widget.state.profiles.isEmpty)
                const VioraPanel(
                  child: Text(
                    'Серверы ещё не добавлены. Вставь ссылку VLESS или позже подключи подписку Viora.',
                  ),
                ),
              FilledButton.icon(
                onPressed: import,
                icon: const Icon(Icons.add),
                label: const Text('Добавить сервер'),
              ),
            ] else if (widget.index == 2) ...[
              Text(
                'Моя подписка',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 18),
              const VioraPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Аккаунт ещё не подключён'),
                    SizedBox(height: 12),
                    Text(
                      'Вход через Telegram, тарифы, инструкция СБП и статусы платежей подключаются на этапе интеграции с ботом.',
                    ),
                  ],
                ),
              ),
              OutlinedButton(
                onPressed: loginDevelopment,
                child: const Text('Подключить сервер разработки'),
              ),
            ] else if (widget.index == 3) ...[
              Text(
                'Маршрутизация',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 18),
              RoutingEditor(
                rules: widget.state.rules,
                onChanged: () => widget.state.onChanged?.call(),
              ),
              const SizedBox(height: 18),
              OutlinedButton(
                onPressed: () => widget.onNavigate(
                  MediaQuery.sizeOf(context).width >= 850 ? 6 : 4,
                ),
                child: const Text('VPN для приложений'),
              ),
            ] else ...[
              Text(switch (widget.index) {
                6 => 'Приложения',
                7 => 'Внешний вид',
                _ => 'Настройки',
              }, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 18),
              if (widget.index != 6)
                VioraPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Внешний вид',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 14),
                      DropdownButtonFormField<ThemeMode>(
                        initialValue: widget.mode,
                        decoration: const InputDecoration(labelText: 'Тема'),
                        items: const [
                          DropdownMenuItem(
                            value: ThemeMode.system,
                            child: Text('Системная'),
                          ),
                          DropdownMenuItem(
                            value: ThemeMode.dark,
                            child: Text('Тёмная'),
                          ),
                          DropdownMenuItem(
                            value: ThemeMode.light,
                            child: Text('Светлая'),
                          ),
                        ],
                        onChanged: (v) => widget.onTheme(v!),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final c in [
                            const Color(0xffbfa0ff),
                            const Color(0xff8dbaff),
                            const Color(0xffffadd3),
                          ])
                            IconButton(
                              onPressed: () => widget.onAccent(c),
                              icon: Icon(Icons.circle, color: c),
                              tooltip: 'Цвет акцента',
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              if (widget.index == 4)
                VioraPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Соединение',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Переподключение'),
                        value: widget.state.reconnect,
                        onChanged: (v) {
                          setState(() => widget.state.reconnect = v);
                          widget.state.onChanged?.call();
                        },
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Доступ к локальной сети'),
                        value: widget.state.lan,
                        onChanged: (v) {
                          setState(() => widget.state.lan = v);
                          widget.state.onChanged?.call();
                        },
                      ),
                      const Text(
                        'Windows и Linux сохраняют настройки между запусками. Сетевое применение пока недоступно.',
                      ),
                    ],
                  ),
                ),
              if (widget.index != 7)
                VioraPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'VPN для приложений',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 14),
                      DropdownButtonFormField<String>(
                        initialValue: widget.state.appMode,
                        decoration: const InputDecoration(labelText: 'Режим'),
                        items: const [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text('Все через VPN'),
                          ),
                          DropdownMenuItem(
                            value: 'only',
                            child: Text('Только выбранные через VPN'),
                          ),
                          DropdownMenuItem(
                            value: 'except',
                            child: Text('Выбранные напрямую'),
                          ),
                        ],
                        onChanged: (v) {
                          setState(() => widget.state.appMode = v!);
                          widget.state.onChanged?.call();
                        },
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Выбор приложений пока не подключён. Windows потребует системную фильтрацию трафика, Linux — отдельные правила для процессов. На Android используется VpnService.',
                      ),
                    ],
                  ),
                ),
              if (widget.index == 4)
                const VioraPanel(
                  child: Text(
                    'DNS, IPv6, защита при обрыве, HWID и обновление подписки остаются обязательными задачами системной интеграции.',
                  ),
                ),
            ],
            if (message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Text(message),
              ),
          ],
        );
}

class _SessionDialog extends StatefulWidget {
  const _SessionDialog();
  @override
  State<_SessionDialog> createState() => _SessionDialogState();
}

class _SessionDialogState extends State<_SessionDialog> {
  final server = TextEditingController(
        text: defaultTargetPlatform == TargetPlatform.android
            ? 'http://10.0.2.2:8765'
            : 'http://127.0.0.1:8765',
      ),
      token = TextEditingController();
  @override
  void dispose() {
    server.dispose();
    token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Сервер разработки'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Только для проверки API. Это не вход через Telegram. Сеанс хранится в памяти до закрытия приложения.',
          ),
          const SizedBox(height: 14),
          TextField(
            controller: server,
            decoration: const InputDecoration(labelText: 'Адрес API'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: token,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Сеанс разработки'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, (server.text.trim(), token.text.trim())),
        child: const Text('Подключить'),
      ),
    ],
  );
}
