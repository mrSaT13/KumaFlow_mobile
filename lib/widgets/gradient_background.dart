import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';
import '../theme/yandex_music_theme.dart';

/// Dynamic gradient background that adapts to content colors.
class GradientBackground extends StatefulWidget {
  final Widget child;
  final String? imageUrl;
  final Color? fallbackColor;
  final bool enableBlur;
  final double blurAmount;

  const GradientBackground({
    super.key,
    required this.child,
    this.imageUrl,
    this.fallbackColor,
    this.enableBlur = true,
    this.blurAmount = 30,
  });

  @override
  State<GradientBackground> createState() => _GradientBackgroundState();
}

class _GradientBackgroundState extends State<GradientBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _colorController;
  Color _dominantColor = const Color(0xFF121212);
  Color _accentColor = const Color(0xFF282828);

  @override
  void initState() {
    super.initState();
    _colorController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _extractColors();
  }

  @override
  void didUpdateWidget(GradientBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.imageUrl != oldWidget.imageUrl) {
      _extractColors();
    }
  }

  @override
  void dispose() {
    _colorController.dispose();
    super.dispose();
  }

  Future<void> _extractColors() async {
    if (widget.imageUrl == null) {
      setState(() {
        _dominantColor = widget.fallbackColor ?? const Color(0xFF121212);
        _accentColor = YandexMusicTheme.darkElevated;
      });
      return;
    }

    try {
      final paletteGenerator = await PaletteGenerator.fromImageProvider(
        NetworkImage(widget.imageUrl!),
        maximumColorCount: 8,
      );

      if (mounted) {
        final newDominant = paletteGenerator.dominantColor?.color ?? const Color(0xFF282828);
        final newAccent = paletteGenerator.vibrantColor?.color ?? const Color(0xFF121212);

        setState(() {
          _dominantColor = newDominant;
          _accentColor = newAccent;
        });

        _colorController.forward(from: 0);
      }
    } catch (e) {
      // Use fallback colors
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _colorController,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                _dominantColor.withValues(alpha: 0.8),
                _darkenColor(_dominantColor, 0.3),
                Color.lerp(_dominantColor, _accentColor, 0.3)!.withValues(alpha: 0.5),
                const Color(0xFF121212),
              ],
              stops: const [0.0, 0.3, 0.6, 1.0],
            ),
          ),
          child: widget.enableBlur
              ? BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: widget.blurAmount,
                    sigmaY: widget.blurAmount,
                  ),
                  child: widget.child,
                )
              : widget.child,
        );
      },
    );
  }

  Color _darkenColor(Color color, double factor) {
    final hsl = HSLColor.fromColor(color);
    final darkened = hsl.withLightness((hsl.lightness * (1 - factor)).clamp(0.0, 1.0));
    return darkened.toColor();
  }
}

/// Animated gradient that shifts colors over time.
class AnimatedGradientBackground extends StatefulWidget {
  final Widget child;
  final List<Color> colors;
  final Duration duration;

  const AnimatedGradientBackground({
    super.key,
    required this.child,
    this.colors = const [
      Color(0xFF1E1E1E),
      Color(0xFF121212),
      Color(0xFF1E1E1E),
    ],
    this.duration = const Duration(seconds: 5),
  });

  @override
  State<AnimatedGradientBackground> createState() => _AnimatedGradientBackgroundState();
}

class _AnimatedGradientBackgroundState extends State<AnimatedGradientBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: widget.colors,
              stops: [
                0.0,
                0.5 + (_animation.value * 0.2 - 0.1),
                1.0,
              ],
            ),
          ),
          child: widget.child,
        );
      },
    );
  }
}

/// Mesh gradient background for more complex effects.
class MeshGradientBackground extends StatelessWidget {
  final Widget child;
  final List<Color> colors;

  const MeshGradientBackground({
    super.key,
    required this.child,
    this.colors = const [
      Color(0xFF1E1E1E),
      Color(0xFF2C2C2C),
      Color(0xFF121212),
      Color(0xFF1E1E1E),
    ],
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-0.8, -0.8),
          radius: 1.2,
          colors: [
            colors[0].withValues(alpha: 0.6),
            Colors.transparent,
          ],
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0.8, 0.8),
            radius: 1.2,
            colors: [
              colors[1].withValues(alpha: 0.4),
              Colors.transparent,
            ],
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0.0, 0.0),
              radius: 1.5,
              colors: [
                colors[2].withValues(alpha: 0.3),
                Colors.transparent,
              ],
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
