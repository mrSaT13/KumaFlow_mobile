import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import 'bpm_analyzer_service.dart';
import 'subsonic_service.dart';
import 'recommendation_service.dart';
import 'local_music_service.dart';
import 'ml_service.dart';
import 'library_database_service.dart';
import '../models/ml/ml_types.dart';
import 'ml/vibe_similarity.dart';
import 'playlist_orchestrator.dart';
import 'kumaflow_brain/kumaflow_brain_bridge.dart';
import 'kumaflow_brain/kumaflow_brain_options.dart';
import 'kumaflow_brain/kumaflow_brain_settings.dart';
import 'kumaflow_brain/kumaflow_brain_wave_resolver.dart';

enum AutoDjMode {
  off,
  shuffleLibrary,
  similarSongs,
  sameGenre,
  sameArtist,
  smartMix,
  mlPowered,
  // Zhivaya volna: podpunkti ocheredi. Vsegda v konce enum chtoby ne
  // sdvinut sohranennyy modeIndex v prefs (0..6 zanyaty).
  flowEveryOther,
  flowDouble,
  flowArtist,
  flowEra,
  // KF-brain: server-driven refill iz mlbrainKF (wave/continue).
  // Strogo v kontse — ne sdvigat sushchestvuyushchie indeksy.
  kfBrain,
}

class SongAnalysis {
  final String songId;
  final int bpm;
  final String? genre;
  final int? year;
  final double energy;
  final int duration;
  final double? valence;
  final double? danceability;

  SongAnalysis({
    required this.songId,
    required this.bpm,
    this.genre,
    this.year,
    required this.energy,
    required this.duration,
    this.valence,
    this.danceability,
  });

  Map<String, dynamic> toJson() => {
    'songId': songId,
    'bpm': bpm,
    'genre': genre,
    'year': year,
    'energy': energy,
    'duration': duration,
    'valence': valence,
    'danceability': danceability,
  };

  factory SongAnalysis.fromJson(Map<String, dynamic> json) => SongAnalysis(
    songId: json['songId'] as String,
    bpm: json['bpm'] as int,
    genre: json['genre'] as String?,
    year: json['year'] as int?,
    energy: (json['energy'] as num).toDouble(),
    duration: json['duration'] as int,
    valence: (json['valence'] as num?)?.toDouble(),
    danceability: (json['danceability'] as num?)?.toDouble(),
  );
}

class AutoDjService extends ChangeNotifier {
  static final AutoDjService _instance = AutoDjService._internal();
  factory AutoDjService() => _instance;
  AutoDjService._internal();

  final BpmAnalyzerService _bpmAnalyzer = BpmAnalyzerService();
  SharedPreferences? _prefs;
  bool _isInitialized = false;

  final Map<String, SongAnalysis> _analysisCache = {};

  static const String _modeKey = 'auto_dj_mode';
  static const String _countKey = 'auto_dj_songs_to_add';
  static const String _thresholdKey = 'auto_dj_threshold';
  static const String _moodKey = 'auto_dj_mood';
  static const String _audiobookEnabledKey = 'auto_dj_audiobook_enabled';

  AutoDjMode _mode = AutoDjMode.off;
  int _songsToAdd = 5;
  int _triggerThreshold = 2;
  String? _currentMood;
  bool _audiobookEnabled = false; // OFF by default per spec

  final Set<String> _recentlyAddedIds = {};
  static const int _maxRecentlyAdded = 100;
  static const String _recentlyAddedKey = 'auto_dj_recently_added_v1';

  /// Персист окна повторов: раньше только in-memory на 100 шт — после
  /// рестарта волна сразу повторялась. Храним последние 100 id+queueKey.
  void _persistRecentlyAdded() {
    try {
      final list = _recentlyAddedIds.toList();
      final tail = list.length > _maxRecentlyAdded
          ? list.sublist(list.length - _maxRecentlyAdded)
          : list;
      unawaited(_prefs?.setStringList(_recentlyAddedKey, tail));
    } catch (_) {}
  }

  /// Проверка «уже в очереди/недавно»: учитывает и id, и queueKey
  /// (коллаб-микс: один id с разных серверов — разные треки).
  static bool _isKnown(Song s, Set<String> existingIds) {
    if (existingIds.contains(s.id)) return true;
    return existingIds.contains(s.queueKey);
  }

  SubsonicService? _subsonicService;
  RecommendationService? _recommendationService;
  LocalMusicService? _localMusicService;
  final LibraryDatabaseService _db = LibraryDatabaseService();

  // KumaFlow Brain: опциональный мост. null = выключен, тихий fallback
  // на локальный скоринг. Очередь/движок общие, отдельного плеера нет.
  KumaFlowBrainBridge? _brain;
  KumaFlowBrainSettings? _brainSettings;

  void setBrain(KumaFlowBrainBridge bridge, KumaFlowBrainSettings settings) {
    _brain = bridge;
    _brainSettings = settings;
  }

  /// M4: мета последнего KF-Brain ответа (reason/score/moods по song id).
  /// Очередь хранит только Song — причины подтягивает UI (субтайтл/снэк),
  /// иначе мозг выглядит как шаффл.
  final Map<String, String> _lastBrainReasons = {};
  final Map<String, List<String>> _lastBrainMoods = {};
  final Map<String, double> _lastBrainScores = {};
  Map<String, String> get lastBrainReasons => Map.unmodifiable(_lastBrainReasons);
  Map<String, List<String>> get lastBrainMoods => Map.unmodifiable(_lastBrainMoods);
  Map<String, double> get lastBrainScores => Map.unmodifiable(_lastBrainScores);
  String getBrainReason(String songId) => _lastBrainReasons[songId] ?? '';
  List<String> getBrainMoods(String songId) =>
      List.unmodifiable(_lastBrainMoods[songId] ?? const []);

  /// M6: фоновый префетч (чанк строго 5). Держим готовую пачку, чтобы не
  /// ждать 18с таймаута на пустой очереди. Инвалидируется сменой трека.
  List<Song> _brainPrefetched = const [];
  String? _brainPrefetchKey;
  bool _brainPrefetching = false;
  List<Song> get brainPrefetched => List.unmodifiable(_brainPrefetched);

  /// M2: живые настройки волны = общие с мозга (одни на всех устройствах) +
  /// снапшот экрана (bset.waveSettingsMap) + текущие пилюли (mywave_* префы
  /// home + _currentMood AutoDJ) + время суток.
  /// Приоритет: пилюли home > _currentMood > общие с мозга > снапшот настроек.
  /// Всё нормализуем в коды каталога (старые RU-пилюли в префах мигрируют).
  Map<String, dynamic> _buildWaveSettings(KumaFlowBrainSettings bset) {
    final merged = Map<String, dynamic>.from(bset.waveSettingsMap);
    try {
      final shared = _brain?.sharedWaveSettings ?? const {};
      for (final k in const ['activity', 'characteristic', 'mood', 'language']) {
        final v = (shared[k] ?? '').toString().trim();
        if (v.isNotEmpty) merged[k] = v;
      }
      if (shared['language_strict'] == true) {
        merged['language_strict'] = true;
      }
    } catch (_) {}
    try {
      final p = _prefs;
      final activity =
          normalizeBrainActivity(p?.getString('mywave_activity') ?? '');
      final character =
          normalizeBrainCharacteristic(p?.getString('mywave_character') ?? '');
      final mood = (p?.getString('mywave_mood') ?? '').trim();
      final lang =
          normalizeBrainLanguage(p?.getString('mywave_lang') ?? '');
      if (activity.isNotEmpty) merged['activity'] = activity;
      if (character.isNotEmpty) merged['characteristic'] = character;
      if (mood.isNotEmpty) merged['mood'] = mood;
      if (lang.isNotEmpty) merged['language'] = lang;
    } catch (_) {}
    final cm = _currentMood?.trim() ?? '';
    if (cm.isNotEmpty) merged['mood'] = cm;
    merged['time_label'] = _timeLabel();
    return merged;
  }

  /// Время суток для волны (сервер пока игнорирует неизвестные ключи —
  /// forward-compatible; используется и локально дляPeriod fallback).
  static String _timeLabel([DateTime? now]) {
    final h = (now ?? DateTime.now()).hour;
    if (h < 6) return 'night';
    if (h < 12) return 'morning';
    if (h < 18) return 'day';
    return 'evening';
  }

  static const String _lastRefreshKey = 'auto_dj_last_daily_refresh';
  Timer? _dailyRefreshTimer;

  VoidCallback? _onProgressUpdate;

  bool _isAnalyzing = false;
  double _analysisProgress = 0.0;
  String _analysisStatus = '';

  bool get isAnalyzing => _isAnalyzing;
  double get analysisProgress => _analysisProgress;
  String get analysisStatus => _analysisStatus;

  AutoDjMode get mode => _mode;
  int get songsToAdd => _songsToAdd;
  int get triggerThreshold => _triggerThreshold;
  bool get isEnabled => _mode != AutoDjMode.off;
  bool get audiobookEnabled => _audiobookEnabled;
  bool get isAudiobookAutoDjEnabled => _audiobookEnabled;
  String? get currentMood => _currentMood;

  bool isEnabledForSong(Song? song) {
    if (song == null) return isEnabled;
    final isAudiobook = song.id.startsWith('abs_') || song.genre == 'Audiobook';
    if (isAudiobook) return _audiobookEnabled;
    return isEnabled;
  }

  bool shouldAddSongsFor(int currentIndex, int queueLength, Song? currentSong) {
    final isAudiobook = currentSong != null && (currentSong.id.startsWith('abs_') || currentSong.genre == 'Audiobook');
    if (isAudiobook && !_audiobookEnabled) return false;
    if (!isEnabled) return false;
    final remaining = queueLength - currentIndex - 1;
    return remaining <= _triggerThreshold;
  }

  void setServices(
    SubsonicService subsonicService,
    RecommendationService? recommendationService, {
    LocalMusicService? localMusicService,
  }) {
    _subsonicService = subsonicService;
    _recommendationService = recommendationService;
    _localMusicService = localMusicService;
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _prefs = await SharedPreferences.getInstance();
      await _bpmAnalyzer.initialize();
      await _loadAnalysisCache();

      final modeIndex = _prefs?.getInt(_modeKey) ?? 0;
      _mode =
          AutoDjMode.values[modeIndex.clamp(0, AutoDjMode.values.length - 1)];
      _songsToAdd = _prefs?.getInt(_countKey) ?? 5;
      _triggerThreshold = _prefs?.getInt(_thresholdKey) ?? 2;
      _currentMood = _prefs?.getString(_moodKey);
      _audiobookEnabled = _prefs?.getBool(_audiobookEnabledKey) ?? false;

      try {
        final stored = _prefs?.getStringList(_recentlyAddedKey) ?? const [];
        _recentlyAddedIds.addAll(stored);
        while (_recentlyAddedIds.length > _maxRecentlyAdded) {
          _recentlyAddedIds.remove(_recentlyAddedIds.first);
        }
      } catch (_) {}

      _isInitialized = true;
      _scheduleDailyRefresh();
    } catch (e) {
      debugPrint('Error initializing AutoDJ: $e');
    }
  }

  void _scheduleDailyRefresh() {
    _dailyRefreshTimer?.cancel();
    _dailyRefreshTimer = Timer.periodic(
      const Duration(hours: 1),
      (_) => _checkDailyRefresh(),
    );
  }

  Future<void> _checkDailyRefresh() async {
    if (!isEnabled || _subsonicService == null) return;
    final lastRefresh = _prefs?.getInt(_lastRefreshKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final oneDayMs = 24 * 60 * 60 * 1000;
    if (now - lastRefresh < oneDayMs) return;

    debugPrint('[AutoDJ] Daily refresh triggered');
    try {
      final songs = await getSongsToQueue(
        currentSong: null,
        currentQueue: [],
      );
      if (songs.isNotEmpty) {
        await _prefs?.setInt(_lastRefreshKey, now);
        debugPrint('[AutoDJ] Daily refresh: generated ${songs.length} songs');
      }
    } catch (e) {
      debugPrint('[AutoDJ] Daily refresh error: $e');
    }
  }

  Future<void> refreshNow() async {
    await _checkDailyRefresh();
  }

  Future<void> setMode(AutoDjMode mode) async {
    _mode = mode;
    await _prefs?.setInt(_modeKey, mode.index);
    notifyListeners();
  }

  Future<void> setSongsToAdd(int count) async {
    _songsToAdd = count.clamp(1, 50);
    await _prefs?.setInt(_countKey, _songsToAdd);
    notifyListeners();
  }

  Future<void> setTriggerThreshold(int threshold) async {
    _triggerThreshold = threshold.clamp(1, 5);
    await _prefs?.setInt(_thresholdKey, _triggerThreshold);
    notifyListeners();
  }

  Future<void> setMood(String? mood) async {
    _currentMood = mood;
    if (mood != null) {
      await _prefs?.setString(_moodKey, mood);
    } else {
      await _prefs?.remove(_moodKey);
    }
    notifyListeners();
  }

  Future<void> setAudiobookEnabled(bool enabled) async {
    _audiobookEnabled = enabled;
    await _prefs?.setBool(_audiobookEnabledKey, enabled);
    notifyListeners();
  }

  bool shouldAddSongs(int currentIndex, int queueLength) {
    if (!isEnabled) return false;
    final remaining = queueLength - currentIndex - 1;
    return remaining <= _triggerThreshold;
  }

  Future<List<Song>> getSongsToQueue({
    required Song? currentSong,
    required List<Song> currentQueue,
    List<Song>? availableSongs,
    // Офлайн-пул (скачанное/локальное): когда сервер недоступен, докачка идёт
    // из него вместо пустого списка. Онлайн игнорируется (сервер + анализ).
    List<Song>? fallbackPool,
  }) async {
    if (!isEnabled || _subsonicService == null) return [];
    // Audiobook guard: if current is audiobook and toggle OFF, return empty
    if (currentSong != null && (currentSong.id.startsWith('abs_') || currentSong.genre == 'Audiobook') && !_audiobookEnabled) {
      return [];
    }

    final existingIds = <String>{
      for (final s in currentQueue) s.id,
      for (final s in currentQueue) s.queueKey,
      ..._recentlyAddedIds,
    };

    try {
      switch (_mode) {
        case AutoDjMode.off:
          return [];

        case AutoDjMode.shuffleLibrary:
          return await _getShuffledLibrarySongs(existingIds);

        case AutoDjMode.similarSongs:
          if (currentSong == null) {
            return await _getShuffledLibrarySongs(existingIds);
          }
          return await _getSimilarSongs(currentSong, existingIds);

        case AutoDjMode.sameGenre:
          if (currentSong?.genre == null) {
            return await _getShuffledLibrarySongs(existingIds);
          }
          return await _getSameGenreSongs(currentSong!.genre!, existingIds);

        case AutoDjMode.sameArtist:
          if (currentSong?.artistId == null) {
            return await _getShuffledLibrarySongs(existingIds);
          }
          return await _getSameArtistSongs(currentSong!.artistId!, existingIds);

        case AutoDjMode.smartMix:
          return await _getSmartMixSongs(
            currentSong,
            existingIds,
            availableSongs,
          );

        case AutoDjMode.mlPowered:
          return await _getMlPoweredSongs(
            currentSong,
            existingIds,
            availableSongs,
          );

        case AutoDjMode.flowEveryOther:
          return await _getFlowEveryOther(
            currentSong,
            existingIds,
          );

        case AutoDjMode.flowDouble:
          return await _getFlowDouble(
            currentSong,
            existingIds,
          );

        case AutoDjMode.flowArtist:
          if (currentSong?.artistId == null) {
            return await _getShuffledLibrarySongs(existingIds);
          }
          return await _getFlowArtist(
            currentSong!,
            existingIds,
          );

        case AutoDjMode.flowEra:
          return await _getFlowEra(
            currentSong,
            existingIds,
            availableSongs,
          );

        case AutoDjMode.kfBrain:
          return await _getKumaFlowBrainSongs(
            currentSong,
            currentQueue,
            existingIds,
            availableSongs,
          );
      }
    } catch (e) {
      debugPrint('Auto DJ error: $e');
      return await _getShuffledLibrarySongs(existingIds, fallbackPool: fallbackPool);
    }
  }

  /// KF-brain: server-driven refill из mlbrainKF (ТЗ 3b).
  /// Триггер — общий AutoDJ (осталось <= threshold / старт с нуля):
  /// waveContinue{queue, current, count 5, settings, exclude_ids,
  ///   recent_events, ratings_delta} -> append через KumaFlowBrainWaveResolver.
  /// missing -> exclude_ids следующего запроса. Чанк строго 5: маленькими
  /// порциями смена настроения в волне заметна сразу, телефон не гоняет
  /// лишнее (M6: фоновая докачка — тоже чанком 5, см. prefetchBrain()).
  /// Любая ошибка/таймаут/пусто -> тихий дешёвый fallback (шаффл библиотеки,
  /// БЕЗ локального ML-скоринга — в серверном режиме локалку не грузим).
  /// M1: свежие события/оценки едут ВНУТРИ waveContinue (кольцо моста),
  /// M2: настройки = мерж снапшота + пилюли + время суток.
  /// M4: reason/moods/score складываем в lastBrain* для UI.
  Future<List<Song>> _getKumaFlowBrainSongs(
    Song? currentSong,
    List<Song> currentQueue,
    Set<String> existingIds,
    List<Song>? availableSongs,
  ) async {
    Future<List<Song>> fallback() {
      // Серверный режим: тяжёлый локальный ML-скоринг не гоняем
      // (бережём телефон) — откат дешёвым шаффлом библиотеки.
      if (_subsonicService == null) return Future.value(const <Song>[]);
      return _getShuffledLibrarySongs(existingIds,
          fallbackPool: availableSongs);
    }
    final brain = _brain;
    final bset = _brainSettings;
    // Мост не привязан/не активен — обычный локальный скоринг, без смены UI.
    if (brain == null || bset == null || !brain.isActive) {
      return _getMlPoweredSongs(currentSong, existingIds, availableSongs);
    }
    if (_subsonicService == null) return fallback();
    // M6: свежая префетч-пачка для этого же трека — отдаём сразу.
    final preKey = currentSong?.id ?? '';
    if (_brainPrefetched.isNotEmpty && _brainPrefetchKey == preKey) {
      final cached = _brainPrefetched
          .where((s) => !_isKnown(s, existingIds))
          .toList();
      _brainPrefetched = const [];
      _brainPrefetchKey = null;
      if (cached.isNotEmpty) {
        for (final s in cached) {
          _recentlyAddedIds.add(s.id);
        }
        _persistRecentlyAdded();
        // Фоново готовим следующую пачку под новый хвост.
        unawaited(prefetchBrain(currentSong: currentSong, currentQueue: [
          ...currentQueue,
          ...cached,
        ]));
        return _filterAndLimit(cached, existingIds);
      }
    }
    try {
      final queueIds = currentQueue.map((s) => s.id).toList();
      // Чанк 5: смена настроения видна сразу, лишнего не тянем.
      const count = 5;
      final tracks = await brain
          .waveContinue(
            queue: queueIds,
            currentTrackId: currentSong?.id,
            count: count,
            settingsMap: _buildWaveSettings(bset),
            excludeIds: brain.pendingExcludeIds,
          )
          .timeout(const Duration(seconds: 18));
      if (tracks.isEmpty) return fallback();
      final resolved = await KumaFlowBrainWaveResolver(_subsonicService!)
          .resolve(tracks, maxTracks: count + 5);
      if (resolved.missing.isNotEmpty) {
        brain.noteMissing(resolved.missing.map((t) =>
            (t.externalId != null && t.externalId!.isNotEmpty)
                ? t.externalId!
                : t.trackId));
      }
      // M4: подклеиваем reason/moods/score по song id для субтайтлов и снеков.
      for (final r in resolved.found) {
        final sid = r.song.id;
        if (r.brain.reason.trim().isNotEmpty) {
          _lastBrainReasons[sid] = r.brain.reason.trim();
        }
        if (r.brain.moods.isNotEmpty) {
          _lastBrainMoods[sid] = List<String>.from(r.brain.moods);
        }
        _lastBrainScores[sid] = r.brain.score;
      }
      while (_lastBrainReasons.length > 200) {
        _lastBrainReasons.remove(_lastBrainReasons.keys.first);
      }
      while (_lastBrainMoods.length > 200) {
        _lastBrainMoods.remove(_lastBrainMoods.keys.first);
      }
      while (_lastBrainScores.length > 200) {
        _lastBrainScores.remove(_lastBrainScores.keys.first);
      }
      final found = resolved.found
          .map((r) => r.song)
          .where((s) => !_isKnown(s, existingIds))
          .toList();
      if (found.isEmpty) return fallback();
      for (final s in found) {
        _recentlyAddedIds.add(s.id);
      }
      _persistRecentlyAdded();
      // M6: сразу готовим следующую пачку фоном (чанк 5, хвост + новинки).
      unawaited(prefetchBrain(
          currentSong: currentSong,
          currentQueue: [...currentQueue, ...found]));
      return _filterAndLimit(found, existingIds);
    } catch (_) {
      return fallback();
    }
  }

  /// M6: фоновый префетч следующей пачки (count=5, НЕ увеличиваем чанк).
  /// Вызывается после каждой выдачи и из плеера, когда очередь ещё не пуста
  /// (осталось > threshold), чтобы не ждать 18с таймаута на пустой очереди.
  /// Ошибки — тихо, очередь не рвём.
  Future<void> prefetchBrain({
    Song? currentSong,
    required List<Song> currentQueue,
  }) async {
    final brain = _brain;
    final bset = _brainSettings;
    if (brain == null || bset == null || !brain.isActive) return;
    if (_subsonicService == null || _brainPrefetching) return;
    final key = currentSong?.id ?? '';
    if (_brainPrefetched.isNotEmpty && _brainPrefetchKey == key) return;
    _brainPrefetching = true;
    try {
      final queueIds = currentQueue.map((s) => s.id).toList();
      const count = 5;
      final tracks = await brain
          .waveContinue(
            queue: queueIds,
            currentTrackId: currentSong?.id,
            count: count,
            settingsMap: _buildWaveSettings(bset),
            excludeIds: brain.pendingExcludeIds,
          )
          .timeout(const Duration(seconds: 18));
      if (tracks.isEmpty) return;
      final resolved = await KumaFlowBrainWaveResolver(_subsonicService!)
          .resolve(tracks, maxTracks: count + 5)
          .timeout(const Duration(seconds: 30));
      if (resolved.missing.isNotEmpty) {
        brain.noteMissing(resolved.missing.map((t) =>
            (t.externalId != null && t.externalId!.isNotEmpty)
                ? t.externalId!
                : t.trackId));
      }
      final existingIds = <String>{
        for (final s in currentQueue) s.id,
        for (final s in currentQueue) s.queueKey,
        ..._recentlyAddedIds,
      };
      final fresh = <Song>[];
      for (final r in resolved.found) {
        if (_isKnown(r.song, existingIds)) continue;
        fresh.add(r.song);
        final sid = r.song.id;
        if (r.brain.reason.trim().isNotEmpty) {
          _lastBrainReasons[sid] = r.brain.reason.trim();
        }
        if (r.brain.moods.isNotEmpty) {
          _lastBrainMoods[sid] = List<String>.from(r.brain.moods);
        }
        _lastBrainScores[sid] = r.brain.score;
      }
      if (fresh.isNotEmpty) {
        _brainPrefetched = fresh;
        _brainPrefetchKey = key;
      }
    } catch (_) {
    } finally {
      _brainPrefetching = false;
    }
  }

  /// Плеер дёргает при смене трека: старый префетч протух, греем новый,
  /// пока пользователь слушает (осталось > threshold — самое время).
  Future<void> onTrackChangedPrefetch({
    Song? currentSong,
    required List<Song> currentQueue,
  }) {
    _brainPrefetched = const [];
    _brainPrefetchKey = null;
    return prefetchBrain(currentSong: currentSong, currentQueue: currentQueue);
  }

  Future<List<Song>> _getShuffledLibrarySongs(
    Set<String> existingIds, {
    List<Song>? fallbackPool,
  }) async {
    final songs = <Song>[];

    // Fetch from server
    try {
      final serverSongs = await _subsonicService!.getRandomSongs(size: _songsToAdd * 2);
      songs.addAll(serverSongs);
    } catch (_) {}

    // Офлайн: сервер пуст — берём скачанное/локальное из fallback-пула.
    if (songs.isEmpty && fallbackPool != null && fallbackPool.isNotEmpty) {
      final pool = List<Song>.from(fallbackPool)..shuffle(Random());
      for (final s in pool) {
        if (songs.length >= _songsToAdd * 2) break;
        if (!songs.any((e) => e.id == s.id)) songs.add(s);
      }
    }

    // Include local songs
    if (_localMusicService != null && _localMusicService!.songs.isNotEmpty) {
      final localSongs = _localMusicService!.songs;
      for (final localSong in localSongs) {
        if (!songs.any((s) => s.id == localSong.id)) {
          songs.add(localSong);
        }
      }
    }

    return _filterAndLimit(songs, existingIds);
  }

  Future<List<Song>> _getSimilarSongs(
    Song song,
    Set<String> existingIds,
  ) async {
    final similarSongs = await _subsonicService!.getSimilarSongs(
      song.id,
      count: _songsToAdd * 2,
    );

    if (similarSongs.isNotEmpty) {
      return _filterAndLimit(similarSongs, existingIds);
    }

    if (song.genre != null) {
      final genreSongs = await _getSameGenreSongs(song.genre!, existingIds);
      if (genreSongs.isNotEmpty) return genreSongs;
    }

    if (song.artistId != null) {
      final artistSongs = await _getSameArtistSongs(
        song.artistId!,
        existingIds,
      );
      if (artistSongs.isNotEmpty) return artistSongs;
    }

    return await _getShuffledLibrarySongs(existingIds);
  }

  Future<List<Song>> _getSameGenreSongs(
    String genre,
    Set<String> existingIds,
  ) async {
    final songs = await _subsonicService!.getSongsByGenre(
      genre,
      count: _songsToAdd * 2,
    );
    final filtered = _filterAndLimit(songs, existingIds);

    if (filtered.isEmpty) {
      return await _getShuffledLibrarySongs(existingIds);
    }
    return filtered;
  }

  Future<List<Song>> _getSameArtistSongs(
    String artistId,
    Set<String> existingIds,
  ) async {
    final topSongs = await _subsonicService!.getArtistTopSongs(
      artistId,
      count: _songsToAdd * 2,
    );
    final filtered = _filterAndLimit(topSongs, existingIds);

    if (filtered.isEmpty) {
      return await _getShuffledLibrarySongs(existingIds);
    }
    return filtered;
  }

  Future<List<Song>> _getSmartMixSongs(
    Song? currentSong,
    Set<String> existingIds,
    List<Song>? availableSongs,
  ) async {
    final List<Song> results = [];
    final List<Future<List<Song>>> futures = [];

    if (currentSong != null) {
      
      futures.add(
        _subsonicService!.getSimilarSongs(
          currentSong.id,
          count: (_songsToAdd * 0.4).ceil(),
        ),
      );

      if (currentSong.genre != null) {
        futures.add(
          _subsonicService!.getSongsByGenre(
            currentSong.genre!,
            count: (_songsToAdd * 0.3).ceil(),
          ),
        );
      }
    }

    if (_recommendationService != null) {
      final topGenres = _recommendationService!.getRecommendedGenres(limit: 3);
      for (final genre in topGenres.take(2)) {
        futures.add(_subsonicService!.getSongsByGenre(genre, count: 3));
      }
    }

    futures.add(
      _subsonicService!.getRandomSongs(size: (_songsToAdd * 0.3).ceil()),
    );

    if (currentSong != null &&
        availableSongs != null &&
        _analysisCache.containsKey(currentSong.id)) {
      final smartQueue = generateQueue(
        seedSong: currentSong,
        availableSongs: availableSongs
            .where((s) => !existingIds.contains(s.id))
            .toList(),
        queueLength: _songsToAdd,
      );
      if (smartQueue.length > 1) {
        return smartQueue.skip(1).toList(); 
      }
    }

    final timed = futures.map((f) {
      return f
          .timeout(const Duration(seconds: 12))
          .catchError((_) => const <Song>[]);
    }).toList();
    final allResults = await Future.wait(timed);
    for (final songList in allResults) {
      results.addAll(songList);
    }

    results.shuffle(Random());
    return _filterAndLimit(results, existingIds);
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Zhivaya volna: rezhimy ocheredi (poryadok vazhen — bez shuffle).
  // ──────────────────────────────────────────────────────────────────────────

  /// Veto + dedup s sohraneniem poryadka (v otlichie ot _filterAndLimit
  /// kotoryy peremeshivaet). Ispolzuetsya flow-rezhimami gde poryadok
  /// eto smysl: cherez odin, pary, volna artista, epoha.
  List<Song> _filterOrdered(List<Song> songs, Set<String> existingIds) {
    final bannedArtists = MLService().profile.bannedArtists.toSet();
    final bannedArtistNamesLower = MLService().profile.bannedArtistNames.values.map((n) => n.toLowerCase()).toSet();
    final dislikedSongs = MLService().profile.dislikedSongs.toSet();
    final seen = <String>{};
    final result = <Song>[];
    for (final s in songs) {
      if (result.length >= _songsToAdd) break;
      if (_isKnown(s, existingIds)) continue;
      if (_recentlyAddedIds.contains(s.id) || _recentlyAddedIds.contains(s.queueKey)) continue;
      if (!seen.add(s.queueKey)) continue;
      if (dislikedSongs.contains(s.id)) continue;
      if (s.artistId != null && bannedArtists.contains(s.artistId)) continue;
      if (s.artist != null && bannedArtistNamesLower.contains(s.artist!.toLowerCase())) continue;
      // Ne bolshe 2 podryad odnogo artista (kak v kollab-merzhe).
      if (result.length >= 2) {
        final a = (s.artist ?? '').toLowerCase();
        if (a.isNotEmpty &&
            result[result.length - 1].artist?.toLowerCase() == a &&
            result[result.length - 2].artist?.toLowerCase() == a) {
          continue;
        }
      }
      result.add(s);
    }
    for (final song in result) {
      _recentlyAddedIds.add(song.id);
      _recentlyAddedIds.add(song.queueKey);
      if (_recentlyAddedIds.length > _maxRecentlyAdded * 2) {
        // LinkedHashSet: first — самый старый.
        _recentlyAddedIds.remove(_recentlyAddedIds.first);
      }
    }
    _persistRecentlyAdded();
    return result;
  }

  /// Cherez odin: svoy/pohozhiy trek, zatem sluchaynyy — i tak dalee.
  Future<List<Song>> _getFlowEveryOther(
    Song? currentSong,
    Set<String> existingIds,
  ) async {
    if (currentSong == null) return _getShuffledLibrarySongs(existingIds);
    final picked = <Song>[];
    try {
      // Параллельно: раньше similar ждал 12с, и только потом шёл random.
      final results = await Future.wait([
        _subsonicService!
            .getSimilarSongs(currentSong.id, count: _songsToAdd)
            .timeout(const Duration(seconds: 6))
            .catchError((_) => const <Song>[]),
        _subsonicService!
            .getRandomSongs(size: _songsToAdd)
            .timeout(const Duration(seconds: 8))
            .catchError((_) => const <Song>[]),
      ]);
      final similar = results[0];
      final random = results[1];
      for (var i = 0; i < _songsToAdd; i++) {
        if (picked.length >= _songsToAdd) break;
        if (i < similar.length) picked.add(similar[i]);
        if (picked.length >= _songsToAdd) break;
        if (i < random.length) picked.add(random[i]);
      }
    } catch (_) {}
    if (picked.isEmpty) return _getShuffledLibrarySongs(existingIds);
    final ordered = _filterOrdered(picked, existingIds);
    if (ordered.isEmpty) return _getShuffledLibrarySongs(existingIds);
    return ordered;
  }

  /// Dubl: vsegda po dva treka odnogo artista podryad.
  Future<List<Song>> _getFlowDouble(
    Song? currentSong,
    Set<String> existingIds,
  ) async {
    final candidates = <Song>[];
    try {
      // Параллельно: topSongs (Last.fm) может висеть — не блокируем similar.
      final futures = <Future<List<Song>>>[];
      if (currentSong?.artistId != null) {
        futures.add(_subsonicService!
            .getArtistTopSongs(currentSong!.artistId!, count: _songsToAdd * 2)
            .timeout(const Duration(seconds: 6))
            .catchError((_) => const <Song>[]));
      }
      if (currentSong != null) {
        futures.add(_subsonicService!
            .getSimilarSongs(currentSong.id, count: _songsToAdd * 2)
            .timeout(const Duration(seconds: 6))
            .catchError((_) => const <Song>[]));
      }
      final results = await Future.wait(futures);
      for (final r in results) {
        candidates.addAll(r);
      }
    } catch (_) {}
    if (candidates.isEmpty) return _getShuffledLibrarySongs(existingIds);
    // Gruppiruem po artistu s sohraneniem poryadka, berem pary.
    final byArtist = <String, List<Song>>{};
    final order = <String>[];
    for (final s in candidates) {
      final key = s.artistId ?? s.artist?.toLowerCase() ?? s.id;
      if (!byArtist.containsKey(key)) order.add(key);
      byArtist.putIfAbsent(key, () => []).add(s);
    }
    final picked = <Song>[];
    for (final key in order) {
      if (picked.length >= _songsToAdd) break;
      final group = byArtist[key]!;
      // Para: pervye dva neigravshih treka artista.
      var added = 0;
      for (final s in group) {
        if (added >= 2) break;
        if (picked.any((p) => p.id == s.id)) continue;
        picked.add(s);
        added++;
      }
    }
    final ordered = _filterOrdered(picked, existingIds);
    if (ordered.isEmpty) return _getShuffledLibrarySongs(existingIds);
    return ordered;
  }

  /// Volna artista: tolko treki tekushego ispolnitelya.
  Future<List<Song>> _getFlowArtist(
    Song currentSong,
    Set<String> existingIds,
  ) async {
    try {
      final top = await _subsonicService!
          .getArtistTopSongs(currentSong.artistId!, count: _songsToAdd * 2)
          .timeout(const Duration(seconds: 12))
          .catchError((_) => const <Song>[]);
      if (top.isNotEmpty) {
        final ordered = _filterOrdered(top, existingIds);
        if (ordered.isNotEmpty) return ordered;
      }
    } catch (_) {}
    // Fallback: pohozhie (mogut vyvesti na smezhnyh artistov).
    return _getSimilarSongs(currentSong, existingIds);
  }

  /// Epoha: tolko treki togo zhe desyatiletiya chto tekushiy.
  Future<List<Song>> _getFlowEra(
    Song? currentSong,
    Set<String> existingIds,
    List<Song>? availableSongs,
  ) async {
    final year = currentSong?.year;
    if (year == null) {
      if (currentSong == null) return _getShuffledLibrarySongs(existingIds);
      return _getSimilarSongs(currentSong, existingIds);
    }
    final decade = (year ~/ 10) * 10;
    bool inEra(Song s) =>
        s.year != null && s.year! >= decade && s.year! < decade + 10;

    final pool = <Song>[];
    if (availableSongs != null) {
      pool.addAll(availableSongs.where(inEra));
    }
    // Dobirayem so servera (1-2 zahoda, ne bolShe chtoby ne shtormit set).
    for (var attempt = 0; attempt < 2 && pool.length < _songsToAdd * 2; attempt++) {
      try {
        final random = await _subsonicService!
            .getRandomSongs(size: 50)
            .timeout(const Duration(seconds: 12))
            .catchError((_) => const <Song>[]);
        pool.addAll(random.where(inEra));
      } catch (_) {
        break;
      }
    }
    if (pool.isEmpty) {
      if (currentSong == null) return _getShuffledLibrarySongs(existingIds);
      return _getSimilarSongs(currentSong, existingIds);
    }
    final ordered = _filterOrdered(pool, existingIds);
    if (ordered.isEmpty) return _getShuffledLibrarySongs(existingIds);
    return ordered;
  }

  List<Song> _filterAndLimit(List<Song> songs, Set<String> existingIds) {
    final bannedArtists = MLService().profile.bannedArtists.toSet();
    final bannedArtistNamesLower = MLService().profile.bannedArtistNames.values.map((n) => n.toLowerCase()).toSet();
    final dislikedSongs = MLService().profile.dislikedSongs.toSet();
    final filtered = songs.where((s) {
      if (_isKnown(s, existingIds)) return false;
      if (_recentlyAddedIds.contains(s.id) || _recentlyAddedIds.contains(s.queueKey)) return false;
      if (dislikedSongs.contains(s.id)) return false;
      if (s.artistId != null && bannedArtists.contains(s.artistId)) return false;
      if (s.artist != null && bannedArtistNamesLower.contains(s.artist!.toLowerCase())) return false;
      return true;
    }).toList();

    filtered.shuffle(Random());
    // Strict artist diversity: max 1 per artist on first pass, max 2 on second pass
    // Never fallback to unlimited duplicates (fixes Wiz Khalifa spam)
    const maxTracksPerArtist = 2;
    const strictMax = 1;
    final artistCounts = <String, int>{};
    final result = <Song>[];

    // Pass 1: strict max 1 per artist (maximum diversity)
    for (final s in filtered) {
      if (result.length >= _songsToAdd) break;
      final key = (s.artistId ?? s.artist?.toLowerCase() ?? s.id);
      final c = artistCounts[key] ?? 0;
      if (c >= strictMax) continue;
      result.add(s);
      artistCounts[key] = c + 1;
    }
    // Pass 2: allow 2nd track per artist if still not enough
    if (result.length < _songsToAdd) {
      for (final s in filtered) {
        if (result.length >= _songsToAdd) break;
        if (result.any((r) => r.id == s.id)) continue;
        final key = (s.artistId ?? s.artist?.toLowerCase() ?? s.id);
        final c = artistCounts[key] ?? 0;
        if (c >= maxTracksPerArtist) continue;
        result.add(s);
        artistCounts[key] = c + 1;
      }
    }
    // If still not enough, do NOT spam same artist — return what we have
    // (better 3 diverse tracks than 5 from one artist)

    for (final song in result) {
      _recentlyAddedIds.add(song.id);
      _recentlyAddedIds.add(song.queueKey);
      if (_recentlyAddedIds.length > _maxRecentlyAdded * 2) {
        _recentlyAddedIds.remove(_recentlyAddedIds.first);
      }
    }
    _persistRecentlyAdded();

    return result;
  }

  void clearRecentlyAdded() {
    _recentlyAddedIds.clear();
    try {
      unawaited(_prefs?.remove(_recentlyAddedKey));
    } catch (_) {}
  }

  static String getModeDisplayName(AutoDjMode mode) {
    switch (mode) {
      case AutoDjMode.off:
        return 'Off';
      case AutoDjMode.shuffleLibrary:
        return 'Shuffle Library';
      case AutoDjMode.similarSongs:
        return 'Similar Songs';
      case AutoDjMode.sameGenre:
        return 'Same Genre';
      case AutoDjMode.sameArtist:
        return 'Same Artist';
      case AutoDjMode.smartMix:
        return 'Smart Mix';
      case AutoDjMode.mlPowered:
        return 'ML Powered';
      case AutoDjMode.flowEveryOther:
        return 'Every Other';
      case AutoDjMode.flowDouble:
        return 'Double Play';
      case AutoDjMode.flowArtist:
        return 'Artist Wave';
      case AutoDjMode.flowEra:
        return 'Era Wave';
      case AutoDjMode.kfBrain:
        return 'KF-Brain';
    }
  }

  static String getModeDescription(AutoDjMode mode) {
    switch (mode) {
      case AutoDjMode.off:
        return 'Playback stops when queue ends';
      case AutoDjMode.shuffleLibrary:
        return 'Add random songs from your library';
      case AutoDjMode.similarSongs:
        return 'Add songs similar to what\'s playing';
      case AutoDjMode.sameGenre:
        return 'Add songs from the same genre';
      case AutoDjMode.sameArtist:
        return 'Add more songs by the same artist';
      case AutoDjMode.smartMix:
        return 'Intelligent mix based on tempo, genre, and listening habits';
      case AutoDjMode.mlPowered:
        return 'ML-driven recommendations using your listening history and mood';
      case AutoDjMode.flowEveryOther:
        return 'Alternate familiar tracks with fresh discoveries';
      case AutoDjMode.flowDouble:
        return 'Always two tracks by the same artist in a row';
      case AutoDjMode.flowArtist:
        return 'Keep the wave on the current artist';
      case AutoDjMode.flowEra:
        return 'Keep the wave in the same decade';
      case AutoDjMode.kfBrain:
        return 'Server wave from mlbrainKF (best-effort, local fallback)';
    }
  }

  void setProgressCallback(VoidCallback? callback) {
    _onProgressUpdate = callback;
  }

  Future<void> _loadAnalysisCache() async {
    final keys = _prefs?.getKeys().where((k) => k.startsWith('autodj_')) ?? [];
    for (final key in keys) {
      final songId = key.replaceFirst('autodj_', '');
      final bpm = _prefs?.getInt('${key}_bpm') ?? 100;
      final energy = _prefs?.getDouble('${key}_energy') ?? 0.5;
      final genre = _prefs?.getString('${key}_genre');
      final year = _prefs?.getInt('${key}_year');
      final duration = _prefs?.getInt('${key}_duration') ?? 180;

      _analysisCache[songId] = SongAnalysis(
        songId: songId,
        bpm: bpm,
        genre: genre,
        year: year,
        energy: energy,
        duration: duration,
      );
    }
  }

  Future<void> _saveAnalysis(SongAnalysis analysis) async {
    final key = 'autodj_${analysis.songId}';
    await _prefs?.setInt('${key}_bpm', analysis.bpm);
    await _prefs?.setDouble('${key}_energy', analysis.energy);
    if (analysis.genre != null) {
      await _prefs?.setString('${key}_genre', analysis.genre!);
    }
    if (analysis.year != null) {
      await _prefs?.setInt('${key}_year', analysis.year!);
    }
    await _prefs?.setInt('${key}_duration', analysis.duration);
    await _prefs?.setBool(key, true);
  }

  Future<void> analyzeSongs(
    List<Song> songs,
    String Function(String?) getAudioUrl,
  ) async {
    if (_isAnalyzing) return;
    if (!_isInitialized) await initialize();

    _isAnalyzing = true;
    _analysisProgress = 0.0;
    _analysisStatus = 'Starting analysis...';
    _onProgressUpdate?.call();

    try {
      for (int i = 0; i < songs.length; i++) {
        final song = songs[i];

        if (!_analysisCache.containsKey(song.id)) {
          _analysisStatus = 'Analyzing: ${song.title}';
          _onProgressUpdate?.call();

          final audioUrl = getAudioUrl(song.id);
          final bpm = await _bpmAnalyzer.getBPM(song, audioUrl);

          final energy = _estimateEnergy(song, bpm);

          final analysis = SongAnalysis(
            songId: song.id,
            bpm: bpm,
            genre: song.genre,
            year: song.year,
            energy: energy,
            duration: song.duration ?? 180,
          );

          _analysisCache[song.id] = analysis;
          await _saveAnalysis(analysis);
        }

        _analysisProgress = (i + 1) / songs.length;
        _onProgressUpdate?.call();
      }

      _analysisStatus = 'Analysis complete!';
    } catch (e) {
      _analysisStatus = 'Error: $e';
      debugPrint('AutoDJ analysis error: $e');
    } finally {
      _isAnalyzing = false;
      _onProgressUpdate?.call();
    }
  }

  bool areSongsAnalyzed(List<Song> songs) {
    for (final song in songs) {
      if (!_analysisCache.containsKey(song.id)) {
        return false;
      }
    }
    return true;
  }

  SongAnalysis? getAnalysis(String songId) {
    return _analysisCache[songId];
  }

  double _estimateEnergy(Song song, int bpm) {
    double energy = 0.5;
    final genre = song.genre?.toLowerCase() ?? '';

    if (bpm >= 140) {
      energy = 0.9;
    } else if (bpm >= 120) {
      energy = 0.7;
    } else if (bpm >= 100) {
      energy = 0.5;
    } else if (bpm >= 80) {
      energy = 0.35;
    } else {
      energy = 0.2;
    }

    if (genre.contains('metal') ||
        genre.contains('punk') ||
        genre.contains('hardcore')) {
      energy = min(1.0, energy + 0.2);
    } else if (genre.contains('electronic') ||
        genre.contains('edm') ||
        genre.contains('dance')) {
      energy = min(1.0, energy + 0.15);
    } else if (genre.contains('ballad') ||
        genre.contains('acoustic') ||
        genre.contains('ambient')) {
      energy = max(0.0, energy - 0.2);
    } else if (genre.contains('classical') || genre.contains('jazz')) {
      energy = max(0.0, energy - 0.1);
    }

    return energy.clamp(0.0, 1.0);
  }

  List<Song> generateQueue({
    required Song seedSong,
    required List<Song> availableSongs,
    int queueLength = 20,
    double energyVariation = 0.15,
    int bpmVariation = 15,
  }) {
    if (!_isInitialized || availableSongs.isEmpty) return [];

    final seedAnalysis = _analysisCache[seedSong.id];
    if (seedAnalysis == null) return [];

    final queue = <Song>[seedSong];
    final usedIds = <String>{seedSong.id};

    final candidates = availableSongs
        .where((s) => s.id != seedSong.id)
        .toList();

    for (int i = 0; i < queueLength - 1 && candidates.isNotEmpty; i++) {
      final lastSong = queue.last;
      final lastAnalysis = _analysisCache[lastSong.id];

      if (lastAnalysis == null) break;

      Song? bestMatch;
      double bestScore = -1;

      for (final candidate in candidates) {
        if (usedIds.contains(candidate.id)) continue;

        final candidateAnalysis = _analysisCache[candidate.id];
        if (candidateAnalysis == null) continue;

        final score = _calculateTransitionScore(
          lastAnalysis,
          candidateAnalysis,
          seedAnalysis,
          energyVariation,
          bpmVariation,
        );

        if (score > bestScore) {
          bestScore = score;
          bestMatch = candidate;
        }
      }

      if (bestMatch != null) {
        queue.add(bestMatch);
        usedIds.add(bestMatch.id);
      }
    }

    return queue;
  }

  double _calculateTransitionScore(
    SongAnalysis from,
    SongAnalysis to,
    SongAnalysis seed,
    double energyVariation,
    int bpmVariation,
  ) {
    double score = 0.0;

    final bpmDiff = (from.bpm - to.bpm).abs();
    if (bpmDiff <= bpmVariation) {
      score += 1.0 - (bpmDiff / bpmVariation);
    }

    final energyDiff = (from.energy - to.energy).abs();
    if (energyDiff <= energyVariation) {
      score += 1.0 - (energyDiff / energyVariation);
    }

    final seedBpmDiff = (seed.bpm - to.bpm).abs();
    if (seedBpmDiff <= bpmVariation * 2) {
      score += 0.5 * (1.0 - (seedBpmDiff / (bpmVariation * 2)));
    }

    if (from.genre != null &&
        to.genre != null &&
        from.genre!.toLowerCase() == to.genre!.toLowerCase()) {
      score += 0.5;
    }

    if (from.year != null && to.year != null) {
      final yearDiff = (from.year! - to.year!).abs();
      if (yearDiff <= 5) {
        score += 0.3 * (1.0 - (yearDiff / 5));
      }
    }

    score += Random().nextDouble() * 0.2;

    return score;
  }

  Future<void> clearCache() async {
    final keys = _prefs?.getKeys().where((k) => k.startsWith('autodj_')) ?? [];
    for (final key in keys) {
      await _prefs?.remove(key);
      await _prefs?.remove('${key}_bpm');
      await _prefs?.remove('${key}_energy');
      await _prefs?.remove('${key}_genre');
      await _prefs?.remove('${key}_year');
      await _prefs?.remove('${key}_duration');
      await _prefs?.remove('${key}_valence');
      await _prefs?.remove('${key}_danceability');
    }
    _analysisCache.clear();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // ML-Powered Mode
  // ──────────────────────────────────────────────────────────────────────────

  Future<List<Song>> _getMlPoweredSongs(
    Song? currentSong,
    Set<String> existingIds,
    List<Song>? availableSongs,
  ) async {
    final List<Song> results = [];

    // П4: было 3k pool → OOM. Стало 700 стратифицированных + excludeIds против повторов.
    // Разнообразие дает RANDOM каждый вызов + фильтр existingIds/_recentlyAddedIds, а не размер пула.
    List<Song>? hybridPool;
    if (_recommendationService != null && (availableSongs == null || availableSongs.length > 800)) {
      try {
        final exclude = <String>{...existingIds, ..._recentlyAddedIds}.toList();
        // Mood-aware DB prefilter if mood active
        if (_currentMood != null) {
          hybridPool = await _recommendationService!.getMoodPool(_currentMood!, limit: 700);
          if (hybridPool.isEmpty) {
            hybridPool = await _recommendationService!.getSongsForMixHybrid(mood: _currentMood, limit: 700, excludeIds: exclude);
          }
        }
        if (hybridPool == null || hybridPool.isEmpty) {
          hybridPool = await _recommendationService!.getNotPlayedPool(limit: 700);
          if (hybridPool.isEmpty) {
            hybridPool = await _recommendationService!.getSongsForMixHybrid(limit: 700, excludeIds: exclude);
          }
        }
        if (hybridPool.isNotEmpty) {
          // Filter hybrid pool with existingIds in-memory (small pool, fast)
          hybridPool = hybridPool.where((s) => !_isKnown(s, existingIds) && !_recentlyAddedIds.contains(s.id) && !_recentlyAddedIds.contains(s.queueKey)).toList();
        }
      } catch (_) {}
    }

    // Use recommendation service to score and rank songs
    if (_recommendationService != null && (hybridPool != null || availableSongs != null)) {
      final sourcePool = hybridPool ?? availableSongs!;
      final candidates = sourcePool
          .where((s) => !_isKnown(s, existingIds) && !_recentlyAddedIds.contains(s.id) && !_recentlyAddedIds.contains(s.queueKey))
          .toList();

      final scored = _recommendationService!.getPersonalizedFeed(
        candidates,
        limit: _songsToAdd * 3,
      );

      // Apply mood filtering if set
      final moodFiltered = _currentMood != null
          ? applyMoodFilter(scored, _currentMood!)
          : scored;

      // Alchemy: mood of last 10 tracks influences next picks
      List<Song> alchemyRanked = moodFiltered;
      // Try to build alchemy profile from availableSongs as queue proxy
      final alchemyProfile = _buildRecentAlchemyProfile(availableSongs, availableSongs?.indexWhere((s) => currentSong != null && s.id == currentSong.id));
      if (alchemyProfile != null && moodFiltered.length > 5) {
        alchemyRanked = _applyAlchemyRanking(moodFiltered, alchemyProfile);
      }

      // Apply BPM/energy smoothing from current song if available
      if (currentSong != null && _analysisCache.containsKey(currentSong.id)) {
        final smoothed = _smoothTransitions(currentSong, alchemyRanked);
        alchemyRanked = smoothed;
      }

      // Orchestrator: arrange for smooth energy/mood transitions
      if (alchemyRanked.length > 2) {
        alchemyRanked = PlaylistOrchestrator.orchestrate(alchemyRanked, startWith: 'mixed', endWith: 'mixed');
      }

      results.addAll(alchemyRanked.take(_songsToAdd));
    }

    // Fallback: if ML results are insufficient, supplement with genre-based
    if (results.length < _songsToAdd && currentSong?.genre != null) {
      final genreSongs = await _getSameGenreSongs(
        currentSong!.genre!,
        existingIds..addAll(results.map((s) => s.id))..addAll(results.map((s) => s.queueKey)),
      );
      results.addAll(genreSongs.take(_songsToAdd - results.length));
    }

    // Final fallback: random
    if (results.isEmpty) {
      return await _getShuffledLibrarySongs(existingIds);
    }

    for (final song in results) {
      _recentlyAddedIds.add(song.id);
      _recentlyAddedIds.add(song.queueKey);
      if (_recentlyAddedIds.length > _maxRecentlyAdded * 2) {
        _recentlyAddedIds.remove(_recentlyAddedIds.first);
      }
    }
    _persistRecentlyAdded();

    return results;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Music Alchemy: mood of last 10 tracks + orchestration for smooth flow
  // ──────────────────────────────────────────────────────────────────────────

  /// Build vibe profile from last 10 tracks in queue / recent plays
  VibeFeatures? _buildRecentAlchemyProfile(List<Song>? currentQueue, int? currentIndex) {
    final vibe = VibeSimilarity();
    List<Song> recent = [];
    // Prefer queue window around currentIndex (guard: index must be valid,
    // indexWhere returns -1 when the song is not in the pool).
    if (currentQueue != null && currentQueue.isNotEmpty && currentIndex != null && currentIndex >= 0) {
      final start = (currentIndex - 10).clamp(0, currentQueue.length);
      final end = currentIndex.clamp(0, currentQueue.length);
      recent = currentQueue.sublist(start, end);
      // If at start of queue, also include upcoming 2 to fill to 5 minimum
      if (recent.length < 5 && currentQueue.length > currentIndex + 2) {
        final extra = currentQueue.sublist(currentIndex, (currentIndex + 3).clamp(0, currentQueue.length));
        recent = [...recent, ...extra];
      }
    }
    // Fallback to ML recentlyPlayed
    if (recent.length < 5 && _recommendationService != null) {
      final recentIds = _recommendationService!.recentlyPlayed.take(10).toList();
      if (recentIds.isNotEmpty && currentQueue != null) {
        final byId = {for (final s in currentQueue) s.id: s};
        // Try to map via availableSongs if provided via next call, else use queue
        final mapped = recentIds.map((id) => byId[id]).whereType<Song>().toList();
        if (mapped.length >= 5) recent = mapped;
      }
    }
    if (recent.length < 3) return null;
    double e = 0, va = 0, d = 0, b = 0, ac = 0, inst = 0;
    for (final s in recent) {
      final f = vibe.analyzeTrack(s);
      e += f.energy; va += f.valence; d += f.danceability; b += f.bpm; ac += f.acousticness; inst += f.instrumentalness;
    }
    final n = recent.length.toDouble();
    return VibeFeatures(energy: e / n, valence: va / n, danceability: d / n, bpm: b / n, acousticness: ac / n, instrumentalness: inst / n);
  }

  /// Re-rank candidates by similarity to recent alchemy profile (last 10 mood)
  List<Song> _applyAlchemyRanking(List<Song> candidates, VibeFeatures alchemyProfile) {
    final vibe = VibeSimilarity();
    final scored = candidates.map((s) {
      final f = vibe.analyzeTrack(s);
      final sim = vibe.vibeSimilarity(alchemyProfile, f); // 0..1
      // Bonus up to 0.35 for alchemy similarity
      return MapEntry(s, sim);
    }).toList()..sort((a, b) => b.value.compareTo(a.value));
    // Keep top 70% by alchemy similarity to preserve mood continuity while keeping base ML ranking
    final keep = (scored.length * 0.7).ceil().clamp(5, scored.length);
    final filtered = scored.take(keep).map((e) => e.key).toList();
    // Blend: 60% alchemy similarity + 40% original order (already scored by ML)
    // Re-sort filtered by blended score
    final blended = filtered.map((s) {
      final f = vibe.analyzeTrack(s);
      final sim = vibe.vibeSimilarity(alchemyProfile, f);
      final origIdx = candidates.indexOf(s);
      final origScore = 1.0 - (origIdx / candidates.length);
      final score = sim * 0.6 + origScore * 0.4 + Random().nextDouble() * 0.05;
      return MapEntry(s, score);
    }).toList()..sort((a, b) => b.value.compareTo(a.value));
    return blended.map((e) => e.key).toList();
  }

  List<Song> applyMoodFilter(List<Song> songs, String mood) {
    // 1) First prefer DB mood tag if present (metadata mood column) — exact match fast path
    final moodTagged = songs.where((s) => s.mood != null && s.mood!.toLowerCase() == mood.toLowerCase()).toList();
    if (moodTagged.length >= 5) return moodTagged;
    // 2) Map moods to energy/valence ranges for filtering (fallback)
    switch (mood) {
      case 'energetic':
        return songs.where((s) {
          if (s.mood != null && s.mood!.toLowerCase() == mood) return true;
          final a = _analysisCache[s.id];
          if (a == null) return true;
          return a.energy >= 0.6 || a.bpm >= 120;
        }).toList();
      case 'calm':
        return songs.where((s) {
          if (s.mood != null && s.mood!.toLowerCase() == mood) return true;
          final a = _analysisCache[s.id];
          if (a == null) return true;
          return a.energy <= 0.5 && a.bpm <= 110;
        }).toList();
      case 'happy':
        return songs.where((s) {
          if (s.mood != null && s.mood!.toLowerCase() == mood) return true;
          final a = _analysisCache[s.id];
          if (a == null) return true;
          return (a.valence ?? 0.5) >= 0.5 || a.energy >= 0.5;
        }).toList();
      case 'sad':
        return songs.where((s) {
          if (s.mood != null && s.mood!.toLowerCase() == mood) return true;
          final a = _analysisCache[s.id];
          if (a == null) return true;
          return (a.valence ?? 0.5) <= 0.4 || a.energy <= 0.4;
        }).toList();
      default:
        // Custom mood tag (e.g. "chill", "dark") — exact mood match if available
        if (moodTagged.isNotEmpty) return moodTagged;
        return songs;
    }
  }

  List<Song> _smoothTransitions(Song currentSong, List<Song> candidates) {
    final currentAnalysis = _analysisCache[currentSong.id];
    if (currentAnalysis == null) return candidates;

    final recentIds = _recommendationService != null
        ? _recommendationService!.recentlyPlayed.take(15).toSet()
        : <String>{};

    final scored = candidates.map((s) {
      final a = _analysisCache[s.id];
      if (a == null) return MapEntry(s, 0.5);

      double score = 0.0;

      // BPM proximity (prefer similar tempo)
      final bpmDiff = (currentAnalysis.bpm - a.bpm).abs().toDouble();
      score += max(0, 1.0 - bpmDiff / 40) * 0.3;

      // Energy proximity
      final energyDiff = (currentAnalysis.energy - a.energy).abs();
      score += max(0, 1.0 - energyDiff * 2) * 0.25;

      // Genre match bonus
      if (currentAnalysis.genre != null &&
          a.genre != null &&
          currentAnalysis.genre!.toLowerCase() == a.genre!.toLowerCase()) {
        score += 0.2;
      }

      // Valence proximity for mood continuity
      if (currentAnalysis.valence != null && a.valence != null) {
        final valDiff = (currentAnalysis.valence! - a.valence!).abs();
        score += max(0, 1.0 - valDiff * 2) * 0.15;
      }

      // Push recently-played tracks down so mixes feel fresh.
      if (recentIds.contains(s.id)) score -= 0.5;

      // Random jitter (bigger than before so ordering varies between runs)
      score += Random().nextDouble() * 0.35;

      return MapEntry(s, score);
    }).toList();

    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.map((e) => e.key).toList();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Mood-based Instant Mix
  // ──────────────────────────────────────────────────────────────────────────

  Future<List<Song>> getInstantMix({
    required Song seedSong,
    required int count,
    String? mood,
    List<Song>? availableSongs,
  }) async {
    if (_subsonicService == null) return [];

    final Set<String> excludeIds = {seedSong.id, seedSong.queueKey};
    final List<Song> results = [seedSong];

    // Recency penalty: recently-played tracks shouldn't dominate the mix.
    final Set<String> recentIds = _recommendationService != null
        ? _recommendationService!.recentlyPlayed.take(20).toSet()
        : <String>{};

    // Gather candidates from multiple sources in parallel
    final List<Future<List<Song>>> futures = [];

    // Similar songs
    futures.add(_subsonicService!.getSimilarSongs(
      seedSong.id,
      count: count * 3,
    ));

    // Genre-based
    if (seedSong.genre != null) {
      futures.add(_subsonicService!.getSongsByGenre(
        seedSong.genre!,
        count: count * 2,
      ));
    }

    // ML recommendations from available library (taste-aware diversity)
    if (_recommendationService != null && availableSongs != null) {
      final candidates = availableSongs
          .where((s) => !excludeIds.contains(s.id))
          .toList();
      final recs = _recommendationService!.getPersonalizedFeed(
        candidates,
        limit: count * 3,
      );
      futures.add(Future.value(recs));
    }

    // Interleave sources round-robin from a random starting source so the
    // mix isn't always dominated by the same source order.
    final random = Random();
final bannedArtists = MLService().profile.bannedArtists.toSet();
    final bannedArtistNamesLower = MLService().profile.bannedArtistNames.values.map((n) => n.toLowerCase()).toSet();
    final dislikedSongs = MLService().profile.dislikedSongs.toSet();
    // Each source gets its own timeout: slow sources (e.g. a cold Subsonic
    // server when the Yandex/MTS integrations are off) return empty instead
    // of blocking the whole mix, while fast sources keep their results.
    final timed = futures.map((f) {
      return f
          .timeout(const Duration(seconds: 12))
          .catchError((_) => const <Song>[]);
    }).toList();
    final allResults = await Future.wait(timed);

    final sources = allResults
        .map((l) => l.where((s) {
              if (excludeIds.contains(s.id) || excludeIds.contains(s.queueKey)) return false;
              if (_recentlyAddedIds.contains(s.id) || _recentlyAddedIds.contains(s.queueKey)) return false;
              if (dislikedSongs.contains(s.id)) return false;
              if (s.artistId != null && bannedArtists.contains(s.artistId)) return false;
              if (s.artist != null && bannedArtistNamesLower.contains(s.artist!.toLowerCase())) return false;
              return true;
            }).toList())
        .where((l) => l.isNotEmpty)
        .toList();
    sources.shuffle(random);

    var sourceIndex = 0;
    var tookAny = true;
    while (tookAny && results.length <= count * 2) {
      tookAny = false;
      for (var i = 0; i < sources.length; i++) {
        final list = sources[(sourceIndex + i) % sources.length];
        if (list.isEmpty) continue;
        final song = list.removeAt(0);
        // Heavy penalty for recently-played tracks; skip them when possible.
        if (recentIds.contains(song.id)) continue;
        if (excludeIds.contains(song.id) || excludeIds.contains(song.queueKey)) continue;
        excludeIds.add(song.id);
        excludeIds.add(song.queueKey);
        results.add(song);
        tookAny = true;
      }
      sourceIndex = (sourceIndex + 1) % sources.length;
    }

    // Apply mood filter
    if (mood != null) {
      final moodFiltered = applyMoodFilter(results.sublist(1), mood);
      return [seedSong, ...moodFiltered.take(count)];
    }

    // Smooth transitions from seed song
    final smoothed = _smoothTransitions(seedSong, results.sublist(1));
    return [seedSong, ...smoothed.take(count)];
  }
}
