import 'package:flutter/material.dart';
import '../../data/account_api.dart';
import '../../domain/control.dart';
import 'admin_page.dart';
import '../../ui/account_widgets.dart';
import 'admin_tools_page.dart';

class LiveAdminPage extends StatefulWidget {
  final AccountController account;
  final ControlRepository repository;
  const LiveAdminPage({
    super.key,
    required this.account,
    required this.repository,
  });
  @override
  State<LiveAdminPage> createState() => _LiveAdminPageState();
}

class _LiveAdminPageState extends State<LiveAdminPage> {
  Map<String, dynamic>? data;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

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
        setState(() {
          error = e is AccountError
              ? e.message
              : 'Не удалось выполнить действие';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  Future<void> load() => run(() async {
    final value = await widget.account.features('admin/overview');
    if (mounted) {
      setState(() {
        data = value;
      });
    }
  });
  Future<void> decide(Map order, bool approve) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(approve ? 'Подтвердить поступление?' : 'Отклонить заявку?'),
        content: Text(
          'VPN-${order['id']} · ${order['amount']} руб.\nПользователь ${order['tg_id']}\n${approve ? 'Подтверждай только после проверки поступления в банке. Срок будет зачислен сразу.' : 'Дни не будут начислены.'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Назад'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Подтвердить'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await run(() async {
      await widget.account.features(
        'admin/orders/${approve ? 'approve' : 'reject'}',
        body: {'id': order['id']},
      );
      final value = await widget.account.features('admin/overview');
      if (mounted) {
        setState(() {
          data = value;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const Text('Администрирование Viora', style: TextStyle(fontSize: 26)),
      const Text('Доступ подтверждён сервером через Telegram'),
      if (busy) const LinearProgressIndicator(),
      if (error != null)
        Text(
          error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      const SizedBox(height: 16),
      Text(
        'Пользователей: ${data?['users'] ?? '—'} · активных: ${data?['active'] ?? '—'}',
      ),
      for (final total in data?['totals'] as List? ?? [])
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              MoneyAmount(
                total['amount'],
                currency: total['currency'] as String,
                size: 20,
              ),
              Text('Поступления · ${total['count']} оплат'),
            ],
          ),
        ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('Пользователи и группы')),
              body: AdminPage(repository: widget.repository),
            ),
          ),
        ),
        icon: const Icon(Icons.group),
        label: const Text('Пользователи · группы · выдача дней'),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: busy ? null : load,
        icon: const Icon(Icons.refresh),
        label: const Text('Обновить'),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final tool in adminTools)
            SizedBox(
              width: MediaQuery.sizeOf(context).width < 600 ? double.infinity : 260,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AdminToolsPage(
                      account: widget.account,
                      section: tool.$1,
                    ),
                  ),
                ),
                icon: Icon(tool.$3),
                label: Text(tool.$2),
              ),
            ),
        ],
      ),
      const SizedBox(height: 20),
      const Text('Проверка оплат', style: TextStyle(fontSize: 22)),
      if (data != null && (data!['pending'] as List).isEmpty)
        const Text('Нет заявок на проверке'),
      for (final order in data?['pending'] as List? ?? [])
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'VPN-${order['id']}',
                  style: const TextStyle(fontSize: 18),
                ),
                const SizedBox(height: 8),
                MoneyAmount(order['amount'], size: 22),
                const SizedBox(height: 12),
                Text(
                  '${(order['first_name'] as String? ?? '').trim().isEmpty ? 'Пользователь' : order['first_name']} · ID ${order['tg_id']}',
                ),
                Text(
                  order['submitted'] == 1
                      ? 'Пользователь сообщил об оплате'
                      : 'Заявка создана · ожидает оплаты',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed: busy ? null : () => decide(order as Map, true),
                      child: const Text('Подтвердить'),
                    ),
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => decide(order as Map, false),
                      child: const Text('Отклонить'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
    ],
  );
}
