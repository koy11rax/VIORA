import 'dart:math';

class VioraUser {
  final int id;
  final String name;
  final String username;
  DateTime? expires;
  VioraUser(this.id, this.name, this.username, this.expires);
  bool get active => expires?.isAfter(DateTime.now().toUtc()) ?? false;
  factory VioraUser.fromJson(Map<String, dynamic> json) => VioraUser(
    json['tg_id'] as int,
    json['first_name'] as String? ?? 'Пользователь',
    json['username'] as String? ?? '',
    DateTime.tryParse(json['expires_at'] as String? ?? '')?.toUtc(),
  );
}

class VioraGroup {
  final String id, name;
  final int count;
  const VioraGroup(this.id, this.name, this.count);
}

class GrantRecipient {
  final int id;
  final String name;
  final DateTime? before;
  final DateTime after;
  const GrantRecipient(this.id, this.name, this.before, this.after);
}

class GrantPreview {
  final String id, reason;
  final int days;
  final List<GrantRecipient> recipients;
  final DateTime deadline;
  const GrantPreview(
    this.id,
    this.days,
    this.reason,
    this.recipients,
    this.deadline,
  );
}

abstract interface class ControlRepository {
  bool get isDevelopment;
  Future<bool> isOwner();
  Future<List<VioraUser>> users();
  Future<List<VioraGroup>> groups();
  Future<VioraGroup> createGroup(String name, Set<int> ids);
  Future<GrantPreview> preview(
    int days,
    String reason,
    Set<int> ids,
    Set<String> groups,
  );
  Future<String> commit(GrantPreview preview);
  Future<List<String>> audit();
}

/// Explicit development fixtures. This is not a source of server privileges.
class DevelopmentControl implements ControlRepository {
  @override
  bool get isDevelopment => true;
  final List<VioraUser> _users = [
    VioraUser(
      1001,
      'Алексей',
      'alex_demo',
      DateTime.now().toUtc().add(const Duration(days: 30)),
    ),
    VioraUser(
      1002,
      'Мария',
      'maria_demo',
      DateTime.now().toUtc().add(const Duration(days: 12)),
    ),
    VioraUser(
      1003,
      'Илья',
      'ilya_demo',
      DateTime.now().toUtc().subtract(const Duration(days: 2)),
    ),
  ];
  final Map<String, (String, Set<int>)> _groups = {};
  final Map<String, GrantPreview> _previews = {};
  final Set<String> _committed = {};
  final List<String> _audit = [];
  @override
  Future<bool> isOwner() async => true;
  @override
  Future<List<VioraUser>> users() async => List.unmodifiable(_users);
  @override
  Future<List<VioraGroup>> groups() async => _groups.entries
      .map((e) => VioraGroup(e.key, e.value.$1, e.value.$2.length))
      .toList();
  @override
  Future<VioraGroup> createGroup(String name, Set<int> ids) async {
    if (name.trim().isEmpty || ids.isEmpty) {
      throw StateError('Укажи название и выбери пользователей');
    }
    final id = 'group-${_groups.length + 1}';
    _groups[id] = (name.trim(), Set.of(ids));
    return VioraGroup(id, name.trim(), ids.length);
  }

  @override
  Future<GrantPreview> preview(
    int days,
    String reason,
    Set<int> ids,
    Set<String> groups,
  ) async {
    if (days < 1 || days > 3650 || reason.trim().length < 3) {
      throw StateError('Укажи 1–3650 дней и причину');
    }
    final all = Set<int>.of(ids);
    for (final group in groups) {
      if (['all', 'active', 'expired', 'recent'].contains(group)) {
        all.addAll(
          _users
              .where(
                (u) =>
                    group == 'all' ||
                    (group == 'recent' &&
                        !u.active &&
                        u.expires != null &&
                        u.expires!.isAfter(
                          DateTime.now().toUtc().subtract(
                            const Duration(days: 10),
                          ),
                        )) ||
                    (group != 'recent' && u.active == (group == 'active')),
              )
              .map((u) => u.id),
        );
      } else {
        all.addAll(_groups[group]?.$2 ?? {});
      }
    }
    if (all.isEmpty) throw StateError('Выбери получателей');
    final now = DateTime.now().toUtc();
    final recipients = _users
        .where((u) => all.contains(u.id))
        .map(
          (u) => GrantRecipient(
            u.id,
            u.name,
            u.expires,
            (u.active ? u.expires! : now).add(Duration(days: days)),
          ),
        )
        .toList();
    final p = GrantPreview(
      'preview-${Random.secure().nextInt(1 << 32)}',
      days,
      reason.trim(),
      recipients,
      now.add(const Duration(minutes: 5)),
    );
    _previews[p.id] = p;
    return p;
  }

  @override
  Future<String> commit(GrantPreview preview) async {
    if (_committed.contains(preview.id)) return 'Дни уже выданы · разработка';
    final p = _previews[preview.id];
    if (p == null || p.deadline.isBefore(DateTime.now().toUtc())) {
      throw StateError('Предпросмотр истёк');
    }
    for (final r in p.recipients) {
      if (_users.firstWhere((u) => u.id == r.id).expires != r.before) {
        throw StateError('Подписки изменились. Проверь список заново');
      }
    }
    for (final r in p.recipients) {
      _users.firstWhere((u) => u.id == r.id).expires = r.after;
      _audit.insert(0, '${r.name}: +${p.days} дней · ${p.reason}');
    }
    _committed.add(p.id);
    return 'Выдано ${p.days} дней: ${p.recipients.length} получателей. Только локальные данные разработки.';
  }

  @override
  Future<List<String>> audit() async => List.unmodifiable(_audit);
}
