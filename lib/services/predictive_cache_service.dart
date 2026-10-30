import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';

/// Service for predictive caching of favorite tracks.
///
/// Analyzes listening patterns and automatically downloads tracks
/// that the user is likely to listen to next.
class PredictiveCacheService {
  static final PredictiveCacheService _instance = PredictiveCacheService._internal();
  factory PredictiveCacheService() => _instance;
  PredictiveCacheService._internal();

  static const _kEnabledKey = 'predictive_cache_enabled';
  static const _kAutoDownloadFavoritesKey = 'auto_download_favorites';
  static const _kMaxCacheSizeKey = 'predictive_cache_max_size_mb';
  static const _kLastAnalysisKey = 'predictive_cache_last_analysis';

  bool _isEnabled = false;
  bool _autoDownloadFavorites = true;
  int _maxCacheSizeMb = 500; // 500MB default
  DateTime? _lastAnalysis;
  Timer? _analysisTimer;

  bool get isEnabled => _isEnabled;
  bool get autoDownloadFavorites => _autoDownloadFavorites;
  int get maxCacheSizeMb => _maxCacheSizeMb;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool(_kEnabledKey) ?? false;
    _autoDownloadFavorites = prefs.getBool(_kAutoDownloadFavoritesKey) ?? true;
    _maxCacheSizeMb = prefs.getInt(_kMaxCacheSizeKey) ?? 500;
    final lastAnalysisMs = prefs.getInt(_kLastAnalysisKey);
    if (lastAnalysisMs != null) {
      _lastAnalysis = DateTime.fromMillisecondsSinceEpoch(lastAnalysisMs);
    }
  }

  /// Enable/disable predictive caching.
  Future<void> setEnabled(bool value) async {
    _isEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey, value);

    if (value) {
      _startPeriodicAnalysis();
    } else {
      _analysisTimer?.cancel();
    }
  }

  /// Enable/disable auto-download of favorites.
  Future<void> setAutoDownloadFavorites(bool value) async {
    _autoDownloadFavorites = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoDownloadFavoritesKey, value);
  }

  /// Set maximum cache size in MB.
  Future<void> setMaxCacheSize(int mb) async {
    _maxCacheSizeMb = mb;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kMaxCacheSizeKey, mb);
  }

  /// Start periodic analysis of listening patterns.
  void _startPeriodicAnalysis() {
    _analysisTimer?.cancel();
    // Analyze every 6 hours
    _analysisTimer = Timer.periodic(
      const Duration(hours: 6),
      (_) => analyzeAndCache(),
    );
  }

  /// Analyze listening patterns and cache predicted tracks.
  Future<List<Song>> analyzeAndCache({
    List<Song> allSongs = const [],
    List<Song> recentlyPlayed = const [],
    Map<String, double> artistAffinity = const {},
    Map<String, double> genreAffinity = const {},
    Set<String> starredSongs = const {},
  }) async {
    if (!_isEnabled) return [];

    debugPrint('[PredictiveCache] Starting analysis...');

    final predictions = <Song, double>{};

    for (final song in allSongs) {
      double score = 0;

      // Boost starred songs
      if (starredSongs.contains(song.id)) {
        score += 0.4;
      }

      // Boost by artist affinity
      if (song.artistId != null && artistAffinity.containsKey(song.artistId)) {
        score += (artistAffinity[song.artistId] ?? 0) * 0.3;
      }

      // Boost by genre affinity
      if (song.genre != null && genreAffinity.containsKey(song.genre)) {
        score += (genreAffinity[song.genre] ?? 0) * 0.2;
      }

      // Boost recently played artists
      final recentArtistIds = recentlyPlayed
          .where((s) => s.artistId != null)
          .map((s) => s.artistId!)
          .toSet();
      if (song.artistId != null && recentArtistIds.contains(song.artistId)) {
        score += 0.1;
      }

      // Boost songs not yet cached (to avoid re-downloading)
      // This would check offline status in real implementation

      if (score > 0.3) {
        predictions[song] = score;
      }
    }

    // Sort by score and take top predictions
    final sortedPredictions = predictions.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final topPredictions = sortedPredictions
        .take(50) // Max 50 tracks to cache
        .map((e) => e.key)
        .toList();

    debugPrint('[PredictiveCache] Found ${topPredictions.length} tracks to cache');

    // Update last analysis time
    _lastAnalysis = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLastAnalysisKey, _lastAnalysis!.millisecondsSinceEpoch);

    return topPredictions;
  }

  /// Get tracks that should be auto-downloaded (favorites).
  List<Song> getFavoritesToDownload({
    required List<Song> allSongs,
    required Set<String> starredSongs,
  }) {
    if (!_autoDownloadFavorites) return [];

    return allSongs
        .where((song) => starredSongs.contains(song.id))
        .toList();
  }

  /// Check if predictive caching should run now.
  bool shouldRunAnalysis() {
    if (!_isEnabled) return false;
    if (_lastAnalysis == null) return true;

    // Run if more than 6 hours since last analysis
    final hoursSinceLastAnalysis =
        DateTime.now().difference(_lastAnalysis!).inHours;
    return hoursSinceLastAnalysis >= 6;
  }

  /// Get cache statistics.
  Future<CacheStats> getStats() async {
    // Simplified stats - in real implementation, would query actual cache
    return CacheStats(
      cachedTracks: 0,
      cachedSizeMb: 0,
      maxSizeMb: _maxCacheSizeMb,
      lastAnalysis: _lastAnalysis,
      usagePercent: 0,
    );
  }

  void dispose() {
    _analysisTimer?.cancel();
  }
}

/// Cache statistics.
class CacheStats {
  final int cachedTracks;
  final int cachedSizeMb;
  final int maxSizeMb;
  final DateTime? lastAnalysis;
  final int usagePercent;

  CacheStats({
    required this.cachedTracks,
    required this.cachedSizeMb,
    required this.maxSizeMb,
    this.lastAnalysis,
    required this.usagePercent,
  });
}
