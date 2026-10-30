import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Gesture-driven star rating with half-star support, spring animation,
/// compact badge and full input modes.
class StarRating extends StatefulWidget {
  final double rating;
  final ValueChanged<double>? onRatingChanged;
  final double starSize;
  final double spacing;
  final Color activeColor;
  final Color inactiveColor;
  final bool allowHalf;
  final bool interactive;
  final StarRatingMode mode;

  const StarRating({
    super.key,
    this.rating = 0,
    this.onRatingChanged,
    this.starSize = 28,
    this.spacing = 2,
    this.activeColor = AppTheme.appleMusicRed,
    this.inactiveColor = const Color(0xFF555555),
    this.allowHalf = true,
    this.interactive = true,
    this.mode = StarRatingMode.input,
  });

  @override
  State<StarRating> createState() => _StarRatingState();

  /// Compact badge showing the rating as a number with a small star icon.
  static Widget badge({
    required double rating,
    double starSize = 14,
    TextStyle? textStyle,
    Color? textColor,
    Color? starColor,
  }) {
    return _StarRatingBadge(
      rating: rating,
      starSize: starSize,
      textStyle: textStyle,
      textColor: textColor,
      starColor: starColor,
    );
  }
}

enum StarRatingMode { input, badge }

class _StarRatingState extends State<StarRating>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _scaleAnim;
  double _hoverRating = 0;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _animController, curve: Curves.elasticOut),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  double _getRatingFromPosition(Offset localPosition, double starWidth) {
    final totalWidth = starWidth * 5 + widget.spacing * 4;
    final x = localPosition.dx.clamp(0.0, totalWidth);
    final starIndex = x / (starWidth + widget.spacing);

    if (widget.allowHalf) {
      final fractional = starIndex - starIndex.floorToDouble();
      if (fractional < 0.25) {
        return starIndex.floorToDouble();
      } else if (fractional < 0.75) {
        return starIndex.floorToDouble() + 0.5;
      } else {
        return math.min(starIndex.floorToDouble() + 1.0, 5.0);
      }
    }
    return math.min(starIndex.roundToDouble(), 5.0);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mode == StarRatingMode.badge) {
      return StarRating.badge(rating: widget.rating, starSize: widget.starSize);
    }

    final effectiveRating = _isDragging ? _hoverRating : widget.rating;

    return GestureDetector(
      onHorizontalDragStart: widget.interactive
          ? (details) {
              setState(() {
                _isDragging = true;
                _hoverRating = widget.rating;
              });
              _animController.forward(from: 0);
            }
          : null,
      onHorizontalDragUpdate: widget.interactive
          ? (details) {
              final box = context.findRenderObject() as RenderBox?;
              if (box == null) return;
              final starWidth =
                  (box.size.width - widget.spacing * 4) / 5;
              final newRating =
                  _getRatingFromPosition(details.localPosition, starWidth);
              if (newRating != _hoverRating) {
                setState(() => _hoverRating = newRating);
                _animController.forward(from: 0);
              }
            }
          : null,
      onHorizontalDragEnd: widget.interactive
          ? (details) {
              setState(() => _isDragging = false);
              widget.onRatingChanged?.call(_hoverRating);
            }
          : null,
      onTapDown: widget.interactive
          ? (details) {
              final box = context.findRenderObject() as RenderBox?;
              if (box == null) return;
              final starWidth =
                  (box.size.width - widget.spacing * 4) / 5;
              final tapRating =
                  _getRatingFromPosition(details.localPosition, starWidth);
              if (tapRating == widget.rating) {
                widget.onRatingChanged?.call(0);
              } else {
                widget.onRatingChanged?.call(tapRating);
              }
              _animController.forward(from: 0);
            }
          : null,
      child: AnimatedBuilder(
        animation: _scaleAnim,
        builder: (context, child) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(5, (index) {
              final starValue = index + 1.0;
              final fillLevel = _getFillLevel(effectiveRating, starValue);

              return Padding(
                padding: EdgeInsets.symmetric(horizontal: widget.spacing / 2),
                child: Transform.scale(
                  scale: _isDragging && fillLevel > 0 ? _scaleAnim.value : 1.0,
                  child: _StarIcon(
                    fillLevel: fillLevel,
                    size: widget.starSize,
                    activeColor: widget.activeColor,
                    inactiveColor: widget.inactiveColor,
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }

  double _getFillLevel(double rating, double starValue) {
    if (rating >= starValue) return 1.0;
    if (rating >= starValue - 0.5) return 0.5;
    return 0.0;
  }
}

class _StarIcon extends StatelessWidget {
  final double fillLevel;
  final double size;
  final Color activeColor;
  final Color inactiveColor;

  const _StarIcon({
    required this.fillLevel,
    required this.size,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _StarPainter(
          fillLevel: fillLevel,
          activeColor: activeColor,
          inactiveColor: inactiveColor,
        ),
      ),
    );
  }
}

class _StarPainter extends CustomPainter {
  final double fillLevel;
  final Color activeColor;
  final Color inactiveColor;

  _StarPainter({
    required this.fillLevel,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final path = _createStarPath(center, radius, 5, radius * 0.4);

    // Inactive fill
    final inactivePaint = Paint()
      ..color = inactiveColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, inactivePaint);

    // Active fill with clipping for half-star support
    if (fillLevel > 0) {
      canvas.save();
      final clipRect = Rect.fromLTWH(0, 0, size.width * fillLevel, size.height);
      canvas.clipRect(clipRect);

      final activePaint = Paint()
        ..color = activeColor
        ..style = PaintingStyle.fill;
      canvas.drawPath(path, activePaint);
      canvas.restore();
    }

    // Stroke outline
    final strokePaint = Paint()
      ..color = activeColor.withAlpha(180)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawPath(path, strokePaint);
  }

  Path _createStarPath(
      Offset center, double outerRadius, int points, double innerRadius) {
    final path = Path();
    final angle = math.pi / points;

    for (int i = 0; i < points * 2; i++) {
      final r = i.isEven ? outerRadius : innerRadius;
      final a = i * angle - math.pi / 2;
      final point = Offset(center.dx + r * math.cos(a), center.dy + r * math.sin(a));
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(_StarPainter oldDelegate) =>
      fillLevel != oldDelegate.fillLevel ||
      activeColor != oldDelegate.activeColor ||
      inactiveColor != oldDelegate.inactiveColor;
}

class _StarRatingBadge extends StatelessWidget {
  final double rating;
  final double starSize;
  final TextStyle? textStyle;
  final Color? textColor;
  final Color? starColor;

  const _StarRatingBadge({
    required this.rating,
    this.starSize = 14,
    this.textStyle,
    this.textColor,
    this.starColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveTextColor = textColor ?? theme.textTheme.bodySmall?.color;
    final effectiveStarColor = starColor ?? AppTheme.appleMusicRed;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: effectiveStarColor.withAlpha(30),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: starSize, color: effectiveStarColor),
          const SizedBox(width: 2),
          Text(
            rating.toStringAsFixed(1),
            style: textStyle ??
                TextStyle(
                  fontSize: starSize * 0.85,
                  fontWeight: FontWeight.w600,
                  color: effectiveTextColor,
                ),
          ),
        ],
      ),
    );
  }
}
