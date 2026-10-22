import 'dart:math' as math;
import 'package:flutter/material.dart';

class VioraColors {
  final BuildContext context;
  VioraColors(this.context);
  bool get dark => Theme.of(context).brightness == Brightness.dark;
  Color get ink => dark ? const Color(0xfff3f2f6) : const Color(0xff25242b);
  Color get muted => dark ? const Color(0xffaaa9b3) : const Color(0xff63616e);
  Color get line => dark ? const Color(0xff303035) : const Color(0xffdedee4);
  Color get panel => dark ? const Color(0xff1a1a1e) : Colors.white;
  Color get raised => dark ? const Color(0xff232327) : const Color(0xffeeeef1);
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
            fontSize: 28,
            height: 1.2,
            letterSpacing: -.8,
            fontWeight: FontWeight.w600,
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

class PowerOrbit extends StatefulWidget {
  final VoidCallback? onPressed;
  final double size;
  final bool active, connecting, stopping, failed, motion;
  const PowerOrbit({
    super.key,
    this.onPressed,
    this.size = 182,
    this.active = false,
    this.connecting = false,
    this.stopping = false,
    this.failed = false,
    this.motion = true,
  });
  @override
  State<PowerOrbit> createState() => _PowerOrbitState();
}

class _PowerOrbitState extends State<PowerOrbit>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );

  void _syncMotion() {
    if (widget.motion &&
        !MediaQuery.disableAnimationsOf(context) &&
        (widget.connecting || widget.stopping)) {
      if (!_rotation.isAnimating) _rotation.repeat();
    } else {
      _rotation.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(PowerOrbit oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = VioraColors(context);
    final animating = widget.connecting || widget.stopping;
    final label = widget.stopping
        ? 'Отключаем VPN'
        : widget.connecting
        ? widget.onPressed == null
              ? 'Подключаем VPN'
              : 'Отменить подключение'
        : widget.active
        ? 'Отключить VPN'
        : 'Подключить VPN';
    final duration = !widget.motion || MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _rotation,
          builder: (context, child) => CustomPaint(
            painter: _OrbitPainter(
              line: c.line,
              accent: widget.failed
                  ? Theme.of(context).colorScheme.error
                  : c.accent,
              rotation: _rotation.value * 2 * math.pi,
              animating: animating,
              active: widget.active,
              stopping: widget.stopping,
            ),
            child: child,
          ),
          child: Center(
            child: Semantics(
              label: label,
              button: true,
              enabled: widget.onPressed != null && !widget.stopping,
              child: ExcludeSemantics(
                child: AnimatedContainer(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  width: widget.size * .63,
                  height: widget.size * .63,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.active
                        ? c.accent
                        : animating
                        ? c.soft
                        : c.raised,
                    border: Border.all(
                      color: widget.active || animating ? c.accent : c.line,
                    ),
                    boxShadow: widget.active
                        ? [
                            BoxShadow(
                              color: c.accent.withValues(alpha: .12),
                              blurRadius: 30,
                            ),
                          ]
                        : const [],
                  ),
                  child: IconButton(
                    tooltip: label,
                    onPressed: widget.stopping ? null : widget.onPressed,
                    style: IconButton.styleFrom(
                      shape: const CircleBorder(),
                      foregroundColor: widget.active
                          ? Theme.of(context).colorScheme.onPrimary
                          : animating
                          ? c.accent
                          : c.muted,
                    ),
                    icon: Icon(
                      Icons.power_settings_new,
                      size: widget.size * .23,
                    ),
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

class _OrbitPainter extends CustomPainter {
  final Color line, accent;
  final double rotation;
  final bool animating, active, stopping;
  const _OrbitPainter({
    required this.line,
    required this.accent,
    required this.rotation,
    required this.animating,
    required this.active,
    required this.stopping,
  });
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = line;
    canvas.drawCircle(center, radius, paint);
    canvas.drawCircle(center, radius * .81, paint);
    if (animating) {
      paint
        ..color = accent
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      final angle = stopping ? -rotation : rotation;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        angle,
        math.pi * .65,
        false,
        paint,
      );
      paint
        ..color = accent.withValues(alpha: .45)
        ..strokeWidth = 1.5;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius * .81),
        -angle,
        math.pi * .8,
        false,
        paint,
      );
    }
    canvas.drawCircle(
      Offset(center.dx + radius * .7, center.dy - radius * .7),
      3.5,
      Paint()..color = active || animating ? accent : line,
    );
  }

  @override
  bool shouldRepaint(_OrbitPainter old) =>
      old.line != line ||
      old.accent != accent ||
      old.rotation != rotation ||
      old.animating != animating ||
      old.active != active ||
      old.stopping != stopping;
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
