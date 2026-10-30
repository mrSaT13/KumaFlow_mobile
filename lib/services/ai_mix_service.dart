import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import 'ai_service.dart';
import 'subsonic_service.dart';
import 'ml_service.dart';
import 'recommendation_service.dart';
import 'library_database_service.dart';
import 'ml/vibe_similarity.dart';

/// Результат AI микса
class AiMixResult {
  final String name;
  final String comment;
  final List<Song> songs;
  final List<String> songIds;
  final String rawResponse;
  final bool fromFallback;

  AiMixResult({
    required this.name,
    required this.comment,
    required this.songs,
    required this.songIds,
    this.rawResponse = '',
    this.fromFallback = false,
  });
}

class AiMixService {
  static final AiMixService _instance = AiMixService._internal();
  factory AiMixService() => _instance;
  AiMixService._internal();

  static const _kDailyDate = 'ai_daily_last_date';
  static const _kDailyName = 'ai_daily_last_name';
  static const _kDailyIds = 'ai_daily_last_ids';
  // Серверный id сохранённого daily-микса: сохранённые живут в плейлистах
  // и не затираются регенерацией — новый остаётся временным до «Сохранить».
  static const _kDailySavedId = 'ai_daily_saved_playlist_id';

  final _random = Random();

  /// Проверяет нужен ли ежедневный микс (раз в сутки)
  Future<bool> shouldGenerateDaily() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString(_kDailyDate);
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (last == today) return false;
    return true;
  }

  Future<void> markDailyDone(String name, List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    await prefs.setString(_kDailyDate, today);
    await prefs.setString(_kDailyName, name);
    await prefs.setStringList(_kDailyIds, ids);
  }

  Future<Map<String, dynamic>?> getLastDailyInfo() async {
    final prefs = await SharedPreferences.getInstance();
    final date = prefs.getString(_kDailyDate);
    final name = prefs.getString(_kDailyName);
    final ids = prefs.getStringList(_kDailyIds);
    if (date == null || name == null || ids == null) return null;
    return {'date': date, 'name': name, 'ids': ids};
  }

  Future<void> resetDaily() async {
    final prefs = await SharedPreferences.getInstance();
    // Было: удалялась только дата — getLastDailyInfo() продолжал отдавать
    // вчерашние название/треки. Чистим всё.
    await prefs.remove(_kDailyDate);
    await prefs.remove(_kDailyName);
    await prefs.remove(_kDailyIds);
  }

  /// Серверный id сохранённого daily (null = временный, замена стирает).
  Future<String?> getDailySavedPlaylistId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_kDailySavedId);
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null;
    }
  }

  Future<void> setDailySavedPlaylistId(String? id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (id == null || id.isEmpty) {
        await prefs.remove(_kDailySavedId);
      } else {
        await prefs.setString(_kDailySavedId, id);
      }
    } catch (_) {}
  }

  /// Основной метод: prompt -> подборка
  Future<AiMixResult> generateFromPrompt({
    required String userQuery,
    required List<Song> library,
    int desiredCount = 30,
    String? hintMood,
  }) async {
    if (library.isEmpty) throw Exception('Библиотека пуста');
    final query = userQuery.trim();
    if (query.isEmpty) throw Exception('Пустой запрос');

    // 1. Кандидаты локально
    final candidates = _buildCandidates(query, library, desiredCount * 10);
    final pool = candidates.isEmpty ? (library..shuffle(_random)).take(desiredCount * 10).toList() : candidates;
    final limitedForLlm = pool.take(280).toList(); // чтобы не превысить контекст

    // 2. Попытка LLM
    try {
      final ai = AiService();
      await ai.initialize();
      if (!ai.isConfigured) {
        final reason = ai.unconfiguredReason;
        debugPrint('[AiMix] AI not configured: $reason');
        return _fallbackResult(query, pool, desiredCount, reason: reason);
      }
      final llmResult = await _callLlm(query, limitedForLlm, desiredCount);
      if (llmResult.songs.isNotEmpty) {
        return llmResult;
      }
      return _fallbackResult(query, pool, desiredCount, raw: llmResult.rawResponse);
    } catch (e) {
      debugPrint('[AiMix] LLM failed: $e');
      final reason = e.toString().length > 180 ? '${e.toString().substring(0,180)}...' : e.toString();
      return _fallbackResult(query, pool, desiredCount, reason: reason);
    }
  }

  /// Ежедневный автоматический микс — без запроса, на основе вкусов
  Future<AiMixResult?> generateDailyAutoMix({
    required List<Song> library,
    bool force = false,
  }) async {
    if (!force && !(await shouldGenerateDaily())) return null;
    if (library.isEmpty) return null;

    final ai = AiService();
    await ai.initialize();
    final hasAi = ai.isConfigured;

    // Формируем промпт дня
    final ml = MLService();
    final rec = RecommendationService();
    // попытаться взять топ жанры/артисты
    String tasteHint = '';
    try {
      final topGenres = ml.getTopGenres(limit: 3);
      final topArtists = ml.getTopArtists(limit: 3);
      if (topGenres.isNotEmpty) tasteHint += 'Любимые жанры: ${topGenres.join(', ')}. ';
      if (topArtists.isNotEmpty) tasteHint += 'Любимые артисты по ID: ${topArtists.join(', ')}. ';
    } catch (_) {}
    final dayNames = ['понедельник','вторник','среда','четверг','пятница','суббота','воскресенье'];
    final now = DateTime.now();
    final dayName = dayNames[now.weekday - 1];
    final hour = now.hour;
    String timeHint = '';
    if (hour < 12) timeHint = 'утро — лёгкая энергия';
    else if (hour < 18) timeHint = 'день — энергично';
    else if (hour < 22) timeHint = 'вечер — расслабленно';
    else timeHint = 'ночь — спокойно';

    final dailyPrompt = 'Ежедневный микс на $dayName, $timeHint. $tasteHint'
        'Сделай разнообразную подборку: 70% знакомое, 30% открытия. '
        'Настроение — сбалансированное для сегодня.';

    // Кандидаты: используем rec personalized feed как базу разнообразия
    List<Song> pool;
    try {
      if (rec.enabled) {
        pool = rec.getPersonalizedFeed(library, limit: 400);
        if (pool.isEmpty) pool = library;
      } else {
        pool = library;
      }
    } catch (_) {
      pool = library;
    }

    final candidates = pool.take(300).toList();
    if (candidates.isEmpty) return null;

    if (hasAi) {
      try {
        final res = await _callLlm(dailyPrompt, candidates.take(260).toList(), 30, isDaily: true);
        if (res.songs.isNotEmpty) {
          await markDailyDone(res.name, res.songIds);
          return res;
        }
      } catch (e) {
        debugPrint('[AiMix] daily LLM failed: $e');
      }
    }
    // fallback daily
    final fallback = _fallbackResult(dailyPrompt, candidates, 30, dailyPrefix: 'День ${now.day}.${now.month}');
    await markDailyDone(fallback.name, fallback.songIds);
    return fallback;
  }

  // ───────────────────────────────────────────────
  List<Song> _buildCandidates(String query, List<Song> library, int limit) {
    final qLower = query.toLowerCase();
    final qTokens = qLower.split(RegExp(r'[\s,]+')).where((t) => t.length > 2).toList();
    final moodTarget = _detectMoodFromQuery(qLower);

    // Score each song
    final vibe = VibeSimilarity();
    final ml = MLService();
    final scored = <MapEntry<Song, double>>[];

    for (final s in library) {
      double score = 0;

      // 1. Text match
      final hay = '${s.title} ${s.artist ?? ''} ${s.album ?? ''} ${s.genre ?? ''}'.toLowerCase();
      for (final tok in qTokens) {
        if (hay.contains(tok)) score += 3;
      }
      if (qTokens.isNotEmpty && hay.contains(qLower)) score += 5;

      // 2. Genre exact
      if (s.genre != null && qLower.contains(s.genre!.toLowerCase())) score += 4;

      // 3. Mood vibe match
      if (moodTarget != null) {
        try {
          final f = vibe.analyzeTrack(s);
          final mood = vibe.detectMood(f);
          if (mood.mood.name.toLowerCase() == moodTarget) score += 2.5;
          // bonus for energy/valence proximity to mood target
          final targetEnergy = _moodEnergy(moodTarget);
          if (targetEnergy != null) {
            score += (1 - (f.energy - targetEnergy).abs()) * 1.2;
          }
        } catch (_) {}
      }

      // 4. ML preference boost
      try {
        score += ml.calculateTrackScore(s.id) * 0.02;
      } catch (_) {}

      // 5. Small random to diversify
      score += _random.nextDouble() * 0.8;

      if (score > 0.5) scored.add(MapEntry(s, score));
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    // Top limit, but ensure diversity by artist
    final seenArtists = <String>{};
    final diverse = <Song>[];
    for (final e in scored) {
      final art = e.key.artist?.toLowerCase() ?? e.key.id;
      if (seenArtists.length < limit * 0.6) {
        if (seenArtists.add(art)) diverse.add(e.key);
        else if (diverse.length < limit && _random.nextDouble() < 0.3) diverse.add(e.key);
      } else {
        diverse.add(e.key);
      }
      if (diverse.length >= limit) break;
    }
    if (diverse.length < limit) {
      // дополнить топом
      for (final e in scored) {
        if (!diverse.contains(e.key)) {
          diverse.add(e.key);
          if (diverse.length >= limit) break;
        }
      }
    }
    // если всё ещё мало — просто рандом из библиотеки
    if (diverse.length < 40) {
      final extra = library.where((s) => !diverse.contains(s)).toList()..shuffle(_random);
      diverse.addAll(extra.take(limit - diverse.length));
    }
    return diverse.take(limit).toList();
  }

  String? _detectMoodFromQuery(String q) {
    if (q.contains('груст') || q.contains('sad') || q.contains('меланхол') || q.contains('печаль') || q.contains('тоск')) return 'sad';
    if (q.contains('весел') || q.contains('радост') || q.contains('happy') || q.contains('позитив')) return 'happy';
    if (q.contains('энерг') || q.contains('энергия') || q.contains('бег') || q.contains('спорт') || q.contains('тренир') || q.contains('workout') || q.contains('running')) return 'energetic';
    if (q.contains('спокой') || q.contains('calm') || q.contains('медитац') || q.contains('сон') || q.contains('sleep') || q.contains('relax')) return 'calm';
    if (q.contains('агресс') || q.contains('зл') || q.contains('aggressive') || q.contains('metal')) return 'aggressive';
    if (q.contains('мрач') || q.contains('melancholic')) return 'melancholic';
    if (q.contains('вечерин') || q.contains('party') || q.contains('танц') || q.contains('dance')) return 'energetic';
    if (q.contains('романт') || q.contains('любов') || q.contains('love')) return 'happy';
    if (q.contains('фокус') || q.contains('работ') || q.contains('focus')) return 'calm';
    return null;
  }

  double? _moodEnergy(String mood) {
    switch (mood) {
      case 'energetic': return 0.8;
      case 'aggressive': return 0.9;
      case 'happy': return 0.65;
      case 'calm': return 0.3;
      case 'sad': return 0.35;
      case 'melancholic': return 0.25;
      default: return null;
    }
  }

  Future<AiMixResult> _callLlm(String userQuery, List<Song> candidates, int desiredCount, {bool isDaily = false}) async {
    final ai = AiService();

    final cat = candidates.asMap().entries.map((e) {
      final idx = e.key + 1;
      final s = e.value;
      final genre = s.genre ?? 'unknown';
      final dur = s.duration != null ? '${(s.duration! / 60).floor()}:${(s.duration! % 60).toString().padLeft(2, '0')}' : '';
      return '$idx. [${s.id}] "${s.title}" — ${s.artist ?? "Unknown"} | $genre | $dur';
    }).join('\n');

    final sysPrompt = isDaily
        ? 'Ты — музыкальный куратор KumaFlow. Твоя задача — собрать ежедневный микс.'
        : 'Ты — музыкальный куратор KumaFlow. Пользователь попросил подборку.';

    final prompt = '''$sysPrompt

Запрос пользователя: "$userQuery"
Желаемое количество треков: $desiredCount

Кандидаты (выбери ТОЛЬКО из этого списка, не выдумывай ID):
$cat

Верни СТРОГО JSON без markdown:
{
  "name": "Короткое креативное название плейлиста 2-4 слова на русском",
  "comment": "1-2 предложения описания, почему эти треки подходят под запрос (на русском)",
  "ids": ["id1", "id2", ... ровно $desiredCount или близко, только ID из списка]
}

Правила:
- ids только из кандидатов, без повторов
- Разнообразие артистов (не более 2 треков одного артиста подряд)
- Учитывай жанр и настроение запроса
- Ответ только JSON, без пояснений до/после''';

    final raw = await ai.generateText(prompt, maxTokens: 1200, temperature: 0.7, timeout: const Duration(seconds: 35));

    final parsed = _parseLlmJson(raw, candidates);
    if (parsed != null) return parsed;

    // fallback: try to extract ids via regex
    final fallbackIds = _extractIdsFromText(raw, candidates, desiredCount);
    if (fallbackIds.isNotEmpty) {
      final byId = {for (final s in candidates) s.id: s};
      final songs = <Song>[];
      final goodIds = <String>[];
      for (final id in fallbackIds) {
        final song = byId[id];
        if (song != null) {
          songs.add(song);
          goodIds.add(id);
        } else {
          debugPrint('[AiMix] skip unknown id from LLM: $id');
        }
      }
      if (songs.isEmpty) throw Exception('LLM parse failed: no valid ids');
      final name = _generateFallbackName(userQuery, songs);
      final comment = 'Подборка от ИИ по запросу "$userQuery" • ${songs.length} треков';
      return AiMixResult(name: name, comment: comment, songs: songs, songIds: goodIds, rawResponse: raw);
    }
    throw Exception('LLM parse failed');
  }

  AiMixResult? _parseLlmJson(String raw, List<Song> candidates) {
    try {
      String jsonStr = raw.trim();
      // strip markdown fences
      if (jsonStr.contains('```')) {
        final m = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(jsonStr);
        if (m != null) jsonStr = m.group(1)!.trim();
      }
      // find first { ... } block
      final start = jsonStr.indexOf('{');
      final end = jsonStr.lastIndexOf('}');
      if (start != -1 && end != -1) jsonStr = jsonStr.substring(start, end + 1);

      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final name = (data['name'] as String?)?.trim() ?? '';
      final comment = (data['comment'] as String?)?.trim() ?? '';
      final idsRaw = data['ids'] as List?;
      if (idsRaw == null) return null;
      final ids = idsRaw.map((e) => e.toString().trim()).where((id) => id.isNotEmpty).toList();
      final idSet = candidates.map((s) => s.id).toSet();
      final validIds = ids.where((id) => idSet.contains(id)).toList();
      if (validIds.length < 5) return null;
      final byId = {for (final s in candidates) s.id: s};
      final songs = <Song>[];
      for (final id in validIds) {
        final song = byId[id];
        if (song != null) songs.add(song);
      }
      if (songs.length < 5) return null;
      final safeName = name.isEmpty ? _generateFallbackName('AI Mix', songs) : (name.length > 40 ? name.substring(0, 40) : name);
      final safeComment = comment.isEmpty ? 'Подборка от ИИ • ${songs.length} треков' : comment;
      return AiMixResult(name: safeName, comment: safeComment, songs: songs, songIds: validIds, rawResponse: raw);
    } catch (e) {
      debugPrint('[AiMix] json parse error: $e raw=${raw.substring(0, raw.length.clamp(0, 200))}');
      return null;
    }
  }

  List<String> _extractIdsFromText(String raw, List<Song> candidates, int limit) {
    final idSet = candidates.map((s) => s.id).toSet();
    final found = <String>[];
    final seen = <String>{};
    // find quoted ids
    final reg = RegExp(r'"([^"]+)"|\b([a-zA-Z0-9\-_]{6,})\b');
    for (final m in reg.allMatches(raw)) {
      final cand = (m.group(1) ?? m.group(2) ?? '').trim();
      if (idSet.contains(cand) && seen.add(cand)) found.add(cand);
      if (found.length >= limit) break;
    }
    return found;
  }

  String _generateFallbackName(String query, List<Song> songs) {
    if (songs.isEmpty) return query.isEmpty ? 'AI Mix' : query;
    final q = query.trim();
    if (q.length <= 20 && q.isNotEmpty) {
      final cap = q[0].toUpperCase() + q.substring(1);
      return cap.contains('Mix') ? cap : '$cap — AI Mix';
    }
    final genre = songs.first.genre;
    if (genre != null && genre.isNotEmpty) return '${genre[0].toUpperCase()}${genre.substring(1)} — AI Mix';
    return 'AI Mix • ${songs.length} треков';
  }

  AiMixResult _fallbackResult(String query, List<Song> pool, int count, {String raw = '', String? dailyPrefix, String? reason}) {
    final vibe = VibeSimilarity();
    final mood = _detectMoodFromQuery(query.toLowerCase());
    List<Song> sorted = pool;
    if (mood != null) {
      try {
        final targetEnergy = _moodEnergy(mood);
        sorted = List<Song>.from(pool)..sort((a, b) {
          double scoreA = 0, scoreB = 0;
          try {
            final fa = vibe.analyzeTrack(a);
            final fb = vibe.analyzeTrack(b);
            if (targetEnergy != null) {
              scoreA -= (fa.energy - targetEnergy).abs();
              scoreB -= (fb.energy - targetEnergy).abs();
            }
            if (vibe.detectMood(fa).mood.name.toLowerCase() == mood) scoreA += 1;
            if (vibe.detectMood(fb).mood.name.toLowerCase() == mood) scoreB += 1;
          } catch (_) {}
          return scoreB.compareTo(scoreA);
        });
      } catch (_) {}
    }
    // diverse pick
    final seen = <String>{};
    final result = <Song>[];
    for (final s in sorted) {
      final art = s.artist?.toLowerCase() ?? s.id;
      if (seen.add(art) || result.length >= count * 1.2) {
        result.add(s);
        if (result.length >= count) break;
      }
    }
    if (result.length < count) {
      for (final s in sorted) {
        if (!result.contains(s)) {
          result.add(s);
          if (result.length >= count) break;
        }
      }
    }
    final trimmed = result.take(count).toList();
    final name = dailyPrefix != null ? 'Ежедневный микс для $dailyPrefix' : _generateFallbackName(query, trimmed);
    String baseComment;
    if (reason != null && reason.isNotEmpty) {
      baseComment = 'ИИ недоступен: $reason. Показан локальный набор из ${trimmed.length} треков, подобран по жанру/настроению (vibe) схоже с запросом "$query". Включи ИИ в Настройки → ИИ или проверь интернет/токен.';
    } else if (mood != null) {
      baseComment = 'Плейлист "$query" — ${mood} подборка, ${trimmed.length} треков. Локальная генерация без ИИ.';
    } else {
      baseComment = 'Плейлист для запроса "$query" из ${trimmed.length} треков. Это локальная генерация без ИИ — алгоритмы подобрали схожие по настроению/жанру.';
    }
    return AiMixResult(name: name, comment: baseComment, songs: trimmed, songIds: trimmed.map((s) => s.id).toList(), rawResponse: raw, fromFallback: true);
  }

  /// Создаёт плейлист на сервере и возвращает ID (если сервер отдал)
  Future<String?> createServerPlaylist({
    required SubsonicService subsonic,
    required AiMixResult result,
  }) async {
    try {
      await subsonic.createPlaylist(name: result.name, comment: result.comment, songIds: result.songIds);
      // try to find created playlist by name (Navidrome returns via getPlaylists)
      await Future.delayed(const Duration(milliseconds: 600));
      final pls = await subsonic.getPlaylists();
      final match = pls.where((p) => p.name == result.name).toList();
      if (match.isNotEmpty) {
        match.sort((a, b) => (b.changed ?? b.created ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(a.changed ?? a.created ?? DateTime.fromMillisecondsSinceEpoch(0)));
        final createdId = match.first.id;
        // Navidrome игнорирует comment в createPlaylist — дожимаем через
        // updatePlaylist, иначе страница плейлиста открывается без описания.
        if (result.comment.trim().isNotEmpty) {
          try {
            await subsonic.updatePlaylist(playlistId: createdId, comment: result.comment.trim());
          } catch (e) {
            debugPrint('[AiMix] update comment failed: $e');
          }
        }
        return createdId;
      }
      return null;
    } catch (e) {
      debugPrint('[AiMix] create playlist failed: $e');
      rethrow;
    }
  }
}
