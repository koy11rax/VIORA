import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/account_api.dart';
import '../../ui/account_widgets.dart';

class RenewalPage extends StatefulWidget {
  final AccountController account;
  const RenewalPage({super.key, required this.account});
  @override
  State<RenewalPage> createState() => _RenewalPageState();
}

class _RenewalPageState extends State<RenewalPage> {
  Map<String, dynamic>? data;
  int? selected;
  bool busy = false;
  String? error;
  final paymentKey = GlobalKey();
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
              : 'Не удалось выполнить действие. Повтори попытку.';
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
    final result = await widget.account.features('renewal');
    await widget.account.restore();
    if (mounted) {
      setState(() {
        data = result;
        selected ??=
            (result['orders'] as List)
                    .where((o) => o['status'] == 'pending')
                    .firstOrNull?['id']
                as int?;
      });
    }
  });
  Future<void> choose(String tariff) => run(() async {
    final nonce = base64Url
        .encode(List.generate(24, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
    final result = await widget.account.features(
      'orders',
      body: {'tariff': tariff, 'request_id': nonce},
    );
    final refreshed = await widget.account.features('renewal');
    if (mounted) {
      setState(() {
        selected = result['id'] as int;
        data = refreshed;
      });
      revealPayment();
    }
  });
  void revealPayment() => WidgetsBinding.instance.addPostFrameCallback((_) {
    final target = paymentKey.currentContext;
    if (mounted && target != null) {
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 300),
      );
    }
  });

  Future<void> copy(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$label скопирован')));
    }
  }

  Widget detail(
    String label,
    String value,
    IconData icon, {
    String? copyLabel,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Icon(
            icon,
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                value,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        if (copyLabel != null)
          IconButton(
            tooltip: copyLabel,
            onPressed: () => copy(value, label),
            icon: const Icon(Icons.copy_outlined, size: 20),
          ),
      ],
    ),
  );

  String status(Map order) => switch (order['status']) {
    'approved' => 'Оплата подтверждена',
    'rejected' => 'Отклонена',
    _ => order['submitted'] == 1 ? 'На проверке' : 'Ожидает оплаты',
  };

  Widget step(int number, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 13,
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Text(
            '$number',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(text)),
      ],
    ),
  );
  Future<void> submit(int id) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Перевод уже выполнен?'),
        content: Text(
          'Подтверждай только после перевода. Заявка VPN-$id будет видна администратору. Подписка продлится после проверки фактического поступления денег.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Назад'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Я оплатил'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await run(() async {
      await widget.account.features('orders/submit', body: {'id': id});
      final result = await widget.account.features('renewal');
      if (mounted) {
        setState(() {
          data = result;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final orders = (data?['orders'] as List? ?? []).cast<Map>();
    final current = orders.where((o) => o['id'] == selected).firstOrNull;
    final requisites = data?['requisites'] as Map? ?? {};
    return Scaffold(
      appBar: AppBar(title: const Text('Продлить Viora VPN')),
      body: AccountContent(
        children: [
          AccountCard(
            highlighted: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AccountBadge(
                  'Продление без перехода в бот',
                  icon: Icons.autorenew,
                ),
                const SizedBox(height: 16),
                Text(
                  'Оставайся на своей волне',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 10),
                const Text(
                  'Выбери срок и оплати через СБП. Инструкция и статус заявки будут здесь. Дни добавятся к твоей общей подписке Viora.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text('Выбери тариф', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 14),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          for (final tariff in data?['tariffs'] as List? ?? [])
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(
                    color: current?['tariff'] == tariff['id']
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: busy ? null : () => choose(tariff['id'] as String),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 20,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${tariff['name']}',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '${tariff['days']} дней',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        MoneyAmount(tariff['rub'], size: 22),
                        const SizedBox(width: 8),
                        Icon(
                          current?['tariff'] == tariff['id']
                              ? Icons.check_circle_outline
                              : Icons.chevron_right,
                          size: 20,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (current != null) ...[
            const SizedBox(height: 16),
            AccountCard(
              key: paymentKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const AccountBadge(
                    'СБП · перевод по телефону',
                    icon: Icons.account_balance_outlined,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Заявка VPN-${current['id']}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 10),
                  MoneyAmount(current['amount'], size: 32),
                  const SizedBox(height: 16),
                  AccountBadge(
                    status(current),
                    icon: current['status'] == 'approved'
                        ? Icons.check_circle_outline
                        : Icons.schedule,
                  ),
                  if (current['status'] == 'pending') ...[
                    const SizedBox(height: 18),
                    const Divider(height: 1),
                    const SizedBox(height: 8),
                    detail(
                      'Телефон',
                      '${requisites['phone'] ?? ''}',
                      Icons.phone_outlined,
                      copyLabel: 'Скопировать телефон',
                    ),
                    detail(
                      'Банк',
                      '${requisites['bank'] ?? ''}',
                      Icons.account_balance_outlined,
                    ),
                    detail(
                      'Получатель',
                      '${requisites['name'] ?? ''}',
                      Icons.person_outline,
                    ),
                    detail(
                      'Комментарий',
                      'VPN-${current['id']}',
                      Icons.chat_bubble_outline,
                      copyLabel: 'Скопировать комментарий',
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Text(
                        'Обязательно укажи комментарий к переводу. По нему администратор найдёт твою оплату.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (current['submitted'] != 1)
                      FilledButton.icon(
                        onPressed: busy
                            ? null
                            : () => submit(current['id'] as int),
                        icon: const Icon(Icons.check),
                        label: const Text('Я оплатил'),
                      ),
                    if (current['submitted'] == 1)
                      const Text(
                        'Заявка передана на проверку. Дождись подтверждения администратора.',
                      ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: busy ? null : load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Обновить статус'),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            AccountCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Как оплатить',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 18),
                  step(
                    1,
                    'Открой свой банк и выбери перевод через СБП — по номеру телефона.',
                  ),
                  step(
                    2,
                    'Вставь телефон из реквизитов, выбери указанный банк. Проверь имя получателя и сумму.',
                  ),
                  step(
                    3,
                    'Добавь комментарий VPN-${current['id']} и выполни перевод. Если банк не позволяет указать комментарий — сохрани чек и напиши в поддержку своего бота.',
                  ),
                  step(
                    4,
                    'Вернись сюда и нажми «Я оплатил». После проверки дни добавятся к подписке в приложении и боте.',
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Мои заявки',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Обновить заявки',
                onPressed: busy ? null : load,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (data != null && orders.isEmpty)
            const AccountCard(
              child: Text('Пока нет заявок. Выбери подходящий тариф выше.'),
            ),
          for (final order in orders)
            Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 8,
                ),
                leading: Icon(
                  order['status'] == 'approved'
                      ? Icons.check_circle_outline
                      : Icons.receipt_long_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                title: Text('VPN-${order['id']}'),
                subtitle: Text(status(order)),
                trailing: MoneyAmount(order['amount'], size: 16),
                onTap: () {
                  setState(() {
                    selected = order['id'] as int;
                  });
                  revealPayment();
                },
              ),
            ),
        ],
      ),
    );
  }
}
