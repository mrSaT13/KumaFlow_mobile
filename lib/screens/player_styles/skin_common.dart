import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/song.dart';
import '../../services/audiobookshelf_service.dart';
import '../../services/offline_service.dart';
import '../../services/safe_image_cache_manager.dart';
import '../../services/subsonic_service.dart';
import '../../widgets/album_artwork.dart' show isLocalFilePath;
import '../../widgets/kion_queue_sheet.dart';
import '../../widgets/synced_lyrics_view.dart';

/// Общая база скинов плеера (spotify/apple/vinyl/neon/youtube).
/// Визуал у каждого свой — здесь только общее поведение, чтобы доделанное
/// в одном месте (офлайн-обложки, кэш, очередь, тексты, свайпы) работало везде:
/// - резолв обложки с офлайн-приоритетом (скачанная cover_*.jpg бьёт сеть)
///   и единым размером кэша 600 (не плодим 600/700/900-дубли на диске);
/// - очередь и тексты одной шторкой;
/// - свайпы как в остальных плеерах.
class SkinCommon {
  /// URL обложки: локальный файл офлайна → http/abs → subsonic 600.
  static String coverUrl(Song? s, SubsonicService svc, {int size = 600}) {
    try {
      final local = OfflineService().getLocalCoverForSong(
        albumId: s?.albumId,
        coverArt: s?.coverArt,
        trackId: s?.id,
      );
      if (local != null) return local;
    } catch (_) {}
    final ca = s?.coverArt;
    if (ca == null || ca.isEmpty) return '';
    if (ca.startsWith('http')) return ca;
    if (isLocalFilePath(ca)) return ca;
    if (ca.startsWith('abs:')) {
      return AudiobookshelfService().getCoverUrl(ca.substring(4), width: size);
    }
    return svc.getCoverArtUrl(ca, size: size);
  }

  static Map<String, String>? headersFor(String url) {
    if (url.contains('audiobookshelf')) {
      return AudiobookshelfService().authHeaders;
    }
    return null;
  }

  /// Обложка через единый кэш-менеджер (офлайн-кэш общий со всеми экранами).
  static Widget artwork(
    String url, {
    BoxFit fit = BoxFit.cover,
    int cacheSize = 600,
    Widget? placeholder,
  }) {
    final ph = placeholder ?? const SizedBox.shrink();
    if (url.isEmpty) return ph;
    if (isLocalFilePath(url)) {
      return Image.file(
        File(url),
        fit: fit,
        cacheWidth: cacheSize,
        errorBuilder: (_, __, ___) => ph,
      );
    }
    return CachedNetworkImage(
      key: ValueKey('skin_${url.hashCode}_$cacheSize'),
      imageUrl: url,
      httpHeaders: headersFor(url),
      cacheManager: SafeImageCacheManager.instance,
      cacheKey: 'skin_${url.hashCode}_$cacheSize',
      fit: fit,
      memCacheWidth: cacheSize,
      maxWidthDiskCache: cacheSize,
      maxHeightDiskCache: cacheSize,
      useOldImageOnUrlChange: true,
      fadeInDuration: const Duration(milliseconds: 100),
      fadeOutDuration: Duration.zero,
      placeholder: (_, __) => ph,
      errorWidget: (_, __, ___) => ph,
    );
  }

  static void openQueue(BuildContext ctx) {
    showModalBottomSheet(
      context: ctx,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const KionQueueSheet(),
    );
  }

  static void openLyrics(BuildContext ctx, Song? song,
      {Color bg = const Color(0xFF141110)}) {
    if (song == null) return;
    showModalBottomSheet(
      context: ctx,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Container(
        height: MediaQuery.of(ctx).size.height * 0.85,
        decoration: BoxDecoration(
          color: bg,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(children: [
          const SizedBox(height: 10),
          Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2))),
          Expanded(child: SyncedLyricsView(song: song)),
        ]),
      ),
    );
  }

  /// Горизонтальные свайпы: влево — очередь, вправо — текст.
  static void onHSwipe(BuildContext ctx, DragEndDetails d, Song? song) {
    final v = d.primaryVelocity ?? 0;
    if (v < -300) {
      openQueue(ctx);
    } else if (v > 300) {
      openLyrics(ctx, song);
    }
  }
}
