import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'wave/wave_mood.dart';

/// V3 «Моя волна» — порт десктопного WebGL-движка vibe (domain warping +
/// fbm-шум + лучи + неон) под Flutter FragmentShader.
///
/// Источник: `C:\kumaflow-pc-new\src\features\wave\vibe-worker.js` (rev 27),
/// настройки — `vibe-wave-background.tsx`: палитра крутится под акцент
/// обложки/жанра, лайк греет оттенок, дизлайк холодит, огонь — только
/// жёстким жанрам. Звука-анализатора как в браузере нет: пульс считается
/// от BPM трека (как в танцующих блобах), энергия — из кеша фич.
///
/// Для слабых телефонов есть V1/V2 (Canvas) — V3 включается в настройках
/// оформления. При ошибке компиляции шейдера рисуется [fallback].
class VibeWaveBackground extends StatefulWidget {
  /// Акцент — доминанта обложки (как WaveTrio[0] на ПК) или жанровый цвет.
  final Color? accent;

  /// Жанр текущего трека — выбирает пресет bend/rays/neon.
  final String? genre;

  /// 0..1 — энергия трека (AudioFeaturesCache).
  final double energy;

  /// BPM текущего трека (60..200).
  final double bpm;

  /// false = медленный дрейф и спад энергии (как пауза на ПК),
  /// тикер стоит только вне экрана / в фоне.
  final bool isPlaying;

  /// Тёмная карточка или светлая.
  final bool dark;

  /// Реакция на оценку: true/false/null (нет оценки).
  final bool? like;

  /// Скорость течения (на ПК ховер даёт 1.4).
  final double speed;

  /// Что показать, если шейдер не скомпилировался.
  final Widget? fallback;

  const VibeWaveBackground({
    super.key,
    this.accent,
    this.genre,
    this.energy = 0.5,
    this.bpm = 120,
    this.isPlaying = true,
    this.dark = true,
    this.like,
    this.speed = 1.0,
    this.fallback,
  });

  @override
  State<VibeWaveBackground> createState() => _VibeWaveBackgroundState();
}

/// Пресеты формы шейдера по настроению жанра — 1в1 VIBE_MOOD_SHAPE с ПК.
({double bend, double rays, double neonMul, double softness})
    _vibeShapeForMood(WaveMood mood) {
  switch (mood) {
    case WaveMood.fire:
      return (bend: 0.9, rays: 0.32, neonMul: 1.1, softness: 0.74);
    case WaveMood.warp:
      return (bend: 1.0, rays: 0.34, neonMul: 1.25, softness: 0.75);
    case WaveMood.bounce:
      return (bend: 0.85, rays: 0.32, neonMul: 1.1, softness: 0.8);
    case WaveMood.sparkle:
    case WaveMood.sun:
      return (bend: 0.9, rays: 0.3, neonMul: 1.1, softness: 0.85);
    case WaveMood.smoke:
    case WaveMood.breath:
    case WaveMood.dust:
    case WaveMood.mist:
    case WaveMood.fireflies:
      return (bend: 0.9, rays: 0.2, neonMul: 0.85, softness: 0.9);
    case WaveMood.none:
      return (bend: 1.0, rays: 0.4, neonMul: 1.0, softness: 0.88);
  }
}

/// Оттенок hex в градусы. Серый/мусор — null (палитра не крутится).
double? _hexToHueDeg(Color? c) {
  if (c == null) return null;
  final r = c.r;
  final g = c.g;
  final b = c.b;
  final maxV = r > g ? (r > b ? r : b) : (g > b ? g : b);
  final minV = r < g ? (r < b ? r : b) : (g < b ? g : b);
  final d = maxV - minV;
  if (d < 0.06) return null;
  double h;
  if (maxV == r) {
    h = ((g - b) / d + (g < b ? 6 : 0)) * 60;
  } else if (maxV == g) {
    h = ((b - r) / d + 2) * 60;
  } else {
    h = ((r - g) / d + 4) * 60;
  }
  return h;
}

double _wrap01(double v) => ((v % 1) + 1) % 1;

bool _isDarkCover(Color? c) {
  if (c == null) return false;
  final lum = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
  return lum < 0.16;
}

class _VibeWaveBackgroundState extends State<VibeWaveBackground>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static ui.FragmentProgram? _program;
  static bool _failed = false;

  Ticker? _ticker;
  final ValueNotifier<int> _frame = ValueNotifier(0);
  double _time = 0;
  double _energyShown = 0.5;
  Duration? _lastTick;
  bool _visible = true;
  bool _appActive = true;

  bool get _ready => _program != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _energyShown = widget.energy.clamp(0.0, 1.0);
    _load();
    _applyTicker();
  }

  Future<void> _load() async {
    if (_program != null || _failed) {
      if (mounted) setState(() {});
      return;
    }
    try {
      _program = await ui.FragmentProgram.fromAsset('shaders/vibe_wave.frag');
    } catch (e) {
      debugPrint('[Vibe] shader load failed: $e');
      _failed = true;
    }
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant VibeWaveBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) _applyTicker();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (active != _appActive) {
      _appActive = active;
      _applyTicker();
    }
  }

  void _applyTicker() {
    // Как движок на ПК: узел висит подключённым и на паузе — тикер идёт
    // всегда, пока карточка видна: на паузе время течёт медленно (0.12x),
    // энергия спадает к покою. Полный стоп — только вне экрана / в фоне.
    final want = _visible && _appActive;
    if (want && _ticker == null) {
      _ticker = createTicker(_onTick)..start();
    } else if (!want) {
      _lastTick = null;
      _ticker?.stop();
      _ticker?.dispose();
      _ticker = null;
    }
  }

  void _onTick(Duration elapsed) {
    // Цель ~30fps как targetFps движка на ПК.
    final last = _lastTick;
    _lastTick = elapsed;
    if (last == null) return;
    final dt = (elapsed - last).inMicroseconds / 1e6;
    if (dt < 0.033) return;
    final speed = widget.isPlaying ? widget.speed : widget.speed * 0.12;
    _time += dt.clamp(0.0, 0.05) * speed;
    final target = widget.isPlaying ? widget.energy.clamp(0.0, 1.0) : 0.13;
    _energyShown += (target - _energyShown) * (dt * 3).clamp(0.0, 1.0);
    _frame.value++;
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
          _applyTicker();
        }
      }
    } catch (_) {}
    return false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return widget.fallback ?? const SizedBox.expand();
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _frame,
          builder: (ctx, _) {
            return CustomPaint(
              painter: _VibePainter(
                program: _program!,
                fragTime: _time,
                accent: widget.accent,
                genre: widget.genre,
                energy: _energyShown.clamp(0.0, 1.0),
                bpm: widget.bpm.clamp(60.0, 200.0),
                playing: widget.isPlaying,
                dark: widget.dark,
                like: widget.like,
              ),
              size: Size.infinite,
            );
          },
        ),
      ),
    );
  }
}

class _VibePainter extends CustomPainter {
  final ui.FragmentProgram program;
  final double fragTime;
  final Color? accent;
  final String? genre;
  final double energy;
  final double bpm;
  final bool playing;
  final bool dark;
  final bool? like;

  _VibePainter({
    required this.program,
    required this.fragTime,
    required this.accent,
    required this.genre,
    required this.energy,
    required this.bpm,
    required this.playing,
    required this.dark,
    required this.like,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final shader = program.fragmentShader();

    // --- палитра: акцент + лайк/дизлайк + тёмная обложка (1в1 с ПК) ---
    const paletteHue = 0.895;
    const baseNeon = 0.85;
    double hueOffset = 0;
    final deg = _hexToHueDeg(accent);
    if (deg != null) hueOffset = _wrap01(deg / 360 - paletteHue);
    final darkCover = _isDarkCover(accent);
    double hueShift = 0;
    double neonMul = 1;
    double intMul = 1;
    double scaleMul = 1;
    if (like == true) {
      hueShift = 0.055;
      neonMul = 1.12;
      intMul = 1.1;
      scaleMul = 1.03;
    } else if (like == false) {
      hueShift = -0.105;
      neonMul = 0.7;
      intMul = 0.7;
      scaleMul = 0.93;
    }

    final mood = waveMoodForGenre(genre);
    final shape = _vibeShapeForMood(mood);

    // --- пульс от BPM по wall-clock (как в танцующих блобах) ---
    double beat = 0;
    if (playing) {
      final t = DateTime.now().millisecondsSinceEpoch / 1000.0;
      final phase = (t * bpm / 60.0) % 1.0;
      final s = math.sin(math.pi * phase);
      beat = (s * s).clamp(0.0, 1.0) * (0.35 + 0.65 * energy);
    }

    final bg = dark ? const Color(0xFF141A26) : const Color(0xFFF0F0F5);

    int i = 0;
    shader.setFloat(i++, size.width);
    shader.setFloat(i++, size.height);
    shader.setFloat(i++, fragTime);
    shader.setFloat(i++, _wrap01(hueOffset + hueShift));
    shader.setFloat(i++, bg.r);
    shader.setFloat(i++, bg.g);
    shader.setFloat(i++, bg.b);
    shader.setFloat(
        i++, (dark ? 0.9 : 1.0) * intMul * (darkCover ? 0.55 : 1.0));
    shader.setFloat(i++, shape.softness);
    shader.setFloat(i++, scaleMul);
    shader.setFloat(i++, shape.rays);
    shader.setFloat(i++,
        baseNeon * shape.neonMul * neonMul * (darkCover ? 0.6 : 1.0));
    shader.setFloat(i++, shape.bend);
    shader.setFloat(i++, energy);
    shader.setFloat(i++, beat);
    shader.setFloat(i++, 0.0); // uScream — источника скрима нет
    shader.setFloat(i++, mood == WaveMood.fire ? 0.85 : 0.0);

    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _VibePainter old) => false;
}
