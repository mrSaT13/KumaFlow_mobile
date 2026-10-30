import 'dart:math';
import '../../models/ml/ml_types.dart';
import '../../models/song.dart';
import 'vibe_similarity.dart';
import 'ml_wave_service.dart';
import 'ml_store.dart';

// ── Ported from D:\kumaflow-1.6.1\src\service\track-scorer.ts GENRE_BRIDGES ──
const Map<String, Map<String, List<String>>> _genreBridges = {
  'Rock': {
    'Pop': ['Indie', 'Indie Rock', 'Alternative', 'Indie Pop'],
    'Hip-Hop': ['Rap Rock', 'Nu Metal', 'Alternative Hip-Hop'],
    'Electronic': ['Synth Rock', 'Electro Rock', 'New Wave'],
  },
  'Pop': {
    'Rock': ['Indie', 'Indie Pop', 'Alternative', 'Pop Rock'],
    'Hip-Hop': ['Pop Rap', 'Trap Pop', 'R&B'],
    'Electronic': ['Synth Pop', 'Dance Pop', 'Electropop'],
  },
  'Hip-Hop': {
    'Rock': ['Rap Rock', 'Nu Metal', 'Alternative Hip-Hop'],
    'Pop': ['Pop Rap', 'Trap Pop', 'R&B'],
    'Electronic': ['Trap', 'Hip-House', 'Electro'],
  },
  'Electronic': {
    'Rock': ['Synth Rock', 'Electro Rock', 'New Wave'],
    'Pop': ['Synth Pop', 'Dance Pop', 'Electropop'],
    'Hip-Hop': ['Trap', 'Hip-House', 'Electro'],
  },
  'Jazz': {
    'Rock': ['Jazz Fusion', 'Jazz Rock', 'Funk'],
    'Pop': ['Vocal Jazz', 'Jazz Pop', 'Swing'],
    'Hip-Hop': ['Jazz Rap', 'Lo-Fi Hip-Hop', 'Trip-Hop'],
  },
};

class SmartAutoDJ {
  final MLWaveService _waveService;
  final MLStore _store;
  final VibeSimilarity _vibe = VibeSimilarity();
  final Random _random = Random();

  SmartAutoDJ(this._waveService, this._store);

  Future<List<Song>> generateSmartAutoDJ({
    required Song currentSong,
    required List<Song> songlist,
    required int currentIndex,
    int count = 10,
  }) async {
    final lastPlayed = _getLastPlayedTracks(songlist, currentIndex, 5);

    double avgEnergy = 0, avgValence = 0, avgDanceability = 0, avgBpm = 0, avgAcousticness = 0;
    for (final song in lastPlayed) {
      final f = _vibe.analyzeTrack(song);
      avgEnergy += f.energy;
      avgValence += f.valence;
      avgDanceability += f.danceability;
      avgBpm += f.bpm;
      avgAcousticness += f.acousticness;
    }
    if (lastPlayed.isNotEmpty) {
      avgEnergy /= lastPlayed.length;
      avgValence /= lastPlayed.length;
      avgDanceability /= lastPlayed.length;
      avgBpm /= lastPlayed.length;
      avgAcousticness /= lastPlayed.length;
    }

    final contextProfile = VibeFeatures(
      energy: avgEnergy, valence: avgValence, danceability: avgDanceability,
      bpm: avgBpm, acousticness: avgAcousticness, instrumentalness: 0,
    );

    // candidateCount = count*3 как в desktop smart-auto-dj.ts
    final similar = await _waveService.getSimilarTracks(currentSong, count * 3);

    final feedback = _waveService.behaviorTracker.getRecentFeedback();
    final skippedIds = feedback['skippedTrackIds'] as Set<String>? ?? {};
    final bannedArtists = _store.profile.bannedArtists.toSet();
    // Фильтр по именам: MLStore хранит только id; имя сверяем через songInfo
    // рейтингов + dislikedSongs (копипаст-баг: раньше тут был тот же set id).
    final dislikedSongs = _store.profile.dislikedSongs.toSet();
    final bannedLowerNames = <String>{};
    for (final id in bannedArtists) {
      final info = _store.ratings[id]?.songInfo;
      final n = info?['artist'];
      if (n != null && n.isNotEmpty) bannedLowerNames.add(n.toLowerCase());
    }

    // ── Filter banned/skipped ──
    var filtered = similar.where((s) {
      if (skippedIds.contains(s.id)) return false;
      if (dislikedSongs.contains(s.id)) return false;
      if (s.artistId != null && bannedArtists.contains(s.artistId)) return false;
      if (s.artist != null && bannedLowerNames.contains(s.artist!.toLowerCase())) return false;
      return true;
    }).toList();

    if (filtered.isEmpty) return [];

    // ── Vibe 60% filter: оставляем топ 60% по similarity к contextProfile ──
    // Как в desktop: vibe-фильтр 60% similarity to last 5 tracks
    if (filtered.length > count && lastPlayed.isNotEmpty) {
      final withSim = filtered.map((s) {
        final sim = _vibe.vibeSimilarity(contextProfile, _vibe.analyzeTrack(s));
        return MapEntry(s, sim);
      }).toList()..sort((a, b) => b.value.compareTo(a.value));
      final keep = (filtered.length * 0.6).ceil().clamp(count, filtered.length);
      filtered = withSim.take(keep).map((e) => e.key).toList();
    }

    // Adaptive weights: новичок (<50 лайков) vs опытный
    final isBeginner = _store.profile.likedSongs.length < 50;
    final wVibe = isBeginner ? 0.25 : 0.35;
    final wBpm = 0.20;
    final wGenre = isBeginner ? 0.25 : 0.15;
    final wArtist = 0.10;
    final wEnergy = 0.10;

    // Precompute top genres for bridge bonus
    final topGenres = _getTopGenres(3);

    final scored = <Map<String, dynamic>>[];
    for (final song in filtered) {
      final f = _vibe.analyzeTrack(song);
      final vibeSim = _vibe.vibeSimilarity(contextProfile, f);

      final targetBpm = _getTargetBpm();
      final bpmFit = 1.0 - ((f.bpm - targetBpm).abs() / 100).clamp(0.0, 1.0);

      double genreTransition = 0;
      if (song.genre != null && currentSong.genre != null && song.genre!.toLowerCase() == currentSong.genre!.toLowerCase()) {
        genreTransition = 0.8;
      } else {
        genreTransition = 0.5;
      }
      // Genre bridge bonus (additive, not replacing transition)
      final bridgeBonus = _calculateGenreBridgeBonus(song.genre, topGenres);

      double artistDiversity = 1.0;
      if (song.artistId != null && song.artistId == currentSong.artistId) artistDiversity = 0.5;

      double energyBalance = 1.0 - ((f.energy - avgEnergy).abs()).clamp(0.0, 1.0);

      double behavioralPenalty = 0;
      if (skippedIds.contains(song.id)) behavioralPenalty = 0.3;

      final anniversaryBonus = _calculateAnniversaryBonus(song);
      // Time-aware bonus: если трек часто слушают в этот час
      double timeBonus = 0;
      // MLStore не хранит timeHistory напрямую, используем vibe context: work/workout/sleep уже учтены в bpmFit/energy
      // Anniversary уже добавили

      double jitter = _random.nextDouble() * 0.04; // маленький jitter для разнообразия, не ломает детерминизм

      final score = vibeSim * wVibe +
          bpmFit * wBpm +
          genreTransition * wGenre +
          artistDiversity * wArtist +
          energyBalance * wEnergy +
          bridgeBonus +
          anniversaryBonus +
          timeBonus -
          behavioralPenalty +
          jitter;

      scored.add({'song': song, 'score': score, 'vibeSim': vibeSim});
    }

    scored.sort((a, b) => (b['score'] as double).compareTo(a['score'] as double));

    // ── Diversity: не более 2 треков одного артиста подряд ──
    final result = <Song>[];
    final usedArtists = <String, int>{};
    for (final entry in scored) {
      if (result.length >= count) break;
      final s = entry['song'] as Song;
      final aid = s.artistId ?? s.artist ?? s.id;
      final cnt = usedArtists[aid] ?? 0;
      if (cnt >= 2) continue; // пропускаем третьего подряд того же артиста
      result.add(s);
      usedArtists[aid] = cnt + 1;
    }
    // Если из-за diversity недобор — добираем без ограничения
    if (result.length < count) {
      for (final entry in scored) {
        if (result.length >= count) break;
        final s = entry['song'] as Song;
        if (result.any((r) => r.id == s.id)) continue;
        result.add(s);
      }
    }

    return result.take(count).toList();
  }

  double _calculateGenreBridgeBonus(String? songGenre, List<String> topGenres) {
    if (songGenre == null || topGenres.length < 2) return 0;
    final sg = songGenre.toLowerCase();
    for (int i = 0; i < topGenres.length; i++) {
      for (int j = i + 1; j < topGenres.length; j++) {
        final a = topGenres[i];
        final b = topGenres[j];
        final bridges = _genreBridges[a]?[b] ?? _genreBridges[b]?[a] ?? [];
        for (final bridge in bridges) {
          if (sg.contains(bridge.toLowerCase())) return 0.12;
        }
      }
    }
    return 0;
  }

  double _calculateAnniversaryBonus(Song song) {
    final rating = _store.ratings[song.id];
    final lastPlayedRaw = rating?.lastPlayed;
    if (rating == null || lastPlayedRaw == null || lastPlayedRaw.isEmpty) return 0;
    try {
      final last = DateTime.tryParse(lastPlayedRaw);
      if (last == null) return 0;
      final now = DateTime.now();
      final sameDay = now.day == last.day && now.month == last.month;
      final sameMonth = now.month == last.month;
      if (sameDay) {
        final years = now.year - last.year;
        if (years >= 1) return 0.15;
      }
      if (sameMonth) {
        final years = now.year - last.year;
        if (years >= 1) return 0.07;
      }
    } catch (_) {}
    return 0;
  }

  List<String> _getTopGenres(int limit) {
    final map = _store.profile.preferredGenres;
    if (map.isEmpty) return [];
    final sorted = map.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(limit).map((e) => e.key).toList();
  }

  List<Song> _getLastPlayedTracks(List<Song> songlist, int currentIndex, int count) {
    final start = max(0, currentIndex - count);
    final end = currentIndex.clamp(0, songlist.length);
    if (start >= end) return [];
    return songlist.sublist(start, end);
  }

  double _getTargetBpm() {
    final hour = DateTime.now().hour;
    if (hour >= 6 && hour < 12) return 105;
    if (hour >= 12 && hour < 18) return 130;
    if (hour >= 18 && hour < 22) return 110;
    return 75;
  }

  bool canUseSmartAutoDJ(List<Song> songlist, int currentIndex) {
    return currentIndex >= 3 && songlist.length > 5;
  }
}
