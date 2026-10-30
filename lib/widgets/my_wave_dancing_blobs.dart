import 'dart:math';
import 'package:flutter/material.dart';

/// Isolated dancing blobs for "Моя волна" hero.
/// Wrapped in RepaintBoundary so animation repaints only this subtree,
/// never triggers rebuild of player or list below (Yandex-like isolation).
///
/// Пульс «в такт» без микрофона (работает и в наушниках):
/// фаза бита считается от wall-clock и BPM трека — смены BPM/isPlaying
/// не рвут фазу, скачков нет. Плавный разгон/затухание — через _ramp:
/// появление и play разгоняют амплитуду 0.06→1 (~1с), пауза гасит до 0.06
/// и фризит дрейф (как ПК: «почти не двигается», 0 затрат в покое).
/// Вне экрана (скролл) и в фоне тикеры стопаются полностью.
class MyWaveDancingBlobs extends StatefulWidget {
  final List<Color> genreColors;
  /// BPM текущего трека (60..200, фолбек 120).
  final double bpm;
  /// 0..1 — глубина пульса.
  final double energy;
  /// 0..1 — лёгкое расширение пульса.
  final double danceability;
  /// false = плавное затухание + freeze (как пауза на ПК).
  final bool isPlaying;

  const MyWaveDancingBlobs({
    super.key,
    required this.genreColors,
    this.bpm = 120,
    this.energy = 0.5,
    this.danceability = 0.5,
    this.isPlaying = true,
  });

  @override
  State<MyWaveDancingBlobs> createState() => _MyWaveDancingBlobsState();
}

class _MyWaveDancingBlobsState extends State<MyWaveDancingBlobs>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _slow;
  late AnimationController _fast;
  // Плавная огибающая амплитуды: появление/play 0.06→1, пауза/хайд →0.06.
  late AnimationController _ramp;
  // Cache colors to avoid rebuild
  List<Color> _colors = const [];
  bool _visible = true;
  bool _appActive = true;
  bool _wantDrift = true;

  static const double _kRestAmp = 0.06;

  @override
  void initState() {
    super.initState();
    _colors = widget.genreColors.length >= 2
        ? widget.genreColors
        : [const Color(0xFF7C3AED), const Color(0xFF06B6D4), const Color(0xFFF59E0B)];
    // Slow 8s loop for large blobs, fast 6s for medium
    _slow = AnimationController(vsync: this, duration: const Duration(milliseconds: 8200))..repeat();
    _fast = AnimationController(vsync: this, duration: const Duration(milliseconds: 6100))..repeat();
    // Стартуем «тихо» и разгоняемся — без резкого рывка при появлении hero.
    _ramp = AnimationController(
      vsync: this,
      lowerBound: _kRestAmp,
      upperBound: 1.0,
      value: _kRestAmp,
      duration: const Duration(milliseconds: 900),
    );
    _ramp.addListener(_onRampTick);
    WidgetsBinding.instance.addObserver(this);
    _wantDrift = widget.isPlaying;
    if (!_wantDrift) {
      // Пауза с первого кадра: тикеры остановит _onRampTick (уже на дне).
      _slow.stop();
      _fast.stop();
    } else {
      // ignore: discarded_futures
      _ramp.animateTo(1.0, curve: Curves.easeOut);
    }
  }

  @override
  void didUpdateWidget(covariant MyWaveDancingBlobs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.genreColors != widget.genreColors) {
      _colors = widget.genreColors.length >= 2
          ? widget.genreColors
          : [const Color(0xFF7C3AED), const Color(0xFF06B6D4), const Color(0xFFF59E0B)];
    }
    if (oldWidget.isPlaying != widget.isPlaying) _applyTargets();
    // bpm/energy применяются сами (фаза от часов — разрывов нет).
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (active != _appActive) {
      _appActive = active;
      _applyTargets();
    }
  }

  void _applyTargets() {
    if (!_visible || !_appActive) {
      // Вне экрана / фон: тихо гаснем, дрейф встанет по _onRampTick.
      _wantDrift = false;
      // ignore: discarded_futures
      _ramp.animateTo(_kRestAmp,
          duration: const Duration(milliseconds: 450), curve: Curves.easeIn);
      return;
    }
    if (widget.isPlaying) {
      // Плавный разгон как просил: дрейф с места (фаза могла сброситься,
      // но амплитуда ещё ~0.06 — рывка не видно), огибающая 0.06→1.
      if (!_slow.isAnimating) _slow.repeat();
      if (!_fast.isAnimating) _fast.repeat();
      _wantDrift = true;
      // ignore: discarded_futures
      _ramp.animateTo(1.0,
          duration: const Duration(milliseconds: 1000), curve: Curves.easeOut);
    } else {
      // Пауза как на ПК: затухание ~0.7с, потом freeze (0 затрат).
      _wantDrift = false;
      // ignore: discarded_futures
      _ramp.animateTo(_kRestAmp,
          duration: const Duration(milliseconds: 700), curve: Curves.easeInOut);
    }
  }

  void _onRampTick() {
    // Огибающая села на дно и дрейф не нужен — стопаем тикеры (статика).
    if (!_ramp.isAnimating &&
        _ramp.value <= _kRestAmp + 0.001 &&
        !_wantDrift) {
      if (_slow.isAnimating) _slow.stop();
      if (_fast.isAnimating) _fast.stop();
    }
  }

  bool _onScroll(ScrollNotification n) {
    try {
      final obj = context.findRenderObject();
      if (obj is RenderBox && obj.attached && obj.hasSize) {
        final dy = obj.localToGlobal(Offset.zero).dy;
        final h = MediaQuery.of(context).size.height;
        final vis = dy < h && dy + obj.size.height > -80;
        if (vis != _visible) {
          _visible = vis;
          _applyTargets();
        }
      }
    } catch (_) {}
    return false; // не глушим скролл выше
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ramp.removeListener(_onRampTick);
    _slow.dispose();
    _fast.dispose();
    _ramp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary isolates raster cache — nothing outside repaints
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([_slow, _fast, _ramp]),
          builder: (ctx, _) {
            final bpm = widget.bpm.clamp(60.0, 200.0);
            final energy = widget.energy.clamp(0.0, 1.0);
            final dance = widget.danceability.clamp(0.0, 1.0);
            // Фаза от часов: смена BPM не рвёт пульс, пауза/стоп не сдвигают сетку.
            final t = DateTime.now().millisecondsSinceEpoch / 1000.0;
            final phase = (t * bpm / 60.0) % 1.0;
            final s = sin(pi * phase);
            final beat = s * s; // 0..1, один мягкий «кик» на бит
            final amp = _ramp.value;
            // Глубина пульса от энергии: 5%..14% радиуса.
            final depth = (0.05 + 0.09 * energy) * (0.75 + 0.25 * dance);
            // Дрейф тоже дышит через огибающую (на паузе сжимается к ~четверти).
            final drift = 0.2 + 0.8 * amp;
            return CustomPaint(
              painter: _BlobsPainter(
                slowT: _slow.value,
                fastT: _fast.value,
                beat: beat * amp,
                depth: depth,
                drift: drift,
                colors: _colors,
              ),
              size: Size.infinite,
            );
          },
        ),
      ),
    );
  }
}

class _BlobsPainter extends CustomPainter {
  final double slowT;
  final double fastT;
  final double beat;
  final double depth;
  final double drift;
  final List<Color> colors;

  _BlobsPainter({
    required this.slowT,
    required this.fastT,
    required this.beat,
    required this.depth,
    required this.drift,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    // Base — тёмная подложка как на картинке Яндекс (глубокий фиолетовый/синий)
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF0D0A1A));

    void drawBlob(Offset center, double radius, Color color, double alpha, double blur) {
      final paint = Paint()
        ..color = color.withValues(alpha: alpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
      canvas.drawCircle(center, radius, paint);
    }

    // Яркие цвета как на скрине: жёлтый центр + фиолетовый/синий края
    final cCenter = const Color(0xFFFFD600); // ярко-жёлтый
    final cPurple = const Color(0xFF7B2FF7);
    final cBlue = const Color(0xFF2F6BFF);
    final cPink = const Color(0xFFFF2E93);
    // Смешиваем жанровые цвета с яркими для узнаваемости
    final g0 = colors[0];
    final g1 = colors.length > 1 ? colors[1] : cBlue;

    // Большой жёлтый центр — самый заметный (как на картинке).
    // Пульс в такт BPM: радиус и плотность дышат на кике.
    final pulse = 1.0 + depth * beat;
    final cx = w * (0.52 + 0.08 * drift * sin(slowT * 2 * pi));
    final cy = h * (0.50 + 0.07 * drift * cos(fastT * 2 * pi));
    drawBlob(Offset(cx, cy), w * 0.62 * pulse, cCenter, (0.95 - 0.12 * beat).clamp(0.0, 1.0), 32);

    // Оранжевый ореол вокруг жёлтого
    drawBlob(Offset(cx + w * 0.04, cy - h * 0.02), w * 0.45 * pulse, const Color(0xFFFF8A00), 0.55, 36);

    // Фиолетовый левый край
    final p1x = w * (0.12 + 0.10 * drift * sin(slowT * 2 * pi + 0.5));
    final p1y = h * (0.35 + 0.12 * drift * cos(slowT * 2 * pi));
    drawBlob(Offset(p1x, p1y), w * 0.48, cPurple, 0.78, 38);

    // Синий правый низ
    final p2x = w * (0.88 + 0.08 * drift * sin(fastT * 2 * pi + 1.2));
    final p2y = h * (0.72 + 0.10 * drift * cos(fastT * 2 * pi * 0.8));
    drawBlob(Offset(p2x, p2y), w * 0.44, cBlue, 0.75, 36);

    // Розовый верхний
    final p3x = w * (0.78 + 0.06 * drift * sin((slowT + fastT) * pi));
    final p3y = h * (0.14 + 0.08 * drift * cos(slowT * 2 * pi * 1.1));
    drawBlob(Offset(p3x, p3y), w * 0.32, cPink, 0.60, 30);

    // Жанровый акцент — небольшой, чтобы Моя волна подстраивалась под вкус
    drawBlob(Offset(w * 0.22 + w * 0.05 * drift * cos(fastT * 2 * pi), h * 0.82 + h * 0.04 * drift * sin(slowT * 2 * pi)), w * 0.18, g0, 0.45, 22);
    drawBlob(Offset(w * 0.75 + w * 0.04 * drift * sin(slowT * 2 * pi), h * 0.22), w * 0.14, g1, 0.35, 20);
  }

  @override
  bool shouldRepaint(covariant _BlobsPainter oldDelegate) =>
      oldDelegate.slowT != slowT ||
      oldDelegate.fastT != fastT ||
      oldDelegate.beat != beat ||
      oldDelegate.depth != depth ||
      oldDelegate.drift != drift ||
      oldDelegate.colors != colors;
}
