import 'package:flutter/foundation.dart';
import '../models/song.dart';
import 'mix_cache_service.dart';
import 'recommendation_service.dart';

/// Единая точка загрузки грида ML-миксов для Home и Mixes.
///
/// Раньше оба экрана считали `generateMixesIsolated` каждый своим пулом
/// и ключом: открыл Home (изолят 1), открыл Миксы (изолят 2) — двойной
/// скоринг одного и того же каталога. Теперь:
/// - один канонический ключ (пул + баны) и один пул-источник;
/// - single-flight: параллельные запросы с тем же ключом ждут один Future;
/// - память (TTL) + диск (MixCacheService) перед изолятом.
class SharedMixesLoader {
  static final SharedMixesLoader _instance = SharedMixesLoader._internal();
  factory SharedMixesLoader() => _instance;
  SharedMixesLoader._internal();

  static const Duration memTtl = Duration(hours: 12);

  final Map<String, _MemEntry> _mem = {};
  final Map<String, Future<Map<String, List<Song>>>> _inflight = {};

  /// Канонический ключ: размер + хэш id пула + ключ банов.
  static String cacheKeyFor(List<Song> pool, String bannedKey) {
    var h = pool.length;
    for (final s in pool) {
      h = (h * 31 + s.id.hashCode) & 0x7fffffff;
    }
    return '${pool.length}_${h}_$bannedKey';
  }

  Future<Map<String, List<Song>>> getAllMixes({
    required List<Song> pool,
    required String bannedKey,
    required RecommendationService rec,
    bool force = false,
  }) {
    final key = cacheKeyFor(pool, bannedKey);
    if (!force) {
      final mem = _mem[key];
      if (mem != null &&
          DateTime.now().millisecondsSinceEpoch - mem.at <
              memTtl.inMilliseconds &&
          mem.mixes.isNotEmpty) {
        return Future.value(mem.mixes);
      }
    } else {
      _mem.remove(key);
    }
    final running = _inflight[key];
    if (running != null && !force) return running;

    final fut = _loadOrCompute(key: key, pool: pool, rec: rec, force: force);
    if (!force) _inflight[key] = fut;
    return fut.whenComplete(() => _inflight.remove(key));
  }

  Future<Map<String, List<Song>>> _loadOrCompute({
    required String key,
    required List<Song> pool,
    required RecommendationService rec,
    required bool force,
  }) async {
    if (pool.isEmpty) return const {};
    if (!force) {
      try {
        final cached = await MixCacheService().loadAllMixes(key, pool);
        if (cached != null && cached.isNotEmpty) {
          _mem[key] = _MemEntry(
              at: DateTime.now().millisecondsSinceEpoch, mixes: cached);
          return cached;
        }
      } catch (_) {}
    }
    // generateMixesIsolated сам падает в синхронный generateMixes на
    // маленьких пулах (<400) — ветвление снаружи не нужно.
    Map<String, List<Song>> mixes = const {};
    try {
      mixes = await rec.generateMixesIsolated(pool);
    } catch (e) {
      debugPrint('[SharedMixes] compute failed: $e');
      final mem = _mem[key];
      if (mem != null && mem.mixes.isNotEmpty) return mem.mixes;
      return const {};
    }
    if (mixes.isNotEmpty) {
      _mem[key] =
          _MemEntry(at: DateTime.now().millisecondsSinceEpoch, mixes: mixes);
      try {
        await MixCacheService().saveAllMixes(key, mixes);
      } catch (_) {}
    }
    return mixes;
  }

  /// Сброс для pull-to-refresh: память + диск.
  Future<void> invalidate() async {
    _mem.clear();
    try {
      await MixCacheService().invalidate();
    } catch (_) {}
  }
}

class _MemEntry {
  final int at;
  final Map<String, List<Song>> mixes;
  _MemEntry({required this.at, required this.mixes});
}
