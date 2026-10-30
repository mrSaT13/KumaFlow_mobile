import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import '../services/services.dart';
import '../services/local_music_service.dart';
import '../services/yandex_enrichment_service.dart';
import '../services/ml_service.dart';
import '../services/ml/ml_store.dart' as ml_store_lib;
import '../services/ml/audio_features_cache.dart';

class LibraryProvider extends ChangeNotifier {
  final SubsonicService _subsonicService;
  final AndroidAutoService _androidAutoService = AndroidAutoService();

  bool _localOnlyMode = false;
  bool _serverOfflineMode = false;
  bool _mergeLocalLibrary = false;
  LocalMusicService? _localMusicService;
  final LibraryDatabaseService _db = LibraryDatabaseService();

  static const String _kMergeLocalLibrary = 'merge_local_library';

  List<Artist> _artists = [];
  List<Album> _recentAlbums = [];
  List<Album> _frequentAlbums = [];
  List<Album> _newestAlbums = [];
  List<Album> _randomAlbums = [];
  List<Playlist> _playlists = [];
  List<Song> _randomSongs = [];
  List<String> _genres = [];
  List<Genre> _richGenres = [];
  SearchResult? _starred;

  List<Album> _cachedAllAlbums = [];
  List<Song> _cachedAllSongs = [];
  List<Playlist> _cachedPlaylists = [];
  DateTime? _lastCacheUpdate;

  bool _isLoading = false;
  bool _isInitialized = false;
  String? _error;

  // Sync progress tracking
  bool _isSyncing = false;
  int _syncedSongs = 0;
  int _totalSongsEstimate = 0;
  String _syncPhase = '';
  bool _supportsSearch3 = false;

  /// Троттлинг прогресса синка: notifyListeners не чаще 1/сек, чтобы UI
  /// не перестраивался на каждой странице во время воспроизведения.
  DateTime _lastSyncNotify = DateTime.fromMillisecondsSinceEpoch(0);
  void _notifySyncProgress({bool force = false}) {
    final now = DateTime.now();
    if (force || now.difference(_lastSyncNotify).inMilliseconds >= 1000) {
      _lastSyncNotify = now;
      notifyListeners();
    }
  }

  /// Колбэк "сейчас играет?" — ставит main_screen. Если играет, синк стартует
  /// с паузой и идёт маленькими батчами, чтобы не душить сервер и стрим.
  bool Function()? isPlayingCheck;
  // ignore: avoid_setters_without_getters
  set playingCheck(bool Function() fn) => isPlayingCheck = fn;

  bool _yandexEnrichRunning = false;
  DateTime? _lastYandexEnrich;

  static const String _playlistsCacheKey = 'cached_playlists';
  static const String _artistsCacheKey = 'cached_artists';
  static const String _lastUpdateKey = 'last_cache_update';
  static const String _starredCacheKey = 'cached_starred_v1';

  LibraryProvider(this._subsonicService) {
    // Register callback to push library data when Android Auto service requests it
    _androidAutoService.onRequestLibraryData = _onRequestLibraryData;
    // Бесшовный офлайн->онлайн: флаг сети — единый источник, тихий рефреш
    // при возврате (иначе _serverOfflineMode залипал до рестарта).
    try {
      OfflineService().addOnlineListener(_onNetworkRestored);
      OfflineService().addListener(_onOfflineServiceChanged);
    } catch (_) {}
  }

  void _onOfflineServiceChanged() {
    final offline =
        _serverOfflineMode || OfflineService().isOfflineMode;
    // Только нотификация: тяжёлый рефреш — в _onNetworkRestored/refreshOnline.
    if (offline != _lastOfflineBroadcast) {
      _lastOfflineBroadcast = offline;
      notifyListeners();
    }
  }

  bool _lastOfflineBroadcast = false;
  bool _refreshOnlineInFlight = false;

  /// Лёгкий онлайн-рефреш без полного ресинка БД (фаза-2 initialize):
  /// недавние/случайные/плейлисты/артисты/лайки. Безопасно звать на каждый
  /// возврат сети; тяжёлый _refreshAllDataInBackground — только если кэш пуст.
  ///
  /// Строго последовательно с короткими капами: параллельный залп из пяти
  /// висящих запросов кладёт и так медленный сервер (502, 13.10.2026).
  /// При первом провале останавливаемся — кэш уже показан.
  Future<void> _loadSectionsLight() async {
    for (final loader in <Future<void> Function()>[
      loadRecentAlbums,
      loadRandomSongs,
      loadPlaylists,
      loadArtists,
      loadStarred,
    ]) {
      try {
        await loader().timeout(const Duration(seconds: 6));
      } catch (_) {
        break;
      }
    }
  }

  Future<void> refreshOnline() async {
    if (_refreshOnlineInFlight) return;
    if (_serverOfflineMode || OfflineService().isOfflineMode) return;
    _refreshOnlineInFlight = true;
    try {
      await _loadSectionsLight();
      notifyListeners();
      if (_cachedAllSongs.isEmpty) {
        unawaited(_refreshAllDataInBackground());
      }
    } catch (e) {
      debugPrint('[Library] refreshOnline failed: $e');
    } finally {
      _refreshOnlineInFlight = false;
    }
  }

  void _onNetworkRestored() {
    // Сбрасываем залипший серверный флаг (ставился разово из MainScreen)
    // и тихо тянем свежие данные — музыка не прерывается.
    if (_serverOfflineMode) {
      _serverOfflineMode = false;
    }
    _lastOfflineBroadcast = false;
    notifyListeners();
    unawaited(refreshOnline());
  }
  SubsonicService get subsonicService => _subsonicService;

  void _onRequestLibraryData() {
    debugPrint('LibraryProvider: Android Auto requested library data');
    if (_isInitialized) {
      if (_serverOfflineMode) {
        _pushOfflineLibraryToAndroidAuto();
      } else {
        _pushLibraryToAndroidAuto();
      }
    } else {
      // If not initialized yet, try to initialize and then push
      if (!_isLoading) {
        initialize().then((_) {
          if (_serverOfflineMode) {
            _pushOfflineLibraryToAndroidAuto();
          } else {
            _pushLibraryToAndroidAuto();
          }
        });
      }
    }
  }

  void setLocalMusicService(LocalMusicService service,
      {bool mergeWithServer = false}) {
    _localMusicService?.removeListener(_onLocalMusicServiceChanged);
    _localMusicService = service;
    _mergeLocalLibrary = mergeWithServer;
    // Don't force _localOnlyMode here — it is controlled explicitly via
    // setLocalOnlyMode() by main_screen. Previously this line forced
    // localOnly=true when merge=false, which broke server-only mode and
    // made the toggle appear to re-enable itself.
    if (mergeWithServer) {
      _localOnlyMode = false;
    }
    _isInitialized = false;
    service.addListener(_onLocalMusicServiceChanged);
    if (mergeWithServer) {
      _onLocalMusicServiceChanged();
    }
    if (mergeWithServer) {
      _saveMergeLocalLibrary(true);
    }
  }

  void _onLocalMusicServiceChanged() {
    if (_localMusicService == null || _localMusicService!.isScanning) return;

    if (_localOnlyMode) {
      // Local only mode - use only local library
      _cachedAllSongs = List.from(_localMusicService!.songs);
      _cachedAllAlbums = List.from(_localMusicService!.albums);
      _artists = List.from(_localMusicService!.artists);
      _randomSongs = _cachedAllSongs.take(50).toList();
      _recentAlbums = _cachedAllAlbums.take(20).toList();
      _isInitialized = true;
      _isLoading = false;
      notifyListeners();
      _triggerYandexEnrichment();
    } else if (_mergeLocalLibrary) {
      // Merge mode - just notify that local library changed
      // The getters will handle the merging
      notifyListeners();
      _triggerYandexEnrichment();
    }
  }

  void _triggerYandexEnrichment() {
    if (_cachedAllSongs.isEmpty) return;
    // Офлайн: сеть обречена, каждый вызов горит таймаутом 10с и держит
    // очередь (ANR на старте 13.10.2026). Только при живой сети.
    if (isOfflineNow) return;
    if (_yandexEnrichRunning) return;
    final now = DateTime.now();
    if (_lastYandexEnrich != null && now.difference(_lastYandexEnrich!).inSeconds < 15) return;
    _yandexEnrichRunning = true;
    _lastYandexEnrich = now;
    // Фоново, без токена, только для треков без жанра — до 15 за раз, с мьютексом и дебаунсом 15с
    Future.microtask(() async {
      try {
        final count = await YandexEnrichmentService().enrichBatch(_cachedAllSongs, limit: 15);
        if (count > 0) {
          debugPrint('[LibraryProvider] Yandex enrich: +$count жанров');
          notifyListeners();
        }
      } catch (e) {
        debugPrint('[LibraryProvider] Yandex enrich error: $e');
      } finally {
        _yandexEnrichRunning = false;
      }
    });
  }

  /// Toggle merging local library with server library
  void setMergeLocalLibrary(bool enabled) {
    if (_mergeLocalLibrary == enabled) return;
    _mergeLocalLibrary = enabled;
    _saveMergeLocalLibrary(enabled);
    notifyListeners();
  }

  Future<void> _saveMergeLocalLibrary(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kMergeLocalLibrary, enabled);
  }

  Future<void> _loadMergeLocalLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    _mergeLocalLibrary = prefs.getBool(_kMergeLocalLibrary) ?? false;
  }

  void setLocalOnlyMode(bool enabled) {
    if (!enabled && _localOnlyMode) {
      _localMusicService?.removeListener(_onLocalMusicServiceChanged);
      _localMusicService = null;
      _cachedAllSongs = [];
      _cachedAllAlbums = [];
      _artists = [];
      _randomSongs = [];
      _recentAlbums = [];
      _playlists = [];
      _cachedPlaylists = [];
    }
    _localOnlyMode = enabled;
    _isInitialized = false;
    notifyListeners();
  }

  bool get isLocalOnlyMode => _localOnlyMode;
  bool get isServerOfflineMode => _serverOfflineMode;

  /// Единый флаг «мы в офлайне» (ручной офлайн-режим сервера или пропавшая сеть).
  bool get isOfflineNow => _serverOfflineMode || OfflineService().isOfflineMode;

  /// Все файлы доступные без сети: скачанные треки + локальные файлы телефона
  /// + всё у чего есть файл на диске. Используется волной/миксами в офлайне
  /// вместо полного пула (неиграемые серверные треки в волну не попадают).
  List<Song> get offlineSongs {
    final off = OfflineService();
    final downloadedIds = off.getDownloadedSongIds().toSet();
    final localSongs = _localMusicService?.songs ?? const <Song>[];
    final localIds = localSongs.map((s) => s.id).toSet();
    bool hasFile(Song s) {
      if (s.isLocal == true) return true;
      if (downloadedIds.contains(s.id) || localIds.contains(s.id)) return true;
      if (off.getLocalPath(s.id) != null) return true;
      if (off.getLocalPath(s.queueKey) != null) return true;
      return false;
    }

    final result = _cachedAllSongs.where(hasFile).toList();
    for (final ls in localSongs) {
      if (!result.any((s) => s.id == ls.id)) result.add(ls);
    }
    if (result.isEmpty) {
      result.addAll(_randomSongs.where(hasFile));
    }
    return result;
  }

  /// Пул для волны/миксов: в офлайне — только играемое (offlineSongs),
  /// иначе — как раньше (весь кеш или random).
  List<Song> playablePool() {
    if (isOfflineNow) {
      final off = offlineSongs;
      if (off.isNotEmpty) return off;
    }
    if (_cachedAllSongs.isNotEmpty) return cachedAllSongs;
    return _randomSongs;
  }
  bool get mergeLocalLibrary => _mergeLocalLibrary;

  void setServerOfflineMode(bool offline) {
    if (_serverOfflineMode == offline) return;
    _serverOfflineMode = offline;
    _lastOfflineBroadcast = offline || OfflineService().isOfflineMode;
    notifyListeners();
  }

  String getCoverArtUrl(String? coverArt) {
    return _subsonicService.getCoverArtUrl(coverArt, size: 300);
  }

  List<Album> get recentAlbums => _recentAlbums;
  List<Album> get frequentAlbums => _frequentAlbums;
  List<Album> get newestAlbums => _newestAlbums;
  List<Album> get randomAlbums => _randomAlbums;
  List<Playlist> get playlists => _playlists;

  /// Виртуальные плейлисты из добавленных локальных папок: по одному на
  /// каждый custom scan path + общий «Все локальные файлы».
  /// Только чтение (id с префиксом local-folder:) — сервер их не трогает,
  /// сюда же ложится ML/оркестратор по BPM: миксы уже умеют локальные треки.
  List<Playlist> get localFolderPlaylists {
    final local = _localMusicService;
    if (local == null) return const [];
    final songs = local.songs
        .where((s) => s.path != null && s.path!.isNotEmpty)
        .toList();
    if (songs.isEmpty) return const [];
    String norm(String p) => p.replaceAll('\\', '/').toLowerCase();
    final out = <Playlist>[];
    for (final folder in local.customScanPaths) {
      final f = norm(folder);
      final inFolder =
          songs.where((s) => norm(s.path!).startsWith(f)).toList();
      if (inFolder.isEmpty) continue;
      final parts =
          folder.split(RegExp(r'[\\/]')).where((e) => e.isNotEmpty).toList();
      final name = parts.isNotEmpty ? parts.last : folder;
      final dur = inFolder.fold<int>(0, (a, s) => a + (s.duration ?? 0));
      out.add(Playlist(
        id: 'local-folder:$folder',
        name: name,
        comment: folder,
        songCount: inFolder.length,
        duration: dur,
        songs: inFolder,
      ));
    }
    final totalDur = songs.fold<int>(0, (a, s) => a + (s.duration ?? 0));
    out.insert(
      0,
      Playlist(
        id: 'local-folder:__all__',
        name: 'Все локальные файлы',
        songCount: songs.length,
        duration: totalDur,
        songs: songs,
      ),
    );
    return out;
  }

  /// Виртуальный локальный плейлист по id (без сети, только чтение).
  Playlist? getLocalFolderPlaylist(String playlistId) {
    if (!playlistId.startsWith('local-folder:')) return null;
    for (final p in localFolderPlaylists) {
      if (p.id == playlistId) return p;
    }
    return null;
  }
  List<Song> get randomSongs => _randomSongs;
  List<String> get genres => _genres;
  List<Genre> get richGenres => _richGenres;
  SearchResult? get starred => _starred;
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;
  String? get error => _error;

  // Sync progress getters
  bool get isSyncing => _isSyncing;
  int get syncedSongs => _syncedSongs;
  int get totalSongsEstimate => _totalSongsEstimate;
  String get syncPhase => _syncPhase;
  bool get supportsSearch3 => _supportsSearch3;

  List<Album> get cachedAllAlbums {
    final isOffline = _serverOfflineMode || OfflineService().isOfflineMode;
    final shouldMergeLocal = isOffline || _mergeLocalLibrary;
    if (!shouldMergeLocal ||
        _localMusicService == null ||
        _localMusicService!.isEmpty) {
      return _cachedAllAlbums;
    }
    // Merge server albums with local albums — Set для O(1)
    final localAlbums = _localMusicService!.albums;
    final merged = [..._cachedAllAlbums];
    final seenIds = merged.map((a) => a.id).toSet();
    for (final localAlbum in localAlbums) {
      if (seenIds.add(localAlbum.id)) {
        merged.add(localAlbum);
      }
    }
    return merged;
  }

  /// Совместимость: ограниченный рабочий набор (<=800), НЕ вся библиотека.
  /// Точные данные — getSongsPage/searchDbAsync/getSongsByArtistId/getPoolForMix.
  List<Song> get cachedAllSongs {
    // When not merging, exclude DB-stored locals (isLocal).
    // In offline mode local files must remain visible even if merge is off.
    List<Song> base = _cachedAllSongs;
    final shouldFilterLocals = !_mergeLocalLibrary && !_localOnlyMode && !(_serverOfflineMode || OfflineService().isOfflineMode);
    if (shouldFilterLocals) {
      base = base.where((s) => !s.isLocal).toList();
    }
    final isOffline = _serverOfflineMode || OfflineService().isOfflineMode;
    final shouldMergeLocal = isOffline || _mergeLocalLibrary;
    if (!shouldMergeLocal ||
        _localMusicService == null ||
        _localMusicService!.isEmpty) {
      return base;
    }
    // Merge server songs with local songs — Set для O(1) вместо O(n*m) any()
    final localSongs = _localMusicService!.songs;
    final merged = [...base];
    final seenIds = merged.map((s) => s.id).toSet();
    for (final localSong in localSongs) {
      if (seenIds.add(localSong.id)) {
        merged.add(localSong);
      }
    }
    return merged;
  }

  List<Artist> get artists {
    final isOffline = _serverOfflineMode || OfflineService().isOfflineMode;
    final shouldMergeLocal = isOffline || _mergeLocalLibrary;
    if (!shouldMergeLocal ||
        _localMusicService == null ||
        _localMusicService!.isEmpty) {
      return _artists;
    }
    // Merge server artists with local artists
    final localArtists = _localMusicService!.artists;
    final merged = [..._artists];
    final seenIds = merged.map((a) => a.id).toSet();
    for (final localArtist in localArtists) {
      if (seenIds.add(localArtist.id)) {
        merged.add(localArtist);
      }
    }
    return merged;
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    await _loadMergeLocalLibrary();

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      if (_localOnlyMode && _localMusicService != null) {
        _cachedAllSongs = List.from(_localMusicService!.songs);
        _cachedAllAlbums = List.from(_localMusicService!.albums);
        _artists = List.from(_localMusicService!.artists);
        _randomSongs = _cachedAllSongs.take(50).toList();
        _recentAlbums = _cachedAllAlbums.take(20).toList();
        _isInitialized = true;
        _isLoading = false;
        notifyListeners();
        return;
      }

      await _loadCachedData(loadFullLibrary: true);

      if (_recentAlbums.isEmpty && _cachedAllAlbums.isNotEmpty) {
        _recentAlbums = _cachedAllAlbums.take(20).toList();
      }
      if (_randomSongs.isEmpty && _cachedAllSongs.isNotEmpty) {
        _randomSongs = _cachedAllSongs.take(50).toList();
      }
      if (_playlists.isEmpty && _cachedPlaylists.isNotEmpty) {
        _playlists = _cachedPlaylists;
      }

      // ── Phase 1: показать кэш мгновенно (Substreamer-like) ──
      _isInitialized = true;
      _isLoading = false;
      _preloadCoverArt();
      _scheduleBackgroundRefresh();
      _triggerYandexEnrichment();
      if (_serverOfflineMode) {
        _pushOfflineLibraryToAndroidAuto();
      } else {
        _pushLibraryToAndroidAuto();
      }
      Future.delayed(const Duration(milliseconds: 800), () {
        if (_serverOfflineMode) {
          _pushOfflineLibraryToAndroidAuto();
        } else {
          _pushLibraryToAndroidAuto();
        }
      });
      notifyListeners();

      // ── Phase 2: сеть в фоне, не блокирует UI ──
      // Секции строго по очереди (см. _loadSectionsLight): залп вешает сервер.
      if (!_serverOfflineMode) {
        Future.microtask(() async {
          try {
            await _loadSectionsLight();
            // Обновить UI после фоновой догрузки
            notifyListeners();
          } catch (serverError) {
            debugPrint('Server initialization skipped: $serverError');
          }
        });
      }
      return;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> ensureLibraryLoaded() async {
    if (_cachedAllSongs.isNotEmpty) {
      _triggerYandexEnrichment();
      return;
    }

    if (_localOnlyMode && _localMusicService != null) {
      _cachedAllSongs = List.from(_localMusicService!.songs);
      _cachedAllAlbums = List.from(_localMusicService!.albums);
      _artists = List.from(_localMusicService!.artists);
      _randomSongs = _cachedAllSongs.take(50).toList();
      _recentAlbums = _cachedAllAlbums.take(20).toList();
      notifyListeners();
      _triggerYandexEnrichment();
      return;
    }

    _isLoading = true;
    notifyListeners();

    await _loadCachedData(loadFullLibrary: true);

    if (_cachedAllSongs.isEmpty) {
      await _refreshAllDataInBackground();
    } else {
      _triggerYandexEnrichment();
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> _loadCachedData({bool loadFullLibrary = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final playlistsJson = prefs.getString(_playlistsCacheKey);
      if (playlistsJson != null) {
        final List<dynamic> playlistsList = json.decode(playlistsJson);
        _cachedPlaylists = playlistsList
            .map((p) => Playlist.fromJson(p as Map<String, dynamic>))
            .toList();
        _playlists = _cachedPlaylists;
      }

      final artistsJson = prefs.getString(_artistsCacheKey);
      if (artistsJson != null) {
        final List<dynamic> artistsList = json.decode(artistsJson);
        _artists = artistsList
            .map((a) => Artist.fromJson(a as Map<String, dynamic>))
            .toList();
      }

      final starredJson = prefs.getString(_starredCacheKey);
      if (starredJson != null) {
        try {
          final m = json.decode(starredJson) as Map<String, dynamic>;
          final artists = (m['artists'] as List?)?.map((a) => Artist.fromJson(a as Map<String, dynamic>)).toList() ?? [];
          final albums = (m['albums'] as List?)?.map((a) => Album.fromJson(a as Map<String, dynamic>)).toList() ?? [];
          final songs = (m['songs'] as List?)?.map((s) => Song.fromJson(s as Map<String, dynamic>)).toList() ?? [];
          _starred = SearchResult(artists: artists, albums: albums, songs: songs);
        } catch (_) {}
      }

      if (loadFullLibrary) {
        // Третий заход: 80к больше не грузим. Альбомов ~10x меньше — их можно,
        // песни — только рабочий набор 800 (случайная выборка полных объектов
        // для пулов/витрин). Точные данные — точечными SQL-методами ниже.
        try {
          _cachedAllAlbums = await _db.getAllAlbums();
        } catch (e) {
          debugPrint('Error loading albums from DB: $e');
        }
        try {
          _cachedAllSongs = await _db.getRandomSongsSample(limit: 800);
        } catch (e) {
          debugPrint('Error loading working set from DB: $e');
        }
      }

      final lastUpdate = prefs.getInt(_lastUpdateKey);
      if (lastUpdate != null) {
        _lastCacheUpdate = DateTime.fromMillisecondsSinceEpoch(lastUpdate);
      }
    } catch (e) {
      debugPrint('Error loading cached data: $e');
    }
  }

  void _scheduleBackgroundRefresh() {
    // Если кэш пуст (первый запуск) — синк нужен, иначе пусто.
    // Чуть позже, когда UI уже жив, и только при живой сети.
    if (_cachedAllSongs.isEmpty) {
      debugPrint('[LibraryProvider] Cache empty - scheduling initial sync');
      Future.delayed(const Duration(seconds: 4), () {
        if (!_serverOfflineMode && !OfflineService().isOfflineMode) {
          _refreshAllDataInBackground();
        }
      });
      return;
    }

    // Протухший кэш на старте больше НЕ синкаем сами: полный синк —
    // только вручную (pull-to-refresh / refresh()). Авто-синк каждый
    // запуск душил сервер (502, 13.10.2026).
    if (_lastCacheUpdate == null ||
        DateTime.now().difference(_lastCacheUpdate!) > const Duration(hours: 24)) {
      debugPrint('[LibraryProvider] Cache stale - sync only manually (pull-to-refresh)');
    } else {
      debugPrint('[LibraryProvider] Cache fresh - skipping auto sync');
    }
  }

  Future<void> _refreshAllDataInBackground() async {
    if (_isSyncing) {
      debugPrint('[LibrarySync] Already syncing - skip duplicate refresh');
      return;
    }
    try {
      // Если трек играет — даём стриму фору 3с, синк пойдёт мелкими батчами.
      try {
        if (isPlayingCheck?.call() == true) {
          await Future.delayed(const Duration(seconds: 3));
        }
      } catch (_) {}
      _isSyncing = true;
      _syncedSongs = 0;
      _totalSongsEstimate = 0;
      _syncPhase = 'probe';
      _lastSyncNotify = DateTime.now();
      notifyListeners();

      // Incremental sync: do NOT clear DB before refresh to avoid wiping
      // 55k+ cache on every launch. Inserts are upserts; stale entries
      // will be overwritten. Use refresh() for full reset if needed.

      final seenSongIds = <String>{};
      final List<Album> allAlbums = [];
      var failedAlbumLoads = 0;

      // Probe search3 support (empty query, 1 album, with offset)
      _supportsSearch3 = await _subsonicService.probeSearch3();
      debugPrint('search3 probe: ${_supportsSearch3 ? "supported" : "not supported"}');

      if (_subsonicService.isJellyfin) {
        // ── Jellyfin: O(1) bulk fetch ────────────────────────────────────
        _syncPhase = 'albums';
        notifyListeners();

        try {
          final allSongs = await _subsonicService.getAllSongs()
              .timeout(const Duration(seconds: 60));
          _totalSongsEstimate = allSongs.length;
          _syncPhase = 'songs';
          notifyListeners();

          for (final song in allSongs) {
            seenSongIds.add(song.id);
          }
          await _db.insertSongsBatch(allSongs);
          _syncedSongs = allSongs.length;
          notifyListeners();
        } catch (e) {
          debugPrint('Jellyfin getAllSongs failed: $e');
        }

        // Still need albums for the UI
        const pageSize = 200;
        int offset = 0;
        while (true) {
          List<Album> page;
          try {
            page = await _subsonicService.getAlbumList(
              type: 'alphabeticalByName', size: pageSize, offset: offset,
            ).timeout(const Duration(seconds: 25));
          } catch (e) {
            debugPrint('[LibrarySync] Jellyfin albums page failed: $e');
            break;
          }
          if (page.isEmpty) break;
          allAlbums.addAll(page);
          await _db.insertAlbumsBatch(page);
          if (page.length < pageSize) break;
          offset += pageSize;
        }

      } else if (_supportsSearch3) {
        // ── Fast path: search3 bulk fetch ─────────────────────────────────
        debugPrint('[LibrarySync] Using search3 fast path');

        // Phase 1: Albums via search3
        _syncPhase = 'albums';
        _notifySyncProgress(force: true);

        const albumPageSize = 200;
        int albumOffset = 0;
        var pageErrors = 0;
        while (true) {
          List<Album> page;
          try {
            page = await _subsonicService.search3AlbumsPage(
              offset: albumOffset, count: albumPageSize,
            ).timeout(const Duration(seconds: 25));
          } catch (e) {
            debugPrint('[LibrarySync] Albums page failed: $e');
            if (++pageErrors >= 5) break;
            await Future.delayed(const Duration(seconds: 2));
            continue;
          }
          pageErrors = 0;
          if (page.isEmpty) break;
          allAlbums.addAll(page);
          await _db.insertAlbumsBatch(page);
          debugPrint('[LibrarySync] Albums: +${page.length} (total: ${allAlbums.length})');
          _notifySyncProgress();
          if (page.length < albumPageSize) break;
          albumOffset += albumPageSize;
        }

        // Phase 2: Songs via search3
        _syncPhase = 'songs';
        _totalSongsEstimate = albumOffset > 0 ? allAlbums.length * 10 : 50000;
        _notifySyncProgress(force: true);

        const songPageSize = 200;
        int songOffset = 0;
        pageErrors = 0;
        while (true) {
          List<Song> page;
          try {
            page = await _subsonicService.search3SongsPage(
              offset: songOffset, count: songPageSize,
            ).timeout(const Duration(seconds: 25));
          } catch (e) {
            debugPrint('[LibrarySync] Songs page failed: $e');
            if (++pageErrors >= 5) break;
            await Future.delayed(const Duration(seconds: 2));
            continue;
          }
          pageErrors = 0;
          if (page.isEmpty) break;
          final newSongs = page.where((s) => seenSongIds.add(s.id)).toList();
          if (newSongs.isNotEmpty) {
            await _db.insertSongsBatch(newSongs);
          }
          _syncedSongs += newSongs.length;
          debugPrint('[LibrarySync] Songs: +${newSongs.length} (total: $_syncedSongs)');
          _notifySyncProgress();
          if (page.length < songPageSize) break;
          songOffset += songPageSize;
        }

      } else {
        // ── Legacy path: getAlbumList2 + per-album song fetch ─────────────
        debugPrint('[LibrarySync] Using legacy path (getAlbumList2 + per-album)');

        // Phase 1: Albums via getAlbumList2
        _syncPhase = 'albums';
        _notifySyncProgress(force: true);

        const pageSize = 200;
        int offset = 0;
        while (true) {
          List<Album> page;
          try {
            page = await _subsonicService.getAlbumList(
              type: 'alphabeticalByName', size: pageSize, offset: offset,
            ).timeout(const Duration(seconds: 25));
          } catch (e) {
            debugPrint('[LibrarySync] Legacy albums page failed: $e');
            break;
          }
          if (page.isEmpty) break;
          allAlbums.addAll(page);
          await _db.insertAlbumsBatch(page);
          _notifySyncProgress();
          if (page.length < pageSize) break;
          offset += pageSize;
        }

        // Phase 2: Songs per album — батчами по 5 параллельно + пауза 50-100мс,
        // retry с backoff, стоп при серии серверных ошибок (не кладём сервер).
        _syncPhase = 'songs';
        _totalSongsEstimate = allAlbums.length * 10;
        _notifySyncProgress(force: true);

        final albumCount = await _db.getAlbumCount();
        const albumBatchSize = 50;
        var consecutiveErrors = 0;
        for (int aOffset = 0; aOffset < albumCount; aOffset += albumBatchSize) {
          final albums = await _db.getAlbumsPaginated(limit: albumBatchSize, offset: aOffset);
          for (var i = 0; i < albums.length; i += 5) {
            final chunk = albums.skip(i).take(5).toList();
            final results = await Future.wait(chunk.map((album) async {
              var attempt = 0;
              while (true) {
                try {
                  return await _subsonicService.getAlbumSongs(album.id);
                } catch (e) {
                  attempt++;
                  final msg = e.toString();
                  final serverError = msg.contains('500') ||
                      msg.contains('Server error') ||
                      msg.contains('timed out');
                  if (!serverError || attempt >= 3) rethrow;
                  await Future.delayed(Duration(milliseconds: 200 * attempt));
                }
              }
            }).map((f) async {
              try {
                return await f;
              } catch (e) {
                failedAlbumLoads++;
                consecutiveErrors++;
                debugPrint('Error loading album: $e');
                return <Song>[];
              }
            }));
            consecutiveErrors = 0;
            for (final albumSongs in results) {
              final newSongs = albumSongs.where((s) => seenSongIds.add(s.id)).toList();
              if (newSongs.isNotEmpty) {
                await _db.insertSongsBatch(newSongs);
              }
              _syncedSongs += newSongs.length;
            }
            _notifySyncProgress();
            // Не душим сервер и даём стриму воздух, особенно если играет.
            final playing = isPlayingCheck?.call() == true;
            await Future.delayed(Duration(milliseconds: playing ? 100 : 50));
            if (consecutiveErrors >= 10) {
              debugPrint('[LibrarySync] Too many errors — abort legacy loop to protect server');
              break;
            }
          }
          if (consecutiveErrors >= 10) break;
        }
      }

      // Phase 3: Metadata (parallel)
      _syncPhase = 'metadata';
      notifyListeners();

      try {
        final artistsFuture = _subsonicService.getArtists();
        final playlistsFuture = _subsonicService.getPlaylists();
        final genresFuture = _subsonicService.getGenres();
        final starredFuture = _subsonicService.getStarred();
        final results = await Future.wait([artistsFuture, playlistsFuture, genresFuture, starredFuture])
            .timeout(const Duration(seconds: 30), onTimeout: () {
          debugPrint('[LibrarySync] Metadata timed out - skip');
          throw TimeoutException('metadata sync timeout');
        });
        _artists = results[0] as List<Artist>;
        _playlists = results[1] as List<Playlist>;
        _richGenres = results[2] as List<Genre>;
        _starred = results[3] as SearchResult;
        _genres = _richGenres.map((g) => g.value).toList();
        _cachedPlaylists = _playlists;
        _androidAutoService.updateArtists(_artists);
        _androidAutoService.updatePlaylists(_playlists, getCoverArtUrl);
        notifyListeners();
      } catch (e) {
        debugPrint('Metadata fetch failed: $e');
      }

      _cachedAllAlbums = allAlbums;
      // Третий заход: никакой getAllSongs после синка. Рабочий набор 800 +
      // точный счетчик из SQL. Чанки синка уже лежат в БД, прогресс шел по ходу.
      try {
        _syncedSongs = await _db.getSongCount();
      } catch (_) {
        _syncedSongs = seenSongIds.length;
      }
      try {
        _cachedAllSongs = await _db.getRandomSongsSample(limit: 800);
      } catch (_) {}
      _randomSongs = _cachedAllSongs.take(50).toList();
      _lastCacheUpdate = DateTime.now();

      _syncPhase = 'done';
      _isSyncing = false;

      await _saveCachedData();

      // ── ML import: избранное/звёзды/история с сервера → локальный ML (обязательно для миксов) ──
      unawaited(_importServerDataToML());

      // Offline-first vibe cache: precompute + persist audio features for
      // new songs so similarity scoring never recomputes them later.
      // Отложен на 15с после синка: записи в audio_features конкурировали
      // с чтениями UI за замок БД на старте («database has been locked» + ANR).
      final warmedSongs = List<Song>.from(_cachedAllSongs);
      Future.delayed(const Duration(seconds: 15), () {
        unawaited(AudioFeaturesCache().warmCache(warmedSongs));
      });

      notifyListeners();
      debugPrint(
        'Background refresh complete: ${allAlbums.length} albums, '
        '${_cachedAllSongs.length} songs '
        '(${failedAlbumLoads > 0 ? "$failedAlbumLoads album(s) failed, " : ""}kept what succeeded).',
      );
      _triggerYandexEnrichment();
      // Auto-hide banner after 4s
      Future.delayed(const Duration(seconds: 4), () {
        if (_syncPhase == 'done') {
          _syncPhase = '';
          notifyListeners();
        }
      });
    } catch (e) {
      debugPrint('Error refreshing all data: $e');
      _isSyncing = false;
      _syncPhase = 'error';
      notifyListeners();
      Future.delayed(const Duration(seconds: 4), () {
        if (_syncPhase == 'error') {
          _syncPhase = '';
          notifyListeners();
        }
      });
    }
  }

  Future<void> _saveCachedData() async {
    try {
      // Третий заход: песни/альбомы уже лежат в БД чанками по ходу синка —
      // повторная вставка всего (было: getAllSongs + insert) удваивала работу
      // и RAM. Здесь только мелочь: плейлисты/артисты/starred/метка времени.
      final prefs = await SharedPreferences.getInstance();

      // Playlists and artists are small enough to keep in SharedPreferences
      final playlistsJson = json.encode(
        _cachedPlaylists.map((p) => p.toJson()).toList(),
      );
      await prefs.setString(_playlistsCacheKey, playlistsJson);

      if (_artists.isNotEmpty) {
        final artistsJson = json.encode(
          _artists.map((a) => a.toJson()).toList(),
        );
        await prefs.setString(_artistsCacheKey, artistsJson);
      }

      if (_starred != null) {
        try {
          final starredJson = json.encode({
            'artists': _starred!.artists.map((a) => a.toJson()).toList(),
            'albums': _starred!.albums.map((a) => a.toJson()).toList(),
            'songs': _starred!.songs.map((s) => s.toJson()).toList(),
          });
          await prefs.setString(_starredCacheKey, starredJson);
        } catch (_) {}
      }

      await prefs.setInt(
        _lastUpdateKey,
        _lastCacheUpdate?.millisecondsSinceEpoch ??
            DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      debugPrint('Error saving cached data: $e');
    }
  }

  Future<void> _importServerDataToML() async {
    final ml = MLService();
    await ml.initialize();
    final store = ml_store_lib.MLStore();
    await store.init();
    // Bulk-режим обоих сторов: десятки тысяч импортов без тысяч
    // notifyListeners и сейвов (фриз главного потока, факт 15.10.2026).
    ml.beginBulkImport();
    store.beginBulk();
    try {

      int importedLikes = 0;
      int importedRatings = 0;
      int importedPlays = 0;

      // Batch SQL — собираем один транзакционный апдейт вместо 50k отдельных
      final List<Map<String, dynamic>> dbBatch = [];

      // 1) starred songs -> like без накрутки playCount
      if (_starred != null) {
        for (final s in _starred!.songs) {
          try {
            if (ml.ratings[s.id]?.like != true) {
              ml.importLike(s.id, true, song: s, persistDb: false);
              importedLikes++;
            }
            final existing = store.ratings[s.id];
            if (existing == null || existing.like != true) {
              store.importLike(s.id, true, songInfo: {'title': s.title, 'artist': s.artist});
            }
            dbBatch.add({'id': s.id, 'starred': 1, 'disliked': 0});
          } catch (_) {}
        }
        for (final a in _starred!.artists) {
          try { ml.likeArtist(a.id, liked: true, weight: 1.5); } catch (_) {}
        }
        for (final al in _starred!.albums) {
          if (al.artistId != null) {
            try { ml.likeArtist(al.artistId!, liked: true, weight: 0.8); } catch (_) {}
          }
        }
      }

      // 2) Все песни сервера: userRating/playCount/played/starred.
      // Было: цикл по _cachedAllSongs (80к объектов в RAM).
      // Стало: чанковый скан рейтинговых колонок, стаб Song на чанк (GC чистит).
      const ratingChunk = 2000;
      final ratingTotal = await _db.getSongCount();
      for (var ratingOffset = 0; ratingOffset < ratingTotal; ratingOffset += ratingChunk) {
        final rows = await _db.getSongsRatingScan(limit: ratingChunk, offset: ratingOffset);
        if (rows.isEmpty) break;
        final chunkSongs = rows.map((m) {
          final lp = m['lastPlayed'] as int?;
          return Song(
            id: m['id'] as String,
            title: m['title'] as String? ?? 'Unknown',
            artist: m['artist'] as String?,
            userRating: m['userRating'] as int?,
            playCount: m['playCount'] as int?,
            starred: (m['starred'] as int?) == 1,
            played: lp != null ? DateTime.fromMillisecondsSinceEpoch(lp).toIso8601String() : null,
          );
        }).toList();
        for (final song in chunkSongs) {
        bool needsDb = false;
        final dbVals = <String, dynamic>{'id': song.id};
        if (song.userRating != null && song.userRating! >= 1 && song.userRating! <= 5) {
          final r = song.userRating!;
          dbVals['userRating'] = r;
          needsDb = true;
          if (r >= 4 && ml.ratings[song.id]?.like != true) {
            ml.importLike(song.id, true, song: song, persistDb: false);
            store.importLike(song.id, true, songInfo: {'title': song.title, 'artist': song.artist});
            dbVals['disliked'] = 0; dbVals['starred'] = 1;
            importedRatings++;
          } else if (r <= 2 && ml.ratings[song.id]?.like != false) {
            ml.importLike(song.id, false, song: song, persistDb: false);
            store.importLike(song.id, false, songInfo: {'title': song.title, 'artist': song.artist});
            dbVals['disliked'] = 1;
            importedRatings++;
          }
        }
        final pc = song.playCount ?? 0;
        if (pc > 0) {
          final playedDt = song.played != null ? DateTime.tryParse(song.played!) : null;
          final before = ml.ratings[song.id]?.playCount ?? 0;
          ml.importPlayCount(song.id, pc, song: song, played: playedDt, persistDb: false, userRating: song.userRating);
          store.importPlayCount(song.id, pc, playedIso: song.played);
          dbVals['playCount'] = pc;
          if (playedDt != null) dbVals['lastPlayed'] = playedDt.millisecondsSinceEpoch;
          needsDb = true;
          if (pc > before) importedPlays += pc - before;
        }
        if (song.starred == true) {
          dbVals['starred'] = 1;
          needsDb = true;
          if (ml.ratings[song.id]?.like != true) {
            ml.importLike(song.id, true, song: song, persistDb: false);
            store.importLike(song.id, true, songInfo: {'title': song.title, 'artist': song.artist});
            dbVals['disliked'] = 0;
            importedLikes++;
          }
        }
        // также если у песни userRating уже есть — продублируем в db
        if (song.userRating != null) { dbVals['userRating'] = song.userRating; needsDb = true; }
        if (needsDb && dbVals.length > 1) dbBatch.add(dbVals);
        } // for song in chunk
        // Инкрементальный флеш: было — один гигантский батч на всю библиотеку
        // в конце (монолитная транзакция + 15с фриз главного потока, факт
        // 15.10.2026). Стало — сливаем каждые 2000 с уступкой event loop.
        if (dbBatch.length >= 2000) {
          final flush = List<Map<String, dynamic>>.from(dbBatch);
          dbBatch.clear();
          await _db.updateSongPlayStatusBatch(flush);
          await Future.delayed(Duration.zero);
        }
      } // for chunk (чанки по 2000, GC чистит каждый)
      if (dbBatch.isNotEmpty) {
        await _db.updateSongPlayStatusBatch(dbBatch);
        debugPrint('[ML Import] DB batch ${dbBatch.length} rows synced');
      }

      debugPrint('[ML Import] starredLikes=+$importedLikes ratings=+$importedRatings plays=+$importedPlays from server');
    } catch (e) {
      debugPrint('[ML Import] failed: $e');
    } finally {
      ml.endBulkImport();
      await store.endBulk();
    }
  }

  void _pushLibraryToAndroidAuto() {
    if (_artists.isNotEmpty) {
      _androidAutoService.updateArtists(_artists);
    }
    if (_recentAlbums.isNotEmpty) {
      _androidAutoService.updateAlbums(_recentAlbums, getCoverArtUrl);
    }
    if (_playlists.isNotEmpty) {
      _androidAutoService.updatePlaylists(_playlists, getCoverArtUrl);
    }
    if (_randomSongs.isNotEmpty) {
      _androidAutoService.updateRecentSongs(_randomSongs, getCoverArtUrl);
    }
    // Моя волна для Android Auto — ИИ-генерация как на телефоне
    final pool = _cachedAllSongs.isNotEmpty ? _cachedAllSongs : _randomSongs;
    if (pool.isNotEmpty) {
      try {
        final wave = MLService().generateLocalMyWave(songs: pool, count: 30);
        if (wave.isNotEmpty) _androidAutoService.updateMyWave(wave, getCoverArtUrl);
      } catch (_) {}
    }
  }

  Future<void> _pushOfflineLibraryToAndroidAuto() async {
    final offlineService = OfflineService();
    await offlineService.initialize();
    final downloadedIds = offlineService.getDownloadedSongIds().toSet();

    // In offline mode, local files (isLocal) must always be available regardless of download cache
    final localSongs = _localMusicService?.songs ?? <Song>[];
    final localIds = localSongs.map((s) => s.id).toSet();

    if (downloadedIds.isEmpty && localSongs.isEmpty) {
      _pushLibraryToAndroidAuto();
      return;
    }

    // Было: фильтр рабочего набора (800) — терял скачанное. Стало: гидрация по id из БД.
    final List<Song> offlineSongs = [];
    final seenOff = <String>{};
    try {
      if (downloadedIds.isNotEmpty) {
        final resolved = await _db.getSongsByIds(downloadedIds.toList(), light: false);
        for (final s in resolved) {
          if (seenOff.add(s.id)) offlineSongs.add(s);
        }
      }
    } catch (_) {}
    if (offlineSongs.isEmpty) {
      for (final s in _cachedAllSongs) {
        if (downloadedIds.contains(s.id) || localIds.contains(s.id) || s.isLocal) {
          if (seenOff.add(s.id)) offlineSongs.add(s);
        }
      }
    }
    // Also add local songs that might not be in _cachedAllSongs when merge disabled
    for (final ls in localSongs) {
      if (seenOff.add(ls.id)) offlineSongs.add(ls);
    }
    if (offlineSongs.isNotEmpty) {
      _androidAutoService.updateRecentSongs(offlineSongs, getCoverArtUrl);
    } else if (_randomSongs.isNotEmpty) {
      _androidAutoService.updateRecentSongs(_randomSongs, getCoverArtUrl);
    }

    final albumIdsWithDownloads =
        offlineSongs.map((s) => s.albumId).whereType<String>().toSet();
    final offlineAlbums = _cachedAllAlbums
        .where((a) => albumIdsWithDownloads.contains(a.id))
        .toList();
    if (offlineAlbums.isNotEmpty) {
      _androidAutoService.updateAlbums(offlineAlbums, getCoverArtUrl);
    } else if (_recentAlbums.isNotEmpty) {
      _androidAutoService.updateAlbums(_recentAlbums, getCoverArtUrl);
    }

    final artistIdsWithDownloads =
        offlineSongs.map((s) => s.artistId).whereType<String>().toSet();
    final offlineArtists =
        _artists.where((a) => artistIdsWithDownloads.contains(a.id)).toList();
    if (offlineArtists.isNotEmpty) {
      _androidAutoService.updateArtists(offlineArtists);
    } else if (_artists.isNotEmpty) {
      _androidAutoService.updateArtists(_artists);
    }

    if (_playlists.isNotEmpty) {
      _androidAutoService.updatePlaylists(_playlists, getCoverArtUrl);
    }
    if (offlineSongs.isNotEmpty) {
      try {
        final wave = MLService().generateLocalMyWave(songs: offlineSongs, count: 30);
        if (wave.isNotEmpty) _androidAutoService.updateMyWave(wave, getCoverArtUrl);
      } catch (_) {}
    }
  }

  void _preloadCoverArt() {
    Future.microtask(() async {
      final allAlbums = [..._recentAlbums, ..._randomAlbums];
      for (final album in allAlbums.take(20)) {
        if (album.coverArt != null) {
          try {
            final url = _subsonicService.getCoverArtUrl(
              album.coverArt,
              size: 300,
            );
            if (url.isNotEmpty) {
              _subsonicService.getCoverArtUrl(album.coverArt, size: 300);
            }
          } catch (_) {}
        }
      }
    });
  }

  Future<void> refresh({bool forceFullResync = false}) async {
    _isInitialized = false;
    _lastCacheUpdate = null; // force full re-sync
    if (forceFullResync) {
      await _db.clearServerData();
    }
    await initialize();

    // Force immediate full background refresh if server is reachable.
    if (!_serverOfflineMode && !_localOnlyMode) {
      _refreshAllDataInBackground();
    }
  }

  Future<void> forceFullResync() async {
    await _db.clearServerData();
    _lastCacheUpdate = null;
    _isInitialized = false;
    await _refreshAllDataInBackground();
  }

  Future<void> loadArtists() async {
    if (_serverOfflineMode) return;
    try {
      _artists = await _subsonicService.getArtists();
      notifyListeners();
      _androidAutoService.updateArtists(_artists);
      _saveCachedData();
    } catch (e) {
      debugPrint('Error loading artists: $e');

      if (_artists.isNotEmpty) {
        _androidAutoService.updateArtists(_artists);
      }
    }
  }

  Future<void> loadRecentAlbums() async {
    if (_serverOfflineMode) return;
    try {
      final fetched = await _subsonicService.getAlbumList(
        type: 'recent',
        size: 20,
      );
      // Only replace the list when the server actually returned results.
      // On Navidrome, type=recent returns [] if nothing has been played
      // recently, which would wipe the cached albums shown in the UI.
      if (fetched.isNotEmpty) {
        _recentAlbums = fetched;
      }
      notifyListeners();
      _androidAutoService.updateAlbums(_recentAlbums, getCoverArtUrl);
    } catch (e) {
      debugPrint('Error loading recent albums: $e');
    }
  }

  Future<void> loadFrequentAlbums() async {
    if (_serverOfflineMode) return;
    try {
      _frequentAlbums = await _subsonicService.getAlbumList(
        type: 'frequent',
        size: 20,
      );
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading frequent albums: $e');
    }
  }

  Future<void> loadNewestAlbums() async {
    if (_serverOfflineMode) return;
    try {
      _newestAlbums = await _subsonicService.getAlbumList(
        type: 'newest',
        size: 20,
      );
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading newest albums: $e');
    }
  }

  Future<void> loadRandomAlbums() async {
    if (_serverOfflineMode) return;
    try {
      _randomAlbums = await _subsonicService.getAlbumList(
        type: 'random',
        size: 20,
      );
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading random albums: $e');
    }
  }

  Future<void> loadPlaylists() async {
    if (_serverOfflineMode) return;
    try {
      final newPlaylists = await _subsonicService.getPlaylists();

      final List<Playlist> mergedPlaylists = [];

      for (final newPlaylist in newPlaylists) {
        final cachedIndex = _cachedPlaylists.indexWhere(
          (p) => p.id == newPlaylist.id,
        );
        if (cachedIndex != -1) {
          final cachedFn = _cachedPlaylists[cachedIndex];

          if (cachedFn.songs != null && cachedFn.songs!.isNotEmpty) {
            mergedPlaylists.add(newPlaylist.copyWith(songs: cachedFn.songs));
            continue;
          }
        }
        mergedPlaylists.add(newPlaylist);
      }

      _playlists = mergedPlaylists;
      _cachedPlaylists = _playlists;
      _saveCachedData();
      notifyListeners();
      _androidAutoService.updatePlaylists(_playlists, getCoverArtUrl);
    } catch (e) {
      debugPrint('Error loading playlists: $e');
      if (_playlists.isEmpty && _cachedPlaylists.isNotEmpty) {
        _playlists = _cachedPlaylists;
        notifyListeners();
      }

      if (_playlists.isNotEmpty) {
        _androidAutoService.updatePlaylists(_playlists, getCoverArtUrl);
      }
    }
  }

  Future<void> loadRandomSongs() async {
    if (_serverOfflineMode) return;
    try {
      _randomSongs = await _subsonicService.getRandomSongs(size: 50);
      notifyListeners();
      _androidAutoService.updateRecentSongs(_randomSongs, getCoverArtUrl);
    } catch (e) {
      debugPrint('Error loading random songs: $e');

      if (_randomSongs.isNotEmpty) {
        _androidAutoService.updateRecentSongs(_randomSongs, getCoverArtUrl);
      }
    }
  }

  Future<void> loadGenres() async {
    if (_serverOfflineMode) return;
    try {
      _richGenres = await _subsonicService.getGenres();
      _genres = _richGenres.map((g) => g.value).toList();
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading genres: $e');
    }
  }

  Future<void> loadStarred() async {
    if (_serverOfflineMode) return;
    try {
      _starred = await _subsonicService.getStarred();
      // persist for cold start
      try {
        final prefs = await SharedPreferences.getInstance();
        final starredJson = json.encode({
          'artists': _starred!.artists.map((a) => a.toJson()).toList(),
          'albums': _starred!.albums.map((a) => a.toJson()).toList(),
          'songs': _starred!.songs.map((s) => s.toJson()).toList(),
        });
        await prefs.setString(_starredCacheKey, starredJson);
      } catch (_) {}
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading starred: $e');
    }
  }

  Future<List<Album>> getArtistAlbums(String artistId) async {
    if (_localOnlyMode && _localMusicService != null) {
      return _localMusicService!.getAlbumsByArtist(artistId);
    }
    try {
      return await _subsonicService.getArtistAlbums(artistId);
    } catch (e) {
      debugPrint('Error loading artist albums: $e');
      return [];
    }
  }

  Future<List<Song>> getAlbumSongs(String albumId) async {
    if (_localOnlyMode && _localMusicService != null) {
      return _localMusicService!.getSongsByAlbum(albumId);
    }
    try {
      return await _subsonicService.getAlbumSongs(albumId);
    } catch (e) {
      debugPrint('Error loading album songs: $e');
      return [];
    }
  }

  // Дедуп параллельных запросов деталей плейлиста (шторм 13.10.2026:
  // 140 getPlaylist по 66 id за 18с — сложенные экраны артистов каждый
  // тянули детали всех плейлистов; дубли плодили запросы и парсинг).
  final Map<String, Future<Playlist>> _playlistInflight = {};

  // Дебаунс записи кэша на диск: getPlaylist раньше json.encode'ил ВЕСЬ
  // кэш плейлистов с треками (мегабайты) + писал prefs на КАЖДОЕ
  // завершение — при веере это вешало UI-поток (ANR 13.10.2026, 226% CPU,
  // broadcast COMPACT_OPEN_APP не дождался очереди). Память обновляем
  // сразу, на диск — не чаще раза в 2с.
  Timer? _saveDebounce;
  void _scheduleSaveCachedData() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), () {
      try {
        _saveCachedData();
      } catch (_) {}
    });
  }

  Future<Playlist> getPlaylist(String playlistId) async {
    // Виртуальные локальные плейлисты — сразу, без сервера.
    final local = getLocalFolderPlaylist(playlistId);
    if (local != null) return local;
    final isOffline = _serverOfflineMode || OfflineService().isOfflineMode;
    if (isOffline) {
      final cached = _playlists.firstWhere(
        (p) => p.id == playlistId,
        orElse: () => _cachedPlaylists.firstWhere(
          (p) => p.id == playlistId,
          orElse: () => throw Exception('Playlist not available offline'),
        ),
      );
      return cached;
    }

    // Один id — один полёт: повторный вызов делит тот же future.
    final inflight = _playlistInflight[playlistId];
    if (inflight != null) return inflight;

    final fut = _fetchPlaylistDetails(playlistId);
    _playlistInflight[playlistId] = fut;
    try {
      return await fut;
    } finally {
      _playlistInflight.remove(playlistId);
    }
  }

  Future<Playlist> _fetchPlaylistDetails(String playlistId) async {
    try {
      final playlist = await _subsonicService.getPlaylist(playlistId);

      final index = _playlists.indexWhere((p) => p.id == playlistId);
      if (index != -1) {
        _playlists[index] = playlist;
      } else {
        _playlists.add(playlist);
      }

      _cachedPlaylists = List.from(_playlists);
      _scheduleSaveCachedData();
      notifyListeners();

      return playlist;
    } catch (e) {
      debugPrint('Error loading playlist details: $e');

      final cachedPlaylist = _playlists.firstWhere(
        (p) => p.id == playlistId,
        orElse: () => throw e,
      );

      if (cachedPlaylist.songs != null && cachedPlaylist.songs!.isNotEmpty) {
        return cachedPlaylist;
      }

      rethrow;
    }
  }

  Future<void> createPlaylist(String name, {List<String>? songIds, String? comment}) async {
    await _subsonicService.createPlaylist(name: name, comment: comment, songIds: songIds);
    await loadPlaylists();
  }

  Future<void> deletePlaylist(String playlistId) async {
    await _subsonicService.deletePlaylist(playlistId);
    await loadPlaylists();
  }

  Future<void> addSongToPlaylist(String playlistId, String songId) async {
    await _subsonicService.updatePlaylist(
      playlistId: playlistId,
      songIdsToAdd: [songId],
    );
  }

  /// Слияние двух выдач поиска с дедупом по id (для офлайн fast-path).
  SearchResult _mergeSearch(SearchResult a, SearchResult b) {
    final seenSongs = a.songs.map((e) => e.id).toSet();
    final songs = [...a.songs];
    for (final s in b.songs) {
      if (seenSongs.add(s.id)) songs.add(s);
    }
    final seenArtists = a.artists.map((e) => e.id).toSet();
    final artists = [...a.artists];
    for (final ar in b.artists) {
      if (seenArtists.add(ar.id)) artists.add(ar);
    }
    final seenAlbums = a.albums.map((e) => e.id).toSet();
    final albums = [...a.albums];
    for (final al in b.albums) {
      if (seenAlbums.add(al.id)) albums.add(al);
    }
    return SearchResult(songs: songs, artists: artists, albums: albums);
  }

  Future<SearchResult> search(String query) async {
    if (_localOnlyMode) {
      return _searchLocal(query);
    }

    // Офлайн: сервер не дёргаем (вис на таймаутах + пусто) — сразу кэш+локальное.
    // При возврате сети этот же метод снова пойдёт на сервер: залипания нет.
    if (_serverOfflineMode || OfflineService().isOfflineMode) {
      final dbResult = await searchDbAsync(query);
      if (_localMusicService != null && _localMusicService!.songs.isNotEmpty) {
        final localResult = _searchLocal(query);
        return _mergeSearch(dbResult, localResult);
      }
      return dbResult;
    }

    // Search server first
    SearchResult serverResult;
    try {
      serverResult = await _subsonicService.search(query);
    } catch (e) {
      serverResult = SearchResult(songs: [], artists: [], albums: []);
    }

    // Fallback to DB cache if server returned empty (large libraries, search3 may miss)
    SearchResult dbResult = SearchResult(songs: [], artists: [], albums: []);
    if (serverResult.isEmpty || serverResult.songs.length < 3) {
      // Второй заход: песни — SQL (searchDbAsync), а не скан 80к в _searchDb.
      dbResult = await searchDbAsync(query);
      // Merge DB results into serverResult (dedup by id, O(1) через Set)
      final seenSongs = serverResult.songs.map((e) => e.id).toSet();
      final allSongs = [...serverResult.songs];
      for (final s in dbResult.songs) {
        if (seenSongs.add(s.id)) allSongs.add(s);
      }
      final seenArtists = serverResult.artists.map((e) => e.id).toSet();
      final allArtists = [...serverResult.artists];
      for (final a in dbResult.artists) {
        if (seenArtists.add(a.id)) allArtists.add(a);
      }
      final seenAlbums = serverResult.albums.map((e) => e.id).toSet();
      final allAlbums = [...serverResult.albums];
      for (final a in dbResult.albums) {
        if (seenAlbums.add(a.id)) allAlbums.add(a);
      }
      serverResult = SearchResult(songs: allSongs, artists: allArtists, albums: allAlbums);
    }

    // Merge local files results if local music is available (dedup O(1) через Set)
    if (_localMusicService != null && _localMusicService!.songs.isNotEmpty) {
      final localResult = _searchLocal(query);
      final seenSongs = serverResult.songs.map((s) => s.id).toSet();
      final allSongs = [...serverResult.songs];
      for (final localSong in localResult.songs) {
        if (seenSongs.add(localSong.id)) allSongs.add(localSong);
      }
      final seenArtists = serverResult.artists.map((a) => a.id).toSet();
      final allArtists = [...serverResult.artists];
      for (final localArtist in localResult.artists) {
        if (seenArtists.add(localArtist.id)) allArtists.add(localArtist);
      }
      final seenAlbums = serverResult.albums.map((a) => a.id).toSet();
      final allAlbums = [...serverResult.albums];
      for (final localAlbum in localResult.albums) {
        if (seenAlbums.add(localAlbum.id)) allAlbums.add(localAlbum);
      }
      return SearchResult(songs: allSongs, artists: allArtists, albums: allAlbums);
    }

    return serverResult;
  }

  /// Global server-side artist search with pagination (search3 artistOffset).
  /// First page additionally merges DB-cache hits (dedup by id) so
  /// offline-known artists stay visible even when the server misses them.
  Future<List<Artist>> searchArtistsGlobal(
    String query, {
    int offset = 0,
    int count = 50,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    if (_localOnlyMode) {
      final lower = q.toLowerCase();
      return _artists
          .where((a) => a.name.toLowerCase().contains(lower))
          .skip(offset)
          .take(count)
          .toList();
    }
    // Офлайн: сервер не дёргаем — только кэш имён (мгновенно, без таймаутов).
    if (_serverOfflineMode || OfflineService().isOfflineMode) {
      final lower = q.toLowerCase();
      return _artists
          .where((a) => a.name.toLowerCase().contains(lower))
          .skip(offset)
          .take(count)
          .toList();
    }
    var serverArtists = <Artist>[];
    try {
      final res = await _subsonicService.search(
        q,
        artistCount: count,
        artistOffset: offset,
        albumCount: 0,
        songCount: 0,
      );
      serverArtists = res.artists;
    } catch (_) {}
    if (offset == 0) {
      final lower = q.toLowerCase();
      final seen = serverArtists.map((a) => a.id).toSet();
      for (final a in _artists) {
        if (serverArtists.length >= count) break;
        if (a.name.toLowerCase().contains(lower) && seen.add(a.id)) {
          serverArtists.add(a);
        }
      }
    }
    return serverArtists;
  }

  // П1+П2+П3: SQL-путь без 80к в RAM. Оставлен sync _searchDb для
  // совместимости, новый код использует searchDbAsync + getSongsPage.
  Future<SearchResult> searchDbAsync(String query, {int limit = 50}) async {
    try {
      final songs = await _db.searchSongs(query, limit: limit);
      final artists = _artists.where((a) => a.name.toLowerCase().contains(query.toLowerCase().trim())).take(20).toList();
      final albums = _cachedAllAlbums.where((a) => a.name.toLowerCase().contains(query.toLowerCase().trim())).take(20).toList();
      return SearchResult(songs: songs, artists: artists, albums: albums);
    } catch (_) {
      return _searchDb(query);
    }
  }

  Future<List<Song>> getSongsPage({int limit = 200, int offset = 0, String sort = 'titleAsc'}) {
    return _db.getSongsLightPaginated(limit: limit, offset: offset, sort: sort);
  }

  // Второй заход: точечные SQL без cachedAllSongs.
  Future<List<Song>> getSongsByArtistId(String artistId, {int limit = 500}) =>
      _db.getSongsByArtistId(artistId, limit: limit);
  Future<List<Song>> getSongsByAlbumId(String albumId, {int limit = 500}) =>
      _db.getSongsByAlbumId(albumId, limit: limit);
  Future<List<Map<String, dynamic>>> getGenreStats() => _db.getGenreStats();
  Future<List<Song>> getGenreSample(String genre, {String? excludeArtistId, int limit = 60}) =>
      _db.getSongsByGenreSample(genre, excludeArtistId: excludeArtistId, limit: limit);

  Future<int> getSongsTotal() => _db.getSongCount();

  // Третий заход: свежий RANDOM-пул для волн/миксов вместо среза кэша.
  Future<List<Song>> getPoolForMix({int limit = 700, List<String> excludeIds = const []}) async {
    try {
      final pool = await _db.getSongsForMixStratified(limit: limit, excludeIds: excludeIds);
      if (pool.isNotEmpty) return pool;
    } catch (_) {}
    if (_cachedAllSongs.isNotEmpty) return List<Song>.from(_cachedAllSongs);
    return List<Song>.from(_randomSongs);
  }

  Future<Map<String, int>> getLibraryStats() => _db.getLibraryStats();
  Future<Map<String, int>> getStorageStats() => _db.getStorageStats();
  Future<List<Song>> getPlayedSongs({int limit = 500}) => _db.getPlayedSongs(limit: limit);
  Future<Map<String, int>> getAlbumPlayCounts() => _db.getAlbumPlayCounts();

  /// Точный офлайн-список из БД (скачанные id → гидрация), без 80к в RAM.
  Future<List<Song>> getOfflineSongs() async {
    try {
      final off = OfflineService();
      await off.initialize();
      final ids = off.getDownloadedSongIds().toList();
      final localSongs = _localMusicService?.songs ?? const <Song>[];
      final seen = <String>{};
      final out = <Song>[];
      if (ids.isNotEmpty) {
        final resolved = await _db.getSongsByIds(ids, light: false);
        for (final s in resolved) {
          if (seen.add(s.id)) out.add(s);
        }
      }
      for (final ls in localSongs) {
        if (seen.add(ls.id)) out.add(ls);
      }
      if (out.isNotEmpty) return out;
    } catch (_) {}
    return offlineSongs;
  }

  Future<Song?> getSongById(String id) => _db.getSongById(id);
  Future<List<Song>> getSongsByIds(List<String> ids) => _db.getSongsByIds(ids);

  SearchResult _searchDb(String query) {

    final q = query.toLowerCase().trim();
    if (q.isEmpty) return SearchResult(songs: [], artists: [], albums: []);
    final songs = _cachedAllSongs.where((s) => s.title.toLowerCase().contains(q) || (s.artist?.toLowerCase().contains(q) ?? false) || (s.album?.toLowerCase().contains(q) ?? false)).take(50).toList();
    final artists = _artists.where((a) => a.name.toLowerCase().contains(q)).take(20).toList();
    final albums = _cachedAllAlbums.where((a) => a.name.toLowerCase().contains(q) || (a.artist?.toLowerCase().contains(q) ?? false)).take(20).toList();
    // Also add genre hits: if query matches genre, include songs of that genre
    if (songs.length < 10) {
      final genreSongs = _cachedAllSongs.where((s) => s.genre != null && s.genre!.toLowerCase().contains(q)).take(20).toList();
      for (final gs in genreSongs) {
        if (!songs.any((e) => e.id == gs.id)) songs.add(gs);
        if (songs.length >= 50) break;
      }
    }
    return SearchResult(songs: songs, artists: artists, albums: albums);
  }

  SearchResult _searchLocal(String query) {
    final q = query.toLowerCase();

    // Use localMusicService directly for local songs if available
    final localSongs = _localMusicService?.songs ?? [];
    final localAlbums = _localMusicService?.albums ?? [];
    final localArtists = _localMusicService?.artists ?? [];

    final songs = localSongs
        .where(
          (s) =>
              s.title.toLowerCase().contains(q) ||
              (s.artist?.toLowerCase().contains(q) ?? false) ||
              (s.album?.toLowerCase().contains(q) ?? false),
        )
        .take(50)
        .toList();
    final artists = localArtists
        .where((a) => a.name.toLowerCase().contains(q))
        .take(20)
        .toList();
    final albums = localAlbums
        .where(
          (a) =>
              a.name.toLowerCase().contains(q) ||
              (a.artist?.toLowerCase().contains(q) ?? false),
        )
        .take(20)
        .toList();
    return SearchResult(songs: songs, artists: artists, albums: albums);
  }

  Future<void> star({String? songId, String? albumId, String? artistId}) async {
    await _subsonicService.star(
      id: songId,
      albumId: albumId,
      artistId: artistId,
    );
    await loadStarred();
  }

  Future<void> unstar({
    String? songId,
    String? albumId,
    String? artistId,
  }) async {
    await _subsonicService.unstar(
      id: songId,
      albumId: albumId,
      artistId: artistId,
    );
    await loadStarred();
  }

  Future<List<Song>> getSongsByGenre(String genre) async {
    try {
      return await _subsonicService.getSongsByGenre(genre);
    } catch (e) {
      debugPrint('Error loading songs by genre: $e');
      return [];
    }
  }

  Future<List<Album>> getAlbumsByGenre(String genre) async {
    try {
      return await _subsonicService.getAlbumsByGenre(genre);
    } catch (e) {
      debugPrint('Error loading albums by genre: $e');
      return [];
    }
  }

  Future<List<Song>> getAllSongs() async {
    try {
      final allArtists = await _subsonicService.getArtists();

      final List<Song> allSongs = [];

      for (final artist in allArtists) {
        try {
          final artistAlbums = await _subsonicService.getArtistAlbums(
            artist.id,
          );
          for (final album in artistAlbums) {
            try {
              final songs = await _subsonicService.getAlbumSongs(album.id);
              allSongs.addAll(songs);
            } catch (e) {
              debugPrint('Error loading album ${album.id}: $e');
            }
          }
        } catch (e) {
          debugPrint('Error loading albums for artist ${artist.name}: $e');
        }
      }

      return allSongs;
    } catch (e) {
      debugPrint('Error loading all songs: $e');
      return [];
    }
  }

  Future<List<Album>> getAllAlbums() async {
    try {
      final allArtists = await _subsonicService.getArtists();

      final List<Album> allAlbums = [];

      for (final artist in allArtists) {
        try {
          final artistAlbums = await _subsonicService.getArtistAlbums(
            artist.id,
          );
          allAlbums.addAll(artistAlbums);
        } catch (e) {
          debugPrint('Error loading albums for artist ${artist.name}: $e');
        }
      }

      return allAlbums;
    } catch (e) {
      debugPrint('Error loading all albums: $e');
      return [];
    }
  }

  @override
  void dispose() {
    _localMusicService?.removeListener(_onLocalMusicServiceChanged);
    try {
      OfflineService().removeOnlineListener(_onNetworkRestored);
      OfflineService().removeListener(_onOfflineServiceChanged);
    } catch (_) {}
    super.dispose();
  }
}






