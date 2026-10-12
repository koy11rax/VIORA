import 'dart:async';
import 'dart:io';
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
import '../../main.dart' show VioraPanel;
import 'approved_content.dart';
import 'import_dialog.dart';
import '../../platform/tunnel.dart';
import '../../domain/tunnel_config.dart';
import '../../data/server_latency.dart';

class ClientState {
  final AccountController account;
  ClientState({AccountController? account})
    : account = account ?? AccountController();
  final tunnel = TunnelController(platformTunnelEngine());
  final applications = <String>{};
  final profiles = <VlessProfile>[];
  final rules = <RoutingRule>[];
  final subscriptions = <String, List<String>>{};
  final latency = <String, int>{};
  VoidCallback? onChanged;
  int selectedProfile = -1, demoProfile = 0;
  bool profilesLoaded = false, startupHandled = false;
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
          (id) => !RegExp(
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
  const ClientPage({
    super.key,
    required this.index,
    required this.state,
    required this.mode,
    required this.onTheme,
    required this.onAccent,
    required this.onNavigate,
    required this.onRepository,
    this.desktop = false,
    this.demo = false,
  });
  @override
  State<ClientPage> createState() => ClientPageState();
}

class ClientPageState extends State<ClientPage> with WidgetsBindingObserver {
  Timer? _maintenanceTimer;
  bool _maintenanceBusy = false;
  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      WidgetsBinding.instance.addObserver(this);
      _maintenanceTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _maintain(),
      );
      unawaited(Future<void>.delayed(const Duration(seconds: 2), _maintain));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_maintain());
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

  void applyImport(ImportedConnection value, {bool silent = false}) {
    final state = widget.state;
    if (value.source != null &&
        !state.subscriptions.containsKey(value.source) &&
        state.subscriptions.length >= 200) {
      notice('Можно сохранить до 200 подписок');
      return;
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
      notice('Можно сохранить до 200 серверов');
      return;
    }
    final current =
        state.selectedProfile >= 0 &&
            state.selectedProfile < state.profiles.length
        ? state.profiles[state.selectedProfile].toShareLink()
        : null;
    setState(() {
      state.profiles
        ..clear()
        ..addAll(remaining);
      final previousIndex = remaining.indexWhere(
        (p) => p.toShareLink() == current,
      );
      state.selectedProfile = previousIndex >= 0
          ? previousIndex
          : remaining.indexWhere(
              (p) => p.toShareLink() == value.profiles.first.toShareLink(),
            );
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
  }

  bool refreshing = false;
  bool measuring = false;
  Future<void> checkLatency() async {
    final state = widget.state;
    if (measuring) return;
    if (state.selectedProfile < 0 ||
        state.selectedProfile >= state.profiles.length) {
      notice('Сначала выбери сервер');
      return;
    }
    final profile = state.profiles[state.selectedProfile];
    final key = profile.toShareLink();
    setState(() {
      measuring = true;
      state.latency.remove(key);
    });
    try {
      final value = await measureServerLatency(profile.host, profile.port);
      if (!mounted) return;
      setState(() {
        state.latency[key] = value;
      });
      notice(
        'Сервер отвечает: $value мс · TCP. При включённом VPN проверка идёт через текущий маршрут.',
      );
    } catch (_) {
      if (mounted) {
        notice('Сервер не ответил за 5 секунд. Проверь сеть и повтори.');
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
    if (refreshing) return;
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
      for (final source in widget.state.subscriptions.keys.toList()) {
        final result = await SubscriptionImporter().load(source);
        if (!mounted) return;
        applyImport(result, silent: silent);
      }
    } on FormatException catch (e) {
      if (mounted && !silent) notice(e.message.toString());
    } catch (_) {
      if (mounted && !silent) {
        notice('Не удалось обновить подписки. Прежние серверы сохранены.');
      }
    } finally {
      if (mounted) {
        setState(() {
          refreshing = false;
        });
      }
    }
  }

  Future<void> toggleTunnel() async {
    final state = widget.state, tunnel = widget.state.tunnel;
    if (tunnel.busy) return;
    if (tunnel.running || tunnel.phase == TunnelPhase.failed) {
      if (tunnel.running) {
        await tunnel.disconnect();
        return;
      }
    }
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
      final config = TunnelConfig.build(
        profile: profile,
        rules: state.rules,
        appMode: state.appMode,
        applications: state.applications,
        localNetwork: state.lan,
        russianServicesDirect: state.options['russianServicesDirect'] as bool,
        dns: state.options['dns'] == 'custom'
            ? state.options['dnsAddress'] as String
            : null,
        mtu: state.options['mtu'] == 'auto'
            ? 1500
            : int.parse(state.options['mtu'] as String),
        strict: state.options['protection'] == 'strict',
        reconnect: state.reconnect,
        retries: int.parse(state.options['retry'] as String),
      );
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
      (widget.desktop || defaultTargetPlatform == TargetPlatform.android)
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
