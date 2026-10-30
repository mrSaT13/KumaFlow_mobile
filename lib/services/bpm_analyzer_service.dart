import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import 'cache_settings_service.dart';
import 'ml/audio_features_cache.dart';

class BpmAnalyzerService {
  static final BpmAnalyzerService _instance = BpmAnalyzerService._internal();
  factory BpmAnalyzerService() => _instance;
  BpmAnalyzerService._internal();

  static const String _migratedFlag = 'audio_features_bpm_migrated_v1';

  bool _isInitialized = false;
  SharedPreferences? _prefs;
  final _cacheSettings = CacheSettingsService();
  final _features = AudioFeaturesCache();

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _prefs = await SharedPreferences.getInstance();
      await _cacheSettings.initialize();
      _isInitialized = true;
      // One-time move of legacy bpm_* keys into the audio_features table.
      _migrateLegacyCache();
    } catch (e) {
      debugPrint('Error initializing BPM analyzer: $e');
    }
  }

  Future<void> _migrateLegacyCache() async {
    try {
      if (_prefs?.getBool(_migratedFlag) ?? false) return;
      final legacy = <String, int>{};
      for (final key in _prefs?.getKeys() ?? <String>{}) {
        if (key.startsWith('bpm_')) {
          final v = _prefs?.getInt(key);
          if (v != null) legacy[key.substring(4)] = v;
        }
      }
      if (legacy.isNotEmpty) {
        final n = await _features.migrateLegacyBpm(
          legacy: legacy,
          removeKey: (id) async {
            await _prefs?.remove('bpm_$id');
          },
        );
        debugPrint('[BPM] migrated $n legacy bpm values to audio_features');
      }
      await _prefs?.setBool(_migratedFlag, true);
    } catch (_) {}
  }

  Future<int> getBPM(Song song, String audioUrl) async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_cacheSettings.getBpmCacheEnabled()) {
      try {
        final cached = await _features.getCachedBpm(song.id);
        if (cached != null) return cached.round();
      } catch (_) {}
      // Pre-migration fallback (prefs). Migrated lazily into the table.
      final legacy = _prefs?.getInt('bpm_${song.id}');
      if (legacy != null) {
        try {
          await _features.get(song);
          await _prefs?.remove('bpm_${song.id}');
        } catch (_) {}
        return legacy;
      }
    }

    // Full feature row (computed once, persisted) — bpm comes from it.
    try {
      final f = await _features.get(song);
      return f.bpm.round();
    } catch (_) {
      return _estimateBPMFromGenre(song);
    }
  }

  int _estimateBPMFromGenre(Song song) {
    final genre = song.genre?.toLowerCase() ?? '';

    if (genre.contains('electronic') ||
        genre.contains('edm') ||
        genre.contains('techno') ||
        genre.contains('house')) {
      return 128;
    } else if (genre.contains('hip hop') ||
        genre.contains('rap') ||
        genre.contains('trap')) {
      return 85;
    } else if (genre.contains('rock') || genre.contains('metal')) {
      return 120;
    } else if (genre.contains('jazz') || genre.contains('blues')) {
      return 90;
    } else if (genre.contains('classical') || genre.contains('orchestra')) {
      return 100;
    } else if (genre.contains('reggae') || genre.contains('dub')) {
      return 75;
    } else if (genre.contains('country') || genre.contains('folk')) {
      return 95;
    } else if (genre.contains('disco') || genre.contains('funk')) {
      return 115;
    } else if (genre.contains('pop')) {
      return 110;
    } else if (genre.contains('ballad') || genre.contains('slow')) {
      return 70;
    }

    final duration = song.duration ?? 0;
    if (duration < 120) {
      return 140;
    } else if (duration > 300) {
      return 80;
    }

    return 100;
  }

  Future<void> clearCache() async {
    try {
      await _features.clearDb();
    } catch (_) {}
    _features.clearMemory();
    try {
      final keys = _prefs?.getKeys() ?? <String>{};
      for (final key in keys) {
        if (key.startsWith('bpm_')) {
          await _prefs?.remove(key);
        }
      }
    } catch (_) {}
  }

  Future<void> cacheAllBPM(
    List<Song> songs, {
    Function(int current, int total)? onProgress,
    Function(Song song, int bpm)? onSongCached,
    VoidCallback? onCompleted,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    final total = songs.length;
    for (int i = 0; i < songs.length; i++) {
      final song = songs[i];

      double? cached;
      try {
        cached = await _features.getCachedBpm(song.id);
      } catch (_) {}
      if (cached == null && _cacheSettings.getBpmCacheEnabled()) {
        cached = _prefs?.getInt('bpm_${song.id}')?.toDouble();
      }
      if (cached != null) {
        onProgress?.call(i + 1, total);
        continue;
      }

      int bpm;
      try {
        final f = await _features.get(song);
        bpm = f.bpm.round();
      } catch (_) {
        bpm = _estimateBPMFromGenre(song);
      }

      onProgress?.call(i + 1, total);
      onSongCached?.call(song, bpm);
    }

    onCompleted?.call();
  }

  Future<int> getCachedCount() async {
    var count = 0;
    try {
      count += await _features.count();
    } catch (_) {}
    final keys = _prefs?.getKeys() ?? <String>{};
    count += keys.where((key) => key.startsWith('bpm_')).length;
    return count;
  }

  Future<bool> isCached(String songId) async {
    try {
      final bpm = await _features.getCachedBpm(songId);
      if (bpm != null) return true;
    } catch (_) {}
    return _prefs?.getInt('bpm_$songId') != null;
  }
}
