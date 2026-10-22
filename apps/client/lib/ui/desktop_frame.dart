import 'dart:io';
import 'package:flutter/material.dart';
import 'design.dart';

class DesktopFrame extends StatelessWidget {
  final int index;
  final bool owner, demo;
  final String? warning;
  final ValueChanged<int> onNavigate;
  final VoidCallback onImport;
  final VoidCallback? onAccount, onTrayMenu;
  final Widget child;
  const DesktopFrame({
    super.key,
    required this.index,
    required this.owner,
    required this.demo,
    required this.onNavigate,
    required this.onImport,
    required this.child,
    this.warning,
    this.onAccount,
    this.onTrayMenu,
  });
  @override
  Widget build(BuildContext context) {
    final c = VioraColors(context);
    final currentPage = index >= 10 ? 4 : index;
    final destinations = [
      (0, Icons.blur_circular, 'Главная'),
      (1, Icons.layers_outlined, 'Серверы'),
      (2, Icons.confirmation_number_outlined, 'Моя подписка'),
      (3, Icons.route_outlined, 'Маршрутизация'),
      (6, Icons.web_asset_outlined, 'Приложения'),
      (7, Icons.palette_outlined, 'Внешний вид'),
      (4, Icons.tune, 'Настройки'),
    ];
    Widget nav(int page, IconData icon, String label) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: currentPage == page ? c.soft : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: Semantics(
          selected: currentPage == page,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => onNavigate(page),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 19,
                      color: currentPage == page ? c.accent : c.muted,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: page == 5 ? 12 : 13,
                          height: 1.5,
                          color: currentPage == page ? c.ink : c.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  key: const Key('approved-sidebar'),
                  width: 216,
                  decoration: BoxDecoration(
                    border: Border(right: BorderSide(color: c.line)),
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 28),
                        child: SizedBox(
                          height: 48,
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(11),
                                child: Image.asset(
                                  'assets/viora.png',
                                  width: 40,
                                  height: 40,
                                  excludeFromSemantics: true,
                                ),
                              ),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'viora',
                                    style: TextStyle(
                                      fontSize: 29,
                                      height: 1.2,
                                      letterSpacing: -1.6,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              for (final d in destinations)
                                nav(d.$1, d.$2, d.$3),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (owner)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 20),
                          child: Tooltip(
                            message: 'Кабинет владельца',
                            child: OutlinedButton.icon(
                              onPressed: () => onNavigate(5),
                              icon: const Icon(Icons.shield_outlined, size: 19),
                              label: const Text(
                                'Администрирование',
                                style: TextStyle(fontSize: 12),
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 12,
                                ),
                                foregroundColor: c.accent,
                                backgroundColor: c.soft,
                              ),
                            ),
                          ),
                        ),
                      nav(8, Icons.help_outline, 'Помощь'),
                      Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Text(
                          'Viora VPN · ваш сервис',
                          style: TextStyle(fontSize: 12, color: c.muted),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(32, 20, 32, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (onAccount != null) ...[
                              IconButton(
                                tooltip: 'Мой аккаунт',
                                onPressed: onAccount,
                                icon: const Icon(Icons.account_circle_outlined),
                              ),
                              const SizedBox(width: 10),
                            ],
                            OutlinedButton.icon(
                              onPressed: onImport,
                              icon: const Icon(Icons.add, size: 19),
                              label: const Text('Импорт'),
                              style: OutlinedButton.styleFrom(
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                minimumSize: const Size(0, 40),
                                textStyle: TextStyle(
                                  fontSize: 12,
                                  fontFamily: Theme.of(
                                    context,
                                  ).textTheme.labelLarge?.fontFamily,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                              ),
                            ),
                            if (onTrayMenu != null)
                              IconButton(
                                tooltip: 'Меню VIORA',
                                onPressed: onTrayMenu,
                                icon: const Icon(Icons.more_vert),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        if (warning != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              warning!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        Expanded(child: child),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.line)),
            ),
            child: Text(
              demo
                  ? 'Демонстрационные данные · Без реальных подключений и оплат'
                  : Platform.isWindows
                  ? 'Крестик — в трей · Полный выход — в меню значка VIORA'
                  : 'VIORA · Твой интернет. Твои правила.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: c.muted),
            ),
          ),
        ],
      ),
    );
  }
}
