import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../theme/app_theme.dart';
import 'album_artwork.dart';

/// KION-style queue bottom sheet with drag-to-reorder.
class KionQueueSheet extends StatefulWidget {
  const KionQueueSheet({super.key});

  @override
  State<KionQueueSheet> createState() => _KionQueueSheetState();
}

class _KionQueueSheetState extends State<KionQueueSheet> {
  ScrollController? _scrollController;
  bool _autoScrolled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryAutoScroll();
    });
  }

  void _tryAutoScroll() {
    if (_autoScrolled) return;
    final ctrl = _scrollController;
    if (ctrl == null || !ctrl.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryAutoScroll());
      return;
    }
    final player = context.read<PlayerProvider>();
    final idx = player.currentIndex;
    if (idx < 0 || idx >= player.queue.length) return;
    _autoScrolled = true;
    ctrl.animateTo(
      (idx * 72).toDouble().clamp(0.0, ctrl.position.maxScrollExtent),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        _scrollController = scrollController;
        return Container(
          decoration: const BoxDecoration(
            color: AppTheme.darkSurface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 8),
              // Drag handle
              Container(
                width: 36,
                height: 5,
                decoration: BoxDecoration(
                  color: AppTheme.darkDivider,
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
              const SizedBox(height: 16),
              // Title row with "Jump to current" button
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Очередь',
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                              color: Colors.white,
                            ),
                      ),
                    ),
                    Consumer<PlayerProvider>(
                      builder: (context, player, _) {
                        final currentIdx = player.currentIndex;
                        if (currentIdx < 0 || currentIdx >= player.queue.length) {
                          return const SizedBox.shrink();
                        }
                        return TextButton.icon(
                          onPressed: () {
                            final ctrl = _scrollController;
                            if (ctrl != null && ctrl.hasClients) {
                              ctrl.animateTo(
                                (currentIdx * 72).toDouble().clamp(
                                  0.0,
                                  ctrl.position.maxScrollExtent,
                                ),
                                duration: const Duration(milliseconds: 350),
                                curve: Curves.easeInOut,
                              );
                            }
                          },
                          icon: Icon(
                            Icons.play_circle_filled_rounded,
                            color: Theme.of(context).colorScheme.primary,
                            size: 18,
                          ),
                          label: const Text(
                            'К текущему',
                            style: TextStyle(color: Colors.white),
                          ),
                          style: TextButton.styleFrom(
                            backgroundColor: Colors.white12,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Queue list
              Expanded(
                child: Consumer<PlayerProvider>(
                  builder: (context, player, _) {
                    final queue = player.queue;
                    final currentIndex = player.currentIndex;

                    if (queue.isEmpty) {
                      return const Center(
                        child: Text(
                          'Очередь пуста',
                          style: TextStyle(color: Colors.white54),
                        ),
                      );
                    }

                    return ReorderableListView.builder(
                      scrollController: scrollController,
                      itemCount: queue.length,
                      onReorder: (oldIndex, newIndex) {
                        HapticFeedback.lightImpact();
                        player.reorderQueue(oldIndex, newIndex);
                      },
                      itemBuilder: (context, index) {
                        final song = queue[index];
                        final isPlaying = index == currentIndex;

                        return _QueueItem(
                          key: ValueKey('${song.id}_$index'),
                          song: song,
                          isPlaying: isPlaying,
                          index: index,
                          onPlay: () {
                            // keep sheet open but ensure seek doesn't trigger grey screen due to duplicate keys
                            // use microtask to avoid re-entrancy during ReorderableListView build
                            Future.microtask(() => player.skipToIndex(index));
                          },
                          onRemove: () => player.removeFromQueue(index),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Single queue item with album art, title, artist, and remove button.
class _QueueItem extends StatelessWidget {
  final Song song;
  final bool isPlaying;
  final int index;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  const _QueueItem({
    super.key,
    required this.song,
    required this.isPlaying,
    required this.index,
    required this.onPlay,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Stack(
        alignment: Alignment.center,
        children: [
          AlbumArtwork(coverArt: song.coverArt, size: 44, borderRadius: 6, song: song),
          if (isPlaying)
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(Icons.equalizer_rounded,
                  color: Theme.of(context).colorScheme.primary, size: 18),
            ),
          if (!isPlaying)
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(4)),
                child: Text('${index + 1}', style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600)),
              ),
            ),
        ],
      ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color:
              isPlaying ? Theme.of(context).colorScheme.primary : Colors.white,
          fontSize: 14,
          fontWeight: isPlaying ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: Text(
        song.artist ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppTheme.darkSecondaryText,
          fontSize: 12,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(
              Icons.remove_circle_outline,
              color: Colors.white70,
              size: 20,
            ),
            onPressed: onRemove,
          ),
          const Icon(
            Icons.drag_handle,
            color: Colors.white38,
            size: 20,
          ),
        ],
      ),
      onTap: onPlay,
    );
  }
}
