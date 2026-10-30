import '../../models/ml/ml_types.dart';
import '../../models/song.dart';

class SonicFingerprintService {
  SonicFingerprint? _fingerprint;
  final List<Map<String, dynamic>> _recentTracks = [];
  static const int maxRecentTracks = 100;

  SonicFingerprint? get fingerprint => _fingerprint;

  Future<SonicFingerprint?> updateFingerprint(String trackId, Map<String, dynamic> features) async {
    _recentTracks.add({
      'trackId': trackId,
      'features': features,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    if (_recentTracks.length > maxRecentTracks) {
      _recentTracks.removeAt(0);
    }

    if (_recentTracks.length < 10) return _fingerprint;

    double totalEnergy = 0, totalDance = 0, totalValence = 0, totalAcoustic = 0, totalBpm = 0;
    final genreCounts = <String, int>{};

    for (final track in _recentTracks) {
      final f = track['features'] as Map<String, dynamic>;
      totalEnergy += (f['energy'] as num?)?.toDouble() ?? 0.5;
      totalDance += (f['danceability'] as num?)?.toDouble() ?? 0.5;
      totalValence += (f['valence'] as num?)?.toDouble() ?? 0.5;
      totalAcoustic += (f['acousticness'] as num?)?.toDouble() ?? 0.5;
      totalBpm += (f['bpm'] as num?)?.toDouble() ?? 120;
      if (f['genre'] != null) {
        genreCounts[f['genre'] as String] = (genreCounts[f['genre'] as String] ?? 0) + 1;
      }
    }

    final count = _recentTracks.length;
    final sortedGenres = genreCounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    _fingerprint = SonicFingerprint(
      avgEnergy: totalEnergy / count,
      avgDanceability: totalDance / count,
      avgValence: totalValence / count,
      avgAcousticness: totalAcoustic / count,
      avgBpm: totalBpm / count,
      topGenres: sortedGenres.take(5).map((e) => e.key).toList(),
      recentTrackIds: _recentTracks.map((t) => t['trackId'] as String).toList(),
      lastUpdated: DateTime.now().toIso8601String(),
    );

    return _fingerprint;
  }

  double scoreAgainstFingerprint(Map<String, dynamic> features) {
    if (_fingerprint == null) return 0.5;

    final energy = (features['energy'] as num?)?.toDouble() ?? 0.5;
    final dance = (features['danceability'] as num?)?.toDouble() ?? 0.5;
    final valence = (features['valence'] as num?)?.toDouble() ?? 0.5;
    final acoustic = (features['acousticness'] as num?)?.toDouble() ?? 0.5;
    final bpm = (features['bpm'] as num?)?.toDouble() ?? 120;

    final similarity = 1.0 - (
      (energy - _fingerprint!.avgEnergy).abs() * 0.3 +
      (dance - _fingerprint!.avgDanceability).abs() * 0.2 +
      (valence - _fingerprint!.avgValence).abs() * 0.2 +
      (acoustic - _fingerprint!.avgAcousticness).abs() * 0.15 +
      ((bpm - _fingerprint!.avgBpm).abs() / 100) * 0.15
    );

    return similarity.clamp(0.0, 1.0);
  }

  List<Song> getFingerprintRecommendations(List<Song> allSongs, int limit) {
    if (_fingerprint == null) return allSongs.take(limit).toList();

    final scored = <Map<String, dynamic>>[];
    for (final song in allSongs) {
      final features = {
        'energy': 0.5,
        'danceability': 0.5,
        'valence': 0.5,
        'acousticness': 0.5,
        'bpm': 120.0,
      };
      final score = scoreAgainstFingerprint(features);
      scored.add({'song': song, 'score': score});
    }

    scored.sort((a, b) => (b['score'] as double).compareTo(a['score'] as double));
    return scored.take(limit).map((s) => s['song'] as Song).toList();
  }
}
