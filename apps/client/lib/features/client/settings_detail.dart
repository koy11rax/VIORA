import 'hwid_page.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import '../../ui/design.dart';
import 'client_page.dart' show ClientState;

class SettingsDetail extends StatelessWidget {
  final int index;
  final ClientState state;
  final VoidCallback onChanged;
  final ValueChanged<int> onNavigate;
  final ValueChanged<String> onNotice;
  const SettingsDetail({
    super.key,
    required this.index,
    required this.state,
    required this.onChanged,
    required this.onNavigate,
    required this.onNotice,
  });
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
                  'При смене Wi-Fi и мобильной сети и при остановке VPN-движка',
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
                choose(
                  'protection',
                  'Защита при обрыве',
                  'Строгий режим требует системной блокировки соединений без VPN',
                  [
                    ('session', 'В пределах VPN-сессии'),
                    ('strict', 'Строго: без выхода напрямую'),
                  ],
                ),
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
                  'В текущем Android-движке IPv6 блокируется в обоих режимах',
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
                const DesignSetting(
                  'Уведомление VPN',
                  'Время, скорость и трафик; нажатие открывает VIORA. Кнопка «Отключить» завершает соединение.',
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
                    applicationVersion: '0.7.4',
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
                  'При импорте и обновлении подписки Viora на Android',
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
                const DesignSetting(
                  'Защищённое восстановление',
                  'Последний VPN-профиль хранится на устройстве в зашифрованном виде. Ключ — в Android Keystore. Ручное отключение отменяет восстановление службы. Системный «Постоянный VPN» управляется Android.',
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
