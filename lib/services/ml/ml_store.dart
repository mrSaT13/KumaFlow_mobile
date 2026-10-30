import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/ml/ml_types.dart';

class MLStore {
  late SharedPreferences _prefs;
  Map<String, TrackRating> _ratings = {};
  MLProfile _profile = MLProfile();
  final List<PlayEvent> _listeningHistory = [];

  /// Bulk-режим для серверного импорта: десятки тысяч importLike/
  /// importPlayCount подряд, каждый звал _save() — а это ТРИ полных
  /// jsonEncode всей базы + 3 записи prefs. На большой библиотеке один
  /// сейв — секунды CPU, тысячи подряд — 15-20с фриз главного потока
  /// (факт 15.10.2026: Skipped 1399 frames). В bulk сейвы глушатся,
  /// в конце — один. Плюс коалесцировка: параллельные _save не
  /// кодируют одновременно, а ставят один повторный.
  int _bulkDepth = 0;
  bool _saveQueued = false;
  bool _saveInFlight = false;

  void beginBulk() => _bulkDepth++;
  Future<void> endBulk() async {
    if (_bulkDepth > 0) _bulkDepth--;
    if (_bulkDepth == 0 && _saveQueued) {
      _saveQueued = false;
      await _save();
    }
  }

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _load();
  }

  Map<String, TrackRating> get ratings => _ratings;
  MLProfile get profile => _profile;
  List<PlayEvent> get listeningHistory => List.unmodifiable(_listeningHistory);

  Future<void> _load() async {
    try {
      final ratingsJson = _prefs.getString('ml_ratings');
      if (ratingsJson != null) {
        final decoded = jsonDecode(ratingsJson) as Map<String, dynamic>;
        _ratings = decoded.map((k, v) => MapEntry(k, TrackRating.fromJson(v as Map<String, dynamic>)));
      }

      final profileJson = _prefs.getString('ml_profile');
      if (profileJson != null) {
        _profile = MLProfile.fromJson(jsonDecode(profileJson) as Map<String, dynamic>);
      }

      final historyJson = _prefs.getString('ml_history');
      if (historyJson != null) {
        final decoded = jsonDecode(historyJson) as List;
        _listeningHistory.addAll(decoded.map((e) => PlayEvent.fromJson(e as Map<String, dynamic>)));
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    if (_bulkDepth > 0) {
      _saveQueued = true;
      return;
    }
    if (_saveInFlight) {
      _saveQueued = true;
      return;
    }
    _saveInFlight = true;
    try {
      final sw = Stopwatch()..start();
      await _prefs.setString('ml_ratings', jsonEncode(_ratings.map((k, v) => MapEntry(k, v.toJson()))));
      await _prefs.setString('ml_profile', jsonEncode(_profile.toJson()));
      await _prefs.setString('ml_history', jsonEncode(_listeningHistory.map((e) => e.toJson()).toList()));
      sw.stop();
      if (sw.elapsedMilliseconds > 500) {
        debugPrint('[MLStore] _save took ${sw.elapsedMilliseconds}ms for ${_ratings.length} ratings');
      }
    } finally {
      _saveInFlight = false;
      if (_saveQueued) {
        _saveQueued = false;
        await _save();
      }
    }
  }

  Future<void> rateSong(String songId, bool? like, Map<String, String>? songInfo) async {
    final rating = _ratings[songId] ?? TrackRating(songId: songId, songInfo: songInfo);
    rating.like = like;

    if (like == true) {
      rating.score += 100;
      if (!_profile.likedSongs.contains(songId)) _profile.likedSongs.add(songId);
      _profile.dislikedSongs.remove(songId);
    } else if (like == false) {
      rating.score -= 100;
      if (!_profile.dislikedSongs.contains(songId)) _profile.dislikedSongs.add(songId);
      _profile.likedSongs.remove(songId);
    }

    _ratings[songId] = rating;
    await _save();
  }

  void incrementPlayCount(String songId, double? playProgress) {
    var rating = _ratings[songId];
    // Раньше первый плей без prior rateSong терялся (return), а
    // RecommendationService уже считал — рассинхрон локального ML и KumaFlow Brain.
    rating ??= TrackRating(songId: songId);
    _ratings[songId] = rating;

    rating.playCount++;
    rating.score += 10;
    rating.lastPlayed = DateTime.now().toIso8601String();

    final hour = DateTime.now().hour;
    rating.hourPlayed.add(hour);
    if (rating.hourPlayed.length > 500) rating.hourPlayed.removeAt(0);

    final day = DateTime.now().weekday;
    rating.dayPlayed.add(day);
    if (rating.dayPlayed.length > 500) rating.dayPlayed.removeAt(0);

    if (rating.firstHeard == null) {
      rating.firstHeard = DateTime.now().toIso8601String();
    }

    if (playProgress != null && playProgress > 0.9) {
      rating.score += 15;
    }

    _ratings[songId] = rating;
    _save();
  }

  void incrementSkipCount(String songId, int? skipTime) {
    var rating = _ratings[songId];
    rating ??= TrackRating(songId: songId);
    _ratings[songId] = rating;

    rating.skipCount++;
    rating.lastSkipTime = skipTime ?? DateTime.now().millisecondsSinceEpoch;

    if (skipTime != null && skipTime < 30) {
      rating.score -= 15;
    } else {
      rating.score -= 5;
    }

    if (rating.skipCount >= 3 && rating.like != false) {
      rating.like = false;
      if (!_profile.dislikedSongs.contains(songId)) _profile.dislikedSongs.add(songId);
      _profile.likedSongs.remove(songId);
    }

    _ratings[songId] = rating;
    _save();
  }

  void recordReplay(String songId) {
    final rating = _ratings[songId];
    if (rating == null) return;

    rating.replayCount++;
    rating.score += 50;
    _ratings[songId] = rating;
    _save();
  }

  /// User seeked significantly backwards — re-listening, strong interest.
  void recordSeekBack(String songId) {
    var rating = _ratings[songId];
    rating ??= TrackRating(songId: songId);
    rating.seekBackCount++;
    rating.score += 30;
    rating.lastPlayed = DateTime.now().toIso8601String();
    _ratings[songId] = rating;
    _save();
  }

  /// Track left behind at 5–80% without an explicit skip. Soft negative.
  void recordAbandon(String songId) {
    var rating = _ratings[songId];
    rating ??= TrackRating(songId: songId);
    rating.abandonCount++;
    rating.score -= 8;
    _ratings[songId] = rating;
    _save();
  }

  void importLike(String songId, bool like, {Map<String, dynamic>? songInfo}) {
    Map<String, String>? si;
    if (songInfo != null) { si = {}; songInfo.forEach((k,v){ if(v!=null) si![k]=v.toString();}); }
    final rating = _ratings[songId] ?? TrackRating(songId: songId, songInfo: si);
    if (rating.like == like) return;
    rating.like = like;
    if (like) {
      rating.score += 50;
    } else {
      rating.score -= 50;
    }
    _ratings[songId] = rating;
    _save();
  }

  void importPlayCount(String songId, int serverPlayCount, {String? playedIso}) {    final rating = _ratings[songId];
    if (rating == null) {
      _ratings[songId] = TrackRating(songId: songId, songInfo: null)
        ..playCount = serverPlayCount
        ..score = serverPlayCount * 10
        ..lastPlayed = playedIso ?? DateTime.now().toIso8601String()
        ..firstHeard ??= playedIso ?? DateTime.now().toIso8601String();
      _save();
      return;
    }
    if (serverPlayCount <= rating.playCount) return;
    final delta = serverPlayCount - rating.playCount;
    rating.playCount = serverPlayCount;
    rating.score += delta * 10;
    if (playedIso != null) rating.lastPlayed = playedIso;
    _ratings[songId] = rating;
    _save();
  }

  /// Seed taste profile from cold-start onboarding (genres, artists, liked
  /// songs). Mirrors MLService.seedTaste so both ML stores stay in sync.
  /// Genre keys are lowercased to match TrackScorer lookups.
  Future<void> seedTaste({
    required Set<String> genres,
    required Map<String, double> artistWeights,
    List<String>? likedSongs,
  }) async {
    for (final g in genres) {
      final key = g.trim().toLowerCase();
      if (key.isEmpty) continue;
      _profile.preferredGenres[key] = (_profile.preferredGenres[key] ?? 0) + 1.0;
    }
    artistWeights.forEach((id, weight) {
      if (id.isEmpty) return;
      _profile.preferredArtists[id] =
          (_profile.preferredArtists[id] ?? 0) + weight;
    });
    if (likedSongs != null) {
      for (final id in likedSongs) {
        if (!_profile.likedSongs.contains(id)) _profile.likedSongs.add(id);
        _profile.dislikedSongs.remove(id);
      }
    }
    await _save();
  }

  /// Clear all ML data (used by full reset).
  Future<void> reset() async {
    _ratings.clear();
    _profile = MLProfile();
    _listeningHistory.clear();
    await _save();
  }

  double calculateTrackScore(String songId, {double timeBonus = 0}) {
    final rating = _ratings[songId];
    if (rating == null) return timeBonus;

    double score = rating.score.toDouble();
    if (rating.like == true) score += 100;
    if (rating.like == false) score -= 100;
    score += rating.replayCount * 50;
    score += rating.seekBackCount * 30;
    score -= rating.abandonCount * 8;
    if (rating.skipCount > 1) score -= rating.skipCount * 10;
    score += rating.playCount * 10;
    score += timeBonus;

    return score;
  }

  double calculateNoveltyScore(String songId) {
    final rating = _ratings[songId];
    if (rating == null) return 1.0;
    if (rating.lastPlayed == null) return 1.0;

    final lastPlayed = DateTime.tryParse(rating.lastPlayed!);
    if (lastPlayed == null) return 1.0;

    final daysSince = DateTime.now().difference(lastPlayed).inDays;
    return (daysSince / 30).clamp(0.0, 1.0);
  }

  void updateLastPlayed(String songId) {
    final rating = _ratings[songId];
    if (rating == null) return;
    rating.lastPlayed = DateTime.now().toIso8601String();
    _ratings[songId] = rating;
    _save();
  }

  void saveTrackAnalysis(String songId, Map<String, dynamic> analysis) {
    final rating = _ratings[songId] ?? TrackRating(songId: songId);
    rating.energy = (analysis['energy'] as num?)?.toDouble();
    rating.danceability = (analysis['danceability'] as num?)?.toDouble();
    rating.valence = (analysis['valence'] as num?)?.toDouble();
    rating.acousticness = (analysis['acousticness'] as num?)?.toDouble();
    rating.bpm = (analysis['bpm'] as num?)?.toDouble();
    _ratings[songId] = rating;
    _save();
  }

  void applyDecayFactor() {
    final genreKeys = _profile.preferredGenres.keys.toList();
    for (final key in genreKeys) {
      _profile.preferredGenres[key] = (_profile.preferredGenres[key] ?? 0) * 0.995;
    }
    final artistKeys = _profile.preferredArtists.keys.toList();
    for (final key in artistKeys) {
      _profile.preferredArtists[key] = (_profile.preferredArtists[key] ?? 0) * 0.995;
    }
    _save();
  }

  void banArtist(String artistId, String artistName) {
    if (!_profile.bannedArtists.contains(artistId)) {
      _profile.bannedArtists.add(artistId);
      _save();
    }
  }

  /// Регистрирует дизлайк трека артиста. Возвращает текущее число
  /// дизлайков по артисту. Используется правилом "3 дизлайка = бан артиста".
  int registerArtistDislike(String artistId) {
    final cur = (_profile.artistDislikeCounts[artistId] ?? 0) + 1;
    _profile.artistDislikeCounts[artistId] = cur;
    _save();
    return cur;
  }

  int getArtistDislikeCount(String artistId) =>
      _profile.artistDislikeCounts[artistId] ?? 0;

  void clearArtistDislikeCount(String artistId) {
    if (_profile.artistDislikeCounts.remove(artistId) != null) _save();
  }

  void unbanArtist(String artistId, String artistName) {
    _profile.bannedArtists.remove(artistId);
    _save();
  }

  void addListeningEvent(PlayEvent event) {
    _listeningHistory.add(event);
    if (_listeningHistory.length > 1000) {
      _listeningHistory.removeAt(0);
    }
    _save();
  }

  void cleanup({int maxAgeDays = 180}) {
    final cutoff = DateTime.now().subtract(Duration(days: maxAgeDays));
    _ratings.removeWhere((key, rating) {
      if (rating.lastPlayed == null) return false;
      final lastPlayed = DateTime.tryParse(rating.lastPlayed!);
      return lastPlayed != null && lastPlayed.isBefore(cutoff);
    });

    _listeningHistory.removeWhere((e) {
      final eventDate = DateTime.fromMillisecondsSinceEpoch(e.timestamp);
      return eventDate.isBefore(cutoff);
    });

    if (_ratings.length > 5000) {
      final sorted = _ratings.entries.toList()
        ..sort((a, b) => a.value.score.compareTo(b.value.score));
      for (int i = 0; i < sorted.length - 5000; i++) {
        _ratings.remove(sorted[i].key);
      }
    }

    _save();
  }
}
