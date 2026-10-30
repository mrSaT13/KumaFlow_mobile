import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/theme_service.dart';

/// Глобальный градиент как на главной — используется на всех страницах.
/// Цвета берутся из выбранного accentColor, прозрачность зависит от темы.
/// Повторяет stops HomeScreen: [0.0, 0.15, 0.35, 0.6, 1.0]
class AppGradientBackground extends StatelessWidget {
  final Widget child;

  /// Если true — градиент тянется на всю высоту, иначе только сверху (~60%)
  final bool fullHeight;

  const AppGradientBackground({
    super.key,
    required this.child,
    this.fullHeight = true,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accentColor =
        context.select<ThemeService, Color>((t) => t.accentColor.color);
    final intensity =
        context.select<ThemeService, double>((t) => t.gradientIntensity);
    final base = isDark ? const Color(0xFF000000) : const Color(0xFFF2F2F7);

    // intensity 0 → прозрачный градиент (однотон), 1 → полная как на главной
    double a(double v) => (v * intensity).clamp(0.0, 1.0);

    return Stack(
      children: [
        // Базовый однотон как на остальных страницах раньше — чтобы низ списка не был прозрачным
        Positioned.fill(child: ColoredBox(color: base)),
        // Градиент как на главной сверху
        if (intensity > 0.01)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    accentColor.withValues(alpha: a(0.50)),
                    accentColor.withValues(alpha: a(0.30)),
                    accentColor.withValues(alpha: a(0.15)),
                    accentColor.withValues(alpha: a(0.05)),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.15, 0.35, 0.6, 1.0],
                ),
              ),
            ),
          ),
        child,
      ],
    );
  }
}

/// Полупрозрачный AppBar/SliverAppBar с блюром и градиентом — как на Home.
/// Используй в SliverAppBar.flexibleSpace или AppBar.flexibleSpace
class AppGradientAppBarBackground extends StatelessWidget {
  final Widget child;
  const AppGradientAppBarBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accentColor =
        context.select<ThemeService, Color>((t) => t.accentColor.color);
    final intensity =
        context.select<ThemeService, double>((t) => t.gradientIntensity);
    double a(double v) => (v * intensity).clamp(0.0, 1.0);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accentColor.withValues(alpha: a(isDark ? 0.40 : 0.20)),
            accentColor.withValues(alpha: a(isDark ? 0.16 : 0.08)),
            (isDark ? Colors.black : Colors.white).withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.55, 1.0],
        ),
        border: Border(
          bottom: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08 * intensity + 0.02)
                : Colors.black.withValues(alpha: 0.07 * intensity + 0.02),
            width: 1,
          ),
        ),
      ),
      child: child,
    );
  }
}
