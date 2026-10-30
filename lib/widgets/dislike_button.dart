import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Dislike button with animated inverted heart icon and confirmation dialog.
/// Persists dislike state for ML recommendation filtering.
class DislikeButton extends StatefulWidget {
  final bool isDisliked;
  final ValueChanged<bool>? onDislikeChanged;
  final double size;
  final Color activeColor;
  final Color inactiveColor;
  final bool showConfirmation;

  const DislikeButton({
    super.key,
    this.isDisliked = false,
    this.onDislikeChanged,
    this.size = 28,
    this.activeColor = AppTheme.appleMusicRed,
    this.inactiveColor = const Color(0xFFB3B3B3),
    this.showConfirmation = true,
  });

  @override
  State<DislikeButton> createState() => _DislikeButtonState();
}

class _DislikeButtonState extends State<DislikeButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _scaleAnim;
  late Animation<double> _rotationAnim;
  late Animation<Color?> _colorAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    _scaleAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.8), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 0.8, end: 1.3), weight: 40),
      TweenSequenceItem(tween: Tween(begin: 1.3, end: 1.0), weight: 30),
    ]).animate(CurvedAnimation(parent: _animController, curve: Curves.easeInOut));

    _rotationAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );

    _colorAnim = ColorTween(
      begin: widget.inactiveColor,
      end: widget.activeColor,
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeInOut));

    if (widget.isDisliked) {
      _animController.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(DislikeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isDisliked != oldWidget.isDisliked) {
      if (widget.isDisliked) {
        _animController.forward();
      } else {
        _animController.reverse();
      }
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _handleTap() async {
    if (widget.showConfirmation && !widget.isDisliked) {
      final confirmed = await _showConfirmationDialog();
      if (confirmed != true) return;
    }

    final newValue = !widget.isDisliked;
    widget.onDislikeChanged?.call(newValue);

    if (newValue) {
      _animController.forward();
    } else {
      _animController.reverse();
    }
  }

  Future<bool?> _showConfirmationDialog() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.heart_broken_rounded, color: widget.activeColor, size: 22),
            const SizedBox(width: 8),
            Text(
              'Dislike Track?',
              style: TextStyle(
                color: isDark ? Colors.white : Colors.black,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        content: Text(
          'This track will be excluded from recommendations. You can undo this later.',
          style: TextStyle(
            color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText,
            fontSize: 15,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              backgroundColor: widget.activeColor.withAlpha(30),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(
              'Dislike',
              style: TextStyle(
                color: widget.activeColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      child: AnimatedBuilder(
        animation: _animController,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnim.value,
            child: Transform.rotate(
              angle: _rotationAnim.value * 0.5,
              child: SizedBox(
                width: widget.size,
                height: widget.size,
                child: CustomPaint(
                  painter: _InvertedHeartPainter(
                    color: _colorAnim.value ?? widget.inactiveColor,
                    fillOpacity: _animController.value,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _InvertedHeartPainter extends CustomPainter {
  final Color color;
  final double fillOpacity;

  _InvertedHeartPainter({
    required this.color,
    required this.fillOpacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final scale = size.width / 24;

    // Inverted heart path (rotated 180 degrees)
    final path = Path();
    path.moveTo(center.dx, center.dy + 7 * scale);
    path.cubicTo(
      center.dx - 10 * scale,
      center.dy + 1 * scale,
      center.dx - 10 * scale,
      center.dy - 5 * scale,
      center.dx,
      center.dy - 2 * scale,
    );
    path.cubicTo(
      center.dx + 10 * scale,
      center.dy - 5 * scale,
      center.dx + 10 * scale,
      center.dy + 1 * scale,
      center.dx,
      center.dy + 7 * scale,
    );
    path.close();

    // Fill
    final fillPaint = Paint()
      ..color = color.withAlpha((fillOpacity * 255).toInt())
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);

    // Stroke
    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, strokePaint);

    // "X" mark overlay when active
    if (fillOpacity > 0.5) {
      final xPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8 * scale
        ..strokeCap = StrokeCap.round;

      final xSize = 4 * scale;
      canvas.drawLine(
        Offset(center.dx - xSize, center.dy + xSize * 0.3),
        Offset(center.dx + xSize, center.dy - xSize * 0.3),
        xPaint,
      );
      canvas.drawLine(
        Offset(center.dx + xSize, center.dy + xSize * 0.3),
        Offset(center.dx - xSize, center.dy - xSize * 0.3),
        xPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_InvertedHeartPainter oldDelegate) =>
      color != oldDelegate.color || fillOpacity != oldDelegate.fillOpacity;
}
