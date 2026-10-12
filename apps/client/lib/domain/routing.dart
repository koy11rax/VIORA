import 'dart:io';

enum RuleKind { domain, subnet, port }

enum RuleAction { vpn, direct, block }

class RoutingRule {
  final RuleKind kind;
  final String value;
  final RuleAction action;
  final bool enabled;
  const RoutingRule(this.kind, this.value, this.action, {this.enabled = true});

  factory RoutingRule.parse(
    RuleKind kind,
    String input,
    RuleAction action, {
    bool enabled = true,
  }) {
    var value = input.trim().toLowerCase();
    var valid = false;
    switch (kind) {
      case RuleKind.domain:
        if (value.endsWith('.')) value = value.substring(0, value.length - 1);
        valid =
            value.length <= 253 &&
            InternetAddress.tryParse(value) == null &&
            value.contains('.') &&
            value
                .split('.')
                .every(
                  (label) => RegExp(
                    r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$',
                  ).hasMatch(label),
                );
      case RuleKind.subnet:
        final parts = value.split('/');
        final ip = InternetAddress.tryParse(parts.first);
        final prefix = parts.length == 2 ? int.tryParse(parts.last) : null;
        valid =
            parts.length == 2 &&
            ip != null &&
            prefix != null &&
            prefix >= 0 &&
            prefix <= (ip.type == InternetAddressType.IPv4 ? 32 : 128);
      case RuleKind.port:
        final parts = value.split('-');
        final first = int.tryParse(parts.first);
        final last = int.tryParse(parts.last);
        valid =
            parts.length <= 2 &&
            first != null &&
            last != null &&
            first >= 1 &&
            last <= 65535 &&
            first <= last;
    }
    if (!valid) {
      throw const FormatException('Проверь домен, подсеть или диапазон портов');
    }
    return RoutingRule(kind, value, action, enabled: enabled);
  }
  RoutingRule toggle() => RoutingRule(kind, value, action, enabled: !enabled);
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'value': value,
    'action': action.name,
    'enabled': enabled,
  };
  factory RoutingRule.fromJson(Map<String, dynamic> data) => RoutingRule.parse(
    RuleKind.values.byName(data['kind'] as String),
    data['value'] as String,
    RuleAction.values.byName(data['action'] as String),
    enabled: data['enabled'] as bool,
  );
}
