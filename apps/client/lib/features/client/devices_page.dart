import 'package:flutter/material.dart';
import '../../data/account_api.dart';

class DevicesPage extends StatefulWidget {
  final AccountController account;
  const DevicesPage({super.key, required this.account});
  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  List<AccountDevice> devices = [];
  int limit = 3;
  bool busy = false;
  String? error, message;
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
        setState(
          () => error = e is AccountError
              ? e.message
              : 'Не удалось обновить устройства. Повтори попытку.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void apply(Map<String, dynamic> data) {
    if (!mounted) return;
    setState(() {
      devices = (data['devices'] as List)
          .map((d) => AccountDevice.fromJson(d as Map))
          .toList();
      limit = data['limit'] as int;
    });
  }

  Future<void> load() => run(() async {
    apply(await widget.account.features('devices'));
  });
  Future<void> revoke(AccountDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Отвязать ${device.name}?'),
        content: const Text(
          'Ключ этого устройства перестанет принимать новые подключения. Если это текущий телефон, его VPN тоже потеряет доступ. Повторно разрешить это же устройство сможет администратор — как в боте.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Отвязать'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await run(() async {
      final result = await widget.account.features(
        'devices/revoke',
        body: {'id': device.id},
      );
      apply(result);
      if (mounted) {
        setState(
          () => message = result['access_sync'] == 'pending'
              ? 'Отвязка сохранена. VPN применит её автоматически в течение минуты.'
              : 'Устройство отвязано, слот освобождён.',
        );
      }
      await widget.account.restore();
    });
  }

  String seen(DateTime? date) {
    if (date == null) return 'Нет данных об обновлении';
    final d = (date.isUtc ? date : DateTime.parse('${date.toIso8601String()}Z'))
        .toLocal();
    return 'Обновлялось: ${d.day}.${d.month}.${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Устройства подписки')),
    body: RefreshIndicator(
      onRefresh: load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Занято ${devices.length} из $limit',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text(
            'Чтобы привязать новое устройство, обнови на нём подписку. Смена Wi-Fi на мобильную сеть новый слот не занимает. Отвязывай устройства при замене или потере.',
          ),
          const SizedBox(height: 16),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (message != null) Text(message!),
          if (!busy && error == null && devices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('Привязанных устройств пока нет.'),
            ),
          for (final device in devices)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        device.platform.toLowerCase().contains('android')
                            ? Icons.phone_android
                            : Icons.devices,
                      ),
                      title: Text(device.name),
                      subtitle: Text(
                        '${device.platform}\n${seen(device.lastSeen)}',
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: busy || device.id == null
                          ? null
                          : () => revoke(device),
                      icon: const Icon(Icons.link_off),
                      label: const Text('Отвязать устройство'),
                    ),
                  ],
                ),
              ),
            ),
          OutlinedButton.icon(
            onPressed: busy ? null : load,
            icon: const Icon(Icons.refresh),
            label: const Text('Обновить список'),
          ),
        ],
      ),
    ),
  );
}
