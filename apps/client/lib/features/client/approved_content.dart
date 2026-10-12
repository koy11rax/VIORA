import 'hwid_page.dart';
import 'package:flutter/material.dart';
import '../../ui/design.dart';
import 'client_page.dart' show ClientState;
import 'routing_page.dart';
import 'settings_detail.dart';
import 'application_picker.dart';
import '../../platform/tunnel.dart';
import 'dart:io';
import 'renewal_page.dart';
import 'devices_page.dart';

class ApprovedContent extends StatelessWidget {
  final int index;
  final ClientState state;
  final ThemeMode mode;
  final bool demo;
  final ValueChanged<ThemeMode> onTheme;
  final ValueChanged<Color> onAccent;
  final ValueChanged<int> onNavigate;
  final VoidCallback onImport, onLogin, onConnect, onChanged, onRefresh;
  final VoidCallback? onPing;
  final ValueChanged<int>? onSelectServer;
  final bool refreshing, measuring;
  final ValueChanged<String> onNotice;
  const ApprovedContent({
    super.key,
    required this.index,
    required this.state,
    required this.mode,
    required this.demo,
    required this.onTheme,
    required this.onAccent,
    required this.onNavigate,
    required this.onImport,
    required this.onLogin,
    required this.onRefresh,
    required this.onConnect,
    required this.onChanged,
    required this.onNotice,
    this.onPing,
    this.onSelectServer,
    this.refreshing = false,
    this.measuring = false,
  });
  Widget button(
    String text,
    VoidCallback onPressed, {
    bool primary = false,
    IconData? icon,
  }) => primary
      ? FilledButton(onPressed: onPressed, child: Text(text))
      : OutlinedButton(
          onPressed: onPressed,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 19),
                const SizedBox(width: 9),
              ],
              Flexible(child: Text(text)),
            ],
          ),
        );
  Widget fullButton(
    String text,
    VoidCallback onPressed, {
    bool primary = false,
    IconData? icon,
  }) => SizedBox(
    width: double.infinity,
    child: icon == null
        ? button(text, onPressed, primary: primary)
        : primary
        ? FilledButton.icon(
            onPressed: onPressed,
            icon: Icon(icon, size: 20),
            label: Text(text),
          )
        : OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon, size: 20),
            label: Text(text),
          ),
  );
  Widget title(String value) => Text(
    value,
    style: const TextStyle(
      fontSize: 17,
      height: 1.35,
      fontWeight: FontWeight.w500,
    ),
  );
  Widget gap([double height = 14]) => SizedBox(height: height);
  void unavailable(String feature) =>
      onNotice('$feature ещё не подключено к боту и VPN-серверу.');

  void openRenewal(BuildContext context) {
    if (state.account.value == null) {
      onLogin();
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => RenewalPage(account: state.account)),
    );
  }

  void openDevices(BuildContext context) {
    if (state.account.value == null) {
      onLogin();
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DevicesPage(account: state.account)),
    );
  }

  Widget provider(BuildContext context) {
    final c = VioraColors(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            top: -48,
            right: -36,
            child: Transform.rotate(
              angle: .31,
              child: Container(
                width: 150,
                height: 150,
                decoration: BoxDecoration(
                  border: Border.all(color: c.soft, width: 28),
                  borderRadius: BorderRadius.circular(40),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const DesignTag('VIORA VPN · ПОДПИСКА'),
                gap(18),
                const Text(
                  'Твоя связь.\nТвои возможности.',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -.5,
                  ),
                ),
                gap(10),
                Text(
                  demo
                      ? 'Активна до 10 ноября 2026 · пример'
                      : state.account.value?.expires != null
                      ? 'Подписка до ${state.account.value!.expires!.toLocal().day}.${state.account.value!.expires!.toLocal().month}.${state.account.value!.expires!.toLocal().year}'
                      : !state.hasVioraSubscription
                      ? 'Добавь ссылку подписки из своего бота'
                      : 'Подписка импортирована · ${state.vioraProfileIndices.length} серверов',
                  style: TextStyle(fontSize: 12, color: c.muted),
                ),
                gap(18),
                fullButton(
                  'Продлить подписку',
                  () => openRenewal(context),
                  primary: true,
                  icon: Icons.autorenew,
                ),
                gap(18),
                Divider(color: c.line, height: 1),
                gap(14),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    Text(
                      demo
                          ? '1 из 3 устройств · демо'
                          : state.account.value != null
                          ? 'Telegram · ${state.account.value!.name}'
                          : 'Telegram не связан',
                      style: TextStyle(fontSize: 11, color: c.muted),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.fingerprint, size: 19, color: c.muted),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            state.hasVioraSubscription
                                ? 'HWID · передан при импорте'
                                : 'HWID · только для Viora',
                            style: TextStyle(fontSize: 11, color: c.muted),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static const demoNames = [
    'Основной',
    'Альтернативный',
    'REALITY',
    'Мой сервер',
  ];
  static const demoProtocols = [
    'VLESS · WS TLS',
    'VLESS · XHTTP TLS',
    'VLESS · Vision',
    'WireGuard',
  ];
  String get selectedName =>
      state.selectedProfile >= 0 &&
          state.selectedProfile < state.profiles.length
      ? state.profiles[state.selectedProfile].name
      : demo
      ? demoNames[state.demoProfile]
      : 'Сервер не выбран';
  String get selectedProtocol =>
      state.selectedProfile >= 0 &&
          state.selectedProfile < state.profiles.length
      ? 'VLESS · ${state.profiles[state.selectedProfile].transport.toUpperCase()} · ${state.profiles[state.selectedProfile].security.toUpperCase()}'
      : demo
      ? demoProtocols[state.demoProfile]
      : 'Импортируй профиль или подключи подписку';

  Widget home(BuildContext context) {
    final c = VioraColors(context);
    final hero = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'На своей\nволне.',
          style: TextStyle(
            fontSize: 44,
            height: 1.08,
            letterSpacing: -1.3,
            fontWeight: FontWeight.w500,
          ),
        ),
        gap(12),
        Text('Твой интернет. Твои правила.', style: TextStyle(color: c.muted)),
        gap(24),
        Center(
          child: Column(
            children: [
              PowerOrbit(onPressed: onConnect),
              gap(10),
              Text(
                state.tunnel.label,
                style: const TextStyle(
                  fontSize: 20,
                  letterSpacing: -.4,
                  fontWeight: FontWeight.w500,
                ),
              ),
              gap(6),
              Text(
                state.tunnel.phase == TunnelPhase.active
                    ? 'Туннель запущен · ${state.tunnel.activeProfile ?? 'Android VPN'}'
                    : state.tunnel.error ?? 'Выбери сервер и включи VPN',
                style: TextStyle(fontSize: 12, color: c.muted),
                textAlign: TextAlign.center,
              ),
              gap(22),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: fullButton(
                  state.tunnel.running ? 'Отключиться' : 'Подключиться',
                  onConnect,
                  primary: true,
                  icon: state.tunnel.running
                      ? Icons.power_settings_new
                      : Icons.shield_outlined,
                ),
              ),
              gap(12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      textStyle: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(fontSize: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: refreshing ? null : onRefresh,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(
                      refreshing ? 'Обновляем…' : 'Обновить подписку',
                    ),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      textStyle: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(fontSize: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: measuring ? null : onPing,
                    icon: const Icon(Icons.speed, size: 16),
                    label: Text(measuring ? 'Проверяем…' : 'Проверить пинг'),
                  ),
                ],
              ),
              if (state.selectedProfile >= 0 &&
                  state.selectedProfile < state.profiles.length &&
                  state.latency[state.profiles[state.selectedProfile]
                          .toShareLink()] !=
                      null)
                Text(
                  'TCP · ${state.latency[state.profiles[state.selectedProfile].toShareLink()]} мс',
                  style: TextStyle(fontSize: 12, color: c.muted),
                ),
            ],
          ),
        ),
        gap(20),
        Divider(color: c.line, height: 1),
        gap(18),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final item in [
              [
                'Время',
                state.tunnel.phase == TunnelPhase.active
                    ? state.tunnel.stats.duration
                    : '—',
              ],
              ['Сервер', selectedName],
              [
                'Трафик',
                state.tunnel.phase == TunnelPhase.active
                    ? '${((state.tunnel.stats.upload + state.tunnel.stats.download) / 1048576).toStringAsFixed(1)} МБ'
                    : '—',
              ],
            ])
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item[0],
                      style: TextStyle(fontSize: 11, color: c.muted),
                    ),
                    gap(4),
                    Text(
                      item[1],
                      style: const TextStyle(fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
    final right = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        provider(context),
        gap(),
        DesignCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ВЫБРАННЫЙ ПРОФИЛЬ',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.3,
                  color: c.muted,
                ),
              ),
              gap(),
              Row(
                children: [
                  serverIcon(context),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        title(selectedName),
                        gap(4),
                        Text(
                          '$selectedProtocol\n${state.isVioraProfile(state.selectedProfile) ? 'Viora VPN' : 'Личный импорт'}',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: c.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              gap(),
              fullButton(
                'Выбрать сервер',
                () => onNavigate(1),
                icon: Icons.dns_outlined,
              ),
            ],
          ),
        ),
        gap(),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.shield_outlined, size: 19, color: c.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                state.tunnel.stats.lockdown
                    ? 'Android блокирует соединения вне VPN. Строгая системная защита включена.'
                    : Platform.isAndroid
                    ? 'Защита действует во время VPN-сессии. Постоянный VPN и блокировку вне VPN можно включить в настройках Android.'
                    : 'Защита действует во время VPN-сессии. Постоянная блокировка вне VPN пока недоступна.',
                style: TextStyle(fontSize: 12, height: 1.5, color: c.muted),
              ),
            ),
          ],
        ),
        TextButton(
          onPressed: onImport,
          style: TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: EdgeInsets.zero,
          ),
          child: const Text('+ Импортировать сервер или подписку'),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= 650
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 105, child: hero),
                const SizedBox(width: 28),
                Expanded(flex: 100, child: right),
              ],
            )
          : Column(children: [hero, gap(28), right]),
    );
  }

  Widget serverIcon(BuildContext context) => Container(
    width: 44,
    height: 44,
    decoration: BoxDecoration(
      color: VioraColors(context).raised,
      borderRadius: BorderRadius.circular(13),
    ),
    child: Icon(Icons.cell_tower, color: VioraColors(context).accent, size: 20),
  );
  Widget serverRow(
    BuildContext context,
    String name,
    String protocol,
    String hint,
    bool selected,
    VoidCallback onTap, {
    int? latency,
  }) {
    final c = VioraColors(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected ? c.soft : c.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: selected ? c.accent : c.line),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                serverIcon(context),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      gap(4),
                      Text(
                        '$protocol\n$hint',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: c.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Icon(
                      selected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: selected ? c.accent : c.muted,
                      size: 22,
                    ),
                    if (latency != null) ...[
                      gap(6),
                      Text(
                        '$latency мс',
                        style: TextStyle(fontSize: 12, color: c.muted),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget importedServer(
    BuildContext context,
    int i,
    String source,
  ) => serverRow(
    context,
    state.profiles[i].name,
    'VLESS · ${state.profiles[i].transport.toUpperCase()} · ${state.profiles[i].security.toUpperCase()}',
    source,
    state.selectedProfile == i,
    () {
      if (onSelectServer != null) {
        onSelectServer!(i);
      } else {
        state.selectedProfile = i;
        onChanged();
      }
    },
    latency: state.latency[state.profiles[i].toShareLink()],
  );

  Widget servers(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const DesignHeading(
        'Твои серверы',
        'Подписка твоего VPN и личные подключения — в одном месте.',
      ),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: title('Viora VPN')),
          button(
            state.hasVioraSubscription ? 'Обновить' : 'Подключить',
            state.hasVioraSubscription ? onRefresh : onImport,
            icon: Icons.refresh,
          ),
        ],
      ),
      gap(12),
      if (demo) ...[
        for (var i = 0; i < 3; i++)
          serverRow(
            context,
            demoNames[i],
            demoProtocols[i],
            'Тот же сервер · транспорт · демо',
            state.selectedProfile == -1 && state.demoProfile == i,
            () {
              state.demoProfile = i;
              state.selectedProfile = -1;
              onChanged();
            },
          ),
        Text(
          'Три транспорта одного сервера · один слот устройства · демо',
          style: TextStyle(fontSize: 12, color: VioraColors(context).muted),
        ),
      ] else if (state.vioraProfileIndices.isNotEmpty) ...[
        for (final i in state.vioraProfileIndices)
          importedServer(context, i, 'Подписка Viora VPN'),
      ] else
        DesignCard(
          child: Text(
            'Подписка Viora ещё не подключена. Добавь ссылку из своего бота.',
            style: TextStyle(color: VioraColors(context).muted),
          ),
        ),
      gap(22),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: title('Другие серверы')),
          button('Импорт', onImport, icon: Icons.add),
        ],
      ),
      gap(12),
      if (demo)
        serverRow(
          context,
          demoNames[3],
          demoProtocols[3],
          'Личный импорт · демо',
          state.selectedProfile == -1 && state.demoProfile == 3,
          () {
            state.demoProfile = 3;
            state.selectedProfile = -1;
            onChanged();
          },
        ),
      for (final i in state.otherProfileIndices)
        importedServer(
          context,
          i,
          state.subscriptions.values.any(
                (links) => links.contains(state.profiles[i].toShareLink()),
              )
              ? 'Другая подписка'
              : 'Личный импорт',
        ),
      if (!demo && state.otherProfileIndices.isEmpty)
        const DesignCard(
          child: Text(
            'Серверы ещё не добавлены. Вставь ссылку подписки из бота или VLESS.',
          ),
        ),
    ],
  );

  Widget subscription(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const DesignHeading(
        'Моя подписка',
        'Всё для твоего VPN — без поиска ссылки и лишних настроек.',
      ),
      provider(context),
      gap(16),
      LayoutBuilder(
        builder: (context, c) {
          final cards = [
            DesignCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title('Это устройство'),
                  gap(),
                  DesignSetting(
                    'Подписка Viora',
                    'Серверы из твоего бота',
                    DesignTag(
                      state.hasVioraSubscription
                          ? 'Импортирована'
                          : 'Не добавлена',
                    ),
                  ),
                  DesignSetting(
                    'Отправка HWID',
                    'При импорте и обновлении подписки Viora',
                    DesignTag(
                      state.hasVioraSubscription
                          ? 'Автоматически'
                          : 'При подключении',
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => HwidPage(
                          hasSubscription: state.hasVioraSubscription,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.fingerprint),
                    label: const Text('Мой HWID'),
                  ),
                ],
              ),
            ),
            DesignCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title('Управление'),
                  gap(),
                  Text(
                    state.account.value == null
                        ? 'Свяжи Telegram: срок подписки, устройства и продление появятся здесь.'
                        : 'Тарифы, инструкция СБП и статус оплаты доступны в Viora. Подписка общая с твоим Telegram-ботом.',
                  ),
                  gap(),
                  fullButton(
                    'Продлить подписку',
                    () => openRenewal(context),
                    primary: true,
                  ),
                  gap(),
                  fullButton(
                    'Управлять устройствами',
                    () => openDevices(context),
                  ),
                  if (state.account.value != null) ...[
                    gap(),
                    Text(
                      'Занято ${state.account.value!.devices.length} из ${state.account.value!.deviceLimit} устройств',
                    ),
                  ],
                  gap(),
                  fullButton('Открыть аккаунт', onLogin),
                ],
              ),
            ),
          ];
          return c.maxWidth >= 650
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: cards[0]),
                    const SizedBox(width: 16),
                    Expanded(child: cards[1]),
                  ],
                )
              : Column(children: [cards[0], gap(16), cards[1]]);
        },
      ),
      gap(20),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          button('Обновить подписку', onRefresh),
          button('Добавить другую подписку', onImport),
        ],
      ),
      gap(24),
      DesignCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            title('Аккаунт Telegram'),
            gap(),
            const Text(
              'Свяжи Telegram, чтобы видеть срок подписки и устройства. Для самого подключения VPN вход не требуется.',
            ),
            gap(),
            button(
              state.account.value == null
                  ? 'Связать Telegram'
                  : 'Открыть аккаунт',
              onLogin,
            ),
          ],
        ),
      ),
    ],
  );

  Widget settings(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const DesignHeading(
        'Настройки',
        'Всё, что нужно для твоего VPN, — в одном месте.',
      ),
      for (final row in [
        (
          10,
          Icons.shield_outlined,
          'Соединение и защита',
          'Переподключение, блокировка трафика, локальная сеть',
        ),
        (
          3,
          Icons.route_outlined,
          'Маршрутизация',
          'Домены, IP и порты · порядок правил',
        ),
        (
          6,
          Icons.web_asset_outlined,
          'Приложения',
          'Выбор приложений для VPN или основной сети',
        ),
        (
          11,
          Icons.language,
          'DNS и IPv6',
          'DNS-профиль, свой сервер, IPv6-политика',
        ),
        (
          12,
          Icons.tune,
          'Приложение',
          'Автозапуск, уведомления, поведение окна',
        ),
        (
          13,
          Icons.fingerprint,
          'Подписки и приватность',
          'Обновления, HWID, локальный журнал',
        ),
        (
          7,
          Icons.palette_outlined,
          'Внешний вид',
          'Тема, свой цвет, фон, форма и плотность',
        ),
        (
          2,
          Icons.confirmation_number_outlined,
          'Моя подписка',
          'Срок, устройства, продление',
        ),
        (
          8,
          Icons.help_outline,
          'Помощь',
          'Проверка соединения и отчёт без секретов',
        ),
      ]) ...[
        DesignCard(
          padding: 0,
          child: ListTile(
            minVerticalPadding: 16,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: VioraColors(context).raised,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(row.$2, size: 19, color: VioraColors(context).accent),
            ),
            title: Text(
              row.$3,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            subtitle: Text(
              row.$4,
              style: TextStyle(fontSize: 12, color: VioraColors(context).muted),
            ),
            trailing: const Icon(Icons.chevron_right, size: 19),
            onTap: () => onNavigate(row.$1),
          ),
        ),
        gap(10),
      ],
    ],
  );

  Widget apps(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const DesignHeading(
        'VPN для приложений',
        'Выбери, какие приложения будут использовать VPN.',
      ),
      DesignCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            title('Режим маршрутизации'),
            gap(),
            RadioGroup<String>(
              groupValue: state.appMode,
              onChanged: (v) {
                state.appMode = v!;
                onChanged();
              },
              child: Column(
                children: [
                  for (final item in [
                    (
                      'all',
                      'Все через VPN',
                      'Единый маршрут для всех приложений',
                    ),
                    (
                      'only',
                      'Только выбранные через VPN',
                      'Остальные используют основную сеть',
                    ),
                    (
                      'except',
                      'Выбранные напрямую',
                      'Остальные используют VPN',
                    ),
                  ])
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      value: item.$1,
                      title: Text(item.$2),
                      subtitle: Text(
                        item.$3,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
            gap(),
            DesignTag(
              Platform.isAndroid
                  ? 'ANDROID · ПРИ СЛЕДУЮЩЕМ ПОДКЛЮЧЕНИИ'
                  : 'СИСТЕМНАЯ ИНТЕГРАЦИЯ В РАЗРАБОТКЕ',
            ),
            gap(),
            if (Platform.isAndroid && state.appMode != 'all')
              ApplicationPicker(
                selected: state.applications,
                onChanged: onChanged,
              )
            else
              Text(
                Platform.isAndroid
                    ? 'Все приложения используют VPN, кроме самой Viora. Для выбора приложений смени режим выше.'
                    : 'Режим сохраняется, но ещё не применяется. Выбор процессов и системная фильтрация будут подключены отдельно для Windows и Linux.',
              ),
          ],
        ),
      ),
    ],
  );

  Widget appearance(BuildContext context) {
    final c = VioraColors(context);
    final controls = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        title('Тема'),
        gap(12),
        Wrap(
          spacing: 8,
          children: [
            for (final item in [
              (ThemeMode.system, 'Системная'),
              (ThemeMode.light, 'Светлая'),
              (ThemeMode.dark, 'Тёмная'),
            ])
              ChoiceChip(
                label: Text(item.$2),
                selected: mode == item.$1,
                showCheckmark: false,
                onSelected: (_) => onTheme(item.$1),
              ),
          ],
        ),
        gap(24),
        title('Акцент'),
        gap(),
        Wrap(
          spacing: 12,
          children: [
            for (final color in [
              0xffc6a7ff,
              0xffa7baff,
              0xffffadd3,
              0xffffc08c,
              0xffdfd8eb,
            ])
              Semantics(
                button: true,
                label: 'Цвет акцента',
                child: InkWell(
                  onTap: () => onAccent(Color(color)),
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Color(color),
                      border: Border.all(color: c.panel, width: 4),
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [BoxShadow(color: c.line, spreadRadius: 1)],
                    ),
                  ),
                ),
              ),
          ],
        ),
        gap(),
        Text(
          'Фиолетовый — фирменный. Выбор цвета — твой.',
          style: TextStyle(color: c.muted),
        ),
        gap(12),
        button('Свой цвет', () async {
          final value = await showDialog<Color>(
            context: context,
            builder: (_) => const _HexColorDialog(),
          );
          if (value != null && context.mounted) onAccent(value);
        }),
        gap(24),
        title('Форма карточек'),
        gap(12),
        Wrap(
          spacing: 8,
          children: [
            for (final item in [
              (12.0, 'Строже'),
              (24.0, 'Баланс'),
              (32.0, 'Мягче'),
            ])
              ChoiceChip(
                label: Text(item.$2),
                selected: state.radius == item.$1,
                showCheckmark: false,
                onSelected: (_) {
                  state.radius = item.$1;
                  onChanged();
                },
              ),
          ],
        ),
        DesignSetting(
          'Плотность',
          'Размер отступов и списка серверов',
          DropdownButton<bool>(
            value: state.compact,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: false, child: Text('Свободно')),
              DropdownMenuItem(value: true, child: Text('Компактно')),
            ],
            onChanged: (v) {
              state.compact = v!;
              onChanged();
            },
          ),
        ),
        DesignSetting(
          'Анимации',
          'Учитывать системное снижение движения',
          Switch(
            value: state.motion,
            onChanged: (v) {
              state.motion = v;
              onChanged();
            },
          ),
        ),
        DesignSetting(
          'Фон',
          'Нейтральный или с фирменным оттенком',
          DropdownButton<bool>(
            value: state.neutral,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: false, child: Text('С оттенком')),
              DropdownMenuItem(value: true, child: Text('Нейтральный')),
            ],
            onChanged: (v) {
              state.neutral = v!;
              onChanged();
            },
          ),
        ),
        gap(18),
        button('Вернуть фирменный стиль', () {
          state.radius = 24;
          state.compact = false;
          state.motion = true;
          state.neutral = false;
          onTheme(ThemeMode.dark);
          onAccent(const Color(0xffc6a7ff));
          onChanged();
        }),
      ],
    );
    final preview = DesignCard(
      child: Column(
        children: [
          Text(
            'ТВОЙ СТИЛЬ',
            style: TextStyle(fontSize: 11, letterSpacing: 1.3, color: c.muted),
          ),
          gap(20),
          const Text(
            'На своей волне.',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w500),
          ),
          gap(20),
          PowerOrbit(size: 108, onPressed: () {}),
          gap(20),
          const DesignTag('Viora VPN'),
          gap(20),
          fullButton('Подключиться', onConnect, primary: true),
          gap(20),
          Text(
            'Предпросмотр компонентов',
            style: TextStyle(fontSize: 12, color: c.muted),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const DesignHeading(
          'Сделай по-своему',
          'Внешний вид — отдельный раздел. Настройки применяются ко всем экранам.',
        ),
        LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth >= 650
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 12, child: controls),
                    const SizedBox(width: 24),
                    Expanded(flex: 10, child: preview),
                  ],
                )
              : Column(children: [controls, gap(24), preview]),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: ValueKey('section-$index'),
    child: switch (index) {
      >= 10 => SettingsDetail(
        index: index,
        state: state,
        onChanged: onChanged,
        onNavigate: onNavigate,
        onNotice: onNotice,
      ),
      0 => home(context),
      1 => servers(context),
      2 => subscription(context),
      4 => settings(context),
      6 => apps(context),
      7 => appearance(context),
      3 => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const DesignHeading(
            'Маршрутизация',
            'Твой интернет идёт по твоим правилам.',
          ),
          RoutingEditor(
            rules: state.rules,
            onChanged: onChanged,
            appliesToAndroid: Platform.isAndroid,
          ),
          gap(20),
          button('VPN для приложений', () => onNavigate(6)),
        ],
      ),
      _ => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const DesignHeading(
            'Нужна помощь?',
            'Если соединение не работает, здесь можно понять причину.',
          ),
          DesignCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title('Проверка подключения'),
                DesignSetting(
                  'Туннель',
                  'Состояние соединения',
                  DesignTag(state.tunnel.label),
                ),
                const DesignSetting(
                  'DNS / IPv6',
                  'Проверка утечек',
                  DesignTag('В разработке'),
                ),
                gap(),
                Text(
                  Platform.isAndroid
                      ? 'Состояние приходит от Android. Запуск туннеля сам по себе не подтверждает доступность сервера: проверь открытие сайта после подключения.'
                      : 'Состояние приходит от VPN-компонента. При подключении подтверди системный запрос. Доступность сервера проверь открытием сайта.',
                ),
                gap(),
                button('Связаться через бота', () => unavailable('Поддержка')),
              ],
            ),
          ),
        ],
      ),
    },
  );
}

class _HexColorDialog extends StatefulWidget {
  const _HexColorDialog();
  @override
  State<_HexColorDialog> createState() => _HexColorDialogState();
}

class _HexColorDialogState extends State<_HexColorDialog> {
  final value = TextEditingController(text: '8B5CF6');
  String? error;
  @override
  void dispose() {
    value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Свой цвет'),
    content: TextField(
      controller: value,
      maxLength: 6,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: 'HEX',
        prefixText: '#',
        errorText: error,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(value.text)) {
            setState(() => error = 'Укажи 6 символов: 0–9, A–F');
            return;
          }
          Navigator.pop(
            context,
            Color(0xff000000 | int.parse(value.text, radix: 16)),
          );
        },
        child: const Text('Применить'),
      ),
    ],
  );
}
