import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/yandex_music_theme.dart';

/// Teardrop/drop-shaped card with hover animation.
///
/// Used for "My Wave" section on home screen, similar to Yandex Music.
class TeardropCard extends StatefulWidget {
  final String? imageUrl;
  final String title;
  final String? subtitle;
  final IconData icon;
  final Color gradientStart;
  final Color gradientEnd;
  final VoidCallback? onTap;
  final double width;
  final double height;

  const TeardropCard({
    super.key,
    this.imageUrl,
    required this.title,
    this.subtitle,
    this.icon = Icons.play_arrow_rounded,
    this.gradientStart = const Color(0xFF8B5CF6),
    this.gradientEnd = const Color(0xFFEF4444),
    this.onTap,
    this.width = double.infinity,
    this.height = 200,
  });

  @override
  State<TeardropCard> createState() => _TeardropCardState();
}

class _TeardropCardState extends State<TeardropCard>
    with TickerProviderStateMixin {
  late AnimationController _hoverController;
  late AnimationController _pulseController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _glowAnimation;
  late Animation<double> _pulseAnimation;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();

    // Hover animation
    _hoverController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.02).animate(
      CurvedAnimation(parent: _hoverController, curve: Curves.easeOut),
    );
    _glowAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _hoverController, curve: Curves.easeOut),
    );

    // Pulse animation for the play button
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.1).animate(
      CurvedAnimation(
        parent: _pulseController,
        curve: Curves.easeInOut,
      ),
    );
  }

  @override
  void dispose() {
    _hoverController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) {
        setState(() => _isHovered = true);
        _hoverController.forward();
        _pulseController.repeat(reverse: true);
      },
      onExit: (_) {
        setState(() => _isHovered = false);
        _hoverController.reverse();
        _pulseController.stop();
        _pulseController.reset();
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: Listenable.merge([_hoverController, _pulseController]),
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAnimation.value,
              child: Container(
                width: widget.width,
                height: widget.height,
                decoration: _buildTeardropDecoration(),
                child: ClipPath(
                  clipper: TeardropClipper(),
                  child: _buildCardContent(),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  BoxDecoration _buildTeardropDecoration() {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      boxShadow: [
        // Glow effect on hover
        BoxShadow(
          color: widget.gradientStart.withValues(
            alpha: 0.3 * _glowAnimation.value,
          ),
          blurRadius: 30 * _glowAnimation.value,
          spreadRadius: 5 * _glowAnimation.value,
        ),
        // Base shadow
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.3),
          blurRadius: 16,
          offset: const Offset(0, 8),
        ),
      ],
    );
  }

  Widget _buildCardContent() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            widget.gradientStart,
            widget.gradientEnd,
          ],
        ),
      ),
      child: Stack(
        children: [
          // Background pattern (subtle circles)
          Positioned.fill(
            child: CustomPaint(
              painter: WavePatternPainter(
                color: Colors.white.withValues(alpha: 0.1),
              ),
            ),
          ),

          // Content
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Top section
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          widget.icon,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      if (_isHovered)
                        AnimatedOpacity(
                          opacity: _isHovered ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 200),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.play_arrow_rounded,
                                  color: Colors.white,
                                  size: 16,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  'PLAY',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),

                  // Bottom section
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.5,
                        ),
                      ),
                      if (widget.subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          widget.subtitle!,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Animated play button (pulsing on hover)
          if (_isHovered)
            Positioned(
              bottom: 20,
              right: 20,
              child: Transform.scale(
                scale: _pulseAnimation.value,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(
                    widget.icon,
                    color: widget.gradientStart,
                    size: 28,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Custom clipper for teardrop shape.
class TeardropClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();

    // Start from top-left with rounded corner
    path.moveTo(20, 0);

    // Top edge
    path.lineTo(size.width - 20, 0);

    // Top-right rounded corner
    path.quadraticBezierTo(size.width, 0, size.width, 20);

    // Right edge
    path.lineTo(size.width, size.height - 40);

    // Teardrop bottom curve
    path.quadraticBezierTo(
      size.width,
      size.height,
      size.width - 40,
      size.height,
    );

    // Bottom edge
    path.lineTo(40, size.height);

    // Teardrop bottom-left curve
    path.quadraticBezierTo(
      0,
      size.height,
      0,
      size.height - 40,
    );

    // Left edge
    path.lineTo(0, 20);

    // Top-left rounded corner
    path.quadraticBezierTo(0, 0, 20, 0);

    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// Painter for subtle wave pattern in background.
class WavePatternPainter extends CustomPainter {
  final Color color;

  WavePatternPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // Draw subtle curved lines
    for (double i = 0; i < size.height; i += 30) {
      final path = Path();
      path.moveTo(0, i);
      path.quadraticBezierTo(
        size.width / 2,
        i + 15,
        size.width,
        i,
      );
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
