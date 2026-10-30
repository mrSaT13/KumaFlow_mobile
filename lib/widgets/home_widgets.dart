import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

/// Simple now-playing widget for Android home screen
class NowPlayingWidget extends StatelessWidget {
  final String? title;
  final String? artist;
  final String? imageUrl;
  final bool isPlaying;
  final VoidCallback? onPlayPause;
  final VoidCallback? onNext;

  const NowPlayingWidget({
    super.key,
    this.title,
    this.artist,
    this.imageUrl,
    this.isPlaying = false,
    this.onPlayPause,
    this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppTheme.darkDivider,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          // Album art placeholder
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppTheme.darkElevated,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.music_note,
              color: Colors.red,
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          // Song info
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title ?? 'KumaFlow',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (artist != null)
                  Text(
                    artist!,
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          // Controls
          IconButton(
            icon: Icon(
              isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
            ),
            onPressed: onPlayPause,
          ),
          IconButton(
            icon: const Icon(
              Icons.skip_next,
              color: Colors.white,
            ),
            onPressed: onNext,
          ),
        ],
      ),
    );
  }
}

/// Quick actions widget for home screen
class QuickActionsWidget extends StatelessWidget {
  final VoidCallback? onShuffle;
  final VoidCallback? onFavorites;
  final VoidCallback? onRecentlyPlayed;

  const QuickActionsWidget({
    super.key,
    this.onShuffle,
    this.onFavorites,
    this.onRecentlyPlayed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppTheme.darkDivider,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ActionButton(
            icon: Icons.shuffle,
            label: 'Случайно',
            onTap: onShuffle,
          ),
          _ActionButton(
            icon: Icons.favorite,
            label: 'Избранное',
            onTap: onFavorites,
          ),
          _ActionButton(
            icon: Icons.history,
            label: 'История',
            onTap: onRecentlyPlayed,
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.red, size: 28),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
