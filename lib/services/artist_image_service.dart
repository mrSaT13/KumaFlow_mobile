import 'dart:async';
import 'package:flutter/foundation.dart';
import 'safe_image_cache_manager.dart';
import 'yandex_music_public_api.dart' show YandexMusicPublicApi, ArtistInfo;
import 'subsonic_service.dart';

/// Service for loading artist images with priority (холодный старт first):
/// 1. Subsonic из кеша/сервера — показать СРАЗУ (быстро, работает офлайн)
/// 2. Yandex CDN в фоне — апгрейд качества когда догрузится
/// 3. Память 24ч + диск SafeImageCacheManager (7д/400)
class ArtistImageService {
  static const _cacheExpiry = Duration(hours: 24);

  final YandexMusicPublicApi _yandexApi;
  final SubsonicService _subsonic;

  // In-memory cache
  final Map<String, _CachedImage> _memoryCache = {};

  ArtistImageService({
    required YandexMusicPublicApi yandexApi,
    required SubsonicService subsonic,
  })  : _yandexApi = yandexApi,
        _subsonic = subsonic;

  // ──────────────────────────────────────────────────────────────────────────
  // Public API
  // ──────────────────────────────────────────────────────────────────────────

  /// Быстрый синхронный путь: Subsonic URL без сети.
  /// Возвращает '' если конфиг ещё не загружен (холодный старт) — НЕ кешировать.
  String getSubsonicUrlFast(String? subsonicCoverArtId, {int size = 300}) {
    if (subsonicCoverArtId == null || subsonicCoverArtId.isEmpty) return '';
    try {
      return _subsonic.getCoverArtUrl(subsonicCoverArtId, size: size);
    } catch (_) {
      return '';
    }
  }

  /// Get artist image URL with priority loading.
  /// Сначала Subsonic (мгновенно, офлайн), Yandex только если [allowNetwork].
  /// Найденный URL сразу греется на диск для следующего холодного старта.
  Future<String?> getArtistImage({
    required String artistName,
    String? artistId,
    String? subsonicCoverArtId,
    int size = 300,
    bool allowNetwork = true,
  }) async {
    final cacheKey = '${artistName.toLowerCase()}_$artistId';
    final cached = _memoryCache[cacheKey];
    if (cached != null && !cached.isExpired && cached.url.isNotEmpty) {
      // Фоново греем диск и пробуем апгрейд до Yandex если текущий — subsonic.
      if (cached.source == 'subsonic' && allowNetwork) {
        unawaited(_upgradeToYandexInBackground(cacheKey, artistName, artistId, size: size));
      }
      return cached.url;
    }

    // 1. Subsonic — мгновенно, без сети (пустой URL не кешируем).
    if (subsonicCoverArtId != null && subsonicCoverArtId.isNotEmpty) {
      final subsonicUrl = getSubsonicUrlFast(subsonicCoverArtId, size: size);
      if (subsonicUrl.isNotEmpty) {
        _memoryCache[cacheKey] = _CachedImage(
          url: subsonicUrl,
          source: 'subsonic',
          timestamp: DateTime.now(),
        );
        unawaited(_warmDiskCache(subsonicUrl));
        // Yandex-апгрейд в фоне, не блокируем UI.
        if (allowNetwork) {
          unawaited(_upgradeToYandexInBackground(cacheKey, artistName, artistId, size: size));
        }
        return subsonicUrl;
      }
    }

    // 2. Subsonic пуст (холодный старт, конфиг не готов) — пробуем Yandex
    // только если сеть разрешена (не офлайн).
    if (!allowNetwork) return null;
    final yandexUrl = await _getYandexBest(artistName, artistId, size: size);
    if (yandexUrl != null) {
      _memoryCache[cacheKey] = _CachedImage(
        url: yandexUrl,
        source: 'yandex',
        timestamp: DateTime.now(),
      );
      unawaited(_warmDiskCache(yandexUrl));
      return yandexUrl;
    }
    return null;
  }

  /// Прогрев списка: батчами по 8 через Future.wait, без Yandex в офлайне.
  Future<void> preloadArtistImages(
    List<ArtistInfo> artists, {
    bool allowNetwork = true,
  }) async {
    const batch = 8;
    for (var i = 0; i < artists.length; i += batch) {
      final chunk = artists.sublist(
        i,
        (i + batch).clamp(0, artists.length),
      );
      await Future.wait(
        chunk.map((artist) => getArtistImage(
              artistName: artist.name,
              artistId: artist.id,
              subsonicCoverArtId: artist.coverArtId,
              allowNetwork: allowNetwork,
            ).catchError((_) => null)),
      );
    }
  }

  /// Get multiple artist images in parallel.
  Future<Map<String, String?>> getArtistImagesBatch(
    List<ArtistInfo> artists, {
    bool allowNetwork = true,
  }) async {
    final results = <String, String?>{};
    const batch = 8;
    for (var i = 0; i < artists.length; i += batch) {
      final chunk = artists.sublist(
        i,
        (i + batch).clamp(0, artists.length),
      );
      await Future.wait(
        chunk.map((artist) async {
          try {
            final url = await getArtistImage(
              artistName: artist.name,
              artistId: artist.id,
              subsonicCoverArtId: artist.coverArtId,
              allowNetwork: allowNetwork,
            );
            results[artist.name] = url;
          } catch (_) {
            results[artist.name] = null;
          }
        }),
      );
    }
    return results;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Private methods
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _upgradeToYandexInBackground(
    String cacheKey,
    String artistName,
    String? artistId, {
    int size = 300,
  }) async {
    try {
      final yandexUrl = await _getYandexBest(artistName, artistId, size: size);
      if (yandexUrl == null || yandexUrl.isEmpty) return;
      final cur = _memoryCache[cacheKey];
      if (cur != null && cur.url == yandexUrl) return;
      _memoryCache[cacheKey] = _CachedImage(
        url: yandexUrl,
        source: 'yandex',
        timestamp: DateTime.now(),
      );
      await _warmDiskCache(yandexUrl);
    } catch (_) {}
  }

  Future<String?> _getYandexBest(String artistName, String? artistId, {int size = 300}) async {
    if (artistId != null && artistId.isNotEmpty) {
      final byId = await _getYandexArtistImage(artistId, size: size);
      if (byId != null) return byId;
    }
    return _getYandexImageBySearch(artistName, size: size);
  }

  Future<void> _warmDiskCache(String url) async {
    if (url.isEmpty) return;
    try {
      await SafeImageCacheManager.instance.downloadFile(url);
    } catch (_) {}
  }

  Future<String?> _getYandexArtistImage(String artistId, {int size = 300}) async {
    try {
      final info = await _yandexApi.getArtistInfo(artistId);
      if (info == null) return null;

      // Try artist cover
      final artist = info['artist'] as Map<String, dynamic>?;
      if (artist != null) {
        final cover = artist['cover'] as Map<String, dynamic>?;
        final url = _yandexApi.extractCoverUrl(cover);
        if (url != null) return url;
      }

      // Try allCovers
      final allCovers = info['allCovers'] as List?;
      if (allCovers != null && allCovers.isNotEmpty) {
        final firstCover = allCovers.first as Map<String, dynamic>?;
        final uri = firstCover?['uri'] as String?;
        if (uri != null) return _yandexApi.getCoverUrl(uri, size: size);
      }

      return null;
    } catch (e) {
      debugPrint('[ArtistImageService] Yandex artist image error: $e');
      return null;
    }
  }

  Future<String?> _getYandexImageBySearch(String artistName, {int size = 300}) async {
    try {
      final results = await _yandexApi.searchArtists(artistName, limit: 1);
      if (results.isEmpty) return null;

      final firstResult = results.first;
      final cover = firstResult['cover'] as Map<String, dynamic>?;
      return _yandexApi.extractCoverUrl(cover);
    } catch (e) {
      debugPrint('[ArtistImageService] Yandex search image error: $e');
      return null;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Cache management
  // ──────────────────────────────────────────────────────────────────────────

  /// Clear all cached images.
  void clearCache() {
    _memoryCache.clear();
  }

  /// Clear expired cache entries.
  void clearExpiredCache() {
    _memoryCache.removeWhere((key, value) => value.isExpired);
  }

  /// Get cache statistics.
  Map<String, dynamic> getCacheStats() {
    final sources = <String, int>{};
    for (final entry in _memoryCache.values) {
      sources[entry.source] = (sources[entry.source] ?? 0) + 1;
    }
    return {
      'total': _memoryCache.length,
      'sources': sources,
    };
  }
}

/// Cached image entry.
class _CachedImage {
  final String url;
  final String source;
  final DateTime timestamp;

  _CachedImage({
    required this.url,
    required this.source,
    required this.timestamp,
  });

  bool get isExpired => DateTime.now().difference(timestamp) > ArtistImageService._cacheExpiry;
}
