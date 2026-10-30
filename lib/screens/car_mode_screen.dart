import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/song.dart';
import '../providers/player_provider.dart' as pp;
import '../services/subsonic_service.dart';

/// Simplified interface for driving.
///
/// Large buttons, minimal distractions, voice-friendly.
class CarModeScreen extends StatefulWidget {
  const CarModeScreen({super.key});

  @override
  State<CarModeScreen> createState() => _CarModeScreenState();
}

class _CarModeScreenState extends State<CarModeScreen> {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Selector pattern: split state into a coarse-grained "current song / is playing"
    // and a fine-grained "position". Rebuilds the body when song changes, but not
    // every second for position updates.
    final currentSong = context.select<pp.PlayerProvider, Song?>((p) => p.currentSong);
    final isPlaying = context.select<pp.PlayerProvider, bool>((p) => p.isPlaying);
    final playerProvider = context.read<pp.PlayerProvider>();

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'CAR MODE',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white54 : Colors.black54,
                      letterSpacing: 1.2,
                    ),
                  ),
                  IconButton(
                        icon: const Icon(Icons.arrow_back_rounded, size: 26),
                        onPressed: () => Navigator.of(context).pop(),
                        color: isDark ? Colors.white54 : Colors.black54,
                      ),
                ],
              ),

              const Spacer(),

              // Album Art
              if (currentSong != null)
                Container(
                  width: 280,
                  height: 280,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 30,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: currentSong.coverArt != null
                        ? CachedNetworkImage(
                            imageUrl: Provider.of<SubsonicService>(context, listen: false)
                                .getCoverArtUrl(currentSong.coverArt!, size: 400),
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => _buildPlaceholderArt(isDark),
                          )
                        : _buildPlaceholderArt(isDark),
                  ),
                )
              else
                Container(
                  width: 280,
                  height: 280,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    color: isDark ? const Color(0xFF282828) : Colors.grey[200],
                  ),
                  child: _buildPlaceholderArt(isDark),
                ),

              const SizedBox(height: 32),

              // Song Info
              if (currentSong != null) ...[
                Text(
                  currentSong.title,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Text(
                  currentSong.artist ?? 'Unknown Artist',
                  style: TextStyle(
                    fontSize: 18,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ] else
                Text(
                  'No track playing',
                  style: TextStyle(
                    fontSize: 20,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                ),

              const Spacer(),

              // Progress Bar
              if (currentSong != null)
                _CarProgressBar(song: currentSong),

              const SizedBox(height: 24),

              // Large Controls
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Previous
                  _LargeControlButton(
                    icon: Icons.skip_previous_rounded,
                    size: 56,
                    onTap: () => playerProvider.skipPrevious(),
                  ),

                  // Play/Pause
                  _LargeControlButton(
                    icon: isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 80,
                    isPrimary: true,
                    onTap: () => playerProvider.togglePlayPause(),
                  ),

                  // Next
                  _LargeControlButton(
                    icon: Icons.skip_next_rounded,
                    size: 56,
                    onTap: () => playerProvider.skipNext(),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Quick Actions
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _QuickAction(
                    icon: playerProvider.shuffleEnabled
                        ? Icons.shuffle_on_rounded
                        : Icons.shuffle_rounded,
                    label: 'Shuffle',
                    isActive: playerProvider.shuffleEnabled,
                    onTap: () => playerProvider.toggleShuffle(),
                  ),
                  _QuickAction(
                    icon: playerProvider.repeatMode != pp.RepeatMode.off
                        ? Icons.repeat_on_rounded
                        : Icons.repeat_rounded,
                    label: 'Repeat',
                    isActive: playerProvider.repeatMode != pp.RepeatMode.off,
                    onTap: () => playerProvider.toggleRepeat(),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Like / Dislike (large, thumb-friendly, voice-friendly)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _QuickAction(
                    icon: Icons.heart_broken_rounded,
                    label: 'Dislike',
                    isActive: false,
                    color: Theme.of(context).colorScheme.primary,
                    onTap: () {
                      if (currentSong != null) {
                        final s = currentSong;
                        // Атомарный дизлайк+скип (раньше скипа не было вообще).
                        playerProvider.dislikeAndSkip(s);
                      }
                    },
                  ),
                  const SizedBox(width: 48),
                  _QuickAction(
                    icon: currentSong?.starred == true
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    label: 'Like',
                    isActive: currentSong?.starred == true,
                    color: Theme.of(context).colorScheme.primary,
                    onTap: () {
                      if (currentSong != null) {
                        playerProvider.toggleFavoriteForSong(currentSong);
                      }
                    },
                  ),
                ],
              ),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholderArt(bool isDark) {
    return Container(
      color: isDark ? const Color(0xFF282828) : Colors.grey[200],
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          size: 80,
          color: isDark ? Colors.white24 : Colors.black12,
        ),
      ),
    );
  }
}

class _LargeControlButton extends StatelessWidget {  final IconData icon;
  final double size;
  final bool isPrimary;
  final VoidCallback onTap;

  const _LargeControlButton({
    required this.icon,
    required this.size,
    this.isPrimary = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isPrimary
              ? Theme.of(context).colorScheme.primary
              : (isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.05)),
        ),
        child: Icon(
          icon,
          size: size * 0.6,
          color: isPrimary ? Colors.white : (isDark ? Colors.white : Colors.black),
        ),
      ),
    );
  }
}

class _CarProgressBar extends StatelessWidget {
  final Song song;
  const _CarProgressBar({required this.song});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Subscribe only to position — this widget rebuilds every tick without
    // rebuilding the whole car-mode screen.
    final position = context.select<pp.PlayerProvider, Duration>((p) => p.position);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
            ),
            child: Slider(
              value: position.inSeconds.toDouble(),
              max: song.duration?.toDouble() ?? 1,
              onChanged: (value) {
                context.read<pp.PlayerProvider>().seek(Duration(seconds: value.toInt()));
              },
              activeColor: Theme.of(context).colorScheme.primary,
              inactiveColor: isDark ? Colors.white24 : Colors.black26,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(position),
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                ),
                Text(
                  _formatDuration(song.duration != null
                      ? Duration(seconds: song.duration!)
                      : Duration.zero),
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class _QuickAction extends StatelessWidget {  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final Color? color;

  const _QuickAction({
    required this.icon,
    required this.label,
    this.isActive = false,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeColor = color ?? Theme.of(context).colorScheme.primary;
    final inactiveColor = isDark ? Colors.white54 : Colors.black54;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 40,
            color: isActive ? activeColor : inactiveColor,
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              color: isActive ? activeColor : inactiveColor,
            ),
          ),
        ],
      ),
    );
  }
}
