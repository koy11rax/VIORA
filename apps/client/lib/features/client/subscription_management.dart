import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/subscription_import.dart';
import '../../domain/profile.dart';
import '../../ui/design.dart';

/// The source stays private until the user explicitly reveals the editor.
class SavedSubscription {
  final String source;
  final int profileCount;
  const SavedSubscription(this.source, this.profileCount);

  String get host => Uri.tryParse(source)?.host ?? 'Провайдер';
  bool get viora => isVioraSubscription(Uri.parse(source));

  @override
  String toString() =>
      'SavedSubscription(source:redacted, servers:$profileCount)';
}

class SubscriptionManagementPage extends StatefulWidget {
  final List<SavedSubscription> Function() entries;
  final Future<bool> Function(String source, String replacement) onEdit;
  final Future<bool> Function(String source) onDelete;
  final Future<void> Function() onImport;
  final List<VlessProfile> Function()? standaloneEntries;
  final Future<bool> Function(String link, String replacement)?
  onEditStandalone;
  final Future<bool> Function(String link)? onDeleteStandalone;
  const SubscriptionManagementPage({
    super.key,
    required this.entries,
    required this.onEdit,
    required this.onDelete,
    required this.onImport,
    this.standaloneEntries,
    this.onEditStandalone,
    this.onDeleteStandalone,
  });

  @override
  State<SubscriptionManagementPage> createState() =>
      _SubscriptionManagementPageState();
}

class _SubscriptionManagementPageState
    extends State<SubscriptionManagementPage> {
  bool _busy = false, _processing = false;
  String? _error;

  void _finishOperation() {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _processing = false;
    });
  }

  Future<void> _edit(SavedSubscription entry) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SubscriptionEditor(
          source: entry.source,
          save: (value) => widget.onEdit(entry.source, value),
        ),
      );
    } finally {
      _finishOperation();
    }
  }

  Future<void> _delete(SavedSubscription entry) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить подписку?'),
        content: Text(
          'Будет удалена ссылка ${entry.host} и её серверы (${entry.profileCount}). '
          'Серверы других подписок и подключения, не входящие в эту подписку, останутся. '
          'Если выбранный сервер удаляется, VIORA сначала отключит VPN. '
          'Подписка у провайдера и её оплата не отменяются.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Оставить'),
          ),
          FilledButton(
            key: const ValueKey('confirm-delete-subscription'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить подписку'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() {
      _busy = true;
      _processing = true;
      _error = null;
    });
    try {
      final deleted = await widget.onDelete(entry.source);
      if (mounted && !deleted) {
        setState(
          () => _error =
              'Не удалось удалить подписку. Данные сохранены. Заверши другие операции и повтори.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Не удалось удалить подписку. Данные сохранены.',
        );
      }
    } finally {
      _finishOperation();
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onImport();
    } finally {
      _finishOperation();
    }
  }

  Future<void> _editStandalone(VlessProfile profile) async {
    if (_busy || widget.onEditStandalone == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SubscriptionEditor(
          source: profile.toShareLink(),
          standalone: true,
          save: (value) =>
              widget.onEditStandalone!(profile.toShareLink(), value),
        ),
      );
    } finally {
      _finishOperation();
    }
  }

  Future<void> _deleteStandalone(VlessProfile profile) async {
    if (_busy || widget.onDeleteStandalone == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить отдельный сервер?'),
        content: const Text(
          'Будет удалено только это отдельное подключение. Подписки и другие серверы сохранятся. Если этот сервер используется, VIORA сначала отключит VPN.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Оставить'),
          ),
          FilledButton(
            key: const ValueKey('confirm-delete-standalone'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить сервер'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final removed = await widget.onDeleteStandalone!(profile.toShareLink());
      if (mounted && !removed) {
        setState(
          () => _error = 'Не удалось удалить сервер. Подключение сохранено.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Не удалось удалить сервер. Подключение сохранено.',
        );
      }
    } finally {
      _finishOperation();
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries();
    final standalone =
        widget.standaloneEntries?.call() ?? const <VlessProfile>[];
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Сохранённые подключения')),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Обновляй ссылки и управляй серверами своих провайдеров. Полные ссылки скрыты: они дают доступ к подписке.',
                ),
                const SizedBox(height: 20),
                Text('Подписки', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                if (_processing) const LinearProgressIndicator(),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                if (entries.isEmpty)
                  const DesignCard(
                    child: Text(
                      'Сохранённых подписок пока нет. Добавь HTTPS-ссылку провайдера через импорт.',
                    ),
                  ),
                for (var index = 0; index < entries.length; index++) ...[
                  _SubscriptionCard(
                    entry: entries[index],
                    number: index + 1,
                    edit: _busy ? null : () => _edit(entries[index]),
                    delete: _busy ? null : () => _delete(entries[index]),
                  ),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _import,
                  icon: const Icon(Icons.add_link_rounded),
                  label: const Text('Добавить подписку'),
                ),
                const SizedBox(height: 24),
                Text(
                  'Отдельные серверы',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Подключения без подписки. Серверы из подписок меняются через ссылку провайдера.',
                ),
                const SizedBox(height: 12),
                if (standalone.isEmpty)
                  const DesignCard(child: Text('Отдельных серверов пока нет.')),
                for (final profile in standalone) ...[
                  DesignCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          profile.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(profile.displayLabel),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _editStandalone(profile),
                              icon: const Icon(Icons.edit_outlined, size: 19),
                              label: const Text('Изменить сервер'),
                            ),
                            TextButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _deleteStandalone(profile),
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 19,
                              ),
                              label: const Text('Удалить сервер'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  final SavedSubscription entry;
  final int number;
  final VoidCallback? edit, delete;
  const _SubscriptionCard({
    required this.entry,
    required this.number,
    this.edit,
    this.delete,
  });

  @override
  Widget build(BuildContext context) => DesignCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              entry.viora ? Icons.verified_user_outlined : Icons.link_rounded,
              color: VioraColors(context).accent,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.viora ? 'VIORA VPN' : 'Подписка $number',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    entry.host,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Серверов: ${entry.profileCount}',
                    style: TextStyle(color: VioraColors(context).muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: edit,
              icon: const Icon(Icons.edit_outlined, size: 19),
              label: const Text('Изменить ссылку'),
            ),
            TextButton.icon(
              onPressed: delete,
              icon: const Icon(Icons.delete_outline_rounded, size: 19),
              label: const Text('Удалить'),
            ),
          ],
        ),
      ],
    ),
  );
}

class _SubscriptionEditor extends StatefulWidget {
  final String source;
  final bool standalone;
  final Future<bool> Function(String) save;
  const _SubscriptionEditor({
    required this.source,
    required this.save,
    this.standalone = false,
  });

  @override
  State<_SubscriptionEditor> createState() => _SubscriptionEditorState();
}

class _SubscriptionEditorState extends State<_SubscriptionEditor> {
  late final _controller = TextEditingController(text: widget.source);
  bool _saving = false, _visible = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted || _saving) return;
      _controller.text = data?.text?.trim() ?? '';
      setState(() => _error = null);
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось прочитать буфер обмена');
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    String value;
    try {
      value = widget.standalone
          ? VlessProfile.parse(_controller.text).toShareLink()
          : subscriptionUri(_controller.text).toString();
    } on FormatException {
      setState(
        () => _error = widget.standalone
            ? 'Проверь ссылку сервера и поддерживаемый протокол'
            : 'Укажи корректную HTTPS-ссылку подписки',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _visible = false;
    });
    try {
      final saved = await widget.save(value);
      if (!mounted) return;
      if (saved) {
        Navigator.pop(context, true);
      } else {
        setState(
          () => _error = widget.standalone
              ? 'Не удалось изменить сервер. Прежние параметры сохранены.'
              : 'Не удалось обновить подписку. Проверь ссылку, доступ и другие сохранённые подписки. Старые серверы сохранены.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = widget.standalone
              ? 'Не удалось изменить сервер. Прежние параметры сохранены.'
              : 'Не удалось обновить подписку. Старые серверы сохранены.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(
        widget.standalone
            ? 'Изменить отдельный сервер'
            : 'Изменить ссылку подписки',
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.standalone
                    ? 'Проверим формат ссылки. Если этот сервер используется, VIORA переподключится с новыми параметрами.'
                    : 'Сначала проверим новую подписку. Старая ссылка и серверы сохранятся, если загрузка не удастся.',
              ),
              const SizedBox(height: 18),
              TextField(
                key: const ValueKey('subscription-url-editor'),
                controller: _controller,
                enabled: !_saving,
                obscureText: !_visible,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                smartDashesType: SmartDashesType.disabled,
                smartQuotesType: SmartQuotesType.disabled,
                autofillHints: const [],
                maxLength: 16384,
                decoration: InputDecoration(
                  labelText: widget.standalone
                      ? 'Ссылка сервера'
                      : 'HTTPS-ссылка подписки',
                  counterText: '',
                  suffixIcon: IconButton(
                    tooltip: _visible ? 'Скрыть ссылку' : 'Показать ссылку',
                    onPressed: _saving
                        ? null
                        : () => setState(() => _visible = !_visible),
                    icon: Icon(
                      _visible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _saving ? null : _paste,
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                label: const Text('Вставить из буфера'),
              ),
              if (_saving) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(
                  widget.standalone
                      ? 'Сохраняем параметры сервера…'
                      : 'Проверяем ссылку и загружаем серверы…',
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          key: const ValueKey('save-subscription-url'),
          onPressed: _saving ? null : _save,
          child: const Text('Проверить и сохранить'),
        ),
      ],
    ),
  );
}
