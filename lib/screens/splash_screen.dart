import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/theme_service.dart';

/// Splash screen как на десктопе: иконка с пульсирующими кольцами и
/// вращающейся дугой, пятна на фоне, стадии загрузки с прогресс-баром.
/// Стадии косметические (как на десктопе, ~2.4с) — реальная инициализация
/// идёт в main, сплэш заменяется экраном когда она завершена.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _intro;
  late AnimationController _loop;
  late Animation<double> _fade;
  late Animation<double> _scale;
  Timer? _stageTimer;
  int _stage = 0;
  String _version = '';

  // Те же стадии, что на десктопе (splash-screen.tsx).
  static const List<(double, String)> _stages = [
    (0.10, 'Загрузка конфигурации...'),
    (0.30, 'Проверка подключения к серверу...'),
    (0.50, 'Загрузка данных...'),
    (0.70, 'Инициализация ML профиля...'),
    (0.85, 'Подготовка плеера...'),
    (1.00, 'Готово!'),
  ];

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800));
    _fade = CurvedAnimation(parent: _intro, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.92, end: 1.0).animate(
        CurvedAnimation(parent: _intro, curve: Curves.easeOutBack));
    _intro.forward();
    // Пинг-кольца: 2.4с цикл как на десктопе.
    // Вращения колец на десктопе нет визуально (полные uniform-кольца) —
    // спин-контроллеры не нужны, кольца статичны как в оригинале.
    _loop = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2400))
      ..repeat();
    _stageTimer =
        Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (!mounted) return;
      if (_stage < _stages.length - 1) {
        setState(() => _stage++);
      }
    });
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _version =
            'v${info.version}+${info.buildNumber}');
      }
    } catch (_) {
      if (mounted) setState(() => _version = '');
    }
  }

  @override
  void dispose() {
    _stageTimer?.cancel();
    _intro.dispose();
    _loop.dispose();
    super.dispose();
  }

  double _ringProgress(double offset) {
    // Два кольца со сдвигом в полцикла, как ping-slow-delayed на десктопе.
    final t = (_loop.value + offset) % 1.0;
    return t;
  }
  @override
  Widget build(BuildContext context) {
    final accent =
        context.select<ThemeService, Color>((t) => t.accentColor.color);
    final progress = _stages[_stage].$1;
    final status = _stages[_stage].$2;
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              accent.withValues(alpha: 0.85),
              accent.withValues(alpha: 0.55),
              accent.withValues(alpha: 0.25),
              Colors.black,
            ],
            stops: const [0.0, 0.35, 0.65, 1.0],
          ),
        ),
        child: Stack(
          children: [
            // Пятна 1-в-1 с десктопом: w-80 (320) по углам + w-96 (384)
            // по центру, blur-3xl, animate-pulse. Фон-градиент — динамический.
            AnimatedBuilder(
              animation: _loop,
              builder: (_, __) {
                final pulse = 0.5 + 0.5 * math.sin(_loop.value * 2 * math.pi);
                return Stack(
                  children: [
                    Positioned(
                      top: -160 + 12 * pulse,
                      right: -160,
                      child: Container(
                        width: 320,
                        height: 320,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF10B981)
                              .withValues(alpha: 0.20),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF10B981)
                                  .withValues(alpha: 0.20),
                              blurRadius: 80,
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: -160,
                      left: -160 - 10 * pulse,
                      child: Container(
                        width: 320,
                        height: 320,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF3B82F6)
                              .withValues(alpha: 0.20),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF3B82F6)
                                  .withValues(alpha: 0.20),
                              blurRadius: 80,
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      top: MediaQuery.sizeOf(context).height * 0.5 - 192,
                      left: MediaQuery.sizeOf(context).width * 0.5 - 192,
                      child: Container(
                        width: 384,
                        height: 384,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFFA855F7)
                              .withValues(alpha: 0.10),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFA855F7)
                                  .withValues(alpha: 0.10),
                              blurRadius: 80,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
            Positioned.fill(
              child: FadeTransition(
                opacity: _fade,
                child: ScaleTransition(
                  scale: _scale,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Логотип 1-в-1 с десктопом (w-32 h-32 = 128):
                    // 2 пинг-кольца inset-0 border-2 (второе delay 1.2с),
                    // внешнее кольцо inset-0 border-4, среднее inset-2 border-4,
                    // внутренний круг inset-4 (96) с градиентом + animate-pulse,
                    // иконка 56 (w-14) rounded-2xl по центру.
                    SizedBox(
                      width: 128,
                      height: 128,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          for (var i = 0; i < 2; i++)
                            AnimatedBuilder(
                              animation: _loop,
                              builder: (_, __) {
                                final p = _ringProgress(i * 0.5);
                                return Container(
                                  width: 128 + 57.6 * p,
                                  height: 128 + 57.6 * p,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: (i == 0
                                              ? const Color(0xFF34D399)
                                              : const Color(0xFF60A5FA))
                                          .withValues(alpha: 0.7 * (1 - p)),
                                      width: 2,
                                    ),
                                  ),
                                );
                              },
                            ),
                          // Внешнее кольцо: inset-0, border-4 emerald-500/30.
                          Container(
                            width: 128,
                            height: 128,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0xFF10B981)
                                    .withValues(alpha: 0.30),
                                width: 4,
                              ),
                            ),
                          ),
                          // Среднее кольцо: inset-2 (112), border-4 blue-500/40.
                          Container(
                            width: 112,
                            height: 112,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0xFF3B82F6)
                                    .withValues(alpha: 0.40),
                                width: 4,
                              ),
                            ),
                          ),
                          // Внутренний круг: inset-4 (96), градиент
                          // emerald-500→blue-500 + animate-pulse (opacity).
                          AnimatedBuilder(
                            animation: _loop,
                            builder: (_, __) {
                              final o = 0.75 +
                                  0.25 *
                                      math.sin(
                                          _loop.value * 2 * math.pi);
                              return Opacity(
                                opacity: o.clamp(0.5, 1.0),
                                child: Container(
                                  width: 96,
                                  height: 96,
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        Color(0xFF10B981),
                                        Color(0xFF3B82F6),
                                      ],
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                          color: Colors.black26,
                                          blurRadius: 12,
                                          offset: Offset(0, 6)),
                                    ],
                                  ),
                                  alignment: Alignment.center,
                                  child: ClipRRect(
                                    borderRadius:
                                        BorderRadius.circular(14),
                                    child: Image.asset(
                                      'assets/app_icon.png',
                                      width: 56,
                                      height: 56,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) =>
                                          const Icon(
                                              Icons.music_note_rounded,
                                              size: 48,
                                              color: Colors.white),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                    const Text(
                      'KumaFlow',
                      style: TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Музыкальный плеер с ML рекомендациями',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF6EE7B7)
                            .withValues(alpha: 0.8),
                      ),
                    ),
                    const SizedBox(height: 32),
                    // Прогресс-бар 1-в-1 с десктопом:
                    // emerald-400 -> blue-400 -> purple-400, glow 20.
                    LayoutBuilder(
                      builder: (_, constraints) {
                        final maxW =
                            math.min(256.0, constraints.maxWidth - 64);
                        return SizedBox(
                          width: maxW,
                          height: 6,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: Container(
                              color: Colors.white.withValues(alpha: 0.10),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: AnimatedContainer(
                                  duration:
                                      const Duration(milliseconds: 500),
                                  curve: Curves.easeOut,
                                  width: maxW * progress,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(3),
                                    gradient: const LinearGradient(
                                      colors: [
                                        Color(0xFF34D399),
                                        Color(0xFF60A5FA),
                                        Color(0xFFA78BFA),
                                      ],
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF10B981)
                                            .withValues(alpha: 0.5),
                                        blurRadius: 20,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    Text(
                      status.toUpperCase(),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 1.2,
                        color: Colors.white.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _version.isEmpty ? '' : 'Версия $_version',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.35),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            ),
          ],
        ),
      ),
    );
  }
}
