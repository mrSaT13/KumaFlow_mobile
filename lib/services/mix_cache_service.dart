import 'package:flutter/foundation.dart';
import '../models/song.dart';
import 'library_database_service.dart';

class CachedMixEntry {
  final List<String> songIds;
  final int generatedAt;
  final String cacheKey;

  CachedMixEntry({required this.songIds, required this.generatedAt, required this.cacheKey});

  Map<String, dynamic> toJson() => {'ids': songIds, 'at': generatedAt, 'key': cacheKey};
  factory CachedMixEntry.fromJson(Map<String, dynamic> j) => CachedMixEntry(
        songIds: (j['ids'] as List).cast<String>(),
        generatedAt: j['at'] as int,
        cacheKey: j['key'] as String? ?? '',
      );
}

/// Mix cache backed by SQLite instead of SharedPreferences.
///
/// All data is stored in the mix_cache table via LibraryDatabaseService,
/// avoiding the OOM issues of serializing large JSON blobs in SharedPreferences.
class MixCacheService {
  static const Duration mixesTtl = Duration(hours: 12);
  static const Duration madeForYouTtl = Duration(hours: 6);
  static const Duration myWaveTtl = Duration(hours: 1);
  static const Duration dailyMixTtl = Duration(hours: 24);

  static final MixCacheService _instance = MixCacheService._internal();
  factory MixCacheService() => _instance;
  MixCacheService._internal();

  final _db = LibraryDatabaseService();

  // ── All mixes cache ──────────────────────────────────────────────────

  static const _allMixesKey = 'mix_cache_all_v2';

  Future<Map<String, List<Song>>?> loadAllMixes(String cacheKey, List<Song> pool, {Duration ttl = mixesTtl}) async {
    try {
      final data = await _db.loadMixCache(_allMixesKey);
      if (data == null) return null;
      final savedKey = data['key'] as String? ?? '';
      final at = data['at'] as int? ?? 0;
      if (savedKey != cacheKey) return null;
      if (DateTime.now().millisecondsSinceEpoch - at > ttl.inMilliseconds) return null;
      final mixesJson = data['mixes'] as Map<String, dynamic>? ?? {};
      final poolById = {for (final s in pool) s.id: s};
      final result = <String, List<Song>>{};
      for (final entry in mixesJson.entries) {
        final ids = (entry.value as List).cast<String>();
        final songs = ids.map((id) => poolById[id]).whereType<Song>().toList();
        if (songs.isNotEmpty) result[entry.key] = songs;
      }
      if (result.isEmpty) return null;
      return result;
    } catch (e) {
      debugPrint('[MixCache] load error: $e');
      return null;
    }
  }

  Future<void> saveAllMixes(String cacheKey, Map<String, List<Song>> mixes) async {
    try {
      final data = {
        'key': cacheKey,
        'at': DateTime.now().millisecondsSinceEpoch,
        'mixes': _dedupeMixes(mixes),
      };
      await _db.saveMixCache(_allMixesKey, 'all_mixes', data);
    } catch (e) {
      debugPrint('[MixCache] save error: $e');
    }
  }

  Future<void> invalidate() async {
    await _db.clearMixCache();
  }

  // ── Home cache (mixes + personalized + myWave) ───────────────────────

  static const _homeKey = 'mix_cache_home_v1';

  Future<Map<String, dynamic>?> loadHome(String cacheKey, List<Song> pool, {Duration ttl = myWaveTtl}) async {
    try {
      final data = await _db.loadMixCache(_homeKey);
      if (data == null) return null;
      if (data['key'] != cacheKey) return null;
      if (DateTime.now().millisecondsSinceEpoch - (data['at'] as int) > ttl.inMilliseconds) return null;
      final poolById = {for (final s in pool) s.id: s};
      Map<String, List<Song>> mixes = {};
      if (data['mixes'] != null) {
        final mj = (data['mixes'] as Map).cast<String, dynamic>();
        for (final e in mj.entries) {
          final ids = (e.value as List).cast<String>();
          mixes[e.key] = ids.map((id) => poolById[id]).whereType<Song>().toList();
        }
      }
      List<Song> personalized = [];
      if (data['personalized'] != null) {
        final ids = (data['personalized'] as List).cast<String>();
        personalized = ids.map((id) => poolById[id]).whereType<Song>().toList();
      }
      List<Song> myWave = [];
      if (data['myWave'] != null) {
        final ids = (data['myWave'] as List).cast<String>();
        myWave = ids.map((id) => poolById[id]).whereType<Song>().toList();
      }
      return {'mixes': mixes, 'personalized': personalized, 'myWave': myWave};
    } catch (e) {
      debugPrint('[MixCache] home load error: $e');
      return null;
    }
  }

  // Дедуп по id перед сохранением — защита от дублей в очереди плеера
  List<String> _dedupeIds(List<Song> songs) {
    final seen = <String>{};
    final out = <String>[];
    for (final s in songs) {
      if (seen.add(s.id)) out.add(s.id);
    }
    return out;
  }

  Map<String, List<String>> _dedupeMixes(Map<String, List<Song>> mixes) {
    return {for (final e in mixes.entries) e.key: _dedupeIds(e.value)};
  }

  Future<void> saveHome(String cacheKey, Map<String, List<Song>> mixes, List<Song> personalized, List<Song> myWave) async {
    try {
      final data = {
        'key': cacheKey,
        'at': DateTime.now().millisecondsSinceEpoch,
        'mixes': _dedupeMixes(mixes),
        'personalized': _dedupeIds(personalized),
        'myWave': _dedupeIds(myWave),
      };
      await _db.saveMixCache(_homeKey, 'home', data);
    } catch (e) {
      debugPrint('[MixCache] home save error: $e');
    }
  }

  Future<void> invalidateHome() async {
    try {
      await _db.deleteMixCache(_homeKey);
    } catch (_) {
      await _db.removeKv(_homeKey);
    }
  }

  // ── MadeForYou cache (random 50) ────────────────────────────────────

  static const _madeForYouKey = 'mix_cache_made_for_you';

  Future<List<Song>?> loadMadeForYou(String cacheKey, List<Song> pool, {Duration ttl = madeForYouTtl}) async {
    try {
      final data = await _db.loadMixCache(_madeForYouKey);
      if (data == null) return null;
      if (data['key'] != cacheKey) return null;
      if (DateTime.now().millisecondsSinceEpoch - (data['at'] as int) > ttl.inMilliseconds) return null;
      final ids = (data['ids'] as List).cast<String>();
      final byId = {for (final s in pool) s.id: s};
      final songs = ids.map((id) => byId[id]).whereType<Song>().toList();
      if (songs.isEmpty) return null;
      return songs;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveMadeForYou(String cacheKey, List<Song> songs) async {
    await _db.saveMixCache(_madeForYouKey, 'made_for_you', {
      'key': cacheKey,
      'at': DateTime.now().millisecondsSinceEpoch,
      'ids': _dedupeIds(songs),
    });
  }

  // ── DailyMix cache ───────────────────────────────────────────────────

  static const _dailyMixKey = 'mix_cache_daily_v1';
  static const _dailyRecentKey = 'mix_cache_daily_recent_ids';

  Future<List<Song>?> loadDailyMix(String cacheKey, List<Song> pool, {Duration ttl = dailyMixTtl}) async {
    try {
      final data = await _db.loadMixCache(_dailyMixKey);
      if (data == null) return null;
      if (data['key'] != cacheKey) return null;
      if (DateTime.now().millisecondsSinceEpoch - (data['at'] as int) > ttl.inMilliseconds) return null;
      final ids = (data['ids'] as List).cast<String>();
      final byId = {for (final s in pool) s.id: s};
      final songs = ids.map((id) => byId[id]).whereType<Song>().toList();
      if (songs.isEmpty) return null;
      return songs;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveDailyMix(String cacheKey, List<Song> songs) async {
    final deduped = _dedupeIds(songs);
    await _db.saveMixCache(_dailyMixKey, 'daily_mix', {
      'key': cacheKey,
      'at': DateTime.now().millisecondsSinceEpoch,
      'ids': deduped,
    });
    await addRecentDailyIds(deduped);
  }

  Future<Set<String>> getRecentDailyIds({int max = 50}) async {
    try {
      final raw = await _db.getKv(_dailyRecentKey);
      if (raw == null || raw.isEmpty) return {};
      // Stored as comma-joined: "id1,id2,id3"
      if (raw.contains(',')) {
        final ids = raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        return ids.take(max).toSet();
      }
      // Fallback: legacy JSON-style quoted list
      final ids = (RegExp(r'"([^"]*)"').allMatches(raw)).map((m) => m.group(1)!).toList();
      if (ids.isNotEmpty) return ids.take(max).toSet();
      // Single id without commas/quotes
      return {raw.trim()}.where((e) => e.isNotEmpty).take(max).toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> addRecentDailyIds(List<String> ids) async {
    try {
      final existing = await getRecentDailyIds(max: 100);
      final merged = [...ids, ...existing].toSet().take(100).toList();
      await _db.setKv(_dailyRecentKey, merged.join(','));
    } catch (_) {}
  }

  Future<void> invalidateDaily() async {
    try {
      await _db.deleteMixCache(_dailyMixKey);
    } catch (_) {
      await _db.removeKv(_dailyMixKey);
    }
  }
}
