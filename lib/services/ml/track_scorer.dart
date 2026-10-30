import 'dart:math';
import '../../models/ml/ml_types.dart';
import '../../models/song.dart';
import 'vibe_similarity.dart';
import 'time_aware_history.dart';
import 'sonic_fingerprint.dart';

class TrackScorer {
  final VibeSimilarity _vibe;
  final TimeAwareHistory? _timeHistory;
  final SonicFingerprintService? _fingerprint;
  final Random _random = Random();

  TrackScorer(
    this._vibe, {
    TimeAwareHistory? timeHistory,
    SonicFingerprintService? fingerprint,
  }) : _timeHistory = timeHistory,
       _fingerprint = fingerprint;

  Map<String, double> _getWeights(int totalLikes) {
    if (totalLikes < 50) {
      return {'audio': 0.20, 'genre': 0.30, 'artist': 0.10, 'behavior': 0.10, 'collab': 0.25, 'novelty': 0.05};
    }
    return {'audio': 0.40, 'genre': 0.20, 'artist': 0.10, 'behavior': 0.20, 'collab': 0.05, 'novelty': 0.05};
  }

  Map<String, dynamic> scoreTrack({
    required Song song,
    required MLProfile profile,
    required Map<String, TrackRating> ratings,
    required List<VibeFeatures> seedFeatures,
    required Map<String, int> usedArtists,
    required Map<String, int> usedGenres,
    int? currentHour,
    String? activity,
    String? mood,
    List<PlayEvent>? recentEvents,
    double? collabScore,
  }) {
    final weights = _getWeights(profile.likedSongs.length);
    final rating = ratings[song.id];
    final vibeFeatures = _vibe.analyzeTrack(song);

    double audioScore = 0;
    if (seedFeatures.isNotEmpty) {
      double totalSim = 0;
      for (final seedFeat in seedFeatures) {
        totalSim += _vibe.vibeSimilarity(vibeFeatures, seedFeat);
      }
      audioScore = totalSim / seedFeatures.length;
    }

    // Combine the rolling sonic fingerprint (what you've been listening to)
    // with the instantaneous vibe similarity to seeds.
    if (_fingerprint != null) {
      final fpScore = _fingerprint!.scoreAgainstFingerprint(vibeFeatures.toJson());
      audioScore = audioScore * 0.6 + fpScore * 0.4;
    }

    double genreScore = 0;
    if (song.genre != null) {
      genreScore = profile.preferredGenres[song.genre!.toLowerCase()] ?? 0;
      genreScore = (genreScore / 10).clamp(0.0, 1.0);
    }

    double artistScore = 0;
    if (song.artistId != null) {
      artistScore = profile.preferredArtists[song.artistId!] ?? 0;
      artistScore = (artistScore / 10).clamp(0.0, 1.0);
    }

    double behaviorScore = 0;
    if (rating != null) {
      behaviorScore = ((rating.score + 50) / 100).clamp(0.0, 1.0);
    }

    double noveltyScore = 1.0;    if (rating != null && rating.playCount > 0) {
      noveltyScore = (1.0 / (1.0 + rating.playCount + rating.replayCount * 2)).clamp(0.0, 1.0);
    }
    if (song.genre != null) {
      final genrePopularity = profile.preferredGenres[song.genre!.toLowerCase()] ?? 0;
      noveltyScore *= (1.0 - genrePopularity * 0.01).clamp(0.5, 1.0);
    }

    double contextBonus = 0;
    if (currentHour != null) {
      if (activity == 'work' && vibeFeatures.energy >= 0.3 && vibeFeatures.energy <= 0.6) contextBonus += 0.1;
      if (activity == 'workout' && vibeFeatures.bpm > 110) contextBonus += 0.15;
      if (activity == 'sleep' && vibeFeatures.energy < 0.3) contextBonus += 0.1;
      if (mood != null) {
        final moodDet = _vibe.detectMood(vibeFeatures);
        if (moodDet.mood.name == mood) contextBonus += 0.1;
      }
    }

    // Day/night context: boost songs historically played near this hour.
    double timeBonus = 0;
    if (_timeHistory != null && currentHour != null) {
      final rawBonus = _timeHistory!.getTimeBonus(song.id, currentHour);
      timeBonus = (rawBonus / 50).clamp(0.0, 0.2);
      contextBonus += timeBonus;
    }

    double diversityPenalty = 0;
    if (song.artistId != null && usedArtists.containsKey(song.artistId)) {
      final count = usedArtists[song.artistId]!;
      if (count == 1) diversityPenalty = 0.05;
      if (count == 2) diversityPenalty = 0.10;
      if (count >= 3) diversityPenalty = 0.15;
    }
    if (song.genre != null && usedGenres.containsKey(song.genre)) {
      final count = usedGenres[song.genre]!;
      if (count == 1) diversityPenalty += 0.03;
      if (count == 2) diversityPenalty += 0.07;
      if (count >= 3) diversityPenalty += 0.12;
    }

    double behaviorBonus = 0;
    if (recentEvents != null) {
      for (final event in recentEvents.take(10)) {
        if (event.trackId == song.id) {
          if (event.action == 'like') behaviorBonus += 0.2;
          if (event.action == 'seek_back') behaviorBonus += 0.25;
          if (event.action == 'replay') behaviorBonus += 0.25;
          if (event.action == 'abandon') behaviorBonus -= 0.15;
          if (event.action == 'skip' && event.position < 30) behaviorBonus -= 0.3;
        }
      }
    }

    final collab = (collabScore ?? 0.0).clamp(0.0, 1.0);

    // Server history: personal rating + community average (Navidrome 1–5).
    double serverScore = 0;
    if (song.userRating != null && song.userRating! > 0) {
      serverScore += (song.userRating!.clamp(1, 5) / 5.0) * 0.15;
    }
    if (song.averageRating != null && song.averageRating! > 0) {
      serverScore += (song.averageRating!.clamp(0.0, 5.0) / 5.0) * 0.10;
    }

    final totalScore = (
      weights['audio']! * audioScore +
      weights['genre']! * genreScore +
      weights['artist']! * artistScore +
      weights['behavior']! * behaviorScore +
      weights['collab']! * collab +
      weights['novelty']! * noveltyScore +
      0.08 * noveltyScore +
      contextBonus +
      behaviorBonus +
      serverScore -
      diversityPenalty +
      _random.nextDouble() * 0.12
    ).clamp(0.0, 1.0);

    String? reason;
    if (collab >= 0.7) reason = 'Loved by friends';
    else if (audioScore > 0.8) reason = 'Similar to what you love';
    else if (artistScore > 0.5) reason = 'By ${song.artist}';
    else if (genreScore > 0.5) reason = '${song.genre} you enjoy';
    else if (noveltyScore > 0.8) reason = 'New discovery';

    return {
      'song': song,
      'totalScore': totalScore,
      'audioScore': audioScore,
      'genreScore': genreScore,
      'artistScore': artistScore,
      'behaviorScore': behaviorScore,
      'collabScore': collab,
      'noveltyScore': noveltyScore,
      'contextBonus': contextBonus,
      'diversityPenalty': diversityPenalty,
      'reason': reason,
    };
  }

  List<Map<String, dynamic>> scoreAndRankTracks({
    required List<Song> candidates,
    required MLProfile profile,
    required Map<String, TrackRating> ratings,
    required List<Song> seedTracks,
    int? limit,
    int? currentHour,
    String? activity,
    String? mood,
    List<PlayEvent>? recentEvents,
    Map<String, double>? collabScores,
  }) {
    final usedArtists = <String, int>{};
    final usedGenres = <String, int>{};
    final results = <Map<String, dynamic>>[];

    // Pre-compute seed vibe features once (was being recomputed per candidate).
    final seedFeaturesList = <VibeFeatures>[];
    for (final seed in seedTracks) {
      seedFeaturesList.add(_vibe.analyzeTrack(seed));
    }

    for (final song in candidates) {
      final result = scoreTrack(
        song: song,
        profile: profile,
        ratings: ratings,
        seedFeatures: seedFeaturesList,
        usedArtists: usedArtists,
        usedGenres: usedGenres,
        currentHour: currentHour,
        activity: activity,
        mood: mood,
        recentEvents: recentEvents,
        collabScore: collabScores?[song.queueKey] ?? collabScores?[song.id],
      );
      results.add(result);

      if (song.artistId != null) {
        usedArtists[song.artistId!] = (usedArtists[song.artistId!] ?? 0) + 1;
      }
      if (song.genre != null) {
        usedGenres[song.genre!] = (usedGenres[song.genre!] ?? 0) + 1;
      }
    }

    results.sort((a, b) => (b['totalScore'] as double).compareTo(a['totalScore'] as double));
    if (limit != null) return results.take(limit).toList();
    return results;
  }
}
