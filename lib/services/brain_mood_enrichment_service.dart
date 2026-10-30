import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'kumaflow_brain/kumaflow_brain_client.dart';
import 'library_database_service.dart';

/// Подтяжка настроений с мозга для скачанных треков (сервер → плеер).
///
/// Сервер уже хранит sonic-анализ (`TrackFeatures`: energy/valence/
/// danceability/tempo + mood_labels), а локальная волна в офлайне читает
/// sqflite `audio_features` + `songs.mood`. Этот сервис — труба между ними:
/// берёт `downloadedIds`, дотягивает фичи батчами и кладёт в БД
/// с `source='brain'` (приоритет выше жанровой эвристики `genre`).
///
/// Анти-OOM/ANR (строго):
/// - за один прогон не больше [maxTracks] (дефолт 150), очередь — только
///   недостающие (уже обогащённые помним в prefs, не дёргаем сеть повторно);
/// - сеть — пачками по [_batchSize]=5 с таймаутом 8с на трек, между пачками
///   пауза 200мс (отдаём поток UI, никакого ANR);
/// - в памяти одновременно не больше одной пачки (5 ответов), пишем в БД
///   тоже попачково — потребление O(1), не O(N);
/// - любой чих сети/парсинга = skip трека, прогон продолжается.
class BrainMoodEnrichmentService {
  static final BrainMoodEnrichmentService _instance =
      BrainMoodEnrichmentService._internal();
  factory BrainMoodEnrichmentService() => _instance;
  BrainMoodEnrichmentService._internal();

  static const int _batchSize = 5;
  static const Duration _trackTimeout = Duration(seconds: 8);
  static const Duration _batchPause = Duration(milliseconds: 200);
  static const int _enrichedCap = 5000;

  static const String _kEnrichedKey = 'brain_mood_enriched_v1';
  static const String _kLastRunKey = 'brain_mood_enrich_last_v1';
  static const String _kSkippedKey = 'brain_mood_skipped_v1';
  static const String _kMoodsKey = 'brain_mood_count_v1';

  final LibraryDatabaseService _db = LibraryDatabaseService();

  /// Сколько треков обогащено суммарно (размер кэша id).
  Future<int> enrichedCount() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kEnrichedKey);
      if (raw == null || raw.isEmpty) return 0;
      return (json.decode(raw) as List).length;
    } catch (_) {
      return 0;
    }
  }

  Future<DateTime?> lastRun() async {
    try {
      final p = await SharedPreferences.getInstance();
      final ms = p.getInt(_kLastRunKey);
      if (ms == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  /// Прогон обогащения. Возвращает число треков с настроениями за прогон
  /// (раньше возвращал число с любыми фичами — счётчик врал вверх).
  Future<int> enrichDownloaded({
    required KumaFlowBrainClient client,
    required Set<String> downloadedIds,
    int maxTracks = 150,
    void Function(int done, int total)? onProgress,
  }) async {
    final r = await enrichDownloadedDetailed(
      client: client,
      downloadedIds: downloadedIds,
      maxTracks: maxTracks,
      onProgress: onProgress,
    );
    return r.moods;
  }

  /// Детальный прогон: {enriched (с фичами), moods (с настроением), total}.
  Future<({int enriched, int moods, int total})> enrichDownloadedDetailed({
    required KumaFlowBrainClient client,
    required Set<String> downloadedIds,
    int maxTracks = 150,
    void Function(int done, int total)? onProgress,
  }) async {
    if (downloadedIds.isEmpty) return (enriched: 0, moods: 0, total: 0);
    final prefs = await SharedPreferences.getInstance();

    final already = <String>{};
    try {
      final raw = prefs.getString(_kEnrichedKey);
      if (raw != null && raw.isNotEmpty) {
        already.addAll((json.decode(raw) as List).map((e) => '$e'));
      }
    } catch (_) {}
    // Пропущенные без данных (404/пусто) — не долбим каждый раз, кулдаун 7 дней.
    final skipped = await _loadSkipped();

    // Только недостающие, срез лимитом прогона — сеть и БД под контролем.
    // local_* сразу отбрасываем: мозг знает только серверный каталог.
    final queue = downloadedIds
        .where((id) =>
            !already.contains(id) &&
            !skipped.contains(id) &&
            !id.startsWith('local_'))
        .take(maxTracks)
        .toList();
    if (queue.isEmpty) {
      await prefs.setInt(_kLastRunKey, DateTime.now().millisecondsSinceEpoch);
      return (enriched: 0, moods: 0, total: 0);
    }

    var done = 0;
    var enriched = 0;
    var moods = 0;
    for (var i = 0; i < queue.length; i += _batchSize) {
      final end =
          (i + _batchSize < queue.length) ? i + _batchSize : queue.length;
      final batch = queue.sublist(i, end);
      try {
        final got = await _enrichBatch(client, batch);
        enriched += got.enriched;
        moods += got.moods;
      } catch (_) {}
      done = end;
      try {
        onProgress?.call(done, queue.length);
      } catch (_) {}
      // Отдаём поток UI/сети между пачками — никакого ANR и просадок.
      await Future<void>.delayed(_batchPause);
    }

    try {
      await prefs.setInt(_kLastRunKey, DateTime.now().millisecondsSinceEpoch);
      final p = await SharedPreferences.getInstance();
      await p.setInt(_kMoodsKey, (await moodsInDb()) );
    } catch (_) {}
    return (enriched: enriched, moods: moods, total: queue.length);
  }

  /// Сколько песен реально имеют настроение в БД (честный счётчик для UI).
  Future<int> moodsInDb() async {
    try {
      return await _db.countSongsWithMood();
    } catch (_) {
      return 0;
    }
  }

  Future<Set<String>> _loadSkipped() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kSkippedKey);
      if (raw == null || raw.isEmpty) return <String>{};
      final m = json.decode(raw) as Map;
      final now = DateTime.now().millisecondsSinceEpoch;
      final out = <String>{};
      m.forEach((k, v) {
        try {
          final ts = (v as num).toInt();
          if (now - ts < 7 * 24 * 3600 * 1000) out.add('$k');
        } catch (_) {}
      });
      return out;
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> _markSkipped(List<String> ids) async {
    if (ids.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      Map<String, int> m = {};
      try {
        final raw = p.getString(_kSkippedKey);
        if (raw != null && raw.isNotEmpty) {
          (json.decode(raw) as Map).forEach((k, v) {
            try { m['$k'] = (v as num).toInt(); } catch (_) {}
          });
        }
      } catch (_) {}
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final id in ids) {
        m[id] = now;
      }
      // Тримминг чтобы не рос бесконечно.
      if (m.length > _enrichedCap) {
        final keys = m.keys.toList()..sort((a, b) => m[a]!.compareTo(m[b]!));
        for (final k in keys.take(m.length - _enrichedCap)) {
          m.remove(k);
        }
      }
      await p.setString(_kSkippedKey, json.encode(m));
    } catch (_) {}
  }

  /// Одна пачка: сеть → парс → запись в БД.
  /// Возвращает (enriched с фичами, moods с настроением).
  /// Пустые (null) уходят в skipped-кулдаун чтобы не гонять их каждый прогон.
  Future<({int enriched, int moods})> _enrichBatch(
      KumaFlowBrainClient client, List<String> batch) async {
    final results = await Future.wait(
      batch.map((id) => _fetchOne(client, id)),
      eagerError: false,
    );
    final features = <String, Map<String, double?>>{};
    final moods = <String, String?>{};
    final okIds = <String>[];
    final failIds = <String>[];
    for (var i = 0; i < batch.length; i++) {
      final r = results[i];
      if (r == null) {
        failIds.add(batch[i]);
        continue;
      }
      okIds.add(batch[i]);
      if (r.features.isNotEmpty) features[batch[i]] = r.features;
      if (r.mood != null && r.mood!.isNotEmpty) moods[batch[i]] = r.mood;
    }
    // Пишем попачково малыми транзакциями — память O(пачка).
    try {
      if (features.isNotEmpty) {
        await _db.saveAudioFeaturesBatch(features, source: 'brain');
      }
    } catch (_) {
      okIds.clear();
    }
    try {
      if (moods.isNotEmpty && okIds.isNotEmpty) {
        await _db.updateSongMoodBatch(moods);
      }
    } catch (_) {}
    if (okIds.isNotEmpty) {
      await _markEnriched(okIds);
    }
    if (failIds.isNotEmpty) {
      await _markSkipped(failIds);
    }
    return (enriched: okIds.length, moods: moods.length);
  }

  Future<void> _markEnriched(List<String> ids) async {
    if (ids.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      final list = <String>[];
      try {
        final raw = p.getString(_kEnrichedKey);
        if (raw != null && raw.isNotEmpty) {
          list.addAll((json.decode(raw) as List).map((e) => '$e'));
        }
      } catch (_) {}
      final set = list.toSet()..addAll(ids);
      // FIFO-тримминг: кэш не растёт бесконечно.
      final trimmed = set.length > _enrichedCap
          ? set.skip(set.length - _enrichedCap).toList()
          : set.toList();
      await p.setString(_kEnrichedKey, json.encode(trimmed));
    } catch (_) {}
  }

  Future<_BrainTrackMood?> _fetchOne(
      KumaFlowBrainClient client, String externalId) async {
    try {
      final d = await client.getTrack(externalId).timeout(_trackTimeout);
      if (d.isEmpty) return null;
      // Это точно наш трек? Если сервер вернул external_id и он чужой — skip.
      try {
        final ext = (d['external_id'] ?? '').toString();
        if (ext.isNotEmpty && ext != externalId) return null;
      } catch (_) {}
      final features = _parseFeatures(d);
      final mood = _parseMood(d);
      if (features.isEmpty && (mood == null || mood.isEmpty)) return null;
      return _BrainTrackMood(features: features, mood: mood);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _nestedFeat(Map<String, dynamic> d) {
    // Сервер кладёт анализ в разные гнёзда — ищем первое непустое.
    for (final k in ['features', 'audio_features', 'analysis', 'sonic', 'enrichment']) {
      try {
        final v = d[k];
        if (v is Map && v.isNotEmpty) return Map<String, dynamic>.from(v);
      } catch (_) {}
    }
    return d;
  }

  Map<String, double?> _parseFeatures(Map<String, dynamic> d) {
    Map<String, dynamic>? feat;
    try {
      final f = d['features'];
      if (f is Map) feat = Map<String, dynamic>.from(f);
    } catch (_) {}
    feat ??= _nestedFeat(d);
    double? num_(String k) {
      try {
        final v = feat![k];
        if (v is num) return v.toDouble();
        return double.tryParse('$v');
      } catch (_) {
        return null;
      }
    }

    double? clamp01(double? v) => v?.clamp(0.0, 1.0).toDouble();
    double? bpm = num_('tempo_bpm') ?? num_('bpm') ?? num_('tempo');
    if (bpm != null) bpm = bpm.clamp(40.0, 250.0).toDouble();
    final out = <String, double?>{
      'bpm': bpm,
      'energy': clamp01(num_('energy')),
      'valence': clamp01(num_('valence')),
      'danceability': clamp01(num_('danceability')),
      'acousticness': clamp01(num_('acousticness')),
      'instrumentalness': clamp01(num_('instrumentalness')),
    };
    // Пустой ответ (ни одного числа) — не считаем фичами.
    if (out.values.every((v) => v == null)) return const {};
    return out;
  }

  String? _parseMood(Map<String, dynamic> d) {
    final feat = _nestedFeat(d);
    dynamic pick(String k) {
      if (d.containsKey(k) && d[k] != null) return d[k];
      if (feat.containsKey(k) && feat[k] != null) return feat[k];
      return null;
    }

    // 1) списки строк под разными именами.
    for (final key in ['mood_labels', 'moods', 'labels', 'predicted_moods']) {
      try {
        final v = pick(key);
        if (v is List) {
          for (final item in v) {
            final clean = '$item'.trim().toLowerCase();
            if (clean.isNotEmpty && clean != 'null') return clean;
          }
        } else if (v is String && v.trim().isNotEmpty) {
          return v.trim().toLowerCase();
        }
      } catch (_) {}
    }
    // 2) dict {label: weight} — mood_vector / mood_scores / emotions.
    for (final key in ['mood_vector', 'mood_scores', 'emotions']) {
      try {
        final mv = pick(key);
        if (mv is Map && mv.isNotEmpty) {
          String? top;
          double best = -1;
          for (final e in mv.entries) {
            final w = e.value is num
                ? (e.value as num).toDouble()
                : double.tryParse('${e.value}') ?? -1;
            if (w > best) {
              best = w;
              top = '${e.key}'.trim().toLowerCase();
            }
          }
          if (top != null && top.isNotEmpty) return top;
        }
      } catch (_) {}
    }
    // 3) одиночные строки под разными именами.
    for (final key in ['mood', 'predicted_mood', 'top_mood', 'primary_mood', 'dominant_mood']) {
      try {
        final m = '${pick(key) ?? ''}'.trim().toLowerCase();
        if (m.isNotEmpty && m != 'null') return m;
      } catch (_) {}
    }
    return null;
  }
}

class _BrainTrackMood {
  final Map<String, double?> features;
  final String? mood;
  const _BrainTrackMood({required this.features, this.mood});
}
