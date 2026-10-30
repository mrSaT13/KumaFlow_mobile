import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../models/lyrics.dart';
import '../models/ml/ml_types.dart';
import 'ai_service.dart';
import 'bpm_analyzer_service.dart';
import 'lyrics_service.dart';
import 'ml/vibe_similarity.dart';

/// Комбинированный детектор настроения KumaFlow.
/// Текст (лирика) + Аудио (BPM/жанр/энергия) — усиленный вариант vibe_similarity.
/// Оффлайн-лексикон RU+EN, кэш, опц. уточнение через AiService.
class LyricsMoodService {
  static final LyricsMoodService _instance = LyricsMoodService._internal();
  factory LyricsMoodService() => _instance;
  LyricsMoodService._internal();

  final _vibe = VibeSimilarity();
  final _bpmService = BpmAnalyzerService();
  final _lyricsService = LyricsService();
  final Map<String, _CachedMood> _memoryCache = {};

  static const _cachePrefix = 'lyric_mood_';
  static const _cacheExpiry = Duration(hours: 72);

  // ---- Оффлайн лексиконы RU/EN ----
  static const _happyWords = <String>{
    'счаст', 'рад', 'любов', 'солнц', 'свет', 'улыб', 'радость', 'весел', 'happy', 'love', 'sun', 'joy', 'smile', 'bright', 'laugh', 'celebrat', 'hope', 'dream', 'heart', 'dance',
  };
  static const _sadWords = <String>{
    'груст', 'печал', 'тоск', 'слез', 'плач', 'боль', 'один', 'потеря', 'sad', 'cry', 'tear', 'lonely', 'alone', 'lost', 'pain', 'hurt', 'sorry', 'goodbye', 'broken', 'empty',
  };
  static const _aggressiveWords = <String>{
    'зл', 'ненавис', 'ярост', 'бешен', 'кров', 'убь', 'война', 'битв', 'angry', 'hate', 'rage', 'kill', 'blood', 'fight', 'war', 'fire', 'burn', 'mad', 'fury', 'violent',
  };
  static const _calmWords = <String>{
    'тих', 'спокой', 'нежн', 'сон', 'мягк', 'тепл', 'calm', 'quiet', 'soft', 'gentle', 'peace', 'sleep', 'dream', 'tender', 'warm', 'slow', 'whisper', 'breathe',
  };
  static const _energeticWords = <String>{
    'энерг', 'силы', 'вперед', 'взлет', 'огонь', 'движ', 'танц', 'energy', 'power', 'strong', 'run', 'fast', 'jump', 'move', 'up', 'fly', 'alive', 'free',
  };
  static const _melancholicWords = <String>{
    'меланхол', 'ностальг', 'вспомин', 'прошл', 'ушл', 'дожд', 'осень', 'melanch', 'nostalg', 'remember', 'past', 'gone', 'rain', 'fall', 'autumn', 'yesterday', 'memor',
  };

  /// Основной метод — комбинированная оценка.
  /// 0.4 лирика + 0.6 аудио, если лирика есть. Иначе только аудио.
  Future<MoodDetection> detectMood(
    Song song, {
    SyncedLyrics? lyrics,
    bool allowAiFallback = true,
  }) async {
    final cacheKey = '${song.id}:${song.title}:${song.artist}';
    // memory cache
    final mem = _memoryCache[cacheKey];
    if (mem != null && !mem.isExpired) return mem.detection;

    // disk cache
    final disk = await _readDiskCache(cacheKey);
    if (disk != null) {
      _memoryCache[cacheKey] = _CachedMood(disk);
      return disk;
    }

    // 1. Аудио mood (VibeSimilarity)
    final audioFeatures = _vibe.analyzeTrack(song);
    // Уточняем BPM из BpmAnalyzer если есть жанр
    double bpm = audioFeatures.bpm;
    try {
      final est = await _bpmService.getBPM(song, '');
      if (est != 100) bpm = est.toDouble();
    } catch (_) {}
    final audioFeaturesWithBpm = VibeFeatures(
      energy: audioFeatures.energy,
      valence: audioFeatures.valence,
      danceability: audioFeatures.danceability,
      bpm: bpm,
      acousticness: audioFeatures.acousticness,
      instrumentalness: audioFeatures.instrumentalness,
    );
    final audioDetection = _vibe.detectMood(audioFeaturesWithBpm);

    // 2. Лирика mood (если нет — возвращаем аудио)
    if (lyrics == null || lyrics.isEmpty) {
      await _writeDiskCache(cacheKey, audioDetection);
      _memoryCache[cacheKey] = _CachedMood(audioDetection);
      return audioDetection;
    }

    final lyricText = lyrics.lines.map((l) => l.text).join(' ').toLowerCase();
    final lyricDetection = _detectByLexicon(lyricText);

    // 3. Если лирика низкая уверенность и AI включен — уточняем через AiService
    MoodDetection lyricFinal = lyricDetection;
    if (allowAiFallback && lyricDetection.confidence < 0.62 && AiService().isConfigured) {
      try {
        final aiMood = await _classifyViaAi(lyricText.substring(0, lyricText.length.clamp(0, 800)), song);
        if (aiMood != null) {
          lyricFinal = aiMood;
        }
      } catch (e) {
        debugPrint('[LyricsMood] AI fallback failed: $e');
      }
    }

    // 4. Фьюжн: 0.4 лирика + 0.6 аудио
    final combined = _fuseMoods(audioDetection, lyricFinal);

    await _writeDiskCache(cacheKey, combined);
    _memoryCache[cacheKey] = _CachedMood(combined);
    return combined;
  }

  /// Быстрый синхронный детект только по лирике (для дебаунс / isolate)
  MoodDetection detectByLyricsSync(SyncedLyrics lyrics) {
    final text = lyrics.lines.map((l) => l.text).join(' ').toLowerCase();
    return _detectByLexicon(text);
  }

  /// Оффлайн лексикон
  MoodDetection _detectByLexicon(String lowerText) {
    if (lowerText.trim().isEmpty) {
      return const MoodDetection(mood: MoodType.calm, confidence: 0.5, arousal: 0.5, dominance: 0.5);
    }

    // Подсчет вхождений подстрок
    int count(Set<String> dict) {
      int c = 0;
      for (final w in dict) {
        // простое contains, без морфологии — быстро и достаточно для 2 языков
        if (lowerText.contains(w)) c++;
      }
      return c;
    }

    final happy = count(_happyWords);
    final sad = count(_sadWords);
    final aggr = count(_aggressiveWords);
    final calm = count(_calmWords);
    final energ = count(_energeticWords);
    final mel = count(_melancholicWords);

    final scores = <MoodType, int>{
      MoodType.happy: happy,
      MoodType.sad: sad,
      MoodType.angry: aggr,
      MoodType.calm: calm,
      MoodType.energetic: energ,
      MoodType.melancholic: mel,
    };

    // Найти максимум
    MoodType best = MoodType.calm;
    int bestScore = 0;
    int total = 0;
    scores.forEach((k, v) {
      total += v;
      if (v > bestScore) {
        bestScore = v;
        best = k;
      }
    });

    if (total == 0 || bestScore == 0) {
      return const MoodDetection(mood: MoodType.calm, confidence: 0.45, arousal: 0.4, dominance: 0.5);
    }

    // Уверенность = доля лучшего + бонус за отрыв
    final sorted = scores.values.toList()..sort((a, b) => b.compareTo(a));
    final second = sorted.length > 1 ? sorted[1] : 0;
    double conf = (bestScore / (total == 0 ? 1 : total)).clamp(0.0, 1.0);
    conf = (conf + (bestScore - second) * 0.08).clamp(0.35, 0.95);

    // Arousal/dominance эвристики для совместимости с Vibe
    double arousal;
    double dominance;
    switch (best) {
      case MoodType.energetic:
      case MoodType.angry:
        arousal = 0.85; dominance = 0.7; break;
      case MoodType.happy:
        arousal = 0.65; dominance = 0.6; break;
      case MoodType.calm:
      case MoodType.relaxed:
        arousal = 0.25; dominance = 0.4; break;
      case MoodType.sad:
      case MoodType.melancholic:
        arousal = 0.3; dominance = 0.35; break;
      default:
        arousal = 0.5; dominance = 0.5;
    }

    return MoodDetection(mood: best, confidence: conf, arousal: arousal, dominance: dominance);
  }

  /// Фьюжн аудио + лирика
  MoodDetection _fuseMoods(MoodDetection audio, MoodDetection lyric) {
    // Если лирика уверенная — даем ей вес 0.4, иначе 0.2
    final lyricWeight = lyric.confidence >= 0.6 ? 0.4 : 0.2;
    final audioWeight = 1.0 - lyricWeight;

    // Если настроения совпадают или совместимы — усиливаем
    final vibe = VibeSimilarity();
    final compat = vibe.moodCompatibilityScore(audio.mood, lyric.mood);

    // При высокой совместимости — берем лирику (она точнее по эмоции), иначе — аудио (оно точнее по энергетике)
    MoodType finalMood;
    double finalConf;
    if (compat >= 0.8 || audio.mood == lyric.mood) {
      finalMood = lyric.mood;
      finalConf = (lyric.confidence * lyricWeight + audio.confidence * audioWeight + 0.05).clamp(0.0, 0.98);
    } else if (lyric.confidence >= 0.72) {
      // Лирика очень уверенная — доверяем ей даже при несовместимости (мажорная музыка с грустным текстом → грустный)
      finalMood = lyric.mood;
      finalConf = (lyric.confidence * 0.55 + audio.confidence * 0.45).clamp(0.0, 0.95);
    } else {
      finalMood = audio.mood;
      finalConf = (audio.confidence * audioWeight + lyric.confidence * lyricWeight).clamp(0.0, 0.95);
    }

    final arousal = (audio.arousal * audioWeight + lyric.arousal * lyricWeight).clamp(0.0, 1.0);
    final dominance = (audio.dominance * audioWeight + lyric.dominance * lyricWeight).clamp(0.0, 1.0);

    return MoodDetection(mood: finalMood, confidence: finalConf, arousal: arousal, dominance: dominance);
  }

  /// AI уточнение — промпт как в aonsoku, но для настроения
  Future<MoodDetection?> _classifyViaAi(String snippet, Song song) async {
    final ai = AiService();
    if (!ai.isConfigured) return null;
    final prompt = 'Classify mood of this song lyrics snippet (RU/EN). '
        'Song: "${song.title}" — ${song.artist ?? ""} (${song.genre ?? ""}). '
        'Snippet: "$snippet". '
        'Reply ONLY one word from: energetic, happy, calm, sad, angry, melancholic, relaxed, focused, romantic, dramatic. No explanation.';
    try {
      final raw = await ai.classifyMood(prompt);
      final cleaned = raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
      final map = {
        'energetic': MoodType.energetic,
        'happy': MoodType.happy,
        'calm': MoodType.calm,
        'sad': MoodType.sad,
        'angry': MoodType.angry,
        'melancholic': MoodType.melancholic,
        'melancholy': MoodType.melancholic,
        'relaxed': MoodType.relaxed,
        'focused': MoodType.focused,
        'romantic': MoodType.romantic,
        'dramatic': MoodType.dramatic,
      };
      final type = map[cleaned];
      if (type == null) return null;
      return MoodDetection(mood: type, confidence: 0.78, arousal: 0.6, dominance: 0.6);
    } catch (_) {
      return null;
    }
  }

  // ---- Disk cache ----
  Future<MoodDetection?> _readDiskCache(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_cachePrefix$key');
      if (raw == null) return null;
      final parts = raw.split('|');
      if (parts.length < 4) return null;
      final moodStr = parts[0];
      final conf = double.tryParse(parts[1]) ?? 0.5;
      final arousal = double.tryParse(parts[2]) ?? 0.5;
      final dom = double.tryParse(parts[3]) ?? 0.5;
      final ts = int.tryParse(parts.length > 4 ? parts[4] : '0') ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - ts > _cacheExpiry.inMilliseconds) {
        await prefs.remove('$_cachePrefix$key');
        return null;
      }
      final mood = MoodType.values.firstWhere((m) => m.name == moodStr, orElse: () => MoodType.calm);
      return MoodDetection(mood: mood, confidence: conf, arousal: arousal, dominance: dom);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDiskCache(String key, MoodDetection d) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = '${d.mood.name}|${d.confidence}|${d.arousal}|${d.dominance}|${DateTime.now().millisecondsSinceEpoch}';
      await prefs.setString('$_cachePrefix$key', raw);
    } catch (_) {}
  }

  Future<void> clearCache() async {
    _memoryCache.clear();
    final prefs = await SharedPreferences.getInstance();
    for (final k in prefs.getKeys().where((k) => k.startsWith(_cachePrefix))) {
      await prefs.remove(k);
    }
  }
}

class _CachedMood {
  final MoodDetection detection;
  final DateTime cachedAt;
  _CachedMood(this.detection) : cachedAt = DateTime.now();
  bool get isExpired => DateTime.now().difference(cachedAt) > LyricsMoodService._cacheExpiry;
}
