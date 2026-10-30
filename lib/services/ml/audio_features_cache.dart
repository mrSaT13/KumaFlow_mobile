import '../../models/ml/ml_types.dart';
import '../../models/song.dart';
import '../library_database_service.dart';
import 'vibe_similarity.dart';

/// Offline-first cache for audio features (BPM, energy, valence,
/// danceability, acousticness, instrumentalness).
///
/// Layers:
/// 1. process memory (fastest, session scope),
/// 2. SQLite `audio_features` table (persists across restarts),
/// 3. genre-profile estimate via [VibeSimilarity] (computed once, then stored).
///
/// Vibe similarity therefore never recomputes or hits the network for a
/// warmed track — features come straight from the local DB.
class AudioFeaturesCache {
  static final AudioFeaturesCache _instance = AudioFeaturesCache._internal();
  factory AudioFeaturesCache() => _instance;
  AudioFeaturesCache._internal();

  final LibraryDatabaseService _db = LibraryDatabaseService();
  final VibeSimilarity _vibe = VibeSimilarity();

  final Map<String, VibeFeatures> _memory = {};
  static const int _memoryCap = 5000;

  VibeFeatures _fromRow(Map<String, double> row) => VibeFeatures(
        energy: row['energy'] ?? 0.5,
        valence: row['valence'] ?? 0.5,
        danceability: row['danceability'] ?? 0.5,
        bpm: row['bpm'] ?? 120,
        acousticness: row['acousticness'] ?? 0.5,
        instrumentalness: row['instrumentalness'] ?? 0.0,
      );

  Map<String, double?> _toRow(VibeFeatures f) => {
        'bpm': f.bpm,
        'energy': f.energy,
        'valence': f.valence,
        'danceability': f.danceability,
        'acousticness': f.acousticness,
        'instrumentalness': f.instrumentalness,
      };

  void _remember(String songId, VibeFeatures f) {
    if (_memory.length >= _memoryCap) {
      _memory.remove(_memory.keys.first);
    }
    _memory[songId] = f;
  }

  /// A row counts as cached only when all six features are present
  /// (bpm-only legacy rows are recomputed on demand).
  bool _isComplete(Map<String, double> row) =>
      row.containsKey('bpm') &&
      row.containsKey('energy') &&
      row.containsKey('valence') &&
      row.containsKey('danceability') &&
      row.containsKey('acousticness') &&
      row.containsKey('instrumentalness');

  /// DB-only read (no compute, no persist). Null when not cached.
  Future<VibeFeatures?> getCached(String songId) async {
    final hit = _memory[songId];
    if (hit != null) return hit;
    try {
      final row = await _db.getAudioFeatures(songId);
      if (row == null || !_isComplete(row)) return null;
      final f = _fromRow(row);
      _remember(songId, f);
      return f;
    } catch (_) {
      return null;
    }
  }

  /// Cached BPM or null (used by BPM consumers without triggering compute).
  Future<double?> getCachedBpm(String songId) async {
    final f = await getCached(songId);
    return f?.bpm;
  }

  /// Full features: memory → SQLite → compute + persist.
  Future<VibeFeatures> get(Song song) async {
    final hit = _memory[song.id];
    if (hit != null) return hit;
    try {
      final row = await _db.getAudioFeatures(song.id);
      if (row != null && _isComplete(row)) {
        final f = _fromRow(row);
        _remember(song.id, f);
        return f;
      }
    } catch (_) {}
    final computed = _vibe.analyzeTrack(song);
    _remember(song.id, computed);
    try {
      await _db.saveAudioFeatures(song.id, _toRow(computed));
    } catch (_) {}
    return computed;
  }

  /// Batch version: single SELECT for all ids, missing ones computed and
  /// persisted in one batch write.
  Future<Map<String, VibeFeatures>> getBatch(List<Song> songs) async {
    final out = <String, VibeFeatures>{};
    final missing = <Song>[];
    for (final s in songs) {
      final hit = _memory[s.id];
      if (hit != null) {
        out[s.id] = hit;
      } else {
        missing.add(s);
      }
    }
    if (missing.isNotEmpty) {
      try {
        final rows = await _db.getAudioFeaturesBatch(
          missing.map((s) => s.id).toList(),
        );
        final stillMissing = <Song>[];
        for (final s in missing) {
          final row = rows[s.id];
          if (row != null && _isComplete(row)) {
            final f = _fromRow(row);
            _remember(s.id, f);
            out[s.id] = f;
          } else {
            stillMissing.add(s);
          }
        }
        if (stillMissing.isNotEmpty) {
          final toSave = <String, Map<String, double?>>{};
          for (final s in stillMissing) {
            final f = _vibe.analyzeTrack(s);
            _remember(s.id, f);
            out[s.id] = f;
            toSave[s.id] = _toRow(f);
          }
          await _db.saveAudioFeaturesBatch(toSave);
        }
      } catch (_) {
        for (final s in missing) {
          if (!out.containsKey(s.id)) {
            final f = _vibe.analyzeTrack(s);
            _remember(s.id, f);
            out[s.id] = f;
          }
        }
      }
    }
    return out;
  }

  /// Precompute + persist features for tracks missing from the DB
  /// (called after library sync; subsequent runs only handle new songs).
  Future<void> warmCache(
    List<Song> songs, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (songs.isEmpty) return;
    try {
      final existing = await _db.getAudioFeaturesBatch(
        songs.map((s) => s.id).toList(),
      );
      final toSave = <String, Map<String, double?>>{};
      var done = 0;
      for (final s in songs) {
        final row = existing[s.id];
        if (row != null && _isComplete(row)) {
          _remember(s.id, _fromRow(row));
        } else if (!_memory.containsKey(s.id)) {
          final f = _vibe.analyzeTrack(s);
          _remember(s.id, f);
          toSave[s.id] = _toRow(f);
        }
        done++;
        if (done % 2000 == 0) onProgress?.call(done, songs.length);
      }
      if (toSave.isNotEmpty) {
        await _db.saveAudioFeaturesBatch(toSave);
      }
      onProgress?.call(done, songs.length);
    } catch (_) {}
  }

  /// One-time move of legacy `bpm_<id>` SharedPreferences values into the
  /// table (source `legacy_bpm`). Returns the number of migrated rows.
  /// [readBpm]/[removeBpm] come from the prefs owner (BpmAnalyzerService)
  /// to keep SharedPreferences access in one place.
  Future<int> migrateLegacyBpm({
    required Map<String, int> legacy,
    required Future<void> Function(String key) removeKey,
  }) async {
    if (legacy.isEmpty) return 0;
    try {
      final ids = legacy.keys.toList();
      final existing = await _db.getAudioFeaturesBatch(ids);
      final toSave = <String, Map<String, double?>>{};
      for (final id in ids) {
        if (existing.containsKey(id)) continue;
        toSave[id] = {
          'bpm': legacy[id]!.toDouble(),
          'energy': null,
          'valence': null,
          'danceability': null,
          'acousticness': null,
          'instrumentalness': null,
        };
      }
      if (toSave.isNotEmpty) {
        await _db.saveAudioFeaturesBatch(toSave, source: 'legacy_bpm');
      }
      for (final id in ids) {
        try {
          await removeKey(id);
        } catch (_) {}
      }
      return toSave.length;
    } catch (_) {
      return 0;
    }
  }

  Future<void> prune() => _db.pruneAudioFeatures();

  Future<int> count() => _db.getAudioFeaturesCount();

  Future<void> clearDb() => _db.clearAudioFeatures();

  void clearMemory() => _memory.clear();
}
