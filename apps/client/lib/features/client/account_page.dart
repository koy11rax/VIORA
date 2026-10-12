import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/account_api.dart';
import '../../platform/native_bridge.dart';
import 'renewal_page.dart';
import 'devices_page.dart';
import '../../ui/account_widgets.dart';

class AccountPage extends StatefulWidget {
  final AccountController account;
  final Future<void> Function(String) importSubscription;
  const AccountPage({
    super.key,
    required this.account,
    required this.importSubscription,
  });
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  LoginChallenge? challenge;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    widget.account.addListener(changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) perform(widget.account.restore);
    });
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> perform(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } on AccountError catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Не удалось завершить действие. Повтори попытку.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    widget.account.removeListener(changed);
    final pending = challenge;
    if (pending != null) {
      widget.account.api.cancel(pending).catchError((Object _) {});
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.account.value;
    final pending = challenge;
    return Scaffold(
      appBar: AppBar(title: const Text('Моя подписка Viora')),
      body: AccountContent(
        children: [
          if (account != null) ...[
            AccountCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer,
                    child: Icon(
                      Icons.telegram,
                      color: Theme.of(context).colorScheme.primary,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          account.name,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 10),
                        AccountBadge(
                          account.owner
                              ? 'Владелец Viora'
                              : 'Telegram подтверждён',
                          icon: account.owner
                              ? Icons.admin_panel_settings_outlined
                              : Icons.verified_outlined,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            AccountCard(
              highlighted: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'VIORA VPN',
                    style: TextStyle(fontSize: 12, letterSpacing: 2),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    account.expires?.isAfter(DateTime.now()) == true
                        ? 'Подписка активна'
                        : 'Подписка не активна',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    account.expires == null
                        ? 'Выбери тариф, чтобы начать'
                        : 'Действует до ${subscriptionDate(account.expires!)}',
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  RenewalPage(account: widget.account),
                            ),
                          ),
                    icon: const Icon(Icons.autorenew),
                    label: const Text('Продлить подписку в приложении'),
                  ),
                  if (account.subscriptionUrl != null) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () => perform(
                              () => widget.importSubscription(
                                account.subscriptionUrl!,
                              ),
                            ),
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Загрузить мою подписку'),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'HWID передаётся автоматически. Это устройство занимает один слот, даже если сменить сеть.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            AccountCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Мои устройства',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      AccountBadge(
                        '${account.devices.length} / ${account.deviceLimit}',
                        icon: Icons.devices,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  for (final device in account.deviceRecords)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        device.platform.toLowerCase().contains('android')
                            ? Icons.phone_android
                            : Icons.computer,
                      ),
                      title: Text(device.name),
                    ),
                  if (account.devices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Устройства пока не привязаны'),
                    ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  DevicesPage(account: widget.account),
                            ),
                          ),
                    icon: const Icon(Icons.tune),
                    label: const Text('Управлять устройствами'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            AccountCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => perform(widget.account.restore),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Обновить аккаунт'),
                  ),
                  if (account.botUrl != null) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () => perform(
                              () => NativeBridge.openTelegram(account.botUrl!),
                            ),
                      icon: const Icon(Icons.telegram),
                      label: const Text('Открыть Telegram-бота'),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: busy ? null : () => perform(widget.account.logout),
              child: const Text('Выйти из аккаунта'),
            ),
          ] else if (pending != null) ...[
            const Icon(Icons.telegram, size: 56),
            const SizedBox(height: 24),
            const Text(
              'Подтверди вход в своём боте',
              style: TextStyle(fontSize: 22),
            ),
            const SizedBox(height: 16),
            const Text(
              'Сравни код в боте с этим кодом и нажми «Подтвердить вход». Затем вернись сюда.',
            ),
            const SizedBox(height: 16),
            Center(
              child: SelectableText(
                pending.code,
                style: const TextStyle(fontSize: 36, letterSpacing: 8),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () => perform(
                      () => NativeBridge.openTelegram(pending.botUrl),
                    ),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Открыть Telegram'),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      await Clipboard.setData(
                        ClipboardData(text: pending.botUrl.toString()),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Ссылка входа скопирована'),
                          ),
                        );
                      }
                    },
              child: const Text('Скопировать ссылку входа'),
            ),
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () => perform(() async {
                      final session = await widget.account.api.poll(pending);
                      if (session == null) {
                        throw const AccountError(
                          'Подтверждение ещё не получено. Нажми кнопку в боте.',
                        );
                      }
                      challenge = null;
                      await widget.account.complete(session);
                    }),
              child: const Text('Проверить подтверждение'),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => perform(() async {
                      try {
                        await widget.account.api.cancel(pending);
                      } finally {
                        challenge = null;
                      }
                    }),
              child: const Text('Начать заново'),
            ),
            const Text(
              'Код действует 5 минут. Секрет сеанса в Telegram не передаётся.',
            ),
          ] else ...[
            const Icon(Icons.telegram, size: 56),
            const SizedBox(height: 24),
            const Text(
              'Твой Telegram — твоя подписка',
              style: TextStyle(fontSize: 22),
            ),
            const SizedBox(height: 16),
            const Text(
              'Подтверди вход в своём боте, чтобы видеть срок подписки и устройства. Для подключения VPN достаточно импортированной ссылки.',
            ),
            const SizedBox(height: 24),
            if (widget.account.hasSession)
              FilledButton(
                onPressed: busy ? null : () => perform(widget.account.restore),
                child: const Text('Восстановить аккаунт'),
              )
            else
              FilledButton.icon(
                onPressed: busy
                    ? null
                    : () => perform(() async {
                        challenge = await widget.account.api.start();
                      }),
                icon: const Icon(Icons.telegram),
                label: const Text('Связать Telegram'),
              ),
          ],
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: LinearProgressIndicator(),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
