import '../../models/ml/ml_types.dart';
import '../../models/song.dart';

class VibeSimilarity {
  /// Session-wide memo so repeated similarity passes over the same tracks
  /// don't recompute genre estimates. Static: call sites often create
  /// short-lived instances (e.g. `VibeSimilarity().analyzeTrack(song)`).
  static final Map<String, VibeFeatures> _memo = {};
  static const int _memoCap = 10000;

  static String memoKey(Song song) => '${song.id}|${song.genre ?? ''}';

  /// Drop memoized entries (e.g. on server switch).
  static void clearMemo() => _memo.clear();
  static const Map<String, VibeFeatures> genreProfiles = {
    'electronic': VibeFeatures(energy: 0.85, valence: 0.6, danceability: 0.9, bpm: 128, acousticness: 0.1, instrumentalness: 0.7),
    'edm': VibeFeatures(energy: 0.9, valence: 0.7, danceability: 0.95, bpm: 130, acousticness: 0.05, instrumentalness: 0.8),
    'house': VibeFeatures(energy: 0.8, valence: 0.65, danceability: 0.9, bpm: 125, acousticness: 0.05, instrumentalness: 0.75),
    'techno': VibeFeatures(energy: 0.85, valence: 0.4, danceability: 0.85, bpm: 135, acousticness: 0.05, instrumentalness: 0.9),
    'hip hop': VibeFeatures(energy: 0.6, valence: 0.5, danceability: 0.75, bpm: 90, acousticness: 0.2, instrumentalness: 0.1),
    'rap': VibeFeatures(energy: 0.65, valence: 0.5, danceability: 0.7, bpm: 85, acousticness: 0.15, instrumentalness: 0.05),
    'pop': VibeFeatures(energy: 0.65, valence: 0.7, danceability: 0.75, bpm: 115, acousticness: 0.3, instrumentalness: 0.05),
    'rock': VibeFeatures(energy: 0.75, valence: 0.55, danceability: 0.5, bpm: 120, acousticness: 0.25, instrumentalness: 0.3),
    'metal': VibeFeatures(energy: 0.9, valence: 0.35, danceability: 0.3, bpm: 140, acousticness: 0.1, instrumentalness: 0.5),
    'punk': VibeFeatures(energy: 0.85, valence: 0.5, danceability: 0.4, bpm: 150, acousticness: 0.15, instrumentalness: 0.3),
    'jazz': VibeFeatures(energy: 0.4, valence: 0.6, danceability: 0.4, bpm: 100, acousticness: 0.7, instrumentalness: 0.6),
    'blues': VibeFeatures(energy: 0.4, valence: 0.4, danceability: 0.4, bpm: 90, acousticness: 0.7, instrumentalness: 0.4),
    'classical': VibeFeatures(energy: 0.3, valence: 0.5, danceability: 0.2, bpm: 80, acousticness: 0.9, instrumentalness: 0.95),
    'ambient': VibeFeatures(energy: 0.15, valence: 0.5, danceability: 0.1, bpm: 70, acousticness: 0.6, instrumentalness: 0.9),
    'folk': VibeFeatures(energy: 0.35, valence: 0.6, danceability: 0.35, bpm: 95, acousticness: 0.85, instrumentalness: 0.2),
    'country': VibeFeatures(energy: 0.5, valence: 0.65, danceability: 0.55, bpm: 110, acousticness: 0.6, instrumentalness: 0.15),
    'r&b': VibeFeatures(energy: 0.55, valence: 0.6, danceability: 0.7, bpm: 95, acousticness: 0.35, instrumentalness: 0.1),
    'soul': VibeFeatures(energy: 0.5, valence: 0.65, danceability: 0.6, bpm: 100, acousticness: 0.45, instrumentalness: 0.1),
    'reggae': VibeFeatures(energy: 0.5, valence: 0.7, danceability: 0.7, bpm: 80, acousticness: 0.4, instrumentalness: 0.3),
    'latin': VibeFeatures(energy: 0.7, valence: 0.75, danceability: 0.85, bpm: 110, acousticness: 0.3, instrumentalness: 0.1),
    'indie': VibeFeatures(energy: 0.55, valence: 0.55, danceability: 0.5, bpm: 110, acousticness: 0.5, instrumentalness: 0.25),
    'alternative': VibeFeatures(energy: 0.65, valence: 0.5, danceability: 0.45, bpm: 115, acousticness: 0.35, instrumentalness: 0.2),
    'lo-fi': VibeFeatures(energy: 0.25, valence: 0.5, danceability: 0.3, bpm: 75, acousticness: 0.6, instrumentalness: 0.7),
    'synthwave': VibeFeatures(energy: 0.7, valence: 0.6, danceability: 0.65, bpm: 118, acousticness: 0.1, instrumentalness: 0.6),
    'metalcore': VibeFeatures(energy: 0.9, valence: 0.3, danceability: 0.25, bpm: 145, acousticness: 0.1, instrumentalness: 0.4),
  };

  static const Map<String, List<String>> moodCompatibility = {
    'energetic': ['happy', 'dramatic', 'focused'],
    'happy': ['energetic', 'calm', 'relaxed'],
    'calm': ['happy', 'relaxed', 'romantic'],
    'sad': ['melancholic', 'calm', 'dramatic'],
    'angry': ['energetic', 'dramatic'],
    'melancholic': ['sad', 'calm', 'romantic'],
    'relaxed': ['calm', 'happy', 'romantic'],
    'focused': ['energetic', 'calm'],
    'romantic': ['calm', 'relaxed', 'melancholic'],
    'dramatic': ['energetic', 'angry', 'melancholic'],
  };

  VibeFeatures analyzeTrack(Song song, {Map<String, dynamic>? extraFeatures}) {
    final key = memoKey(song);
    if (extraFeatures == null) {
      final hit = _memo[key];
      if (hit != null) return hit;
    }

    late final VibeFeatures result;
    if (extraFeatures != null) {
      result = VibeFeatures(
        energy: (extraFeatures['energy'] as num?)?.toDouble() ?? _estimateFromGenre(song.genre, 'energy'),
        valence: (extraFeatures['valence'] as num?)?.toDouble() ?? _estimateFromGenre(song.genre, 'valence'),
        danceability: (extraFeatures['danceability'] as num?)?.toDouble() ?? _estimateFromGenre(song.genre, 'danceability'),
        bpm: (extraFeatures['bpm'] as num?)?.toDouble() ?? _estimateFromGenre(song.genre, 'bpm'),
        acousticness: (extraFeatures['acousticness'] as num?)?.toDouble() ?? _estimateFromGenre(song.genre, 'acousticness'),
        instrumentalness: (extraFeatures['instrumentalness'] as num?)?.toDouble() ?? _estimateFromGenre(song.genre, 'instrumentalness'),
      );
    } else {
      result = VibeFeatures(
        energy: _estimateFromGenre(song.genre, 'energy'),
        valence: _estimateFromGenre(song.genre, 'valence'),
        danceability: _estimateFromGenre(song.genre, 'danceability'),
        bpm: _estimateFromGenre(song.genre, 'bpm'),
        acousticness: _estimateFromGenre(song.genre, 'acousticness'),
        instrumentalness: _estimateFromGenre(song.genre, 'instrumentalness'),
      );
    }

    if (_memo.length >= _memoCap) {
      _memo.remove(_memo.keys.first);
    }
    _memo[key] = result;
    return result;
  }

  double _estimateFromGenre(String? genre, String feature) {
    if (genre == null) return 0.5;
    final lowerGenre = genre.toLowerCase();
    VibeFeatures? profile;
    for (final entry in genreProfiles.entries) {
      if (lowerGenre.contains(entry.key)) {
        profile = entry.value;
        break;
      }
    }
    profile ??= genreProfiles['pop']!;

    switch (feature) {
      case 'energy': return profile.energy;
      case 'valence': return profile.valence;
      case 'danceability': return profile.danceability;
      case 'bpm': return profile.bpm;
      case 'acousticness': return profile.acousticness;
      case 'instrumentalness': return profile.instrumentalness;
      default: return 0.5;
    }
  }

  double vibeDistance(VibeFeatures a, VibeFeatures b) {
    double dist = 0;
    dist += (a.energy - b.energy).abs() * 1.0;
    dist += (a.valence - b.valence).abs() * 0.8;
    dist += (a.danceability - b.danceability).abs() * 0.9;
    dist += ((a.bpm - b.bpm).abs() / 140) * 0.7;
    dist += (a.acousticness - b.acousticness).abs() * 0.6;
    return dist / 4.0;
  }

  double vibeSimilarity(VibeFeatures a, VibeFeatures b) {
    return (1.0 - vibeDistance(a, b)).clamp(0.0, 1.0);
  }

  MoodDetection detectMood(VibeFeatures features) {
    final arousal = (features.energy + features.danceability) / 2;
    final dominance = 1.0 - features.acousticness;

    MoodType mood;
    double confidence;

    if (features.energy > 0.7) {
      if (features.valence > 0.7) {
        mood = MoodType.energetic;
        confidence = 0.8 + (features.energy - 0.7) * 0.5;
      } else if (features.valence < 0.4) {
        mood = MoodType.angry;
        confidence = 0.75 + (features.energy - 0.7) * 0.3;
      } else {
        mood = MoodType.dramatic;
        confidence = 0.7;
      }
    } else if (features.energy < 0.4) {
      if (features.valence > 0.7) {
        mood = MoodType.calm;
        confidence = 0.8;
      } else if (features.valence < 0.4) {
        mood = MoodType.sad;
        confidence = 0.75;
      } else {
        mood = MoodType.relaxed;
        confidence = 0.7;
      }
    } else {
      if (features.instrumentalness > 0.7) {
        mood = MoodType.focused;
        confidence = 0.7;
      } else if (features.acousticness > 0.7 && features.valence > 0.5) {
        mood = MoodType.romantic;
        confidence = 0.65;
      } else if (features.valence < 0.4) {
        mood = MoodType.melancholic;
        confidence = 0.65;
      } else if (features.valence > 0.7) {
        mood = MoodType.happy;
        confidence = 0.7;
      } else {
        mood = MoodType.calm;
        confidence = 0.6;
      }
    }

    return MoodDetection(
      mood: mood,
      confidence: confidence.clamp(0.0, 1.0),
      arousal: arousal,
      dominance: dominance,
    );
  }

  List<Map<String, dynamic>> findSimilarTracks({
    required Song target,
    required List<Song> candidates,
    required VibeFeatures targetFeatures,
    int limit = 50,
    double minSimilarity = 0.6,
    Map<String, TrackRating>? ratings,
    Map<String, VibeFeatures>? featuresCache,
  }) {
    final scored = <Map<String, dynamic>>[];

    for (final candidate in candidates) {
      if (candidate.id == target.id) continue;

      final candidateFeatures =
          featuresCache?[candidate.id] ?? analyzeTrack(candidate);
      final sim = vibeSimilarity(targetFeatures, candidateFeatures);

      if (sim >= minSimilarity) {
        scored.add({
          'song': candidate,
          'similarity': sim,
          'features': candidateFeatures,
        });
      }
    }

    scored.sort((a, b) => (b['similarity'] as double).compareTo(a['similarity'] as double));
    return scored.take(limit).toList();
  }

  double moodCompatibilityScore(MoodType from, MoodType to) {
    final fromName = from.name;
    final toName = to.name;
    if (fromName == toName) return 1.0;
    final compatible = moodCompatibility[fromName];
    if (compatible == null) return 0.3;
    return compatible.contains(toName) ? 0.8 : 0.3;
  }

  bool isKeyCompatible(int? key1, String? scale1, int? key2, String? scale2) {
    if (key1 == null || key2 == null) return true;
    if (key1 == key2) return true;
    final diff = (key1 - key2).abs() % 12;
    return diff == 1 || diff == 5 || diff == 7;
  }
}
