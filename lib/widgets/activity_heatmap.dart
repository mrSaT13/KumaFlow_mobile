import 'package:flutter/material.dart';

/// GitHub-style тепловая карта (heatmap) прослушиваний.
/// Показывает интенсивность прослушиваний по дням и неделям.
class ActivityHeatmap extends StatefulWidget {
  /// Карта {дата: количество прослушиваний}. Дата — начало дня (UTC).
  final Map<DateTime, int> listenData;

  /// Количество недель для отображения (по умолчанию 20).
  final int weeksToShow;

  /// Размер ячейки.
  final double cellSize;

  /// Зазор между ячейками.
  final double cellGap;

  const ActivityHeatmap({
    super.key,
    required this.listenData,
    this.weeksToShow = 20,
    this.cellSize = 12,
    this.cellGap = 2,
  });

  @override
  State<ActivityHeatmap> createState() => _ActivityHeatmapState();
}

class _ActivityHeatmapState extends State<ActivityHeatmap> {
  DateTime? _hoveredDate;
  int _hoveredCount = 0;

  /// Интерполяция цвета от светлого к тёмно-красному.
  Color _colorForCount(int count, int maxCount) {
    if (count == 0) {
      return const Color(0xFF1A1A2E);
    }
    final t = (count / maxCount).clamp(0.0, 1.0);
    // Светлый красный (0x80) → Насыщенный красный (0xFF)
    final r = lerpDouble(0x60, 0xFF, t)!;
    final g = lerpDouble(0x30, 0x30, t)!;
    final b = lerpDouble(0x40, 0x40, t)!;
    return Color.fromRGBO(r.toInt(), g.toInt(), b.toInt(), 1.0);
  }

  static double? lerpDouble(num a, num b, double t) {
    return a + (b - a) * t;
  }

  /// Формат даты для тултипа.
  String _formatDate(DateTime date) {
    const months = [
      'янв', 'фев', 'мар', 'апр', 'май', 'июн',
      'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // Начало отсчёта — понедельник N недель назад
    final totalDays = widget.weeksToShow * 7;
    final startDate = today.subtract(Duration(days: totalDays - 1));
    // Сдвигаем к ближайшему понедельнику
    final startWeekday = startDate.weekday;
    final adjustedStart =
        startDate.subtract(Duration(days: startWeekday - 1));

    // Нормализуем данные
    final normalized = <DateTime, int>{};
    for (final entry in widget.listenData.entries) {
      final key = DateTime(
          entry.key.year, entry.key.month, entry.key.day);
      normalized[key] = entry.value;
    }

    final maxCount = normalized.values.isEmpty
        ? 1
        : normalized.values.reduce((a, b) => a > b ? a : b);

    // Построение сетки
    final rows = <List<_CellData>>[];
    for (int week = 0; week < widget.weeksToShow; week++) {
      final row = <_CellData>[];
      for (int day = 0; day < 7; day++) {
        final date =
            adjustedStart.add(Duration(days: week * 7 + day));
        final count = normalized[date] ?? 0;
        final inRange = !date.isAfter(today);
        row.add(_CellData(
          date: date,
          count: inRange ? count : -1,
          inRange: inRange,
        ));
      }
      rows.add(row);
    }

    final totalWidth = widget.weeksToShow * (widget.cellSize + widget.cellGap);
    final totalHeight = 7 * (widget.cellSize + widget.cellGap);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Тултип при наведении
        if (_hoveredDate != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '${_hoveredCount} прослушиваний — ${_formatDate(_hoveredDate!)}',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
              ),
            ),
          ),
        // Тепловая карта
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: totalWidth,
            height: totalHeight,
            child: Column(
              children: List.generate(7, (day) {
                return Row(
                  children: List.generate(widget.weeksToShow, (week) {
                    final cell = rows[week][day];
                    if (!cell.inRange) {
                      return _emptyCell();
                    }
                    final color = cell.count == -1
                        ? const Color(0xFF1A1A2E)
                        : _colorForCount(cell.count, maxCount);
                    return MouseRegion(
                      onEnter: (_) {
                        setState(() {
                          _hoveredDate = cell.date;
                          _hoveredCount = cell.count == -1 ? 0 : cell.count;
                        });
                      },
                      onExit: (_) {
                        setState(() => _hoveredDate = null);
                      },
                      child: Container(
                        width: widget.cellSize,
                        height: widget.cellSize,
                        margin: EdgeInsets.all(widget.cellGap / 2),
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    );
                  }),
                );
              }),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Легенда less / more
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'less',
              style: TextStyle(color: Colors.white54, fontSize: 10),
            ),
            const SizedBox(width: 4),
            ...List.generate(5, (i) {
              final t = i / 4;
              final r = 0x60 + ((0xFF - 0x60) * t).toInt();
              return Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: i == 0
                      ? const Color(0xFF1A1A2E)
                      : Color.fromRGBO(r, 0x30, 0x40, 1.0),
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
            const SizedBox(width: 4),
            const Text(
              'more',
              style: TextStyle(color: Colors.white54, fontSize: 10),
            ),
          ],
        ),
      ],
    );
  }

  Widget _emptyCell() {
    return Container(
      width: widget.cellSize,
      height: widget.cellSize,
      margin: EdgeInsets.all(widget.cellGap / 2),
    );
  }
}

class _CellData {
  final DateTime date;
  final int count; // -1 если вне диапазона
  final bool inRange;

  const _CellData({
    required this.date,
    required this.count,
    required this.inRange,
  });
}
