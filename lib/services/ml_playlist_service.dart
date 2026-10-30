import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../models/ml/ml_types.dart';
import 'subsonic_service.dart';
import 'recommendation_service.dart';
import 'auto_dj_service.dart';
import 'local_music_service.dart';
import 'ml/vibe_similarity.dart';
import 'ml/audio_features_cache.dart';
import 'mix_cache_service.dart';
import 'ml_service.dart';

enum PlaylistRefreshInterval {
  never,
  daily,
  weekly,
  biweekly,
  monthly,
}

class MlPlaylistConfig {
  final String id;
  final String name;
  final int minTracks;
  final int maxTracks;
  final List<String> allowedGenres;
  final List<String> blockedGenres;
  final String? mood;
  final PlaylistRefreshInterval refreshInterval;
  final DateTime? lastRefreshed;
  final bool isActive;

  MlPlaylistConfig({
    required this.id,
    required this.name,
    this.minTracks = 10,
    this.maxTracks = 50,
    this.allowedGenres = const [],
    this.blockedGenres = const [],
    this.mood,
    this.refreshInterval = PlaylistRefreshInterval.weekly,
    this.lastRefreshed,
    this.isActive = true,
  });

  MlPlaylistConfig copyWith({
    String? name,
    int? minTracks,
    int? maxTracks,
    List<String>? allowedGenres,
    List<String>? blockedGenres,
    String? mood,
    PlaylistRefreshInterval? refreshInterval,
    DateTime? lastRefreshed,
    bool? isActive,
  }) {
    return MlPlaylistConfig(
      id: id,
      name: name ?? this.name,
      minTracks: minTracks ?? this.minTracks,
      maxTracks: maxTracks ?? this.maxTracks,
      allowedGenres: allowedGenres ?? this.allowedGenres,
      blockedGenres: blockedGenres ?? this.blockedGenres,
      mood: mood ?? this.mood,
      refreshInterval: refreshInterval ?? this.refreshInterval,
      lastRefreshed: lastRefreshed ?? this.lastRefreshed,
      isActive: isActive ?? this.isActive,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'minTracks': minTracks,
    'maxTracks': maxTracks,
    'allowedGenres': allowedGenres,
    'blockedGenres': blockedGenres,
    'mood': mood,
    'refreshInterval': refreshInterval.index,
    'lastRefreshed': lastRefreshed?.toIso8601String(),
    'isActive': isActive,
  };

  factory MlPlaylistConfig.fromJson(Map<String, dynamic> json) =>
      MlPlaylistConfig(
        id: json['id'] as String,
        name: json['name'] as String,
        minTracks: json['minTracks'] as int? ?? 10,
        maxTracks: json['maxTracks'] as int? ?? 50,
        allowedGenres: List<String>.from(json['allowedGenres'] ?? []),
        blockedGenres: List<String>.from(json['blockedGenres'] ?? []),
        mood: json['mood'] as String?,
        refreshInterval: PlaylistRefreshInterval
            .values[(json['refreshInterval'] as int?) ?? 2],
        lastRefreshed: json['lastRefreshed'] != null
            ? DateTime.tryParse(json['lastRefreshed'] as String)
            : null,
        isActive: json['isActive'] as bool? ?? true,
      );
}

class MlPlaylistResult {
  final String playlistId;
  final String name;
  final List<Song> songs;
  final DateTime generatedAt;
  final Map<String, dynamic> stats;

  MlPlaylistResult({
    required this.playlistId,
    required this.name,
    required this.songs,
    required this.generatedAt,
    this.stats = const {},
  });
}

class MlPlaylistService extends ChangeNotifier {
  static final MlPlaylistService _instance = MlPlaylistService._internal();
  factory MlPlaylistService() => _instance;
  MlPlaylistService._internal();

  SharedPreferences? _prefs;
  bool _isInitialized = false;

  SubsonicService? _subsonicService;
  RecommendationService? _recommendationService;
  AutoDjService? _autoDjService;
  LocalMusicService? _localMusicService;

  final List<MlPlaylistConfig> _configs = [];
  final Map<String, MlPlaylistResult> _cache = {};
  Timer? _refreshTimer;

  static const String _configsKey = 'ml_playlist_configs';

  bool get isInitialized => _isInitialized;
  List<MlPlaylistConfig> get configs => List.unmodifiable(_configs);

  void setServices({
    required SubsonicService subsonicService,
    RecommendationService? recommendationService,
    AutoDjService? autoDjService,
    LocalMusicService? localMusicService,
  }) {
    _subsonicService = subsonicService;
    _recommendationService = recommendationService;
    _autoDjService = autoDjService;
    _localMusicService = localMusicService;
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _prefs = await SharedPreferences.getInstance();
      await _loadConfigs();
      // Merge missing default presets (existing users keep their configs).
      var changed = false;
      for (final preset in defaultPresets()) {
        if (!_configs.any((c) => c.id == preset.id)) {
          _configs.add(preset);
          changed = true;
        }
      }
      if (changed) await _saveConfigs();
      _scheduleRefreshTimer();
      _isInitialized = true;
    } catch (e) {
      debugPrint('Error initializing MlPlaylistService: $e');
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Config Management
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> addConfig(MlPlaylistConfig config) async {
    _configs.add(config);
    await _saveConfigs();
    notifyListeners();
  }

  Future<void> updateConfig(MlPlaylistConfig config) async {
    final idx = _configs.indexWhere((c) => c.id == config.id);
    if (idx >= 0) {
      _configs[idx] = config;
      await _saveConfigs();
      notifyListeners();
    }
  }

  Future<void> removeConfig(String id) async {
    _configs.removeWhere((c) => c.id == id);
    _cache.remove(id);
    await _saveConfigs();
    notifyListeners();
  }

  MlPlaylistConfig? getConfig(String id) {
    try {
      return _configs.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Playlist Generation
  // ──────────────────────────────────────────────────────────────────────────

  Future<MlPlaylistResult?> generatePlaylist(
    MlPlaylistConfig config, {
    List<Song>? availableSongs,
  }) async {
    if (_subsonicService == null) return null;

    try {
      // Fetch candidates
      final candidates = await _fetchCandidates(availableSongs);
      if (candidates.isEmpty) return null;

      // Apply genre filters
      var filtered = _applyGenreFilters(candidates, config);

      // Score and rank using recommendation service
      var scored = _scoreCandidates(filtered);

      // Apply mood filter
      if (config.mood != null) {
        scored = _applyMoodFilter(scored, config.mood!);
      }

      // Deduplicate
      scored = _deduplicate(scored);

      // Limit to desired range
      final trackCount = min(
        scored.length,
        max(config.minTracks, config.maxTracks),
      );
      final songs = scored.take(trackCount).toList();

      // Update config timestamp
      final updatedConfig = config.copyWith(lastRefreshed: DateTime.now());
      await updateConfig(updatedConfig);

      final result = MlPlaylistResult(
        playlistId: config.id,
        name: config.name,
        songs: songs,
        generatedAt: DateTime.now(),
        stats: {
          'totalCandidates': candidates.length,
          'afterGenreFilter': filtered.length,
          'afterDedup': scored.length,
          'moodFilter': config.mood,
        },
      );

      _cache[config.id] = result;
      notifyListeners();
      return result;
    } catch (e) {
      debugPrint('Error generating ML playlist: $e');
      return null;
    }
  }

  Future<void> generateAndSaveToServer(MlPlaylistConfig config) async {
    final result = await generatePlaylist(config);
    if (result == null || _subsonicService == null) return;

    try {
      // Delete existing playlist with same name if exists
      // Then create a new one
      await _subsonicService!.createPlaylist(
        name: '[ML] ${config.name}',
        comment: 'Auto-generated by KumaFlow ML · ${config.mood ?? "all moods"}',
        songIds: result.songs.map((s) => s.id).toList(),
      );
    } catch (e) {
      debugPrint('Error saving ML playlist to server: $e');
    }
  }

  /// ── DailyMix: forgotten (50%) + vibe (10%) + novelty (40%) ──
  /// Забытые: playCount>=5, lastPlayed >60д, bpm±30% и energy±0.3 от среднего
  /// Вайб: similarity >=0.62 к среднему профилю
  /// Novelty: неигранные (<2) или не в топ-жанрах
  /// Кешируется на 24ч по дате + bannedKey, recentUsedIds исключаются (5 последних)
  Future<MlPlaylistResult?> generateDailyMix({
    required List<Song> pool,
    int limit = 25,
    bool useCache = true,
  }) async {
    if (pool.isEmpty || _recommendationService == null) return null;
    final rec = _recommendationService!;
    final ml = MLService();
    bool isBanned(Song s) => ml.isDisliked(s.id) || ml.isArtistBanned(s.artistId, s.artist);
    // Filter pool upfront for banned/disliked - prevents BTS etc from appearing
    final filteredPool = pool.where((s) => !isBanned(s)).toList();
    if (filteredPool.isEmpty) return null;
    final cache = MixCacheService();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final cacheKey = 'daily_${filteredPool.length}_${today}_${rec.bannedArtistsKey.hashCode}';

    if (useCache) {
      final cached = await cache.loadDailyMix(cacheKey, filteredPool);
      if (cached != null) {
        final filteredCached = cached.where((s) => !isBanned(s)).toList();
        if (filteredCached.isNotEmpty) {
          return MlPlaylistResult(
            playlistId: 'daily_mix_$today',
            name: 'Daily Mix',
            songs: filteredCached,
            generatedAt: DateTime.now(),
            stats: {'source': 'cache'},
          );
        }
      }
    }

    // Быстрый recent set и recent ids из daily cache (исключаем повторы)
    final recentSet = rec.recentlyPlayed.take(20).toSet();
    final recentDailyIds = await cache.getRecentDailyIds(max: 50);
    final profiles = rec.profiles;
    final vibe = VibeSimilarity();
    // Offline-first features: one batched DB read for the whole pool,
    // missing tracks are estimated once and persisted.
    final featById = await AudioFeaturesCache().getBatch(filteredPool);

    // Средний профиль по recent 20 (или по pool если recent пустой)
    List<Song> recentSongs = [];
    if (rec.recentlyPlayed.isNotEmpty) {
      final byId = {for (final s in filteredPool) s.id: s};
      recentSongs = rec.recentlyPlayed.take(20).map((id) => byId[id]).whereType<Song>().toList();
    }
    if (recentSongs.isEmpty) recentSongs = filteredPool.take(20).toList();

    double avgBpm = 0, avgEnergy = 0;
    for (final s in recentSongs) {
      final cached = featById[s.id];
      final bpm = cached?.bpm ?? vibe.analyzeTrack(s).bpm;
      final energy = cached?.energy ?? vibe.analyzeTrack(s).energy;
      avgBpm += bpm;
      avgEnergy += energy;
    }
    if (recentSongs.isNotEmpty) {
      avgBpm /= recentSongs.length;
      avgEnergy /= recentSongs.length;
    } else {
      avgBpm = 110; avgEnergy = 0.5;
    }
    final bpmLow = avgBpm * 0.7, bpmHigh = avgBpm * 1.3;
    final energyLow = (avgEnergy - 0.3).clamp(0.0, 1.0), energyHigh = (avgEnergy + 0.3).clamp(0.0, 1.0);
    final now = DateTime.now();

    // Forgotten
    final forgotten = <Song>[];
    for (final s in filteredPool) {
      if (recentSet.contains(s.id) || recentDailyIds.contains(s.id)) continue;
      final p = profiles[s.id];
      if (p == null) continue;
      if (p.playCount < 5) continue;
      final daysSince = now.difference(p.lastPlayed).inDays;
      if (daysSince < 60) continue;
      final fb = featById[s.id];
      final bpm = fb?.bpm ?? vibe.analyzeTrack(s).bpm;
      if (bpm < bpmLow || bpm > bpmHigh) continue;
      final energy = fb?.energy ?? vibe.analyzeTrack(s).energy;
      if (energy < energyLow || energy > energyHigh) continue;
      forgotten.add(s);
    }
    // Сорт forgotten по base score (любимые забытые выше)
    forgotten.sort((a, b) => rec.calculateSongScore(b).compareTo(rec.calculateSongScore(a)));

    final forgottenCount = (limit * 0.5).round().clamp(0, forgotten.length);
    final pickedForgotten = forgotten.take(forgottenCount).toList();
    final pickedIds = pickedForgotten.map((e) => e.id).toSet();

    // Vibe 10%
    final vibeCount = (limit * 0.1).round();
    List<Song> vibeClose = [];
    if (recentSongs.isNotEmpty && vibeCount > 0) {
      double e = 0, va = 0, d = 0, b = 0, ac = 0, inst = 0;
      for (final s in recentSongs) {
        final f = featById[s.id] ?? vibe.analyzeTrack(s);
        e += f.energy; va += f.valence; d += f.danceability; b += f.bpm; ac += f.acousticness; inst += f.instrumentalness;
      }
      final n = recentSongs.length;
      final seedProfile = VibeFeatures(energy: e / n, valence: va / n, danceability: d / n, bpm: b / n, acousticness: ac / n, instrumentalness: inst / n);
      final candidates = filteredPool.where((s) => !pickedIds.contains(s.id) && !recentSet.contains(s.id) && !recentDailyIds.contains(s.id)).toList();
      final scored = candidates.map((s) => MapEntry(s, vibe.vibeSimilarity(seedProfile, featById[s.id] ?? vibe.analyzeTrack(s)))).toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      vibeClose = scored.where((x) => x.value >= 0.62).map((x) => x.key).take(vibeCount).toList();
      pickedIds.addAll(vibeClose.map((e) => e.id));
    }

    // Novelty remainder: неигранные или playCount <2, предпочтительно не из топ-жанров
    final topGenres = rec.getRecommendedGenres(limit: 5).map((e) => e.toLowerCase()).toSet();
    final noveltyPool = filteredPool.where((s) {
      if (pickedIds.contains(s.id) || recentSet.contains(s.id) || recentDailyIds.contains(s.id)) return false;
      final p = profiles[s.id];
      if (p == null) return true; // неигранные — максимум novelty
      if (p.playCount >= 2) return false;
      return true;
    }).toList();
    // Приоритет: не топ-жанр → выше novelty
    noveltyPool.sort((a, b) {
      final aTop = a.genre != null && topGenres.contains(a.genre!.toLowerCase());
      final bTop = b.genre != null && topGenres.contains(b.genre!.toLowerCase());
      if (aTop != bTop) return aTop ? 1 : -1;
      return rec.calculateSongScore(b).compareTo(rec.calculateSongScore(a));
    });
    final needNovelty = limit - pickedForgotten.length - vibeClose.length;
    final pickedNovelty = noveltyPool.take(needNovelty.clamp(0, noveltyPool.length)).toList();
    pickedIds.addAll(pickedNovelty.map((e) => e.id));

    var resultSongs = [...pickedForgotten, ...vibeClose, ...pickedNovelty];

    // Если всё ещё недобор — добираем просто топ по score
    if (resultSongs.length < limit) {
      final remaining = filteredPool.where((s) => !pickedIds.contains(s.id) && !recentSet.contains(s.id)).toList()
        ..sort((a, b) => rec.calculateSongScore(b).compareTo(rec.calculateSongScore(a)));
      resultSongs.addAll(remaining.take(limit - resultSongs.length));
    }

    // Перемешиваем сохранением 70/30 баланса: первые 60% — seeded, остальное — случайный порядок
    // Для стабильности: шафлим только novelty часть
    if (pickedNovelty.length > 3) {
      final head = resultSongs.take(pickedForgotten.length + vibeClose.length).toList();
      final tail = resultSongs.skip(head.length).toList()..shuffle();
      resultSongs = [...head, ...tail];
    }

    // Ограничиваем, фильтруем баны и дедуплицируем
    final seen = <String>{};
    resultSongs = resultSongs.where((s) => !isBanned(s) && seen.add(s.id)).take(limit).toList();

    await cache.saveDailyMix(cacheKey, resultSongs);

    return MlPlaylistResult(
      playlistId: 'daily_mix_$today',
      name: 'Daily Mix',
      songs: resultSongs,
      generatedAt: DateTime.now(),
      stats: {
        'forgotten': pickedForgotten.length,
        'vibe': vibeClose.length,
        'novelty': pickedNovelty.length,
        'avgBpm': avgBpm.toStringAsFixed(1),
        'avgEnergy': avgEnergy.toStringAsFixed(2),
      },
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // ML-плейлисты: Тренды / Открытия / Персональное / Настроения
  // ──────────────────────────────────────────────────────────────────────────

  /// Total plays = server playCount + local ML rating playCount.
  int _totalPlaysOf(Song s, Map<String, dynamic> ratings) {
    final r = ratings[s.id];
    final local = (r?.playCount ?? 0) as int;
    return (s.playCount ?? 0) + local;
  }

  /// Тренды: популярное в библиотеке (>2 прослушиваний), сначала топ.
  Future<MlPlaylistResult?> generateTrends({
    required List<Song> pool,
    int limit = 25,
  }) async {
    if (pool.isEmpty) return null;
    final ml = MLService();
    bool banned(Song s) =>
        ml.isDisliked(s.id) || ml.isArtistBanned(s.artistId, s.artist);
    final ratings = ml.ratings;
    final trends = pool
        .where((s) => !banned(s) && _totalPlaysOf(s, ratings) > 2)
        .toList()
      ..sort((a, b) {
        final cmp = _totalPlaysOf(b, ratings).compareTo(_totalPlaysOf(a, ratings));
        if (cmp != 0) return cmp;
        return ml.calculateTrackScore(b.id).compareTo(ml.calculateTrackScore(a.id));
      });
    final songs = trends.take(limit).toList();
    return MlPlaylistResult(
      playlistId: 'trends',
      name: 'Тренды',
      songs: songs,
      generatedAt: DateTime.now(),
      stats: {'pool': pool.length, 'tracks': songs.length},
    );
  }

  /// Открытия: по одному треку от малоигранных артистов (новые имена).
  Future<MlPlaylistResult?> generateDiscoveries({
    required List<Song> pool,
    int limit = 25,
  }) async {
    if (pool.isEmpty) return null;
    final ml = MLService();
    bool banned(Song s) =>
        ml.isDisliked(s.id) || ml.isArtistBanned(s.artistId, s.artist);
    final ratings = ml.ratings;
    final byArtist = <String, List<Song>>{};
    for (final s in pool) {
      if (banned(s)) continue;
      final key = (s.artistId?.isNotEmpty ?? false)
          ? 'id:${s.artistId}'
          : 'name:${(s.artist ?? '').toLowerCase()}';
      byArtist.putIfAbsent(key, () => []).add(s);
    }
    int artistPlays(List<Song> songs) {
      var total = 0;
      for (final s in songs) {
        total += _totalPlaysOf(s, ratings);
      }
      return total;
    }

    final artists = byArtist.values.toList()
      ..sort((a, b) => artistPlays(a).compareTo(artistPlays(b)));
    final songs = <Song>[];
    final usedArtists = <String>{};
    for (final tracks in artists) {
      if (songs.length >= limit) break;
      // Prefer an unplayed track, otherwise the least played one.
      tracks.sort((a, b) =>
          _totalPlaysOf(a, ratings).compareTo(_totalPlaysOf(b, ratings)));
      final pick = tracks.first;
      final key = (pick.artistId?.isNotEmpty ?? false)
          ? 'id:${pick.artistId}'
          : 'name:${(pick.artist ?? '').toLowerCase()}';
      if (usedArtists.add(key)) songs.add(pick);
    }
    return MlPlaylistResult(
      playlistId: 'discoveries',
      name: 'Открытия',
      songs: songs,
      generatedAt: DateTime.now(),
      stats: {'pool': pool.length, 'artists': usedArtists.length},
    );
  }

  /// Персональное: лайкнутые треки (серверные звёзды + локальные лайки).
  Future<MlPlaylistResult?> generatePersonal({
    required List<Song> pool,
    int limit = 25,
  }) async {
    if (pool.isEmpty) return null;
    final ml = MLService();
    final ratings = ml.ratings;
    final liked = pool.where((s) {
      if (ml.isDisliked(s.id)) return false;
      if (s.starred == true) return true;
      return ratings[s.id]?.like == true;
    }).toList()
      ..sort((a, b) =>
          ml.calculateTrackScore(b.id).compareTo(ml.calculateTrackScore(a.id)));
    final songs = liked.take(limit).toList();
    return MlPlaylistResult(
      playlistId: 'personal',
      name: 'Персональное',
      songs: songs,
      generatedAt: DateTime.now(),
      stats: {'pool': pool.length, 'liked': liked.length},
    );
  }

  /// Настроения: треки с совпадающим настроением (happy, energetic, calm,
  /// focused...), добрасываем совместимыми по moodCompatibility.
  Future<MlPlaylistResult?> generateByMood({
    required List<Song> pool,
    required String mood,
    int limit = 25,
  }) async {
    if (pool.isEmpty) return null;
    final ml = MLService();
    bool banned(Song s) =>
        ml.isDisliked(s.id) || ml.isArtistBanned(s.artistId, s.artist);
    final vibe = VibeSimilarity();
    final featById = await AudioFeaturesCache().getBatch(pool);
    final exact = <Song>[];
    final compatible = <Song>[];
    for (final s in pool) {
      if (banned(s)) continue;
      final f = featById[s.id] ?? vibe.analyzeTrack(s);
      final detected = vibe.detectMood(f);
      if (detected.mood.name == mood) {
        exact.add(s);
      } else if (vibe.moodCompatibilityScore(detected.mood, _moodFromName(mood)) >= 0.8) {
        compatible.add(s);
      }
    }
    exact.sort((a, b) =>
        ml.calculateTrackScore(b.id).compareTo(ml.calculateTrackScore(a.id)));
    compatible.sort((a, b) =>
        ml.calculateTrackScore(b.id).compareTo(ml.calculateTrackScore(a.id)));
    final songs = [...exact, ...compatible].take(limit).toList();
    return MlPlaylistResult(
      playlistId: 'mood_$mood',
      name: 'Настроение: $mood',
      songs: songs,
      generatedAt: DateTime.now(),
      stats: {'pool': pool.length, 'exact': exact.length},
    );
  }

  MoodType _moodFromName(String name) {
    for (final m in MoodType.values) {
      if (m.name == name) return m;
    }
    return MoodType.calm;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Auto-Refresh
  // ──────────────────────────────────────────────────────────────────────────

  void _scheduleRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      const Duration(hours: 1),
      (_) => _checkAndRefreshDue(),
    );
  }

  Future<void> _checkAndRefreshDue() async {
    final now = DateTime.now();
    for (final config in _configs) {
      if (!config.isActive) continue;
      if (_isDueForRefresh(config, now)) {
        await generateAndSaveToServer(config);
      }
    }
  }

  bool _isDueForRefresh(MlPlaylistConfig config, DateTime now) {
    if (config.lastRefreshed == null) return true;
    final elapsed = now.difference(config.lastRefreshed!);
    switch (config.refreshInterval) {
      case PlaylistRefreshInterval.never:
        return false;
      case PlaylistRefreshInterval.daily:
        return elapsed.inDays >= 1;
      case PlaylistRefreshInterval.weekly:
        return elapsed.inDays >= 7;
      case PlaylistRefreshInterval.biweekly:
        return elapsed.inDays >= 14;
      case PlaylistRefreshInterval.monthly:
        return elapsed.inDays >= 30;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Scoring & Filtering
  // ──────────────────────────────────────────────────────────────────────────

  Future<List<Song>> _fetchCandidates(List<Song>? availableSongs) async {
    if (availableSongs != null && availableSongs.isNotEmpty) {
      return availableSongs;
    }

    // Fetch from server
    final List<Song> candidates = [];
    try {
      final starred = await _subsonicService!.getStarred();
      candidates.addAll(starred.songs);
    } catch (_) {}

    try {
      final random = await _subsonicService!.getRandomSongs(size: 100);
      candidates.addAll(random);
    } catch (_) {}

    // Include local songs from local folders
    if (_localMusicService != null && _localMusicService!.songs.isNotEmpty) {
      final localSongs = _localMusicService!.songs;
      for (final localSong in localSongs) {
        if (!candidates.any((s) => s.id == localSong.id)) {
          candidates.add(localSong);
        }
      }
    }

    return candidates;
  }

  List<Song> _applyGenreFilters(List<Song> songs, MlPlaylistConfig config) {
    return songs.where((s) {
      final genre = s.genre?.toLowerCase();
      if (genre == null) return true;

      if (config.allowedGenres.isNotEmpty) {
        return config.allowedGenres
            .any((g) => g.toLowerCase() == genre);
      }

      if (config.blockedGenres.isNotEmpty) {
        return !config.blockedGenres
            .any((g) => g.toLowerCase() == genre);
      }

      return true;
    }).toList();
  }

  List<Song> _scoreCandidates(List<Song> songs) {
    if (_recommendationService == null || songs.isEmpty) {
      final shuffled = List<Song>.from(songs)..shuffle(Random());
      return shuffled;
    }

    final scored = songs.map((s) {
      final score = _recommendationService!.calculateSongScore(s);
      return MapEntry(s, score);
    }).toList();

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.map((e) => e.key).toList();
  }

  List<Song> _applyMoodFilter(List<Song> songs, String mood) {
    if (_autoDjService == null) return songs;
    return _autoDjService!.applyMoodFilter(songs, mood);
  }

  List<Song> _deduplicate(List<Song> songs) {
    final seenIds = <String>{};
    return songs.where((s) {
      if (seenIds.contains(s.id)) return false;
      seenIds.add(s.id);
      return true;
    }).toList();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Persistence
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _loadConfigs() async {
    final json = _prefs?.getString(_configsKey);
    if (json == null) return;

    try {
      final list = List<Map<String, dynamic>>.from(
        (Uri.decodeComponent(json) as List).map((e) => Map<String, dynamic>.from(e)),
      );
      _configs.clear();
      _configs.addAll(list.map((e) => MlPlaylistConfig.fromJson(e)));
    } catch (e) {
      debugPrint('Error loading ML playlist configs: $e');
    }
  }

  Future<void> _saveConfigs() async {
    final json = _configs.map((c) => c.toJson()).toList();
    await _prefs?.setString(_configsKey, json.toString());
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Presets
  // ──────────────────────────────────────────────────────────────────────────

  static List<MlPlaylistConfig> defaultPresets() {
    return [
      MlPlaylistConfig(
        id: 'daily_mix',
        name: 'Daily Mix',
        minTracks: 25,
        maxTracks: 50,
        refreshInterval: PlaylistRefreshInterval.daily,
      ),
      MlPlaylistConfig(
        id: 'workout',
        name: 'Workout Energy',
        minTracks: 15,
        maxTracks: 30,
        mood: 'energetic',
        blockedGenres: ['classical', 'ambient', 'jazz'],
        refreshInterval: PlaylistRefreshInterval.weekly,
      ),
      MlPlaylistConfig(
        id: 'chill',
        name: 'Chill Vibes',
        minTracks: 20,
        maxTracks: 40,
        mood: 'calm',
        blockedGenres: ['metal', 'punk', 'hardcore'],
        refreshInterval: PlaylistRefreshInterval.weekly,
      ),
      MlPlaylistConfig(
        id: 'discovery',
        name: 'Discovery',
        minTracks: 10,
        maxTracks: 25,
        refreshInterval: PlaylistRefreshInterval.biweekly,
      ),
      MlPlaylistConfig(
        id: 'trends',
        name: 'Тренды',
        minTracks: 15,
        maxTracks: 25,
        refreshInterval: PlaylistRefreshInterval.daily,
      ),
      MlPlaylistConfig(
        id: 'discoveries',
        name: 'Открытия',
        minTracks: 10,
        maxTracks: 25,
        refreshInterval: PlaylistRefreshInterval.weekly,
      ),
      MlPlaylistConfig(
        id: 'personal',
        name: 'Персональное',
        minTracks: 15,
        maxTracks: 50,
        refreshInterval: PlaylistRefreshInterval.daily,
      ),
      MlPlaylistConfig(
        id: 'mood_happy',
        name: 'Настроение: радость',
        minTracks: 15,
        maxTracks: 30,
        mood: 'happy',
        refreshInterval: PlaylistRefreshInterval.weekly,
      ),
      MlPlaylistConfig(
        id: 'mood_energetic',
        name: 'Настроение: энергия',
        minTracks: 15,
        maxTracks: 30,
        mood: 'energetic',
        blockedGenres: ['classical', 'ambient'],
        refreshInterval: PlaylistRefreshInterval.weekly,
      ),
      MlPlaylistConfig(
        id: 'mood_calm',
        name: 'Настроение: спокойствие',
        minTracks: 15,
        maxTracks: 30,
        mood: 'calm',
        blockedGenres: ['metal', 'punk', 'hardcore'],
        refreshInterval: PlaylistRefreshInterval.weekly,
      ),
      MlPlaylistConfig(
        id: 'mood_focused',
        name: 'Настроение: фокус',
        minTracks: 15,
        maxTracks: 30,
        mood: 'focused',
        refreshInterval: PlaylistRefreshInterval.weekly,
      ),
    ];
  }

  static String getRefreshIntervalName(PlaylistRefreshInterval interval) {
    switch (interval) {
      case PlaylistRefreshInterval.never:
        return 'Never';
      case PlaylistRefreshInterval.daily:
        return 'Daily';
      case PlaylistRefreshInterval.weekly:
        return 'Weekly';
      case PlaylistRefreshInterval.biweekly:
        return 'Every 2 weeks';
      case PlaylistRefreshInterval.monthly:
        return 'Monthly';
    }
  }
}
