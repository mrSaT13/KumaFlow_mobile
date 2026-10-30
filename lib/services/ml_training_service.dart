import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import 'recommendation_service.dart';

/// Service for ML training based on user feedback (like/dislike).
///
/// When user likes a track, it increases affinity for that artist/genre.
/// When user dislikes, it decreases affinity and adds to blocklist.
class MlTrainingService {
  static final MlTrainingService _instance = MlTrainingService._internal();
  factory MlTrainingService() => _instance;
  MlTrainingService._internal();

  static const _kLikedArtistsKey = 'ml_liked_artists';
  static const _kLikedGenresKey = 'ml_liked_genres';
  static const _kDislikedArtistsKey = 'ml_disliked_artists';
  static const _kDislikedGenresKey = 'ml_disliked_genres';
  static const _kDislikedTracksKey = 'ml_disliked_tracks';
  static const _kArtistWeightKey = 'ml_artist_weight_';
  static const _kGenreWeightKey = 'ml_genre_weight_';

  // Weights for ML training
  static const double _likeArtistWeight = 0.15;
  static const double _likeGenreWeight = 0.10;
  static const double _dislikeArtistWeight = -0.20;
  static const double _dislikeGenreWeight = -0.15;
  static const double _playCompletionWeight = 0.05;
  static const double _skipPenaltyWeight = -0.03;

  final RecommendationService _recommendationService = RecommendationService();

  // ──────────────────────────────────────────────────────────────────────────
  // Like/Dislike tracking
  // ──────────────────────────────────────────────────────────────────────────

  /// Record a like for a track.
  Future<void> likeTrack(Song song) async {
    final prefs = await SharedPreferences.getInstance();

    // Update artist affinity
    if (song.artistId != null) {
      final currentWeight = prefs.getDouble('$_kArtistWeightKey${song.artistId}') ?? 0.0;
      final newWeight = (currentWeight + _likeArtistWeight).clamp(-1.0, 1.0);
      await prefs.setDouble('$_kArtistWeightKey${song.artistId}', newWeight);

      // Track liked artists
      final likedArtists = prefs.getStringList(_kLikedArtistsKey) ?? [];
      if (!likedArtists.contains(song.artistId)) {
        likedArtists.add(song.artistId!);
        await prefs.setStringList(_kLikedArtistsKey, likedArtists);
      }

      debugPrint('[MlTraining] Liked artist ${song.artist}: weight=$newWeight');
    }

    // Update genre affinity
    if (song.genre != null) {
      final currentWeight = prefs.getDouble('$_kGenreWeightKey${song.genre}') ?? 0.0;
      final newWeight = (currentWeight + _likeGenreWeight).clamp(-1.0, 1.0);
      await prefs.setDouble('$_kGenreWeightKey${song.genre}', newWeight);

      // Track liked genres
      final likedGenres = prefs.getStringList(_kLikedGenresKey) ?? [];
      if (!likedGenres.contains(song.genre)) {
        likedGenres.add(song.genre!);
        await prefs.setStringList(_kLikedGenresKey, likedGenres);
      }

      debugPrint('[MlTraining] Liked genre ${song.genre}: weight=$newWeight');
    }

    // Update recommendation service
    await _recommendationService.trackSongPlay(
      song,
      completed: true,
    );
  }

  /// Record a dislike for a track.
  Future<void> dislikeTrack(Song song) async {
    final prefs = await SharedPreferences.getInstance();

    // Update artist affinity (decrease)
    if (song.artistId != null) {
      final currentWeight = prefs.getDouble('$_kArtistWeightKey${song.artistId}') ?? 0.0;
      final newWeight = (currentWeight + _dislikeArtistWeight).clamp(-1.0, 1.0);
      await prefs.setDouble('$_kArtistWeightKey${song.artistId}', newWeight);

      // Track disliked artists
      final dislikedArtists = prefs.getStringList(_kDislikedArtistsKey) ?? [];
      if (!dislikedArtists.contains(song.artistId)) {
        dislikedArtists.add(song.artistId!);
        await prefs.setStringList(_kDislikedArtistsKey, dislikedArtists);
      }

      debugPrint('[MlTraining] Disliked artist ${song.artist}: weight=$newWeight');
    }

    // Update genre affinity (decrease)
    if (song.genre != null) {
      final currentWeight = prefs.getDouble('$_kGenreWeightKey${song.genre}') ?? 0.0;
      final newWeight = (currentWeight + _dislikeGenreWeight).clamp(-1.0, 1.0);
      await prefs.setDouble('$_kGenreWeightKey${song.genre}', newWeight);

      // Track disliked genres
      final dislikedGenres = prefs.getStringList(_kDislikedGenresKey) ?? [];
      if (!dislikedGenres.contains(song.genre)) {
        dislikedGenres.add(song.genre!);
        await prefs.setStringList(_kDislikedGenresKey, dislikedGenres);
      }

      debugPrint('[MlTraining] Disliked genre ${song.genre}: weight=$newWeight');
    }

    // Add to disliked tracks (to exclude from recommendations)
    final dislikedTracks = prefs.getStringList(_kDislikedTracksKey) ?? [];
    if (!dislikedTracks.contains(song.id)) {
      dislikedTracks.add(song.id);
      await prefs.setStringList(_kDislikedTracksKey, dislikedTracks);
    }

    // Update recommendation service
    await _recommendationService.trackSongPlay(
      song,
      completed: false,
    );
  }

  /// Record a play completion (positive signal).
  Future<void> completePlay(Song song) async {
    final prefs = await SharedPreferences.getInstance();

    // Slight positive weight for completed plays
    if (song.artistId != null) {
      final currentWeight = prefs.getDouble('$_kArtistWeightKey${song.artistId}') ?? 0.0;
      final newWeight = (currentWeight + _playCompletionWeight).clamp(-1.0, 1.0);
      await prefs.setDouble('$_kArtistWeightKey${song.artistId}', newWeight);
    }

    if (song.genre != null) {
      final currentWeight = prefs.getDouble('$_kGenreWeightKey${song.genre}') ?? 0.0;
      final newWeight = (currentWeight + _playCompletionWeight).clamp(-1.0, 1.0);
      await prefs.setDouble('$_kGenreWeightKey${song.genre}', newWeight);
    }
  }

  /// Record a skip (negative signal).
  Future<void> skipTrack(Song song) async {
    final prefs = await SharedPreferences.getInstance();

    // Slight negative weight for skips
    if (song.artistId != null) {
      final currentWeight = prefs.getDouble('$_kArtistWeightKey${song.artistId}') ?? 0.0;
      final newWeight = (currentWeight + _skipPenaltyWeight).clamp(-1.0, 1.0);
      await prefs.setDouble('$_kArtistWeightKey${song.artistId}', newWeight);
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Query methods
  // ──────────────────────────────────────────────────────────────────────────

  /// Get artist affinity weight.
  Future<double> getArtistWeight(String artistId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble('$_kArtistWeightKey$artistId') ?? 0.0;
  }

  /// Get genre affinity weight.
  Future<double> getGenreWeight(String genre) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble('$_kGenreWeightKey$genre') ?? 0.0;
  }

  /// Get all liked artist IDs.
  Future<List<String>> getLikedArtists() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kLikedArtistsKey) ?? [];
  }

  /// Get all liked genres.
  Future<List<String>> getLikedGenres() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kLikedGenresKey) ?? [];
  }

  /// Get all disliked artist IDs.
  Future<List<String>> getDislikedArtists() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kDislikedArtistsKey) ?? [];
  }

  /// Get all disliked genres.
  Future<List<String>> getDislikedGenres() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kDislikedGenresKey) ?? [];
  }

  /// Get all disliked track IDs (to exclude from recommendations).
  Future<Set<String>> getDislikedTracks() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_kDislikedTracksKey) ?? []).toSet();
  }

  /// Get artist affinity map for recommendation service.
  Future<Map<String, double>> getArtistAffinityMap() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, double>{};

    for (final key in prefs.getKeys()) {
      if (key.startsWith(_kArtistWeightKey)) {
        final artistId = key.substring(_kArtistWeightKey.length);
        final weight = prefs.getDouble(key) ?? 0.0;
        if (weight != 0) {
          map[artistId] = weight;
        }
      }
    }

    return map;
  }

  /// Get genre affinity map for recommendation service.
  Future<Map<String, double>> getGenreAffinityMap() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, double>{};

    for (final key in prefs.getKeys()) {
      if (key.startsWith(_kGenreWeightKey)) {
        final genre = key.substring(_kGenreWeightKey.length);
        final weight = prefs.getDouble(key) ?? 0.0;
        if (weight != 0) {
          map[genre] = weight;
        }
      }
    }

    return map;
  }

  /// Check if a track is liked.
  Future<bool> isTrackLiked(String trackId) async {
    final prefs = await SharedPreferences.getInstance();
    final likedTracks = prefs.getStringList('liked_tracks') ?? [];
    return likedTracks.contains(trackId);
  }

  /// Check if a track is disliked.
  Future<bool> isTrackDisliked(String trackId) async {
    final dislikedTracks = await getDislikedTracks();
    return dislikedTracks.contains(trackId);
  }

  /// Get ML training statistics.
  Future<MlStats> getStats() async {
    final likedArtists = await getLikedArtists();
    final likedGenres = await getLikedGenres();
    final dislikedArtists = await getDislikedArtists();
    final dislikedGenres = await getDislikedGenres();
    final dislikedTracks = await getDislikedTracks();

    return MlStats(
      likedArtistsCount: likedArtists.length,
      likedGenresCount: likedGenres.length,
      dislikedArtistsCount: dislikedArtists.length,
      dislikedGenresCount: dislikedGenres.length,
      dislikedTracksCount: dislikedTracks.length,
    );
  }

  /// Clear all ML training data.
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();

    // Remove all ML weights
    final keysToRemove = prefs.getKeys().where((k) =>
        k.startsWith(_kArtistWeightKey) ||
        k.startsWith(_kGenreWeightKey) ||
        k == _kLikedArtistsKey ||
        k == _kLikedGenresKey ||
        k == _kDislikedArtistsKey ||
        k == _kDislikedGenresKey ||
        k == _kDislikedTracksKey);

    for (final key in keysToRemove) {
      await prefs.remove(key);
    }

    debugPrint('[MlTraining] Cleared all training data');
  }
}

/// ML training statistics.
class MlStats {
  final int likedArtistsCount;
  final int likedGenresCount;
  final int dislikedArtistsCount;
  final int dislikedGenresCount;
  final int dislikedTracksCount;

  MlStats({
    required this.likedArtistsCount,
    required this.likedGenresCount,
    required this.dislikedArtistsCount,
    required this.dislikedGenresCount,
    required this.dislikedTracksCount,
  });

  int get totalFeedback =>
      likedArtistsCount +
      likedGenresCount +
      dislikedArtistsCount +
      dislikedGenresCount +
      dislikedTracksCount;
}
