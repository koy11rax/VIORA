import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/account_api.dart';
import '../../ui/account_widgets.dart';

const adminTools = <(String, String, IconData)>[
  ('stats', 'Статистика', Icons.bar_chart_rounded),
  ('funnel', 'Воронка', Icons.filter_alt_outlined),
  ('user', 'Подписки и устройства', Icons.manage_accounts_outlined),
  ('payments', 'История оплат', Icons.receipt_long_outlined),
  ('logs', 'Действия пользователей', Icons.history_rounded),
  ('support', 'Обращения и ответы', Icons.support_agent_rounded),
  ('broadcast', 'Рассылка', Icons.campaign_outlined),
  ('give', 'Новая подписка по ID', Icons.person_add_alt_rounded),
  ('backup', 'Резервная копия', Icons.backup_outlined),
  ('jobs', 'Журнал операций', Icons.fact_check_outlined),
];

class AdminToolsPage extends StatefulWidget {
  final AccountController account;
  final String section;
  const AdminToolsPage({
    super.key,
    required this.account,
    required this.section,
  });
  @override
  State<AdminToolsPage> createState() => _AdminToolsPageState();
}

class _AdminToolsPageState extends State<AdminToolsPage> {
  final user = TextEditingController(), text = TextEditingController();
  final reason = TextEditingController(),
      days = TextEditingController(text: '30');
  String audience = 'all';
  int hours = 24, page = 0;
  bool busy = false, confirming = false;
  String? error, photo;
  Map<String, dynamic>? data;
  String get section => widget.section;
  @override
  void initState() {
    super.initState();
    if (!['user', 'broadcast', 'give', 'backup'].contains(section)) load();
  }

  @override
  void dispose() {
    for (final c in [user, text, reason, days]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<Map<String, dynamic>> api(String path, [Map<String, dynamic>? body]) =>
      widget.account.features('admin/tools/$path', body: body ?? {});
  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is AccountError
              ? e.message
              : 'Не удалось выполнить действие. Повтори позже.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Map<String, dynamic> get filters => {
    'page': page,
    'hours': hours,
    if (user.text.trim().isNotEmpty) 'user_id': int.tryParse(user.text.trim()),
  };
  Future<void> load() => run(() async {
    if (user.text.trim().isNotEmpty && int.tryParse(user.text.trim()) == null) {
      throw const AccountError('Укажи числовой Telegram ID');
    }
    final value = await api(section, filters);
    if (mounted) setState(() => data = value);
  });
  Future<void> pickPhoto() => run(() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Фото',
          extensions: ['jpg', 'jpeg', 'png'],
          mimeTypes: ['image/jpeg', 'image/png'],
        ),
      ],
    );
    if (file == null) return;
    if (await file.length() > 600000) {
      throw const AccountError('Выбери JPEG или PNG до 600 КБ');
    }
    final bytes = await file.readAsBytes();
    if (mounted) setState(() => photo = base64Encode(bytes));
  });
  Future<void> prepare(
    String action, {
    Map<String, dynamic> values = const {},
    String? fixedReason,
  }) => run(() async {
    final preview = await api('prepare', {
      'action': action,
      'reason': fixedReason ?? reason.text.trim(),
      if (['broadcast', 'reply'].contains(action)) ...{
        'text': text.text,
        if (photo != null) 'photo': photo,
      },
      if (action == 'broadcast') 'audience': audience,
      if (action == 'give') ...{
        'user_id': int.tryParse(user.text.trim()),
        'days': int.tryParse(days.text.trim()),
      },
      ...values,
    });
    if (!mounted) return;
    setState(() => confirming = true);
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(preview['title'] as String),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in preview['summary'] as List)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('$line'),
                ),
              if (photo != null && ['broadcast', 'reply'].contains(action))
                Image.memory(base64Decode(photo!), height: 150),
              Text('Причина: ${preview['reason']}'),
              const SizedBox(height: 12),
              const Text(
                'После подтверждения действие будет выполнено на сервере.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              action == 'broadcast' ? 'Отправить рассылку' : 'Подтвердить',
            ),
          ),
        ],
      ),
    );
    if (mounted) setState(() => confirming = false);
    if (approved != true || !mounted) return;
    await api('commit', {'id': preview['id']});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Задание принято. Проверь результат в журнале операций.'),
      ),
    );
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            AdminToolsPage(account: widget.account, section: 'jobs'),
      ),
    );
  });
  Future<void> deviceAction(Map row, bool allow) async {
    final why = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(allow ? 'Разрешить устройство' : 'Отвязать устройство'),
        content: TextField(
          controller: why,
          decoration: const InputDecoration(
            labelText: 'Причина',
            hintText: 'Не менее 3 символов',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Далее'),
          ),
        ],
      ),
    );
    final value = why.text;
    why.dispose();
    if (accepted == true) {
      await prepare(
        allow ? 'allow' : 'revoke',
        values: {'user_id': data!['user']['tg_id'], 'device_id': row['id']},
        fixedReason: value,
      );
    }
  }

  Widget field(
    TextEditingController controller,
    String label, {
    bool numeric = false,
    bool multiline = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      controller: controller,
      enabled: !busy,
      keyboardType: numeric
          ? TextInputType.number
          : multiline
          ? TextInputType.multiline
          : TextInputType.text,
      maxLines: multiline ? 5 : 1,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );
  Widget card(List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
  Widget get compose => card([
    if (section == 'broadcast')
      DropdownButtonFormField<String>(
        isExpanded: true,
        initialValue: audience,
        decoration: const InputDecoration(labelText: 'Получатели'),
        items: const [
          DropdownMenuItem(value: 'all', child: Text('Все посетители бота')),
          DropdownMenuItem(value: 'active', child: Text('Активные подписки')),
          DropdownMenuItem(value: 'expired', child: Text('Истёкшие подписки')),
        ],
        onChanged: busy ? null : (v) => setState(() => audience = v!),
      ),
    const SizedBox(height: 16),
    field(text, 'Текст сообщения', multiline: true),
    if (photo != null) ...[
      Image.memory(base64Decode(photo!), height: 180),
      TextButton(
        onPressed: busy ? null : () => setState(() => photo = null),
        child: const Text('Убрать фото'),
      ),
    ],
    OutlinedButton.icon(
      onPressed: busy ? null : pickPhoto,
      icon: const Icon(Icons.add_photo_alternate_outlined),
      label: const Text('Добавить фото · до 600 КБ'),
    ),
    const SizedBox(height: 16),
    field(reason, 'Причина отправки', multiline: true),
    const Text('Обычный текст. Подпись к фото — до 900 символов.'),
    const SizedBox(height: 12),
    if (section == 'broadcast')
      FilledButton.icon(
        onPressed: busy ? null : () => prepare('broadcast'),
        icon: const Icon(Icons.visibility_outlined),
        label: const Text('Предпросмотр рассылки'),
      ),
  ]);
  Widget metrics(Map values) => Wrap(
    spacing: 12,
    runSpacing: 12,
    children: [
      for (final e in values.entries)
        SizedBox(
          width: MediaQuery.sizeOf(context).width < 600 ? double.infinity : 230,
          child: card([
            Text(
              labels[e.key] ?? '${e.key}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            if ('${e.key}'.startsWith('rub_'))
              MoneyAmount(e.value, size: 26)
            else if ('${e.key}'.startsWith('stars_'))
              MoneyAmount(e.value, currency: 'XTR', size: 26)
            else
              Text(
                '${e.value}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
          ]),
        ),
    ],
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(adminTools.firstWhere((v) => v.$1 == section).$2),
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (busy && !confirming) const LinearProgressIndicator(),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if ([
          'user',
          'logs',
          'support',
          'payments',
          'give',
        ].contains(section)) ...[
          field(
            user,
            section == 'user' || section == 'give'
                ? 'Telegram ID пользователя'
                : 'Фильтр по Telegram ID · необязательно',
            numeric: true,
          ),
          if (section != 'give')
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () {
                      page = 0;
                      load();
                    },
              icon: const Icon(Icons.search),
              label: const Text('Показать'),
            ),
          const SizedBox(height: 16),
        ],
        if (section == 'funnel') ...[
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 24, label: Text('24 ч')),
              ButtonSegment(value: 168, label: Text('7 дней')),
              ButtonSegment(value: 720, label: Text('30 дней')),
            ],
            selected: {hours},
            onSelectionChanged: busy
                ? null
                : (v) {
                    setState(() => hours = v.single);
                    load();
                  },
          ),
          const SizedBox(height: 16),
        ],
        if (data?['stats'] is Map) metrics(data!['stats'] as Map),
        if (data?['funnel'] is Map) metrics(data!['funnel'] as Map),
        if (section == 'broadcast') compose,
        if (section == 'support') ...[
          const Text(
            'Выбери обращение ниже и подготовь ответ. Новые фото доступны прямо здесь; старые вложения — в чате Telegram.',
          ),
          const SizedBox(height: 16),
          compose,
        ],
        if (section == 'give')
          card([
            const Text(
              'Для нового Telegram ID. Существующим пользователям выдавай дни через раздел «Пользователи и группы».',
            ),
            const SizedBox(height: 16),
            field(days, 'Количество дней', numeric: true),
            field(reason, 'Причина выдачи', multiline: true),
            FilledButton.icon(
              onPressed: busy ? null : () => prepare('give'),
              icon: const Icon(Icons.preview_outlined),
              label: const Text('Проверить выдачу'),
            ),
          ]),
        if (section == 'backup')
          card([
            const Icon(Icons.backup_outlined, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Резервная копия базы пользователей и привязок устройств. Архив останется на сервере и придёт владельцу в Telegram, как в боте.',
            ),
            const SizedBox(height: 16),
            field(reason, 'Причина создания', multiline: true),
            FilledButton.icon(
              onPressed: busy ? null : () => prepare('backup'),
              icon: const Icon(Icons.save_alt),
              label: const Text('Создать резервную копию'),
            ),
          ]),
        if (section == 'user' && data?['user'] is Map) ...[
          card([
            Text(
              '${data!['user']['first_name'] ?? ''} · ${data!['user']['username'] ?? ''}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text('ID: ${data!['user']['tg_id']}'),
            Text('Подписка до: ${date(data!['user']['expires_at'])}'),
            if (data!['subscription_url'] != null)
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: data!['subscription_url'] as String),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Ссылка скопирована')),
                    );
                  }
                },
                icon: const Icon(Icons.copy),
                label: const Text('Скопировать подписку'),
              ),
          ]),
          const SizedBox(height: 12),
          const Text('Активные устройства', style: TextStyle(fontSize: 20)),
          if ((data!['devices'] as List).isEmpty)
            const Text('Нет активных устройств'),
          for (final row in data!['devices'] as List)
            deviceCard(row as Map, false),
          const SizedBox(height: 12),
          const Text(
            'Заблокированные устройства',
            style: TextStyle(fontSize: 20),
          ),
          if ((data!['blocked'] as List).isEmpty)
            const Text('Нет заблокированных устройств'),
          for (final row in data!['blocked'] as List)
            deviceCard(row as Map, true),
          const SizedBox(height: 20),
          card([
            const Text('Удаление подписки', style: TextStyle(fontSize: 20)),
            const SizedBox(height: 12),
            field(reason, 'Причина удаления', multiline: true),
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () => prepare(
                      'delete',
                      values: {'user_id': data!['user']['tg_id']},
                    ),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Проверить удаление'),
            ),
          ]),
        ],
        if (data?['rows'] is List) ...[
          if ((data!['rows'] as List).isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('Записей пока нет'),
            ),
          for (final row in data!['rows'] as List) record(row as Map),
          if (section != 'jobs')
            Wrap(
              spacing: 12,
              children: [
                OutlinedButton(
                  onPressed: busy || page == 0
                      ? null
                      : () {
                          page--;
                          load();
                        },
                  child: const Text('Назад'),
                ),
                Text('Страница ${page + 1}'),
                OutlinedButton(
                  onPressed: busy || data!['more'] != true
                      ? null
                      : () {
                          page++;
                          load();
                        },
                  child: const Text('Далее'),
                ),
              ],
            ),
        ],
        if (!['give', 'backup', 'broadcast'].contains(section))
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: OutlinedButton.icon(
              onPressed: busy ? null : load,
              icon: const Icon(Icons.refresh),
              label: const Text('Обновить'),
            ),
          ),
      ],
    ),
  );
  Widget deviceCard(Map row, bool blocked) => card([
    Row(
      children: [
        Icon(blocked ? Icons.phonelink_erase : Icons.devices),
        const SizedBox(width: 12),
        Expanded(
          child: Text('${row['model'] ?? row['platform'] ?? 'Устройство'}'),
        ),
      ],
    ),
    const SizedBox(height: 8),
    Text('ID ${row['id']} · ${row['platform'] ?? ''}'),
    if (row['last_seen'] != null)
      Text('Обновлялось: ${date(row['last_seen'])}'),
    const SizedBox(height: 12),
    OutlinedButton(
      onPressed: busy ? null : () => deviceAction(row, blocked),
      child: Text(blocked ? 'Разрешить снова' : 'Отвязать'),
    ),
  ]);
  Widget record(Map row) => card([
    if (section == 'jobs') ...[
      Text(
        actionLabels[row['action']] ?? '${row['action']}',
        style: const TextStyle(fontSize: 18),
      ),
      Text(statusLabels[row['state']] ?? '${row['state']}'),
      Text(date(row['created'])),
      if (row['reason'] != null) Text('Причина: ${row['reason']}'),
      if (row['result'] is Map)
        for (final e in (row['result'] as Map).entries)
          Text('${labels[e.key] ?? e.key}: ${e.value}'),
    ] else ...[
      Text(
        'ID ${row['tg_id']} · ${date(row['created_at'])}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      if (section == 'payments') ...[
        MoneyAmount(row['amount'], currency: '${row['currency']}', size: 22),
        Text('${row['method']} · ${row['tariff']}'),
      ],
      if (section == 'logs') ...[
        Text(labels[row['action']] ?? '${row['action']}'),
        SelectableText('${row['details'] ?? ''}'),
      ],
      if (section == 'support') ...[
        SelectableText('${row['message_text']}'),
        if (row['photo'] == true)
          SupportPhoto(account: widget.account, ticket: row['id'] as int),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: busy
              ? null
              : () => prepare('reply', values: {'ticket_id': row['id']}),
          icon: const Icon(Icons.reply),
          label: const Text('Ответить этим сообщением'),
        ),
      ],
    ],
  ]);
}

String date(dynamic value) {
  final d = DateTime.tryParse('$value');
  if (d == null) return '—';
  final v =
      (d.isUtc
              ? d
              : DateTime.utc(
                  d.year,
                  d.month,
                  d.day,
                  d.hour,
                  d.minute,
                  d.second,
                ))
          .toLocal();
  return '${v.day.toString().padLeft(2, '0')}.${v.month.toString().padLeft(2, '0')}.${v.year} ${v.hour.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')}';
}

const actionLabels = {
  'broadcast': 'Рассылка',
  'reply': 'Ответ поддержки',
  'delete': 'Удаление подписки',
  'revoke': 'Отвязка устройства',
  'allow': 'Разрешение устройства',
  'give': 'Новая подписка',
  'backup': 'Резервная копия',
};
const statusLabels = {
  'preview': 'Ожидает подтверждения',
  'queued': 'В очереди',
  'running': 'Выполняется',
  'finished': 'Завершено',
  'failed': 'Ошибка · проверь результат',
  'interrupted': 'Прервано · проверь результат',
};
const labels = {
  'total': 'Всего пользователей',
  'active': 'Активные подписки',
  'new_today': 'Новые сегодня',
  'new_month': 'Новые за 30 дней',
  'rub_today': 'Рубли сегодня',
  'rub_month': 'Рубли за 30 дней',
  'stars_today': 'Stars сегодня',
  'stars_month': 'Stars за 30 дней',
  'start': 'Запуски бота',
  'trial_got': 'Получили тест',
  'buy_menu': 'Открыли тарифы',
  'choose_tariff': 'Выбрали тариф',
  'pay_stars': 'Оплата Stars',
  'pay_sbp': 'Оплата СБП',
  'payment_success': 'Успешные оплаты',
  'support': 'Поддержка',
  'support_msg': 'Обращение',
  'message': 'Результат',
  'name': 'Файл',
  'sent': 'Доставлено',
  'failed_or_uncertain': 'Ошибки или неподтверждённые доставки',
  'skipped': 'Пропущено',
  'access_sync': 'Применение доступа',
};

class SupportPhoto extends StatefulWidget {
  final AccountController account;
  final int ticket;
  const SupportPhoto({super.key, required this.account, required this.ticket});
  @override
  State<SupportPhoto> createState() => _SupportPhotoState();
}

class _SupportPhotoState extends State<SupportPhoto> {
  late final future = widget.account.features(
    'admin/tools/photo',
    body: {'ticket_id': widget.ticket},
  );
  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: future,
    builder: (context, snapshot) {
      if (snapshot.hasError) return const Text('Не удалось загрузить фото');
      if (!snapshot.hasData) return const LinearProgressIndicator();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Image.memory(
          base64Decode(snapshot.data!['photo'] as String),
          height: 240,
        ),
      );
    },
  );
}
