import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import 'album_artwork.dart';

/// Очередь треков с drag-and-drop перетаскиванием.
/// Поддерживает reorder, контекстное меню, выделение текущего трека.
class QueueList extends StatelessWidget {
  final void Function(Song song)? onRemove;
  final void Function(Song song)? onAddToPlaylist;

  const QueueList({
    super.key,
    this.onRemove,
    this.onAddToPlaylist,
  });

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final queue = player.queue;
    final currentSongId = player.currentSong?.id;
    // Дебаг дублей — лог если в очереди дубли по id (queue_list дубликаты)
    assert(() {
      final seen = <String>{};
      for (final s in queue) {
        if (!seen.add(s.id)) {
          debugPrint('[QueueList] duplicate id ${s.id} "${s.title}"');
        }
      }
      return true;
    }());

    if (queue.isEmpty) {
      return const Center(
        child: Text(
          'Очередь пуста',
          style: TextStyle(color: Colors.white38),
        ),
      );
    }

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: queue.length,
      onReorder: (oldIndex, newIndex) {
        // ReorderableListView может вернуть newIndex > oldIndex
        // из-за удаления элемента перед вставкой
        if (newIndex > oldIndex) newIndex--;
        player.reorderQueue(oldIndex, newIndex);
      },
      itemBuilder: (context, index) {
        final song = queue[index];
        final isCurrent = song.id == currentSongId;

        return Dismissible(
          key: ValueKey('${song.id}_$index'),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            color: Colors.red.shade900,
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          confirmDismiss: (_) async {
            return await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF2C2C2E),
                title: const Text(
                  'Удалить из очереди?',
                  style: TextStyle(color: Colors.white),
                ),
                content: Text(
                  '"${song.title}"',
                  style: const TextStyle(color: Colors.white70),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Отмена'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text(
                      'Удалить',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ),
                ],
              ),
            );
          },
          onDismissed: (_) {
            onRemove?.call(song);
            player.removeFromQueue(index);
          },
          child: ListTile(
            key: ValueKey('${song.id}_tile_$index'),
            selected: isCurrent,
            selectedTileColor: Colors.white.withOpacity(0.08),
            leading: _buildLeading(context, song, isCurrent),
            title: Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isCurrent
                    ? Theme.of(context).colorScheme.secondary
                    : Colors.white,
                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            subtitle: Builder(builder: (ctx) {
              // M4: причина от мозга — в субтайтл очереди, иначе мозг как шаффл.
              String brainExtra = '';
              try {
                final reason =
                    player.autoDjService.getBrainReason(song.id).trim();
                if (reason.isNotEmpty) {
                  brainExtra = ' • 🧠 $reason';
                }
              } catch (_) {}
              final base = song.artist ?? 'Неизвестный артист';
              final text = brainExtra.isEmpty ? base : '$base$brainExtra';
              return Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isCurrent ? Colors.white54 : Colors.white38,
                  fontSize: 12,
                ),
              );
            }),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  song.formattedDuration,
                  style: const TextStyle(color: Colors.white30, fontSize: 12),
                ),
                const SizedBox(width: 4),
                // Кнопка меню
                PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.more_vert,
                    color: Colors.white30,
                    size: 20,
                  ),
                  color: const Color(0xFF2C2C2E),
                  onSelected: (action) {
                    _handleMenuAction(context, action, song, index);
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'play',
                      child: Text('Воспроизвести',
                          style: TextStyle(color: Colors.white)),
                    ),
                    const PopupMenuItem(
                      value: 'playlist',
                      child: Text('Добавить в плейлист',
                          style: TextStyle(color: Colors.white)),
                    ),
                    // M4: «почему» — причина и пилюли настроения от мозга.
                    const PopupMenuItem(
                      value: 'why',
                      child: Text('Почему этот трек? 🧠',
                          style: TextStyle(color: Colors.white)),
                    ),
                    const PopupMenuItem(
                      value: 'remove',
                      child: Text('Удалить',
                          style: TextStyle(color: Colors.redAccent)),
                    ),
                  ],
                ),
              ],
            ),
            onTap: () {
              player.skipToIndex(index);
            },
          ),
        );
      },
    );
  }

  Widget _buildLeading(BuildContext context, Song song, bool isCurrent) {
    // Раньше была только цифра трека — в офлайне казалось «пусто».
    // Показываем обложку (с локальным приоритетом внутри AlbumArtwork).
    return Stack(
      alignment: Alignment.center,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 40,
            height: 40,
            child: (song.coverArt == null || song.coverArt!.isEmpty)
                ? Container(
                    color: Colors.white10,
                    alignment: Alignment.center,
                    child: Text(
                      '${song.track ?? ''}',
                      style: TextStyle(
                        color: isCurrent ? Colors.white54 : Colors.white24,
                        fontSize: 12,
                      ),
                    ),
                  )
                : AlbumArtwork(
                    coverArt: song.coverArt,
                    song: song,
                    size: 40,
                  ),
          ),
        ),
        if (isCurrent)
          Positioned(
            left: 0,
            child: Container(
              width: 4,
              height: 16,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
      ],
    );
  }

  void _handleMenuAction(
    BuildContext context,
    String action,
    Song song,
    int index,
  ) {
    final player = context.read<PlayerProvider>();
    switch (action) {
      case 'play':
        player.skipToIndex(index);
        break;
      case 'playlist':
        onAddToPlaylist?.call(song);
        break;
      case 'why':
        // M4: снэк «почему» + moods-пилюли из lastBrain*.
        try {
          final reason = player.autoDjService.getBrainReason(song.id).trim();
          final moods = player.autoDjService.getBrainMoods(song.id);
          final score = player.autoDjService.lastBrainScores[song.id];
          final buf = StringBuffer();
          if (reason.isNotEmpty) {
            buf.write(reason);
          } else {
            buf.write('Причина не сохранена (трек не из волны мозга).');
          }
          if (moods.isNotEmpty) buf.write('\nНастроение: ${moods.join(', ')}');
          if (score != null && score > 0) {
            buf.write('\nScore: ${score.toStringAsFixed(2)}');
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('🧠 ${song.title}: ${buf.toString()}'),
              duration: const Duration(seconds: 4),
            ),
          );
        } catch (_) {}
        break;
      case 'remove':
        player.removeFromQueue(index);
        break;
    }
  }
}
