import 'hwid_page.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import '../../ui/design.dart';
import '../../platform/desktop_protection.dart';
import '../../platform/quick_settings.dart';
import '../../platform/tunnel.dart';
import 'client_page.dart' show ClientState;

class SettingsDetail extends StatelessWidget {
  final int index;
  final ClientState state;
  final VoidCallback onChanged;
  final ValueChanged<int> onNavigate;
  final ValueChanged<String> onNotice;
  final bool? quickSettingsSupported;
  const SettingsDetail({
    super.key,
    required this.index,
    required this.state,
    required this.onChanged,
    required this.onNavigate,
    required this.onNotice,
    this.quickSettingsSupported,
  });
  Future<void> _protection(BuildContext context, String action) async {
    if (state.protectionBusy) return;
    if (action != 'status' &&
        state.tunnel.phase != TunnelPhase.disconnected &&
        state.tunnel.phase != TunnelPhase.failed) {
      onNotice('Сначала отключи VPN и дождись остановки');
      return;
    }
    if (action == 'enable') {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Включить постоянную защиту?'),
          content: const Text(
            'Интернет будет недоступен без VPN, даже после закрытия VIORA и перезагрузки. Прямые исключения тоже блокируются. Снять блокировку можно здесь кнопкой «Выключить защиту».',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Включить'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
    }
    state.protectionBusy = true;
    onChanged();
    try {
      final enabled = await DesktopProtection.change(action);
      state.protectionStatus = enabled ? 'on' : 'off';
      state.options['protection'] = enabled ? 'strict' : 'session';
      onNotice(
        enabled
            ? 'Системная блокировка включена. Подключись к VPN'
            : 'Системная блокировка выключена',
      );
    } catch (error) {
      state.protectionStatus = 'unknown';
      onNotice(
        error is FormatException
            ? error.message
            : 'Не удалось подтвердить состояние защиты',
      );
    } finally {
      state.protectionBusy = false;
      onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget toggle(String key, String label, String description) =>
        DesignSetting(
          label,
          description,
          Switch(
            value: state.options[key] as bool,
            onChanged: (v) {
              state.options[key] = v;
              onChanged();
            },
          ),
        );
    Widget choose(
      String key,
      String label,
      String description,
      List<(String, String)> choices,
    ) => DesignSetting(
      label,
      description,
      DropdownButton<String>(
        isExpanded: true,
        value: state.options[key] as String,
        underline: const SizedBox.shrink(),
        items: [
          for (final c in choices)
            DropdownMenuItem(
              value: c.$1,
              enabled: true,
              child: Text(c.$2, style: const TextStyle(fontSize: 12)),
            ),
        ],
        onChanged: (v) {
          state.options[key] = v!;
          onChanged();
        },
      ),
    );
    final title = switch (index) {
      10 => 'Соединение и защита',
      11 => 'DNS и IPv6',
      12 => 'Приложение',
      _ => 'Подписки и приватность',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed: () => onNavigate(4),
          icon: const Icon(Icons.arrow_back, size: 19),
          label: const Text('Настройки'),
        ),
        DesignHeading(
          title,
          Platform.isAndroid
              ? 'Параметры применяются при следующем подключении. Восстановление работает в фоновой VPN-службе. Строгая защита включается в настройках Android.'
              : 'DNS, MTU и маршруты применяются при подключении VPN.',
        ),
        DesignCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (index == 10) ...[
                toggle(
                  'russianServicesDirect',
                  'Российские сервисы напрямую',
                  'VK, Госуслуги, Одноклассники, Mail, Яндекс, банки и домены .ru / .рф / .su — через обычный интернет. Применится при следующем подключении. Твои правила маршрутизации имеют приоритет.',
                ),
                DesignSetting(
                  'Восстанавливать соединение',
                  Platform.isAndroid
                      ? 'При смене Wi-Fi и мобильной сети и при остановке VPN-движка'
                      : 'После неожиданной остановки движка или службы. Ручное отключение отменяет повторные попытки',
                  Switch(
                    value: state.reconnect,
                    onChanged: (v) {
                      state.reconnect = v;
                      onChanged();
                    },
                  ),
                ),
                choose(
                  'timeout',
                  'Ожидание подключения',
                  'Максимальное ожидание первого запуска',
                  [
                    ('10', '10 секунд'),
                    ('15', '15 секунд'),
                    ('30', '30 секунд'),
                  ],
                ),
                choose(
                  'retry',
                  'Количество попыток',
                  'Число попыток восстановления; пауза увеличивается после ошибки',
                  [('3', '3 попытки'), ('5', '5 попыток')],
                ),
                if (Platform.isAndroid)
                  choose(
                    'protection',
                    'Защита при обрыве',
                    Platform.isAndroid
                        ? 'Строгий режим требует системной блокировки соединений без VPN'
                        : 'Защита действует в пределах VPN-сессии. Постоянная блокировка вне VPN для ПК пока недоступна',
                    [
                      ('session', 'В пределах VPN-сессии'),
                      ('strict', 'Строго: без выхода напрямую'),
                    ],
                  ),
                if (Platform.isWindows || Platform.isLinux) ...[
                  DesignSetting(
                    'Постоянная блокировка без VPN',
                    'Сохраняется при закрытии VIORA и перезагрузке. Приложения и сервисы, выбранные напрямую, тоже потеряют доступ. Подключение VPN само блокировку не выключает.',
                    DesignTag(switch (state.protectionStatus) {
                      'on' => 'Включена',
                      'off' => 'Выключена',
                      _ => 'Не проверена',
                    }),
                  ),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed:
                            state.protectionBusy ||
                                state.tunnel.phase != TunnelPhase.disconnected
                            ? null
                            : () => _protection(context, 'enable'),
                        icon: const Icon(Icons.shield_outlined),
                        label: const Text('Включить защиту'),
                      ),
                      OutlinedButton.icon(
                        onPressed: state.protectionBusy
                            ? null
                            : () => _protection(context, 'disable'),
                        icon: const Icon(Icons.lock_open),
                        label: const Text('Выключить защиту'),
                      ),
                      TextButton.icon(
                        onPressed: state.protectionBusy
                            ? null
                            : () => _protection(context, 'status'),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Проверить состояние'),
                      ),
                    ],
                  ),
                  if (state.protectionBusy) const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  const Text(
                    'Перед изменением отключи VPN. Обычное подключение и выход из приложения не снимают постоянную блокировку. Для импорта подписки без VPN сначала выключи защиту.',
                  ),
                ],
                DesignSetting(
                  'Доступ к локальной сети',
                  'Принтеры и домашние устройства',
                  Switch(
                    value: state.lan,
                    onChanged: (v) {
                      state.lan = v;
                      onChanged();
                    },
                  ),
                ),
                choose(
                  'mtu',
                  'Размер пакета MTU',
                  'Авто — 1500; применяется при следующем подключении',
                  [
                    ('auto', 'Из профиля / авто'),
                    ('1280', '1280'),
                    ('1420', '1420'),
                  ],
                ),
                const DesignSetting(
                  'Другой сервер',
                  'Если сервер недоступен, выбери другой на главной странице или в разделе «Серверы»',
                  DesignTag('Выбор сервера'),
                ),
                if (Platform.isAndroid) ...[
                  const DesignSetting(
                    'Постоянный VPN и строгая защита',
                    'В Android выбери VIORA, включи «Постоянный VPN» и при необходимости «Блокировать соединения без VPN». В строгом режиме приложения вне VPN потеряют доступ к сети. Для первого сохранения сервера подключись в обычном режиме.',
                    DesignTag('Android'),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      try {
                        await const MethodChannel(
                          'dev.viora/platform',
                        ).invokeMethod<void>('openVpnSettings');
                      } catch (_) {
                        onNotice('Открой настройки Android → VPN → VIORA');
                      }
                    },
                    icon: const Icon(Icons.security),
                    label: const Text('Открыть настройки VPN в Android'),
                  ),
                ],
              ] else if (index == 11) ...[
                choose(
                  'dns',
                  'DNS-сервер',
                  'Стандартный — Cloudflare через HTTPS внутри VPN; свой DNS — по IP',
                  [('profile', 'Стандартный'), ('custom', 'Свой DNS по IP')],
                ),
                if (state.options['dns'] == 'custom')
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: TextFormField(
                      initialValue: state.options['dnsAddress'] as String,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Адрес DNS',
                        hintText: 'Например, 1.1.1.1 · Enter для сохранения',
                      ),
                      onFieldSubmitted: (v) {
                        if (InternetAddress.tryParse(v.trim())?.type !=
                            InternetAddressType.IPv4) {
                          onNotice('Укажи корректный IPv4 адрес DNS');
                          return;
                        }
                        state.options['dnsAddress'] = v.trim();
                        onChanged();
                        onNotice('Адрес DNS сохранён в конфигурации');
                      },
                    ),
                  ),
                choose(
                  'ipv6',
                  'IPv6',
                  'В этой версии IPv6 блокируется в обоих режимах',
                  [
                    ('auto', 'Через VPN или блокировать'),
                    ('block', 'Всегда блокировать в туннеле'),
                  ],
                ),
                const DesignSetting(
                  'DNS без скрытого обхода',
                  'Не переходить на DNS провайдера при ошибке VPN',
                  DesignTag('Обязательно'),
                ),
              ] else if (index == 12) ...[
                if (quickSettingsSupported ?? Platform.isAndroid) ...[
                  _QuickSettingsCard(onNotice: onNotice),
                  const SizedBox(height: 20),
                ],
                toggle(
                  'autoconnect',
                  'Подключаться при открытии',
                  'К последнему выбранному серверу; системное разрешение запрашивается при необходимости',
                ),
                if (!Platform.isAndroid)
                  const DesignSetting(
                    'Закрытие окна',
                    'Крестик сворачивает VIORA в трей. Полный выход — через меню значка.',
                    DesignTag('Трей'),
                  ),
                DesignSetting(
                  'Уведомление VPN',
                  Platform.isAndroid
                      ? 'Время, скорость и трафик; нажатие открывает VIORA. Кнопка «Отключить» завершает соединение.'
                      : 'Состояние и быстрые действия доступны в трее. Подключение, отключение, выбор сервера и полный выход.',
                  DesignTag('Во время VPN'),
                ),
                const DesignSetting(
                  'Язык',
                  'Первый релиз',
                  DesignTag('Русский'),
                ),
              ] else ...[
                TextButton.icon(
                  onPressed: () => showLicensePage(
                    context: context,
                    applicationName: 'Viora',
                    applicationVersion: '1.0.2',
                  ),
                  icon: const Icon(Icons.info_outline),
                  label: const Text('Лицензии компонентов'),
                ),
                choose(
                  'updateInterval',
                  'Обновлять подписки',
                  'Автоматически, пока приложение открыто; при ошибке сохраняются прежние серверы',
                  [
                    ('manual', 'Вручную'),
                    ('60', 'Раз в час'),
                    ('360', 'Раз в 6 часов'),
                  ],
                ),
                const DesignSetting(
                  'HWID для Viora VPN',
                  'При импорте и обновлении подписки Viora',
                  DesignTag('Обязательно'),
                ),
                TextButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          HwidPage(hasSubscription: state.hasVioraSubscription),
                    ),
                  ),
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Посмотреть HWID устройства'),
                ),
                const DesignSetting(
                  'Сторонние провайдеры',
                  'Идентификатор Viora им не передаётся',
                  DesignTag('Отдельная привязка'),
                ),
                DesignSetting(
                  'Защищённое восстановление',
                  Platform.isAndroid
                      ? 'Последний VPN-профиль хранится на устройстве в зашифрованном виде. Ключ — в Android Keystore. Ручное отключение отменяет восстановление службы. Системный «Постоянный VPN» управляется Android.'
                      : 'Сеанс и серверы хранятся в защищённом хранилище системы. Автоподключение при открытии настраивается отдельно. После полного выхода из приложения VPN останавливается.',
                  DesignTag('На устройстве'),
                ),
                const DesignSetting(
                  'Отправка аналитики',
                  'Автоматическая отправка не предусмотрена',
                  DesignTag('Выключена'),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        DesignTag(
          Platform.isAndroid
              ? 'ПРИМЕНЯЕТСЯ ПРИ ПОДКЛЮЧЕНИИ'
              : 'ПРИМЕНЯЕТСЯ ПРИ ПОДКЛЮЧЕНИИ',
        ),
      ],
    );
  }
}

class _QuickSettingsCard extends StatefulWidget {
  final ValueChanged<String> onNotice;
  const _QuickSettingsCard({required this.onNotice});

  @override
  State<_QuickSettingsCard> createState() => _QuickSettingsCardState();
}

class _QuickSettingsCardState extends State<_QuickSettingsCard> {
  bool _pending = false;
  String? _status;

  Future<void> _addTile() async {
    if (_pending) return;
    setState(() => _pending = true);
    String message;
    try {
      final result = await QuickSettings.requestAddTile();
      message = switch (result) {
        'added' => 'Плитка VIORA добавлена в быстрые настройки',
        'already_added' => 'Плитка VIORA уже есть в быстрых настройках',
        'not_added' => 'Добавление отменено. Плитку можно добавить вручную',
        'manual' =>
          'На этой версии Android добавь плитку вручную по инструкции ниже',
        _ =>
          'Системное добавление недоступно. Добавь плитку вручную по инструкции ниже',
      };
    } on PlatformException catch (error) {
      message = switch (error.code) {
        'busy' => 'Запрос уже открыт. Заверши его в системном окне',
        'not_foreground' => 'Открой VIORA на экране и попробуй ещё раз',
        _ =>
          'Не удалось открыть системное окно. Добавь плитку вручную по инструкции ниже',
      };
    } catch (_) {
      message =
          'Не удалось открыть системное окно. Добавь плитку вручную по инструкции ниже';
    }
    if (!mounted) return;
    setState(() {
      _pending = false;
      _status = message;
    });
    widget.onNotice(message);
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: VioraColors(context).raised,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.dashboard_customize_outlined, size: 22),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Быстрые настройки',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Подключай и отключай VPN из шторки рядом с Wi-Fi и яркостью. Для подключения нужен сохранённый сервер.',
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            key: const Key('quick-settings-add-tile'),
            onPressed: _pending ? null : _addTile,
            icon: _pending
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add),
            label: Text(
              _pending ? 'Ожидаем Android…' : 'Добавить плитку VIORA',
            ),
          ),
          if (_status != null) ...[
            const SizedBox(height: 12),
            Semantics(liveRegion: true, child: Text(_status!)),
          ],
          const SizedBox(height: 14),
          Text(
            'Вручную: раскрой шторку быстрых настроек полностью → нажми карандаш или «Изменить» → найди VIORA среди доступных плиток и перетащи её наверх. Названия пунктов могут отличаться на твоём телефоне.',
            style: TextStyle(color: VioraColors(context).muted, height: 1.4),
          ),
        ],
      ),
    ),
  );
}
