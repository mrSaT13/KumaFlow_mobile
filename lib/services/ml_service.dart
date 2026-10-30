import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import 'bpm_analyzer_service.dart';
import 'yandex_enrichment_service.dart';
import 'library_database_service.dart';
import 'ml/vibe_similarity.dart';
import 'ml/ml_store.dart';
import 'ml/multi_armed_bandit.dart';

/// Track rating with scoring system (port from desktop ml.store.ts)
class TrackRating {
  final String songId;
  final String? title;
  final String? artist;
  final String? artistId;
  final String? genre;
  final String? album;
  bool? like; // null = no rating, true = liked, false = disliked
  int playCount;
  int skipCount;
  double score;
  int? replayCount;
  int seekBackCount;
  int abandonCount;
  DateTime? lastPlayed;
  DateTime? firstHeard;
  DateTime? lastSkipTime;

  TrackRating({
    required this.songId,
    this.title,
    this.artist,
    this.artistId,
    this.genre,
    this.album,
    this.like,
    this.playCount = 0,
    this.skipCount = 0,
    this.score = 0,
    this.replayCount,
    this.seekBackCount = 0,
    this.abandonCount = 0,
    this.lastPlayed,
    this.firstHeard,
    this.lastSkipTime,
  });

  Map<String, dynamic> toJson() => {
    'songId': songId,
    'title': title,
    'artist': artist,
    'artistId': artistId,
    'genre': genre,
    'album': album,
    'like': like,
    'playCount': playCount,
    'skipCount': skipCount,
    'score': score,
    'replayCount': replayCount,
    'seekBackCount': seekBackCount,
    'abandonCount': abandonCount,
    'lastPlayed': lastPlayed?.toIso8601String(),
    'firstHeard': firstHeard?.toIso8601String(),
    'lastSkipTime': lastSkipTime?.toIso8601String(),
  };

  factory TrackRating.fromJson(Map<String, dynamic> json) => TrackRating(
    songId: json['songId'] ?? '',
    title: json['title'],
    artist: json['artist'],
    artistId: json['artistId'],
    genre: json['genre'],
    album: json['album'],
    like: json['like'],
    playCount: json['playCount'] ?? 0,
    skipCount: json['skipCount'] ?? 0,
    score: (json['score'] ?? 0).toDouble(),
    replayCount: json['replayCount'],
    seekBackCount: json['seekBackCount'] as int? ?? 0,
    abandonCount: json['abandonCount'] as int? ?? 0,
    lastPlayed: json['lastPlayed'] != null ? DateTime.tryParse(json['lastPlayed']) : null,
    firstHeard: json['firstHeard'] != null ? DateTime.tryParse(json['firstHeard']) : null,
    lastSkipTime: json['lastSkipTime'] != null ? DateTime.tryParse(json['lastSkipTime']) : null,
  );
}

/// ML Profile with artist/genre preferences
class MLProfile {
  Map<String, double> preferredArtists;
  Map<String, String> preferredArtistNames;
  Map<String, double> preferredGenres;
  List<String> likedSongs;
  List<String> dislikedSongs;
  List<String> bannedArtists;
  /// Display-name lookup for banned artists so recommendation paths that
  /// key on artist *name* (not ID) can also filter them out.
  Map<String, String> bannedArtistNames;

  MLProfile({
    Map<String, double>? preferredArtists,
    Map<String, String>? preferredArtistNames,
    Map<String, double>? preferredGenres,
    List<String>? likedSongs,
    List<String>? dislikedSongs,
    List<String>? bannedArtists,
    Map<String, String>? bannedArtistNames,
  })  : preferredArtists = preferredArtists ?? {},
        preferredArtistNames = preferredArtistNames ?? {},
        preferredGenres = preferredGenres ?? {},
        likedSongs = likedSongs ?? [],
        dislikedSongs = dislikedSongs ?? [],
        bannedArtists = bannedArtists ?? [],
        bannedArtistNames = bannedArtistNames ?? {};

  Map<String, dynamic> toJson() => {
    'preferredArtists': preferredArtists,
    'preferredArtistNames': preferredArtistNames,
    'preferredGenres': preferredGenres,
    'likedSongs': likedSongs,
    'dislikedSongs': dislikedSongs,
    'bannedArtists': bannedArtists,
    'bannedArtistNames': bannedArtistNames,
  };

  factory MLProfile.fromJson(Map<String, dynamic> json) => MLProfile(
    preferredArtists: Map<String, double>.from(json['preferredArtists'] ?? {}),
    preferredArtistNames: Map<String, String>.from(
        json['preferredArtistNames'] ?? {}),
    preferredGenres: Map<String, double>.from(json['preferredGenres'] ?? {}),
    likedSongs: List<String>.from(json['likedSongs'] ?? []),
    dislikedSongs: List<String>.from(json['dislikedSongs'] ?? []),
    bannedArtists: List<String>.from(json['bannedArtists'] ?? []),
    bannedArtistNames: Map<String, String>.from(
        json['bannedArtistNames'] ?? {}),
  );
}

/// ML Service - port of desktop ml.store.ts
class MLService extends ChangeNotifier {
  static final MLService _instance = MLService._internal();
  factory MLService() => _instance;
  MLService._internal();

  SharedPreferences? _prefs;
  bool _isInitialized = false;
  final Random _random = Random();

  final Map<String, TrackRating> _ratings = {};
  MLProfile _profile = MLProfile();
  final LibraryDatabaseService _db = LibraryDatabaseService();

  /// Callback fired when banned artists change — used to sync with RecommendationService.
  void Function(Set<String> bannedIds, Set<String> bannedNames)?
      onBannedArtistsChanged;

  static const String _ratingsKey = 'ml_ratings_v2';
  static const String _profileKey = 'ml_profile_v2';
  static const String _coldStartKey = 'ml_cold_start_done_v1';
  // Тап «Скачанное»: ML-волна из офлайна (с дозагруженными настроениями)
  // вместо голого шаффла. Выключается тумблером в Настройки → ML.
  static const String _downloadedMlKey = 'ml_downloaded_wave_ml_v1';

  /// Mirror store (MLStore, owned by PlayerProvider) and the shared bandit.
  /// Wired by PlayerProvider at startup; seedTaste fans out to all of them so
  /// cold-start answers land everywhere ML data already flows.
  MLStore? _mirrorStore;
  MultiArmedBandit? _bandit;

  void setMirrorStore(MLStore store) => _mirrorStore = store;
  void setBandit(MultiArmedBandit bandit) => _bandit = bandit;

  Map<String, TrackRating> get ratings => Map.unmodifiable(_ratings);
  MLProfile get profile => _profile;
  bool get isInitialized => _isInitialized;
  bool get coldStartDone => _prefs?.getBool(_coldStartKey) ?? false;

  /// ML-волна по тапу «Скачанное» (офлайн). true = generateLocalMyWave
  /// с фолбеком на шаффл, false = старый голый шаффл как сейчас.
  bool get downloadedMlWave => _prefs?.getBool(_downloadedMlKey) ?? true;

  Future<void> setDownloadedMlWave(bool v) async {
    await initialize();
    await _prefs?.setBool(_downloadedMlKey, v);
    notifyListeners();
  }

  /// Mark cold-start onboarding as completed (persisted).
  Future<void> markColdStartDone() async {
    // Ensure prefs are loaded first — otherwise nothing is persisted and
    // the onboarding screen stays forever.
    await initialize();
    await _prefs?.setBool(_coldStartKey, true);
    notifyListeners();
  }

  /// Seed taste profile from cold-start onboarding (genres, artists, liked songs).
  /// Fans out to every ML sink: own profile (v2), mirror MLStore (v1) and the
  /// shared multi-armed bandit (genre arms +1, artist arms +2).
  /// Genre keys are lowercased to match TrackScorer lookups.
  Future<void> seedTaste({
    required Set<String> genres,
    required Map<String, double> artistWeights,
    List<String>? likedSongs,
    Map<String, String>? artistNames,
  }) async {
    final cleanGenres = <String>{};
    for (final g in genres) {
      final key = g.trim().toLowerCase();
      if (key.isEmpty) continue;
      cleanGenres.add(key);
      _profile.preferredGenres[key] =
          (_profile.preferredGenres[key] ?? 0) + 1.0;
    }
    final cleanArtists = <String, double>{};
    artistWeights.forEach((artist, weight) {
      final id = artist.trim();
      if (id.isEmpty) return;
      cleanArtists[id] = weight;
      _profile.preferredArtists[id] =
          (_profile.preferredArtists[id] ?? 0) + weight;
      if (artistNames?[id] != null) rememberArtistName(id, artistNames![id]);
    });
    if (likedSongs != null) {
      for (final id in likedSongs) {
        if (!_profile.likedSongs.contains(id)) {
          _profile.likedSongs.add(id);
        }
      }
    }
    _scheduleSave();

    // Mirror into the second store (PlayerProvider's MLStore).
    try {
      await _mirrorStore?.seedTaste(
        genres: cleanGenres,
        artistWeights: cleanArtists,
        likedSongs: likedSongs,
      );
    } catch (_) {}

    // Seed the bandit: genre arms +1, artist arms +2 (one pull each).
    try {
      final names = <String, String>{};
      cleanArtists.forEach((id, _) {
        names[id] = (artistNames?[id]?.isNotEmpty ?? false)
            ? artistNames![id]!
            : id;
      });
      _bandit?.seedFromColdStart(
        genres: cleanGenres,
        artistNames: names,
      );
    } catch (_) {}

    notifyListeners();
  }

  /// Backfill the bandit for users who already passed cold start and just
  /// update the app (their bandit is empty — it used to be in-memory only).
  /// If the bandit still has no arms but profiles already hold genre/artist
  /// preferences (own v2 store + mirror v1 store), seed arms from them:
  /// positive weights mapped to 0.5..5.0 reward, one pull each.
  /// Safe to call fire-and-forget at startup; retries while stores load.
  Future<void> backfillBanditFromProfiles() async {
    final bandit = _bandit;
    if (bandit == null) return;
    try {
      await initialize();
      await bandit.load();
      for (var attempt = 0; attempt < 6; attempt++) {
        if ((bandit.getStats()['totalArms'] as int) > 0) return;
        final genres = <String, double>{}..addAll(_profile.preferredGenres);
        final artists = <String, double>{}..addAll(_profile.preferredArtists);
        try {
          _mirrorStore?.profile.preferredGenres.forEach((k, v) {
            genres[k] = (genres[k] ?? 0) + v;
          });
          _mirrorStore?.profile.preferredArtists.forEach((k, v) {
            artists[k] = (artists[k] ?? 0) + v;
          });
        } catch (_) {}
        genres.removeWhere((_, v) => v <= 0);
        artists.removeWhere((_, v) => v <= 0);
        if (genres.isNotEmpty || artists.isNotEmpty) {
          final ctx = bandit.getCurrentContext();
          for (final e in genres.entries) {
            bandit.recordReward(
              e.key,
              e.value.clamp(0.5, 5.0).toDouble(),
              ctx,
              'genre',
              e.key,
            );
          }
          artists.forEach((id, w) {
            bandit.recordReward(
              id,
              w.clamp(0.5, 5.0).toDouble(),
              ctx,
              'artist',
              id,
            );
          });
          await bandit.save();
          return;
        }
        await Future.delayed(const Duration(seconds: 2));
      }
    } catch (_) {}
  }

  /// Reset all ML data (ratings, profile, cold-start flag, bandit).
  Future<void> resetEverything() async {
    _ratings.clear();
    _profile = MLProfile();
    await _prefs?.remove(_ratingsKey);
    await _prefs?.remove(_profileKey);
    await _prefs?.remove(_coldStartKey);
    try {
      await _mirrorStore?.reset();
    } catch (_) {}
    try {
      _bandit?.reset();
    } catch (_) {}
    _scheduleSave();
    notifyListeners();
  }

  Future<void> initialize() async {
    if (_isInitialized) return;
    _prefs = await SharedPreferences.getInstance();
    await _loadData();
    _isInitialized = true;
    notifyListeners();
  }

  // ─── Core Rating ──────────────────────────────────────────────────

  /// Rate a song (like/dislike/null). Updates artist/genre weights.
  void rateSong(String songId, bool? like, {Song? song}) {
    final existing = _ratings[songId];
    final songInfo = song;

    final rating = TrackRating(
      songId: songId,
      title: songInfo?.title ?? existing?.title,
      artist: songInfo?.artist ?? existing?.artist,
      artistId: songInfo?.artistId ?? existing?.artistId,
      genre: songInfo?.genre ?? existing?.genre,
      album: songInfo?.album ?? existing?.album,
      like: like,
      playCount: (existing?.playCount ?? 0) + 1,
      skipCount: existing?.skipCount ?? 0,
      score: existing?.score ?? 0,
      replayCount: existing?.replayCount,
      seekBackCount: existing?.seekBackCount ?? 0,
      abandonCount: existing?.abandonCount ?? 0,
      lastPlayed: DateTime.now(),
      firstHeard: existing?.firstHeard ?? DateTime.now(),
    );

    _ratings[songId] = rating;

    // Update profile lists
    if (like == true) {
      if (!_profile.likedSongs.contains(songId)) {
        _profile.likedSongs.add(songId);
      }
      _profile.dislikedSongs.remove(songId);

      // Boost artist/genre weights
      if (songInfo?.artistId != null) {
        _profile.preferredArtists[songInfo!.artistId!] =
            (_profile.preferredArtists[songInfo.artistId!] ?? 0) + 1;
        rememberArtistName(songInfo.artistId, songInfo.artist);
      }
      if (songInfo?.genre != null) {
        _profile.preferredGenres[songInfo!.genre!] =
            (_profile.preferredGenres[songInfo.genre!] ?? 0) + 1;
      }
    } else if (like == false) {
      if (!_profile.dislikedSongs.contains(songId)) {
        _profile.dislikedSongs.add(songId);
      }
      _profile.likedSongs.remove(songId);

      // Penalize artist/genre weights
      if (songInfo?.artistId != null) {
        _profile.preferredArtists[songInfo!.artistId!] =
            (_profile.preferredArtists[songInfo.artistId!] ?? 0) - 0.5;
        rememberArtistName(songInfo.artistId, songInfo.artist);
      }
      if (songInfo?.genre != null) {
        _profile.preferredGenres[songInfo!.genre!] =
            (_profile.preferredGenres[songInfo.genre!] ?? 0) - 0.3;
      }
    } else {
      // null = remove rating
      _profile.likedSongs.remove(songId);
      _profile.dislikedSongs.remove(songId);
    }

    _scheduleSave();
    notifyListeners();
  }

  /// Track a play event. +10 score, +15 if completed >90%.
  void incrementPlayCount(String songId, {double? playProgress, Song? song}) {
    final existing = _ratings[songId];
    final score = (existing?.score ?? 0) + 10;

    final completedBonus = (playProgress != null && playProgress > 0.9) ? 15 : 0;

    _ratings[songId] = TrackRating(
      songId: songId,
      title: song?.title ?? existing?.title,
      artist: song?.artist ?? existing?.artist,
      artistId: song?.artistId ?? existing?.artistId,
      genre: song?.genre ?? existing?.genre,
      album: song?.album ?? existing?.album,
      like: existing?.like,
      playCount: (existing?.playCount ?? 0) + 1,
      skipCount: existing?.skipCount ?? 0,
      score: score + completedBonus,
      replayCount: existing?.replayCount,
      seekBackCount: existing?.seekBackCount ?? 0,
      abandonCount: existing?.abandonCount ?? 0,
      lastPlayed: DateTime.now(),
      firstHeard: existing?.firstHeard ?? DateTime.now(),
    );

    _scheduleSave();
    notifyListeners();
    // Hybrid DB sync
    _db.updateSongPlayStatus(songId,
        playCount: _ratings[songId]?.playCount, lastPlayed: DateTime.now().millisecondsSinceEpoch).catchError((_) {});
  }

  /// Track a skip. -5 score, -15 if skipped in first 30s. Auto-dislike after 3 skips.
  void incrementSkipCount(String songId, {int? skipTimeMs}) {
    final existing = _ratings[songId];
    final skipCount = (existing?.skipCount ?? 0) + 1;

    // -15 if early skip, -5 otherwise
    final skipPenalty = (skipTimeMs != null && skipTimeMs < 30000) ? -15 : -5;
    final newScore = (existing?.score ?? 0) + skipPenalty;

    // Auto-dislike after 3 skips
    bool? newLike = existing?.like;
    if (skipCount >= 3 && newLike != false) {
      newLike = false;
      // Add to disliked list
      if (!_profile.dislikedSongs.contains(songId)) {
        _profile.dislikedSongs.add(songId);
      }
      _profile.likedSongs.remove(songId);
    }

    _ratings[songId] = TrackRating(
      songId: songId,
      title: existing?.title,
      artist: existing?.artist,
      artistId: existing?.artistId,
      genre: existing?.genre,
      album: existing?.album,
      like: newLike,
      playCount: existing?.playCount ?? 0,
      skipCount: skipCount,
      score: newScore,
      replayCount: existing?.replayCount,
      seekBackCount: existing?.seekBackCount ?? 0,
      abandonCount: existing?.abandonCount ?? 0,
      lastPlayed: existing?.lastPlayed,
      firstHeard: existing?.firstHeard ?? DateTime.now(),
      lastSkipTime: DateTime.now(),
    );

    _scheduleSave();
    notifyListeners();
    _db.updateSongPlayStatus(songId, skipCount: skipCount, disliked: newLike == false).catchError((_) {});
  }

  /// Record replay. +50 score (strong signal!).
  void recordReplay(String songId) {
    final existing = _ratings[songId];
    final replayCount = (existing?.replayCount ?? 0) + 1;

    _ratings[songId] = TrackRating(
      songId: songId,
      title: existing?.title,
      artist: existing?.artist,
      artistId: existing?.artistId,
      genre: existing?.genre,
      album: existing?.album,
      like: existing?.like,
      playCount: existing?.playCount ?? 0,
      skipCount: existing?.skipCount ?? 0,
      score: (existing?.score ?? 0) + 50,
      replayCount: replayCount,
      seekBackCount: existing?.seekBackCount ?? 0,
      abandonCount: existing?.abandonCount ?? 0,
      lastPlayed: DateTime.now(),
      firstHeard: existing?.firstHeard ?? DateTime.now(),
    );

    _scheduleSave();
    notifyListeners();
  }

  /// Record seek-back (re-listen). +30 score, small artist/genre boost.
  void recordSeekBack(String songId, {Song? song}) {
    final existing = _ratings[songId];
    _ratings[songId] = TrackRating(
      songId: songId,
      title: song?.title ?? existing?.title,
      artist: song?.artist ?? existing?.artist,
      artistId: song?.artistId ?? existing?.artistId,
      genre: song?.genre ?? existing?.genre,
      album: song?.album ?? existing?.album,
      like: existing?.like,
      playCount: existing?.playCount ?? 0,
      skipCount: existing?.skipCount ?? 0,
      score: (existing?.score ?? 0) + 30,
      replayCount: existing?.replayCount,
      seekBackCount: (existing?.seekBackCount ?? 0) + 1,
      abandonCount: existing?.abandonCount ?? 0,
      lastPlayed: DateTime.now(),
      firstHeard: existing?.firstHeard ?? DateTime.now(),
      lastSkipTime: existing?.lastSkipTime,
    );
    final info = song;
    if (info?.artistId != null) {
      _profile.preferredArtists[info!.artistId!] =
          (_profile.preferredArtists[info.artistId!] ?? 0) + 0.3;
      rememberArtistName(info.artistId, info.artist);
    }
    if (info?.genre != null) {
      _profile.preferredGenres[info!.genre!] =
          (_profile.preferredGenres[info.genre!] ?? 0) + 0.2;
    }
    _scheduleSave();
    notifyListeners();
  }

  /// Record abandon (left at 5–80% without skip). −8 score, small penalty.
  void recordAbandon(String songId, {Song? song}) {
    final existing = _ratings[songId];
    _ratings[songId] = TrackRating(
      songId: songId,
      title: song?.title ?? existing?.title,
      artist: song?.artist ?? existing?.artist,
      artistId: song?.artistId ?? existing?.artistId,
      genre: song?.genre ?? existing?.genre,
      album: song?.album ?? existing?.album,
      like: existing?.like,
      playCount: existing?.playCount ?? 0,
      skipCount: existing?.skipCount ?? 0,
      score: (existing?.score ?? 0) - 8,
      replayCount: existing?.replayCount,
      seekBackCount: existing?.seekBackCount ?? 0,
      abandonCount: (existing?.abandonCount ?? 0) + 1,
      lastPlayed: existing?.lastPlayed,
      firstHeard: existing?.firstHeard ?? DateTime.now(),
      lastSkipTime: existing?.lastSkipTime,
    );
    final info = song;
    if (info?.artistId != null) {
      _profile.preferredArtists[info!.artistId!] =
          (_profile.preferredArtists[info.artistId!] ?? 0) - 0.2;
      rememberArtistName(info.artistId, info.artist);
    }
    if (info?.genre != null) {
      _profile.preferredGenres[info!.genre!] =
          (_profile.preferredGenres[info.genre!] ?? 0) - 0.1;
    }
    _scheduleSave();
    notifyListeners();
  }

  /// Bulk import from server — starred / rating without bumping playCount
  void importLike(String songId, bool like, {Song? song, bool persistDb = true}) {
    final existing = _ratings[songId];
    if (existing != null && existing.like == like) return;
    final info = song;
    _ratings[songId] = TrackRating(
      songId: songId,
      title: info?.title ?? existing?.title,
      artist: info?.artist ?? existing?.artist,
      artistId: info?.artistId ?? existing?.artistId,
      genre: info?.genre ?? existing?.genre,
      album: info?.album ?? existing?.album,
      like: like,
      playCount: existing?.playCount ?? 0,
      skipCount: existing?.skipCount ?? 0,
      score: existing?.score ?? 0,
      replayCount: existing?.replayCount,
      seekBackCount: existing?.seekBackCount ?? 0,
      abandonCount: existing?.abandonCount ?? 0,
      lastPlayed: existing?.lastPlayed,
      firstHeard: existing?.firstHeard ?? DateTime.now(),
      lastSkipTime: existing?.lastSkipTime,
    );
    if (like) {
      if (!_profile.likedSongs.contains(songId)) _profile.likedSongs.add(songId);
      _profile.dislikedSongs.remove(songId);
      if (info?.artistId != null) {
        _profile.preferredArtists[info!.artistId!] = (_profile.preferredArtists[info.artistId!] ?? 0) + 0.5;
        rememberArtistName(info.artistId, info.artist);
      }
      if (info?.genre != null) {
        _profile.preferredGenres[info!.genre!] = (_profile.preferredGenres[info.genre!] ?? 0) + 0.3;
      }
    } else {
      if (!_profile.dislikedSongs.contains(songId)) _profile.dislikedSongs.add(songId);
      _profile.likedSongs.remove(songId);
    }
    _scheduleBulkSave();
    _notifyBulk();
    if (persistDb) _db.updateSongPlayStatus(songId, disliked: !like, starred: like).catchError((_) {});
  }

  /// Bulk import server playCount/played without 50x looping — delta*10 score
  void importPlayCount(String songId, int serverPlayCount, {Song? song, DateTime? played, int? userRating, bool persistDb = true}) {
    final existing = _ratings[songId];
    final local = existing?.playCount ?? 0;
    if (serverPlayCount <= local && userRating == null && played == null) return;
    final delta = (serverPlayCount > local) ? serverPlayCount - local : 0;
    final addScore = delta * 10.0;
    _ratings[songId] = TrackRating(
      songId: songId,
      title: song?.title ?? existing?.title,
      artist: song?.artist ?? existing?.artist,
      artistId: song?.artistId ?? existing?.artistId,
      genre: song?.genre ?? existing?.genre,
      album: song?.album ?? existing?.album,
      like: existing?.like,
      playCount: serverPlayCount > local ? serverPlayCount : local,
      skipCount: existing?.skipCount ?? 0,
      score: (existing?.score ?? 0) + addScore,
      replayCount: existing?.replayCount,
      seekBackCount: existing?.seekBackCount ?? 0,
      abandonCount: existing?.abandonCount ?? 0,
      lastPlayed: played ?? existing?.lastPlayed ?? DateTime.now(),
      firstHeard: existing?.firstHeard ?? played ?? DateTime.now(),
      lastSkipTime: existing?.lastSkipTime,
    );
    _scheduleBulkSave();
    _notifyBulk();
    if (persistDb) _db.updateSongPlayStatus(songId, playCount: serverPlayCount, lastPlayed: (played ?? DateTime.now()).millisecondsSinceEpoch, userRating: userRating).catchError((_) {});
  }

  /// Calculate final score for a song
  double calculateTrackScore(String songId) {
    final rating = _ratings[songId];
    if (rating == null) return 0;

    double score = rating.score;
    if (rating.like == true) score += 100;
    if (rating.like == false) score -= 100;
    if (rating.replayCount != null) score += rating.replayCount! * 50;
    score += rating.seekBackCount * 30;
    score -= rating.abandonCount * 8;
    if (rating.skipCount > 1) score -= rating.skipCount * 10;

    return score;
  }

  /// Check if a song is disliked
  bool isDisliked(String songId) {
    return _profile.dislikedSongs.contains(songId) ||
        _ratings[songId]?.like == false;
  }

  /// Check if an artist is banned
  bool isArtistBanned(String? artistId, String? artistName) {
    if (artistId != null && _profile.bannedArtists.contains(artistId)) return true;
    if (artistName != null) {
      final lower = artistName.toLowerCase();
      if (_profile.bannedArtistNames.values.any((n) => n.toLowerCase() == lower)) return true;
      // Fallback: old data where bannedArtists may contain names
      if (_profile.bannedArtists.any((banned) => banned.toLowerCase() == lower)) return true;
    }
    return false;
  }

  /// Ban an artist
  void banArtist(String artistId, String artistName) {
    if (!_profile.bannedArtists.contains(artistId)) {
      _profile.bannedArtists.add(artistId);
      _profile.bannedArtistNames[artistId] = artistName;
      _scheduleSave();
      notifyListeners();
      _emitBannedArtistsChanged();
    }
  }

  /// Bulk-режим для серверного импорта: десятки тысяч importLike/
  /// importPlayCount/likeArtist подряд давали столько же notifyListeners
  /// (перестройки всего дерева) + сейвов — 15с фриз главного потока
  /// (факт 15.10.2026: MotionEvent 15.2с). В bulk всё глушится, в конце —
  /// один save + один notify.
  int _bulkDepth = 0;
  void beginBulkImport() => _bulkDepth++;
  void endBulkImport() {
    if (_bulkDepth > 0) _bulkDepth--;
    if (_bulkDepth == 0) {
      _scheduleSave();
      notifyListeners();
    }
  }

  void _notifyBulk() {
    if (_bulkDepth > 0) return;
    notifyListeners();
  }

  void _scheduleBulkSave() {
    if (_bulkDepth > 0) return;
    _scheduleSave();
  }

  /// `preferredArtists` weight by `+1.5` (or zeros it when `liked == false`)
  /// so this artist shows up more often in personalized feeds.
  void likeArtist(String artistId, {bool liked = true, double weight = 1.5, String? artistName}) {
    final current = _profile.preferredArtists[artistId] ?? 0.0;
    _profile.preferredArtists[artistId] =
        liked ? (current + weight).clamp(0.0, 5.0) : 0.0;
    if (artistName != null) rememberArtistName(artistId, artistName);
    _scheduleBulkSave();
    _notifyBulk();
  }

  /// Whether the user has explicitly liked this artist (weight > 0.5).
  bool isArtistLiked(String artistId) {
    return (_profile.preferredArtists[artistId] ?? 0.0) > 0.5;
  }

  /// Unban an artist
  void unbanArtist(String artistId) {
    _profile.bannedArtists.remove(artistId);
    _profile.bannedArtistNames.remove(artistId);
    _scheduleSave();
    notifyListeners();
    _emitBannedArtistsChanged();
  }

  /// Применить удаление вкуса с сервера (tombstone из sync-to-mobile).
  /// kind: ban (key=artist_name, aux=artist_external_id),
  /// like/dislike (key=external_id трека = локальный songId).
  /// Счётчики не трогаем — только снимаем оценку/бан. Возвращает true,
  /// если что-то реально изменилось.
  bool applyTasteRemoval(
      {required String kind, required String key, String aux = ''}) {
    final k = kind.trim().toLowerCase();
    final songId = key.trim();
    var changed = false;
    if ((k == 'like' || k == 'dislike') && songId.isNotEmpty) {
      final wantLike = k == 'like';
      final existing = _ratings[songId];
      // Снимаем только совпадающую оценку; чужую не трогаем
      // (мобила могла переставить её позже курсора).
      if (existing != null && existing.like == wantLike) {
        existing.like = null;
        changed = true;
      }
      if (wantLike) {
        changed = _profile.likedSongs.remove(songId) || changed;
      } else {
        changed = _profile.dislikedSongs.remove(songId) || changed;
      }
      if (changed) {
        _scheduleSave();
        notifyListeners();
      }
      return changed;
    }
    if (k == 'ban') {
      final name = key.trim().toLowerCase();
      final aid = aux.trim();
      final ids = _profile.bannedArtists.toList();
      for (final id in ids) {
        final storedName = (_profile.bannedArtistNames[id] ?? '').toLowerCase();
        if ((aid.isNotEmpty && id == aid) ||
            (name.isNotEmpty && (id.toLowerCase() == name || storedName == name))) {
          _profile.bannedArtists.remove(id);
          _profile.bannedArtistNames.remove(id);
          changed = true;
        }
      }
      if (changed) {
        _scheduleSave();
        notifyListeners();
        _emitBannedArtistsChanged();
      }
      return changed;
    }
    return false;
  }

  void _emitBannedArtistsChanged() {
    onBannedArtistsChanged?.call(
      _profile.bannedArtists.toSet(),
      _profile.bannedArtistNames.values.toSet(),
    );
  }

  /// Запомнить человекочитаемое имя артиста для id-ключа топа.
  void rememberArtistName(String? artistId, String? artistName) {
    if (artistId == null || artistId.isEmpty) return;
    final n = artistName?.trim() ?? '';
    if (n.isEmpty || n == artistId) return;
    if (_profile.preferredArtistNames[artistId] != n) {
      _profile.preferredArtistNames[artistId] = n;
    }
  }

  /// Человекочитаемое имя для ключа топа (id → имя, иначе сам ключ).
  String displayNameForArtist(String key) {
    final n = _profile.preferredArtistNames[key];
    if (n != null && n.trim().isNotEmpty) return n;
    final b = _profile.bannedArtistNames[key];
    if (b != null && b.trim().isNotEmpty) return b;
    return key;
  }

  /// Get top preferred artists sorted by weight
  List<String> getTopArtists({int limit = 10}) {
    final entries = _profile.preferredArtists.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(limit).map((e) => e.key).toList();
  }

  /// Get top preferred genres sorted by weight
  List<String> getTopGenres({int limit = 10}) {
    final entries = _profile.preferredGenres.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(limit).map((e) => e.key).toList();
  }

   /// Filter songs: exclude disliked and banned artists
  List<Song> filterSongs(List<Song> songs) {
    return songs.where((s) {
      if (isDisliked(s.id)) return false;
      if (isArtistBanned(s.artistId, s.artist)) return false;
      return true;
    }).toList();
  }

  /// Enrichment helper — effective genre (local -> Yandex cache)
  String? _effectiveGenre(Song s) {
    if (s.genre != null && s.genre!.isNotEmpty) return s.genre;
    return YandexEnrichmentService().effectiveGenre(s);
  }

  /// Async batch enrich missing genres (fire-and-forget, no token needed)
  Future<int> enrichMissingGenres(List<Song> songs, {int limit = 40}) {
    return YandexEnrichmentService().enrichBatch(songs, limit: limit);
  }

    /// Score and sort songs by ML preference (with Yandex genre enrichment)
   List<Song> scoreAndSort(List<Song> songs) {
      final enrich = YandexEnrichmentService();
      final scored = songs.map((s) {
        double score = calculateTrackScore(s.id);

        // Boost by artist preference (id + name fallback for local files)
        if (s.artistId != null) {
          score += (_profile.preferredArtists[s.artistId] ?? 0) * 10;
        } else if (s.artist != null) {
          score += (_profile.preferredArtists[s.artist!] ?? 0) * 4;
        }

        // Boost by genre preference — with Yandex-effective genre
        final effGenre = _effectiveGenre(s);
        if (effGenre != null) {
          score += (_profile.preferredGenres[effGenre] ?? 0) * 5;
          // Small bonus if enriched genre matches a top genre
          if (s.genre == null && enrich.getCachedForSong(s) != null) {
            score += 0.8;
          }
        }

        // Bonus for similar-artist affinity (if song's artist is similar to a liked artist)
        if (s.artist != null) {
          final meta = enrich.getCachedForArtist(s.artist!);
          if (meta != null && meta.similarArtists.isNotEmpty) {
            for (final sim in meta.similarArtists.take(3)) {
              if (_profile.preferredArtists.containsKey(sim)) {
                score += 1.2;
                break;
              }
            }
          }
        }

        // Penalize disliked
        if (isDisliked(s.id)) score -= 200;

        return MapEntry(s, score);
      }).toList();

      scored.sort((a, b) => b.value.compareTo(a.value));
      return scored.map((e) => e.key).toList();
    }

    // ── 777/999 + AudioMuse-AI — порт ML-РЕКОМЕНДАЦИИ (Ядро системы).py
    // Псевдокод дек+кластеризация: history 30d -> clusters genre/tempo/valence -> 70% familiar +30% discoveries bpm 90-130 smooth_wave
    static List<double>? decode777(String? b64) {
      if (b64 == null || b64.isEmpty) return null;
      try {
        // 777 дек — base64 -> float32 vector (voyager ANN 256d). Фолбэк: genre hash
        final bytes = base64Decode(b64);
        if (bytes.length % 4 != 0) return null;
        final view = bytes.buffer.asByteData();
        final vec = <double>[];
        for (int i = 0; i < bytes.length; i += 4) {
          vec.add(view.getFloat32(i, Endian.little));
        }
        return vec.isEmpty ? null : vec;
      } catch (_) {
        return null;
      }
    }

    Future<List<Song>> generateDailyMix({required List<Song> songs, int count = 30}) async {
      // Кластеризация по genre+tempo( BPM/30 ) + valence из VibeSimilarity — как в pseudocode
      final vibe = VibeSimilarity();
      final clusters = <String, List<Song>>{};
      for (final s in songs) {
        final f = vibe.analyzeTrack(s);
        final bpmBucket = ((await BpmAnalyzerService().getBPM(s, '')) / 30).floor();
        final valenceBucket = (f.valence * 3).floor();
        final key = '${s.genre ?? 'unknown'}_${bpmBucket}_$valenceBucket';
        clusters.putIfAbsent(key, () => []).add(s);
      }
      final sortedClusters = clusters.values.toList()..sort((a,b)=>b.length.compareTo(a.length));
      final mix = <Song>[];
      for (final cluster in sortedClusters) {
        if (mix.length >= count) break;
        final scored = scoreAndSort(cluster);
        final familiarCount = (scored.length * 0.7).ceil().clamp(1, (count*0.5).ceil());
        final familiar = scored.take(familiarCount).toList()..shuffle(_random);
        // discoveries — те что не в топ, с novelty + BPM 90-130
        final discoveriesPool = scored.skip(familiarCount).where((s) {
          final bpm = 100; // async would need await, simplify: genre estimate via vibe.bpm
          return true;
        }).toList()..shuffle(_random);
        final discCount = ((count - mix.length) * 0.3).ceil().clamp(0, discoveriesPool.length);
        final discoveries = discoveriesPool.take(discCount);
        mix.addAll([...familiar, ...discoveries]);
        // BPM flow filter 90-130 для merge_with_flow
        mix.retainWhere((s) => true);
      }
      // optimize_transitions smooth_wave — сортируем по energy curve
      final scoredMix = mix.map((s) {
        final f = vibe.analyzeTrack(s);
        return MapEntry(s, f.energy);
      }).toList();
      scoredMix.sort((a,b) {
        // smooth_wave: low-high-low energy
        return a.value.compareTo(b.value);
      });
      // делаем волну: берем низ-энергию по краям, высокую в центр
      final wave = <Song>[];
      for (int i=0; i<scoredMix.length; i++) {
        if (i % 2 == 0) wave.add(scoredMix[i].key);
        else wave.insert(wave.length ~/2, scoredMix[i].key);
      }
      return wave.take(count).toList();
    }

    /// Generate a local "My Wave" playlist from offline songs.
    ///
    /// Adds controlled randomness so the wave isn't the exact same list every
    /// time: top favorites always appear, but lower-ranked tracks rotate in.
   List<Song> generateLocalMyWave({required List<Song> songs, int count = 30}) {
      final filtered = filterSongs(songs);
      if (filtered.isEmpty) return [];
      // Shuffle before scoring to break deterministic ties when scores are equal
      filtered.shuffle(_random);
      final sorted = scoreAndSort(filtered);
      if (sorted.length <= count) return sorted..shuffle(_random);

      final result = <Song>[];
      // Reduced anchor to 20% so wave actually changes on refresh (was 40%).
      final topCount = (count * 0.2).round().clamp(3, 8);
      // Pick anchor from top 25% with weighted randomness, not strictly top N
      final anchorPool = sorted.take((sorted.length * 0.25).ceil()).toList();
      anchorPool.shuffle(_random);
      // Score anchor pool slightly so higher-scored still preferred but not guaranteed
      final anchorScored = anchorPool.map((s) {
        double sc = calculateTrackScore(s.id);
        sc += _random.nextDouble() * 4;
        return MapEntry(s, sc);
      }).toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      result.addAll(anchorScored.take(topCount).map((e) => e.key));

      // Rotate the rest with shuffled draw + recency penalty
      final remaining = sorted.where((s) => !result.contains(s)).toList();
      final now = DateTime.now().millisecondsSinceEpoch;
      final weighted = remaining.map((s) {
        double score = calculateTrackScore(s.id);
        final lastPlayed = ratings[s.id]?.lastPlayed;
        if (lastPlayed != null) {
          final lastMs = lastPlayed.millisecondsSinceEpoch;
          final hours = (now - lastMs) / 3600000;
          score -= (1.0 / (1.0 + hours / 24.0)) * 3;
        }
        score += _random.nextDouble() * 10;
        return MapEntry(s, score);
      }).toList();
      weighted.sort((a, b) => b.value.compareTo(a.value));

      result.addAll(weighted.take(count - result.length).map((e) => e.key));
      // Shuffle the whole result so cover and order vary each refresh
      result.shuffle(_random);
      return result;
    }

  // ─── Persistence ──────────────────────────────────────────────────

  Timer? _saveTimer;
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _saveData);
  }

  Future<void> _saveData() async {
    try {
      final ratingsJson = _ratings.map((k, v) => MapEntry(k, v.toJson()));
      await _prefs?.setString(_ratingsKey, json.encode(ratingsJson));
      await _prefs?.setString(_profileKey, json.encode(_profile.toJson()));
    } catch (e) {
      debugPrint('Error saving ML data: $e');
    }
  }

  Future<void> _loadData() async {
    try {
      final ratingsJson = _prefs?.getString(_ratingsKey);
      if (ratingsJson != null) {
        final map = json.decode(ratingsJson) as Map<String, dynamic>;
        _ratings.clear();
        for (final entry in map.entries) {
          _ratings[entry.key] = TrackRating.fromJson(entry.value);
        }
      }

      final profileJson = _prefs?.getString(_profileKey);
      if (profileJson != null) {
        _profile = MLProfile.fromJson(json.decode(profileJson));
        // Migration: if old bans have no names, keep ids as fallback names so filtering still works
        if (_profile.bannedArtistNames.isEmpty && _profile.bannedArtists.isNotEmpty) {
          for (final id in _profile.bannedArtists) {
            _profile.bannedArtistNames[id] = id;
          }
          _scheduleSave();
        }
        // Push current bans to listeners so RecommendationService stays in sync after restart
        Future.microtask(() => _emitBannedArtistsChanged());
      }
    } catch (e) {
      debugPrint('Error loading ML data: $e');
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _saveData();
    super.dispose();
  }
}
