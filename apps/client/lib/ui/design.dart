import 'dart:math' as math;
import 'package:flutter/material.dart';

class VioraColors {
  final BuildContext context;
  VioraColors(this.context);
  bool get dark => Theme.of(context).brightness == Brightness.dark;
  Color get ink => dark ? const Color(0xfff4f1fc) : const Color(0xff221c35);
  Color get muted => dark ? const Color(0xffb4abc5) : const Color(0xff655c76);
  Color get line => dark ? const Color(0xff3c354b) : const Color(0xffded8e9);
  Color get panel => dark ? const Color(0xff1d1b25) : Colors.white;
  Color get raised => dark ? const Color(0xff272431) : const Color(0xffeeebf5);
  Color get accent => Theme.of(context).colorScheme.primary;
  Color get soft => Theme.of(context).colorScheme.primaryContainer;
}

class DesignHeading extends StatelessWidget {
  final String title, subtitle;
  const DesignHeading(this.title, this.subtitle, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 36,
            height: 1.08,
            letterSpacing: -1.3,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          subtitle,
          style: TextStyle(color: VioraColors(context).muted, height: 1.5),
        ),
      ],
    ),
  );
}

class DesignCard extends StatelessWidget {
  final Widget child;
  final double padding;
  const DesignCard({super.key, required this.child, this.padding = 22});
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(padding: EdgeInsets.all(padding), child: child),
  );
}

class DesignTag extends StatelessWidget {
  final String text;
  const DesignTag(this.text, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = VioraColors(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: c.soft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: c.accent)),
    );
  }
}

class PowerOrbit extends StatelessWidget {
  final VoidCallback? onPressed;
  final double size;
  const PowerOrbit({super.key, this.onPressed, this.size = 182});
  @override
  Widget build(BuildContext context) {
    final c = VioraColors(context);
    final factor = size / 182;
    return SizedBox(
      width: size * 1.15,
      height: size * 1.15,
      child: Center(
        child: Transform.rotate(
          angle: -9 * math.pi / 180,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(42 * factor),
              border: Border.all(color: c.line),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [c.soft, Theme.of(context).scaffoldBackgroundColor],
              ),
            ),
            child: Center(
              child: Transform.rotate(
                angle: 9 * math.pi / 180,
                child: SizedBox(
                  width: 132 * factor,
                  height: 132 * factor,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(32 * factor),
                      ),
                      elevation: 0,
                      shadowColor: Colors.transparent,
                    ),
                    onPressed: onPressed,
                    child: Icon(Icons.power_settings_new, size: 38 * factor),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DesignSetting extends StatelessWidget {
  final String title, subtitle;
  final Widget control;
  const DesignSetting(this.title, this.subtitle, this.control, {super.key});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 17),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: VioraColors(context).line)),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final labels = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: VioraColors(context).muted),
            ),
          ],
        );
        final dropdown = control is DropdownButton;
        if (dropdown && constraints.maxWidth < 520) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [labels, const SizedBox(height: 10), control],
          );
        }
        return Row(
          children: [
            Expanded(child: labels),
            const SizedBox(width: 16),
            if (dropdown) SizedBox(width: 220, child: control) else control,
          ],
        );
      },
    ),
  );
}
