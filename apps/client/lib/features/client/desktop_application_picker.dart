import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../domain/desktop_applications.dart';
import '../../platform/native_bridge.dart';

class DesktopApplicationPicker extends StatefulWidget {
  final Set<String> selected;
  final VoidCallback onChanged;
  const DesktopApplicationPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });
  @override
  State<DesktopApplicationPicker> createState() =>
      _DesktopApplicationPickerState();
}

class _DesktopApplicationPickerState extends State<DesktopApplicationPicker> {
  late Future<List<Map<String, dynamic>>> apps = NativeBridge.applications();
  String query = '';
  String get platform => Platform.operatingSystem;
  void notice(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> add() async {
    final file = await openFile(
      acceptedTypeGroups: Platform.isWindows
          ? [
              const XTypeGroup(label: 'Программа Windows', extensions: ['exe']),
            ]
          : [],
    );
    if (file == null || !mounted) return;
    String path;
    try {
      final stat = await File(file.path).stat();
      if (stat.type != FileSystemEntityType.file ||
          (Platform.isLinux && stat.mode & 0x49 == 0)) {
        notice('Выбери исполняемый файл программы, а не ярлык');
        return;
      }
      path = Platform.isLinux
          ? await File(file.path).resolveSymbolicLinks()
          : file.path;
    } on FileSystemException {
      notice('Не удалось прочитать файл программы');
      return;
    }
    if (!mounted) return;
    final id = '$platform:${path.replaceAll(r'\', '/')}';
    if (!DesktopApplications.valid(id, platform)) {
      notice('Выбери исполняемый файл программы');
      return;
    }
    setState(() => widget.selected.add(id));
    widget.onChanged();
  }

  Future<void> importList() async {
    try {
      final ids = DesktopApplications.parse(
        (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '',
        platform,
      );
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Импорт программ'),
          content: Text(
            'В списке ${ids.length} программ. Пути должны существовать на этом компьютере. Изменения применятся после переподключения.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'merge'),
              child: const Text('Добавить'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'replace'),
              child: const Text('Заменить список'),
            ),
          ],
        ),
      );
      if (!mounted || choice == null) return;
      setState(() {
        if (choice == 'replace') widget.selected.clear();
        widget.selected.addAll(ids);
      });
      widget.onChanged();
    } on FormatException catch (e) {
      notice(e.message);
    } catch (_) {
      notice('Не удалось импортировать список');
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.tonalIcon(
            onPressed: add,
            icon: const Icon(Icons.add),
            label: const Text('Добавить программу'),
          ),
          OutlinedButton.icon(
            onPressed: importList,
            icon: const Icon(Icons.content_paste),
            label: const Text('Импорт'),
          ),
          OutlinedButton.icon(
            onPressed: widget.selected.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(
                      ClipboardData(
                        text: DesktopApplications.encode(
                          widget.selected,
                          platform,
                        ),
                      ),
                    );
                    notice('Список программ скопирован');
                  },
            icon: const Icon(Icons.copy),
            label: const Text('Экспорт'),
          ),
          IconButton(
            onPressed: () => setState(() => apps = NativeBridge.applications()),
            tooltip: 'Обновить список',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      const SizedBox(height: 16),
      TextField(
        decoration: const InputDecoration(
          labelText: 'Найти программу',
          prefixIcon: Icon(Icons.search),
        ),
        onChanged: (v) => setState(() => query = v.toLowerCase().trim()),
      ),
      const SizedBox(height: 12),
      FutureBuilder<List<Map<String, dynamic>>>(
        future: apps,
        builder: (context, snapshot) {
          final rows = <String, String>{};
          for (final row in snapshot.data ?? <Map<String, dynamic>>[]) {
            final id = row['id'];
            if (id is String && DesktopApplications.valid(id, platform)) {
              rows[id] = row['name'] as String;
            }
          }
          for (final id in widget.selected) {
            rows.putIfAbsent(id, () => id.split('/').last);
          }
          final ids =
              rows.keys
                  .where(
                    (id) => '$id ${rows[id]}'.toLowerCase().contains(query),
                  )
                  .toList()
                ..sort((a, b) {
                  final first =
                      (widget.selected.contains(b) ? 1 : 0) -
                      (widget.selected.contains(a) ? 1 : 0);
                  return first != 0
                      ? first
                      : rows[a]!.toLowerCase().compareTo(
                          rows[b]!.toLowerCase(),
                        );
                });
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (snapshot.connectionState != ConnectionState.done)
                const LinearProgressIndicator(),
              if (snapshot.hasError)
                const Text(
                  'Автоматический список недоступен. Программу можно добавить вручную.',
                ),
              for (final id in ids)
                CheckboxListTile(
                  key: ValueKey(id),
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.apps_outlined),
                  title: Text(rows[id]!),
                  subtitle: Text(
                    id.substring(id.indexOf(':') + 1),
                    style: const TextStyle(fontSize: 11),
                  ),
                  value: widget.selected.contains(id),
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        widget.selected.add(id);
                      } else {
                        widget.selected.remove(id);
                      }
                    });
                    widget.onChanged();
                  },
                ),
              if (ids.isEmpty &&
                  snapshot.connectionState == ConnectionState.done)
                const Text(
                  'Программы не найдены. Добавь исполняемый файл вручную.',
                ),
            ],
          );
        },
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
      const Text(
        'Выбирай исполняемый файл, а не ярлык. Для браузера или клиента с несколькими процессами при необходимости добавь вспомогательные программы. DNS остаётся защищённым через VPN.',
      ),
    ],
  );
}
