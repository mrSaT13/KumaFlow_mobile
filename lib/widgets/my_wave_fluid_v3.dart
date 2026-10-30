import 'dart:math';
import 'package:flutter/material.dart';

/// V3 «флюид» для светлой темы — как на десктопе:
/// белая подложка + пурпурно-сиреневые пятна с blur и медленным дрейфом.
/// Пульс в такт опционален (beat 0..1), в покое — почти статика.
class MyWaveFluidV3 extends StatefulWidget {
  final double beat;
  final bool isPlaying;

  const MyWaveFluidV3({super.key, this.beat = 0, this.isPlaying = true});

  @override
  State<MyWaveFluidV3> createState() => _MyWaveFluidV3State();
}

class _MyWaveFluidV3State extends State<MyWaveFluidV3>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 12000))
      ..repeat();
    if (!widget.isPlaying) _ctrl.stop();
  }

  @override
  void didUpdateWidget(covariant MyWaveFluidV3 oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      if (widget.isPlaying) {
        if (!_ctrl.isAnimating) _ctrl.repeat();
      } else {
        _ctrl.stop();
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (ctx, _) {
          return CustomPaint(
            painter: _FluidV3Painter(
                t: _ctrl.value, beat: widget.beat.clamp(0.0, 1.0)),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _FluidV3Painter extends CustomPainter {
  final double t;
  final double beat;

  _FluidV3Painter({required this.t, required this.beat});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    // Белая подложка как на скрине десктопа.
    canvas.drawRect(
        Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);

    void blob(Offset c, double r, Color color, double alpha, double blur) {
      canvas.drawCircle(
          c,
          r,
          Paint()
            ..color = color.withValues(alpha: alpha)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur));
    }

    final pulse = 1.0 + 0.06 * beat;
    final a = t * 2 * pi;

    // Крупное пурпурное пятно слева (как на скрине).
    blob(
        Offset(w * (0.30 + 0.05 * sin(a + 0.4)),
            h * (0.45 + 0.06 * cos(a * 0.9))),
        w * 0.55 * pulse,
        const Color(0xFFB537F2),
        0.85,
        42);
    // Сиреневое правое.
    blob(
        Offset(w * (0.75 + 0.05 * sin(a * 1.1 + 1.2)),
            h * (0.40 + 0.07 * cos(a + 2.0))),
        w * 0.48 * pulse,
        const Color(0xFFE879F9),
        0.75,
        44);
    // Розовое нижнее.
    blob(
        Offset(w * (0.55 + 0.06 * cos(a * 0.8 + 0.7)),
            h * (0.85 + 0.05 * sin(a * 1.2))),
        w * 0.42,
        const Color(0xFFF0ABFC),
        0.7,
        40);
    // Фиолетовое верхнее.
    blob(
        Offset(w * (0.60 + 0.04 * sin(a * 1.3)),
            h * (0.10 + 0.05 * cos(a * 0.7 + 1.0))),
        w * 0.30,
        const Color(0xFF8B5CF6),
        0.65,
        34);
    // Тёмно-фиолетовое ядро слева для глубины.
    blob(
        Offset(w * (0.18 + 0.03 * cos(a + 2.2)), h * 0.55),
        w * 0.28 * pulse,
        const Color(0xFF7E22CE),
        0.55,
        36);
  }

  @override
  bool shouldRepaint(covariant _FluidV3Painter old) =>
      old.t != t || old.beat != beat;
}
