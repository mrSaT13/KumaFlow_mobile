import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import '../models/ml/ml_types.dart';
import 'ml/vibe_similarity.dart';
import 'ml/sonic_fingerprint.dart';
import 'ml/multi_armed_bandit.dart';
import 'ml/time_aware_history.dart';
import 'ml/mood_drift_detector.dart';
import 'ml/item_similarity.dart';
import 'yandex_enrichment_service.dart';
import 'library_database_service.dart';
import 'lyrics_mood_service.dart';
import '../models/lyrics.dart';

// Isolate helpers for heavy JSON (80k profiles)
String _encodeJsonIsolate(Object data) => json.encode(data);

/// Top-level entry для compute(): считает миксы в отдельном изоляте.
/// Принимает/возвращает только plain-data (SendPort-совместимо).
/// В изоляте нет prefs/БД/сети — всё состояние едет в [payload].
Future<Map<String, List<Map<String, dynamic>>>> generateMixesIsolateEntry(
  Map<String, dynamic> payload,
) async {
  Map<String, double> doubles(dynamic raw) => (raw as Map? ?? {}).map(
        (k, v) => MapEntry(k as String, (v as num).toDouble()),
      );
  final svc = RecommendationService._forIsolate(
    enabled: payload['enabled'] as bool? ?? true,
    profiles: (payload['profiles'] as Map? ?? {}).map(
      (k, v) => MapEntry(
          k as String, SongProfile.fromJson(Map<String, dynamic>.from(v as Map))),
    ),
    artistAffinity: doubles(payload['artistAffinity']),
    genreAffinity: doubles(payload['genreAffinity']),
    albumAffinity: doubles(payload['albumAffinity']),
    artistRatingAffinity: doubles(payload['artistRatingAffinity']),
    genreRatingAffinity: doubles(payload['genreRatingAffinity']),
    skipCounts: (payload['skipCounts'] as Map? ?? {})
        .map((k, v) => MapEntry(k as String, (v as num).toInt())),
    timePatterns: (payload['timePatterns'] as Map? ?? {}).map(
      (k, v) {
        final parsed = int.tryParse(k.toString());
        if (parsed == null) return MapEntry(-1, <String, double>{});
        return MapEntry(parsed, doubles(v));
      },
    )..removeWhere((k, _) => k == -1),
    bannedIds: Set<String>.from(payload['bannedIds'] as List? ?? const []),
    bannedNames: Set<String>.from(payload['bannedNames'] as List? ?? const []),
    recentlyPlayed:
        List<String>.from(payload['recentlyPlayed'] as List? ?? const []),
    starred: Set<String>.from(payload['starred'] as List? ?? const []),
    enrichGenres: Map<String, String>.from(payload['enrichGenres'] as Map? ?? {}),
    enrichSimilar: (payload['enrichSimilar'] as Map? ?? {}).map(
      (k, v) => MapEntry(k as String, List<String>.from(v as List)),
    ),
    bpm: doubles(payload['bpm']),
  );
  final songs = (payload['songs'] as List)
      .map((m) => Song.fromJson(Map<String, dynamic>.from(m as Map)))
      .toList();
  final mixes = await svc.generateMixes(songs);
  return mixes.map((k, v) => MapEntry(k, v.map((s) => s.toJson()).toList()));
}

abstract class _W {
  static const double artistAffinity = 0.28;
  static const double genreAffinity = 0.18;
  static const double artistRating = 0.11;
  static const double genreRating = 0.07;
  static const double albumAffinity = 0.06;
  static const double completionRate = 0.09;
  static const double hourPreference = 0.05;
  static const double playCountSignal = 0.04;
  static const double userRating = 0.10;
  static const double songLevelRating = 0.06;
  static const double averageRating = 0.05;
  static const double starBonus = 0.20;
  static const double noveltyBonus = 0.08;
  static const double skipPenaltyPerSkip = 0.06;
  static const double maxSkipPenalty = 0.35;
  static const double recencyPenaltyStep = 0.015;
  static const double timePatternsBonus = 0.05;
  static const double randomJitter = 0.12;
}

const _kDecayHalfLifeDays = 30.0;

class RecommendationService extends ChangeNotifier {
  static const _kDataKey = 'rec_data_v3';
  static const _kSkipKey = 'rec_skips_v3';
  static const _kTimeKey = 'rec_time_v3';
  static const _kEnabledKey = 'recommendations_enabled';
  static const _kDecayKey = 'rec_decay_ts';

  bool _enabled = true;

  /// Optional reference to a [SonicFingerprintService] used to score
  /// candidates against the user's recent sonic fingerprint. Wired in
  /// from `PlayerProvider` so home/mixes playlists can favor tracks that
  /// match the user's actual sound taste (not just liked-artist bias).
  SonicFingerprintService? _fingerprint;
  void setSonicFingerprint(SonicFingerprintService fp) {
    _fingerprint = fp;
  }

  /// Optional reference to a [MultiArmedBandit] that learns which artists
  /// and genres the user actually keeps playing (by time-of-day / weekday
  /// context). Its top-performing arms get a small bonus in `_sortByScore`.
  /// Wired in from `PlayerProvider`.
  MultiArmedBandit? _bandit;
  void setMultiArmedBandit(MultiArmedBandit bandit) {
    _bandit = bandit;
  }

  // Hybrid DB — coarse filters (not-played/played/disliked) via WHERE + index, pool 2-5k for in-memory ML
  final LibraryDatabaseService _db = LibraryDatabaseService();

  /// Top-performing artist/genre arm ids from the bandit, capped at [count].
  /// Empty when the bandit hasn't learned anything yet.
  Set<String> _topArmIds(int count) {
    final bandit = _bandit;
    if (bandit == null) return const {};
    final top = bandit.getTopArms(count);
    if (top.isEmpty) return const {};
    return {for (final a in top) a.id};
  }

  /// Optional reference to a [TimeAwareHistory] so `_sortByScore` can boost
  /// tracks the user listens to around this hour of day. Wired in from
  /// `PlayerProvider`.
  TimeAwareHistory? _timeHistory;
  void setTimeAwareHistory(TimeAwareHistory history) {
    _timeHistory = history;
  }

  /// Optional reference to a [MoodDriftDetector] so `_sortByScore` can skip
  /// recently temp-banned artists/genres and prefer calmer picks when the
  /// user has been skipping a lot (mood drift). Wired in from `PlayerProvider`.
  MoodDriftDetector? _moodDrift;
  void setMoodDriftDetector(MoodDriftDetector detector) {
    _moodDrift = detector;
  }

  ItemSimilarityService? _itemSim;
  void setItemSimilarity(ItemSimilarityService svc) {
    _itemSim = svc;
  }

  SharedPreferences? _prefs;

  Map<String, SongProfile> _profiles = {};
  Map<String, double> _artistAffinity = {};
  Map<String, double> _genreAffinity = {};
  Map<String, double> _albumAffinity = {};
  Map<String, double> _artistRatingAffinity = {};
  Map<String, double> _genreRatingAffinity = {};
  Map<String, int> _skipCounts = {};
  Map<int, Map<String, double>> _timePatterns = {};

  /// Set of banned artist IDs — updated from MLService to exclude from recommendations.
  Set<String> _bannedArtists = {};
  /// Set of banned artist NAMES — populated by `updateBannedArtists(ids, names)`
  /// alongside the IDs. Some recommendation paths (Quick Picks, top-artists)
  /// key on the artist *name* (not ID), so the name set is required for
  /// proper filtering of mixes that the user has previously played a lot.
  Set<String> _bannedArtistsNames = {};
  void updateBannedArtists(Set<String> ids, {Set<String>? names}) {
    final prevIds = _bannedArtists;
    final prevNames = _bannedArtistsNames;
    _bannedArtists = ids;
    if (names != null) _bannedArtistsNames = names;
    // Hybrid DB sync — fire-and-forget, keeps WHERE banned fast
    final addedIds = ids.difference(prevIds);
    final removedIds = prevIds.difference(ids);
    if (addedIds.isNotEmpty) _db.setBannedForArtists(addedIds, true).catchError((_) {});
    if (removedIds.isNotEmpty) _db.setBannedForArtists(removedIds, false).catchError((_) {});
    if (names != null) {
      final addedNames = names.difference(prevNames);
      final removedNames = prevNames.difference(names);
      if (addedNames.isNotEmpty) _db.setBannedForArtistNames(addedNames, true).catchError((_) {});
      if (removedNames.isNotEmpty) _db.setBannedForArtistNames(removedNames, false).catchError((_) {});
    }
  }

  /// Stable hash of the banned-artist set, used as part of the mix cache key
  /// so unban/ban immediately invalidates cached mixes on screen.
  String get bannedArtistsKey =>
      _bannedArtists.join(',') + '|' + _bannedArtistsNames.join(',');
  List<String> _recentlyPlayed = [];
  Set<String> _starredSongs = {};

  Map<String, int> _recentIndex = {};

  // ── Isolate-режим: снапшот состояния для compute(). В изоляте нет
  // SharedPreferences/БД/сети — только переданные карты. Нейросервисы
  // (_bandit/_timeHistory/_moodDrift/_itemSim/_fingerprint) остаются null,
  // их бонусы тихо пропускаются (null-guards уже есть в _sortByScore).
  bool _inIsolate = false;
  Map<String, String>? _enrichGenreOverride;
  Map<String, List<String>>? _enrichSimilarOverride;
  Map<String, double>? _bpmOverride;

  RecommendationService();

  /// Конструктор для фонового изолята: восстанавливает состояние из
  /// снапшота [buildMixIsolatePayload], без prefs/БД/сети.
  RecommendationService._forIsolate({
    required bool enabled,
    required Map<String, SongProfile> profiles,
    required Map<String, double> artistAffinity,
    required Map<String, double> genreAffinity,
    required Map<String, double> albumAffinity,
    required Map<String, double> artistRatingAffinity,
    required Map<String, double> genreRatingAffinity,
    required Map<String, int> skipCounts,
    required Map<int, Map<String, double>> timePatterns,
    required Set<String> bannedIds,
    required Set<String> bannedNames,
    required List<String> recentlyPlayed,
    required Set<String> starred,
    required Map<String, String> enrichGenres,
    required Map<String, List<String>> enrichSimilar,
    required Map<String, double> bpm,
  }) {
    _inIsolate = true;
    _enabled = enabled;
    _profiles = profiles;
    _artistAffinity = artistAffinity;
    _genreAffinity = genreAffinity;
    _albumAffinity = albumAffinity;
    _artistRatingAffinity = artistRatingAffinity;
    _genreRatingAffinity = genreRatingAffinity;
    _skipCounts = skipCounts;
    _timePatterns = timePatterns;
    _bannedArtists = bannedIds;
    _bannedArtistsNames = bannedNames;
    _recentlyPlayed = recentlyPlayed;
    _starredSongs = starred;
    _enrichGenreOverride = enrichGenres;
    _enrichSimilarOverride = enrichSimilar;
    _bpmOverride = bpm;
    _rebuildRecentIndex();
  }

  DateTime _lastDecayApplied = DateTime.fromMillisecondsSinceEpoch(0);

  Timer? _saveTimer;
  static const _kSaveDebounceMs = 800;

  double? _maxArtistAffinity;
  double? _maxGenreAffinity;
  double? _maxAlbumAffinity;
  double? _maxArtistRating;
  double? _maxGenreRating;

  bool get enabled => _enabled;
  Map<String, SongProfile> get profiles => Map.unmodifiable(_profiles);
  List<String> get recentlyPlayed => List.unmodifiable(_recentlyPlayed);

  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    _enabled = _prefs!.getBool(_kEnabledKey) ?? true;
    await _loadAllData();
    _applyDecay();
    notifyListeners();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Settings
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await _prefs?.setBool(_kEnabledKey, value);
    notifyListeners();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Tracking
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> trackSongPlay(
    Song song, {
    int durationPlayed = 0,
    bool completed = false,
  }) async {
    final id = song.id;
    final hour = DateTime.now().hour;

    _profiles
        .putIfAbsent(
          id,
          () => SongProfile(
            songId: id,
            title: song.title,
            artist: song.artist,
            artistId: song.artistId,
            albumId: song.albumId,
            genre: song.genre,
            duration: song.duration,
          ),
        )
        .addPlay(
            durationPlayed: durationPlayed, completed: completed, hour: hour);

    _recentlyPlayed.remove(id);
    _recentlyPlayed.insert(0, id);
    if (_recentlyPlayed.length > 500) {
      _recentlyPlayed = _recentlyPlayed.sublist(0, 500);
    }
    _rebuildRecentIndex();

    if (_enabled) {
      final lw = _listenWeight(song, durationPlayed, completed: completed);

      if (song.artist != null) {
        _artistAffinity[song.artist!] =
            (_artistAffinity[song.artist!] ?? 0) + lw;
        _maxArtistAffinity = null;
      }
      if (song.genre != null) {
        _genreAffinity[song.genre!] =
            (_genreAffinity[song.genre!] ?? 0) + lw * 0.75;
        _maxGenreAffinity = null;
      }
      if (song.albumId != null) {
        _albumAffinity[song.albumId!] =
            (_albumAffinity[song.albumId!] ?? 0) + lw * 0.6;
        _maxAlbumAffinity = null;
      }

      _timePatterns.putIfAbsent(hour, () => {});
      if (song.genre != null) {
        _timePatterns[hour]![song.genre!] =
            (_timePatterns[hour]![song.genre!] ?? 0) + 1;
      }
    }

    _scheduleSave();
    notifyListeners();
    // Hybrid DB sync — keep coarse filter columns up to date
    final p = _profiles[id];
    _db.updateSongPlayStatus(id,
        playCount: p?.playCount, lastPlayed: DateTime.now().millisecondsSinceEpoch).catchError((_) {});
  }

  Future<void> trackSkip(Song song, {int secondsPlayed = 0}) async {
    final id = song.id;
    _skipCounts[id] = (_skipCounts[id] ?? 0) + 1;
    _profiles[id]?.skipCount++;

    if (_enabled) {
      final earlyFactor = song.duration != null && song.duration! > 0
          ? 1.0 - (secondsPlayed / song.duration!).clamp(0.0, 1.0)
          : 1.0;
      final penalty = 0.3 * earlyFactor;

      if (song.artist != null) {
        _artistAffinity[song.artist!] =
            (_artistAffinity[song.artist!] ?? 0) - penalty;
        _maxArtistAffinity = null;
      }
      if (song.genre != null) {
        _genreAffinity[song.genre!] =
            (_genreAffinity[song.genre!] ?? 0) - penalty * 0.5;
        _maxGenreAffinity = null;
      }
    }

    _scheduleSave();
    notifyListeners();
    _db.updateSongPlayStatus(id, skipCount: _skipCounts[id], disliked: (_skipCounts[id] ?? 0) >= 3).catchError((_) {});
  }

  Future<void> trackSongRating(Song song, int rating) async {
    if (rating < 1 || rating > 5) return;

    (_profiles[song.id] ??
            (_profiles[song.id] = SongProfile(
              songId: song.id,
              title: song.title,
              artist: song.artist,
              artistId: song.artistId,
              albumId: song.albumId,
              genre: song.genre,
              duration: song.duration,
            )))
        .userRating = rating;

    if (_enabled) {
      final signedWeight = (rating - 3) / 2.0;

      if (song.artist != null) {
        _artistRatingAffinity[song.artist!] =
            (_artistRatingAffinity[song.artist!] ?? 0) + signedWeight * 2.5;
        _maxArtistRating = null;
      }
      if (song.genre != null) {
        _genreRatingAffinity[song.genre!] =
            (_genreRatingAffinity[song.genre!] ?? 0) + signedWeight * 1.8;
        _maxGenreRating = null;
      }
    }

    _scheduleSave();
    notifyListeners();
  }

  Future<void> trackDislike(Song song) async {
    _profiles
        .putIfAbsent(
          song.id,
          () => SongProfile(
            songId: song.id,
            title: song.title,
            artist: song.artist,
            artistId: song.artistId,
            albumId: song.albumId,
            genre: song.genre,
            duration: song.duration,
          ),
        )
        .dislikeCount++;

    if (_enabled) {
      if (song.artist != null) {
        _artistAffinity[song.artist!] =
            (_artistAffinity[song.artist!] ?? 0) - 0.8;
        _maxArtistAffinity = null;
      }
      if (song.genre != null) {
        _genreAffinity[song.genre!] =
            (_genreAffinity[song.genre!] ?? 0) - 0.4;
        _maxGenreAffinity = null;
      }
    }

    _scheduleSave();
    notifyListeners();
    _db.updateSongPlayStatus(song.id, disliked: true).catchError((_) {});
  }

  Future<void> trackStarred(Song song, bool starred) async {
    if (starred) {
      _starredSongs.add(song.id);
    } else {
      _starredSongs.remove(song.id);
    }

    if (_enabled) {
      final delta = starred ? 1.0 : -0.5;
      if (song.artist != null) {
        _artistAffinity[song.artist!] =
            (_artistAffinity[song.artist!] ?? 0) + delta * 2.0;
        _maxArtistAffinity = null;
      }
      if (song.genre != null) {
        _genreAffinity[song.genre!] =
            (_genreAffinity[song.genre!] ?? 0) + delta * 1.5;
        _maxGenreAffinity = null;
      }
    }

    _scheduleSave();
    notifyListeners();
  }

  /// Server import helpers — idempotent, no extra save storm
  void importStarredBulk(List<Song> songs) {
    var changed = false;
    for (final s in songs) {
      if (_starredSongs.add(s.id)) changed = true;
      if (_enabled) {
        if (s.artist != null) {
          _artistAffinity[s.artist!] = (_artistAffinity[s.artist!] ?? 0) + 0.6;
          _maxArtistAffinity = null;
          changed = true;
        }
        if (s.genre != null) {
          _genreAffinity[s.genre!] = (_genreAffinity[s.genre!] ?? 0) + 0.4;
          _maxGenreAffinity = null;
          changed = true;
        }
      }
      // keep profile playCount in sync for hybrid DB scoring
      _profiles.putIfAbsent(s.id, () => SongProfile(songId: s.id, title: s.title, artist: s.artist, artistId: s.artistId, albumId: s.albumId, genre: s.genre, duration: s.duration));
    }
    if (changed) { _scheduleSave(); notifyListeners(); }
  }

  void importPlayCountBulk(Map<String,int> playCounts) {
    var changed=false;
    for (final e in playCounts.entries) {
      final p = _profiles.putIfAbsent(e.key, () => SongProfile(songId: e.key, title: e.key, artist: null, artistId: null, albumId: null, genre: null, duration: null));
      if (e.value > p.playCount) { p.playCount = e.value; changed=true; }
    }
    if (changed) { _scheduleSave(); notifyListeners(); }
  }

  // Yandex enrichment fallback for missing genre
  String? _effectiveGenreForRec(Song s) {
    if (s.genre != null && s.genre!.isNotEmpty) return s.genre;
    final ov = _enrichGenreOverride?[s.id];
    if (ov != null) return ov;
    // В изоляте синглтона enrich нет — только снапшот.
    if (_inIsolate) return null;
    return YandexEnrichmentService().effectiveGenre(s);
  }

  /// Есть ли enrich-жанр для трека (снапшот в изоляте / синглтон на main).
  bool _hasEnrichSongCache(Song s) {
    if (_inIsolate) return _enrichGenreOverride?.containsKey(s.id) ?? false;
    return YandexEnrichmentService().getCachedForSong(s) != null;
  }

  /// Похожие артисты из enrich-кэша (снапшот в изоляте / синглтон на main).
  List<String> _enrichSimilarArtists(String artist) {
    if (_inIsolate) return _enrichSimilarOverride?[artist] ?? const [];
    return YandexEnrichmentService().getCachedForArtist(artist)?.similarArtists ??
        const [];
  }

  double calculateSongScore(Song song, {int? currentHour}) {
    if (!_enabled) return 0.0;

    double score = 0.0;
    final profile = _profiles[song.id];
    final hour = currentHour ?? DateTime.now().hour;
    final effGenre = _effectiveGenreForRec(song);

    if (song.artist != null) {
      final maxA = _cachedMax(_artistAffinity, () => _maxArtistAffinity,
          (v) => _maxArtistAffinity = v);
      if (maxA > 0) {
        score += ((_artistAffinity[song.artist] ?? 0).clamp(0, maxA) / maxA) *
            _W.artistAffinity;
      }
    }

    if (effGenre != null) {
      final maxG = _cachedMax(_genreAffinity, () => _maxGenreAffinity,
          (v) => _maxGenreAffinity = v);
      if (maxG > 0) {
        score += ((_genreAffinity[effGenre] ?? 0).clamp(0, maxG) / maxG) *
            _W.genreAffinity;
      }
      // Небольшой бонус если жанр получен из ЯМ (заполняет пробелы у локальных файлов)
      if (song.genre == null && _hasEnrichSongCache(song)) {
        score += 0.02;
      }
    }

    if (song.albumId != null) {
      final maxAl = _cachedMax(_albumAffinity, () => _maxAlbumAffinity,
          (v) => _maxAlbumAffinity = v);
      if (maxAl > 0) {
        score += ((_albumAffinity[song.albumId] ?? 0).clamp(0, maxAl) / maxAl) *
            _W.albumAffinity;
      }
    }

    if (song.artist != null) {
      final maxAr = _cachedMax(_artistRatingAffinity, () => _maxArtistRating,
          (v) => _maxArtistRating = v);
      if (maxAr > 0) {
        score += ((_artistRatingAffinity[song.artist] ?? 0).clamp(0, maxAr) /
                maxAr) *
            _W.artistRating;
      }
    }

    if (song.genre != null) {
      final maxGr = _cachedMax(_genreRatingAffinity, () => _maxGenreRating,
          (v) => _maxGenreRating = v);
      if (maxGr > 0) {
        score +=
            ((_genreRatingAffinity[song.genre] ?? 0).clamp(0, maxGr) / maxGr) *
                _W.genreRating;
      }
    }

    if (profile != null) {
      score += profile.completionRate * _W.completionRate;
      score += profile.getHourPreference(hour) * _W.hourPreference;
      score += min(profile.playCount / 10.0, 1.0) * _W.playCountSignal;
      if (profile.userRating != null) {
        score += (profile.userRating! / 5.0) * _W.userRating;
      }
    } else {
      score += _W.noveltyBonus;
    }

    if (song.userRating != null) {
      score += (song.userRating! / 5.0) * _W.songLevelRating;
    }

    // Server community rating (Navidrome averageRating 1–5): tracks the
    // crowd loves get a small boost even without personal history.
    if (song.averageRating != null && song.averageRating! > 0) {
      score += (song.averageRating!.clamp(0.0, 5.0) / 5.0) * _W.averageRating;
    }

    if (_starredSongs.contains(song.id) || song.starred == true) {
      score += _W.starBonus;
    }

    final skips = _skipCounts[song.id] ?? 0;
    if (skips > 0) {
      score -= min(skips * _W.skipPenaltyPerSkip, _W.maxSkipPenalty);
    }

    final recentIdx = _recentIndex[song.id];
    if (recentIdx != null && recentIdx < 20) {
      score -= (20 - recentIdx) * _W.recencyPenaltyStep;
    }

    final genreForTime = effGenre;
    if (genreForTime != null) {
      final hourMap = _timePatterns[hour];
      if (hourMap != null && hourMap.isNotEmpty) {
        final maxHg = hourMap.values.reduce(max);
        if (maxHg > 0) {
          score += ((hourMap[genreForTime] ?? 0) / maxHg) * _W.timePatternsBonus;
        }
      }
    }

    // Yandex similar-artist bonus: if song's artist similar to top liked artist
    if (song.artist != null) {
      final similar = _enrichSimilarArtists(song.artist!);
      if (similar.isNotEmpty) {
        final topArtists = _getTopArtists(5).map((e) => e.toLowerCase()).toSet();
        for (final sim in similar.take(3)) {
          if (topArtists.contains(sim.toLowerCase())) {
            score += 0.03;
            break;
          }
        }
      }
    }

    return score.clamp(0.0, 1.0);
  }

  List<Song> getPersonalizedFeed(
    List<Song> allSongs, {
    int limit = 50,
    String? seedArtist,
    String? seedArtistId,
    String? seedGenre,
  }) {
    if (!_enabled || allSongs.isEmpty) return allSongs.take(limit).toList();
    // ── Seeded wave: My Wave по артисту/жанру ──
    if (seedArtist != null || seedArtistId != null || seedGenre != null) {
      return _getSeededFeed(
        allSongs,
        limit: limit,
        seedArtist: seedArtist,
        seedArtistId: seedArtistId,
        seedGenre: seedGenre,
      );
    }
    // Тихое подмешивание Yandex: до 2 треков похожих артистов в персоналку (Плейлист дня)
    var feedPool = allSongs;
    try {
      final topArtists = _getTopArtists(3);
      final yandexSimilarNames = <String>{};
      for (final a in topArtists) {
        yandexSimilarNames.addAll(_enrichSimilarArtists(a).map((e) => e.toLowerCase()));
      }
      if (yandexSimilarNames.isNotEmpty) {
        final yandexCandidates = allSongs.where((s) {
          if (s.artist == null) return false;
          if (_recentlyPlayed.contains(s.id)) return false;
          if (s.artistId != null && _bannedArtists.contains(s.artistId)) return false;
          if (_bannedArtistsNames.map((n) => n.toLowerCase()).contains(s.artist!.toLowerCase())) return false;
          return yandexSimilarNames.contains(s.artist!.toLowerCase());
        }).toList();
        if (yandexCandidates.isNotEmpty) {
          // Берём 2 самых скорых по base score
          final scored = yandexCandidates.map((s) => MapEntry(s, calculateSongScore(s))).toList()
            ..sort((a, b) => b.value.compareTo(a.value));
          final inject = scored.take(2).map((e) => e.key).where((s) => !feedPool.any((p) => p.id == s.id)).toList();
          if (inject.isNotEmpty) {
            debugPrint('[Rec] PersonalizedFeed Yandex inject: +${inject.length}');
            // Подмешиваем в пул — _sortByScore потом перемешает, но они имеют шанс попасть в топ
            feedPool = [...inject, ...feedPool];
          }
        }
      }
    } catch (e) {
      debugPrint('[Rec] Yandex inject Personalized error: $e');
    }
    final vibe = _buildVibeProfile(feedPool);
    return _sortByScore(
      feedPool,
      jitter: _W.randomJitter,
      limit: limit,
      vibeProfile: vibe,
    );
  }

  /// Удобные врапперы для UI: My Wave по артисту / жанру
  List<Song> getWaveByArtist(List<Song> allSongs, String artist, {String? artistId, int limit = 50}) =>
      getPersonalizedFeed(allSongs, limit: limit, seedArtist: artist, seedArtistId: artistId);

  List<Song> getWaveByGenre(List<Song> allSongs, String genre, {int limit = 50}) =>
      getPersonalizedFeed(allSongs, limit: limit, seedGenre: genre);

  /// ── Radio → Recommendation bridge ──
  /// Скoring радиостанций по твоим жанровым аффинити: имя станции содержит топ-жанр → выше.
  /// Не сеть, мгновенно, кэшируется через `rankRadioStations`.
  List<RadioStation> rankRadioStations(List<RadioStation> stations, {int limit = 50}) {
    if (stations.isEmpty) return [];
    if (!_enabled || _genreAffinity.isEmpty) {
      final shuffled = List<RadioStation>.from(stations)..shuffle();
      return shuffled.take(limit).toList();
    }
    final maxG = _genreAffinity.values.reduce(max);
    if (maxG <= 0) return stations.take(limit).toList();
    final scored = stations.map((st) {
      final nameLow = st.name.toLowerCase();
      double score = 0;
      // Совпадение по жанру в названии
      for (final entry in _genreAffinity.entries) {
        final genreLow = entry.key.toLowerCase();
        if (nameLow.contains(genreLow)) {
          score += (entry.value / maxG) * _W.genreAffinity;
        }
      }
      // Небольшой бонус за станции, которые уже слушал (если в recentlyPlayed есть треки с похожим жанром)
      // Для детерминизма добавляем крошечный jitter по id
      final jitter = (st.id.hashCode % 100) / 1000.0;
      return MapEntry(st, score + jitter);
    }).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return scored.take(limit).map((e) => e.key).toList();
  }

  /// Генерация очереди после радио: берёт seed-жанр из названия станции и строит волну
  List<Song> getRadioBridgeQueue(
    List<Song> pool,
    RadioStation station, {
    int limit = 10,
  }) {
    if (pool.isEmpty) return [];
    final nameLow = station.name.toLowerCase();
    // Пытаемся угадать жанр из названия станции
    String? seedGenre;
    double best = 0;
    for (final genre in _getTopGenres(10)) {
      if (nameLow.contains(genre.toLowerCase())) {
        final aff = _genreAffinity[genre] ?? 0;
        if (aff > best) {
          best = aff;
          seedGenre = genre;
        }
      }
    }
    if (seedGenre != null) {
      return getWaveByGenre(pool, seedGenre, limit: limit);
    }
    // Fallback: персоналка без seed
    return getPersonalizedFeed(pool, limit: limit);
  }

  /// Внутренняя seeded-генерация: фильтр по seed + vibe-расширение + скоринг
  List<Song> _getSeededFeed(
    List<Song> allSongs, {
    required int limit,
    String? seedArtist,
    String? seedArtistId,
    String? seedGenre,
  }) {
    final seedLower = seedArtist?.toLowerCase();
    final genreLower = seedGenre?.toLowerCase();

    // Собрать seed-треки (точный матч)
    final seedSongs = allSongs.where((s) {
      if (seedArtistId != null && s.artistId != null && s.artistId == seedArtistId) return true;
      if (seedLower != null && s.artist != null && s.artist!.toLowerCase() == seedLower) return true;
      if (genreLower != null && s.genre != null && s.genre!.toLowerCase() == genreLower) return true;
      return false;
    }).toList();

    // Если артист-запрос, расширяем пул через Yandex similar (если есть кэш)
    Set<String> expandedArtists = {};
    if (seedLower != null) {
      try {
        final similar = _enrichSimilarArtists(seedArtist!);
        if (similar.isNotEmpty) {
          expandedArtists = similar.map((e) => e.toLowerCase()).toSet();
        }
      } catch (_) {}
    }

    // Фильтр пула: точный seed + опционально похожие артисты (до 30% пула)
    var pool = allSongs.where((s) {
      if (seedArtistId != null && s.artistId == seedArtistId) return true;
      if (seedLower != null && s.artist != null && s.artist!.toLowerCase() == seedLower) return true;
      if (genreLower != null && s.genre != null && s.genre!.toLowerCase() == genreLower) return true;
      return false;
    }).toList();

    // Если пул маленький (< limit), добираем похожие по вайбу + Yandex similar
    if (pool.length < limit) {
      final poolIds = pool.map((e) => e.id).toSet();
      final yandexExtra = <Song>[];
      if (expandedArtists.isNotEmpty) {
        for (final s in allSongs) {
          if (poolIds.contains(s.id)) continue;
          if (s.artist != null && expandedArtists.contains(s.artist!.toLowerCase())) {
            yandexExtra.add(s);
          }
        }
        // Берём топ по base score, чтобы не размывать волну
        if (yandexExtra.isNotEmpty) {
          yandexExtra.sort((a, b) => calculateSongScore(b).compareTo(calculateSongScore(a)));
          pool.addAll(yandexExtra.take((limit - pool.length).clamp(0, limit ~/ 2)));
        }
      }
      // Если всё ещё мало — добираем вайб-близкие к seed
      if (pool.length < limit && seedSongs.isNotEmpty) {
        final vibe = VibeSimilarity();
        // Средний профиль seed
        double e = 0, va = 0, d = 0, b = 0, ac = 0, inst = 0;
        for (final s in seedSongs.take(10)) {
          final f = vibe.analyzeTrack(s);
          e += f.energy; va += f.valence; d += f.danceability; b += f.bpm; ac += f.acousticness; inst += f.instrumentalness;
        }
        final n = min(seedSongs.length, 10);
        final seedProfile = VibeFeatures(energy: e / n, valence: va / n, danceability: d / n, bpm: b / n, acousticness: ac / n, instrumentalness: inst / n);
        final remaining = allSongs.where((s) => !poolIds.contains(s.id) && !pool.any((p) => p.id == s.id)).toList();
        final scored = remaining.map((s) {
          final sim = vibe.vibeSimilarity(seedProfile, vibe.analyzeTrack(s));
          return MapEntry(s, sim);
        }).toList()..sort((a, b) => b.value.compareTo(a.value));
        const threshold = 0.62; // как в desktop findSimilarTracks
        final vibeClose = scored.where((e) => e.value >= threshold).map((e) => e.key).toList();
        if (vibeClose.isNotEmpty) {
          final need = limit - pool.length;
          // Ограничиваем вайб-добавку 40% от лимита, чтобы волна оставалась seed-центричной
          pool.addAll(vibeClose.take(min(need, (limit * 0.4).round())));
        }
      }
    }

    if (pool.isEmpty) return [];

    // Vibe-профиль для _sortByScore — строим из seedSongs, а не из всего пула
    final vibeProfile = _buildVibeProfile(seedSongs.isNotEmpty ? seedSongs : pool, take: 10);
    // Seed-бонус: точные матчи получают небольшой boost внутри _sortByScore через base score,
    // но здесь добавляем jitter поменьше для более детерминированной волны
    return _sortByScore(
      pool,
      jitter: 0.08,
      limit: limit,
      vibeProfile: vibeProfile,
      vibeWeight: 0.14,
      fingerprintWeight: 0.10,
    );
  }

  List<Song> getQuickPicks(List<Song> allSongs, {int limit = 20, Set<String>? excludeIds}) {
    if (!_enabled || allSongs.isEmpty) return [];

    final topArtists = _getTopArtists(5).toSet();
    final topGenres = _getTopGenres(4).toSet();
    final recentSet = _recentlyPlayed.take(10).toSet();
    final excludeSet = excludeIds ?? {};

    // TopGenres is built from `_genreAffinity` (genre-name based), so the
    // quick-pick pool is keyed on artist NAMES and genre NAMES too — filter
    // any banned artist (by ID OR by name) so a disliked artist doesn't sneak
    // into "Quick Picks" because it has high `_artistAffinity` from old plays.
    final bannedNames = _bannedArtistsNames.map((n) => n.toLowerCase()).toSet();

    var candidates = allSongs.where((s) {
      if (recentSet.contains(s.id)) return false;
      if (excludeSet.contains(s.id)) return false;
      if (s.artistId != null && _bannedArtists.contains(s.artistId)) return false;
      if (s.artist != null && bannedNames.contains(s.artist!.toLowerCase())) return false;
      return topArtists.contains(s.artist) || topGenres.contains(s.genre);
    }).toList();

    if (candidates.length < limit) {
      final extra = allSongs
          .where((s) {
            if (recentSet.contains(s.id)) return false;
            if (excludeSet.contains(s.id)) return false;
            if (s.artistId != null && _bannedArtists.contains(s.artistId)) {
              return false;
            }
            if (s.artist != null && bannedNames.contains(s.artist!.toLowerCase())) {
              return false;
            }
            return !candidates.contains(s);
          })
          .take(limit - candidates.length);
      candidates = [...candidates, ...extra];
    }

    final vibe = _buildVibeProfile(allSongs);
    return _sortByScore(
      candidates,
      jitter: 0.30,
      limit: limit,
      vibeProfile: vibe,
    );
  }

  List<Song> getDiscoverMix(List<Song> allSongs, {int limit = 25, Set<String>? excludeIds}) {
    if (!_enabled || allSongs.isEmpty) return [];

    final knownIds = _profiles.keys.toSet();
    final topGenres = _getTopGenres(5).toSet();
    final topArtists = _getTopArtists(10).toSet();
    final recentSet = _recentlyPlayed.take(20).toSet();
    final excludeSet = excludeIds ?? {};

    final bannedNamesLower = _bannedArtistsNames.map((n) => n.toLowerCase()).toSet();
    bool isBanned(Song s) =>
        (s.artistId != null && _bannedArtists.contains(s.artistId)) ||
        (s.artist != null && bannedNamesLower.contains(s.artist!.toLowerCase()));
    bool isUnheard(Song s) =>
        !knownIds.contains(s.id) &&
        !recentSet.contains(s.id) &&
        !excludeSet.contains(s.id) &&
        !isBanned(s);

    final tier1 = allSongs
        .where((s) =>
            isUnheard(s) &&
            topGenres.contains(s.genre) &&
            !topArtists.contains(s.artist))
        .toList();

    final tier2 = allSongs
        .where((s) => isUnheard(s) && topGenres.contains(s.genre))
        .toList();

    final tier3 = allSongs.where(isUnheard).toList();

    var pool = tier1.isNotEmpty
        ? tier1
        : tier2.isNotEmpty
            ? tier2
            : tier3.isNotEmpty
                ? tier3
                : allSongs.where((s) => !recentSet.contains(s.id) && !excludeSet.contains(s.id) && !isBanned(s)).toList();

    // Тихое подмешивание Yandex-похожих: берём similar из кэша ЯМ для топ-артистов и ищем их треки на сервере
    try {
      final topPlayedArtists = _getTopArtists(3);
      final yandexSimilarNames = <String>{};
      for (final a in topPlayedArtists) {
        yandexSimilarNames.addAll(_enrichSimilarArtists(a).map((e) => e.toLowerCase()));
      }
      if (yandexSimilarNames.isNotEmpty) {
        final yandexPool = allSongs.where((s) {
          if (!isUnheard(s)) return false;
          if (s.artist == null) return false;
          return yandexSimilarNames.contains(s.artist!.toLowerCase());
        }).toList();
        if (yandexPool.isNotEmpty) {
          // Тихо: подмешиваем до 3-4 треков в начало пула, остальное через _sortByScore перемешается
          final injectCount = yandexPool.length >= 3 ? 3 : yandexPool.length;
          final injected = (yandexPool..shuffle()).take(injectCount).toList();
          // Убираем дубли если уже в пуле
          final poolIds = pool.map((e) => e.id).toSet();
          final toAdd = injected.where((s) => !poolIds.contains(s.id)).toList();
          if (toAdd.isNotEmpty) {
            pool = [...toAdd, ...pool];
            debugPrint('[Rec] Discover Yandex inject: +${toAdd.length} (similar to ${topPlayedArtists.join(',')})');
          }
        }
      }
    } catch (e) {
      debugPrint('[Rec] Yandex inject Discover error: $e');
    }

    final vibe = _buildVibeProfile(allSongs);
    return _sortByScore(
      pool,
      jitter: 0.50,
      limit: limit,
      vibeProfile: vibe,
    );
  }

  List<Song> getArtistMix(
    List<Song> allSongs,
    String artist, {
    int limit = 25,
    Set<String>? excludeIds,
  }) {
    if (!_enabled) return [];
    final excludeSet = excludeIds ?? {};
    final artistSongs = allSongs.where((s) => s.artist == artist && !excludeSet.contains(s.id)).toList();
    return _sortByScore(artistSongs, jitter: 0.40, limit: limit);
  }

  List<Song> getGenreMix(
    List<Song> allSongs,
    String genre, {
    int limit = 25,
    Set<String>? excludeIds,
  }) {
    if (!_enabled) return [];
    final excludeSet = excludeIds ?? {};
    final genreSongs = allSongs.where((s) => s.genre == genre && !excludeSet.contains(s.id)).toList();
    return _sortByScore(genreSongs, jitter: 0.40, limit: limit);
  }

  // ── П4: было 2-5k → OOM/ANR на 80к. Стало 700: разнообразие дает
  // RANDOM-сэмпл + стратификация, а не размер пула. Кэш ML в БД (song_profiles/audio_features).
  Future<List<Song>> getNotPlayedPool({int limit = 700, int offset = 0}) async {
    try {
      final dbSongs = await _db.getNotPlayedSongs(limit: limit, offset: offset);
      if (dbSongs.isNotEmpty) return dbSongs;
    } catch (_) {}
    return [];
  }

  Future<List<Song>> getPlayedPool({int limit = 700, int offset = 0}) async {
    try {
      final dbSongs = await _db.getPlayedSongs(limit: limit, offset: offset);
      if (dbSongs.isNotEmpty) return dbSongs;
    } catch (_) {}
    return [];
  }

  Future<List<Song>> getDislikedPool({int limit = 700, int offset = 0}) async {
    try {
      final dbSongs = await _db.getDislikedSongs(limit: limit, offset: offset);
      if (dbSongs.isNotEmpty) return dbSongs;
    } catch (_) {}
    return [];
  }

  Future<List<Song>> getSongsForMixHybrid({String? genre, String? mood, String? excludeArtistId, int limit = 600, List<String> excludeIds = const []}) async {
    try {
      // П4: стратифицированный RANDOM-пул вместо одного LIMIT 2000.
      final dbSongs = await _db.getSongsForMixStratified(
        genre: genre, mood: mood, excludeArtistId: excludeArtistId, limit: limit, excludeIds: excludeIds,
      );
      if (dbSongs.isNotEmpty) return dbSongs;
      final fallback = await _db.getSongsForMix(genre: genre, mood: mood, excludeArtistId: excludeArtistId, limit: limit);
      if (fallback.isNotEmpty) return fallback;
    } catch (_) {}
    return [];
  }

  Future<List<Song>> getMoodPool(String mood, {int limit = 700, int offset = 0}) async {
    try {
      final dbSongs = await _db.getSongsByMoodHybrid(mood, limit: limit, offset: offset);
      if (dbSongs.isNotEmpty) return dbSongs;
    } catch (_) {}
    return [];
  }

  // Mood-aware mix: DB mood WHERE → 700 pool → ML scoring (vibe/time/bandit)
  Future<Map<String, List<Song>>> generateMoodMixesHybrid(String mood, {int perMixLimit = 15}) async {
    final pool = await getMoodPool(mood, limit: 700);
    final effectivePool = pool.isNotEmpty ? pool : await getNotPlayedPool(limit: 700);
    if (effectivePool.isEmpty) return {};
    final filtered = effectivePool.where((s) => s.mood == mood || s.genre == mood || s.mood == null).toList();
    final usePool = filtered.isNotEmpty ? filtered : effectivePool;
    return generateMixes(usePool);
  }

  // --- KumaFlow: комбинированная mood-оценка лирика + аудио ---
  /// Возвращает `MoodDetection` с фьюжном `lyrics (0.4) + audio (0.6)` через `LyricsMoodService`.
  /// Используется UI для бейджей/миксов "по настроению" и для усиления `_sortByScore`.
  Future<MoodDetection> getCombinedMood(Song song, {SyncedLyrics? lyrics}) async {
    try {
      return await LyricsMoodService().detectMood(song, lyrics: lyrics, allowAiFallback: true);
    } catch (_) {
      // Fallback чисто аудио (VibeSimilarity)
      return VibeSimilarity().detectMood(VibeSimilarity().analyzeTrack(song));
    }
  }

  /// Снапшот состояния для фонового изолята: песни + профили + affinity +
  /// enrich-жанры/похожие (sync-чтение кэша) + BPM одним батчем из БД.
  /// Вызывать на main до compute().
  Future<Map<String, dynamic>> buildMixIsolatePayload(List<Song> songs) async {
    final enrich = YandexEnrichmentService();
    final enrichGenres = <String, String>{};
    final enrichSimilar = <String, List<String>>{};
    for (final s in songs) {
      if (s.genre == null || s.genre!.isEmpty) {
        final g = enrich.effectiveGenre(s);
        if (g != null && g.isNotEmpty) enrichGenres[s.id] = g;
      }
      final artist = s.artist;
      if (artist != null && !enrichSimilar.containsKey(artist)) {
        final meta = enrich.getCachedForArtist(artist);
        if (meta != null && meta.similarArtists.isNotEmpty) {
          enrichSimilar[artist] = meta.similarArtists.take(5).toList();
        }
      }
    }
    final bpm = await _bpmForPool(songs);
    return {
      'songs': songs.map((s) => s.toJson()).toList(),
      'enabled': _enabled,
      'profiles': _profiles.map((k, v) => MapEntry(k, v.toJson())),
      'artistAffinity': _artistAffinity,
      'genreAffinity': _genreAffinity,
      'albumAffinity': _albumAffinity,
      'artistRatingAffinity': _artistRatingAffinity,
      'genreRatingAffinity': _genreRatingAffinity,
      'skipCounts': _skipCounts,
      'timePatterns':
          _timePatterns.map((k, v) => MapEntry(k.toString(), v)),
      'bannedIds': _bannedArtists.toList(),
      'bannedNames': _bannedArtistsNames.toList(),
      'recentlyPlayed': _recentlyPlayed,
      'starred': _starredSongs.toList(),
      'enrichGenres': enrichGenres,
      'enrichSimilar': enrichSimilar,
      'bpm': bpm,
    };
  }

  /// Генерация миксов в отдельном изоляте (не вешает UI на 2000+ треках).
  /// Маленькие пулы считает на месте — дешевле, чем сериализация.
  /// При любой ошибке — тихий фолбэк на main-поток.
  Future<Map<String, List<Song>>> generateMixesIsolated(
      List<Song> songs) async {
    if (!_enabled || songs.isEmpty) return {};
    if (songs.length < 400) return generateMixes(songs);
    try {
      final payload = await buildMixIsolatePayload(songs);
      final raw = await compute(generateMixesIsolateEntry, payload);
      final byId = {for (final s in songs) s.id: s};
      final out = <String, List<Song>>{};
      raw.forEach((name, list) {
        out[name] = [
          for (final m in list)
            byId[m['id'] as String] ??
                Song.fromJson(Map<String, dynamic>.from(m)),
        ];
      });
      return out;
    } catch (e) {
      debugPrint('[Rec] isolate failed, fallback to main: $e');
      return generateMixes(songs);
    }
  }

  Future<Map<String, List<Song>>> generateMixesHybrid({int perMixLimit = 15}) async {
    // Hybrid: DB prefilter (not-played preferred) → 700 pool → in-memory ML scoring (vibe/time/mood)
    final pool = await getNotPlayedPool(limit: 700);
    final effectivePool = pool.isNotEmpty ? pool : await getPlayedPool(limit: 700);
    if (effectivePool.isEmpty) return {};
    // Use existing generateMixes on the smaller, DB-filtered pool (much faster than 80k)
    return generateMixes(effectivePool);
  }

  Future<Map<String, List<Song>>> generateMixes(List<Song> allSongs) async {
    if (!_enabled || allSongs.isEmpty) return {};

    final mixes = <String, List<Song>>{};
    final usedSongIds = <String>{}; // Track used songs across all mixes

    // Yield to event loop every chunk to avoid ANR (5с блок = "подождать/закрыть") — 16мс = 1 кадр 60fps
    Future<void> yieldFrame() => Future.delayed(const Duration(milliseconds: 16));

    final quick = getQuickPicks(allSongs, limit: 20);
    if (quick.isNotEmpty) {
      mixes['Quick Picks'] = quick;
      usedSongIds.addAll(quick.map((s) => s.id));
    }

    final discover = getDiscoverMix(allSongs, limit: 20, excludeIds: usedSongIds);
    if (discover.isNotEmpty) {
      mixes['Discover Mix'] = discover;
      usedSongIds.addAll(discover.map((s) => s.id));
    }

    for (final artist in _getTopArtists(3)) {
      // _getTopArtists already filters banned names, so this only loops
      // over non-banned artists — but a defensive check here keeps the
      // contract clear if `_getTopArtists` ever changes its filter rules.
      if (_bannedArtistsNames.map((n) => n.toLowerCase()).contains(artist.toLowerCase())) continue;
      final mix = getArtistMix(allSongs, artist, limit: 15, excludeIds: usedSongIds);
      if (mix.length >= 5) {
        mixes['$artist Mix'] = mix;
        usedSongIds.addAll(mix.map((s) => s.id));
      }
    }

    for (final genre in _getTopGenres(2)) {
      final mix = getGenreMix(allSongs, genre, limit: 15, excludeIds: usedSongIds);
      if (mix.length >= 5) {
        mixes['$genre Mix'] = mix;
        usedSongIds.addAll(mix.map((s) => s.id));
      }
    }

    await yieldFrame();

    final hour = DateTime.now().hour;
    final hourMap = _timePatterns[hour];
    if (hourMap != null && hourMap.isNotEmpty) {
      final topG =
          hourMap.entries.reduce((a, b) => a.value > b.value ? a : b).key;
      final timeSongs = _sortByScore(
        allSongs.where((s) => s.genre == topG && !usedSongIds.contains(s.id)).toList(),
        jitter: 0.30,
        limit: 15,
      );
      if (timeSongs.length >= 5) {
        mixes['${_timeLabel(hour)} Vibes'] = timeSongs;
        usedSongIds.addAll(timeSongs.map((s) => s.id));
      }
    }

    await yieldFrame();

    // ── New ML mixes: Mood / Tempo / Era / Deep Cut / Artist Fusion ──

    final mood = await _buildMoodMix(allSongs, usedSongIds);
    if (mood.isNotEmpty) {
      mixes['Mood Mix'] = mood;
      usedSongIds.addAll(mood.map((s) => s.id));
    }

    await yieldFrame();

    final tempo = await _buildTempoMix(allSongs, usedSongIds);
    if (tempo.isNotEmpty) {
      mixes['Tempo Mix'] = tempo;
      usedSongIds.addAll(tempo.map((s) => s.id));
    }

    await yieldFrame();

    final era = _buildEraMix(allSongs, usedSongIds);
    if (era.isNotEmpty) {
      mixes['Era Mix'] = era;
      usedSongIds.addAll(era.map((s) => s.id));
    }

    await yieldFrame();

    final deepCut = _buildDeepCutMix(allSongs, usedSongIds);
    if (deepCut.isNotEmpty) {
      mixes['Deep Cut Mix'] = deepCut;
      usedSongIds.addAll(deepCut.map((s) => s.id));
    }

    await yieldFrame();

    final fusion = _buildArtistFusionMix(allSongs, usedSongIds);
    if (fusion.isNotEmpty) {
      mixes['Artist Fusion'] = fusion;
      usedSongIds.addAll(fusion.map((s) => s.id));
    }

    await yieldFrame();

    final local = _buildLocalMix(allSongs, usedSongIds);
    if (local.isNotEmpty) {
      mixes['Local Mix'] = local;
      usedSongIds.addAll(local.map((s) => s.id));
    }

    await yieldFrame();

    // ── Activity/Mood/TimeOfDay mixes — ОТКЛЮЧЕНЫ для автогенерации чтобы не ANR ──
    // Тяжёлые Activity/Mood (11+6) генерим лениво по требованию, не в основном потоке.
    // Для автогенерации оставляем только лёгкий TimeOfDay.
    final timeOfDay = _buildTimeOfDayMix(allSongs, usedSongIds);
    if (timeOfDay.isNotEmpty) {
      mixes['Time of Day Mix'] = timeOfDay;
      usedSongIds.addAll(timeOfDay.map((s) => s.id));
    }

    await yieldFrame();

    // Activity/Mood — только если библиотека маленькая (<1500) и не в фоне, иначе пропустим (ленивая загрузка)
    if (allSongs.length <= 1500) {
      final activityMixes = _buildActivityMixes(allSongs, usedSongIds, limitActivities: 3);
      for (final e in activityMixes.entries) {
        mixes[e.key] = e.value;
        usedSongIds.addAll(e.value.map((s) => s.id));
        await yieldFrame();
      }

      final moodMixes = _buildMoodMixes(allSongs, usedSongIds, limitMoods: 3);
      for (final e in moodMixes.entries) {
        mixes[e.key] = e.value;
        usedSongIds.addAll(e.value.map((s) => s.id));
        await yieldFrame();
      }
    }

     return mixes;
   }

  double _getTimeOfDayTargetEnergy(int hour) {
    // Порт desktop getTimeOfDayTargetEnergy 0.2-0.7
    if (hour >= 6 && hour < 12) return 0.40; // утро — средне
    if (hour >= 12 && hour < 18) return 0.70; // день — энергично
    if (hour >= 18 && hour < 22) return 0.50; // вечер — умеренно
    if (hour >= 22 || hour < 5) return 0.20; // ночь — спокойно
    return 0.35; // 5-6 раннее утро
  }

  List<Song> _buildTimeOfDayMix(List<Song> allSongs, Set<String> usedIds, {int limit = 15}) {
    final hour = DateTime.now().hour;
    final target = _getTimeOfDayTargetEnergy(hour);
    final pool = allSongs.where((s) => !usedIds.contains(s.id)).toList();
    if (pool.isEmpty) return [];
    final vibe = VibeSimilarity();
    final scored = pool.map((s) {
      final f = vibe.analyzeTrack(s);
      final dist = (f.energy - target).abs();
      final score = calculateSongScore(s) + (1 - dist) * 0.25;
      return MapEntry(s, score);
    }).toList()..sort((a, b) => b.value.compareTo(a.value));
    // Top 40% близких к target + jitter.
    // clamp(min, max) требует min <= max: при маленьком пуле
    // clamp(limit, pool.length) падало с Invalid argument(s): 15.
    final takeCount = (pool.length * 0.4).ceil().clamp(0, pool.length);
    final filtered = scored.take(takeCount).map((e) => e.key).toList();
    return _sortByScore(filtered, jitter: 0.12, limit: limit);
  }

  Map<String, List<Song>> _buildActivityMixes(List<Song> allSongs, Set<String> usedIds, {int limitActivities = 11}) {
    final result = <String, List<Song>>{};
    final vibe = VibeSimilarity();
    // 11 activity из for-you-page.tsx: meditation, deepwork, running, workout, cycling, creativity, cooking, reading, gaming, sleep, acoustic
    final activities = <String, bool Function(VibeFeatures)>{
      'Workout Mix': (f) => f.energy >= 0.7 && f.bpm >= 110,
      'Running Mix': (f) => f.energy >= 0.75 && f.bpm >= 130,
      'Cycling Mix': (f) => f.energy >= 0.6 && f.bpm >= 110 && f.bpm <= 150,
      'Meditation Mix': (f) => f.energy <= 0.3 && f.bpm <= 90,
      'Sleep Mix': (f) => f.energy <= 0.25 && f.bpm <= 80,
      'Focus Mix': (f) => f.energy >= 0.3 && f.energy <= 0.6 && f.bpm >= 80 && f.bpm <= 110,
      'Creativity Mix': (f) => f.energy >= 0.4 && f.energy <= 0.7 && f.valence >= 0.5,
      'Cooking Mix': (f) => f.energy >= 0.5 && f.energy <= 0.8 && f.valence >= 0.6,
      'Reading Mix': (f) => f.energy >= 0.2 && f.energy <= 0.5 && f.acousticness >= 0.5,
      'Gaming Mix': (f) => f.energy >= 0.6 && f.bpm >= 110,
      'Acoustic Mix': (f) => f.acousticness >= 0.6,
    };
    var count = 0;
    for (final entry in activities.entries) {
      if (count >= limitActivities) break;
      count++;
      final filtered = allSongs.where((s) {
        if (usedIds.contains(s.id)) return false;
        final f = vibe.analyzeTrack(s);
        return entry.value(f);
      }).toList();
      if (filtered.length < 5) continue;
      // Сортируем по скор + лёгкий jitter, берём топ 15
      final ranked = _sortByScore(filtered, jitter: 0.15, limit: 15);
      if (ranked.length >= 5) {
        result[entry.key] = ranked;
        // Не добавляем в usedIds здесь — сделает вызывающий, но для разнообразия activity между собой
        // добавляем локально чтобы не дублировать внутри цикла
        usedIds.addAll(ranked.map((s) => s.id));
      }
    }
    return result;
  }

  Map<String, List<Song>> _buildMoodMixes(List<Song> allSongs, Set<String> usedIds, {int limitMoods = 6}) {
    final result = <String, List<Song>>{};
    final vibe = VibeSimilarity();
    // 6 mood из for-you-page: happy, sad, energetic, party, melancholy, aggressive ( + calm уже в Meditation, но добавим)
    final moods = ['happy', 'sad', 'energetic', 'calm', 'melancholic', 'aggressive'].take(limitMoods).toList();
    final moodLabels = {
      'happy': 'Happy Mix',
      'sad': 'Sad Mix',
      'energetic': 'Energetic Mix',
      'calm': 'Calm Mix',
      'melancholic': 'Melancholic Mix',
      'aggressive': 'Aggressive Mix',
    };
    for (final mood in moods) {
      final filtered = allSongs.where((s) {
        if (usedIds.contains(s.id)) return false;
        final f = vibe.analyzeTrack(s);
        final detected = vibe.detectMood(f).mood.name.toLowerCase();
        return detected == mood;
      }).toList();
      // Fallback: если точных совпадений мало (<5), берём близкие по valence/energy
      List<Song> pool = filtered;
      if (pool.length < 5) {
        pool = allSongs.where((s) {
          if (usedIds.contains(s.id) || filtered.any((f) => f.id == s.id)) return false;
          final f = vibe.analyzeTrack(s);
          // Эвристика для недобора
          switch (mood) {
            case 'happy': return f.valence >= 0.6 && f.energy >= 0.5;
            case 'sad': return f.valence <= 0.4 && f.energy <= 0.5;
            case 'energetic': return f.energy >= 0.7;
            case 'calm': return f.energy <= 0.4;
            case 'melancholic': return f.valence <= 0.45 && f.energy <= 0.4;
            case 'aggressive': return f.energy >= 0.8;
            default: return false;
          }
        }).toList();
        pool = [...filtered, ...pool];
      }
      if (pool.length < 5) continue;
      final ranked = _sortByScore(pool, jitter: 0.12, limit: 15);
      if (ranked.length >= 5) {
        result[moodLabels[mood]!] = ranked;
        usedIds.addAll(ranked.map((s) => s.id));
      }
    }
    return result;
  }

  List<Song> _buildLocalMix(List<Song> allSongs, Set<String> usedSongIds, {int limit = 20}) {
    final bannedLower = _bannedArtistsNames.map((n) => n.toLowerCase()).toSet();
    bool isBanned(Song s) =>
        (s.artistId != null && _bannedArtists.contains(s.artistId)) ||
        (s.artist != null && bannedLower.contains(s.artist!.toLowerCase()));
    final pool = allSongs.where((s) => s.isLocal && !usedSongIds.contains(s.id) && !isBanned(s)).toList();
    if (pool.isEmpty) return [];
    // No heavy scoring needed — local files have less metadata, just jitter + recency
    pool.shuffle();
    final deduped = <String>{};
    final result = <Song>[];
    for (final s in pool) {
      if (deduped.add(s.artist ?? s.id)) result.add(s);
      if (result.length >= limit) break;
    }
    if (result.length < limit) {
      for (final s in pool) {
        if (!result.any((r) => r.id == s.id)) {
          result.add(s);
          if (result.length >= limit) break;
        }
      }
    }
    return result;
  }

  /// Mood Mix — split favorite songs into "chill" and "energetic" buckets by
  /// BPM estimate (cached where available), then pick the bucket that best
  /// matches the current hour (night → chill, day → energetic).
  /// Ensures artist diversity for a more varied listening experience.
  Future<List<Song>> _buildMoodMix(List<Song> allSongs, Set<String> usedSongIds,
      {int limit = 20}) async {
    final pool =
        allSongs.where((s) => !usedSongIds.contains(s.id)).toList();
    if (pool.isEmpty) return [];

    final hour = DateTime.now().hour;
    final wantChill = hour < 8 || hour >= 22;
    final bpmCache = await _bpmForPool(pool);

    double bpmOf(Song s) {
      final cached = bpmCache[s.id];
      if (cached != null) return cached;
      final g = (s.genre ?? '').toLowerCase();
      if (g.contains('electronic') || g.contains('edm') || g.contains('house') ||
          g.contains('techno')) return 128;
      if (g.contains('hip hop') || g.contains('rap') || g.contains('trap')) return 85;
      if (g.contains('rock') || g.contains('metal')) return 120;
      if (g.contains('jazz') || g.contains('blues')) return 90;
      if (g.contains('classical') || g.contains('ambient')) return 70;
      if (g.contains('pop')) return 110;
      if (g.contains('ballad') || g.contains('slow')) return 65;
      return 100;
    }

    final scored = pool.map((s) {
      final bpm = bpmOf(s);
      final chillScore = 130 - bpm; // higher BPM → lower chill score
      final energyScore = bpm - 60;
      final base = calculateSongScore(s);
      final score = wantChill ? chillScore * 0.7 + base : energyScore * 0.7 + base;
      return MapEntry(s, score);
    }).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // Deduplicate artists for better diversity
    final seenArtists = <String>{};
    final result = <Song>[];
    for (final entry in scored) {
      if (result.length >= limit) break;
      if (entry.key.artistId != null && seenArtists.contains(entry.key.artistId)) {
        continue;
      }
      if (entry.key.artistId != null) seenArtists.add(entry.key.artistId!);
      result.add(entry.key);
    }
    return result;
  }

  /// Tempo Mix — sorts by BPM into three consecutive buckets (slow/mid/fast)
  /// so the mix gently ramps up and down like a DJ set. Ensures artist diversity.
  Future<List<Song>> _buildTempoMix(List<Song> allSongs, Set<String> usedSongIds,
      {int limit = 25}) async {
    final pool =
        allSongs.where((s) => !usedSongIds.contains(s.id)).toList();
    if (pool.isEmpty) return [];
    final bpmCache = await _bpmForPool(pool);

    double bpmOf(Song s) {
      final cached = bpmCache[s.id];
      if (cached != null) return cached;
      // Fall back to duration heuristic.
      final d = s.duration ?? 0;
      if (d == 0) return 100;
      if (d < 150) return 132;
      if (d > 300) return 82;
      return 105;
    }

    final slow = pool.where((s) => bpmOf(s) < 90).toList()
      ..sort((a, b) => bpmOf(b).compareTo(bpmOf(a)));
    final mid = pool.where((s) => bpmOf(s) >= 90 && bpmOf(s) <= 115).toList()
      ..sort((a, b) => bpmOf(b).compareTo(bpmOf(a)));
    final fast = pool.where((s) => bpmOf(s) > 115).toList()
      ..sort((a, b) => bpmOf(b).compareTo(bpmOf(a)));

    // Deduplicate artists within each bucket for better diversity
    List<Song> dedupByArtist(List<Song> bucket, {int maxPerArtist = 1}) {
      final seen = <String>{};
      return bucket.where((s) {
        if (s.artistId != null && seen.contains(s.artistId)) return false;
        seen.add(s.artistId!);
        return true;
      }).toList();
    }

    final slowD = dedupByArtist(slow);
    final midD = dedupByArtist(mid);
    final fastD = dedupByArtist(fast);

    final result = <Song>[];
    final perBucket = (limit / 3).ceil();
    result.addAll(slowD.take(perBucket));
    result.addAll(midD.take(perBucket));
    result.addAll(fastD.take(perBucket));
    return result.take(limit).toList();
  }

  /// Era Mix — rotates through decade buckets (pre-80s, 80s, 90s, 2000s,
  /// 2010s, 2020s) picking the top-scored song per decade. Ensures artist diversity.
  List<Song> _buildEraMix(List<Song> allSongs, Set<String> usedSongIds,
      {int limit = 20}) {
    final pool =
        allSongs.where((s) => !usedSongIds.contains(s.id)).toList();
    if (pool.isEmpty) return [];

    int? eraOf(Song s) {
      final y = s.year;
      if (y == null || y <= 0) return null;
      if (y < 1980) return 0;
      if (y < 1990) return 1;
      if (y < 2000) return 2;
      if (y < 2010) return 3;
      if (y < 2020) return 4;
      return 5;
    }

    final buckets = List.generate(6, (_) => <Song>[]);
    for (final s in pool) {
      final e = eraOf(s);
      if (e != null) buckets[e].add(s);
    }
    // Sort each bucket by ML score, then round-robin across decades.
    final sorted = buckets
        .map((b) => _sortByScore(b, limit: 1000))
        .toList();

    // Deduplicate artists per decade
    List<Song> dedupByArtist(List<Song> bucket, {int maxPerArtist = 1}) {
      final seen = <String>{};
      return bucket.where((s) {
        if (s.artistId != null && seen.contains(s.artistId)) return false;
        seen.add(s.artistId!);
        return true;
      }).toList();
    }

    final sortedDedup = sorted.map(dedupByArtist).toList();

    final result = <Song>[];
    var i = 0;
    while (result.length < limit) {
      var added = false;
      for (final bucket in sortedDedup) {
        if (i < bucket.length) {
          result.add(bucket[i]);
          added = true;
          if (result.length >= limit) break;
        }
      }
      if (!added) break;
      i++;
    }
    return result;
  }

  /// Deep Cut Mix — obscure tracks the user played a lot but recently faded
  /// out of rotation; prefers non-starred, low-recently-played songs.
  /// Ensures artist diversity for a more varied listening experience.
  List<Song> _buildDeepCutMix(List<Song> allSongs, Set<String> usedSongIds,
      {int limit = 20}) {
    final pool =
        allSongs.where((s) => !usedSongIds.contains(s.id)).toList();
    if (pool.isEmpty) return [];

    final playedIds = _recentlyPlayed.toSet();
    final scored = pool.map((s) {
      final base = calculateSongScore(s);
      var score = base;
      // Reward songs the user listened to before...
      if (playedIds.contains(s.id)) {
        score += 15;
      }
      // ...but penalize whatever was just played.
      final recentIndex = _recentIndex[s.id];
      if (recentIndex != null && recentIndex < 15) {
        score -= 20 * (1 - recentIndex / 15);
      }
      // Bump non-starred (less obvious) tracks.
      if (!_starredSongs.contains(s.id)) {
        score += 6;
      }
      return MapEntry(s, score);
    }).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // Deduplicate artists for better diversity
    final seenArtists = <String>{};
    final result = <Song>[];
    for (final entry in scored) {
      if (result.length >= limit) break;
      if (entry.key.artistId != null && seenArtists.contains(entry.key.artistId)) {
        continue;
      }
      if (entry.key.artistId != null) seenArtists.add(entry.key.artistId!);
      result.add(entry.key);
    }
    return result;
  }

  /// Artist Fusion — interleaves the top favorite artists' songs, boosting
  /// the songs that appear in both a favorite genre and a favorite artist.
  /// Ensures genre diversity by preferring cross-genre picks.
  List<Song> _buildArtistFusionMix(List<Song> allSongs, Set<String> usedSongIds,
      {int limit = 25}) {
    final topArtists = _getTopArtists(4);
    if (topArtists.isEmpty) return [];
    final topGenres = _getTopGenres(3).toSet();

    final perArtist = (limit / topArtists.length).ceil();
    final result = <Song>[];
    final usedGenres = <String>{};
    for (var round = 0; round < perArtist; round++) {
      for (final artist in topArtists) {
        final candidates = allSongs
            .where((s) =>
                s.artist == artist &&
                !usedSongIds.contains(s.id) &&
                !result.contains(s))
            .toList();
        if (candidates.isEmpty) continue;
        final ranked = candidates
            .map((s) {
              var bonus = 0.0;
              if (s.genre != null && topGenres.contains(s.genre)) bonus += 8;
              // Prefer genres not yet used in this mix for diversity
              if (s.genre != null && !usedGenres.contains(s.genre)) bonus += 5;
              return MapEntry(s, calculateSongScore(s) + bonus);
            })
            .toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        if (ranked.isNotEmpty) {
          result.add(ranked.first.key);
          if (ranked.first.key.genre != null) usedGenres.add(ranked.first.key.genre!);
        }
        if (result.length >= limit) break;
      }
      if (result.length >= limit) break;
    }
    return result;
  }

  /// Пакетное чтение BPM для пула: таблица audio_features одним SELECT
  /// (включая bpm-only legacy-строки, которые getCached() не видит) +
  /// prefs-фолбэк. Раньше чтение шло только из prefs-ключей `bpm_*`,
  /// удалённых миграцией, — Tempo/Mood миксы всегда гадали по жанру.
  Future<Map<String, double>> _bpmForPool(List<Song> pool) async {
    if (_inIsolate) return Map<String, double>.from(_bpmOverride ?? const {});
    final out = <String, double>{};
    try {
      final rows =
          await _db.getAudioFeaturesBatch(pool.map((s) => s.id).toList());
      rows.forEach((id, row) {
        final b = row['bpm'];
        if (b != null) out[id] = b;
      });
    } catch (_) {}
    final prefs = _prefs;
    if (prefs != null) {
      for (final s in pool) {
        if (!out.containsKey(s.id)) {
          final v = prefs.getInt('bpm_${s.id}');
          if (v != null) out[s.id] = v.toDouble();
        }
      }
    }
    return out;
  }

   List<Song> getLocalRecommendations({required List<Song> songs, int count = 20}) {
     final scored = songs.map((s) {
       final score = calculateSongScore(s);
       return MapEntry(s, score);
     }).toList();
     scored.sort((a, b) => b.value.compareTo(a.value));
     return scored.map((e) => e.key).take(count).toList();
   }

   List<String> getRecommendedArtists({int limit = 10}) => _getTopArtists(limit);
   List<String> getRecommendedGenres({int limit = 5}) => _getTopGenres(limit);

  Map<String, dynamic> getListeningStats() {
    int totalPlays = 0;
    int totalDuration = 0;
    int ratedSongs = 0;
    int totalRating = 0;
    int totalSkips = 0;

    for (final p in _profiles.values) {
      totalPlays += p.playCount;
      totalDuration += p.totalListenTime;
      totalSkips += p.skipCount;
      if (p.userRating != null) {
        ratedSongs++;
        totalRating += p.userRating!;
      }
    }

    return {
      'totalPlays': totalPlays,
      'totalMinutes': totalDuration ~/ 60,
      'uniqueSongs': _profiles.length,
      'uniqueArtists': _artistAffinity.length,
      'uniqueGenres': _genreAffinity.length,
      'starredSongs': _starredSongs.length,
      'ratedSongs': ratedSongs,
      'totalSkips': totalSkips,
      'averageRating': ratedSongs > 0 ? totalRating / ratedSongs : 0.0,
      'skipRate': totalPlays > 0 ? totalSkips / totalPlays : 0.0,
      'topArtists': _getTopArtists(5),
      'topGenres': _getTopGenres(5),
    };
  }

  Future<void> clearData() async {
    _profiles.clear();
    _artistAffinity.clear();
    _genreAffinity.clear();
    _albumAffinity.clear();
    _skipCounts.clear();
    _timePatterns.clear();
    _recentlyPlayed.clear();
    _recentIndex.clear();
    _starredSongs.clear();
    _artistRatingAffinity.clear();
    _genreRatingAffinity.clear();
    _invalidateCaches();

    final prefs = _prefs ?? await SharedPreferences.getInstance();
    await Future.wait([
      prefs.remove(_kDataKey),
      prefs.remove(_kSkipKey),
      prefs.remove(_kTimeKey),
      prefs.remove(_kDecayKey),
    ]);

    notifyListeners();
  }

  double _listenWeight(Song song, int secondsPlayed,
      {required bool completed}) {
    if (completed) return 1.5;
    if (song.duration == null || song.duration == 0) return 0.8;
    final ratio = secondsPlayed / song.duration!;
    if (ratio >= 0.80) return 1.3;
    if (ratio >= 0.60) return 1.0;
    if (ratio >= 0.40) return 0.8;
    if (ratio >= 0.20) return 0.5;
    return 0.2;
  }

  List<Song> _sortByScore(
    List<Song> songs, {
    double jitter = 0.0,
    required int limit,
    VibeFeatures? vibeProfile,
    double vibeWeight = 0.10,
    double fingerprintWeight = 0.08,
    double mabWeight = 0.12,
    double timeWeight = 0.60,
    double moodWeight = 0.06,
    double itemSimWeight = 0.18,
  }) {
    if (songs.isEmpty) return [];

    // Deduplicate and filter banned artists
    final seenIds = <String>{};
    final moodDrift = _moodDrift;
    final bannedNamesLower = _bannedArtistsNames.map((n) => n.toLowerCase()).toSet();
    final uniqueSongs = songs.where((s) {
      if (!seenIds.add(s.id)) return false;
      if (s.artistId != null && _bannedArtists.contains(s.artistId)) return false;
      if (s.artist != null && bannedNamesLower.contains(s.artist!.toLowerCase())) return false;
      // Respect short-lived mood-drift bans (e.g. a genre that was skipped
      // 3+ times in a short window).
      if (moodDrift != null) {
        if (s.artistId != null && moodDrift.isTempBanned(s.artistId!, 'artist')) {
          return false;
        }
        if (s.genre != null && moodDrift.isTempBanned(s.genre!, 'genre')) {
          return false;
        }
      }
      return true;
    }).toList();

    final rnd = jitter > 0 ? Random() : null;
    final hour = DateTime.now().hour;
    final vibe = VibeSimilarity();
    final fp = _fingerprint;
    final hotArtists = _topArmIds(6);
    final hotGenres = _topArmIds(6);
    final timeHistory = _timeHistory;
    final itemSim = _itemSim;
    final itemSimScores = itemSim != null && itemSim.isReady
        ? itemSim.aggregateForSeeds(_recentlyPlayed.take(30))
        : <String, double>{};
    final moodAdjustments = moodDrift != null ? moodDrift.getPlaylistAdjustments() : null;
    final moodEnergyMax = moodAdjustments?['energyMax'] as double?;
    final moodMoodFilter = moodAdjustments?['moodFilter'] as String?;
    final sorted = (uniqueSongs.map((s) {
      final base = calculateSongScore(s, currentHour: hour);
      final j = rnd != null ? rnd.nextDouble() * jitter : 0.0;
      double v = 0.0;
      if (vibeProfile != null) {
        final songVibe = vibe.analyzeTrack(s);
        v = vibe.vibeSimilarity(vibeProfile, songVibe) * vibeWeight;
      }
      double f = 0.0;
      if (fp != null) {
        final songVibe = vibe.analyzeTrack(s);
        f = fp.scoreAgainstFingerprint(songVibe.toJson()) * fingerprintWeight;
      }
      double m = 0.0;
      if ((s.artistId != null && hotArtists.contains(s.artistId)) ||
          (s.genre != null && hotGenres.contains(s.genre))) {
        m = mabWeight;
      }
      double t = 0.0;
      if (timeHistory != null) {
        t = (timeHistory.getTimeBonus(s.id, hour) / 50).clamp(0.0, 0.2) * timeWeight;
      }
      double mood = 0.0;
      if (moodEnergyMax != null || moodMoodFilter != null) {
        final songVibe = vibe.analyzeTrack(s);
        final fitsEnergy = moodEnergyMax == null || songVibe.energy <= moodEnergyMax;
        final fitsMood = moodMoodFilter == null || vibe.detectMood(songVibe).mood.name == moodMoodFilter;
        if (fitsEnergy && fitsMood) {
          mood = moodWeight;
        }
      }
      double itemSim = 0.0;
      if (itemSimScores.isNotEmpty) {
        final sc = itemSimScores[s.id];
        if (sc != null) itemSim = sc * itemSimWeight;
      }
      return MapEntry(s, base + j + v + f + m + t + mood + itemSim);
    }).toList()
          ..sort((a, b) => b.value.compareTo(a.value)));

    // Artist diversity enforcement: max 2 per artist to prevent Wiz Khalifa spam
    // Apply for limit >= 10 (feeds/mixes), skip for tiny mixes where genre/artist is intentional
    if (limit >= 10 && sorted.length > limit) {
      const maxPerArtist = 2;
      final artistCounts = <String, int>{};
      final diverse = <Song>[];
      final overflow = <MapEntry<Song, double>>[];
      for (final e in sorted) {
        final key = (e.key.artistId ?? e.key.artist?.toLowerCase() ?? e.key.id);
        final c = artistCounts[key] ?? 0;
        if (c < maxPerArtist) {
          diverse.add(e.key);
          artistCounts[key] = c + 1;
          if (diverse.length >= limit) break;
        } else {
          overflow.add(e);
        }
      }
      // If not enough diverse tracks, fill from overflow (still respects original ranking)
      if (diverse.length < limit) {
        for (final e in overflow) {
          if (diverse.length >= limit) break;
          if (diverse.any((s) => s.id == e.key.id)) continue;
          diverse.add(e.key);
        }
      }
      // Final fallback if still short: take remaining sorted
      if (diverse.length < limit) {
        for (final e in sorted) {
          if (diverse.length >= limit) break;
          if (diverse.any((s) => s.id == e.key.id)) continue;
          diverse.add(e.key);
        }
      }
      return diverse;
    }

    return sorted.take(limit).map((e) => e.key).toList();
  }

  /// Build a vibe profile from the user's recent plays. Used as the seed
  /// for vibe-similarity scoring in `_sortByScore`. Returns null if there
  /// isn't enough recent history to build a meaningful profile.
  VibeFeatures? _buildVibeProfile(List<Song> allSongs, {int take = 20}) {
    if (_recentlyPlayed.isEmpty || allSongs.isEmpty) return null;
    final byId = {for (final s in allSongs) s.id: s};
    final recentSongs = _recentlyPlayed
        .take(take)
        .map((id) => byId[id])
        .whereType<Song>()
        .toList();
    if (recentSongs.isEmpty) return null;

    final v = VibeSimilarity();
    double e = 0, va = 0, d = 0, b = 0, ac = 0, inst = 0;
    for (final s in recentSongs) {
      final f = v.analyzeTrack(s);
      e += f.energy;
      va += f.valence;
      d += f.danceability;
      b += f.bpm;
      ac += f.acousticness;
      inst += f.instrumentalness;
    }
    final n = recentSongs.length;
    return VibeFeatures(
      energy: e / n,
      valence: va / n,
      danceability: d / n,
      bpm: b / n,
      acousticness: ac / n,
      instrumentalness: inst / n,
    );
  }

  double _cachedMax(
    Map<String, double> map,
    double? Function() getter,
    void Function(double) setter,
  ) {
    final cached = getter();
    if (cached != null) return cached;
    if (map.isEmpty) return 0.0;
    final m = map.values.reduce(max);
    setter(m);
    return m;
  }

  void _invalidateCaches() {
    _maxArtistAffinity = null;
    _maxGenreAffinity = null;
    _maxAlbumAffinity = null;
    _maxArtistRating = null;
    _maxGenreRating = null;
  }

  void _rebuildRecentIndex() {
    _recentIndex.clear();
    for (int i = 0; i < _recentlyPlayed.length; i++) {
      _recentIndex[_recentlyPlayed[i]] = i;
    }
  }

  void _applyDecay() {
    final now = DateTime.now();
    final daysSince =
        now.difference(_lastDecayApplied).inMilliseconds / 86400000.0;
    if (daysSince < 1.0) return;

    final factor = pow(0.5, daysSince / _kDecayHalfLifeDays).toDouble();

    void decayMap(Map<String, double> m) {
      for (final k in m.keys.toList()) {
        final decayed = m[k]! * factor;
        if (decayed.abs() < 0.001) {
          m.remove(k);
        } else {
          m[k] = decayed;
        }
      }
    }

    decayMap(_artistAffinity);
    decayMap(_genreAffinity);
    decayMap(_albumAffinity);
    decayMap(_artistRatingAffinity);
    decayMap(_genreRatingAffinity);
    _invalidateCaches();
    _lastDecayApplied = now;
  }

  List<String> _getTopArtists(int limit) {
    if (_artistAffinity.isEmpty) return [];
    final bannedNamesLower = _bannedArtistsNames.map((n) => n.toLowerCase()).toSet();
    return (_artistAffinity.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .where((e) => !bannedNamesLower.contains(e.key.toLowerCase()))
        .take(limit)
        .map((e) => e.key)
        .toList();
  }

  /// Public: returns top N favorite artists by affinity score.
  List<String> getTopFavoriteArtists({int limit = 10}) =>
      _getTopArtists(limit);

  List<String> _getTopGenres(int limit) {
    if (_genreAffinity.isEmpty) return [];
    return (_genreAffinity.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .take(limit)
        .map((e) => e.key)
        .toList();
  }

  String _timeLabel(int hour) {
    if (hour >= 5 && hour < 12) return 'Morning';
    if (hour >= 12 && hour < 17) return 'Afternoon';
    if (hour >= 17 && hour < 21) return 'Evening';
    return 'Night';
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: _kSaveDebounceMs),
      _saveData,
    );
  }

  Future<void> _loadAllData() async {
    final prefs = _prefs!;

    final dataJson = prefs.getString(_kDataKey);
    if (dataJson != null) {
      try {
        final Map<String, dynamic> d = json.decode(dataJson);
        _profiles = (d['profiles'] as Map<String, dynamic>?)
                ?.map((k, v) => MapEntry(k, SongProfile.fromJson(v))) ??
            {};
        _artistAffinity = _parseDoubleMap(d['artists']);
        _genreAffinity = _parseDoubleMap(d['genres']);
        _albumAffinity = _parseDoubleMap(d['albums']);
        _artistRatingAffinity = _parseDoubleMap(d['artistRatings']);
        _genreRatingAffinity = _parseDoubleMap(d['genreRatings']);
        _recentlyPlayed = List<String>.from(d['recent'] ?? []);
        _starredSongs = Set<String>.from(d['starred'] ?? []);
      } catch (e) {
        debugPrint('RecommendationService: error loading main data: $e');
      }
    }

    final skipJson = prefs.getString(_kSkipKey);
    if (skipJson != null) {
      try {
        _skipCounts = Map<String, int>.from(json.decode(skipJson));
      } catch (e) {
        debugPrint('RecommendationService: error loading skip data: $e');
      }
    }

    final timeJson = prefs.getString(_kTimeKey);
    if (timeJson != null) {
      try {
        final Map<String, dynamic> t = json.decode(timeJson);
        final parsed = <int, Map<String, double>>{};
        t.forEach((k, v) {
          final key = int.tryParse(k.toString());
          if (key != null) parsed[key] = _parseDoubleMap(v);
        });
        _timePatterns = parsed;
      } catch (e) {
        debugPrint('RecommendationService: error loading time patterns: $e');
      }
    }

    final decayTs = prefs.getInt(_kDecayKey);
    if (decayTs != null) {
      _lastDecayApplied = DateTime.fromMillisecondsSinceEpoch(decayTs);
    }

    _rebuildRecentIndex();
  }

  Future<void> _saveData() async {
    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();

      final data = {
        'profiles': _profiles.map((k, v) => MapEntry(k, v.toJson())),
        'artists': _artistAffinity,
        'genres': _genreAffinity,
        'albums': _albumAffinity,
        'recent': _recentlyPlayed,
        'starred': _starredSongs.toList(),
        'artistRatings': _artistRatingAffinity,
        'genreRatings': _genreRatingAffinity,
      };

      // Heavy JSON for 80k — offload to Isolate when large
      final dataJson = _profiles.length > 500
          ? await compute(_encodeJsonIsolate, data)
          : json.encode(data);
      final skipJson = _skipCounts.length > 500
          ? await compute(_encodeJsonIsolate, _skipCounts)
          : json.encode(_skipCounts);
      final timeMap = _timePatterns.map((k, v) => MapEntry(k.toString(), v));
      final timeJson = _timePatterns.length > 100
          ? await compute(_encodeJsonIsolate, timeMap)
          : json.encode(timeMap);
      await Future.wait([
        prefs.setString(_kDataKey, dataJson),
        prefs.setString(_kSkipKey, skipJson),
        prefs.setString(_kTimeKey, timeJson),
        prefs.setInt(_kDecayKey, _lastDecayApplied.millisecondsSinceEpoch),
      ]);
    } catch (e) {
      debugPrint('RecommendationService: error saving data: $e');
    }
  }

  Map<String, double> _parseDoubleMap(dynamic raw) {
    if (raw == null) return {};
    return (raw as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, (v as num).toDouble()));
  }
}

class SongProfile {
  final String songId;
  final String title;
  final String? artist;
  final String? artistId;
  final String? albumId;
  final String? genre;
  final int? duration;

  int playCount = 0;
  int skipCount = 0;
  int dislikeCount = 0;
  int totalListenTime = 0;
  int completedPlays = 0;
  int? userRating;
  Map<int, int> hourlyPlays = {};
  late DateTime lastPlayed;

  SongProfile({
    required this.songId,
    required this.title,
    this.artist,
    this.artistId,
    this.albumId,
    this.genre,
    this.duration,
    DateTime? lastPlayed,
  }) : lastPlayed = lastPlayed ?? DateTime.fromMillisecondsSinceEpoch(0);

  double get completionRate =>
      playCount == 0 ? 0.0 : completedPlays / playCount;

  double get skipRate {
    final total = playCount + skipCount;
    return total == 0 ? 0.0 : skipCount / total;
  }

  bool get isDisliked => skipRate > 0.6 && skipCount >= 3;

  double getHourPreference(int hour) {
    if (hourlyPlays.isEmpty) return 0.0;
    final maxH = hourlyPlays.values.reduce(max);
    if (maxH == 0) return 0.0;
    return (hourlyPlays[hour] ?? 0) / maxH;
  }

  void addPlay({int durationPlayed = 0, bool completed = false, int? hour}) {
    playCount++;
    totalListenTime += durationPlayed;
    if (completed) completedPlays++;
    if (hour != null) hourlyPlays[hour] = (hourlyPlays[hour] ?? 0) + 1;
    lastPlayed = DateTime.now();
  }

  Map<String, dynamic> toJson() => {
        'songId': songId,
        'title': title,
        'artist': artist,
        'artistId': artistId,
        'albumId': albumId,
        'genre': genre,
        'duration': duration,
        'playCount': playCount,
        'skipCount': skipCount,
        'totalListenTime': totalListenTime,
        'completedPlays': completedPlays,
        'userRating': userRating,
        'hourlyPlays': hourlyPlays.map((k, v) => MapEntry(k.toString(), v)),
        'lastPlayed': lastPlayed.millisecondsSinceEpoch,
      };

  factory SongProfile.fromJson(Map<String, dynamic> json) => SongProfile(
        songId: json['songId'] as String,
        title: json['title'] as String,
        artist: json['artist'] as String?,
        artistId: json['artistId'] as String?,
        albumId: json['albumId'] as String?,
        genre: json['genre'] as String?,
        duration: json['duration'] as int?,
        lastPlayed: json['lastPlayed'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['lastPlayed'] as int)
            : null,
      )
        ..playCount = json['playCount'] as int? ?? 0
        ..skipCount = json['skipCount'] as int? ?? 0
        ..totalListenTime = json['totalListenTime'] as int? ?? 0
        ..completedPlays = json['completedPlays'] as int? ?? 0
        ..userRating = json['userRating'] as int?
        ..hourlyPlays = (json['hourlyPlays'] as Map<String, dynamic>?)
                ?.entries
                .where((e) => int.tryParse(e.key) != null)
                .map((e) => MapEntry(int.parse(e.key), (e.value as num).toInt()))
                .fold<Map<int, int>>({}, (m, e) => m..[e.key] = e.value) ??
            {};
}
