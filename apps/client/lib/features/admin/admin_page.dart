import 'package:flutter/material.dart';
import '../../domain/control.dart';
import '../../main.dart' show VioraPanel;
import '../../ui/design.dart';

class AdminPage extends StatefulWidget {
  final ControlRepository repository;
  const AdminPage({super.key, required this.repository});
  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  final selected = <int>{}, selectedGroups = <String>{};
  final search = TextEditingController(),
      days = TextEditingController(text: '7'),
      reason = TextEditingController();
  List<VioraUser> users = [];
  List<VioraGroup> groups = [];
  List<String> events = [];
  bool busy = false;
  String section = 'Обзор', filter = 'all', message = '';
  GrantPreview? preview;
  static const sections = [
    'Обзор',
    'Пользователи',
    'Подписки',
    'Устройства',
    'Оплаты',
    'Статистика',
    'Поддержка',
    'Рассылки',
    'Журнал',
  ];
  @override
  void initState() {
    super.initState();
    if (!widget.repository.isDevelopment) section = 'Пользователи';
    reload();
  }

  List<String> get availableSections => widget.repository.isDevelopment
      ? sections
      : const ['Пользователи', 'Подписки', 'Журнал'];

  @override
  void dispose() {
    search.dispose();
    days.dispose();
    reason.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() operation) async {
    setState(() => busy = true);
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        setState(() => message = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> reload() async => run(() async {
    final loaded = await widget.repository.users();
    final saved = await widget.repository.groups();
    final audit = await widget.repository.audit();
    if (mounted) {
      setState(() {
        users = loaded;
        groups = saved;
        events = audit;
      });
    }
  });
  List<VioraUser> get visible => users
      .where(
        (u) =>
            (filter == 'all' ||
                (filter == 'recent' &&
                    !u.active &&
                    u.expires != null &&
                    u.expires!.isAfter(
                      DateTime.now().toUtc().subtract(const Duration(days: 10)),
                    )) ||
                (filter != 'recent' && u.active == (filter == 'active'))) &&
            '${u.name} ${u.username} ${u.id}'.toLowerCase().contains(
              search.text.toLowerCase(),
            ),
      )
      .toList();
  Future<void> makePreview() async => run(() async {
    final count = int.tryParse(days.text);
    if (count == null) throw StateError('Укажи целое количество дней');
    final p = await widget.repository.preview(
      count,
      reason.text,
      selected,
      selectedGroups,
    );
    if (mounted) setState(() => preview = p);
  });
  Future<void> confirm() async {
    final p = preview;
    if (p == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Подтвердить выдачу дней?'),
        content: Text(
          '${p.recipients.length} получателей · +${p.days} дней каждому.\n\nПричина: ${p.reason}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Выдать дни'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await run(() async {
      final result = await widget.repository.commit(p);
      final loaded = await widget.repository.users();
      final audit = await widget.repository.audit();
      if (mounted) {
        setState(() {
          message = result;
          users = loaded;
          events = audit;
          preview = null;
          selected.clear();
          selectedGroups.clear();
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(result)));
      }
    });
  }

  Future<void> saveGroup() async {
    final name = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Новая группа'),
        content: TextField(
          controller: name,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Название · ${selected.length} участников',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    name.dispose();
    if (value == null || !mounted) return;
    await run(() async {
      await widget.repository.createGroup(value, selected);
      final saved = await widget.repository.groups();
      if (mounted) setState(() => groups = saved);
    });
  }

  Widget approvedOverview(BuildContext context) {
    final colors = VioraColors(context);
    Widget metric(String label, String value, String hint) => DesignCard(
      padding: 18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: colors.muted)),
          const SizedBox(height: 12),
          Text(
            value,
            style: const TextStyle(
              fontSize: 30,
              letterSpacing: -1,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(hint, style: TextStyle(fontSize: 12, color: colors.muted)),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: metric(
                'Активные подписки',
                '${users.where((u) => u.active).length}',
                'Из ${users.length} аккаунтов',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: metric(
                'Оплаты на проверке',
                '—',
                'Интеграция с ботом ожидается',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: metric('Обращения', '—', 'Интеграция поддержки ожидается'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 11,
              child: DesignCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Нужна твоя проверка',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Пользователи и подписки Viora VPN — под твоим контролем.',
                      style: TextStyle(color: colors.muted),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: busy
                            ? null
                            : () => setState(() => section = 'Подписки'),
                        child: const Text('Выдать дни группе'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        OutlinedButton(
                          onPressed: () =>
                              setState(() => section = 'Пользователи'),
                          child: const Text('Пользователи'),
                        ),
                        OutlinedButton(
                          onPressed: () => setState(() => section = 'Оплаты'),
                          child: const Text('Очередь оплат'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              flex: 10,
              child: DesignCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Последние события',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (events.isEmpty)
                      Text(
                        'Изменений подписок пока нет.',
                        style: TextStyle(color: colors.muted),
                      ),
                    for (final event in events.take(3))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Text(event),
                      ),
                    Text(
                      '${groups.length} сохранённых групп',
                      style: TextStyle(fontSize: 12, color: colors.muted),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: MediaQuery.sizeOf(context).width >= 850
        ? EdgeInsets.zero
        : const EdgeInsets.all(20),
    children: [
      if (MediaQuery.sizeOf(context).width >= 850)
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const DesignTag('ВЛАДЕЛЕЦ VIORA VPN'),
            Text(
              widget.repository.isDevelopment
                  ? 'Демонстрационные данные'
                  : 'Права проверены сервером',
              style: TextStyle(fontSize: 12, color: VioraColors(context).muted),
            ),
          ],
        )
      else ...[
        Text(
          'Кабинет владельца',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        const Text('Viora VPN · управление сервисом'),
      ],
      const SizedBox(height: 20),
      LayoutBuilder(
        builder: (context, c) => c.maxWidth < 650
            ? DropdownButtonFormField<String>(
                initialValue: section,
                decoration: const InputDecoration(labelText: 'Раздел'),
                items: availableSections
                    .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: busy ? null : (v) => setState(() => section = v!),
              )
            : Wrap(
                spacing: 8,
                runSpacing: 8,
                children: availableSections
                    .map(
                      (s) => ChoiceChip(
                        label: Text(s),
                        selected: section == s,
                        onSelected: busy
                            ? null
                            : (_) => setState(() => section = s),
                      ),
                    )
                    .toList(),
              ),
      ),
      const SizedBox(height: 20),
      if (MediaQuery.sizeOf(context).width >= 850) ...[
        Divider(color: VioraColors(context).line, height: 1),
        DesignHeading(
          section == 'Обзор' ? 'Твой кабинет' : section,
          section == 'Обзор'
              ? 'Пользователи, подписки и оплаты — в одном месте.'
              : 'Управление Viora VPN · доступ владельца',
        ),
      ],
      if (busy) const LinearProgressIndicator(),
      if (message.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(message, key: const Key('admin-result')),
        ),
      if (section == 'Обзор') ...[
        if (MediaQuery.sizeOf(context).width >= 850)
          approvedOverview(context)
        else ...[
          VioraPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${users.where((u) => u.active).length} активных подписок',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                Text(
                  '${users.length} пользователей · ${groups.length} сохранённых групп',
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () => setState(() => section = 'Подписки'),
                  icon: const Icon(Icons.group_add_outlined),
                  label: const Text('Выдать дни группе'),
                ),
              ],
            ),
          ),
          VioraPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Последние изменения'),
                const SizedBox(height: 10),
                ...events
                    .take(5)
                    .map(
                      (e) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(e),
                      ),
                    ),
                if (events.isEmpty)
                  const Text('Выдачи дней пока не выполнялись.'),
              ],
            ),
          ),
        ],
      ] else if (section == 'Пользователи' || section == 'Подписки') ...[
        VioraPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Получатели', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final pair in [
                    ('all', 'Все пользователи'),
                    ('active', 'Активные'),
                    ('expired', 'Истёкшие'),
                    ('recent', 'Истекли за 10 дней'),
                  ])
                    FilterChip(
                      label: Text(pair.$2),
                      selected: selectedGroups.contains(pair.$1),
                      onSelected: busy
                          ? null
                          : (v) => setState(() {
                              v
                                  ? selectedGroups.add(pair.$1)
                                  : selectedGroups.remove(pair.$1);
                              preview = null;
                            }),
                    ),
                  for (final g in groups)
                    FilterChip(
                      label: Text('${g.name} · ${g.count}'),
                      selected: selectedGroups.contains(g.id),
                      onSelected: busy
                          ? null
                          : (v) => setState(() {
                              v
                                  ? selectedGroups.add(g.id)
                                  : selectedGroups.remove(g.id);
                              preview = null;
                            }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Поиск пользователей',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: filter,
                decoration: const InputDecoration(labelText: 'Показать'),
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('Всех')),
                  DropdownMenuItem(value: 'active', child: Text('Активных')),
                  DropdownMenuItem(value: 'expired', child: Text('Истёкших')),
                  DropdownMenuItem(
                    value: 'recent',
                    child: Text('Истекших за 10 дней'),
                  ),
                ],
                onChanged: (v) => setState(() => filter = v!),
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            selected.addAll(visible.map((u) => u.id));
                            preview = null;
                          }),
                    child: const Text('Выбрать найденных'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            selected.clear();
                            selectedGroups.clear();
                            preview = null;
                          }),
                    child: const Text('Снять выбор'),
                  ),
                ],
              ),
              for (final u in visible)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: selected.contains(u.id),
                  onChanged: busy
                      ? null
                      : (v) => setState(() {
                          v! ? selected.add(u.id) : selected.remove(u.id);
                          preview = null;
                        }),
                  title: Text(u.name),
                  subtitle: Text(
                    '@${u.username} · ID ${u.id}\n${u.active ? 'Активна' : 'Истекла'} · ${date(u.expires)}',
                  ),
                  isThreeLine: true,
                ),
              if (visible.isEmpty) const Text('Пользователи не найдены.'),
              Text(
                'Отмечено отдельно: ${selected.length} · групп: ${selectedGroups.length}',
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: busy || selected.isEmpty ? null : saveGroup,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Сохранить выбранных в группу'),
              ),
            ],
          ),
        ),
        VioraPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Выдача дней',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 14),
              TextField(
                controller: days,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() => preview = null),
                decoration: const InputDecoration(
                  labelText: 'Дней каждому',
                  helperText: 'От 1 до 3650',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: reason,
                onChanged: (_) => setState(() => preview = null),
                decoration: const InputDecoration(
                  labelText: 'Причина',
                  hintText: 'Подарок, компенсация или другое',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: busy ? null : makePreview,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Проверить получателей'),
              ),
              const SizedBox(height: 12),
              const Text(
                'Пересечения групп считаются один раз. Ручная выдача не записывается как оплата.',
              ),
            ],
          ),
        ),
        if (preview case final p?)
          VioraPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Предпросмотр · ${p.recipients.length} получателей',
                  key: const Key('grant-preview'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Text('+${p.days} дней каждому · ${p.reason}'),
                const SizedBox(height: 14),
                for (final r in p.recipients)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(r.name),
                    subtitle: Text('${date(r.before)} → ${date(r.after)}'),
                  ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: busy ? null : confirm,
                  child: const Text('Подтвердить выдачу'),
                ),
              ],
            ),
          ),
      ] else if (section == 'Журнал') ...[
        for (final e in events) VioraPanel(child: Text(e)),
        if (events.isEmpty)
          const VioraPanel(child: Text('Изменений пока нет.')),
      ] else
        VioraPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(section, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Text(pending(section)),
              const SizedBox(height: 16),
              const Chip(label: Text('Интеграция ещё не подключена')),
            ],
          ),
        ),
      const SizedBox(height: 20),
      OutlinedButton.icon(
        onPressed: busy ? null : reload,
        icon: const Icon(Icons.refresh),
        label: const Text('Обновить данные'),
      ),
    ],
  );
  String date(DateTime? d) => d == null
      ? 'Нет подписки'
      : '${d.toLocal().day.toString().padLeft(2, '0')}.${d.toLocal().month.toString().padLeft(2, '0')}.${d.toLocal().year}';
  String pending(String s) => switch (s) {
    'Устройства' =>
      'Список HWID, слоты и разрешение повторной привязки подключаются к действующему сервису устройств.',
    'Оплаты' =>
      'Очередь СБП и история Stars будут использовать единый механизм зачисления с ботом.',
    'Статистика' =>
      'Доходы RUB и Stars, средний чек и воронка появятся после интеграции финансовой истории.',
    'Поддержка' =>
      'Обращения и ответы текстом/фото будут синхронизированы с Telegram.',
    'Рассылки' =>
      'Выбор аудитории, предпросмотр, подтверждение и отчёт будут подключены к очереди бота. Сейчас сообщения не отправляются.',
    _ => 'Раздел в разработке.',
  };
}
