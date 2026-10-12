import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../platform/native_bridge.dart';

class HwidPage extends StatefulWidget {
  final bool hasSubscription;
  const HwidPage({super.key, required this.hasSubscription});
  @override
  State<HwidPage> createState() => _HwidPageState();
}

class _HwidPageState extends State<HwidPage> {
  late final Future<String> id = NativeBridge.installationId();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('HWID устройства')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Icon(Icons.fingerprint, size: 64),
        const SizedBox(height: 24),
        const Text(
          'Твой идентификатор установки',
          style: TextStyle(fontSize: 22),
        ),
        const SizedBox(height: 12),
        FutureBuilder<String>(
          future: id,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Text(
                'Не удалось прочитать HWID. Разблокируй системное хранилище и повтори открытие экрана.',
              );
            }
            if (!snapshot.hasData) return const LinearProgressIndicator();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  snapshot.data!,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy),
                  label: const Text('Скопировать HWID'),
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: snapshot.data!),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('HWID скопирован')),
                      );
                    }
                  },
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        Text(
          widget.hasSubscription
              ? 'Подписка Viora импортирована. Приложение отправляет HWID при её импорте и обновлении.'
              : 'Добавь ссылку подписки Viora из бота. При загрузке серверов приложение автоматически передаст этот HWID.',
        ),
        const SizedBox(height: 16),
        const Text(
          'HWID помогает боту учитывать лимит устройств. Это случайный идентификатор установки, а не серийный номер устройства. Он сохраняется в системном защищённом хранилище.',
        ),
        const SizedBox(height: 16),
        const Text(
          'Идентификатор отправляется только серверу подписки Viora. Другим VPN-провайдерам он не передаётся. Подтверждение устройства и количество свободных слотов смотри в боте.',
        ),
      ],
    ),
  );
}
