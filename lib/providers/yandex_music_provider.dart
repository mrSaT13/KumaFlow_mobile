import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import '../services/yandex_music_service.dart';

/// Provider for Yandex Music integration.
///
/// Manages fetching and caching of related content from Yandex Music API.
/// Supports OAuth token for authenticated requests.
class YandexMusicProvider extends ChangeNotifier {
  static const _kTokenKey = 'yandex_music_oauth_token';
  static const _kEnabledKey = 'yandex_music_enabled';

  final YandexMusicService _service;

  // Cache
  final Map<String, List<RelatedAlbumMatch>> _relatedAlbumsCache = {};
  final Map<String, List<RelatedArtistMatch>> _relatedArtistsCache = {};
  final Map<String, YandexArtistResult?> _artistInfoCache = {};
  YandexRecommendationResult? _enhancedRecommendations;

  bool _isLoading = false;
  String? _lastError;
  bool _isEnabled = true;
  String? _oauthToken;

  YandexMusicProvider({YandexMusicService? service})
      : _service = service ?? YandexMusicService() {
    _loadSettings();
  }

  bool get isLoading => _isLoading;
  bool get isEnabled => _isEnabled;
  String? get lastError => _lastError;
  String? get oauthToken => _oauthToken;
  bool get hasToken => _oauthToken != null && _oauthToken!.isNotEmpty;

  YandexRecommendationResult? get enhancedRecommendations =>
      _enhancedRecommendations;

  // ──────────────────────────────────────────────────────────────────────────
  // Settings
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool(_kEnabledKey) ?? true;
    // Совместимость с десктопом и UnifiedMusicAuth: проверяем все ключи
    _oauthToken = prefs.getString(_kTokenKey) ??
        prefs.getString('yandex_oauth_token') ??
        prefs.getString('ym_access_token') ??
        prefs.getString('yandex_music_token');

    if (_oauthToken != null && _oauthToken!.isNotEmpty) {
      _service.setToken(_oauthToken!);
    } else {
      // Попробуем взять токен из UnifiedMusicAuth если есть
      final alt = prefs.getString('yandex_oauth_token');
      if (alt != null && alt.isNotEmpty) {
        _oauthToken = alt;
        _service.setToken(alt);
      }
    }

    notifyListeners();
  }

  /// Set OAuth token for Yandex Music API. Синхронизирует все ключи.
  Future<void> setOAuthToken(String token) async {
    _oauthToken = token.trim();
    if (_oauthToken!.isNotEmpty) {
      _service.setToken(_oauthToken!);
    } else {
      _oauthToken = null;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTokenKey, _oauthToken ?? '');
    // Синхронизация для совместимости с UnifiedMusicAuth и YandexMusicApi (десктоп)
    await prefs.setString('yandex_oauth_token', _oauthToken ?? '');
    await prefs.setString('ym_access_token', _oauthToken ?? '');
    await prefs.setString('yandex_music_token', _oauthToken ?? '');

    clearCache();
    notifyListeners();
  }

  /// Enable/disable Yandex Music integration.
  Future<void> setEnabled(bool value) async {
    _isEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey, value);
    notifyListeners();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Public API
  // ──────────────────────────────────────────────────────────────────────────

  /// Get related albums for an artist, matching with local library.
  Future<List<RelatedAlbumMatch>> getRelatedAlbums({
    required String artistName,
    required List<Album> localAlbums,
    int limit = 10,
  }) async {
    if (!_isEnabled) return [];

    final cacheKey = '${artistName.toLowerCase()}_${localAlbums.length}';

    if (_relatedAlbumsCache.containsKey(cacheKey)) {
      return _relatedAlbumsCache[cacheKey]!;
    }

    _isLoading = true;
    _lastError = null;
    notifyListeners();

    try {
      final matches = await _service.findRelatedAlbums(
        artistName: artistName,
        localAlbums: localAlbums,
        limit: limit,
      );

      _relatedAlbumsCache[cacheKey] = matches;
      _isLoading = false;
      notifyListeners();

      return matches;
    } catch (e) {
      _lastError = e.toString();
      _isLoading = false;
      notifyListeners();
      return [];
    }
  }

  /// Get related artists for an artist, matching with local library.
  Future<List<RelatedArtistMatch>> getRelatedArtists({
    required String artistName,
    required List<Artist> localArtists,
    int limit = 10,
  }) async {
    if (!_isEnabled) return [];

    final cacheKey = '${artistName.toLowerCase()}_${localArtists.length}';

    if (_relatedArtistsCache.containsKey(cacheKey)) {
      return _relatedArtistsCache[cacheKey]!;
    }

    _isLoading = true;
    _lastError = null;
    notifyListeners();

    try {
      final matches = await _service.findRelatedArtists(
        artistName: artistName,
        localArtists: localArtists,
        limit: limit,
      );

      _relatedArtistsCache[cacheKey] = matches;
      _isLoading = false;
      notifyListeners();

      return matches;
    } catch (e) {
      _lastError = e.toString();
      _isLoading = false;
      notifyListeners();
      return [];
    }
  }

  /// Get enhanced recommendations combining YM data with local library.
  Future<YandexRecommendationResult?> getEnhancedRecommendations({
    required List<Song> localSongs,
    required List<Artist> localArtists,
    required List<Album> localAlbums,
  }) async {
    if (!_isEnabled) return null;

    if (_enhancedRecommendations != null) {
      return _enhancedRecommendations;
    }

    _isLoading = true;
    _lastError = null;
    notifyListeners();

    try {
      _enhancedRecommendations = await _service.getEnhancedRecommendations(
        localSongs: localSongs,
        localArtists: localArtists,
        localAlbums: localAlbums,
      );

      _isLoading = false;
      notifyListeners();

      return _enhancedRecommendations;
    } catch (e) {
      _lastError = e.toString();
      _isLoading = false;
      notifyListeners();
      return null;
    }
  }

  /// Get artist info from Yandex Music (with cover URL and derived colors).
  Future<YandexArtistResult?> getArtistInfo(String artistId) async {
    if (!_isEnabled) return null;

    if (_artistInfoCache.containsKey(artistId)) {
      return _artistInfoCache[artistId];
    }

    final info = await _service.getArtistInfo(artistId);
    _artistInfoCache[artistId] = info;
    return info;
  }

  /// Get cover URL for an album from Yandex Music CDN.
  static String? getAlbumCoverUrl(String? coverUri, {String size = '200x200'}) {
    return YandexMusicService.getCoverUrl(coverUri, size: size);
  }

  /// Get derived colors for dynamic theming.
  YandexDerivedColors? getDerivedColors(String albumId) {
    return _enhancedRecommendations?.albumColors[albumId];
  }

  /// Search for artists on Yandex Music.
  Future<List<YandexArtistResult>> searchArtists(String query) async {
    if (!_isEnabled) return [];
    return _service.searchArtists(query);
  }

  /// Search for albums on Yandex Music.
  Future<List<YandexAlbumResult>> searchAlbums(String query) async {
    if (!_isEnabled) return [];
    return _service.searchAlbums(query);
  }

  /// Get similar artists from Yandex Music.
  Future<List<YandexArtistResult>> getSimilarArtists(String artistId) async {
    if (!_isEnabled) return [];
    return _service.getSimilarArtists(artistId);
  }

  /// Clear all cached data.
  void clearCache() {
    _relatedAlbumsCache.clear();
    _relatedArtistsCache.clear();
    _artistInfoCache.clear();
    _enhancedRecommendations = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }
}
