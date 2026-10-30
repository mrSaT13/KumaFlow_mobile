import 'dart:math';
import '../../models/ml/ml_types.dart';
import '../../models/song.dart';
import '../subsonic_service.dart';
import 'vibe_similarity.dart';
import 'track_scorer.dart';
import 'mood_drift_detector.dart';
import 'behavior_tracker.dart';
import 'multi_armed_bandit.dart';
import 'sonic_fingerprint.dart';
import 'time_aware_history.dart';
import 'ml_store.dart';

class MLWaveService {
  final SubsonicService _subsonic;
  final VibeSimilarity _vibe = VibeSimilarity();
  late final TrackScorer _scorer;
  final MoodDriftDetector _moodDetector = MoodDriftDetector();
  final BehaviorTracker _behaviorTracker;
  final MultiArmedBandit _bandit = MultiArmedBandit();
  late final SonicFingerprintService _fingerprint;
  final TimeAwareHistory? _timeHistory;
  final MLStore _store;
  final Random _random = Random();

  /// Pass a shared [BehaviorTracker] (for example from `PlayerProvider`) so the
  /// same events are visible to both the player pipeline and to My Wave /
  /// AutoDJ / Smart Auto-DJ here. When omitted a private tracker is created,
  /// preserving the historical default for any standalone callers.
  MLWaveService(
    this._store,
    this._subsonic, {
    BehaviorTracker? behaviorTracker,
    TimeAwareHistory? timeAwareHistory,
    SonicFingerprintService? sonicFingerprint,
  }) : _behaviorTracker = behaviorTracker ?? BehaviorTracker(),
       _timeHistory = timeAwareHistory {
    _fingerprint = sonicFingerprint ?? SonicFingerprintService();
    _scorer = TrackScorer(
      _vibe,
      timeHistory: _timeHistory,
      fingerprint: _fingerprint,
    );
  }

  VibeSimilarity get vibe => _vibe;
  BehaviorTracker get behaviorTracker => _behaviorTracker;
  MoodDriftDetector get moodDetector => _moodDetector;
  MultiArmedBandit get bandit => _bandit;
  SonicFingerprintService get fingerprint => _fingerprint;

  Future<MLWavePlaylist> generateMyWavePlaylist({
    required List<String> likedSongIds,
    required Map<String, TrackRating> ratings,
    int limit = 50,
    bool excludeDisliked = true,
    MyWaveSettings? settings,
  }) async {
    if (likedSongIds.isEmpty) {
      final randomSongs = await _subsonic.getRandomSongs(size: limit);
      return MLWavePlaylist(songs: randomSongs, source: 'random');
    }

    if (_moodDetector.needsPlaylistReset() && settings?.mood == null) {
      _moodDetector.resetProfile();
    }

    final seedTracks = _selectSeeds(likedSongIds, ratings, settings?.characteristic, limit: 5);
    final seedSongs = <Song>[];
    for (final id in seedTracks) {
      try {
        final result = await _subsonic.search(id, songCount: 1);
        if (result.songs.isNotEmpty) seedSongs.add(result.songs.first);
      } catch (_) {}
    }

    if (seedSongs.isEmpty) {
      final randomSongs = await _subsonic.getRandomSongs(size: limit);
      return MLWavePlaylist(songs: randomSongs, source: 'random');
    }

    final candidates = <Song>[];
    final seenKeys = <String>{};
    void addUnique(List<Song> list) {
      for (final s in list) {
        if (seenKeys.add(s.queueKey)) candidates.add(s);
      }
    }
    for (final seed in seedSongs) {
      try {
        final similar = await _subsonic.getSimilarSongs(seed.id, count: 20);
        addUnique(similar);
      } catch (_) {}
    }

    try {
      final randomSongs = await _subsonic.getRandomSongs(size: 20);
      addUnique(randomSongs);
    } catch (_) {}

    if (settings?.mood != null) {
      candidates.removeWhere((s) {
        final features = _vibe.analyzeTrack(s);
        final mood = _vibe.detectMood(features);
        return mood.mood.name != settings!.mood;
      });
    }

    if (excludeDisliked) {
      candidates.removeWhere((s) => _store.profile.dislikedSongs.contains(s.id));
    }

    candidates.removeWhere((s) => _moodDetector.isTempBanned(s.artistId ?? '', 'artist'));
    candidates.removeWhere((s) => _moodDetector.isTempBanned(s.genre ?? '', 'genre'));

    final scored = _scorer.scoreAndRankTracks(
      candidates: candidates,
      profile: _store.profile,
      ratings: ratings,
      seedTracks: seedSongs,
      limit: limit,
      currentHour: DateTime.now().hour,
      activity: settings?.activity,
      mood: settings?.mood,
      recentEvents: _behaviorTracker.getRecentEvents(),
    );

    final selectedTracks = scored.map((s) => s['song'] as Song).toList();
    // Дедуп после скоринга (кандидаты из разных сидов пересекались).
    final deduped = <Song>[];
    final seenSel = <String>{};
    for (final s in selectedTracks) {
      if (seenSel.add(s.queueKey)) deduped.add(s);
    }
    selectedTracks
      ..clear()
      ..addAll(deduped);

    final adjustments = _moodDetector.getPlaylistAdjustments();
    if (adjustments['energyMax'] != null) {
      selectedTracks.sort((a, b) {
        final aFeatures = _vibe.analyzeTrack(a);
        final bFeatures = _vibe.analyzeTrack(b);
        return aFeatures.energy.compareTo(bFeatures.energy);
      });
    }

    final mabContext = _bandit.getCurrentContext();
    final topArtists = _store.profile.preferredArtists.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final arms = topArtists.take(10).map((e) =>
      MABArm(id: e.key, type: 'artist', name: e.key)
    ).toList();
    if (arms.isNotEmpty) {
      final selectedArm = _bandit.selectArm(arms, mabContext);
      try {
        final topSongs = await _subsonic.getArtistTopSongs(selectedArm.id, count: 5);
        final known = selectedTracks.map((s) => s.queueKey).toSet();
        for (final s in topSongs.take(3)) {
          // MAB-добивка без проверки давала дубли и дизлайки в волне.
          if (known.contains(s.queueKey)) continue;
          if (_store.profile.dislikedSongs.contains(s.id)) continue;
          if (_store.profile.bannedArtists.contains(s.artistId)) continue;
          selectedTracks.add(s);
          known.add(s.queueKey);
        }
      } catch (_) {}
    }

    if (selectedTracks.length < limit) {
      try {
        final more = await _subsonic.getRandomSongs(size: limit - selectedTracks.length);
        final known = selectedTracks.map((s) => s.queueKey).toSet();
        for (final s in more) {
          if (known.contains(s.queueKey)) continue;
          if (_store.profile.dislikedSongs.contains(s.id)) continue;
          if (_store.profile.bannedArtists.contains(s.artistId)) continue;
          selectedTracks.add(s);
          known.add(s.queueKey);
          if (selectedTracks.length >= limit) break;
        }
      } catch (_) {}
    }

    // Пустая выборка после фильтров — раньше RangeError на .first.
    if (selectedTracks.isEmpty) {
      try {
        final fallback = await _subsonic.getRandomSongs(size: limit);
        selectedTracks.addAll(fallback.take(limit));
      } catch (_) {}
      if (selectedTracks.isEmpty) {
        return MLWavePlaylist(songs: const [], source: 'ml-wave-empty');
      }
    }

    _fingerprint.updateFingerprint(
      selectedTracks.first.id,
      _vibe.analyzeTrack(selectedTracks.first).toJson(),
    );

    return MLWavePlaylist(
      songs: selectedTracks.take(limit).toList(),
      source: 'ml-wave',
      name: 'My Wave',
      description: _generateDescription(settings),
    );
  }

  List<String> _selectSeeds(List<String> likedSongIds, Map<String, TrackRating> ratings, String? characteristic, {int limit = 5}) {
    if (likedSongIds.isEmpty) return [];

    double topRatio, recentRatio;
    switch (characteristic) {
      case 'favorite':
        topRatio = 0.7; recentRatio = 0.2;
        break;
      case 'unfamiliar':
        topRatio = 0.3; recentRatio = 0.2;
        break;
      case 'popular':
        topRatio = 0.6; recentRatio = 0.3;
        break;
      default:
        topRatio = 0.5; recentRatio = 0.25;
    }

    final topCount = (limit * topRatio).round();
    final recentCount = (limit * recentRatio).round();
    final randomCount = limit - topCount - recentCount;

    final result = <String>[];

    // Time-of-day signal: tracks you usually play around this hour rank up.
    final hour = DateTime.now().hour;
    double timeBonusOf(String id) {
      final h = _timeHistory;
      if (h == null) return 0;
      try {
        return h.getTimeBonus(id, hour);
      } catch (_) {
        return 0;
      }
    }

    final sortedByScore = likedSongIds.toList()
      ..sort((a, b) => (_store.calculateTrackScore(b, timeBonus: timeBonusOf(b)))
          .compareTo(_store.calculateTrackScore(a, timeBonus: timeBonusOf(a))));
    result.addAll(sortedByScore.take(topCount));

    final recentLiked = likedSongIds.where((id) {
      final r = ratings[id];
      return r?.lastPlayed != null;
    }).toList()
      ..sort((a, b) => (ratings[b]?.lastPlayed ?? '').compareTo(ratings[a]?.lastPlayed ?? ''));
    result.addAll(recentLiked.take(recentCount).where((id) => !result.contains(id)));

    final remaining = likedSongIds.where((id) => !result.contains(id)).toList();
    remaining.shuffle(_random);
    result.addAll(remaining.take(randomCount));

    return result.take(limit).toList();
  }

  Future<MLWavePlaylist> generateSongAlchemy({
    required double energy,
    required double danceability,
    required double valence,
    required double acousticness,
    int limit = 50,
  }) async {
    final candidates = await _subsonic.getRandomSongs(size: 200);

    final scored = <Map<String, dynamic>>[];
    for (final song in candidates) {
      final features = _vibe.analyzeTrack(song);
      final similarity = 1.0 - (
        (features.energy - energy).abs() * 0.3 +
        (features.danceability - danceability).abs() * 0.3 +
        (features.valence - valence).abs() * 0.2 +
        (features.acousticness - acousticness).abs() * 0.2
      );
      scored.add({'song': song, 'score': similarity});
    }

    // Use a heap-like partial sort: only keep the top `limit` candidates.
    scored.sort((a, b) => (b['score'] as double).compareTo(a['score'] as double));
    final selected = scored.take(limit).map((s) => s['song'] as Song).toList();

    return MLWavePlaylist(
      songs: selected,
      source: 'alchemy',
      name: 'Song Alchemy',
      description: 'Custom mix with your preferred vibes',
    );
  }

  Future<List<Song>> getSimilarTracks(Song currentSong, int limit) async {
    final features = _vibe.analyzeTrack(currentSong);
    final similar = await _subsonic.getSimilarSongs(currentSong.id, count: limit * 2);
    final scored = <Map<String, dynamic>>[];
    for (final song in similar) {
      final songFeatures = _vibe.analyzeTrack(song);
      final sim = _vibe.vibeSimilarity(features, songFeatures);
      scored.add({'song': song, 'similarity': sim});
    }
    scored.sort((a, b) => (b['similarity'] as double).compareTo(a['similarity'] as double));
    return scored.take(limit).map((s) => s['song'] as Song).toList();
  }

  /// ── My Wave по артисту/жанру — локальная версия без серверных similar ──
  /// Используется `RecommendationService`-совместимый скоринг + vibe-расширение.
  /// Не делает сетевых запросов, работает мгновенно на `pool` (library).
  List<Song> generateSeededWaveSync({
    required List<Song> pool,
    String? seedArtist,
    String? seedArtistId,
    String? seedGenre,
    int limit = 50,
    int? currentHour,
  }) {
    if (pool.isEmpty) return [];
    final seedLower = seedArtist?.toLowerCase();
    final genreLower = seedGenre?.toLowerCase();

    var filtered = pool.where((s) {
      if (seedArtistId != null && s.artistId == seedArtistId) return true;
      if (seedLower != null && s.artist != null && s.artist!.toLowerCase() == seedLower) return true;
      if (genreLower != null && s.genre != null && s.genre!.toLowerCase() == genreLower) return true;
      return false;
    }).toList();

    // Если пул маленький — добираем вайб-близкие к seed
    if (filtered.length < limit && filtered.isNotEmpty) {
      final ids = filtered.map((e) => e.id).toSet();
      double e = 0, va = 0, d = 0, b = 0, ac = 0, inst = 0;
      for (final s in filtered.take(10)) {
        final f = _vibe.analyzeTrack(s);
        e += f.energy; va += f.valence; d += f.danceability; b += f.bpm; ac += f.acousticness; inst += f.instrumentalness;
      }
      final n = min(filtered.length, 10);
      final seedProfile = VibeFeatures(energy: e / n, valence: va / n, danceability: d / n, bpm: b / n, acousticness: ac / n, instrumentalness: inst / n);
      final remaining = pool.where((s) => !ids.contains(s.id)).toList();
      final scored = remaining.map((s) {
        final sim = _vibe.vibeSimilarity(seedProfile, _vibe.analyzeTrack(s));
        return MapEntry(s, sim);
      }).toList()..sort((a, b) => b.value.compareTo(a.value));
      const threshold = 0.62;
      final vibeClose = scored.where((x) => x.value >= threshold).map((x) => x.key).take((limit - filtered.length).clamp(0, (limit * 0.4).round())).toList();
      if (vibeClose.isNotEmpty) filtered.addAll(vibeClose);
    }

    if (filtered.isEmpty) return [];

    final scored = _scorer.scoreAndRankTracks(
      candidates: filtered,
      profile: _store.profile,
      ratings: _store.ratings,
      seedTracks: filtered.take(min(5, filtered.length)).toList(),
      limit: limit,
      currentHour: currentHour ?? DateTime.now().hour,
      recentEvents: _behaviorTracker.getRecentEvents(),
    );
    return scored.map((e) => e['song'] as Song).toList();
  }

  Future<MLWavePlaylist> generateWaveByArtist({
    required List<Song> pool,
    required String artist,
    String? artistId,
    int limit = 50,
  }) async {
    final songs = generateSeededWaveSync(pool: pool, seedArtist: artist, seedArtistId: artistId, limit: limit);
    if (songs.isEmpty) {
      // Fallback к серверному similar
      try {
        final seed = pool.firstWhere((s) => s.artist?.toLowerCase() == artist.toLowerCase());
        final similar = await getSimilarTracks(seed, limit);
        return MLWavePlaylist(songs: similar.take(limit).toList(), source: 'wave-artist', name: 'Волна по $artist');
      } catch (_) {}
    }
    return MLWavePlaylist(songs: songs, source: 'wave-artist', name: 'Волна по $artist', description: 'По артисту $artist · ${songs.length} треков');
  }

  Future<MLWavePlaylist> generateWaveByGenre({
    required List<Song> pool,
    required String genre,
    int limit = 50,
  }) async {
    final songs = generateSeededWaveSync(pool: pool, seedGenre: genre, limit: limit);
    return MLWavePlaylist(songs: songs, source: 'wave-genre', name: 'Волна по $genre', description: 'По жанру $genre · ${songs.length} треков');
  }

  String _generateDescription(MyWaveSettings? settings) {
    if (settings == null) return 'Your personalized music mix';
    final parts = <String>[];
    if (settings.mood != null) parts.add('${settings.mood} mood');
    if (settings.activity != null) parts.add('for ${settings.activity}');
    if (settings.characteristic != null) parts.add('${settings.characteristic} picks');
    return parts.isEmpty ? 'Your personalized music mix' : parts.join(' · ');
  }
}
