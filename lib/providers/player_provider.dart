import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;

import 'package:audio_session/audio_session.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../services/safe_image_cache_manager.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import '../models/models.dart';
import '../services/subsonic_service.dart';
import '../services/audiobookshelf_service.dart';
import '../services/offline_service.dart';
import '../services/android_auto_service.dart';
import '../services/android_system_service.dart';
import '../services/windows_system_service.dart';
import '../services/bluetooth_avrcp_service.dart';
import '../services/samsung_integration_service.dart';
import '../services/recommendation_service.dart';
import '../services/replay_gain_service.dart';
import '../services/equalizer_service.dart';
import '../services/auto_dj_service.dart';
import '../services/discord_rpc_service.dart';
import '../services/storage_service.dart';
import '../services/cast_service.dart';
import '../services/library_database_service.dart';
import '../services/upnp_service.dart';
import '../services/local_file_server.dart';
import '../services/jukebox_service.dart';
import '../services/audio_handler.dart';
import '../services/fade_settings_service.dart';
import '../services/lock_screen_lyrics_service.dart';
import '../services/transcoding_service.dart';
import '../services/local_music_service.dart';
import '../services/ml_service.dart';
import '../services/local_analytics_service.dart';
import '../services/playlist_orchestrator.dart';
import '../services/ml/ml_store.dart';
import '../services/ml/vibe_similarity.dart';
import '../services/ml/mood_drift_detector.dart';
import '../services/ml/behavior_tracker.dart';
import '../services/ml/multi_armed_bandit.dart';
import '../services/ml/sonic_fingerprint.dart';
import '../services/ml/ml_wave_service.dart';
import '../services/ml/smart_auto_dj.dart';
import '../services/ml/time_aware_history.dart';
import '../services/ml/track_scorer.dart';
import '../services/ml/explainable_ai.dart';
import '../services/ml/item_similarity.dart';
import '../services/collab/multi_server_resolver.dart';
import '../services/theme_service.dart';
import '../services/bpm_crossfade_service.dart';
import '../providers/library_provider.dart';
import '../widgets/home_widget_provider.dart';
import '../services/kumaflow_brain/kumaflow_brain_wave_resolver.dart';
import '../services/kumaflow_brain/kumaflow_brain_mapper.dart';
import '../services/wave_identity.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

// Распил god-object: домены живут в part-файлах (та же библиотека —
// приватные поля/методы доступны без реэкспорта, поведение не меняется).
// Части добавляются по мере выноса (player_brain — первая).
part 'player/player_brain.dart';
part 'player/player_sleep_timer.dart';
part 'player/player_watchdog.dart';
part 'player/player_discord.dart';
part 'player/player_abs.dart';
part 'player/player_queue_store.dart';
part 'player/player_history.dart';
part 'player/player_jukebox.dart';
part 'player/player_android_auto.dart';
part 'player/player_radio.dart';
part 'player/player_fades.dart';
part 'player/player_sources.dart';
part 'player/player_wave.dart';
part 'player/player_cast.dart';
part 'player/player_live.dart';

// Isolate helpers — heavy JSON must not block UI.
// Важно: через compute() можно гонять только plain-data (Map/List/числа),
// объекты Song SendPort не принимает — поэтому вход/выход строго JSON.
List<Song> _deserializeQueueIsolate(List<dynamic> jsonList) =>
    jsonList.map((j) => Song.fromJson(j as Map<String, dynamic>)).toList();
List<Map<String, dynamic>> _filterLocalSongsIsolate(
    List<Map<String, dynamic>> jsonList) {
  final kept = jsonList
      .map((j) => Song.fromJson(j))
      .where((s) {
        if (s.isLocal && s.path != null) {
          try {
            return File(s.path!).existsSync();
          } catch (_) {
            return false;
          }
        }
        return true;
      })
      .toList();
  return kept.map((s) => s.toJson()).toList();
}

enum RepeatMode { off, all, one }

class PlayerProvider extends ChangeNotifier with WidgetsBindingObserver {
  final SubsonicService _subsonicService;
  late final StorageService _storageService;
  final KumaFlowAudioHandler _audioHandler;
  // Convenience getter — use this everywhere just_audio is accessed directly.
  AudioPlayer get _audioPlayer => _audioHandler.player;
  final OfflineService _offlineService = OfflineService();
  // Бесшовные переходы онлайн<->офлайн: следим за флагом сети.
  bool _wasOfflineMode = false;
  final AndroidAutoService _androidAutoService = AndroidAutoService();
  final AndroidSystemService _androidSystemService = AndroidSystemService();
  final WindowsSystemService _windowsService = WindowsSystemService();
  final BluetoothAvrcpService _bluetoothService = BluetoothAvrcpService();
  final SamsungIntegrationService _samsungService = SamsungIntegrationService();
  final ReplayGainService _replayGainService = ReplayGainService();
  final AutoDjService _autoDjService = AutoDjService();
  final MLService _mlService = MLService();
  late final MLStore _mlStore;
  late final VibeSimilarity _vibeSimilarity;
  late final MoodDriftDetector _moodDriftDetector;
  late final BehaviorTracker _behaviorTracker;
  late final MultiArmedBandit _multiArmedBandit;
  late final SonicFingerprintService _sonicFingerprint;
  late final MLWaveService _mlWaveService;
  late final SmartAutoDJ _smartAutoDJ;
  late final TimeAwareHistory _timeAwareHistory;
  late final ItemSimilarityService _itemSimilarity;
  late final TrackScorer _trackScorer;
  late final ExplainableAI _explainableAI;
  late final DiscordRpcService _discordRpcService;
  final CastService _castService;
  late final UpnpService _upnpService;
  CastService get castService => _castService;
  UpnpService get upnpService => _upnpService;
  final LockScreenLyricsService _lyricsService = LockScreenLyricsService();
  LibraryProvider? _libraryProvider;
  RecommendationService? _recommendationService;
  // KumaFlow Brain: опциональный best-effort мост. null = выключен.
  // Поле здесь; методы зеркала — в part player/player_brain.dart.
  dynamic _brain;
  // Signal guards: one seek-back log per played track; skip-logged tracks
  // must not also count as abandoned when the next song starts.
  String? _seekBackLoggedSongId;
  String? _lastSkipLoggedId;
  // Dedup for _trackPlay: gapless index events must not double-count a track
  // that playSong() already tracked (same queueKey within 10s).
  String? _lastTrackPlayKey;
  int _lastTrackPlayMs = 0;
  // Collab / multi-server resolver (stream/cover/scrobble по серверу трека).
  late final MultiServerResolver _multiServerResolver;
  MultiServerResolver get multiServerResolver => _multiServerResolver;

  List<Song> _queue = [];
  int _currentIndex = -1;
  /// Имя очереди для шапки (порт songlist.currentPlaylistName с десктопа).
  /// null = неизвестно → шапка решает по радио/волне, иначе «Моя коллекция».
  String? _currentQueueName;
  String? _currentQueueHint;
  String? get currentQueueName => _currentQueueName;
  String? get currentQueueHint => _currentQueueHint;

  /// Сид-подпись («В стиле: …» / «По треку: …») — заголовок сам по себе.
  static bool _isSeedName(String? name) {
    final n = (name ?? '').toLowerCase().trim();
    return n.startsWith('в стиле') || n.startsWith('по треку');
  }

  /// Явно задать контекст очереди (плейлист/волна/микс/радио).
  /// Пустое имя стирает контекст.
  void setQueueContext({String? playlistName, String? hint}) {
    if (playlistName != null && playlistName.trim().isEmpty) {
      _currentQueueName = null;
    } else if (playlistName != null) {
      _currentQueueName = playlistName;
    }
    if (hint != null) _currentQueueHint = hint.isEmpty ? null : hint;
  }

  bool _isPlaying = false;
  bool _isLoading = false;
  // Сторож мертвого стрима: трек встал (403/обрыв/вечный buffering) —
  // перепрыгиваем дальше вместо тишины.
  Timer? _watchdogTimer;
  Duration _watchdogPosition = Duration.zero;
  int _stallTicks = 0;
  int _consecutiveStreamFailures = 0;
  DateTime? _lastPlayingTime;
  DateTime? _lastUserStopTime;
  final Set<String> _deadStreamKeys = {};
  bool _shuffleEnabled = false;
  bool _gaplessEnabled = true;
  final List<String> _shuffleHistory = [];
  RepeatMode _repeatMode = RepeatMode.off;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Song? _currentSong;
  double _volume = 1.0;

  /// True only while audio is actually being rendered on a remote device.
  /// Distinct from isConnected: if the user plays a radio station while a
  /// UPnP renderer is connected, the audio is still local, so this stays false.
  bool _isRenderingRemotely = false;

  String? _resolvedArtworkUrl;

  bool _isHttpCover(String? s) => s != null && (s.startsWith('http://') || s.startsWith('https://'));

  String _resolveCoverUrl(String? coverArt, {int size = 300, Song? song}) {
    if (coverArt == null || coverArt.isEmpty) return '';
    if (_isHttpCover(coverArt)) return coverArt;
    if (coverArt.startsWith('abs:')) {
      return AudiobookshelfService().getCoverUrl(coverArt.substring(4), width: size);
    }
    // Collab: обложка с сервера-владельца трека.
    if (song != null && song.isRemoteCollab) {
      try {
        return _multiServerResolver.resolveCoverUrl(song, size: size);
      } catch (_) {}
    }
    return _subsonicService.getCoverArtUrl(coverArt, size: size);
  }

  /// Стабильное имя кэш-файла стрима. queueKey.hashCode нестабилен между
  /// запусками (коллизии -> чужой или обрезанный .tmp переиспользуется
  /// как «готовый» кэш, и трек обрывается через несколько секунд),
  /// поэтому кодируем сам ключ.
  String _streamCacheName(Song song) {
    final raw = base64Url.encode(utf8.encode(song.queueKey));
    final safe = raw.replaceAll('=', '');
    final short = safe.length > 48 ? safe.substring(0, 48) : safe;
    return 'kumaflow_stream_$short.tmp';
  }

  /// Удаляет обрезанный стрим-кеш трека (earlyEnded): без этого битый .tmp
  /// переиспользуется как готовый и трек вечно обрывается на ~7с.
  Future<void> _deleteTruncatedStreamCache(Song song) async {
    try {
      final cacheDir = await getTemporaryDirectory();
      final f = File('${cacheDir.path}/${_streamCacheName(song)}');
      if (await f.exists()) {
        await f.delete();
        debugPrint('[Player] deleted truncated stream cache for "${song.title}"');
      }
    } catch (e) {
      debugPrint('[Player] stream cache delete error: $e');
    }
  }

  /// Stream URL с учетом мульти-сервера (трек друга — URL его сервера).
  Future<String> resolvePlayUrl(Song song) async {    if (song.isLocal == true) return song.path ?? '';
    final offlinePath = _offlineService.getLocalPath(song.queueKey);
    if (offlinePath != null) return 'file://$offlinePath';
    final legacyOffline = _offlineService.getLocalPath(song.id);
    if (legacyOffline != null) return 'file://$legacyOffline';
    final tActive =
        _transcodingService.enabled || _transcodingService.smartEnabled;
    final maxBitRate =
        tActive ? _transcodingService.currentBitRate : null;
    final format =
        tActive ? _transcodingService.format : null;
    try {
      return await _multiServerResolver.resolveStreamUrl(song,
          maxBitRate: maxBitRate, format: format);
    } catch (_) {}
    return _subsonicService.getStreamUrl(song.id,
        maxBitRate: maxBitRate, format: format);
  }

  RadioStation? _currentRadioStation;
  bool _isPlayingRadio = false;

  bool _hasPlayedOnce = false;

  final _db = LibraryDatabaseService();
  Timer? _persistDebounceTimer;

  final bool _reactivatingSession = false;

  Timer? _sleepTimer;
  DateTime? _sleepTimerEnd;
  bool _sleepTimerEndCurrentSong = false;
  bool _sleepTimerFadeOut = false;
  int _sleepTimerFadeDurationSeconds = 30;
  Timer? _sleepTimerFadeTimer;
  Timer? _sleepTimerFadePeriodicTimer;
  Timer? _jukeboxPollTimer;

  // ── ABS book sync (Lissen-style: 15s / 5s near edges + coalescing) ────────
  Timer? _absSyncTimer;
  String? _absBookId;
  List<dynamic> _absChaptersRaw = []; // keep raw for offset calc, also typed
  List<BookChapter> _absChaptersTyped = [];
  double _absTotalDuration = 0;
  double _absLastSyncAbsTime = 0;
  int _absUnsyncedMs = 0;
  int? _absPlayingSinceMs;
  bool _absIsSyncing = false;
  bool _absSyncPending = false;

  // Fade in/out
  final FadeSettingsService _fadeSettingsService = FadeSettingsService();
  Timer? _fadeTimer;
  bool _isFading = false;
  Timer? _nowPlayingTimer;

  final JukeboxService _jukeboxService;
  final TranscodingService _transcodingService;

  double _playbackSpeed = 1.0;
  double _pitch = 1.0;
  bool _pitchCorrection = true;

  PlayerProvider(
    this._subsonicService,
    StorageService storageService,
    this._castService,
    this._upnpService,
    this._audioHandler,
    this._jukeboxService,
    this._transcodingService,
  ) {
    _storageService = storageService;
    _discordRpcService = DiscordRpcService(storageService);
    // Collab / multi-server: резолвер stream/cover URL по серверу-владельцу.
    _multiServerResolver = MultiServerResolver(_subsonicService);

    // Initialize ML engine services
    _mlStore = MLStore();
    _mlStore.init();
    _vibeSimilarity = VibeSimilarity();
    _moodDriftDetector = MoodDriftDetector();
    _behaviorTracker = BehaviorTracker();
    _multiArmedBandit = MultiArmedBandit();
    // Fan-out for cold-start answers: MLService.seedTaste writes to its own
    // profile + this mirror store + the shared bandit.
    _mlService.setMirrorStore(_mlStore);
    _mlService.setBandit(_multiArmedBandit);
    // Update path: users who passed cold start earlier have an empty bandit
    // (it was in-memory). Backfill arms from existing profiles; loads the
    // persisted bandit first. Fire-and-forget.
    _mlService.backfillBanditFromProfiles();
    _sonicFingerprint = SonicFingerprintService();
    // TimeAwareHistory must exist before TrackScorer (passed as timeHistory).
    _timeAwareHistory = TimeAwareHistory();
    _timeAwareHistory.load();
    _moodDriftDetector.load();
    _trackScorer = TrackScorer(_vibeSimilarity, timeHistory: _timeAwareHistory);
    _explainableAI = ExplainableAI();
    _mlWaveService = MLWaveService(
      _mlStore,
      _subsonicService,
      behaviorTracker: _behaviorTracker,
      timeAwareHistory: _timeAwareHistory,
      sonicFingerprint: _sonicFingerprint,
    );
    _smartAutoDJ = SmartAutoDJ(_mlWaveService, _mlStore);

    _castService.addListener(_onCastStateChanged);
    _upnpService.addListener(_onUpnpStateChanged);
    _upnpService.onRendererLost = _onUpnpRendererLost;
    _jukeboxService.addListener(_onJukeboxEnabledChanged);
    // Переходы сети: уход в офлайн — ничего не рвём, возврат — мягкий досинк.
    _wasOfflineMode = _offlineService.isOfflineMode;
    _offlineService.addListener(_onOfflineModeChanged);
    _initializePlayer();
    _onJukeboxEnabledChanged();
    try {
      _initializeAndroidAuto();
    } catch (_) {}
    try {
      _initializeSystemServices();
    } catch (_) {}
    _initializeAutoDj();
    _wireAudioHandlerCallbacks();
    try {
      _initializeLyricsService();
    } catch (_) {}

    // Route home-screen widget button presses to the player.
    if (!kIsWeb && Platform.isAndroid) {
      HomeWidgetProvider.init();
      HomeWidgetProvider.setActionHandler((action) {
        switch (action) {
          case 'playPause':
            togglePlayPause();
          case 'next':
            skipNext();
          case 'previous':
            skipPrevious();
          case 'like':
            if (_currentSong != null) {
              toggleFavoriteForSong(_currentSong!);
            }
          case 'dislike':
            if (_currentSong != null) {
              final s = _currentSong!;
              unawaited(dislikeAndSkip(s));
            }
        }
      });
    }

    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      try {
        _discordRpcService.initialize();
      } catch (_) {}
      try {
        loadDiscordRpcStateStyle();
      } catch (_) {}
    }

    // Defer heavy queue restore to after first frame to avoid cold-start ANR (WindowManager Waiting for drawn timeout)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 800), () => _restoreQueueState());
    });

    // Register app lifecycle observer to save state on iOS when app goes to background
    WidgetsBinding.instance.addObserver(this);
  }

  /// Handle app lifecycle changes - save queue state when going to background (important for iOS)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      debugPrint(
          '[Player] App lifecycle state: $state - saving queue state immediately');
      _saveQueueStateImmediate();
      _flushAbsSync(force: true);
    } else if (state == AppLifecycleState.resumed) {
      // Resume sync timer if playing ABS book
      if (_absBookId != null && _isPlaying) _startAbsSyncTimer();
    }
  }

  // ABS Sync (книги/главы): методы — в part player/player_abs.dart.

  void _startNowPlayingTimer() {
    _nowPlayingTimer?.cancel();
    _nowPlayingTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!_isPlaying || _currentSong == null || _currentSong!.isLocal == true) return;
      if (_isPodcastSong(_currentSong)) return;
      if (_offlineService.isOfflineMode) return;
      try {
        await _subsonicService.scrobble(_currentSong!.id, submission: false);
        unawaited(_offlineService.flushPendingScrobbles(_subsonicService));
      } catch (e) {
        _offlineService.queueScrobble(_currentSong!.id, submission: false);
      }
    });
  }

  void _stopNowPlayingTimer() {
    _nowPlayingTimer?.cancel();
    _nowPlayingTimer = null;
  }

  // ABS-геттеры времени/прогресса — в part player/player_abs.dart.

  /// Connect [KumaFlowAudioHandler] lock-screen commands back to this provider.
  /// On iOS these come via [audio_service] instead of [iOSSystemPlugin].
  void _wireAudioHandlerCallbacks() {
    _audioHandler.onPlay = play;
    _audioHandler.onPause = pause;
    _audioHandler.onStop = stop;
    _audioHandler.onSkipNext = skipNext;
    _audioHandler.onSkipPrevious = skipPrevious;
    _audioHandler.onSeekTo = seek;
    _audioHandler.onTogglePlayPause = togglePlayPause;
    _audioHandler.onToggleFavorite = () => toggleFavorite();
  }

  // ── Persistent Queue ───────────────────────────────────────────────────────

  // Персист очереди: методы — в part player/player_queue_store.dart.

  // ── Jukebox mode ──

  // Jukebox mode: методы — в part player/player_jukebox.dart.

  /// Переход сети без остановки музыки.
  /// Уход в офлайн: текущий стрим не рвём (доигрывает из буфера), виджет
  /// переводим на бейдж, дальше скипы сами обходят неиграемое.
  /// Возврат: тихо сливаем скробблы и планируем досинк библиотеки фоном.
  void _onOfflineModeChanged() {
    final offline = _offlineService.isOfflineMode;
    if (offline == _wasOfflineMode) return;
    _wasOfflineMode = offline;
    if (offline) {
      debugPrint('[Player] network lost — seamless offline, keep playing');
      notifyListeners();
      _preloadNextTracks();
    } else {
      debugPrint('[Player] network back — soft online refresh');
      _offlineService
          .flushPendingScrobbles(_subsonicService)
          .catchError((e) {
        debugPrint('Scrobble flush failed: $e');
      });
      notifyListeners();
      // Лёгкий рефреш сразу (фаза-2: списки/артисты/плейлисты), без полного
      // ресинка БД и без 5с задержки — поиск и артисты оживают мгновенно.
      // Музыку не трогаем: текущий стрим доигрывает.
      if (_libraryProvider != null) {
        _libraryProvider!.refreshOnline().catchError((e) {
          debugPrint('Online refresh failed: $e');
        });
      }
    }
  }

  /// Есть ли у трека локальный файл (играет без сети).
  bool _hasPlayableFile(Song s) {
    if (s.isLocal == true && s.path != null) {
      try {
        return File(s.path!).existsSync();
      } catch (_) {
        return false;
      }
    }
    return _offlineService.getLocalPath(s.queueKey) != null ||
        _offlineService.getLocalPath(s.id) != null;
  }

  /// Сетевые ошибки, при которых очередь не должна висеть на 0:00 —
  /// в офлайне такие треки пропускаем как неиграемые.
  bool _isNetworkUnplayable(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('socketexception') ||
        msg.contains('failed host lookup') ||
        msg.contains('connection') ||
        msg.contains('timed out') ||
        msg.contains('timeoutexception') ||
        msg.contains('network error') ||
        msg.contains('cannot connect') ||
        msg.contains('http 404') ||
        msg.contains('http 500') ||
        msg.contains('server error');
  }

  void setLibraryProvider(LibraryProvider libraryProvider) {
    _libraryProvider = libraryProvider;
  }

  void setRecommendationService(RecommendationService recommendationService) {
    _recommendationService = recommendationService;
    // Feed the sonic fingerprint into the recommendation scoring so home &
    // mixes playlists reward tracks that sound like what the user listens to.
    recommendationService.setSonicFingerprint(_sonicFingerprint);
    // Feed the multi-armed bandit's learned artist/genre preferences into
    // the recommendation scoring (read-only top-arm boost, no extra pulls).
    recommendationService.setMultiArmedBandit(_multiArmedBandit);
    // Feed time-of-day history and mood-drift state into the recommendation
    // scoring so home & mixes reflect hour-of-day tastes and short-lived
    // skip-triggered bans.
    recommendationService.setTimeAwareHistory(_timeAwareHistory);
    recommendationService.setMoodDriftDetector(_moodDriftDetector);
    _autoDjService.setServices(_subsonicService, recommendationService);
  }

  void setLocalMusicService(LocalMusicService localMusicService) {
    _autoDjService.setServices(
      _subsonicService,
      _recommendationService,
      localMusicService: localMusicService,
    );
  }

  AutoDjService get autoDjService => _autoDjService;
  LockScreenLyricsService get lyricsService => _lyricsService;

  Future<void> _initializeAutoDj() async {
    await _autoDjService.initialize();
    _autoDjService.setServices(_subsonicService, _recommendationService);
  }

  Future<void> _initializeLyricsService() async {
    await _lyricsService.initialize();
  }

  Future<void> _initializeSystemServices() async {
    await _androidSystemService.initialize();
    _androidSystemService.onPlay = play;
    _androidSystemService.onPause = pause;
    _androidSystemService.onStop = stop;
    _androidSystemService.onSkipNext = skipNext;
    _androidSystemService.onSkipPrevious = skipPrevious;
    _androidSystemService.onSeekTo = seek;
    _androidSystemService.onSeekForward =
        (interval) => seek(_position + interval);
    _androidSystemService.onSeekBackward = (interval) {
      final target = _position - interval;
      seek(target.isNegative ? Duration.zero : target);
    };
    _androidSystemService.onHeadsetHook = togglePlayPause;
    _androidSystemService.onHeadsetDoubleClick = skipNext;

    await _windowsService.initialize();
    _windowsService.onPlay = play;
    _windowsService.onPause = pause;
    _windowsService.onStop = stop;
    _windowsService.onSkipNext = skipNext;
    _windowsService.onSkipPrevious = skipPrevious;
    _windowsService.onSeekTo = seek;

    // Audio focus and noisy callbacks must be no-ops in remote-playback mode.
    // The audio is playing on the renderer device, not on this phone, so
    // Android reassigning audio focus at screen-off (or a noisy event) must
    // not pause the renderer.
    _androidSystemService.onAudioFocusLoss = () {
      if (isRemotePlayback) return;
      pause();
    };
    _androidSystemService.onAudioFocusLossTransient = () {
      if (isRemotePlayback) return;
      pause();
    };
    _androidSystemService.onAudioFocusLossTransientCanDuck = () {
      if (isRemotePlayback) return;
      _smoothVolumeChange(0.3);
    };
    _androidSystemService.onAudioFocusGain = () {
      if (isRemotePlayback) return;
      _smoothVolumeChange(_volume);
    };
    _androidSystemService.onBecomingNoisy = () {
      if (isRemotePlayback) return;
      pause();
    };

    await _bluetoothService.initialize();
    _bluetoothService.onPlay = play;
    _bluetoothService.onPause = pause;
    _bluetoothService.onStop = stop;
    _bluetoothService.onSkipNext = skipNext;
    _bluetoothService.onSkipPrevious = skipPrevious;
    _bluetoothService.onSeekTo = seek;
    _bluetoothService.onDeviceConnected = (device) {
      debugPrint('Bluetooth device connected: ${device.name}');
      // AVRCP support means the device can handle audio controls, which is
      // a reliable proxy for A2DP audio output (watches/controllers don't
      // advertise AVRCP). Re-query isA2dpConnected for ground truth.
      _bluetoothService.isA2dpConnected().then((active) {
        _isA2dpAudioActive = active;
        debugPrint('Bluetooth A2DP audio active: $_isA2dpAudioActive');
      });
      _updateAllServices();
    };
    _bluetoothService.onDeviceDisconnected = (device) {
      debugPrint('Bluetooth device disconnected: ${device.name}');
      _bluetoothService.isA2dpConnected().then((active) {
        _isA2dpAudioActive = active;
        debugPrint('Bluetooth A2DP audio active: $_isA2dpAudioActive');
      });
    };

    _bluetoothService.registerAbsoluteVolumeControl();

    _samsungService.initialize();
    _samsungService.onDexModeEnter = () {
      debugPrint('Entered Samsung DeX mode');
      notifyListeners();
    };
    _samsungService.onDexModeExit = () {
      debugPrint('Exited Samsung DeX mode');
      notifyListeners();
    };
    _samsungService.onEdgePanelAction = (action) {
      switch (action) {
        case 'play':
          play();
          break;
        case 'pause':
          pause();
          break;
        case 'next':
          skipNext();
          break;
        case 'previous':
          skipPrevious();
          break;
      }
    };
  }

  // Android Auto: методы — в part player/player_android_auto.dart (ч.1).
  // (продолжение: _getArtistAlbums/_getPlaylistSongs — там же).
  // (поиск/воспроизведение для AA — там же).
  // (обложки/_updateAndroidAuto — там же).

  void _updateAllServices() {
    if (_currentSong == null) return;

    final artworkUrl = _resolveArtworkUrl();

    final effectiveDuration = _duration.inMilliseconds > 0
        ? _duration
        : Duration(seconds: _currentSong!.duration ?? 0);

    _androidSystemService.updateFromSong(
      song: _currentSong!,
      artworkUrl: artworkUrl,
      duration: effectiveDuration,
      position: _position,
      isPlaying: _isPlaying,
      currentIndex: _currentIndex,
      queueLength: _queue.length,
    );

    _windowsService.updatePlaybackState(
      song: _currentSong!,
      artworkUrl: artworkUrl,
      duration: effectiveDuration,
      position: _position,
      isPlaying: _isPlaying,
    );

    _bluetoothService.updateFromSong(
      song: _currentSong!,
      artworkUrl: artworkUrl,
      duration: effectiveDuration,
      position: _position,
      isPlaying: _isPlaying,
      currentIndex: _currentIndex,
      queueLength: _queue.length,
    );

    // Keep the Android home-screen widget in sync (title, art, progress, like).
    if (!kIsWeb && Platform.isAndroid) {
      String? widgetArtUrl;
      // Prefer the fully-resolved artwork (offline/cached/server) when set.
      if (_resolvedArtworkUrl != null) {
        widgetArtUrl = _resolvedArtworkUrl;
      } else if (_currentSong!.coverArt != null) {
        widgetArtUrl = _resolveCoverUrl(_currentSong!.coverArt!,
            size: 400, song: _currentSong);
      }
      int accentInt = 0xFF4E8CA8;
      try {
        accentInt = ThemeService.cachedAccentInt;
      } catch (_) {}
      HomeWidgetProvider.updateNowPlaying(
        title: _currentSong!.title,
        artist: _currentSong!.artist ?? 'Unknown Artist',
        albumArtUrl: widgetArtUrl,
        isPlaying: _isPlaying,
        isLiked: _currentSong!.starred == true,
        positionMs: _position.inMilliseconds,
        durationMs: effectiveDuration.inMilliseconds,
        accentColor: accentInt,
        isOffline: _offlineService.isOfflineMode,
      );
    }

    if (_samsungService.isSamsungDevice) {
      _samsungService.updateFromSong(
        song: _currentSong!,
        artworkUrl: artworkUrl,
        duration: effectiveDuration,
        position: _position,
        isPlaying: _isPlaying,
      );
    }
  }

  /// Track play counts and ML signals. Called once per song start (not every
  /// second) because several of these do disk/DB writes.
  // История и аналитика: методы — в part player/player_history.dart.

  bool get isSamsungDevice => _samsungService.isSamsungDevice;
  bool get isDexMode => _samsungService.isDexMode;
  bool get hasBluetoothDevice => _bluetoothService.hasConnectedDevices;
  List<BluetoothDeviceInfo> get connectedBluetoothDevices =>
      _bluetoothService.connectedDevices;

  List<Song> get queue => _queue;
  int get currentIndex => _currentIndex;
  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading;

  /// True when audio is playing on a remote renderer (UPnP or Cast) rather
  /// than locally.  Used to suppress audio-focus and noisy-event handling that
  /// would incorrectly pause the remote device, and to route UI volume changes
  /// to the renderer instead of the Android system volume.
  bool get isRemotePlayback => _isRenderingRemotely;
  bool get shuffleEnabled => _shuffleEnabled;
  bool get gaplessEnabled => _gaplessEnabled;
  RepeatMode get repeatMode => _repeatMode;
  Duration get position => _position;
  Duration get duration => _duration;
  Song? get currentSong => _currentSong;
  bool get hasNext =>
      _queue.isNotEmpty &&
      (_currentIndex < _queue.length - 1 ||
          _repeatMode == RepeatMode.all ||
          (_shuffleEnabled && _queue.length > 1));
  bool get hasPrevious =>
      _queue.isNotEmpty &&
      (_currentIndex > 0 ||
          _repeatMode == RepeatMode.all ||
          (_shuffleEnabled && _shuffleHistory.isNotEmpty));
  double get volume => _volume;

  RadioStation? get currentRadioStation => _currentRadioStation;
  bool get isPlayingRadio => _isPlayingRadio;

  // Unified position stream: fed by the local audio player in normal mode, or
  // by UPnP/Cast polling in remote-playback mode.  The UI subscribes to this
  // instead of directly to _audioPlayer.positionStream so that the progress
  // bar animates correctly regardless of which playback path is active.
  final _positionController = StreamController<Duration>.broadcast();
  Stream<Duration> get positionStream => _positionController.stream;

  // Subscriptions stored so they can be cancelled before dispose closes the
  // StreamController, preventing a late just_audio tick from calling add() on
  // a closed controller.
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<int?>? _currentIndexSub;

  ConcatenatingAudioSource? _concatenatingSource;
  // Токен сборки очереди: отбрасываем устаревшие Future.wait результаты,
  // если очередь мутировала пока строились AudioSource (RangeError/OOB).
  int _sourceBuildToken = 0;
  // Окно gapless-очереди: concatenating[i] == _queue[_windowStart + i].
  // Было: источники строились на ВСЮ очередь — на тысячах треков это OOM
  // (сотни LockCachingAudioSource + сеть) и ANR при переключении.
  // Теперь материализуем максимум _kGaplessWindowSize источников вокруг
  // текущего трека, _queue при этом остаётся полной.
  int _windowStart = 0;
  static const int _kGaplessWindowSize = 120;
  static const int _kGaplessKeepBefore = 4;
  static const int _kGaplessMaxSources = 200;

  // Gapless-окно: хелперы — в part player/player_sources.dart.
  // Троттлинг position-сейвов очереди: тики каждые 2с не должны дёргать диск.
  int _lastQueueSaveMs = 0;

  /// Preloaded audio sources for the next 2 tracks (for BPM crossfade).
  final Map<String, AudioSource> _preloadedSources = {};

  // Fallback timer for Windows where positionStream may not emit reliably
  Timer? _windowsPositionTimer;
  Duration? _lastPolledPosition;

  double get progress {
    if (_duration.inMilliseconds == 0) return 0;
    return _position.inMilliseconds / _duration.inMilliseconds;
  }

  double get playbackSpeed => _playbackSpeed;

  double get pitch => _pitch;

  bool get pitchCorrection => _pitchCorrection;

  Future<void> setPlaybackSpeed(double speed) async {
    _playbackSpeed = speed.clamp(0.25, 4.0);

    final targetPitch = _pitchCorrection ? 1.0 : _playbackSpeed;
    _pitch = targetPitch.clamp(0.5, 2.0);

    final success = await _audioHandler.setPlaybackParameters(
      _playbackSpeed,
      _pitch,
    );
    if (!success) {
      // Fallback to just_audio native setSpeed when pitch plugin is unavailable.
      await _audioPlayer.setSpeed(_playbackSpeed);
    }

    notifyListeners();
  }

  Future<void> setPitch(double pitch) async {
    _pitch = pitch.clamp(0.5, 2.0);

    final success = await _audioHandler.setPlaybackParameters(
      _playbackSpeed,
      _pitch,
    );
    if (!success) {
      await _audioPlayer.setSpeed(_playbackSpeed);
    }

    notifyListeners();
  }

  Future<void> togglePitchCorrection() async {
    _pitchCorrection = !_pitchCorrection;
    final targetPitch = _pitchCorrection ? 1.0 : _playbackSpeed;
    _pitch = targetPitch.clamp(0.5, 2.0);

    final success = await _audioHandler.setPlaybackParameters(
      _playbackSpeed,
      _pitch,
    );
    if (!success) {
      await _audioPlayer.setSpeed(_playbackSpeed);
    }

    notifyListeners();
  }

  // Sleep timer: методы — в part player/player_sleep_timer.dart.
  // Watchdog мёртвого стрима: методы — в part player/player_watchdog.dart.

  void _initializePlayer() {
    _configureAudioSession();

    _storageService.getVolume().then((savedVolume) {
      _volume = savedVolume;
      _audioPlayer.setVolume(_volume);
      notifyListeners();
    });

    _storageService.getShuffleMode().then((saved) {
      _shuffleEnabled = saved;
      notifyListeners();
    });

    _storageService.getRepeatMode().then((saved) {
      _repeatMode =
          RepeatMode.values[saved.clamp(0, RepeatMode.values.length - 1)];
      notifyListeners();
    });

    _storageService.getGaplessPlayback().then((saved) {
      _gaplessEnabled = saved;
      notifyListeners();
    });

    _playerStateSub = _audioPlayer.playerStateStream.listen(
      (state) {
        // In remote-playback mode the local player is stopped/paused; ignore
        // its state so it doesn't overwrite the UPnP/Cast-managed values.
        if (_isRenderingRemotely) return;

        final wasPlaying = _isPlaying;
        _isPlaying = state.playing;

        if (wasPlaying != _isPlaying && !_reactivatingSession) {
          debugPrint(
              '[Player] ${_isPlaying ? '▶ Playing' : '⏸ Paused'} — "${_currentSong?.title ?? 'unknown'}" (${state.processingState.name})');
          // Пауза/анпауз из любого источника (кнопка, гарнитура, авто) — в зеркало.
          _brainPublishNow();

          // Start/stop Windows position polling timer
          if (_isPlaying && Platform.isWindows && !_isRenderingRemotely) {
            _windowsPositionTimer?.cancel();
            _lastPolledPosition = null;
            _windowsPositionTimer = Timer.periodic(
              const Duration(milliseconds: 1000),
              (_) {
                final pos = _audioPlayer.position;
                if (_lastPolledPosition == null ||
                    pos.inMilliseconds != _lastPolledPosition!.inMilliseconds) {
                  _lastPolledPosition = pos;
                  _position = pos;
                  _positionController.add(pos);
                  notifyListeners();
                  _updateAllServices();
                }
              },
            );
          } else {
            _windowsPositionTimer?.cancel();
            _windowsPositionTimer = null;
            _lastPolledPosition = null;
          }
        }

        if (state.processingState == ProcessingState.completed) {
          debugPrint(
              '[Player] ✓ Song completed: "${_currentSong?.title ?? 'unknown'}"');
          // Ранний конец (трек «отыграл» 7 секунд из 3 минут) — признак
          // обрезанного кэша/умершего URL: скробблить как полное
          // прослушивание нельзя, просто идем дальше.
          final earlyEnded = _duration.inSeconds > 30 &&
              _position.inSeconds < _duration.inSeconds * 0.5;
          if (earlyEnded) {
            debugPrint(
                '[Player] Early end at ${_position.inSeconds}s of ${_duration.inSeconds}s — possible truncated cache, advancing without scrobble');
            // Удаляем обрезанный .tmp чтобы следующий запуск трека качал заново,
            // а не переиспользовал битый файл как «готовый» (зацикливание stall→skip).
            final deadSong = _currentSong;
            if (deadSong != null) {
              unawaited(_deleteTruncatedStreamCache(deadSong));
            }
          }
          _onSongComplete(earlyEnded: earlyEnded).catchError(
              (e) => debugPrint('[Player] _onSongComplete error: $e'));
        }

        if (state.processingState == ProcessingState.buffering && !wasPlaying) {
          debugPrint(
              '[Player] ⟳ Buffering: "${_currentSong?.title ?? 'unknown'}"');
        }

        if (wasPlaying != _isPlaying && !_reactivatingSession) {
          notifyListeners();
          _updateAndroidAuto();
        }
      },
      onError: (error) {
        debugPrint('[Player] State stream error (usually harmless): $error');
      },
    );

    Duration? lastNotified;
    Duration? lastSystemUpdate;
    _positionSub = _audioPlayer.positionStream.listen(
      (position) {
        // In remote-playback mode the local player sits idle at position zero;
        // ignore its ticks so they don't overwrite the UPnP/Cast position.
        if (_isRenderingRemotely) return;

        final positionJumpedBack = _position.inMilliseconds > 0 &&
            position.inMilliseconds < _position.inMilliseconds - 1000;

        _position = position;
        _positionController.add(position);

        if (positionJumpedBack ||
            lastNotified == null ||
            position.inMilliseconds - lastNotified!.inMilliseconds > 500) {
          lastNotified = position;
          notifyListeners();
        }

        if (lastSystemUpdate == null ||
            (position.inMilliseconds - lastSystemUpdate!.inMilliseconds).abs() >
                2000) {
          lastSystemUpdate = position;
          _updateAllServices();
          // Сейв позиции — не чаще раза в 30с (было: каждый тик 2с дёргал
          // debounce+диск во время всего воспроизведения).
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          if (nowMs - _lastQueueSaveMs >= 30000) {
            _lastQueueSaveMs = nowMs;
            _saveQueueState();
          }
        }
      },
      onError: (error) {
        debugPrint('Position stream error (can be ignored): $error');
      },
    );

    _durationSub = _audioPlayer.durationStream.listen(
      (duration) {
        // In remote-playback mode the local player has no loaded track; ignore
        // its duration so it doesn't zero out the UPnP/Cast duration.
        if (_isRenderingRemotely) return;

        _duration = duration ?? Duration.zero;
        notifyListeners();
        _updateAndroidAuto();
      },
      onError: (error) {
        debugPrint('Duration stream error (can be ignored): $error');
      },
    );

    _currentIndexSub = _audioPlayer.currentIndexStream.listen(
      (index) {
        // index — позиция в concatenating-окне, транслируем в индекс очереди.
        final q = index == null ? null : index + _windowStart;
        if (q != null &&
            q != _currentIndex &&
            q >= 0 &&
            q < _queue.length &&
            !_isRenderingRemotely &&
            _concatenatingSource != null) {
          _onCurrentIndexChanged(q).catchError((e) {
            debugPrint('[Player] _onCurrentIndexChanged error: $e');
          });
        }
      },
      onError: (error) {
        debugPrint('Current index stream error (can be ignored): $error');
      },
    );

    _startStallWatchdog();
    _startLiveHeartbeat();
  }

  Future<void> _configureAudioSession() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      debugPrint('[Player] AudioSession configured for music playback');

      // Listen for audio interruptions (another app takes audio focus)
      session.interruptionEventStream.listen((event) {
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              _audioPlayer.setVolume(0.3);
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              if (isRemotePlayback) return;
              pause();
              break;
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              _audioPlayer.setVolume(_volume);
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              // Optionally resume after interruption ends
              break;
          }
        }
      });

      // Listen for headphone disconnection
      session.becomingNoisyEventStream.listen((_) {
        if (isRemotePlayback) return;
        pause();
      });
    } catch (e) {
      debugPrint('[Player] AudioSession configuration failed: $e');
    }
  }

  Future<void> _ensureAudioFocus() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final granted = await _androidSystemService.requestAudioFocus();
      debugPrint('[Player] Audio focus requested, granted=$granted');
    } catch (e) {
      debugPrint('[Player] Audio focus request failed: $e');
    }
  }

  Future<void> _onSongComplete({bool earlyEnded = false}) async {
    final isPodcast = _isPodcastSong(_currentSong);
    if (!earlyEnded && !isPodcast && _currentSong != null && _currentSong!.isLocal != true) {
      _subsonicService.scrobble(_currentSong!.id, submission: true).catchError((
        e,
      ) {
        _offlineService.queueScrobble(_currentSong!.id, submission: true);
      });
    }

    if (!earlyEnded && !isPodcast && _currentSong != null && _recommendationService != null) {
      _recommendationService!.trackSongPlay(
        _currentSong!,
        durationPlayed: _duration.inSeconds,
        completed: true,
      );
      // Полное прослушивание — и в аналитику «что я слушал уже».
      unawaited(_recordAnalytics(_currentSong!, _duration.inMilliseconds, true));
    } else if (!earlyEnded && isPodcast && _currentSong != null) {
      // Подкасты в музыкальный KumaFlow Brain не пишем, но в аналитику — да.
      unawaited(_recordAnalytics(_currentSong!, _duration.inMilliseconds, true));
    }

    // Auto re-score on a completed listen: update the shared feedback streams
    // and MAB arms so the *next* playlist generation reflects the new listen
    // without regenerating the current queue.
    if (!earlyEnded && _currentSong != null && !_isPodcastSong(_currentSong)) {
      _behaviorTracker.logComplete(_currentSong!.id, genre: _currentSong!.genre);
      _timeAwareHistory.logPlay(_currentSong!.id, DateTime.now().hour);
      final mabContext = _multiArmedBandit.getCurrentContext();
      if (_currentSong!.artistId != null) {
        _multiArmedBandit.recordReward(
          _currentSong!.artistId!,
          _multiArmedBandit.calculateReward('full_play'),
          mabContext,
          'artist',
          _currentSong!.artist,
        );
      }
      if (_currentSong!.genre != null) {
        _multiArmedBandit.recordReward(
          _currentSong!.genre!,
          _multiArmedBandit.calculateReward('full_play'),
          mabContext,
          'genre',
          _currentSong!.genre,
        );
      }
    }

    if (_sleepTimerEndCurrentSong) {
      _doSleepTimerStop();
      return;
    }

    if (_concatenatingSource != null) {
      // With ConcatenatingAudioSource this only fires at the very end
      // of the queue when LoopMode is off.
      await _handleEndOfQueue();
      return;
    }

    // Fallback for single-song mode
    if (_repeatMode == RepeatMode.one ||
        (_repeatMode == RepeatMode.all && _queue.length == 1)) {
      await seek(Duration.zero);
      await play();
    } else if (_currentIndex < _queue.length - 1 ||
        _repeatMode == RepeatMode.all ||
        _shuffleEnabled) {
      await skipNext();
    } else {
      await _handleEndOfQueue();
    }
  }

  Future<void> _handleEndOfQueue() async {
    // Podcasts: play next episode or stop — never AutoDJ music.
    if (_isPodcastSong(_currentSong)) return;
    if (!_autoDjService.isEnabledForSong(_currentSong)) return;
    await _addAutoDjSongs();
    if (_currentIndex < _queue.length - 1) {
      await skipToIndex(_currentIndex + 1);
    }
  }

  /// Abandon signal (soft negative): previous track was left behind at
  /// 5–80% without an explicit skip. Called when a new song starts.
  void _logAbandonIfNeeded() {
    final prev = _currentSong;
    final skipLoggedId = _lastSkipLoggedId;
    _lastSkipLoggedId = null;
    if (prev == null || _isPodcastSong(prev)) return;
    // Explicit skip was already logged for this track — not an abandon.
    if (prev.id == skipLoggedId) return;
    final total = _duration.inSeconds;
    if (total <= 0) return;
    final played = _position.inSeconds;
    final ratio = played / total;
    if (ratio < 0.05 || ratio >= 0.8) return;
    try {
      _behaviorTracker.logAbandon(prev.id, played, genre: prev.genre);
      _mlStore.recordAbandon(prev.id);
      _mlService.recordAbandon(prev.id, song: prev);
      final mabContext = _multiArmedBandit.getCurrentContext();
      if (prev.artistId != null) {
        _multiArmedBandit.recordReward(
          prev.artistId!,
          _multiArmedBandit.calculateReward('abandon'),
          mabContext,
          'artist',
          prev.artist,
        );
      }
      if (prev.genre != null) {
        _multiArmedBandit.recordReward(
          prev.genre!,
          _multiArmedBandit.calculateReward('abandon'),
          mabContext,
          'genre',
          prev.genre,
        );
      }
    } catch (_) {}
  }

  Future<void> playSong(
    Song song, {
    List<Song>? playlist,
    int? startIndex,
    Duration? initialPosition,
    String? playlistName,
    String? waveHint,
    bool? isWave,
  }) async {
    // If the song is already playing AND no new playlist was provided, just
    // toggle play/pause (existing UX). If a new playlist IS provided we
    // always replace the queue — this is how "Build playlist" / "Play radio"
    // surfaces work, otherwise the new tracks never land.
    if (_currentSong?.queueKey == song.queueKey &&
        !_isPlayingRadio &&
        playlist == null) {
      await togglePlayPause();
      return;
    }

    _isPlayingRadio = false;
    _currentRadioStation = null;
    // Уход с радио в обычную очередь: радио-контекст мёртв (иначе шапка
    // продолжит врать «Радио · …» при обычной очереди без имени).
    if ((_currentQueueName ?? '').startsWith('Радио ·') &&
        playlistName == null) {
      _currentQueueName = null;
      _currentQueueHint = null;
    }
    // Свежее намерение пользователя — сессионный бан мертвых стримов сбрасываем.
    _deadStreamKeys.clear();

    // Abandon signal: previous track left at 5–80% without an explicit skip
    // (direct pick / queue jump). Skip-logged tracks are excluded via guard.
    _logAbandonIfNeeded();

    // Jukebox mode: send to server instead of playing locally.
    if (_jukeboxService.enabled) {
      final targetPlaylist = (playlist ?? [song]).toList();
      final targetIndex = startIndex ??
          targetPlaylist
              .indexWhere((s) => s.queueKey == song.queueKey)
              .clamp(0, targetPlaylist.length - 1);
      await _jukeboxService.setQueue(
        _subsonicService,
        targetPlaylist,
        startIndex: targetIndex,
      );
      _isPlaying = true;
      _isLoading = false;
      notifyListeners();
      _updateAllServices();
      _trackPlay();
      _updateAndroidAuto();
      return;
    }

    debugPrint(
        '[Player] ▶ playSong: "${song.title}" by ${song.artist ?? 'unknown'} (id=${song.id} local=${song.isLocal})');
    _isLoading = true;
    notifyListeners();

    try {
      if (playlist != null) {
        final isNewQueue = !identical(playlist, _queue);
        // Дедуп по составному ключу сервер:трек — id с разных серверов
        // могут совпадать, это разные файлы (collab-микс).
        final seen = <String>{};
        final deduped = <Song>[];
        for (final s in playlist) {
          if (seen.add(s.queueKey)) deduped.add(s);
        }
        final sameIds = _queue.length == deduped.length &&
            _queue.asMap().entries.every(
                (e) => e.value.queueKey == deduped[e.key].queueKey);
        _queue = deduped;
        _currentIndex =
            startIndex ?? deduped.indexWhere((s) => s.queueKey == song.queueKey);
        if (_currentIndex == -1) _currentIndex = 0;
        if (isNewQueue) _shuffleHistory.clear();
        // Имя очереди: как десктоп setSongList — не терять при том же списке
        // (второй тап по той же волне/радио), иначе шапка врёт.
        if (playlistName != null && playlistName.trim().isNotEmpty) {
          _currentQueueName = playlistName;
          if (waveHint != null) {
            _currentQueueHint = waveHint.isEmpty ? null : waveHint;
          } else if (_isSeedName(playlistName)) {
            // Сид («В стиле: X») — подпись он сам, как на десктопе.
            _currentQueueHint = playlistName;
          }
        } else if (isWave == true && !isWavePlaylistName(_currentQueueName)) {
          _currentQueueName = '${_currentQueueName ?? 'Очередь'} · Моя волна';
        } else if (!sameIds) {
          // Новый список без имени — старый контекст мёртв.
          if (playlistName != null) _currentQueueName = null;
        }
      } else if (_queue.isEmpty ||
          !_queue.any((s) => s.queueKey == song.queueKey)) {
        _queue = [song];
        _currentIndex = 0;
        _shuffleHistory.clear();
        if (playlistName != null && playlistName.trim().isNotEmpty) {
          _currentQueueName = playlistName;
          if (waveHint != null) {
            _currentQueueHint = waveHint.isEmpty ? null : waveHint;
          } else if (_isSeedName(playlistName)) {
            _currentQueueHint = playlistName;
          }
        }
      } else {
        _currentIndex = _queue.indexWhere((s) => s.queueKey == song.queueKey);
        // Тот же список, другой индекс + пришло имя — подхватить (десктоп).
        if (playlistName != null && playlistName.trim().isNotEmpty) {
          _currentQueueName = playlistName;
          if (waveHint != null) {
            _currentQueueHint = waveHint.isEmpty ? null : waveHint;
          } else if (_isSeedName(playlistName)) {
            _currentQueueHint = playlistName;
          }
        }
      }

      _currentSong = song;
      _resolvedArtworkUrl = null;
      _position = Duration.zero;
      // ABS context: if new queue is ABS keep, otherwise clear
      if (!song.id.startsWith('abs_')) {
        if (_absBookId != null) {
          _absSyncTimer?.cancel();
          clearAbsBookContext();
        }
      }
      notifyListeners();
      _saveQueueState();
      // Preload next N songs for offline (queue cache) — respects music cache toggle + preload count
      try {
        final cfg = _subsonicService.config;
        if (cfg != null) {
          _offlineService.baseUrl = cfg.serverUrl;
          _offlineService.subsonicUser = cfg.username;
        }
        unawaited(_offlineService
            .preloadNextSongs(_queue, _currentIndex, subsonicService: _subsonicService)
            .catchError((e) => debugPrint('[Player] preload failed: $e')));
      } catch (e) {
        debugPrint('[Player] preload setup failed: $e');
      }

      // Обложка/текст НЕ блокируют старт аудио: на деградированной сети
      // каждый из этих запросов может висеть десятки секунд, а трек уже
      // должен играть. Догоняют фоном с защитой от устаревания (быстрые скипы).
      final playKey = song.queueKey;
      unawaited(_refreshArtworkUrl().then((_) {
        if (_currentSong?.queueKey != playKey) return;
        _updateAllServices();
      }).catchError((e) => debugPrint('[Player] artwork refresh failed: $e')));
      unawaited(_loadAndSyncLyrics(song).then((_) async {
        if (_currentSong?.queueKey != playKey) return;
        // Update song info for iOS Live Activity
        try {
          await _lyricsService.updateSongInfo(
            title: song.title,
            artist: song.artist ?? 'Unknown Artist',
            artworkUrl: _resolvedArtworkUrl ?? song.coverArt,
          );
        } catch (e) {
          debugPrint('[Player] song info update failed: $e');
        }
      }).catchError((e) => debugPrint('[Player] lyrics sync failed: $e')));

      if (_castService.isConnected) {
        if (_audioPlayer.playing) await _audioPlayer.stop();

        String playUrl;
        if (_isPodcastSong(song) && song.path != null && song.path!.startsWith('http')) {
          playUrl = song.path!;
        } else if (song.isLocal == true && song.path != null) {
          // Chromecast cannot fetch file:// — same HTTP trick as DLNA.
          try {
            await LocalFileServer.instance.start();
            await LocalFileServer.instance.refreshLanIp();
            playUrl = LocalFileServer.instance.urlForFile(song.path!) ??
                Uri.file(song.path!).toString();
          } catch (_) {
            playUrl = Uri.file(song.path!).toString();
          }
        } else {
          playUrl = await _multiServerResolver.resolveStreamUrl(song);
        }
        // Offline cache also counts as local file
        if (playUrl.startsWith('file://') || playUrl.startsWith('/')) {
          final offlineFallback = _offlineService.getLocalPath(song.queueKey) ??
              _offlineService.getLocalPath(song.id);
          if (offlineFallback != null) {
            try {
              await LocalFileServer.instance.start();
              playUrl = LocalFileServer.instance.urlForFile(offlineFallback) ?? playUrl;
            } catch (_) {}
          }
        }
        final coverUrl = song.isLocal == true && song.coverArt != null
            ? song.coverArt!
            : _resolveCoverUrl(song.coverArt ?? song.id, song: song);

        await _castService.loadMedia(
          url: playUrl,
          title: song.title,
          artist: song.artist ?? 'Unknown Artist',
          imageUrl: coverUrl,
          albumName: song.album,
          trackNumber: song.track,
          duration:
              song.duration != null ? Duration(seconds: song.duration!) : null,
          autoPlay: true,
        );
        _isRenderingRemotely = true;
        _isPlaying = true;
      } else if (_upnpService.isConnected) {
        // Reset before sending Stop so a poll that fires mid-load can't
        // mistake the STOPPED state for a natural track end and advance twice.
        _upnpWasPlaying = false;
        debugPrint(
          'UPnP: playSong() taking UPnP branch, isConnected=${_upnpService.isConnected}',
        );
        if (_audioPlayer.playing) await _audioPlayer.stop();

        var upnpOk = false;
        try {
          // Local files are served over HTTP from this device so the renderer
          // can actually fetch them (file:// URIs are unreachable for a TV).
          // IP телефона мог смениться после переподключения Wi-Fi — обновляем,
          // иначе ТВ получит stale-адрес и трек не стартует.
          try {
            await LocalFileServer.instance.refreshLanIp();
          } catch (_) {}
          String playUrl;
          if (_isPodcastSong(song) && song.path != null && song.path!.startsWith('http')) {
            playUrl = song.path!;
          } else if (song.isLocal == true && song.path != null) {
            final host = _upnpService.connectedDevice?.location != null
                ? Uri.tryParse(_upnpService.connectedDevice!.location)?.host
                : null;
            playUrl = await LocalFileServer.instance
                    .urlForFileForRenderer(song.path!, host) ??
                LocalFileServer.instance.urlForFile(song.path!) ??
                Uri.file(song.path!).toString();
          } else {
            playUrl = await _multiServerResolver.resolveStreamUrl(song);
          }

          // Resolve the MIME type so strict UPnP renderers (e.g. moode /
          // upmpdcli with "check metadata" on) can validate protocolInfo.
          final mimeType =
              song.contentType ?? UpnpService.mimeTypeFromSuffix(song.suffix);
          upnpOk = await _upnpService.loadAndPlay(
            url: playUrl,
            title: song.title,
            artist: song.artist ?? 'Unknown Artist',
            album: song.album,
            albumArtUrl: song.coverArt != null
                ? _resolveCoverUrl(song.coverArt, size: 0, song: song)
                : null,
            durationSecs: song.duration,
            contentType: mimeType,
          );
        } catch (e) {
          debugPrint('UPnP playback error: $e');
          upnpOk = false;
        }

        if (!upnpOk) {
          // The renderer couldn't take over the track. Disconnect so the UI
          // reflects reality, then fall back to local playback below instead
          // of leaving the player silent and stuck.
          debugPrint(
              'UPnP playback failed, falling back to local playback of "${song.title}"');
          _upnpService.disconnect();
          _isRenderingRemotely = false;
        } else {
          _isRenderingRemotely = true;
          _isPlaying = true;
          _updateAllServices();
          _trackPlay();
          // Gapless: prefetch next track via SetNextAVTransportURI
          if (_queue.length > _currentIndex + 1) {
            final next = _queue[_currentIndex + 1];
            try {
              String nextUrl;
              if (next.isLocal == true && next.path != null) {
                // Use renderer-aware IP
                final host = _upnpService.connectedDevice?.location != null
                    ? Uri.tryParse(_upnpService.connectedDevice!.location)?.host
                    : null;
                nextUrl = await LocalFileServer.instance
                        .urlForFileForRenderer(next.path!, host) ??
                    LocalFileServer.instance.urlForFile(next.path!) ??
                    Uri.file(next.path!).toString();
              } else {
                nextUrl = await _multiServerResolver.resolveStreamUrl(next);
              }
              final nextMime =
                  next.contentType ?? UpnpService.mimeTypeFromSuffix(next.suffix);
              unawaited(_upnpService.setNextTrack(
                url: nextUrl,
                title: next.title,
                artist: next.artist ?? 'Unknown Artist',
                album: next.album,
                albumArtUrl: next.coverArt != null
                    ? _resolveCoverUrl(next.coverArt, size: 0, song: next)
                    : null,
                durationSecs: next.duration,
                contentType: nextMime,
              ));
            } catch (e) {
              debugPrint('UPnP SetNext prefetch failed: $e');
            }
          }
        }
      }

      // Local playback path. Skipped when a remote renderer successfully took
      // over the track.
      if (!_isRenderingRemotely) {
        // For YouTube, pre-fetch the manifest then hand a StreamAudioSource
        // to just_audio so ExoPlayer never touches the YouTube URL directly.
        final youtubeSource = song.isLocal != true
            ? await _subsonicService.getYoutubeAudioSource(song)
            : null;

        if (youtubeSource != null) {
          // YouTube: single StreamAudioSource, no gapless
          await _audioPlayer.setAudioSource(youtubeSource);
          await _applyReplayGain(song);
          await _ensureAudioFocus();
          await _audioPlayer.play();
        } else if (_subsonicService.isYoutube) {
          // All songs are YouTube — can't build ConcatenatingAudioSource easily
          final String playUrl;
          if (_isPodcastSong(song)) {
            final cleanId = song.id.replaceFirst('podcast:', '');
            final podPath = _offlineService.getPodcastLocalPath(cleanId) ?? _offlineService.getPodcastLocalPath(song.id);
            if (podPath != null) {
              playUrl = Uri.file(podPath).toString();
            } else if (song.path != null && (song.path!.startsWith('http://') || song.path!.startsWith('https://'))) {
              playUrl = song.path!;
            } else if (song.isLocal == true && song.path != null) {
              playUrl = Uri.file(song.path!).toString();
            } else {
              playUrl = await _multiServerResolver.resolveStreamUrl(song);
            }
          } else if (song.isLocal == true && song.path != null) {
            playUrl = Uri.file(song.path!).toString();
          } else {
            final offlinePath = _offlineService.getLocalPath(song.queueKey) ??
                _offlineService.getLocalPath(song.id);
            if (offlinePath != null) {
              playUrl = 'file://$offlinePath';
            } else {
              playUrl = await _multiServerResolver.resolveStreamUrl(song);
            }
          }
          await _audioPlayer.setUrl(playUrl);
          await _applyReplayGain(song);
          await _ensureAudioFocus();
          await _audioPlayer.play();
        } else if (_gaplessEnabled) {
          // Build ConcatenatingAudioSource for gapless playback — supports initialPosition for book resume (Lissen)
          final desiredPos = initialPosition;
          try {
            await _buildAndSetConcatenatingSource(initialIndex: _currentIndex, initialPosition: desiredPos);
          } catch (e) {
            // Android 16 / Media3 first-play workaround
            if (!_hasPlayedOnce) {
              debugPrint(
                'First playback failed (Android 16 Media3 issue), retrying: $e',
              );
              await Future.delayed(const Duration(milliseconds: 100));
              await _buildAndSetConcatenatingSource(
                  initialIndex: _currentIndex, initialPosition: desiredPos);
              _hasPlayedOnce = true;
            } else {
              rethrow;
            }
          }
          await _applyReplayGain(song);
          await _ensureAudioFocus();
          await _audioPlayer.play();
          // If initialPosition provided, ensure position is set (some just_audio versions ignore it for clipped sources)
          if (desiredPos != null && desiredPos.inMilliseconds > 0) {
            // Small delay to ensure source ready
            await Future.delayed(const Duration(milliseconds: 100));
            try { await _audioPlayer.seek(desiredPos); } catch (_) {}
          }
        } else {
          // Gapless disabled — single-song mode
          final String playUrl;
          if (_isPodcastSong(song)) {
            final cleanId = song.id.replaceFirst('podcast:', '');
            final podPath = _offlineService.getPodcastLocalPath(cleanId) ?? _offlineService.getPodcastLocalPath(song.id) ?? _offlineService.getLocalPath(cleanId) ?? _offlineService.getLocalPath(song.id);
            if (podPath != null) {
              playUrl = Uri.file(podPath).toString();
            } else if (song.path != null && (song.path!.startsWith('http://') || song.path!.startsWith('https://'))) {
              playUrl = song.path!;
            } else if (song.isLocal == true && song.path != null) {
              final exists = await File(song.path!).exists().timeout(const Duration(seconds: 2), onTimeout: () => false);
              if (!exists) throw Exception('Local file not found: ${song.path}');
              playUrl = Uri.file(song.path!).toString();
            } else {
              playUrl = await _multiServerResolver.resolveStreamUrl(song);
            }
          } else if (song.isLocal == true && song.path != null) {
            // Fast fail if local file missing to avoid setUrl hang
            final exists = await File(song.path!).exists().timeout(const Duration(seconds: 2), onTimeout: () => false);
            if (!exists) throw Exception('Local file not found: ${song.path}');
            playUrl = Uri.file(song.path!).toString();
          } else {
            final offlinePath = _offlineService.getLocalPath(song.queueKey) ??
                _offlineService.getLocalPath(song.id);
            if (offlinePath != null) {
              playUrl = 'file://$offlinePath';
            } else {
              // Collab: stream URL с сервера-владельца трека.
              playUrl = await resolvePlayUrl(song);
            }
          }
          // Cache remote streams locally so seeking works even when the
          // server transcodes and doesn't support HTTP range requests (#170).
          // Подкасты с локальным файлом тоже идут напрямую через setUrl.
          final isPodcastCached = _isPodcastSong(song) &&
              (_offlineService.getPodcastLocalPath(song.id.replaceFirst('podcast:', '')) != null ||
                  _offlineService.getPodcastLocalPath(song.id) != null);
          if (song.isLocal == true ||
              isPodcastCached ||
              _offlineService.getLocalPath(song.queueKey) != null ||
              _offlineService.getLocalPath(song.id) != null) {
            await _audioPlayer.setUrl(playUrl);
          } else {
            final cacheDir = await getTemporaryDirectory();
            final cacheFile = File(
              '${cacheDir.path}/${_streamCacheName(song)}',
            );
            // ignore: experimental_member_use
            await _audioPlayer.setAudioSource(
              // ignore: experimental_member_use
              LockCachingAudioSource(
                Uri.parse(playUrl),
                cacheFile: cacheFile,
                tag: song.queueKey,
              ),
            );
          }
          await _applyReplayGain(song);
          await _ensureAudioFocus();
          await _audioPlayer.play();
        }
      }

      if (song.isLocal != true) {
        if (_offlineService.isOfflineMode) {
          _offlineService.queueScrobble(song.id, submission: false);
        } else {
          // Collab: scrobble на сервер-владелец трека (best effort).
          _multiServerResolver
              .scrobble(song, submission: false)
              .catchError((e) {
            _offlineService.queueScrobble(song.id, submission: false);
          });

          _offlineService
              .flushPendingScrobbles(_subsonicService)
              .catchError((e) {
            debugPrint('Scrobble flush failed: $e');
          });
        }
        _startNowPlayingTimer();
      } else {
        _stopNowPlayingTimer();
      }

      // История (RecommendationService.profiles → экран Истории/статистика/
      // KumaFlow Brain волны) пишется НЕ на старте, а по порогу в _maybeCommitHistory
      // (30с или 50%): иначе трек попадал в историю за 0 сек даже при скипе
      // через 5 сек + двойной учёт при дослушивании. Подкасты сюда не пишем.

      _preloadNextTracks();
      _updateAndroidAuto();
      // Start ABS sync if this is a book
      if (_absBookId != null && song.id.startsWith('abs_')) {
        _absPlayingSinceMs = DateTime.now().millisecondsSinceEpoch;
        _startAbsSyncTimer();
      }
    } catch (e, st) {
      debugPrint('[Player] ✗ Error playing song "${song.title}": $e\n$st');
      // Auto-skip missing/unplayable local file instead of hanging queue at 0:00.
      // В офлайне сюда же попадают сетевые ошибки стрима — пропускаем дальше
      // по играемым, музыка не встаёт.
      final isLocalMissing = e.toString().contains('Local file not found') ||
          e.toString().contains('No playable sources') ||
          e.toString().contains('Source build timeout') ||
          e is TimeoutException ||
          _isNetworkUnplayable(e);
      _isPlaying = false;
      _position = Duration.zero;
      _updateAndroidAuto();
      if (isLocalMissing && _queue.length > 1 && _currentIndex >= 0 && _currentIndex < _queue.length - 1) {
        // Schedule skipNext after current frame to avoid re-entrancy during setAudioSource
        final nextIdx = _currentIndex + 1;
        debugPrint('[Player] auto-skipping to next track due to unplayable file (index $nextIdx)');
        Future.microtask(() {
          // remove unplayable track from queue to prevent loop
          try {
            if (_queue.isNotEmpty && _currentIndex >= 0 && _currentIndex < _queue.length) {
              final bad = _queue[_currentIndex];
              if (bad.id == song.id) {
                _queue.removeAt(_currentIndex);
                if (_currentIndex >= _queue.length) _currentIndex = _queue.length - 1;
              }
            }
          } catch (_) {}
          if (nextIdx < _queue.length || _queue.isNotEmpty) {
            skipNext();
          }
        });
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Радио и тексты: методы — в part player/player_radio.dart.

  Future<void> play() async {
    if (_jukeboxService.enabled) {
      await _jukeboxService.play(_subsonicService);
      _isPlaying = true;
      notifyListeners();
      _updateAndroidAuto();
      if (_absBookId != null) { _absPlayingSinceMs = DateTime.now().millisecondsSinceEpoch; _startAbsSyncTimer(); }
      return;
    }
    if (_castService.isConnected) {
      await _castService.play();
      _isPlaying = true;
      notifyListeners();
      _updateAndroidAuto();
      if (_absBookId != null) { _absPlayingSinceMs = DateTime.now().millisecondsSinceEpoch; _startAbsSyncTimer(); }
    } else if (_upnpService.isConnected) {
      await _upnpService.play();
      _isPlaying = true;
      notifyListeners();
      _updateAndroidAuto();
      if (_absBookId != null) { _absPlayingSinceMs = DateTime.now().millisecondsSinceEpoch; _startAbsSyncTimer(); }
    } else {
      // After app restart the audio source may not be loaded yet.
      // If we have a current song but the player has no source, prepare it first.
      if (_currentSong != null &&
          (_audioPlayer.audioSource == null ||
              _audioPlayer.duration == Duration.zero)) {
        await _prepareCurrentSong();
      }
      // Фикс бага: после долгой паузы ExoPlayer может потерять фокус/сессию,
      // volume мог остаться 0 после прерванного fadeOut. Гарантируем фокус и сброс громкости.
      await _ensureAudioFocus();
      // Если громкость 0 из-за гонки _fadeTimer — сразу восстанавливаем перед play
      if (_audioPlayer.volume < 0.01) {
        await _audioPlayer.setVolume(_volume);
        _stopFade();
      }
      await _audioPlayer.play();
      await _fadeIn();
      notifyListeners();
      _updateAndroidAuto();
      _updateAllServices();
      if (_absBookId != null) { _absPlayingSinceMs = DateTime.now().millisecondsSinceEpoch; _startAbsSyncTimer(); }
      if (_currentSong != null && _currentSong!.isLocal != true && !_isPodcastSong(_currentSong)) {
        if (!_offlineService.isOfflineMode) {
          _subsonicService.scrobble(_currentSong!.id, submission: false).catchError((e) => _offlineService.queueScrobble(_currentSong!.id, submission: false));
        }
        _startNowPlayingTimer();
      }
    }
  }

  Future<void> pause() async {
    _stopNowPlayingTimer();
    // flush ABS sync on pause
    if (_absBookId != null) await _syncAbsProgress();
    if (_jukeboxService.enabled) {
      await _jukeboxService.pause(_subsonicService);
      _isPlaying = false;
      notifyListeners();
      _updateAndroidAuto();
      _absSyncTimer?.cancel();
      return;
    }
    if (_castService.isConnected) {
      await _castService.pause();
      _isPlaying = false;
      notifyListeners();
      _updateAndroidAuto();
      _absSyncTimer?.cancel();
    } else if (_upnpService.isConnected) {
      await _upnpService.pause();
      _isPlaying = false;
      notifyListeners();
      _updateAndroidAuto();
      _absSyncTimer?.cancel();
    } else {
      await _fadeOut(onComplete: () async {
        await _audioPlayer.pause();
      });
      _isPlaying = false;
      notifyListeners();
      _updateAndroidAuto();
      _updateAllServices();
      _absSyncTimer?.cancel();
    }
  }

  Future<void> stop() async {
    _lastUserStopTime = DateTime.now();
    _stopNowPlayingTimer();
    if (_absBookId != null) await _flushAbsSync(force: true);
    _absSyncTimer?.cancel();
    if (_castService.isConnected) {
      await _castService.stop();
    } else if (_upnpService.isConnected) {
      _upnpWasPlaying = false; // prevent poll from misreading the STOPPED state
      await _upnpService.stop();
    } else {
      await _audioPlayer.stop();
    }

    _isPlaying = false;
    _position = Duration.zero;
    notifyListeners();
    _updateAndroidAuto();
    _updateAllServices();
  }

  // ── Fade In/Out ────────────────────────────────────────────────────────────

  // Fades: методы — в part player/player_fades.dart.

  Future<void> togglePlayPause() async {
    if (_isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> seek(Duration position) async {
    final before = _position;
    _position = position;
    notifyListeners();
    if (_jukeboxService.enabled) {
      // Jukebox doesn't support seek by position; ignore.
      return;
    }
    if (_castService.isConnected) {
      await _castService.seek(position);
    } else if (_upnpService.isConnected) {
      await _upnpService.seek(position);
    } else {
      await _audioPlayer.seek(position);
    }
    if (_absBookId != null) _syncAbsProgress();
    _logSeekBackIfNeeded(before, position);
    _brainPublishNow();
  }

  /// Seek-back signal: user jumped significantly backwards to re-listen —
  /// strong interest ("это хит"). Once per played track, music only
  /// (podcasts/audiobooks seek constantly and carry no taste signal).
  void _logSeekBackIfNeeded(Duration before, Duration after) {
    final song = _currentSong;
    if (song == null || _isPodcastSong(song)) return;
    if (after >= before - const Duration(seconds: 15)) return;
    if (_seekBackLoggedSongId == song.id) return;
    _seekBackLoggedSongId = song.id;

    try {
      _behaviorTracker.logSeekBack(song.id, after.inSeconds, genre: song.genre);
      _mlStore.recordSeekBack(song.id);
      _mlService.recordSeekBack(song.id, song: song);
      _timeAwareHistory.logPlay(song.id, DateTime.now().hour);
      _moodDriftDetector.logPositiveInteraction(song.id);
      final mabContext = _multiArmedBandit.getCurrentContext();
      if (song.artistId != null) {
        _multiArmedBandit.recordReward(
          song.artistId!,
          _multiArmedBandit.calculateReward('seek_back'),
          mabContext,
          'artist',
          song.artist,
        );
      }
      if (song.genre != null) {
        _multiArmedBandit.recordReward(
          song.genre!,
          _multiArmedBandit.calculateReward('seek_back'),
          mabContext,
          'genre',
          song.genre,
        );
      }
    } catch (_) {}
  }

  Future<void> seekToProgress(double progress) async {
    final position = Duration(
      milliseconds: (progress * _duration.inMilliseconds).round(),
    );
    await seek(position);
  }

  Future<void> skipNext() async {
    // ── Radio → Queue bridge: next скипает радио → играет очередь/бридж ──
    if (_isPlayingRadio) {
      if (_queue.isNotEmpty) {
        final nextSong = _queue.first;
        final idx = 0;
        _isPlayingRadio = false;
        _currentRadioStation = null;
        _isPlaying = false;
        try { await _audioPlayer.stop(); } catch (_) {}
        await playSong(nextSong, playlist: _queue, startIndex: idx);
        return;
      } else {
        // Генерим бридж на-лету если очередь пуста
        if (_recommendationService != null && _libraryProvider != null && _currentRadioStation != null) {
          final pool = await _libraryProvider!.getPoolForMix(limit: 700);
          if (pool.isNotEmpty) {
            final bridge = _recommendationService!.getRadioBridgeQueue(pool, _currentRadioStation!, limit: 5);
            if (bridge.isNotEmpty) {
              _isPlayingRadio = false;
              final st = _currentRadioStation;
              _currentRadioStation = null;
              _isPlaying = false;
              try { await _audioPlayer.stop(); } catch (_) {}
              debugPrint('[Player] Radio skip bridge → ${bridge.length} tracks for "${st?.name}"');
              await playSong(bridge.first, playlist: bridge, startIndex: 0);
              return;
            }
          }
        }
        stopRadio();
        return;
      }
    }
    if (!_isPodcastSong(_currentSong) && _currentSong != null && _recommendationService != null) {
      final played = _position.inSeconds;
      final total = _duration.inSeconds;
      // Дизлайки — только явной кнопкой. Быстрое листание (<15с) — нейтральная
      // навигация, а не негативный сигнал: иначе 3 переключения = "skip3"
      // автодизлайк на сервере + локальный счётчик к бану артиста.
      if (total > 0 && played < total * 0.8 && played >= 15) {
        _recommendationService!.trackSkip(_currentSong!);
        // Track skip in ML service (auto-dislike after 3 skips)
        _mlService.incrementSkipCount(
          _currentSong!.id,
          skipTimeMs: _position.inMilliseconds,
        );

        // Track in advanced ML engine
        _behaviorTracker.logSkip(_currentSong!.id, _position.inSeconds);
        _mlStore.incrementSkipCount(_currentSong!.id, _position.inSeconds);
        _moodDriftDetector.logSkip(_currentSong!.id, _currentSong);
        _brainEvent(_currentSong!.id, 'skip', positionSec: _position.inSeconds);

        // Record MAB reward for current artist/genre
        final mabContext = _multiArmedBandit.getCurrentContext();
        if (_currentSong!.artistId != null) {
          _multiArmedBandit.recordReward(
            _currentSong!.artistId!,
            _multiArmedBandit.calculateReward('skip_late'),
            mabContext,
            'artist',
            _currentSong!.artist,
          );
        }
        if (_currentSong!.genre != null) {
          _multiArmedBandit.recordReward(
            _currentSong!.genre!,
            _multiArmedBandit.calculateReward('skip_late'),
            mabContext,
            'genre',
            _currentSong!.genre,
          );
        }
        // Mark so playSong() doesn't also log this track as abandoned.
        _lastSkipLoggedId = _currentSong!.id;
      } else if (played > 0) {
        // Порог истории: пишем только если слушали ≥30с или ≥50% трека.
        // Короткие скипы — это trackSkip выше, а не прослушивание.
        _maybeCommitHistory(_currentSong!, played, total);
      }
    }

    if (_jukeboxService.enabled) {
      await _jukeboxService.skipNext(_subsonicService);
      return;
    }

    // Было await: ML-подбор жег главный поток прямо перед сиком (ANR).
    if (!_isPodcastSong(_currentSong) && _autoDjService.shouldAddSongsFor(_currentIndex, _queue.length, _currentSong)) {
      unawaited(_addAutoDjSongs());
    }

    if (_concatenatingSource != null) {
      if (_shuffleEnabled && _queue.length > 1) {
        _shuffleHistory.add(_currentSong!.id);
        if (_shuffleHistory.length > 50) _shuffleHistory.removeAt(0);
        int next;
        do {
          next = Random().nextInt(_queue.length);
        } while (next == _currentIndex);
        await _seekQueueIndex(next);
      } else if (_currentIndex < _queue.length - 1) {
        await _seekQueueIndex(_currentIndex + 1);
      } else if (_repeatMode == RepeatMode.all) {
        await _seekQueueIndex(0);
      }
      return;
    }

    if (_shuffleEnabled && _queue.length > 1) {
      _shuffleHistory.add(_currentSong!.id);
      if (_shuffleHistory.length > 50) _shuffleHistory.removeAt(0);
      int next;
      do {
        next = Random().nextInt(_queue.length);
      } while (next == _currentIndex);
      await skipToIndex(next);
    } else if (_currentIndex < _queue.length - 1) {
      await skipToIndex(_currentIndex + 1);
    } else if (_repeatMode == RepeatMode.all) {
      if (_queue.length == 1) {
        await seek(Duration.zero);
        await play();
      } else {
        await skipToIndex(0);
      }
    }
  }

  Future<void> _addAutoDjSongs() async {
    if (!_autoDjService.isEnabledForSong(_currentSong)) return;

    try {
      // Динамический плейлист: в офлайне докачка идёт из играемого пула
      // (скачанное/локальное), онлайн — как раньше с сервера/БД.
      List<Song>? fallback;
      try {
        if (_offlineService.isOfflineMode && _libraryProvider != null) {
          fallback = _libraryProvider!.playablePool();
        }
      } catch (_) {}
      final songsToAdd = await _autoDjService.getSongsToQueue(
        currentSong: _currentSong,
        currentQueue: _queue,
        // null = AutoDJ берет свежий стратифицированный пул из БД (гибрид),
        // вместо среза кэша. Разнообразие выше, RAM ниже.
        availableSongs: null,
        fallbackPool: fallback,
      );

      if (songsToAdd.isNotEmpty) {
        // Оркестрация на добавлении: плавные переходы без утяжеления генерации.
        List<Song> ordered = songsToAdd;
        try {
          ordered = PlaylistOrchestrator.orchestrate(
            songsToAdd, startWith: 'mixed', endWith: 'mixed');
        } catch (_) {}
        _queue.addAll(ordered);
        // append корректен только когда окно покрывает конец очереди.
        if (_concatenatingSource != null &&
            _windowStart + _concatenatingSource!.length ==
                _queue.length - ordered.length) {
          for (final song in ordered) {
            if (_concatenatingSource!.length >= _kGaplessMaxSources) break;
            try {
              final source = await _buildAudioSourceForSong(song);
              _concatenatingSource!.add(source);
            } catch (e) {
              debugPrint(
                  'Error adding AutoDJ song to concatenating source: $e');
            }
          }
        }
        notifyListeners();
        _saveQueueState();
        _brainPublishNow();
        debugPrint('Auto DJ added ${songsToAdd.length} songs to queue');
      }
    } catch (e) {
      debugPrint('Auto DJ error: $e');
    }
  }

  Future<void> skipPrevious() async {
    if (_isPlayingRadio) {
      // Radio has no previous — stop radio, if queue exists play last
      if (_queue.isNotEmpty) {
        final idx = _queue.length - 1;
        final prev = _queue[idx];
        _isPlayingRadio = false;
        _currentRadioStation = null;
        try { await _audioPlayer.stop(); } catch (_) {}
        await playSong(prev, playlist: _queue, startIndex: idx);
        return;
      } else {
        stopRadio();
        return;
      }
    }
    if (_jukeboxService.enabled) {
      await _jukeboxService.skipPrevious(_subsonicService);
      return;
    }
    if (_position.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }

    if (_concatenatingSource != null) {
      if (_shuffleEnabled && _shuffleHistory.isNotEmpty) {
        final prevId = _shuffleHistory.removeLast();
        final prev = _queue.indexWhere((s) => s.id == prevId);
        if (prev != -1) {
          await _seekQueueIndex(prev);
          return;
        }
      }
      if (_currentIndex > 0) {
        await _seekQueueIndex(_currentIndex - 1);
      } else if (_repeatMode == RepeatMode.all && _queue.isNotEmpty) {
        await _seekQueueIndex(_queue.length - 1);
      } else {
        await seek(Duration.zero);
      }
      return;
    }

    if (_shuffleEnabled && _shuffleHistory.isNotEmpty) {
      final prevId = _shuffleHistory.removeLast();
      final prev = _queue.indexWhere((s) => s.id == prevId);
      if (prev != -1) await skipToIndex(prev);
    } else if (_currentIndex > 0) {
      await skipToIndex(_currentIndex - 1);
    } else if (_repeatMode == RepeatMode.all && _queue.isNotEmpty) {
      if (_queue.length == 1) {
        await seek(Duration.zero);
        await play();
      } else {
        await skipToIndex(_queue.length - 1);
      }
    } else {
      await seek(Duration.zero);
    }
  }

  Future<void> skipToIndex(int index) async {
    if (index < 0 || index >= _queue.length) return;
    // В офлайне серверные треки без файла не трогаем — идём к ближайшему
    // играемому вперёд (иначе скип виснет на ошибке сети).
    if (_offlineService.isOfflineMode) {
      var target = index;
      while (target < _queue.length && !_hasPlayableFile(_queue[target])) {
        target++;
      }
      if (target >= _queue.length) {
        // Вперёд играемого нет — пробуем назад от текущего.
        target = index;
        while (target >= 0 && !_hasPlayableFile(_queue[target])) {
          target--;
        }
        if (target < 0) {
          debugPrint('[Player] offline: no playable track ahead/behind, keep current');
          return;
        }
      }
      if (target != index) {
        debugPrint('[Player] offline: skip $index → playable $target');
      }
      await _seekQueueIndex(target);
      return;
    }
    await _seekQueueIndex(index);
  }

  /// Сик на трек очереди: внутри окна — мгновенный seek по смещению,
  /// вне окна (или окна нет) — пересборка окна через playSong.
  Future<void> _seekQueueIndex(int queueIndex) async {
    if (_concatenatingSource != null &&
        _concatHasQueueIndex(queueIndex)) {
      await _audioPlayer.seek(
          Duration.zero, index: _queueToConcatIndex(queueIndex));
      return;
    }
    await playSong(_queue[queueIndex],
        playlist: _queue, startIndex: queueIndex);
  }

  void toggleShuffle() {
    _shuffleEnabled = !_shuffleEnabled;
    _shuffleHistory.clear();
    if (_shuffleEnabled && _queue.length > 1 && _currentSong != null) {
      final currentSong = _currentSong!;
      // Use orchestrator for smooth transitions
      final remaining = _queue.where((s) => s.id != currentSong.id).toList();
      final orchestrated = PlaylistOrchestrator.orchestrate(
        remaining,
        startWith: 'energetic',
        endWith: 'calm',
      );
      _queue = [currentSong, ...orchestrated];
      _currentIndex = 0;
      if (_concatenatingSource != null) {
        _buildAndSetConcatenatingSource(initialIndex: 0).catchError((e) {
          debugPrint('Error rebuilding concatenating source after shuffle: $e');
        });
      }
      _saveQueueState();
    }
    _storageService.saveShuffleMode(_shuffleEnabled);
    notifyListeners();
  }

  void toggleRepeat() {
    switch (_repeatMode) {
      case RepeatMode.off:
        _repeatMode = RepeatMode.all;
        _audioPlayer.setLoopMode(LoopMode.all);
        break;
      case RepeatMode.all:
        _repeatMode = RepeatMode.one;
        _audioPlayer.setLoopMode(LoopMode.one);
        break;
      case RepeatMode.one:
        _repeatMode = RepeatMode.off;
        _audioPlayer.setLoopMode(LoopMode.off);
        break;
    }
    _storageService.saveRepeatMode(_repeatMode.index);
    notifyListeners();
  }

  void toggleGaplessPlayback() {
    _gaplessEnabled = !_gaplessEnabled;
    _storageService.saveGaplessPlayback(_gaplessEnabled);
    try { BpmCrossfadeService().syncGaplessCrossfade(gapless: _gaplessEnabled); } catch (_) {}
    notifyListeners();
  }

  void addToQueue(Song song) {
    if (_queue.any((s) => s.id == song.id)) return;
    _queue.add(song);
    _brainPublishNow();
    notifyListeners();
  }

  Future<void> addToQueueNext(Song song) async {
    if (_queue.any((s) => s.id == song.id)) return;
    final insertIndex = _currentIndex + 1;
    if (insertIndex < _queue.length) {
      _queue.insert(insertIndex, song);
      // Вставка левее окна сдвигает его содержимое — двигаем базу.
      if (insertIndex <= _windowStart) _windowStart++;
    } else {
      _queue.add(song);
    }
    if (_concatenatingSource != null) {
      try {
        final audioSource = await _buildAudioSourceForSong(song);
        // Трансляция в координаты окна; вставка за пределами окна —
        // только в _queue, окно пересоберётся при дальнем сике.
        final ci = _queueToConcatIndex(insertIndex);
        if (ci >= 0 && ci <= _concatenatingSource!.length) {
          if (ci < _concatenatingSource!.length) {
            _concatenatingSource!.insert(ci, audioSource);
          } else {
            _concatenatingSource!.add(audioSource);
          }
        }
      } catch (e) {
        debugPrint('Error adding to concatenating source: $e');
      }
    }
    _brainPublishNow();
    notifyListeners();
  }

  Future<void> addAllToQueue(Iterable<Song> songs) async {
    // Фильтруем дубли по id перед добавлением в очередь
    final seen = _queue.map((s) => s.id).toSet();
    final newSongs = <Song>[];
    for (final s in songs) {
      if (seen.add(s.id)) newSongs.add(s);
    }
    if (newSongs.isEmpty) return;
    _queue.addAll(newSongs);
    // source.add() корректен только когда окно покрывает конец очереди
    // (иначе конец source маппится не на хвост). Плюс потолок окна.
    if (_concatenatingSource != null &&
        _windowStart + _concatenatingSource!.length ==
            _queue.length - newSongs.length) {
      for (final song in newSongs) {
        if (_concatenatingSource!.length >= _kGaplessMaxSources) break;
        try {
          final source = await _buildAudioSourceForSong(song);
          _concatenatingSource!.add(source);
        } catch (e) {
          debugPrint('Error adding to concatenating source: $e');
        }
      }
    }
    notifyListeners();
    _brainPublishNow();
  }

  void removeFromQueue(int index) {
    if (index >= 0 && index < _queue.length) {
      _queue.removeAt(index);
      // Трансляция в координаты окна.
      if (_concatenatingSource != null) {
        if (index < _windowStart) {
          _windowStart--;
        } else {
          final ci = _queueToConcatIndex(index);
          if (ci >= 0 && ci < _concatenatingSource!.length) {
            try {
              _concatenatingSource!.removeAt(ci);
            } catch (e) {
              debugPrint('Error removing from concatenating source: $e');
            }
          }
        }
      }
      if (index < _currentIndex) {
        _currentIndex--;
      } else if (index == _currentIndex && _queue.isNotEmpty) {
        if (_currentIndex >= _queue.length) {
          _currentIndex = _queue.length - 1;
        }
        if (_queue.isNotEmpty) {
          playSong(
            _queue[_currentIndex],
            playlist: _queue,
            startIndex: _currentIndex,
          );
        }
      }
      _saveQueueState();
      notifyListeners();
      _brainPublishNow();
    }
  }

  void clearQueue() {
    _queue.clear();
    _currentIndex = -1;
    _currentSong = null;
    _concatenatingSource = null;
    _windowStart = 0;
    try {
      _discordRpcService.clearPresence();
    } catch (_) {}
    // Clear lyrics when clearing queue
    try {
      _lyricsService.stopSync();
    } catch (_) {}
    _clearPersistedQueue();
    try {
      _lyricsService.loadLyrics(null);
    } catch (_) {}
    _audioPlayer.stop();
    _isPlaying = false;
    _position = Duration.zero;
    notifyListeners();
    _updateAndroidAuto();
    _brainPublishNow();
  }

  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }

    final song = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, song);

    if (_concatenatingSource != null) {
      // move внутри окна — транслируем; через границу окна маппинг
      // поплывёт, поэтому окно сбрасываем (пересоберётся при следующем
      // сике через playSong), звук при этом не рвём.
      final to = _queueToConcatIndex(newIndex);
      final len = _concatenatingSource!.length;
      // Координаты «до» операции: элемент стоял на oldIndex.
      final fromBefore = _queueToConcatIndex(oldIndex);
      final bothInside = fromBefore >= 0 &&
          fromBefore < len &&
          to >= 0 &&
          to < len;
      if (bothInside) {
        try {
          _concatenatingSource!.move(fromBefore, to);
        } catch (e) {
          debugPrint('Error moving in concatenating source: $e');
        }
      } else {
        _concatenatingSource = null;
      }
    }

    if (oldIndex == _currentIndex) {
      _currentIndex = newIndex;
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      _currentIndex -= 1;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      _currentIndex += 1;
    }

    notifyListeners();
    _saveQueueState();
    _brainPublishNow();
  }

  // Cast / UPnP: громкость и методы — в part player/player_cast.dart.
  // Поле здесь: в extension instance-поля запрещены.
  bool _upnpVolumeWriteInProgress = false;

  // ── Gapless playback helpers ───────────────────────────────────────────

  bool _isPodcastSong(Song? s) => s != null && (s.genre == 'Podcast' || s.id.startsWith('podcast:'));

  // Gapless-источники: методы — в part player/player_sources.dart.

  Future<void> _applyReplayGain(Song? song) async {
    await _replayGainService.initialize();

    final replayGainMultiplier = _replayGainService.calculateVolumeMultiplier(
      trackGain: song?.replayGainTrackGain,
      albumGain: song?.replayGainAlbumGain,
      trackPeak: song?.replayGainTrackPeak,
      albumPeak: song?.replayGainAlbumPeak,
    );

    final effectiveVolume = _volume * replayGainMultiplier;
    await _audioPlayer.setVolume(effectiveVolume);
  }

  Future<void> refreshReplayGain() async {
    await _applyReplayGain(_currentSong);
    notifyListeners();
  }

  ReplayGainService get replayGainService => _replayGainService;

  // ML Engine getters for UI access
  RecommendationService? get recommendationService => _recommendationService;
  MLStore get mlStore => _mlStore;
  VibeSimilarity get vibeSimilarity => _vibeSimilarity;
  MoodDriftDetector get moodDriftDetector => _moodDriftDetector;
  BehaviorTracker get behaviorTracker => _behaviorTracker;
  MultiArmedBandit get multiArmedBandit => _multiArmedBandit;
  SonicFingerprintService get sonicFingerprint => _sonicFingerprint;
  MLWaveService get mlWaveService => _mlWaveService;
  SmartAutoDJ get smartAutoDJ => _smartAutoDJ;
  TimeAwareHistory get timeAwareHistory => _timeAwareHistory;
  TrackScorer get trackScorer => _trackScorer;
  ExplainableAI get explainableAI => _explainableAI;

  /// Generate a personalized "My Wave" playlist using the ML engine
  // Волна и оценки: методы — в part player/player_wave.dart.
  // Поле здесь: в extension instance-поля запрещены.
  bool _dislikeSkipBusy = false;

  Future<void> reactivateAudioSession() async {
    await _androidSystemService.requestAudioFocus();

    if (_currentSong != null) {
      _updateAllServices();
    }

    if (Platform.isIOS) {
      try {
        final session = await AudioSession.instance;
        await session.setActive(true);

        // Wait a bit for the audio session to stabilize
        await Future.delayed(const Duration(milliseconds: 100));

        // If there's a current song and audio is not playing, resume it
        // This handles the case where iOS pauses audio when dismissing the player
        if (_currentSong != null && !_audioPlayer.playing) {
          debugPrint(
              '[Player] iOS: Resuming playback after audio session reactivation (song: ${_currentSong!.title})');
          await _audioPlayer.play();
          _isPlaying = true;
          notifyListeners();
          _updateAllServices();
        }
      } catch (e) {
        debugPrint('[Player] iOS: Error reactivating audio session: $e');
      }
    }
  }

  @override
  // Live-зеркало: heartbeat-таймер и one-shot флаг resume
  // (методы — в part player/player_live.dart).
  Timer? _liveHeartbeat;
  bool _resumeDone = false;

  void dispose() {
    _stopNowPlayingTimer();
    _sleepTimer?.cancel();
    _sleepTimerFadeTimer?.cancel();
    _sleepTimerFadePeriodicTimer?.cancel();
    // Save queue state immediately before cancelling the debounce timer
    _saveQueueStateImmediate();
    _persistDebounceTimer?.cancel();
    _jukeboxPollTimer?.cancel();
    _jukeboxService.removeListener(_onJukeboxEnabledChanged);
    _offlineService.removeListener(_onOfflineModeChanged);
    _windowsPositionTimer?.cancel();
    _watchdogTimer?.cancel();
    _stopLiveHeartbeat();
    _castService.removeListener(_onCastStateChanged);
    _upnpService.removeListener(_onUpnpStateChanged);
    if (_upnpService.onRendererLost == _onUpnpRendererLost) {
      _upnpService.onRendererLost = null;
    }
    // Stop playback before disposing audio handler to prevent NPE on Android
    _audioPlayer.stop().catchError((_) {});

    // Dispose audio handler with error handling
    _audioHandler.customAction('dispose').catchError((e) {
      debugPrint('Error disposing audio handler: $e');
    });

    try {
      _androidAutoService.dispose();
    } catch (_) {}
    try {
      _androidSystemService.dispose();
    } catch (_) {}
    try {
      _windowsService.dispose();
    } catch (_) {}
    try {
      _bluetoothService.dispose();
    } catch (_) {}
    try {
      _samsungService.dispose();
    } catch (_) {}

    // Dispose lyrics service
    try {
      _lyricsService.dispose();
    } catch (_) {}

    try {
      _discordRpcService.shutdown();
    } catch (_) {}
    _playerStateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _currentIndexSub?.cancel();
    _positionController.close();
    // Remove app lifecycle observer
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Discord RPC: методы — в part player/player_discord.dart.
  String _discordRpcStateStyle = 'artist';

  // Cast / UPnP: методы — в part player/player_cast.dart.
  // Поля здесь: в extension instance-поля запрещены.
  bool _upnpWasConnected = false;
  bool _upnpWasPlaying = false;
  // True when an A2DP audio-output device (car, speaker) is connected.
  // Control-only devices (Garmin watch, etc.) don't set this flag.
  bool _isA2dpAudioActive = false;
}


