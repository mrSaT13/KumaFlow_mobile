import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/library_provider.dart';

/// Animated banner shown during library synchronization.
/// Displays current phase and progress (e.g. "Syncing songs... 45,200 / 80,000").
class SyncProgressBanner extends StatelessWidget {
  const SyncProgressBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<LibraryProvider>(
      builder: (context, lib, _) {
        final isDone = lib.syncPhase == 'done' || lib.syncPhase == 'error';
        if (!lib.isSyncing && !isDone) return const SizedBox.shrink();

        final phase = lib.syncPhase;
        final synced = lib.syncedSongs;
        final total = lib.totalSongsEstimate;
        final isRu = Localizations.localeOf(context).languageCode == 'ru';

        String message;
        switch (phase) {
          case 'probe':
            message = isRu ? 'Проверка сервера...' : 'Checking server...';
            break;
          case 'albums':
            message = isRu ? 'Загрузка альбомов...' : 'Loading albums...';
            break;
          case 'songs':
            if (total > 0) {
              message = isRu ? 'Загрузка песен... $synced / $total' : 'Loading songs... $synced / $total';
            } else {
              message = isRu ? 'Загрузка песен... $synced' : 'Loading songs... $synced';
            }
            break;
          case 'metadata':
            message = isRu ? 'Загрузка артистов и плейлистов...' : 'Loading artists & playlists...';
            break;
          case 'done':
            message = isRu ? 'Синхронизация завершена!' : 'Sync complete!';
            break;
          case 'error':
            message = isRu ? 'Ошибка синхронизации' : 'Sync error';
            break;
          default:
            message = isRu ? 'Синхронизация...' : 'Syncing...';
        }

        final progress = total > 0 ? (synced / total).clamp(0.0, 1.0) : null;

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer.withAlpha(180),
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
                width: 0.5,
              ),
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: progress,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
