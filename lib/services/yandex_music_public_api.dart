import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Public Yandex Music API — works WITHOUT authentication.
///
/// Endpoints that don't require OAuth token:
/// - Search (artists, albums, tracks)
/// - Artist info (brief-info, top tracks)
/// - Track info (similar tracks, lyrics, supplement)
/// - Cover art from Yandex CDN
/// - Landing page (new releases, mixes)
/// - Genres
class YandexMusicPublicApi {
  static const _baseUrl = 'https://api.music.yandex.net';
  static const _coverBaseUrl = 'https://avatars.yandex.net';

  final Dio _dio;
  DateTime? _lastRequest;
  static const int _minIntervalMs = 450;

  YandexMusicPublicApi({Dio? dio})
      : _dio = dio ?? Dio() {
    _dio.options.headers['User-Agent'] = 'KumaFlow/3.1';
    _dio.options.headers['Accept'] = 'application/json';
    _dio.options.connectTimeout = const Duration(seconds: 10);
    _dio.options.receiveTimeout = const Duration(seconds: 10);
  }

  Future<void> _throttle() async {
    if (_lastRequest != null) {
      final elapsed = DateTime.now().difference(_lastRequest!).inMilliseconds;
      if (elapsed < _minIntervalMs) {
        await Future.delayed(Duration(milliseconds: _minIntervalMs - elapsed));
      }
    }
    _lastRequest = DateTime.now();
  }

  // 429 handling: exponential backoff with jitter, respects Retry-After, max 3 attempts
  Future<Response<T>> _getWithRetry<T>(String path, {Map<String, dynamic>? queryParameters}) async {
    int attempts = 0;
    final rnd = Random();
    while (true) {
      try {
        await _throttle();
        return await _dio.get<T>(path, queryParameters: queryParameters);
      } on DioException catch (e) {
        final code = e.response?.statusCode;
        if (code == 429 && attempts < 3) {
          attempts++;
          int delayMs;
          final retryAfter = e.response?.headers.value('Retry-After') ?? e.response?.headers.value('retry-after');
          if (retryAfter != null) {
            final secs = int.tryParse(retryAfter.trim());
            if (secs != null) {
              delayMs = secs * 1000 + rnd.nextInt(400);
            } else {
              delayMs = 1200 * (1 << (attempts - 1)) + rnd.nextInt(500);
            }
          } else {
            delayMs = 1200 * (1 << (attempts - 1)) + rnd.nextInt(500); // 1200,2400,4800
          }
          if (delayMs > 10000) delayMs = 10000;
          debugPrint('[YandexPublicAPI] 429 rate limited, retry $attempts/3 after ${delayMs}ms for $path');
          await Future.delayed(Duration(milliseconds: delayMs));
          continue;
        }
        rethrow;
      }
    }
  }

  Future<List<Map<String, dynamic>>> _safeGetList(String path, Map<String, dynamic>? params, String listKey, String subKey) async {
    // wrapper unused, kept for future
    return [];
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Cover Art
  // ──────────────────────────────────────────────────────────────────────────

  /// Build cover URL from Yandex Music URI.
  /// Format: "get-music/xxx/yyy/zzz" → "https://avatars.yandex.net/get-music/xxx/yyy/zzz?size=300"
  String? getCoverUrl(String uri, {int size = 300}) {
    if (uri.isEmpty) return null;
    if (uri.startsWith('http')) return '$uri?size=$size';
    return '$_coverBaseUrl/$uri?size=$size';
  }

  /// Build artist cover URL from cover spec.
  String? getArtistCoverUrl(Map<String, dynamic>? cover, {String size = '300x300'}) {
    if (cover == null) return null;
    final uri = cover['uri'] as String?;
    if (uri == null) return null;
    return getCoverUrl(uri, size: 200);
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Search — No auth required
  // ──────────────────────────────────────────────────────────────────────────

  /// Search for artists. No token required.
  Future<List<Map<String, dynamic>>> searchArtists(String query, {int limit = 10}) async {
    try {
      final response = await _getWithRetry(
        '$_baseUrl/search',
        queryParameters: {
          'text': query,
          'type': 'artist',
          'page': 0,
          'nocorrect': false,
        },
      );

      final result = response.data['result'];
      if (result == null) return [];

      final artistsResult = result['artists'];
      if (artistsResult == null) return [];

      final results = artistsResult['results'] as List? ?? [];
      return results.take(limit).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexPublicAPI] Search artists error: $e');
      return [];
    }
  }

  /// Search for albums. No token required.
  Future<List<Map<String, dynamic>>> searchAlbums(String query, {int limit = 10}) async {
    try {
      final response = await _getWithRetry(
        '$_baseUrl/search',
        queryParameters: {
          'text': query,
          'type': 'album',
          'page': 0,
          'nocorrect': false,
        },
      );

      final result = response.data['result'];
      if (result == null) return [];

      final albumsResult = result['albums'];
      if (albumsResult == null) return [];

      final results = albumsResult['results'] as List? ?? [];
      return results.take(limit).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexPublicAPI] Search albums error: $e');
      return [];
    }
  }

  /// Search for tracks. No token required.
  Future<List<Map<String, dynamic>>> searchTracks(String query, {int limit = 10}) async {
    try {
      final response = await _getWithRetry(
        '$_baseUrl/search',
        queryParameters: {
          'text': query,
          'type': 'track',
          'page': 0,
        },
      );

      final result = response.data['result'];
      if (result == null) return [];

      final tracksResult = result['tracks'];
      if (tracksResult == null) return [];

      final results = tracksResult['results'] as List? ?? [];
      return results.take(limit).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexPublicAPI] Search tracks error: $e');
      return [];
    }
  }

  /// Search for all types at once. No token required.
  Future<Map<String, List<Map<String, dynamic>>>> searchAll(String query) async {
    try {
      final response = await _getWithRetry(
        '$_baseUrl/search',
        queryParameters: {
          'text': query,
          'page': 0,
        },
      );

      final result = response.data['result'];
      if (result == null) return {'artists': [], 'albums': [], 'tracks': []};

      return {
        'artists': ((result['artists']?['results'] as List?) ?? []).cast<Map<String, dynamic>>(),
        'albums': ((result['albums']?['results'] as List?) ?? []).cast<Map<String, dynamic>>(),
        'tracks': ((result['tracks']?['results'] as List?) ?? []).cast<Map<String, dynamic>>(),
      };
    } catch (e) {
      debugPrint('[YandexPublicAPI] Search all error: $e');
      return {'artists': [], 'albums': [], 'tracks': []};
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Artist Info — No auth required
  // ──────────────────────────────────────────────────────────────────────────

  /// Get artist brief info (covers, similar artists, genres).
  Future<Map<String, dynamic>?> getArtistInfo(String artistId) async {
    try {
      final response = await _getWithRetry(
        '$_baseUrl/artists/$artistId/brief-info',
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexPublicAPI] Artist info error: $e');
      return null;
    }
  }

  /// Get artist's top tracks. No token required.
  Future<List<Map<String, dynamic>>> getArtistTopTracks(String artistId, {int limit = 10}) async {
    try {
      final response = await _getWithRetry(
        '$_baseUrl/artists/$artistId/top-tracks',
        queryParameters: {'chart': 'all-time'},
      );

      final result = response.data['result'];
      if (result == null) return [];

      final tracks = result['tracks'] as List? ?? [];
      return tracks.take(limit).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexPublicAPI] Artist top tracks error: $e');
      return [];
    }
  }

  /// Get similar artists. No token required.
  Future<List<Map<String, dynamic>>> getSimilarArtists(String artistId, {int limit = 10}) async {
    try {
      final info = await getArtistInfo(artistId);
      if (info == null) return [];

      final similar = info['similarArtists'] as List? ?? [];
      return similar.take(limit).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexPublicAPI] Similar artists error: $e');
      return [];
    }
  }

  /// Get artist albums. No token required.
  Future<List<Map<String, dynamic>>> getArtistAlbums(String artistId, {int limit = 10}) async {
    try {
      final response = await _getWithRetry(
        '$_baseUrl/artists/$artistId/direct-albums',
        queryParameters: {
          'page': 0,
          'page-size': limit,
          'sort-by': 'year',
        },
      );

      final result = response.data['result'];
      if (result == null) return [];

      final albums = result['albums'] as List? ?? [];
      return albums.cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexPublicAPI] Artist albums error: $e');
      return [];
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Track Info — No auth required
  // ──────────────────────────────────────────────────────────────────────────

  /// Get similar tracks. No token required.
  Future<List<Map<String, dynamic>>> getSimilarTracks(String trackId, {int limit = 10}) async {
    try {
      final response = await _getWithRetry(
        '$_baseUrl/tracks/$trackId/similar',
      );

      final result = response.data['result'];
      if (result == null) return [];

      final similar = result['similarTracks'] as List? ?? [];
      return similar.take(limit).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexPublicAPI] Similar tracks error: $e');
      return [];
    }
  }

  /// Get track lyrics. No token required.
  Future<Map<String, dynamic>?> getTrackLyrics(String trackId) async {
    try {
      final response = await _getWithRetry(
        '$_baseUrl/tracks/$trackId/lyrics',
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexPublicAPI] Track lyrics error: $e');
      return null;
    }
  }

  /// Get track supplement (extra info). No token required.
  Future<Map<String, dynamic>?> getTrackSupplement(String trackId) async {
    try {
      final response = await _getWithRetry(
        '$_baseUrl/tracks/$trackId/supplement',
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexPublicAPI] Track supplement error: $e');
      return null;
    }
  }

  /// Get track by ID. No token required.
  Future<Map<String, dynamic>?> getTrack(String trackId) async {
    try {
      final response = await _getWithRetry(
        '$_baseUrl/tracks',
        queryParameters: {
          'track-ids': trackId,
          'with-positions': true,
        },
      );

      final result = response.data['result'];
      if (result == null) return null;

      final tracks = result as List? ?? [];
      if (tracks.isEmpty) return null;

      return tracks.first as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexPublicAPI] Get track error: $e');
      return null;
    }
  }

  /// Get tracks by IDs. No token required.
  Future<List<Map<String, dynamic>>> getTracks(List<String> trackIds) async {
    if (trackIds.isEmpty) return [];
    try {
      final response = await _dio.post(
        '$_baseUrl/tracks',
        data: {'track-ids': trackIds},
        queryParameters: {'with-positions': true},
      );

      final result = response.data['result'];
      if (result == null) return [];

      return (result as List? ?? []).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexPublicAPI] Get tracks error: $e');
      return [];
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Album Info — No auth required
  // ──────────────────────────────────────────────────────────────────────────

  /// Get album info with tracks. No token required.
  Future<Map<String, dynamic>?> getAlbumInfo(String albumId) async {
    try {
      final response = await _getWithRetry(
        '$_baseUrl/albums/$albumId/with-tracks',
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexPublicAPI] Album info error: $e');
      return null;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Landing — No auth required
  // ──────────────────────────────────────────────────────────────────────────

  /// Get landing page (new releases, mixes, charts).
  Future<Map<String, dynamic>?> getLanding() async {
    try {
      final response = await _dio.post(
        '$_baseUrl/landing3',
        data: {
          'catalogue': 'music',
          'genre': 'all',
          'language': 'ru',
        },
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexPublicAPI] Landing error: $e');
      return null;
    }
  }

  /// Get new releases. No token required.
  Future<List<Map<String, dynamic>>> getNewReleases() async {
    try {
      final response = await _getWithRetry('$_baseUrl/landing3/new-releases');
      final result = response.data['result'];
      if (result == null) return [];

      final albums = result['albums'] as List? ?? [];
      return albums.cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexPublicAPI] New releases error: $e');
      return [];
    }
  }

  /// Get editorial playlists. No token required.
  Future<List<Map<String, dynamic>>> getEditorialPlaylists() async {
    try {
      final response = await _getWithRetry('$_baseUrl/editorial/categories');
      final result = response.data['result'];
      if (result == null) return [];

      final categories = result['categories'] as List? ?? [];
      return categories.cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexPublicAPI] Editorial playlists error: $e');
      return [];
    }
  }

  /// Get genres. No token required.
  Future<List<Map<String, dynamic>>> getGenres() async {
    try {
      final response = await _getWithRetry('$_baseUrl/genres');
      final result = response.data['result'];
      if (result == null) return [];

      final genres = result['genres'] as List? ?? [];
      return genres.cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexPublicAPI] Genres error: $e');
      return [];
    }
  }

  /// Search videos (clips). No token required. Marshal: client.search(text, type='video')
  Future<List<Map<String, dynamic>>> searchVideos(String query, {int limit = 20}) async {
    try {
      final response = await _getWithRetry(
        '$_baseUrl/search',
        queryParameters: {'text': query, 'type': 'video', 'page': 0, 'pageSize': limit},
      );
      final result = response.data['result'];
      if (result == null) return [];
      final videosResult = result['videos'];
      if (videosResult == null) return [];
      final results = videosResult['results'] as List? ?? [];
      // Fallback: some API returns videos directly in result
      if (results.isEmpty) {
        final alt = result['videos'] as List? ?? [];
        return alt.take(limit).cast<Map<String, dynamic>>().toList();
      }
      return results.take(limit).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexPublicAPI] Search videos error: $e');
      return [];
    }
  }

  /// Get artist videos via brief-info + search fallback (for clips лента).
  Future<List<Map<String, dynamic>>> getArtistVideosByName(String artistName, {int limit = 20}) async {
    // Try search videos first — richer clips
    final searched = await searchVideos(artistName, limit: limit);
    if (searched.isNotEmpty) return searched;
    // Fallback to brief-info for that artist
    try {
      final artists = await searchArtists(artistName, limit: 1);
      if (artists.isEmpty) return [];
      final id = artists.first['id']?.toString();
      if (id == null) return [];
      final info = await getArtistInfo(id);
      if (info == null) return [];
      final videos = info['videos'] as List? ?? [];
      return videos.take(limit).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexPublicAPI] Artist videos fallback error: $e');
      return [];
    }
  }

  /// Get playlists by tag. No token required.
  Future<List<Map<String, dynamic>>> getPlaylistsByTag(String tagId, {int limit = 20}) async {
    try {
      final response = await _getWithRetry(
        '$_baseUrl/tags/$tagId/playlist-ids',
        queryParameters: {'limit': limit},
      );
      final result = response.data['result'];
      if (result == null) return [];

      final playlistIds = result['playlistIds'] as List? ?? [];
      return playlistIds.cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexPublicAPI] Playlists by tag error: $e');
      return [];
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Charts — No auth required
  // ──────────────────────────────────────────────────────────────────────────

  /// Get chart playlist. No token required.
  Future<Map<String, dynamic>?> getChart({String chartId = 'main'}) async {
    try {
      final response = await _getWithRetry(
        '$_baseUrl/landing3/chart/$chartId',
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexPublicAPI] Chart error: $e');
      return null;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Helpers
  // ──────────────────────────────────────────────────────────────────────────

  /// Extract artist cover URL from various response formats.
  String? extractCoverUrl(dynamic coverData) {
    if (coverData == null) return null;

    if (coverData is String) {
      return getCoverUrl(coverData);
    }

    if (coverData is Map<String, dynamic>) {
      final uri = coverData['uri'] as String?;
      if (uri != null) return getCoverUrl(uri);

      // Try small/mini/default sizes
      final small = coverData['small'] as String?;
      if (small != null) return getCoverUrl(small);

      final mini = coverData['mini'] as String?;
      if (mini != null) return getCoverUrl(mini);

      final defaultCover = coverData['default'] as String?;
      if (defaultCover != null) return getCoverUrl(defaultCover);
    }

    return null;
  }

  /// Extract track cover URL.
  String? extractTrackCoverUrl(Map<String, dynamic>? trackData) {
    if (trackData == null) return null;

    // Try cover200/cover400/cover1200
    for (final size in ['cover1200', 'cover400', 'cover200']) {
      final uri = trackData[size] as String?;
      if (uri != null && uri.isNotEmpty) return getCoverUrl(uri);
    }

    // Try album cover
    final album = trackData['albums'] as List?;
    if (album != null && album.isNotEmpty) {
      final firstAlbum = album.first as Map<String, dynamic>?;
      if (firstAlbum != null) {
        final coverUri = firstAlbum['coverUri'] as String?;
        if (coverUri != null) return getCoverUrl(coverUri);
      }
    }

    return null;
  }

  /// Extract artist ID from track data.
  String? extractArtistId(Map<String, dynamic>? trackData) {
    if (trackData == null) return null;

    final artists = trackData['artists'] as List?;
    if (artists != null && artists.isNotEmpty) {
      final firstArtist = artists.first as Map<String, dynamic>?;
      return firstArtist?['id']?.toString();
    }

    return null;
  }

  /// Extract artist name from track data.
  String? extractArtistName(Map<String, dynamic>? trackData) {
    if (trackData == null) return null;

    final artists = trackData['artists'] as List?;
    if (artists != null && artists.isNotEmpty) {
      final firstArtist = artists.first as Map<String, dynamic>?;
      return firstArtist?['name'] as String?;
    }

    return null;
  }
}

/// Artist info for batch loading.
class ArtistInfo {
  final String name;
  final String? id;
  final String? coverArtId;

  const ArtistInfo({
    required this.name,
    this.id,
    this.coverArtId,
  });
}
