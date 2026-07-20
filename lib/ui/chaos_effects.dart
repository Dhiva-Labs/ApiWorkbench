import 'dart:math';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Chaos Mode response effects: confetti burst on success, shake + red flash
/// on errors. Wraps the response area; inert unless [enabled].
class ChaosEffects extends StatefulWidget {
  const ChaosEffects({
    super.key,
    required this.child,
    required this.enabled,
    required this.trigger, // changes when a new response arrives
    required this.statusCode, // 0 = transport error
    required this.isError,
  });

  final Widget child;
  final bool enabled;
  final Object? trigger;
  final int statusCode;
  final bool isError;

  @override
  State<ChaosEffects> createState() => _ChaosEffectsState();
}

class _ChaosEffectsState extends State<ChaosEffects>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400));
  List<_Particle> _particles = [];
  bool _celebrate = false;

  @override
  void didUpdateWidget(ChaosEffects old) {
    super.didUpdateWidget(old);
    if (!widget.enabled || widget.trigger == null) return;
    if (old.trigger == widget.trigger) return;
    final ok = !widget.isError &&
        widget.statusCode >= 200 &&
        widget.statusCode < 300;
    final bad = widget.isError || widget.statusCode >= 400;
    if (ok) {
      _celebrate = true;
      _particles = _burst();
      _ctrl.forward(from: 0);
    } else if (bad) {
      _celebrate = false;
      _ctrl.forward(from: 0);
    }
  }

  List<_Particle> _burst() {
    final rnd = Random();
    const colors = [
      Palette.accent, Palette.get_, Palette.post,
      Palette.patch, Palette.query, Palette.delete,
    ];
    return List.generate(90, (_) {
      final angle = -pi / 2 + (rnd.nextDouble() - 0.5) * pi * 1.1;
      final speed = 0.55 + rnd.nextDouble() * 0.9;
      return _Particle(
        x: 0.5 + (rnd.nextDouble() - 0.5) * 0.25,
        vx: cos(angle) * speed,
        vy: sin(angle) * speed * 1.15,
        size: 4 + rnd.nextDouble() * 5,
        color: colors[rnd.nextInt(colors.length)],
        spin: (rnd.nextDouble() - 0.5) * 14,
      );
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        final active = _ctrl.isAnimating;
        Widget body = widget.child;
        if (active && !_celebrate) {
          // decaying horizontal shake
          final shake = sin(t * pi * 9) * 9 * (1 - t) * (1 - t);
          body = Transform.translate(offset: Offset(shake, 0), child: body);
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            body,
            if (active && _celebrate)
              IgnorePointer(
                child: CustomPaint(
                    painter: _ConfettiPainter(_particles, t)),
              ),
            if (active && !_celebrate)
              IgnorePointer(
                child: Container(
                  color: Palette.delete
                      .withValues(alpha: 0.16 * (1 - t) * (1 - t)),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Particle {
  _Particle({
    required this.x,
    required this.vx,
    required this.vy,
    required this.size,
    required this.color,
    required this.spin,
  });

  final double x, vx, vy, size, spin;
  final Color color;
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.particles, this.t);

  final List<_Particle> particles;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final p in particles) {
      final x = (p.x + p.vx * t * 0.9) * size.width;
      // launch upward from just below the top, gravity pulls back down
      final y = (0.18 + p.vy * t + 1.35 * t * t) * size.height;
      if (y > size.height || x < -20 || x > size.width + 20) continue;
      paint.color = p.color.withValues(alpha: (1 - t).clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(p.spin * t);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset.zero, width: p.size, height: p.size * 0.62),
            const Radius.circular(1.5)),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}
