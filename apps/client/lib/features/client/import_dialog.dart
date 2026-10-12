import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../domain/profile.dart';
import 'qr_import.dart';
import '../../data/subscription_import.dart';

class ImportDialog extends StatefulWidget {
  final Future<ImportedConnection> Function(String)? loadSubscription;
  const ImportDialog({super.key, this.loadSubscription});
  @override
  State<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<ImportDialog> {
  final input = TextEditingController();
  VlessProfile? preview;
  String? error;
  bool busy = false;
  bool subscription = false;
  bool get camera => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void validate(String value, {bool fromSource = false}) {
    VlessProfile? parsed;
    var isSubscription = false;
    String? problem;
    if (value.trim().isNotEmpty) {
      try {
        if (value.trim().startsWith('https://')) {
          subscriptionUri(value);
          isSubscription = true;
        } else {
          parsed = VlessProfile.parse(value);
        }
      } on FormatException catch (e) {
        problem = e.message;
      }
    } else if (fromSource) {
      problem = 'Здесь пока нет ссылки. Скопируй её в боте или добавь вручную.';
    }
    setState(() {
      preview = parsed;
      subscription = isSubscription;
      error = problem;
    });
  }

  Future<void> submit() async {
    if (!subscription) {
      Navigator.pop(context, ImportedConnection([preview!]));
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result =
          await (widget.loadSubscription ?? SubscriptionImporter().load)(
            input.text.trim(),
          );
      if (mounted) Navigator.pop(context, result);
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void accept(String value) {
    input.text = value.trim();
    validate(input.text, fromSource: true);
  }

  Future<void> paste() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      accept(data?.text ?? '');
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Буфер недоступен. Вставь ссылку вручную.');
      }
    }
  }

  Future<void> image() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Изображение QR',
            extensions: ['png', 'jpg', 'jpeg', 'webp'],
            mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
          ),
        ],
      );
      if (file == null || !mounted) return;
      if (await file.length() > 12 * 1024 * 1024) {
        throw const FormatException('Выбери изображение меньше 12 МБ.');
      }
      final text = await compute(decodeQrImage, await file.readAsBytes());
      if (mounted) accept(text);
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Не удалось прочитать QR. Попробуй другой снимок.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> scan() async {
    final value = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const _ScanPage()));
    if (mounted && value != null) accept(value);
  }

  Widget action(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback callback,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : callback,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: colors.primary, size: 23),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.add_link_rounded, color: colors.primary, size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'ТВОИ ПОДКЛЮЧЕНИЯ',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.2,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                'Добавить VPN',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -.8,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Выбери удобный способ. Ссылку можно взять в боте или у своего VPN-провайдера.',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 22),
              action(
                Icons.content_paste_rounded,
                'Вставить из буфера',
                'Скопировал ссылку? Одно нажатие.',
                paste,
              ),
              const SizedBox(height: 10),
              if (camera) ...[
                action(
                  Icons.qr_code_scanner_rounded,
                  'Сканировать QR-код',
                  'Наведи камеру на код подключения',
                  scan,
                ),
                const SizedBox(height: 10),
              ],
              action(
                Icons.image_outlined,
                'QR из изображения',
                camera ? 'Выбери фото или скриншот' : 'Открой файл с QR-кодом',
                image,
              ),
              const SizedBox(height: 22),
              Text(
                'ИЛИ ДОБАВЬ ССЫЛКУ ВРУЧНУЮ',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: input,
                minLines: 2,
                maxLines: 4,
                maxLength: 16384,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.multiline,
                enabled: !busy,
                onChanged: validate,
                decoration: InputDecoration(
                  hintText: 'https://… или vless://…',
                  counterText: '',
                  labelText: 'Ссылка из бота или на сервер',
                  errorText: error,
                  errorMaxLines: 4,
                  suffixIcon: input.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Очистить ссылку',
                          onPressed: () {
                            input.clear();
                            validate('');
                          },
                          icon: const Icon(Icons.close, size: 18),
                        ),
                ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(top: 14),
                  child: LinearProgressIndicator(),
                ),
              if (preview != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline, color: colors.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              preview!.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              'VLESS · ${preview!.transport.toUpperCase()} · ${preview!.security.toUpperCase()}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: (preview == null && !subscription) || busy
                    ? null
                    : submit,
                icon: const Icon(Icons.add, size: 20),
                label: Text(
                  subscription ? 'Загрузить подписку' : 'Добавить подключение',
                ),
              ),
              const SizedBox(height: 10),
              Text(
                subscription
                    ? (isVioraSubscription(subscriptionUri(input.text)) &&
                              camera
                          ? 'Загрузим серверы из бота. Это устройство передаст HWID и займёт один слот подписки Viora.'
                          : 'Загрузим список серверов по ссылке подписки. Вход через Telegram не требуется.')
                    : 'Вставь ссылку подписки из бота или отдельного сервера VLESS. Привязка Telegram не требуется.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScanPage extends StatefulWidget {
  const _ScanPage();
  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  bool handled = false;
  String? message;
  String? lastValue;

  void detected(BarcodeCapture capture) {
    if (handled || !mounted) return;
    for (final code in capture.barcodes) {
      final value = code.rawValue;
      if (value == null || value == lastValue) continue;
      lastValue = value;
      try {
        if (value.startsWith('https://')) {
          subscriptionUri(value);
        } else {
          VlessProfile.parse(value);
        }
        handled = true;
        Navigator.pop(context, value);
        return;
      } on FormatException {
        setState(
          () => message =
              'В этом QR нет ссылки подписки HTTPS или сервера VLESS.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Сканировать QR-код')),
    body: Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          onDetect: detected,
          overlayBuilder: (context, constraints) => IgnorePointer(
            child: Center(
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 3,
                  ),
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
            ),
          ),
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.no_photography_outlined, size: 48),
                  const SizedBox(height: 16),
                  const Text(
                    'Камера недоступна. Разреши доступ к камере в настройках Android или вернись и выбери QR из изображения.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Назад к импорту'),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 36,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              message ??
                  'Помести QR-код подключения в рамку. После распознавания ты сможешь проверить сервер.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ],
    ),
  );
}
