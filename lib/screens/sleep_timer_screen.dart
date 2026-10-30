import 'dart:async';

import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/theme_service.dart';
import '../widgets/app_gradient_background.dart';

import '../providers/player_provider.dart';

/// Preset durations for the sleep timer.
const _presets = [15, 30, 45, 60, 90];

/// Full-screen sleep timer with preset buttons, end-of-track mode,
/// remaining time display, and dark theme.
class SleepTimerScreen extends StatefulWidget {
  const SleepTimerScreen({super.key});

  @override
  State<SleepTimerScreen> createState() => _SleepTimerScreenState();
}

class _SleepTimerScreenState extends State<SleepTimerScreen>
    with SingleTickerProviderStateMixin {
  Timer? _tickTimer;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  String _formatRemaining(Duration d) {
    if (d.isNegative) return '0:00';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final remaining = player.sleepTimerRemaining;
    final isActive = player.hasSleepTimer;
    final endSong = player.sleepTimerEndCurrentSong;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white70),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Sleep Timer',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),

            // ── Remaining time / idle indicator ──────────────────────────
            if (isActive && remaining != null)
              _buildActiveTimer(remaining)
            else
              _buildIdleIndicator(),

            const Spacer(flex: 2),

            // ── Preset grid ─────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  Text(
                    'Set timer',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 13,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    alignment: WrapAlignment.center,
                    children: _presets.map((min) {
                      return _PresetChip(
                        minutes: min,
                        onTap: () => _setTimer(context, Duration(minutes: min)),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 28),

            // ── End-of-track toggle ─────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: _EndOfTrackToggle(
                value: endSong,
                onChanged: (val) {
                  if (val) {
                    context.read<PlayerProvider>().setSleepTimer(
                          Duration.zero,
                          endCurrentSong: true,
                          fadeOut: false,
                        );
                  } else {
                    context.read<PlayerProvider>().cancelSleepTimer();
                  }
                },
              ),
            ),

            const Spacer(flex: 2),

            // ── Cancel button (visible when timer active) ───────────────
            if (isActive)
              Padding(
                padding: const EdgeInsets.only(bottom: 32),
                child: TextButton(
                  onPressed: () {
                    context.read<PlayerProvider>().cancelSleepTimer();
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFE53935),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 32, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                      side: const BorderSide(color: Color(0xFFE53935), width: 1),
                    ),
                  ),
                  child: const Text(
                    'Cancel Timer',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                ),
              ),

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveTimer(Duration remaining) {
    return Column(
      children: [
        // Pulsing clock icon
        AnimatedBuilder(
          animation: _pulseController,
          builder: (_, __) {
            final opacity = 0.5 + _pulseController.value * 0.5;
            return Icon(
              Icons.nightlight_round,
              size: 56,
              color: Color.lerp(
                const Color(0xFF7C4DFF),
                const Color(0xFFB388FF),
                opacity,
              ),
            );
          },
        ),
        const SizedBox(height: 20),
        Text(
          _formatRemaining(remaining),
          style: const TextStyle(
            fontSize: 48,
            fontWeight: FontWeight.w200,
            color: Colors.white,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'remaining',
          style: TextStyle(
            fontSize: 13,
            color: Colors.white.withValues(alpha: 0.5),
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _buildIdleIndicator() {
    return Column(
      children: [
        Icon(
          Icons.nightlight_round,
          size: 56,
          color: Colors.white.withValues(alpha: 0.25),
        ),
        const SizedBox(height: 20),
        Text(
          'No timer set',
          style: TextStyle(
            fontSize: 18,
            color: Colors.white.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  void _setTimer(BuildContext context, Duration duration) {
    context.read<PlayerProvider>().setSleepTimer(
          duration,
          fadeOut: false,
        );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal widgets
// ─────────────────────────────────────────────────────────────────────────────

class _PresetChip extends StatelessWidget {
  final int minutes;
  final VoidCallback onTap;

  const _PresetChip({required this.minutes, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        height: 56,
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E2E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFF7C4DFF).withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$minutes',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            Text(
              'min',
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EndOfTrackToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _EndOfTrackToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: value
              ? const Color(0xFF7C4DFF).withValues(alpha: 0.2)
              : const Color(0xFF1E1E2E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: value
                ? const Color(0xFF7C4DFF)
                : Colors.white.withValues(alpha: 0.1),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              value ? Icons.music_note : Icons.music_note_outlined,
              size: 20,
              color: value ? const Color(0xFFB388FF) : Colors.white54,
            ),
            const SizedBox(width: 12),
            Text(
              'End of current track',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: value ? Colors.white : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
