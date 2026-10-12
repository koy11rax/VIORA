import 'package:flutter/material.dart';
import '../../domain/routing.dart';

class RoutingEditor extends StatefulWidget {
  final List<RoutingRule> rules;
  final VoidCallback onChanged;
  final bool appliesToAndroid;
  const RoutingEditor({
    super.key,
    required this.rules,
    required this.onChanged,
    this.appliesToAndroid = false,
  });
  @override
  State<RoutingEditor> createState() => _RoutingEditorState();
}

class _RoutingEditorState extends State<RoutingEditor> {
  static const kinds = ['Домен', 'IP / подсеть', 'Порт / диапазон'];
  static const actions = ['Через VPN', 'Напрямую', 'Блокировать'];
  void change(VoidCallback edit) {
    setState(edit);
    widget.onChanged();
  }

  Future<void> add([int? index]) async {
    final rule = await showDialog<RoutingRule>(
      context: context,
      builder: (_) =>
          _RuleDialog(initial: index == null ? null : widget.rules[index]),
    );
    if (rule == null || !mounted) return;
    change(() {
      if (index == null) {
        widget.rules.add(rule);
      } else {
        widget.rules[index] = rule;
      }
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        widget.appliesToAndroid
            ? 'Правила применяются при следующем подключении. Первое совпадение определяет маршрут; домены включают поддомены. DNS остаётся через VPN, IPv6 пока блокируется независимо от правил.'
            : 'Правила проверяются сверху вниз: первое совпадение определяет маршрут. Домены включают поддомены. На ПК пока сохраняется только конфигурация; трафик не изменяется.',
      ),
      const SizedBox(height: 16),
      for (var i = 0; i < widget.rules.length; i++)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(widget.rules[i].value),
                  subtitle: Text(
                    '${kinds[widget.rules[i].kind.index]} · ${actions[widget.rules[i].action.index]}',
                  ),
                  value: widget.rules[i].enabled,
                  onChanged: (_) =>
                      change(() => widget.rules[i] = widget.rules[i].toggle()),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    IconButton(
                      tooltip: 'Выше',
                      onPressed: i == 0
                          ? null
                          : () => change(() {
                              final rule = widget.rules.removeAt(i);
                              widget.rules.insert(i - 1, rule);
                            }),
                      icon: const Icon(Icons.arrow_upward),
                    ),
                    IconButton(
                      tooltip: 'Ниже',
                      onPressed: i == widget.rules.length - 1
                          ? null
                          : () => change(() {
                              final rule = widget.rules.removeAt(i);
                              widget.rules.insert(i + 1, rule);
                            }),
                      icon: const Icon(Icons.arrow_downward),
                    ),
                    IconButton(
                      tooltip: 'Изменить правило',
                      onPressed: () => add(i),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: 'Удалить правило',
                      onPressed: () => change(() => widget.rules.removeAt(i)),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      if (widget.rules.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Text('Правил пока нет'),
        ),
      FilledButton.icon(
        onPressed: widget.rules.length >= 200 ? null : add,
        icon: const Icon(Icons.add),
        label: const Text('Добавить правило'),
      ),
    ],
  );
}

class _RuleDialog extends StatefulWidget {
  final RoutingRule? initial;
  const _RuleDialog({this.initial});
  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late RuleKind kind = widget.initial?.kind ?? RuleKind.domain;
  late RuleAction action = widget.initial?.action ?? RuleAction.vpn;
  late final value = TextEditingController(text: widget.initial?.value);
  String? error;
  @override
  void dispose() {
    value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial == null ? 'Новое правило' : 'Изменить правило'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<RuleKind>(
              initialValue: kind,
              decoration: const InputDecoration(labelText: 'Условие'),
              items: [
                for (final k in RuleKind.values)
                  DropdownMenuItem(
                    value: k,
                    child: Text(_RoutingEditorState.kinds[k.index]),
                  ),
              ],
              onChanged: (v) => setState(() {
                kind = v!;
                error = null;
              }),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: value,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Значение',
                errorText: error,
                hintText: [
                  'example.org',
                  '192.168.0.0/16',
                  '443 или 8000-9000',
                ][kind.index],
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<RuleAction>(
              initialValue: action,
              decoration: const InputDecoration(labelText: 'Действие'),
              items: [
                for (final a in RuleAction.values)
                  DropdownMenuItem(
                    value: a,
                    child: Text(_RoutingEditorState.actions[a.index]),
                  ),
              ],
              onChanged: (v) => setState(() => action = v!),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          try {
            Navigator.pop(
              context,
              RoutingRule.parse(
                kind,
                value.text,
                action,
                enabled: widget.initial?.enabled ?? true,
              ),
            );
          } on FormatException catch (e) {
            setState(() => error = e.message);
          }
        },
        child: const Text('Сохранить'),
      ),
    ],
  );
}
