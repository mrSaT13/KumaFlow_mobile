import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for local listening analytics.
///
/// Tracks and analyzes listening patterns without external services.
class LocalAnalyticsService {
  static final LocalAnalyticsService _instance = LocalAnalyticsService._internal();
  factory LocalAnalyticsService() => _instance;
  LocalAnalyticsService._internal();

  static const _kEnabledKey = 'local_analytics_enabled';
  static const _kListeningHistoryKey = 'analytics_listening_history';
  static const _kDailyStatsKey = 'analytics_daily_stats';
  static const _kArtistStatsKey = 'analytics_artist_stats';
  static const _kGenreStatsKey = 'analytics_genre_stats';

  bool _isEnabled = true;
  List<ListeningEvent> _listeningHistory = [];
  Map<String, DailyStats> _dailyStats = {};
  Map<String, ArtistStats> _artistStats = {};
  Map<String, GenreStats> _genreStats = {};
  // Троттлинг диска: _saveData не чаще раза в 30с, иначе fsync-шторм/ANR
  // на каждое прослушивание (было: полный JSON 10k событий каждый раз).
  int _lastSaveMs = 0;
  bool _saveScheduled = false;
  static const _saveThrottleMs = 30000;
  static const _maxHistory = 2000;

  bool get isEnabled => _isEnabled;
  List<ListeningEvent> get listeningHistory => List.unmodifiable(_listeningHistory);

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool(_kEnabledKey) ?? true;
    await _loadData();
  }

  Future<void> setEnabled(bool value) async {
    _isEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey, value);
  }

  /// Record a listening event.
  Future<void> recordListen({
    required String songId,
    required String songTitle,
    String? artistId,
    String? artistName,
    String? albumId,
    String? albumTitle,
    String? genre,
    required int durationMs,
    required bool completed,
  }) async {
    if (!_isEnabled) return;

    final event = ListeningEvent(
      songId: songId,
      songTitle: songTitle,
      artistId: artistId,
      artistName: artistName,
      albumId: albumId,
      albumTitle: albumTitle,
      genre: genre,
      durationMs: durationMs,
      completed: completed,
      timestamp: DateTime.now(),
    );

    _listeningHistory.add(event);

    // Keep only last [_maxHistory] events (было 10000 — тяжело для префсов)
    if (_listeningHistory.length > _maxHistory) {
      _listeningHistory = _listeningHistory.sublist(_listeningHistory.length - _maxHistory);
    }

    // Update daily stats
    final today = DateTime.now().toIso8601String().split('T')[0];
    _dailyStats.putIfAbsent(today, () => DailyStats(date: today));
    _dailyStats[today]!.totalListens++;
    _dailyStats[today]!.totalDurationMs += durationMs;
    if (completed) _dailyStats[today]!.completedListens++;

    // Update artist stats
    if (artistId != null) {
      _artistStats.putIfAbsent(artistId, () => ArtistStats(
        artistId: artistId,
        artistName: artistName ?? 'Unknown',
      ));
      _artistStats[artistId]!.listenCount++;
      _artistStats[artistId]!.totalDurationMs += durationMs;
      _artistStats[artistId]!.lastPlayed = DateTime.now();
    }

    // Update genre stats
    if (genre != null) {
      _genreStats.putIfAbsent(genre, () => GenreStats(genre: genre));
      _genreStats[genre]!.listenCount++;
      _genreStats[genre]!.totalDurationMs += durationMs;
    }

    _saveThrottled();
  }

  /// Запись на диск не чаще раза в 30с (trailing): следующие вызовы за окном
  /// планируют один отложенный сейв вместо шторма fsync на каждый трек.
  void _saveThrottled() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSaveMs >= _saveThrottleMs && !_saveScheduled) {
      _lastSaveMs = now;
      unawaited(_saveData());
      return;
    }
    if (_saveScheduled) return;
    _saveScheduled = true;
    final delay = (_saveThrottleMs - (now - _lastSaveMs)).clamp(1000, _saveThrottleMs);
    Future.delayed(Duration(milliseconds: delay), () async {
      _saveScheduled = false;
      _lastSaveMs = DateTime.now().millisecondsSinceEpoch;
      try {
        await _saveData();
      } catch (e) {
        debugPrint('[LocalAnalytics] throttled save error: $e');
      }
    });
  }

  /// Принудительный сейв (выход из приложения, очистка).
  Future<void> flush() async {
    _lastSaveMs = DateTime.now().millisecondsSinceEpoch;
    await _saveData();
  }

  /// Get listening statistics for a date range.
  ListeningStats getStats({DateTime? from, DateTime? to}) {
    from ??= DateTime.now().subtract(const Duration(days: 30));
    to ??= DateTime.now();

    final filteredHistory = _listeningHistory.where((e) =>
        e.timestamp.isAfter(from!) && e.timestamp.isBefore(to!)).toList();

    final totalListens = filteredHistory.length;
    final totalDurationMs = filteredHistory.fold<int>(0, (sum, e) => sum + e.durationMs);
    final completedListens = filteredHistory.where((e) => e.completed).length;

    // Top artists
    final artistCounts = <String, int>{};
    for (final event in filteredHistory) {
      if (event.artistId != null) {
        artistCounts[event.artistId!] = (artistCounts[event.artistId!] ?? 0) + 1;
      }
    }
    final topArtists = artistCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // Top genres
    final genreCounts = <String, int>{};
    for (final event in filteredHistory) {
      if (event.genre != null) {
        genreCounts[event.genre!] = (genreCounts[event.genre!] ?? 0) + 1;
      }
    }
    final topGenres = genreCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // Listening by hour
    final hourlyListens = List<int>.filled(24, 0);
    for (final event in filteredHistory) {
      hourlyListens[event.timestamp.hour]++;
    }

    return ListeningStats(
      totalListens: totalListens,
      totalDurationMs: totalDurationMs,
      completedListens: completedListens,
      uniqueArtists: artistCounts.length,
      uniqueGenres: genreCounts.length,
      topArtists: topArtists.take(10).map((e) => (
        name: _artistStats[e.key]?.artistName ?? 'Unknown',
        count: e.value,
      )).toList(),
      topGenres: topGenres.take(10).map((e) => (
        name: e.key,
        count: e.value,
      )).toList(),
      hourlyListens: hourlyListens,
    );
  }

  /// Get daily listening summary for charts.
  List<DailyStats> getDailyStats({int days = 30}) {
    final now = DateTime.now();
    final stats = <DailyStats>[];

    for (int i = days - 1; i >= 0; i--) {
      final date = now.subtract(Duration(days: i));
      final dateStr = date.toIso8601String().split('T')[0];
      stats.add(_dailyStats[dateStr] ?? DailyStats(date: dateStr));
    }

    return stats;
  }

  /// Get top artists.
  List<ArtistStats> getTopArtists({int limit = 10}) {
    final sorted = _artistStats.values.toList()
      ..sort((a, b) => b.listenCount.compareTo(a.listenCount));
    return sorted.take(limit).toList();
  }

  /// Get listening streak (consecutive days).
  int getListeningStreak() {
    final now = DateTime.now();
    int streak = 0;
    DateTime currentDate = DateTime(now.year, now.month, now.day);

    while (true) {
      final dateStr = currentDate.toIso8601String().split('T')[0];
      final stats = _dailyStats[dateStr];

      if (stats != null && stats.totalListens > 0) {
        streak++;
        currentDate = currentDate.subtract(const Duration(days: 1));
      } else {
        break;
      }
    }

    return streak;
  }

  /// Export analytics data as JSON.
  String exportData() {
    return jsonEncode({
      'listening_history': _listeningHistory.map((e) => e.toJson()).toList(),
      'daily_stats': _dailyStats.map((k, v) => MapEntry(k, v.toJson())),
      'artist_stats': _artistStats.map((k, v) => MapEntry(k, v.toJson())),
      'genre_stats': _genreStats.map((k, v) => MapEntry(k, v.toJson())),
    });
  }

  /// Clear all analytics data.
  Future<void> clearAll() async {
    _listeningHistory.clear();
    _dailyStats.clear();
    _artistStats.clear();
    _genreStats.clear();
    await _saveData();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Persistence
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();

    final historyJson = prefs.getString(_kListeningHistoryKey);
    if (historyJson != null) {
      final list = jsonDecode(historyJson) as List;
      _listeningHistory = list.map((e) => ListeningEvent.fromJson(e)).toList();
    }

    final dailyJson = prefs.getString(_kDailyStatsKey);
    if (dailyJson != null) {
      final map = jsonDecode(dailyJson) as Map<String, dynamic>;
      _dailyStats = map.map((k, v) => MapEntry(k, DailyStats.fromJson(v)));
    }

    final artistJson = prefs.getString(_kArtistStatsKey);
    if (artistJson != null) {
      final map = jsonDecode(artistJson) as Map<String, dynamic>;
      _artistStats = map.map((k, v) => MapEntry(k, ArtistStats.fromJson(v)));
    }

    final genreJson = prefs.getString(_kGenreStatsKey);
    if (genreJson != null) {
      final map = jsonDecode(genreJson) as Map<String, dynamic>;
      _genreStats = map.map((k, v) => MapEntry(k, GenreStats.fromJson(v)));
    }
  }

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    _lastSaveMs = DateTime.now().millisecondsSinceEpoch;

    // Save history (keep last [_maxHistory])
    final historyToSave = _listeningHistory.length > _maxHistory
        ? _listeningHistory.sublist(_listeningHistory.length - _maxHistory)
        : _listeningHistory;
    await prefs.setString(_kListeningHistoryKey,
        jsonEncode(historyToSave.map((e) => e.toJson()).toList()));

    // Save stats
    await prefs.setString(_kDailyStatsKey,
        jsonEncode(_dailyStats.map((k, v) => MapEntry(k, v.toJson()))));
    await prefs.setString(_kArtistStatsKey,
        jsonEncode(_artistStats.map((k, v) => MapEntry(k, v.toJson()))));
    await prefs.setString(_kGenreStatsKey,
        jsonEncode(_genreStats.map((k, v) => MapEntry(k, v.toJson()))));
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Data models
// ──────────────────────────────────────────────────────────────────────────

class ListeningEvent {
  final String songId;
  final String songTitle;
  final String? artistId;
  final String? artistName;
  final String? albumId;
  final String? albumTitle;
  final String? genre;
  final int durationMs;
  final bool completed;
  final DateTime timestamp;

  ListeningEvent({
    required this.songId,
    required this.songTitle,
    this.artistId,
    this.artistName,
    this.albumId,
    this.albumTitle,
    this.genre,
    required this.durationMs,
    required this.completed,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'songId': songId,
    'songTitle': songTitle,
    'artistId': artistId,
    'artistName': artistName,
    'albumId': albumId,
    'albumTitle': albumTitle,
    'genre': genre,
    'durationMs': durationMs,
    'completed': completed,
    'timestamp': timestamp.toIso8601String(),
  };

  factory ListeningEvent.fromJson(Map<String, dynamic> json) {
    DateTime ts;
    try {
      ts = DateTime.tryParse(json['timestamp']?.toString() ?? '') ?? DateTime.now();
    } catch (_) {
      ts = DateTime.now();
    }
    return ListeningEvent(
    songId: json['songId'],
    songTitle: json['songTitle'],
    artistId: json['artistId'],
    artistName: json['artistName'],
    albumId: json['albumId'],
    albumTitle: json['albumTitle'],
    genre: json['genre'],
    durationMs: json['durationMs'],
    completed: json['completed'],
    timestamp: ts,
  );
  }
}

class DailyStats {
  final String date;
  int totalListens;
  int totalDurationMs;
  int completedListens;

  DailyStats({
    required this.date,
    this.totalListens = 0,
    this.totalDurationMs = 0,
    this.completedListens = 0,
  });

  String get totalDurationFormatted {
    final hours = totalDurationMs ~/ 3600000;
    final minutes = (totalDurationMs % 3600000) ~/ 60000;
    if (hours > 0) return '${hours}h ${minutes}m';
    return '${minutes}m';
  }

  Map<String, dynamic> toJson() => {
    'date': date,
    'totalListens': totalListens,
    'totalDurationMs': totalDurationMs,
    'completedListens': completedListens,
  };

  factory DailyStats.fromJson(Map<String, dynamic> json) => DailyStats(
    date: json['date'],
    totalListens: json['totalListens'] ?? 0,
    totalDurationMs: json['totalDurationMs'] ?? 0,
    completedListens: json['completedListens'] ?? 0,
  );
}

class ArtistStats {
  final String artistId;
  final String artistName;
  int listenCount;
  int totalDurationMs;
  DateTime? lastPlayed;

  ArtistStats({
    required this.artistId,
    required this.artistName,
    this.listenCount = 0,
    this.totalDurationMs = 0,
    this.lastPlayed,
  });

  Map<String, dynamic> toJson() => {
    'artistId': artistId,
    'artistName': artistName,
    'listenCount': listenCount,
    'totalDurationMs': totalDurationMs,
    'lastPlayed': lastPlayed?.toIso8601String(),
  };

  factory ArtistStats.fromJson(Map<String, dynamic> json) {
    DateTime? lp;
    try {
      final raw = json['lastPlayed']?.toString();
      lp = raw == null ? null : DateTime.tryParse(raw);
    } catch (_) {
      lp = null;
    }
    return ArtistStats(
    artistId: json['artistId'],
    artistName: json['artistName'],
    listenCount: json['listenCount'] ?? 0,
    totalDurationMs: json['totalDurationMs'] ?? 0,
    lastPlayed: lp,
  );
  }
}

class GenreStats {
  final String genre;
  int listenCount;
  int totalDurationMs;

  GenreStats({
    required this.genre,
    this.listenCount = 0,
    this.totalDurationMs = 0,
  });

  Map<String, dynamic> toJson() => {
    'genre': genre,
    'listenCount': listenCount,
    'totalDurationMs': totalDurationMs,
  };

  factory GenreStats.fromJson(Map<String, dynamic> json) => GenreStats(
    genre: json['genre'],
    listenCount: json['listenCount'] ?? 0,
    totalDurationMs: json['totalDurationMs'] ?? 0,
  );
}

class ListeningStats {
  final int totalListens;
  final int totalDurationMs;
  final int completedListens;
  final int uniqueArtists;
  final int uniqueGenres;
  final List<({String name, int count})> topArtists;
  final List<({String name, int count})> topGenres;
  final List<int> hourlyListens;

  ListeningStats({
    required this.totalListens,
    required this.totalDurationMs,
    required this.completedListens,
    required this.uniqueArtists,
    required this.uniqueGenres,
    required this.topArtists,
    required this.topGenres,
    required this.hourlyListens,
  });

  String get totalDurationFormatted {
    final hours = totalDurationMs ~/ 3600000;
    final minutes = (totalDurationMs % 3600000) ~/ 60000;
    if (hours > 0) return '${hours}h ${minutes}m';
    return '${minutes}m';
  }

  double get completionRate =>
      totalListens > 0 ? completedListens / totalListens : 0;
}
