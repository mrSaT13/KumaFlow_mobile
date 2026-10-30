import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../services/safe_image_cache_manager.dart';
import '../services/subsonic_service.dart';
import '../services/audiobookshelf_service.dart';
import '../services/offline_service.dart';
import '../services/player_ui_settings_service.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';

bool isLocalFilePath(String? s) {
  if (s == null || s.isEmpty) return false;
  if (s.startsWith('/')) return true;
  if (s.length > 2 && s[1] == ':') return true;
  return false;
}

class _ImageUrlCache {
  static final Map<String, String> _cache = {};

  static String getUrl(SubsonicService service, String? coverArt, int size,
      {String? serverId}) {
    if (coverArt == null || coverArt.isEmpty) return '';
    // Ключ с сервером: один coverArt у друзей — разные обложки.
    final key = '${serverId ?? 'main'}_${coverArt}_$size';
    final existing = _cache[key];
    // Пустые URL (конфиг ещё не загружен на холодном старте) никогда
    // не кешируем — иначе артисты не загрузятся до очистки кеша.
    if (existing != null && existing.isNotEmpty) return existing;
    final url = service.getCoverArtUrl(coverArt, size: size);
    if (url.isEmpty) return '';
    _cache[key] = url;
    return url;
  }
}

class AlbumArtwork extends StatelessWidget {
  final String? coverArt;
  final double size;

  /// Полный трек для коллаб-микса: обложка грузится с сервера-владельца
  /// через MultiServerResolver, а не с основного сервера.
  final Song? song;

  final double? borderRadius;
  final BoxShadow? shadow;

  final bool preserveAspectRatio;

  const AlbumArtwork({
    super.key,
    this.coverArt,
    this.size = 150,
    this.borderRadius,
    this.shadow,
    this.preserveAspectRatio = false,
    this.song,
  });

  /// Суффикс ключей кэша картинок: разделяет одинаковые coverArt
  /// с разных серверов (коллаб-микс) и разные треки с одной обложкой
  /// (сборники) — иначе при дизлайке/скипе висит старая картинка.
  String get _serverSuffix => song?.sourceServerId ?? 'main';
  String get _trackSuffix => song?.id ?? coverArt ?? 'none';

  /// Subsonic-URL обложки: для трека друга — через его сервер.
  String _resolveSubsonicUrl(
      BuildContext context, String coverArt, int cacheSize) {
    if (song != null && song!.isRemoteCollab) {
      try {
        return Provider.of<PlayerProvider>(context, listen: false)
            .multiServerResolver
            .resolveCoverUrl(song!, size: cacheSize);
      } catch (_) {}
    }
    return _ImageUrlCache.getUrl(
      Provider.of<SubsonicService>(context, listen: false),
      coverArt,
      cacheSize,
      serverId: song?.sourceServerId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final svc = PlayerUiSettingsService();
    return ValueListenableBuilder<String>(
      valueListenable: svc.artworkShapeNotifier,
      builder: (context, shape, _) {
        return ValueListenableBuilder<double>(
          valueListenable: svc.albumArtCornerRadiusNotifier,
          builder: (context, globalRadius, _) {
            return ValueListenableBuilder<String>(
              valueListenable: svc.artworkShadowNotifier,
              builder: (context, shadowLevel, _) {
                return ValueListenableBuilder<String>(
                  valueListenable: svc.artworkShadowColorNotifier,
                  builder: (context, shadowColor, _) {
                    final resolvedRadius =
                        borderRadius ??
                        (shape == 'circle'
                            ? 9999.0
                            : shape == 'square'
                            ? 0.0
                            : globalRadius);
                    return _buildContent(
                      context,
                      resolvedRadius,
                      shadowLevel,
                      shadowColor,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  BoxShadow? _resolvedShadow(
    BuildContext context,
    double resolvedRadius,
    String shadowLevel,
    String shadowColor,
    bool isDark,
  ) {
    if (shadow != null) return shadow;
    if (shadowLevel == 'none') return null;
    final Color color;
    switch (shadowColor) {
      case 'accent':
        color = Theme.of(context).colorScheme.primary;
        break;
      default:
        color = Colors.black;
    }
    double opacity;
    double blur;
    Offset offset;
    switch (shadowLevel) {
      case 'medium':
        opacity = isDark ? 0.35 : 0.25;
        blur = size / 6;
        offset = Offset(0, size / 20);
        break;
      case 'strong':
        opacity = isDark ? 0.55 : 0.40;
        blur = size / 4;
        offset = Offset(0, size / 12);
        break;
      default:
        opacity = isDark ? 0.22 : 0.14;
        blur = size / 10;
        offset = Offset(0, size / 30);
    }
    return BoxShadow(
      color: color.withValues(alpha: opacity),
      blurRadius: blur,
      offset: offset,
    );
  }

  Widget _buildContent(
    BuildContext context,
    double resolvedRadius,
    String shadowLevel,
    String shadowColor,
  ) {
    final validSize = size.isFinite && !size.isNaN ? size : 150.0;

    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheSize = (validSize * dpr).toInt().clamp(200, 800);

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final resolvedShadow = _resolvedShadow(
      context,
      resolvedRadius,
      shadowLevel,
      shadowColor,
      isDark,
    );

    if (preserveAspectRatio) {
      return Container(
        constraints: BoxConstraints(maxWidth: validSize),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(resolvedRadius),
          boxShadow: resolvedShadow != null ? [resolvedShadow] : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(resolvedRadius),
          child: _buildImageNatural(isDark, cacheSize),
        ),
      );
    }

    return Container(
      width: validSize,
      height: validSize,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(resolvedRadius),

        boxShadow: resolvedShadow != null && validSize > 60
            ? [resolvedShadow]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(resolvedRadius),
        child: _buildImage(isDark, cacheSize),
      ),
    );
  }

  bool _isAbsCover(String? s) => s != null && s.startsWith('abs:');
  bool _isHttpCover(String? s) => s != null && (s.startsWith('http://') || s.startsWith('https://'));

  Widget _buildImageNatural(bool isDark, int cacheSize) {
    try {
      if (song != null) {
        final local = OfflineService().getLocalCoverForSong(
          albumId: song!.albumId,
          coverArt: coverArt,
          trackId: song!.id,
        );
        if (local != null) {
          return Image.file(
            File(local),
            key: ValueKey('local_$local'),
            fit: BoxFit.contain,
            errorBuilder: (ctx, err, stack) => _buildPlaceholder(isDark),
          );
        }
      }
    } catch (_) {}
    if (coverArt == null || coverArt!.isEmpty) return _buildPlaceholder(isDark);

    if (_isHttpCover(coverArt)) {
      return CachedNetworkImage(
        imageUrl: coverArt!,
        key: ValueKey(coverArt),
        cacheManager: SafeImageCacheManager.instance,
        cacheKey: 'http_${coverArt.hashCode}_natural_$cacheSize',
        fit: BoxFit.contain,
        fadeInDuration: const Duration(milliseconds: 100),
        fadeOutDuration: Duration.zero,
        placeholder: (ctx, url) => _buildPlaceholder(isDark),
        errorWidget: (ctx, err, stack) => _buildPlaceholder(isDark),
      );
    }

    if (isLocalFilePath(coverArt)) {
      final artFile = File(coverArt!);
      return Image.file(
        artFile,
        key: ValueKey(coverArt),
        fit: BoxFit.contain,
        errorBuilder: (ctx, err, stack) => _buildPlaceholder(isDark),
      );
    }

    if (_isAbsCover(coverArt)) {
      final id = coverArt!.substring(4);
      final url = AudiobookshelfService().getCoverUrl(id, width: cacheSize);
      final headers = AudiobookshelfService().authHeaders;
      if (url.isEmpty) return _buildPlaceholder(isDark);
      return CachedNetworkImage(
        imageUrl: url,
        httpHeaders: headers,
        cacheKey: 'abs_${id}_natural_$cacheSize',
        key: ValueKey('abs_${id}_natural_$cacheSize'),
        cacheManager: SafeImageCacheManager.instance,
        fit: BoxFit.contain,
        fadeInDuration: const Duration(milliseconds: 100),
        fadeOutDuration: Duration.zero,
        placeholder: (ctx, url) => _buildPlaceholder(isDark),
        errorWidget: (ctx, err, stack) => _buildPlaceholder(isDark),
      );
    }

    return Builder(
      builder: (context) {
        final imageUrl = _resolveSubsonicUrl(context, coverArt!, cacheSize);
        if (imageUrl.isEmpty) return _buildPlaceholder(isDark);
        return CachedNetworkImage(
          imageUrl: imageUrl,
          cacheKey: '${_serverSuffix}_${coverArt}_natural_$cacheSize',
          key: ValueKey('${_serverSuffix}_${_trackSuffix}_${coverArt}_natural_$cacheSize'),
          cacheManager: SafeImageCacheManager.instance,
          fit: BoxFit.contain,
          fadeInDuration: const Duration(milliseconds: 100),
          fadeOutDuration: Duration.zero,
          useOldImageOnUrlChange: false,
          placeholder: (ctx, url) => _buildPlaceholder(isDark),
          errorWidget: (ctx, err, stack) {
            debugPrint('AlbumArtwork error (natural): $err');
            return _buildNetworkImageFallback(imageUrl, isDark, BoxFit.contain);
          },
        );
      },
    );
  }

  Widget _buildImage(bool isDark, int cacheSize) {
    // Офлайн-приоритет: скачанная cover_*.jpg бьёт сеть/кэш (очередь и
    // мини-плеер в офлайне иначе пустые при непрогретом HTTP-кэше).
    try {
      if (song != null) {
        final local = OfflineService().getLocalCoverForSong(
          albumId: song!.albumId,
          coverArt: coverArt,
          trackId: song!.id,
        );
        if (local != null) {
          return Image.file(
            File(local),
            key: ValueKey('local_$local'),
            fit: BoxFit.cover,
            cacheWidth: cacheSize,
            cacheHeight: cacheSize,
            errorBuilder: (ctx, err, stack) => _buildPlaceholder(isDark),
          );
        }
      }
    } catch (_) {}
    if (coverArt == null || coverArt!.isEmpty) return _buildPlaceholder(isDark);

    if (_isHttpCover(coverArt)) {
      return CachedNetworkImage(
        imageUrl: coverArt!,
        key: ValueKey(coverArt),
        cacheManager: SafeImageCacheManager.instance,
        cacheKey: 'http_${coverArt.hashCode}_$cacheSize',
        fit: BoxFit.cover,
        memCacheWidth: cacheSize,
        memCacheHeight: cacheSize,
        maxWidthDiskCache: cacheSize,
        maxHeightDiskCache: cacheSize,
        fadeInDuration: const Duration(milliseconds: 100),
        fadeOutDuration: Duration.zero,
        useOldImageOnUrlChange: true,
        placeholder: (ctx, url) => _buildPlaceholder(isDark),
        errorWidget: (ctx, err, stack) => _buildPlaceholder(isDark),
      );
    }

    if (isLocalFilePath(coverArt)) {
      final artFile = File(coverArt!);
      return Image.file(
        artFile,
        key: ValueKey(coverArt),
        fit: BoxFit.cover,
        cacheWidth: cacheSize,
        cacheHeight: cacheSize,
        errorBuilder: (ctx, err, stack) => _buildPlaceholder(isDark),
      );
    }

    if (_isAbsCover(coverArt)) {
      final id = coverArt!.substring(4);
      final url = AudiobookshelfService().getCoverUrl(id, width: cacheSize);
      final headers = AudiobookshelfService().authHeaders;
      if (url.isEmpty) return _buildPlaceholder(isDark);
      return CachedNetworkImage(
        imageUrl: url,
        httpHeaders: headers,
        cacheKey: 'abs_${id}_$cacheSize',
        key: ValueKey('abs_${id}_$cacheSize'),
        cacheManager: SafeImageCacheManager.instance,
        fit: BoxFit.cover,
        memCacheWidth: cacheSize,
        memCacheHeight: cacheSize,
        maxWidthDiskCache: cacheSize,
        maxHeightDiskCache: cacheSize,
        fadeInDuration: const Duration(milliseconds: 100),
        fadeOutDuration: Duration.zero,
        placeholder: (ctx, url) => _buildPlaceholder(isDark),
        errorWidget: (ctx, err, stack) => _buildPlaceholder(isDark),
      );
    }

    return Builder(
      builder: (context) {
        final imageUrl = _resolveSubsonicUrl(context, coverArt!, cacheSize);
        if (imageUrl.isEmpty) return _buildPlaceholder(isDark);
        return CachedNetworkImage(
          imageUrl: imageUrl,
          cacheKey: '${_serverSuffix}_${coverArt}_$cacheSize',
          key: ValueKey('${_serverSuffix}_${_trackSuffix}_${coverArt}_$cacheSize'),
          cacheManager: SafeImageCacheManager.instance,
          fit: BoxFit.cover,
          memCacheWidth: cacheSize,
          memCacheHeight: cacheSize,
          maxWidthDiskCache: cacheSize,
          maxHeightDiskCache: cacheSize,
          fadeInDuration: const Duration(milliseconds: 100),
          fadeOutDuration: Duration.zero,
          useOldImageOnUrlChange: false,
          placeholder: (ctx, url) => _buildPlaceholder(isDark),
          errorWidget: (ctx, err, stack) {
            debugPrint('AlbumArtwork error: $err');
            return _buildNetworkImageFallback(imageUrl, isDark, BoxFit.cover);
          },
        );
      },
    );
  }

  Widget _buildNetworkImageFallback(String url, bool isDark, BoxFit fit) {
    return Image.network(
      url,
      fit: fit,
      errorBuilder: (ctx, err, stack) {
        debugPrint('Network image fallback error: $err');
        return _buildPlaceholder(isDark);
      },
    );
  }

  Widget _buildPlaceholder(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [const Color(0xFF2A2A2A), const Color(0xFF1A1A1A)]
              : [Colors.grey.shade300, Colors.grey.shade200],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          size: (size / 3).clamp(16.0, 60.0),
          color: isDark ? Colors.white24 : Colors.black12,
        ),
      ),
    );
  }
}
