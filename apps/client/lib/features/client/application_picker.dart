import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../domain/application_list.dart';
import 'package:flutter/material.dart';
import '../../platform/native_bridge.dart';

class ApplicationPicker extends StatefulWidget {
  final Set<String> selected;
  final VoidCallback onChanged;
  const ApplicationPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });
  @override
  State<ApplicationPicker> createState() => _ApplicationPickerState();
}

class _ApplicationPickerState extends State<ApplicationPicker> {
  late Future<List<Map<String, dynamic>>> _apps;
  String _query = '';
  @override
  void initState() {
    super.initState();
    _apps = NativeBridge.applications();
  }

  bool transferring = false;
  void _notice(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _export() async {
    try {
      await Clipboard.setData(
        ClipboardData(text: ApplicationList.encode(widget.selected)),
      );
      _notice('Список приложений скопирован');
    } catch (_) {
      _notice('Не удалось скопировать список');
    }
  }

  Future<void> _import() async {
    if (transferring) return;
    setState(() => transferring = true);
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final packages = ApplicationList.parse(data?.text ?? '');
      final installed = await _apps;
      if (!mounted) return;
      final available = installed.map((app) => app['id'] as String).toSet();
      final found = packages.intersection(available);
      final missing = packages.difference(available);
      if (found.isEmpty) {
        _notice(
          'На телефоне не найдено приложений из списка. Текущий выбор сохранён.',
        );
        return;
      }
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Импорт приложений'),
          content: SingleChildScrollView(
            child: Text(
              'Найдено на телефоне: ${found.length}.\nНе найдено: ${missing.length}.\n\n'
              'Режим VPN останется прежним. Неустановленные приложения будут пропущены.'
              '${missing.isEmpty ? '' : '\n\nНе найдены:\n${missing.take(8).join('\n')}${missing.length > 8 ? '\n…' : ''}'}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'replace'),
              child: const Text('Заменить список'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'merge'),
              child: const Text('Дополнить'),
            ),
          ],
        ),
      );
      if (!mounted || choice == null) return;
      if (choice == 'merge' && widget.selected.union(found).length > 1000) {
        _notice('Можно выбрать до 1000 приложений');
        return;
      }
      setState(() {
        if (choice == 'replace') widget.selected.clear();
        widget.selected.addAll(found);
      });
      widget.onChanged();
      _notice(
        'Выбрано приложений: ${widget.selected.length}. Применится при следующем подключении.',
      );
    } on FormatException catch (e) {
      _notice(e.message);
    } catch (_) {
      _notice('Не удалось прочитать список. Проверь буфер обмена и повтори.');
    } finally {
      if (mounted) setState(() => transferring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const Text('Выбор приложений на ПК ещё в разработке.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Выбрано: ${widget.selected.length}. Изменения применяются при следующем подключении.',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: transferring ? null : _import,
              icon: const Icon(Icons.content_paste_go),
              label: const Text('Из буфера'),
            ),
            OutlinedButton.icon(
              onPressed: widget.selected.isEmpty || transferring
                  ? null
                  : _export,
              icon: const Icon(Icons.copy_all),
              label: const Text('Скопировать список'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          decoration: const InputDecoration(
            labelText: 'Найти приложение',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) =>
              setState(() => _query = value.trim().toLowerCase()),
        ),
        TextButton(
          onPressed: widget.selected.isEmpty
              ? null
              : () {
                  setState(widget.selected.clear);
                  widget.onChanged();
                },
          child: const Text('Снять весь выбор'),
        ),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _apps,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Column(
                children: [
                  const Text('Не удалось получить приложения'),
                  TextButton(
                    onPressed: () =>
                        setState(() => _apps = NativeBridge.applications()),
                    child: const Text('Повторить'),
                  ),
                ],
              );
            }
            if (!snapshot.hasData) {
              return const Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(),
              );
            }
            final apps = snapshot.data!
                .where(
                  (app) => '${app['name']} ${app['id']}'.toLowerCase().contains(
                    _query,
                  ),
                )
                .toList();
            apps.sort((a, b) {
              final aSelected = widget.selected.contains(a['id']);
              final bSelected = widget.selected.contains(b['id']);
              if (aSelected != bSelected) return aSelected ? -1 : 1;
              final byName = (a['name'] as String).toLowerCase().compareTo(
                (b['name'] as String).toLowerCase(),
              );
              return byName != 0
                  ? byName
                  : (a['id'] as String).compareTo(b['id'] as String);
            });
            return Column(
              children: [
                if (apps.isEmpty) const Text('Приложения не найдены'),
                for (final app in apps)
                  CheckboxListTile(
                    key: ValueKey(app['id']),
                    contentPadding: EdgeInsets.zero,
                    title: Text(app['name'] as String),
                    subtitle: Text(
                      app['id'] as String,
                      style: const TextStyle(fontSize: 11),
                    ),
                    value: widget.selected.contains(app['id']),
                    onChanged: (checked) {
                      setState(
                        () => checked!
                            ? widget.selected.add(app['id'] as String)
                            : widget.selected.remove(app['id']),
                      );
                      widget.onChanged();
                    },
                  ),
                const Text(
                  'Показаны приложения с иконкой запуска. Системные службы и сама Viora в список не входят.',
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
