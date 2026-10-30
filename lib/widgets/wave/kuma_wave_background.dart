import 'dart:math' as math;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import '../../services/wave_energy_service.dart';
import 'wave_mood.dart';

/// Фон «Моей волны» 1в1 как на ПК (`KumaWaveBackground`):
/// сплошная подложка + ореол blur + капля из 3 blob
/// (radial-gradient + сильный блюр, морфинг в противофазе,
/// блюр сливает их в «взрыв краски») + канвас-эффект по настроению жанра.
///
/// Цвета — из доминанты обложки (buildWaveTrio), не жанровый градиент.
/// Анти-нагрузка: один тикер на всё, DPR без ограничений не трогаем
/// (холст = размер карточки), при !alive тикер стоит, при сворачивании
/// приложения — тоже. Эффекты рубятся поштучно тумблерами.
class KumaWaveBackground extends StatefulWidget {
  final bool alive;
  final bool playing;
  final bool dark;
  final List<Color> trio;
  final WaveMood mood;
  final Set<WaveMood> enabledFx;

  const KumaWaveBackground({
    super.key,
    this.alive = true,
    this.playing = false,
    this.dark = false,
    this.trio = defaultWaveTrio,
    this.mood = WaveMood.none,
    this.enabledFx = const {},
  });

  @override
  State<KumaWaveBackground> createState() => _KumaWaveBackgroundState();
}

class _KumaWaveBackgroundState extends State<KumaWaveBackground>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _loop;
  late final AnimationController _mix;
  List<Color> _fromTrio = defaultWaveTrio;
  // Кроссфейд настроений как на ПК (fxPrev 750мс): старый эффект гаснет
  // поверх нового, смена жанра не щёлкает.
  WaveMood? _prevMood;
  late final AnimationController _fade;

  @override
  void initState() {
    super.initState();
    _fromTrio = widget.trio;
    // Один тикер ~60fps на всё (как rAF на ПК).
    _loop = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 60),
    );
    _mix = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
      value: 1,
    );
    // Непрозрачность уходящего слоя эффекта: 1 → 0 за 750мс.
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
      value: 0,
    );
    _fade.addStatusListener((s) {
      if (s == AnimationStatus.dismissed && mounted && _prevMood != null) {
        setState(() => _prevMood = null);
      }
    });
    if (widget.alive) _loop.repeat();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(KumaWaveBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Списки сравниваем ПО СОДЕРЖИМОМУ: hero пересоздаёт трио каждый
    // билд, identity-сравнение вечно перезапускало морфинг и цвета
    // залипали у старта, дрожание вместо перетекания.
    if (!listEquals(oldWidget.trio, widget.trio)) {
      _fromTrio = List<Color>.from(oldWidget.trio);
      _mix.value = 0;
      _mix.forward();
    }
    if (oldWidget.mood != widget.mood) {
      if (oldWidget.mood != WaveMood.none) {
        _prevMood = oldWidget.mood;
        _fade.value = 1;
        _fade.animateTo(0, curve: Curves.easeOut);
      } else {
        _prevMood = null;
        _fade.value = 0;
      }
    }
    if (oldWidget.alive != widget.alive) {
      if (widget.alive) {
        _loop.repeat();
      } else {
        _loop.stop();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _loop.stop();
    } else if (state == AppLifecycleState.resumed && widget.alive) {
      _loop.repeat();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loop.dispose();
    _mix.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mood =
        widget.enabledFx.contains(widget.mood) ? widget.mood : WaveMood.none;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: Listenable.merge([_loop, _mix, _fade]),
        builder: (_, __) {
          final t = _loop.value * 60.0; // секунды с запуска тикера
          final mix = _mix.value.clamp(0.0, 1.0);
          final trio = List<Color>.generate(
            3,
            (i) => Color.lerp(_fromTrio[i], widget.trio[i], mix)!,
          );
          final main = CustomPaint(
            painter: _WavePainter(
              t: t,
              trio: trio,
              dark: widget.dark,
              mood: mood,
              playing: widget.playing,
            ),
            size: Size.infinite,
          );
          final prev = _prevMood;
          // Уходящий эффект — отдельным слоем поверх, гаснет 750мс.
          // Двойная отрисовка только на время перехода.
          if (prev == null ||
              prev == WaveMood.none ||
              _fade.value <= 0.01) {
            return main;
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              main,
              Opacity(
                opacity: _fade.value.clamp(0.0, 1.0),
                child: CustomPaint(
                  painter: _WavePainter(
                    t: t,
                    trio: trio,
                    dark: widget.dark,
                    mood: prev,
                    playing: widget.playing,
                  ),
                  size: Size.infinite,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

double _hash(int i) {
  final x = math.sin(i * 12.9898) * 43758.5453;
  return x - x.floor();
}

class _WavePainter extends CustomPainter {
  final double t;
  final List<Color> trio;
  final bool dark;
  final WaveMood mood;
  final bool playing;

  _WavePainter({
    required this.t,
    required this.trio,
    required this.dark,
    required this.mood,
    required this.playing,
  });

  /// Базовая энергия (как readEnergy на ПК без анализатора).
  /// Реальный драйв — из WaveEnergyService (темп трека): painter опрашивает
  /// его каждый кадр, LFO тут больше нет.
  double get _energy => _sample.energy;
  double get _beat => _sample.beat;

  ({double energy, double beat}) get _sample {
    try {
      return WaveEnergyService().sample();
    } catch (_) {
      return (energy: 0.13, beat: 0.0);
    }
  }

  void _blob(
    Canvas canvas,
    Offset c,
    double r,
    Color color, {
    double alpha = 0.9,
  }) {
    // БЕЗ MaskFilter: блюр каждый кадр кладёт GPU среднего телефона
    // (факт 15.10.2026: лаги hero). Мягкий край даёт сам радиальный
    // градиент в прозрачность — визуально то же «облачко», бесплатно.
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          color.withValues(alpha: alpha),
          color.withValues(alpha: alpha * 0.55),
          color.withValues(alpha: 0),
        ],
        stops: const [0.0, 0.55, 0.85],
      ).createShader(Rect.fromCircle(center: c, radius: r))
      ..isAntiAlias = true;
    canvas.drawCircle(c, r, paint);
  }

  void _dot(Canvas canvas, double x, double y, double r, Color color,
      {double glow = 0}) {
    // Свечение — вторым полупрозрачным кругом, а не блюром.
    if (glow > 0) {
      final halo = Paint()
        ..color = color.withValues(alpha: color.a * 0.35)
        ..isAntiAlias = true;
      canvas.drawCircle(Offset(x, y), r + glow * 0.5, halo);
    }
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    canvas.drawCircle(Offset(x, y), r, paint);
  }

  // ---- настроения (порты drawEmbers/drawWarp/drawSparkle/...) ----

  /// Огненное кольцо ЗА шаром — порт FireRing с ПК: 9 языков пламени
  /// по кругу, рваный венец, flicker + энергия. Рисуется ДО капли,
  /// шар (blob) языки перекрывает. Мягкость — двойным проходом
  /// (широкий слабый ореол + узкое ядро): острых «треугольников» нет,
  /// а дорогого блюра/слоя на весь экран — тоже.
  void _fireRing(Canvas canvas, double w, double h, Color accent) {
    final cx = w / 2, cy = h / 2;
    final r = math.min(w * 0.24, 230);
    const n = 9;
    final rot = t * 0.1;
    final accentMid = accent.withValues(alpha: 0.6);
    final accentSoft = accent.withValues(alpha: 0.4);
    final core = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final halo = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    // Языки короче и глубже под шаром, чем в первой версии: наружу
    // выглядывают только кончики — как матовое стекло на ПК.
    final alpha = 0.28 + _energy * 0.3;
    for (var i = 0; i < n; i++) {
      final jit = _hash(i);
      final a = (i / n) * math.pi * 2 + rot + (jit - 0.5) * 0.22;
      final dx = math.cos(a), dy = math.sin(a);
      final px = -dy, py = dx;
      final flick =
          0.5 + 0.5 * math.sin(t * 6 + i * 2.7 + math.sin(t * 2.6 + i * 1.2) * 1.5);
      final baseR = r *
          (0.52 +
              0.12 * math.sin(2 * a + t * 0.5) +
              0.08 * math.sin(3 * a - t * 0.34 + 1.2));
      final len =
          r * (0.14 + 0.22 * flick + _energy * 0.45) * (0.5 + jit * 1.0);
      final tipU = baseR + len;
      final bend = math.sin(t * 4 + i * 2.1) * (4 + _energy * 10);
      final wH = (7 + _energy * 7 + flick * 4) * (0.8 + jit * 0.4);
      Offset p(double u, double v) =>
          Offset(cx + dx * u + px * v, cy + dy * u + py * v);
      final b0 = p(baseR, -wH);
      final b1 = p(baseR, wH);
      final c1 = p(baseR + len * 0.35, -wH * 1.15);
      final c2 = p(tipU - len * 0.3, -wH * 0.45 + bend);
      final t0 = p(tipU, bend - wH * 0.08);
      final tc = p(tipU + wH * 0.2, bend);
      final t1 = p(tipU, bend + wH * 0.08);
      final c3 = p(tipU - len * 0.3, wH * 0.45 + bend);
      final c4 = p(baseR + len * 0.35, wH * 1.15);
      final g0 = p(baseR, 0);
      final g1 = p(tipU, bend);
      final shader = LinearGradient(
        begin: Alignment(
            (g0.dx - cx) / r, (g0.dy - cy) / r),
        end: Alignment(
            (g1.dx - cx) / r, (g1.dy - cy) / r),
        colors: [
          accentMid.withValues(alpha: accentMid.a * alpha),
          accentSoft.withValues(alpha: accentSoft.a * alpha),
          const Color.fromRGBO(255, 120, 20, 0),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
      Path tongue(double spread) {
        final s = 1 + spread;
        // Масштабируем весь язык от центра капли: ореол шире и тусклее.
        // Безье строим вручную через масштабированные точки.
        final pp = Path()
          ..moveTo(
              cx + (b0.dx - cx) * s, cy + (b0.dy - cy) * s);
        pp.cubicTo(
            cx + (c1.dx - cx) * s, cy + (c1.dy - cy) * s,
            cx + (c2.dx - cx) * s, cy + (c2.dy - cy) * s,
            cx + (t0.dx - cx) * s, cy + (t0.dy - cy) * s);
        pp.quadraticBezierTo(
            cx + (tc.dx - cx) * s, cy + (tc.dy - cy) * s,
            cx + (t1.dx - cx) * s, cy + (t1.dy - cy) * s);
        pp.cubicTo(
            cx + (c3.dx - cx) * s, cy + (c3.dy - cy) * s,
            cx + (c4.dx - cx) * s, cy + (c4.dy - cy) * s,
            cx + (b1.dx - cx) * s, cy + (b1.dy - cy) * s);
        pp.close();
        return pp;
      }
      // Ореол: шире, вдвое тусклее — сглаживает кромку ядра.
      halo.shader = shader;
      halo.colorFilter = const ColorFilter.mode(
          Color.fromRGBO(255, 255, 255, 0.35), BlendMode.dstIn);
      canvas.drawPath(tongue(0.35), halo);
      halo.colorFilter = null;
      // Ядро.
      core.shader = shader;
      canvas.drawPath(tongue(0.0), core);
    }
  }

  void _fire(Canvas canvas, double w, double h, Color accent) {
    final cx = w / 2, cy = h / 2, r = math.min(w, h) * 0.24;
    for (var i = 0; i < 16; i++) {
      final s1 = _hash(i), s2 = _hash(i + 40);
      final prog = (t * (0.22 + s1 * 0.35) + s2) % 1;
      final x = cx +
          (s1 - 0.5) * r * 1.7 +
          math.sin(t * (1.5 + s2 * 2) + i * 1.9) * (6 + prog * 20);
      final y = cy + r * 0.55 - prog * r * 2.3;
      final tw = 0.4 + 0.6 * (math.sin(t * 5 + i * 2.3).abs());
      final a = (1 - prog) * (0.15 + _energy * 0.55) * tw;
      if (a <= 0.02) continue;
      final c = i % 3 == 2
          ? Color.fromRGBO(255, 214, 140, a)
          : i % 3 == 1
              ? accent.withValues(alpha: a)
              : Color.fromRGBO(255, 240, 220, a * 0.9);
      _dot(canvas, x, y, 1.2 + s2 * 2.4 * (1 - prog * 0.4), c, glow: 8);
    }
  }

  void _warp(Canvas canvas, double w, double h, Color accent) {
    final cx = w / 2, cy = h / 2;
    final maxR = math.sqrt((w / 2) * (w / 2) + (h / 2) * (h / 2));
    const n = 28;
    final rot = t * 0.07;
    // Как фон на ПК: тонкие полупрозрачные полосы с затуханием к концам,
    // а не сплошные штрихи. Градиент вдоль луча вместо блюра — дёшево.
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3
      ..isAntiAlias = true;
    for (var i = 0; i < n; i++) {
      final ang = (i / n) * math.pi * 2 + rot + math.sin(i * 12.9898) * 0.05;
      final off = (math.sin(i * 78.233) * 0.5 + 0.5);
      final prog =
          (t * (0.1 + _energy * 0.55) * (0.7 + off * 0.6) + off) % 1;
      final r0 = math.min(w, h) * 0.2 + prog * (maxR - math.min(w, h) * 0.2);
      final len = 18 + prog * 80 * (0.4 + _energy);
      final a = math.sin(prog * math.pi) * (0.10 + _energy * 0.28);
      if (a <= 0.01) continue;
      final p0 = Offset(cx + math.cos(ang) * r0, cy + math.sin(ang) * r0);
      final p1 = Offset(cx + math.cos(ang) * (r0 + len),
          cy + math.sin(ang) * (r0 + len));
      final base = i % 2 == 0
          ? const Color.fromRGBO(255, 255, 255, 1)
          : accent;
      paint.shader = LinearGradient(
        begin: Alignment(p0.dx / w * 2 - 1, p0.dy / h * 2 - 1),
        end: Alignment(p1.dx / w * 2 - 1, p1.dy / h * 2 - 1),
        colors: [
          base.withValues(alpha: 0),
          base.withValues(alpha: a),
          base.withValues(alpha: 0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromPoints(p0, p1));
      canvas.drawLine(p0, p1, paint);
    }
  }

  void _sparkle(Canvas canvas, double w, double h, Color accent) {
    for (var i = 0; i < 26; i++) {
      final s1 = _hash(i), s2 = _hash(i + 50);
      final prog = (t * (0.12 + s1 * 0.2) + s2) % 1;
      final x = w * s1 + math.sin(t * 0.8 + i) * 22;
      final y = h * (0.95 - prog * 0.75);
      final tw = 0.35 + 0.65 * (math.sin(t * 4 + i * 1.7).abs());
      final a = (1 - prog) * (0.2 + _energy * 0.6) * tw;
      if (a <= 0.02) continue;
      final c = i % 3 == 0
          ? Color.fromRGBO(255, 255, 255, a)
          : i % 3 == 1
              ? accent.withValues(alpha: a)
              : Color.fromRGBO(255, 214, 130, a * 0.9);
      _dot(canvas, x, y, 1 + s2 * 2.2, c, glow: 7);
    }
  }

  void _bounce(Canvas canvas, double w, double h, Color accent) {
    final cx = w / 2, cy = h / 2, r = math.min(w, h) * 0.24;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..isAntiAlias = true;
    for (var k = 0; k < 3; k++) {
      final age = (t * 0.45 + k / 3) % 1;
      paint.color = accent.withValues(alpha: (1 - age) * 0.45);
      canvas.drawCircle(Offset(cx, cy), r * (0.95 + age * 1.15), paint);
    }
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [
          accent.withValues(alpha: _energy * 0.3),
          accent.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r * 1.4));
    canvas.drawCircle(Offset(cx, cy), r * 1.4, glow);
  }

  void _smoke(Canvas canvas, double w, double h, Color accent) {
    for (var i = 0; i < 12; i++) {
      final s1 = _hash(i + 60), s2 = _hash(i + 95);
      final prog = (t * (0.09 + s1 * 0.1) + s2) % 1;
      final x = w * (0.2 + 0.6 * s1) + math.sin(t * 0.7 + i * 1.6) * 30;
      final y = h * 0.85 - prog * h * 0.7;
      final r = 26 + s2 * 44 + prog * 30;
      final a = math.sin(prog * math.pi) * (0.03 + _energy * 0.03);
      if (a <= 0.005) continue;
      _blob(canvas, Offset(x, y), r,
          i % 3 == 0 ? const Color(0xFFEBF0FF) : accent,
          alpha: a * 3);
    }
  }

  void _breath(Canvas canvas, double w, double h, Color accent) {
    final phase = (t % 8) / 8;
    final inhale = 0.5 - 0.5 * math.cos(phase * math.pi * 2);
    final a = 0.06 + inhale * 0.07 + _energy * 0.04;
    final cx = w / 2, cy = h / 2;
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [accent.withValues(alpha: a), accent.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(
          center: Offset(cx, cy), radius: math.min(w, h) * 1.05));
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), paint);
  }

  void _dust(Canvas canvas, double w, double h, Color accent) {
    for (var i = 0; i < 30; i++) {
      final s1 = _hash(i), s2 = _hash(i + 90);
      final x = (s1 * w + math.sin(t * 0.25 + i * 1.3) * 20 + w) % w;
      final y = (s2 * h + math.cos(t * 0.2 + i * 0.9) * 16 + h) % h;
      final tw = 0.4 + 0.6 * (math.sin(t * 1.2 + i * 2.4).abs());
      final a = (0.08 + 0.2 * tw) * (0.7 + _energy * 0.6);
      _dot(
          canvas,
          x,
          y,
          1 + s1 * 1.4,
          i % 4 == 0
              ? accent.withValues(alpha: a)
              : Color.fromRGBO(255, 255, 255, a),
          glow: 4);
    }
  }

  void _sun(Canvas canvas, double w, double h) {
    final cx = w / 2, cy = h / 2, r = math.min(w, h) * 0.24;
    for (var i = 0; i < 8; i++) {
      final ang = t * (0.22 + 0.06 * (i % 3)) + (i / 8) * math.pi * 2;
      final rad = r * (1.25 + 0.25 * math.sin(t * 0.6 + i * 1.4));
      final blink = 0.5 + 0.5 * math.sin(t * 2 + i * 2.6);
      final a = (0.35 + 0.4 * blink) * (0.6 + _energy * 0.6);
      _dot(canvas, cx + math.cos(ang) * rad,
          cy + math.sin(ang) * rad * 0.8, 2.5 + (i % 3),
          Color.fromRGBO(255, 196, 110, a),
          glow: 14);
    }
  }

  void _fireflies(Canvas canvas, double w, double h) {
    final cx = w / 2, cy = h / 2;
    final rx = w * 0.32, ry = h * 0.3;
    for (var i = 0; i < 10; i++) {
      final x = cx +
          math.sin(t * 0.3 * (0.7 + _hash(i) * 0.6) + i * 2.4) * rx;
      final y = cy +
          math.cos(t * 0.23 * (0.7 + _hash(i + 20) * 0.6) + i * 1.7) * ry;
      final gate = 0.5 + 0.5 * math.sin(t * 1.4 + i * 2.2);
      final a = gate * gate * gate * (0.4 + _energy * 0.4);
      if (a <= 0.03) continue;
      _dot(canvas, x, y, 1.6 + _hash(i + 40) * 1.4,
          Color.fromRGBO(230, 255, 234, a),
          glow: 10);
    }
  }

  void _mist(Canvas canvas, double w, double h, Color accent) {
    // Без shadowBlur: толстые полупрозрачные штрихи и так мягкие.
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    for (var k = 0; k < 5; k++) {
      final dir = k % 2 == 0 ? 1 : -1;
      final yBase = h * (0.55 + 0.075 * k) +
          math.sin(t * (0.45 + k * 0.12) + k * 1.8) * 13;
      final breathe = 0.55 + 0.45 * math.sin(t * 0.65 + k * 1.3);
      final path = Path();
      for (var x = -60.0; x <= w + 60; x += 20) {
        final y = yBase +
            math.sin((x * dir + math.sin(t * 0.3 * dir + k * 2.2) * 150) *
                        0.012 +
                    t * (0.55 + k * 0.11) +
                    k * 1.1) *
                (7 + k * 2.2);
        if (x == -60) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      final a = (0.03 + _energy * 0.02) * breathe + 0.012;
      paint.color = k % 2 == 0
          ? Color.fromRGBO(220, 228, 245, a)
          : accent.withValues(alpha: a);
      paint.strokeWidth = 12 + (k % 3) * 7;
      canvas.drawPath(path, paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    if (w <= 0 || h <= 0) return;
    final cx = w / 2, cy = h / 2;
    final r = math.min(w * 0.24, 230);
    final c1 = trio[0], c2 = trio[1], c3 = trio[2];

    // Ореол сзади в цвете трека.
    _blob(canvas, Offset(cx, cy), math.min(w, h) * 0.42,
        (dark ? c2 : c1),
        alpha: dark ? 0.5 : 0.35);

    // Огненное кольцо ЗА каплей (только fire): языки по кругу,
    // blob-капля их перекроет — как слои FxLayer на ПК.
    if (mood == WaveMood.fire) _fireRing(canvas, w, h, c2);

    // Капля: два кластера в противофазе, морфинг translate/scale/rotate.
    // Блюр сливает круги в liquid-пятно как SVG-фильтр kw-liquid на ПК.
    final k = playing ? 0.7 : 1.0;
    final g1x = cx + math.sin(t * 2 * math.pi / (7 * k)) * w * 0.07;
    final g1y = cy - math.cos(t * 2 * math.pi / (7 * k)) * h * 0.06;
    final g2x = cx - math.sin(t * 2 * math.pi / (7 * k)) * w * 0.07;
    final g2y = cy + math.cos(t * 2 * math.pi / (7 * k)) * h * 0.06;

    final s1 = 1 + 0.15 * math.sin(t * 2 * math.pi / (8 * k));
    final s2 = 1 + 0.18 * math.sin(t * 2 * math.pi / (11 * k) + 1.3);
    final s3 = 1 + 0.16 * math.sin(t * 2 * math.pi / (13 * k) + 2.6);
    // Дыхание в такт: вся капля пружинит на кике (как bounce-wrap на ПК).
    final breathe = 1 + _beat * 0.07;

    _blob(canvas, Offset(g1x - r * 0.35, g1y - r * 0.3), r * 0.62 * s1 * breathe, c1);
    _blob(canvas, Offset(g1x + r * 0.45, g1y + r * 0.1), r * 0.72 * s2 * breathe, c2);
    _blob(canvas, Offset(g2x, g2y + r * 0.4), r * 0.66 * s3 * breathe, c3);

    // Настроение жанра поверх капли.
    switch (mood) {
      case WaveMood.fire:
        _fire(canvas, w, h, c2);
        break;
      case WaveMood.warp:
        _warp(canvas, w, h, c2);
        break;
      case WaveMood.sparkle:
        _sparkle(canvas, w, h, c2);
        break;
      case WaveMood.bounce:
        _bounce(canvas, w, h, c2);
        break;
      case WaveMood.smoke:
        _smoke(canvas, w, h, c2);
        break;
      case WaveMood.breath:
        _breath(canvas, w, h, c2);
        break;
      case WaveMood.dust:
        _dust(canvas, w, h, c2);
        break;
      case WaveMood.sun:
        _sun(canvas, w, h);
        break;
      case WaveMood.fireflies:
        _fireflies(canvas, w, h);
        break;
      case WaveMood.mist:
        _mist(canvas, w, h, c2);
        break;
      case WaveMood.none:
        break;
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.t != t ||
      !listEquals(old.trio, trio) ||
      old.mood != mood ||
      old.playing != playing ||
      old.dark != dark;
}
