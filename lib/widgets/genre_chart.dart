import 'dart:math';
import 'package:flutter/material.dart';
import '../models/genre.dart';

/// Круговая диаграмма (donut chart) распределения жанров.
/// С поддержкой анимации сегментов и легендой с процентами.
class GenreChart extends StatefulWidget {
  final List<Genre> genres;
  final double size;
  final double strokeWidth;
  final double centerGap;

  const GenreChart({
    super.key,
    required this.genres,
    this.size = 200,
    this.strokeWidth = 32,
    this.centerGap = 0.6,
  });

  @override
  State<GenreChart> createState() => _GenreChartState();
}

/// Цветовая палитра для жанров
const List<Color> _genrePalette = [
  Color(0xFFE91E63), // Розовый
  Color(0xFF9C27B0), // Фиолетовый
  Color(0xFF3F51B5), // Индиго
  Color(0xFF00BCD4), // Голубой
  Color(0xFF4CAF50), // Зелёный
  Color(0xFFFF9800), // Оранжевый
  Color(0xFFFF5722), // Тёмно-оранжевый
  Color(0xFF795548), // Коричневый
  Color(0xFF607D8B), // Серо-голубой
  Color(0xFFFFEB3B), // Жёлтый
  Color(0xFF009688), // Бирюзовый
  Color(0xFF673AB7), // Глубокий фиолетовый
];

class _GenreChartState extends State<GenreChart>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  int? _hoveredIndex;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<_SegmentData> get _segments {
    final total = widget.genres.fold<int>(0, (sum, g) => sum + g.songCount);
    if (total == 0) return [];

    final sorted = List<Genre>.from(widget.genres)
      ..sort((a, b) => b.songCount.compareTo(a.songCount));

    return sorted.asMap().entries.map((entry) {
      final idx = entry.key;
      final genre = entry.value;
      final fraction = genre.songCount / total;
      return _SegmentData(
        genre: genre,
        fraction: fraction,
        color: _genrePalette[idx % _genrePalette.length],
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final segments = _segments;
    final total = widget.genres.fold<int>(0, (sum, g) => sum + g.songCount);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Donut chart
        SizedBox(
          width: widget.size,
          height: widget.size,
          child: AnimatedBuilder(
            animation: _animation,
            builder: (context, child) {
              return CustomPaint(
                painter: _DonutPainter(
                  segments: segments,
                  progress: _animation.value,
                  strokeWidth: widget.strokeWidth,
                  centerGap: widget.centerGap,
                  hoveredIndex: _hoveredIndex,
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$total',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'треков',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white54,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        // Легенда
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: List.generate(segments.length, (i) {
            final seg = segments[i];
            final pct = (seg.fraction * 100).toStringAsFixed(1);
            return MouseRegion(
              onEnter: (_) => setState(() => _hoveredIndex = i),
              onExit: (_) => setState(() => _hoveredIndex = null),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: seg.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${seg.genre.value} $pct%',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _hoveredIndex == i
                          ? Colors.white
                          : Colors.white70,
                    ),
                  ),
                ],
              ),
            );
          }),
        ),
      ],
    );
  }
}

class _SegmentData {
  final Genre genre;
  final double fraction;
  final Color color;

  const _SegmentData({
    required this.genre,
    required this.fraction,
    required this.color,
  });
}

class _DonutPainter extends CustomPainter {
  final List<_SegmentData> segments;
  final double progress;
  final double strokeWidth;
  final double centerGap;
  final int? hoveredIndex;

  _DonutPainter({
    required this.segments,
    required this.progress,
    required this.strokeWidth,
    required this.centerGap,
    this.hoveredIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2 - strokeWidth / 2;
    final innerRadius = radius * centerGap;

    double startAngle = -pi / 2;

    for (int i = 0; i < segments.length; i++) {
      final seg = segments[i];
      final sweepAngle = 2 * pi * seg.fraction * progress;
      final isHovered = i == hoveredIndex;

      // Сегмент
      final paint = Paint()
        ..color = isHovered ? seg.color.withOpacity(1.0) : seg.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = isHovered ? strokeWidth + 4 : strokeWidth
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle - 0.04, // зазор между сегментами
        false,
        paint,
      );

      startAngle += sweepAngle;
    }

    // Центральный круг (donut hole)
    final holePaint = Paint()..color = const Color(0xFF1E1E1E);
    canvas.drawCircle(center, innerRadius, holePaint);
  }

  @override
  bool shouldRepaint(_DonutPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.hoveredIndex != hoveredIndex;
  }
}
