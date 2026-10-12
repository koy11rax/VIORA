import 'package:flutter/material.dart';

class AccountCard extends StatelessWidget {
  final Widget child;
  final bool highlighted;
  const AccountCard({super.key, required this.child, this.highlighted = false});
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: highlighted ? colors.primaryContainer : colors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: highlighted
              ? colors.primary.withValues(alpha: .32)
              : colors.outlineVariant,
        ),
      ),
      child: child,
    );
  }
}

class AccountBadge extends StatelessWidget {
  final String text;
  final IconData icon;
  const AccountBadge(
    this.text, {
    super.key,
    this.icon = Icons.verified_outlined,
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primary.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ],
    ),
  );
}

/// A font-independent currency glyph, with a spoken currency for accessibility.
class MoneyAmount extends StatelessWidget {
  final Object amount;
  final String currency;
  final double size;
  const MoneyAmount(
    this.amount, {
    super.key,
    this.currency = 'RUB',
    this.size = 24,
  });
  @override
  Widget build(BuildContext context) => Semantics(
    label: '$amount ${currency == 'XTR' ? 'звёзд' : 'рублей'}',
    child: ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              '$amount',
              style: TextStyle(fontSize: size, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            currency == 'XTR' ? Icons.star_rounded : Icons.currency_ruble,
            size: size * .9,
          ),
        ],
      ),
    ),
  );
}

class AccountContent extends StatelessWidget {
  final List<Widget> children;
  const AccountContent({super.key, required this.children});
  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
          children: children,
        ),
      ),
    ),
  );
}

String subscriptionDate(DateTime date) {
  final d = date.toLocal();
  return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
}
