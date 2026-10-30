import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

/// KION-style speed control bottom sheet.
class KionSpeedSheet extends StatelessWidget {
  final double currentSpeed;
  final ValueChanged<double> onSpeedChanged;

  const KionSpeedSheet({
    super.key,
    required this.currentSpeed,
    required this.onSpeedChanged,
  });

  static const List<double> _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.darkSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: AppTheme.darkDivider,
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Скорость воспроизведения',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            ..._speeds.map(
              (speed) => ListTile(
                title: Text(
                  speed == 1.0 ? 'Обычная' : '${speed}x',
                  style: TextStyle(
                    color: currentSpeed == speed
                        ? AppTheme.appleMusicRed
                        : Colors.white,
                    fontWeight: currentSpeed == speed
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                trailing: currentSpeed == speed
                    ? const Icon(
                        Icons.check,
                        color: AppTheme.appleMusicRed,
                        size: 20,
                      )
                    : null,
                onTap: () {
                  HapticFeedback.lightImpact();
                  onSpeedChanged(speed);
                  Navigator.pop(context);
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
