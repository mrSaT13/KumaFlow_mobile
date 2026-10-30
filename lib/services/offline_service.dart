import 'dart:async';
import 'dart:io';

import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:media_store_plus/media_store_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cache_settings_service.dart';
import '../models/song.dart';


/// Модель для отслеживания прогресса загрузки
class DownloadProgress {
  final String trackId;
  final String albumId;
  final double progress;
  final bool isComplete;
  final bool isError;

  const DownloadProgress({
    required this.trackId,
    this.albumId = '',
    this.progress = 0.0,
    this.isComplete = false,
    this.isError = false,
  });

  DownloadProgress copyWith({
    String? trackId,
    String? albumId,
    double? progress,
    bool? isComplete,
    bool? isError,
  }) {
    return DownloadProgress(
      trackId: trackId ?? this.trackId,
      albumId: albumId ?? this.albumId,
      progress: progress ?? this.progress,
      isComplete: isComplete ?? this.isComplete,
      isError: isError ?? this.isError,
    );
  }
}

/// Состояние фоновой загрузки библиотеки
class DownloadState {
  final bool isDownloading;
  final int currentProgress;
  final int totalCount;
  final int downloadedCount;

  const DownloadState({
    this.isDownloading = false,
    this.currentProgress = 0,
    this.totalCount = 0,
    this.downloadedCount = 0,
  });
}

/// Сервис офлайн прослушивания
/// Управляет скачиванием, кэшированием и воспроизведением альбомов/треков без сети
class OfflineService extends ChangeNotifier {
  // ── Singleton: all call sites share one instance so baseUrl/user stay synced
  static final OfflineService _instance = OfflineService._internal();
  factory OfflineService({
    String baseUrl = '',
    String subsonicUser = '',
    int maxCacheSizeMB = 500,
    bool autoSwitchOffline = true,
    VoidCallback? onOnlineRestored,
  }) {
    // Sync credentials if provided (e.g. from AuthProvider)
    if (baseUrl.isNotEmpty) _instance.baseUrl = baseUrl;
    if (subsonicUser.isNotEmpty) _instance.subsonicUser = subsonicUser;
    if (onOnlineRestored != null) _instance.onOnlineRestored = onOnlineRestored;
    return _instance;
  }
  OfflineService._internal({
    this.baseUrl = '',
    this.subsonicUser = '',
    this.maxCacheSizeMB = 500,
    this.autoSwitchOffline = true,
    this.onOnlineRestored,
  });

  /// Базовый URL Subsonic сервера
  String baseUrl;

  /// Имя пользователя Subsonic
  String subsonicUser;

  /// Максимальный размер кэша в МБ
  final int maxCacheSizeMB;

  /// Авто-переключение в офлайн при потере сети
  final bool autoSwitchOffline;

  /// Callback вызывается при успешном возвращении в онлайн режим
  /// (после проверки доступности сервера)
  VoidCallback? onOnlineRestored;

  /// Широковещательные слушатели возврата сети (экраны/провайдеры).
  /// Одиночный onOnlineRestored оставлен для совместимости (auth retry),
  /// но перезаписывается последним configure — сюда подписываются все.
  final Set<VoidCallback> _onlineListeners = {};

  void addOnlineListener(VoidCallback cb) => _onlineListeners.add(cb);
  void removeOnlineListener(VoidCallback cb) => _onlineListeners.remove(cb);

  void configure({String? baseUrl, String? subsonicUser, VoidCallback? onOnlineRestored}) {
    if (baseUrl != null && baseUrl.isNotEmpty) this.baseUrl = baseUrl;
    if (subsonicUser != null && subsonicUser.isNotEmpty) this.subsonicUser = subsonicUser;
    if (onOnlineRestored != null) this.onOnlineRestored = onOnlineRestored;
  }

  void syncFromSubsonic(dynamic subsonicService) {
    try {
      final cfg = subsonicService.config;
      if (cfg != null) {
        if (cfg.serverUrl != null && (cfg.serverUrl as String).isNotEmpty) baseUrl = cfg.normalizedUrl ?? cfg.serverUrl;
        if (cfg.username != null && (cfg.username as String).isNotEmpty) subsonicUser = cfg.username;
      }
    } catch (_) {}
    // fallback via getters
    try {
      final b = (subsonicService as dynamic).baseUrl ?? (subsonicService as dynamic).serverUrl;
      if (b is String && b.isNotEmpty && baseUrl.isEmpty) baseUrl = b;
    } catch (_) {}
  }

  // Состояние
  bool _isOfflineMode = false;
  bool get isOfflineMode => _isOfflineMode;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _error;
  String? get error => _error;

  final Map<String, DownloadProgress> _downloadProgress = {};
  Map<String, DownloadProgress> get downloadProgress =>
      Map.unmodifiable(_downloadProgress);

  final List<String> _downloadedTrackIds = [];
  List<String> get downloadedTrackIds => List.unmodifiable(_downloadedTrackIds);

  File? _currentPlayingFile;
  File? get currentPlayingFile => _currentPlayingFile;

  StreamSubscription? _connectivitySubscription;
  Directory? _cacheDirectory;
  final MediaStore _mediaStore = MediaStore();

  // Circuit breaker «сервер лёг»: пачка 5xx подряд (502/503/504 от упавшего
  // бэкенда за Keenetic-прокси) — не транзиент потрека, а простой сервера.
  // Без брейкера предзагрузка и очередь долбят мёртвый сервер: N треков ×
  // 3 попытки × таймауты 15с/20с = шторм, жор батареи и лаги UI (факт
  // 15.10.2026: 502 на всё, Skipped 57 frames). После 3 подряд 5xx —
  // пауза 60с для ВСЕХ качалок, один лог вместо сотен.
  int _serverErrorStreak = 0;
  DateTime? _serverDownUntil;

  /// true — сервер в дауне, качалки пропускаем молча до конца паузы.
  bool get _serverDown {
    final until = _serverDownUntil;
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _serverDownUntil = null;
      _serverErrorStreak = 0;
      return false;
    }
    return true;
  }

  /// Учёт результата запроса к серверу. 5xx растят стрик, любой успех
  /// (2xx) или клиентская 4xx — сбрасывают (сервер жив).
  void _noteServerResult({int? statusCode, bool ok = false}) {
    if (ok || (statusCode != null && statusCode < 500)) {
      if (_serverErrorStreak > 0) _serverErrorStreak = 0;
      return;
    }
    if (statusCode != null && statusCode >= 500) {
      _serverErrorStreak++;
      if (_serverErrorStreak == 3) {
        _serverDownUntil =
            DateTime.now().add(const Duration(seconds: 60));
        debugPrint('[OfflineService] circuit breaker OPEN: сервер отдаёт '
            '5xx (${_serverErrorStreak} подряд) — пауза качалок 60с');
      }
    }
  }

  static int? _statusFromError(Object e) {
    final m = RegExp(r'(\d{3})').firstMatch('$e');
    if (m == null) return null;
    return int.tryParse(m.group(1) ?? '');
  }

  /// Состояние фоновой загрузки
  final ValueNotifier<DownloadState> downloadState =
      ValueNotifier(const DownloadState());

  /// Инициализация сервиса (идемпотентно: повторные вызовы дешёвые).
  /// init дёргают отовсюду (auth/player/login) — без гарда каждый вызов
  /// заново сканировал весь music_cache и вешал старт.
  bool _initDone = false;
  bool _initInFlight = false;
  Future<void> init() async {
    if (_initDone) return;
    if (_initInFlight) {
      // Дождаться текущего init, а не запускать второй скан параллельно.
      for (var i = 0; i < 100 && !_initDone; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      return;
    }
    _initInFlight = true;
    try {
      await _setupCacheDirectory();
      await _loadDownloadedTracks();
      await _checkAvailableSpace();
      await _loadScrobbleQueue();
      _listenConnectivityChanges();
      // MediaStore для экспорта в общую Музыку (Android). Один раз.
      try {
        MediaStore.appFolder = 'KumaFlow';
        await MediaStore.ensureInitialized();
      } catch (_) {}
      _initDone = true;
    } finally {
      _initInFlight = false;
    }
  }

  /// Настройка директории кэша
  Future<void> _setupCacheDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    _cacheDirectory = Directory('${appDir.path}/music_cache');
    if (!await _cacheDirectory!.exists()) {
      await _cacheDirectory!.create(recursive: true);
    }
    for (final sub in ['abs_cache', 'podcast_cache']) {
      final dir = Directory('${_cacheDirectory!.path}/$sub');
      if (!await dir.exists()) await dir.create(recursive: true);
    }
    // .nomedia: кеш не светится в галерее/чужих плеерах (играем по прямому пути).
    try {
      final nomedia = File('${_cacheDirectory!.path}/.nomedia');
      if (!await nomedia.exists()) await nomedia.create();
    } catch (_) {}
  }

  /// Путь кеша для экрана «Загрузки» (приватный, файловый менеджер его не видит).
  Future<String> getCachePath() async {
    if (_cacheDirectory == null) await _setupCacheDirectory();
    return _cacheDirectory?.path ?? '';
  }

  /// Разбивка загрузок: треки / книги / подкасты (+байты). Для экрана «Загрузки».
  Future<Map<String, int>> getDownloadBreakdown() async {
    final out = {'tracks': 0, 'books': 0, 'podcasts': 0, 'bytes': 0, 'files': 0};
    if (_cacheDirectory == null) await _setupCacheDirectory();
    if (_cacheDirectory == null) return out;
    const exts = ['.mp3', '.ogg', '.flac', '.m4a', '.mp4', '.opus', '.wav', '.aac', '.wma'];
    bool audio(String p) {
      final l = p.toLowerCase();
      for (final e in exts) {
        if (l.endsWith(e)) return true;
      }
      return false;
    }

    Future<void> scan(Directory dir, String kind) async {
      try {
        if (!await dir.exists()) return;
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          if (!audio(entity.path)) continue;
          out[kind] = (out[kind] ?? 0) + 1;
          out['files'] = (out['files'] ?? 0) + 1;
          try {
            out['bytes'] = (out['bytes'] ?? 0) + await entity.length();
          } catch (_) {}
        }
      } catch (_) {}
    }

    await scan(_cacheDirectory!, 'tracks');
    await scan(Directory('${_cacheDirectory!.path}/abs_cache'), 'books');
    await scan(Directory('${_cacheDirectory!.path}/podcast_cache'), 'podcasts');
    return out;
  }

  /// Очистка одного типа: 'books' -> abs_cache, 'podcasts' -> podcast_cache.
  Future<int> clearDownloadKind(String kind) async {
    if (_cacheDirectory == null) await _setupCacheDirectory();
    final sub = kind == 'books'
        ? 'abs_cache'
        : kind == 'podcasts'
            ? 'podcast_cache'
            : null;
    if (sub == null || _cacheDirectory == null) return 0;
    var removed = 0;
    try {
      final dir = Directory('${_cacheDirectory!.path}/$sub');
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is File) {
            try {
              await entity.delete();
              removed++;
            } catch (_) {}
          }
        }
      }
      await _loadDownloadedTracks();
    } catch (_) {}
    return removed;
  }

  /// Человеческое имя файла для экспорта: «Артист — Название.mp3».
  static String exportFileName(String artist, String title, String ext) {
    var base = '${artist.trim()} — ${title.trim()}'.trim();
    if (base.isEmpty || base == '—') base = 'KumaFlow-track';
    base = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (base.length > 120) base = base.substring(0, 120).trim();
    var e = ext.trim().toLowerCase().replaceAll('.', '');
    if (e.isEmpty) e = 'mp3';
    return '$base.$e';
  }

  /// Экспорт скачанного трека в общую Музыку (Android MediaStore, виден везде).
  /// Возвращает путь/uri результата. На iOS/десктопе — копия в Documents/KumaFlow.
  Future<String?> exportTrackFile({
    required String trackId,
    required String artist,
    required String title,
  }) async {
    final src = await getTrackFile(trackId);
    if (src == null) return null;
    final name = exportFileName(artist, title,
        src.path.split('.').lastOrNull ?? 'mp3');
    if (Platform.isAndroid) {
      try {
        final ms = await _mediaStoreSave(
          srcPath: src.path,
          fileName: name,
        );
        if (ms != null) return ms;
      } catch (e) {
        debugPrint('[Offline] MediaStore export failed: $e');
      }
    }
    // Fallback (iOS/десктоп/Android-ошибка): Documents/KumaFlow.
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/KumaFlow');
      if (!await dir.exists()) await dir.create(recursive: true);
      final dst = File('${dir.path}/$name');
      if (!await dst.exists()) await src.copy(dst.path);
      return dst.path;
    } catch (e) {
      debugPrint('[Offline] fallback export failed: $e');
      return null;
    }
  }

  /// Тонкая обёртка над media_store_plus: Music/KumaFlow с человеческим именем.
  /// Файл надо сначала скопировать во временное с нужным именем (имя берётся
  /// из последнего сегмента temp-пути), saveFile сам удалит временный.
  Future<String?> _mediaStoreSave({
    required String srcPath,
    required String fileName,
  }) async {
    try {
      final tmpDir = Directory.systemTemp;
      final tmp = File('${tmpDir.path}/kf-export-$fileName');
      await File(srcPath).copy(tmp.path);
      final info = await _mediaStore
          .saveFile(
        tempFilePath: tmp.path,
        dirType: DirType.audio,
        dirName: DirName.music,
        relativePath: 'KumaFlow',
      );
      return info?.uri?.toString() ?? info?.name;
    } catch (e) {
      debugPrint('[Offline] MediaStore export failed: $e');
      return null;
    }
  }

  /// Загрузка списка скачанных треков из кэша
  Future<void> _loadDownloadedTracks() async {
    _downloadedTrackIds.clear();
    if (_cacheDirectory == null) return;

    const supportedExts = ['.mp3', '.ogg', '.flac', '.m4a', '.mp4', '.opus', '.wav', '.aac', '.wma'];
    await for (final entity in _cacheDirectory!.list()) {
      if (entity is File) {
        final lower = entity.path.toLowerCase();
        for (final ext in supportedExts) {
          if (lower.endsWith(ext)) {
            final fileName = entity.uri.pathSegments.last;
            final trackId = fileName.substring(0, fileName.length - ext.length);
            if (trackId.isNotEmpty) _downloadedTrackIds.add(trackId);
            break;
          }
        }
      }
    }
    // also scan abs_cache subdir
    final absDir = Directory('${_cacheDirectory!.path}/abs_cache');
    if (await absDir.exists()) {
      await for (final entity in absDir.list()) {
        if (entity is File) {
          final lower = entity.path.toLowerCase();
          for (final ext in supportedExts) {
            if (lower.endsWith(ext)) {
              final fileName = entity.uri.pathSegments.last;
              final trackId = fileName.substring(0, fileName.length - ext.length);
              if (trackId.isNotEmpty) _downloadedTrackIds.add(trackId);
              break;
            }
          }
        }
      }
    }
    notifyListeners();
  }

  /// Проверка доступного места на диске
  Future<int> _checkAvailableSpace() async {
    try {
      if (_cacheDirectory == null) return 0;
      final stat = await _cacheDirectory!.stat();
      return stat.size;
    } catch (e) {
      return 0;
    }
  }

  /// Получение текущего размера кэша в байтах
  Future<int> getCacheSize() async {
    if (_cacheDirectory == null || !await _cacheDirectory!.exists()) return 0;

    int totalSize = 0;
    await for (final entity in _cacheDirectory!.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try { totalSize += await entity.length(); } catch (_) {}
      }
    }
    return totalSize;
  }

  /// Проверка, скачан ли трек
  bool isTrackDownloaded(String trackId) {
    return _downloadedTrackIds.contains(trackId);
  }

  /// Получение локального файла трека
  Future<File?> getTrackFile(String trackId) async {
    if (_cacheDirectory == null) return null;

    // Пробуем разные расширения
    for (final ext in ['mp3', 'ogg', 'flac', 'm4a']) {
      final file = File('${_cacheDirectory!.path}/$trackId.$ext');
      if (await file.exists()) return file;
    }
    return null;
  }

  /// Скачивание одного трека — гейтится тумблером cache_music_enabled
  /// Если передан [subsonicService] используется его getStreamUrl (c корректной аутентификацией token/salt), иначе fallback на legacy URL.
  Future<bool> downloadTrack({
    required String trackId,
    required String title,
    required String artist,
    String? albumId,
    dynamic subsonicService,
  }) async {
    if (!CacheSettingsService().getMusicCacheEnabled()) {
      debugPrint('[OfflineService] skip downloadTrack (music cache disabled) $trackId');
      return false;
    }
    if (_cacheDirectory == null) await _setupCacheDirectory();
    if (_cacheDirectory == null) return false;
    // Каталог могли снести уже после init (чистильщик/вручную) — тогда
    // каждая качалка падала с PathNotFoundException (факт 15.10.2026).
    try {
      if (!await _cacheDirectory!.exists()) {
        await _cacheDirectory!.create(recursive: true);
        debugPrint('[OfflineService] music_cache пересоздан');
      }
    } catch (_) {
      return false;
    }
    // Сервер в дауне (5xx-шторм) — не долбим, выходим сразу.
    if (_serverDown) return false;
    if (subsonicService != null) syncFromSubsonic(subsonicService);

    _downloadProgress[trackId] = DownloadProgress(
      trackId: trackId,
      albumId: albumId ?? '',
      progress: 0.0,
    );
    notifyListeners();

    String url;
    if (subsonicService != null) {
      try {
        url = (subsonicService as dynamic).getStreamUrl(trackId) as String;
      } catch (_) {
        url = subsonicService.getDownloadUrl != null ? (subsonicService as dynamic).getDownloadUrl(trackId) as String : '';
        if (url.isEmpty) url = '$baseUrl/rest/stream?id=$trackId&u=$subsonicUser&v=1.16.1&c=KumaFlow';
      }
    } else {
      // попытаться достать из последнего сконфигурированного сервиса через SharedPreferences fallback
      url = '$baseUrl/rest/stream?id=$trackId&u=$subsonicUser&v=1.16.1&c=KumaFlow';
    }

    if (url.isEmpty || baseUrl.isEmpty) {
      debugPrint('[OfflineService] downloadTrack no url/baseUrl for $trackId baseUrl=$baseUrl');
      _downloadProgress[trackId] = _downloadProgress[trackId]!.copyWith(isError: true);
      _error = 'Нет подключения к серверу';
      notifyListeners();
      return false;
    }

    // Ретраи транзиентных сетевых ошибок: один таймаут больше не роняет трек.
    // Качаем во временный .part и переименовываем только целый файл —
    // оборванный хвост никогда не отдаётся плееру как «скачанный».
    // connectionTimeout покрывает только установку соединения, поэтому
    // дополнительно ограничиваем общее время тела ответа.
    const maxAttempts = 3;
    const backoff = [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4)];
    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        await Future.delayed(backoff[attempt - 1]);
        debugPrint('[OfflineService] downloadTrack retry $attempt/$maxAttempts $trackId');
      }
      HttpClient? client;
      IOSink? sink;
      File? partFile;
      try {
        client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 15);
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close().timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException('stream headers timeout'),
        );

        if (response.statusCode != 200) {
          // Учёт 5xx — в catch (один провал = +1 к стрику, без дублей).
          // 4xx (кроме 429/408) — постоянная ошибка, ретраить бессмысленно.
          if (response.statusCode >= 400 &&
              response.statusCode < 500 &&
              response.statusCode != 408 &&
              response.statusCode != 429) {
            throw StateError('Ошибка загрузки: ${response.statusCode}');
          }
          // 5xx при открытом брейкере дальше не крутим — сервер лёг,
          // следующий трек тоже упрётся в паузу.
          if (response.statusCode >= 500 && _serverDown) {
            throw HttpException('Ошибка загрузки: ${response.statusCode}');
          }
          throw HttpException('Ошибка загрузки: ${response.statusCode}');
        }
        _noteServerResult(ok: true);

        final mimeType = response.headers.contentType?.mimeType ?? 'audio/mpeg';
        final ext = mimeType.contains('ogg')
            ? 'ogg'
            : mimeType.contains('flac')
                ? 'flac'
                : mimeType.contains('m4a') || mimeType.contains('mp4')
                    ? 'm4a'
                    : 'mp3';
        final filePath = '${_cacheDirectory!.path}/$trackId.$ext';
        partFile = File('$filePath.part');
        if (await partFile.exists()) {
          try { await partFile.delete(); } catch (_) {}
        }
        sink = partFile.openWrite();
        int bytesReceived = 0;
        final contentLength = response.contentLength ?? 0;

        // Общий лимит на тело: зависший посередине стрим не висит вечно.
        // Через listen с явной отменой подписки: при таймауте в sink больше
        // ничего не прилетает (await-for так отменить нельзя — писал бы
        // в уже закрытый sink).
        StreamSubscription<List<int>>? sub;
        try {
          final done = Completer<void>();
          final activeSink = sink;
          sub = response.listen(
            (chunk) {
              activeSink.add(chunk);
              bytesReceived += chunk.length;

              if (contentLength > 0) {
                final progress = bytesReceived / contentLength;
                _downloadProgress[trackId] =
                    _downloadProgress[trackId]!.copyWith(
                  progress: progress,
                );
                notifyListeners();
              }
            },
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
            onError: (Object e) {
              if (!done.isCompleted) done.completeError(e);
            },
            cancelOnError: true,
          );
          await done.future.timeout(
            const Duration(minutes: 5),
            onTimeout: () => throw TimeoutException('stream body stalled'),
          );
        } finally {
          try { await sub?.cancel(); } catch (_) {}
          sub = null;
        }

        await sink.flush();
        await sink.close();
        sink = null;

        // Целостность: сервер заявил длину — сверяем, огрызок удаляем.
        if (contentLength > 0 && bytesReceived != contentLength) {
          throw HttpException(
              'Неполный файл: $bytesReceived из $contentLength байт');
        }
        if (bytesReceived == 0) {
          throw HttpException('Пустой ответ сервера');
        }
        try {
          final target = File(filePath);
          if (await target.exists()) {
            try { await target.delete(); } catch (_) {}
          }
          await partFile.rename(filePath);
        } catch (_) {
          // rename через границы томов может не сработать — копируем.
          await partFile.copy(filePath);
          try { await partFile.delete(); } catch (_) {}
        }

        _downloadProgress[trackId] = _downloadProgress[trackId]!.copyWith(
          progress: 1.0,
          isComplete: true,
        );
        if (!_downloadedTrackIds.contains(trackId)) {
          _downloadedTrackIds.add(trackId);
        }
        notifyListeners();
        await _cleanCacheIfNeeded();
        debugPrint('[OfflineService] downloadTrack OK $trackId -> $filePath '
            '(attempt ${attempt + 1})');
        return true;
      } catch (e) {
        lastError = e;
        debugPrint('[OfflineService] downloadTrack attempt ${attempt + 1} '
            'FAIL $trackId: $e');
        // Закрываем sink и удаляем частичный файл, чтобы плеер не получил огрызок.
        try { await sink?.close(); } catch (_) {}
        sink = null;
        if (partFile != null) {
          try { if (await partFile.exists()) await partFile.delete(); } catch (_) {}
        }
        // Постоянные ошибки (4xx) — выходим сразу без ретраев.
        if (e is StateError) break;
        // Брейкер только что открылся (сервер лёг) — остаток попыток
        // этого трека тоже пропускаем, не ждём таймауты зря.
        final code = _statusFromError(e);
        if (code != null && code >= 500) {
          _noteServerResult(statusCode: code);
          if (_serverDown) break;
        }
      } finally {
        try { client?.close(force: true); } catch (_) {}
      }
    }
    _downloadProgress[trackId] = _downloadProgress[trackId]!.copyWith(
      isError: true,
    );
    _error = 'Ошибка скачивания: $lastError';
    notifyListeners();
    debugPrint('[OfflineService] downloadTrack FAIL $trackId: $lastError url=$url');
    return false;
  }

  /// Скачивание всего альбома — гейтится тумблером
  Future<int> downloadAlbum({
    required String albumId,
    required List<Map<String, dynamic>> tracks,
  }) async {
    if (!CacheSettingsService().getMusicCacheEnabled()) {
      debugPrint('[OfflineService] skip downloadAlbum (disabled) $albumId');
      return 0;
    }
    _isLoading = true;
    notifyListeners();

    int downloadedCount = 0;

    final parallelism = _parallelDownloads.clamp(1, 5);
    for (int i = 0; i < tracks.length; i += parallelism) {
      final chunk = tracks.skip(i).take(parallelism).toList();
      final results = await Future.wait(chunk.map((track) => downloadTrack(
            trackId: track['id'].toString(),
            title: track['title'] ?? 'Без названия',
            artist: track['artist'] ?? 'Неизвестный',
            albumId: albumId,
          )));
      for (final success in results) {
        if (success) downloadedCount++;
      }
    }

    _isLoading = false;
    notifyListeners();

    return downloadedCount;
  }

  /// Очистка кэша при превышении лимита
  Future<void> _cleanCacheIfNeeded() async {
    final cacheSize = await getCacheSize();
    final maxSizeBytes = maxCacheSizeMB * 1024 * 1024;

    if (cacheSize <= maxSizeBytes) return;

    // Сортируем файлы по дате изменения (старые первые)
    final files = <File>[];
    await for (final entity in _cacheDirectory!.list()) {
      if (entity is File) files.add(entity);
    }

    files.sort((a, b) {
      final statA = a.statSync().modified;
      final statB = b.statSync().modified;
      return statA.compareTo(statB);
    });

    // Удаляем старые файлы пока не влезет в лимит
    int currentSize = cacheSize;
    for (final file in files) {
      if (currentSize <= maxSizeBytes) break;

      final fileSize = await file.length();
      final trackId = file.uri.pathSegments.last.split('.').first;

      await file.delete();
      _downloadedTrackIds.remove(trackId);
      currentSize -= fileSize;
    }

    notifyListeners();
  }

  /// Удаление скачанного трека
  Future<void> deleteTrack(String trackId) async {
    if (_cacheDirectory == null) return;

    for (final ext in ['mp3', 'ogg', 'flac', 'm4a']) {
      final file = File('${_cacheDirectory!.path}/$trackId.$ext');
      if (await file.exists()) {
        await file.delete();
        _downloadedTrackIds.remove(trackId);
        notifyListeners();
        return;
      }
    }
  }

  /// Полная очистка кэша
  Future<void> clearCache() async {
    if (_cacheDirectory == null || !await _cacheDirectory!.exists()) return;

    await _cacheDirectory!.delete(recursive: true);
    await _cacheDirectory!.create(recursive: true);
    _downloadedTrackIds.clear();
    _downloadProgress.clear();
    notifyListeners();
  }

  Timer? _onlineDebounce;
  /// Слушатель изменений подключения к сети.
  /// Возврат сети — с дебаунсом 3с: дребезг WiFi/LTE иначе дёргает
  /// re-auth по нескольку раз и мигает экранами.
  void _listenConnectivityChanges() {
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) {
      final hasConnection = results.any((r) => r != ConnectivityResult.none);

      if (!hasConnection && autoSwitchOffline) {
        _onlineDebounce?.cancel();
        _isOfflineMode = true;
        notifyListeners();
      } else if (hasConnection && _isOfflineMode) {
        // При возвращении сети проверяем реальную доступность сервера.
        // Дебаунс: ждём устойчивого соединения, а не первый флэп.
        _onlineDebounce?.cancel();
        _onlineDebounce = Timer(const Duration(seconds: 3), () {
          if (_isOfflineMode) _verifyServerAndGoOnline();
        });
      }
    });
  }

  /// Проверка доступности сервера перед выходом из офлайн режима.
  /// Старый raw-пинг без auth (без p/t/s) всегда получал 401 и держал
  /// пользователя в офлайне вечно. Теперь сразу выходим из офлайна и
  /// отдаём проверку AuthProvider.retryConnection (pingWithError с auth) —
  /// он сам решит serverUnreachable/authenticated.
  void _verifyServerAndGoOnline() {
    _isOfflineMode = false;
    notifyListeners();
    try {
      onOnlineRestored?.call();
    } catch (_) {}
    for (final cb in _onlineListeners.toList()) {
      try {
        cb();
      } catch (_) {}
    }
  }

  /// Принудительное переключение в офлайн режим
  void setOfflineMode(bool value) {
    _isOfflineMode = value;
    notifyListeners();
  }

  /// Получение файла для воспроизведения (офлайн или онлайн путь)
  Future<File?> getPlayableFile(String trackId) async {
    // Сначала проверяем локальный кэш
    final localFile = await getTrackFile(trackId);
    if (localFile != null) {
      _currentPlayingFile = localFile;
      notifyListeners();
      return localFile;
    }

    // Если в офлайн режиме и файла нет - ошибка
    if (_isOfflineMode) {
      _error = 'Трек не доступен в офлайн режиме';
      notifyListeners();
      return null;
    }

    return null;
  }

  // ─── Совместимость с существующим API ───────────────────────────────

  Future<void> initialize() => init();

  Set<String> getDownloadedSongIds() => _downloadedTrackIds.toSet();

  String? getLocalPath(String trackId) {
    if (_cacheDirectory == null) return null;
    for (final ext in ['mp3', 'ogg', 'flac', 'm4a', 'mp4', 'opus', 'wav', 'aac', 'wma']) {
      final file = File('${_cacheDirectory!.path}/$trackId.$ext');
      if (file.existsSync()) return file.path;
      // ABS book chunk cache: abs_{itemId}_ch_* maps to abs_cache subdir via _absCacheDir
      final absFile = File('${_cacheDirectory!.path}/abs_cache/$trackId.$ext');
      if (absFile.existsSync()) return absFile.path;
    }
    // Check abs_cache prefix for book files: abs_{itemId}_ch_*
    if (trackId.startsWith('abs_')) {
      for (final ext in ['mp3', 'ogg', 'flac', 'm4a', 'mp4', 'opus', 'wav', 'aac', 'wma']) {
        final f = File('${_cacheDirectory!.path}/abs_cache/$trackId.$ext');
        if (f.existsSync()) return f.path;
      }
    }
    return null;
  }

  // ── Podcast cache helpers ──────────────────────────────────────────────
  Directory get _podcastCacheDir => Directory('${_cacheDirectory!.path}/podcast_cache');

  Future<void> _ensurePodcastCacheDir() async {
    if (_cacheDirectory == null) await _setupCacheDirectory();
    if (!await _podcastCacheDir.exists()) await _podcastCacheDir.create(recursive: true);
  }

  bool isPodcastEpisodeDownloaded(String episodeId) {
    if (_cacheDirectory == null) return false;
    for (final ext in ['mp3', 'ogg', 'm4a', 'mp4', 'opus', 'aac', 'wav']) {
      final f = File('${_podcastCacheDir.path}/$episodeId.$ext');
      if (f.existsSync()) return true;
    }
    return _downloadedTrackIds.contains(episodeId);
  }

  String? getPodcastLocalPath(String episodeId) {
    if (_cacheDirectory == null) return null;
    for (final ext in ['mp3', 'ogg', 'm4a', 'mp4', 'opus', 'aac', 'wav']) {
      final f = File('${_podcastCacheDir.path}/$episodeId.$ext');
      if (f.existsSync()) return f.path;
    }
    return getLocalPath(episodeId);
  }

  Future<bool> downloadPodcastEpisode({required String episodeId, required String audioUrl, Function(double)? onProgress}) async {
    if (!CacheSettingsService().getMusicCacheEnabled()) return false;
    await _ensurePodcastCacheDir();
    if (_cacheDirectory == null) return false;
    _downloadProgress[episodeId] = DownloadProgress(trackId: episodeId, progress: 0);
    notifyListeners();
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
      final req = await client.getUrl(Uri.parse(audioUrl));
      req.headers.set('User-Agent', 'KumaFlow/1.0');
      final resp = await req.close();
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final mime = resp.headers.contentType?.mimeType ?? 'audio/mpeg';
      final ext = mime.contains('ogg') ? 'ogg' : mime.contains('m4a') || mime.contains('mp4') ? 'm4a' : mime.contains('flac') ? 'flac' : 'mp3';
      final filePath = '${_podcastCacheDir.path}/$episodeId.$ext';
      final file = File(filePath);
      final sink = file.openWrite();
      int received = 0;
      final total = resp.contentLength;
      await resp.forEach((chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          final p = received / total;
          _downloadProgress[episodeId] = _downloadProgress[episodeId]!.copyWith(progress: p);
          onProgress?.call(p);
          notifyListeners();
        }
      });
      await sink.flush(); await sink.close(); client.close(force:true);
      _downloadProgress[episodeId] = _downloadProgress[episodeId]!.copyWith(progress: 1, isComplete: true);
      _downloadedTrackIds.add(episodeId);
      notifyListeners();
      return true;
    } catch (e) {
      _downloadProgress[episodeId] = _downloadProgress[episodeId]!.copyWith(isError: true);
      _error = 'Podcast download $episodeId: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> deletePodcastEpisode(String episodeId) async {
    if (_cacheDirectory == null) await _setupCacheDirectory();
    for (final ext in ["mp3","ogg","m4a","mp4","opus","aac","wav"]) {
      final f = File("${_podcastCacheDir.path}/$episodeId.$ext");
      if (await f.exists()) await f.delete();
    }
    _downloadedTrackIds.remove(episodeId);
    _downloadProgress.remove(episodeId);
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> getDownloadedPodcasts() async {
    if (_cacheDirectory == null) await _setupCacheDirectory();
    if (!await _podcastCacheDir.exists()) return [];
    final files = await _podcastCacheDir.list().where((e) => e is File).cast<File>().toList();
    return files.map((f) => {'id': f.uri.pathSegments.last.split('.').first, 'path': f.path}).toList();
  }

  Future<List<Map<String, dynamic>>> getDownloadedBooks() async {
    if (_cacheDirectory == null) await _setupCacheDirectory();
    if (!await _absCacheDir.exists()) return [];
    final files = await _absCacheDir.list().where((e) => e is File && !e.path.endsWith('.json')).cast<File>().toList();
    final books = <String, Map<String, dynamic>>{};
    for (final f in files) {
      final name = f.uri.pathSegments.last.split('.').first;
      final itemId = name.contains('_') ? name.split('_').take(2).join('_') : name;
      books[itemId] = {'id': itemId, 'path': f.path, 'fileId': name};
    }
    return books.values.toList();
  }

  // ── ABS book cache helpers ──────────────────────────────────────────────
  Directory get _absCacheDir => Directory('${_cacheDirectory!.path}/abs_cache');

  Future<void> _ensureAbsCacheDir() async {
    if (_cacheDirectory == null) await _setupCacheDirectory();
    if (!await _absCacheDir.exists()) await _absCacheDir.create(recursive: true);
  }

  bool isBookDownloaded(String itemId, List<String> fileIds) {
    if (_cacheDirectory == null) return false;
    for (final fid in fileIds) {
      bool found = false;
      for (final ext in ['mp3', 'ogg', 'flac', 'm4a', 'mp4']) {
        final f = File('${_absCacheDir.path}/${itemId}_$fid.$ext');
        if (f.existsSync()) { found = true; break; }
        final f2 = File('${_absCacheDir.path}/${itemId}.$ext');
        if (fileIds.length == 1 && f2.existsSync()) { found = true; break; }
      }
      if (!found) return false;
    }
    return true;
  }

  bool isBookCached(String itemId) {
    if (_cacheDirectory == null) return false;
    if (!_absCacheDir.existsSync()) return false;
    final files = _absCacheDir.listSync().whereType<File>().where((f) => f.path.contains(itemId));
    return files.isNotEmpty;
  }

  String? getBookFilePath(String itemId, String fileId) {
    if (_cacheDirectory == null) return null;
    for (final ext in ['mp3', 'ogg', 'flac', 'm4a', 'mp4']) {
      final f = File('${_absCacheDir.path}/${itemId}_$fileId.$ext');
      if (f.existsSync()) return f.path;
      final f2 = File('${_absCacheDir.path}/${itemId}.$ext');
      if (f2.existsSync()) return f2.path;
    }
    return null;
  }

  Future<int> downloadBook({
    required String itemId,
    required List<Map<String, dynamic>> audioFiles,
    required String baseUrl,
    required String token,
    Function(String fileId, double progress)? onFileProgress,
    Map<String, dynamic>? bookMeta,
  }) async {
    if (!CacheSettingsService().getMusicCacheEnabled()) {
      debugPrint('[OfflineService] skip downloadBook (disabled) $itemId');
      return 0;
    }
    await _ensureAbsCacheDir();
    int ok = 0;
    for (final f in audioFiles) {
      final fid = f['ino']?.toString() ?? '';
      if (fid.isEmpty) continue;
      final url = '$baseUrl/api/items/$itemId/file/$fid?token=$token';
      final success = await _downloadAbsFile(itemId: itemId, fileId: fid, url: url, token: token, onProgress: (p) => onFileProgress?.call(fid, p));
      if (success) ok++;
    }
    // Fallback single file book (no fileId) — try play endpoint
    if (audioFiles.isEmpty || (audioFiles.length == 1 && ok == 0)) {
      final url = '$baseUrl/api/items/$itemId/play?token=$token';
      final success = await _downloadAbsFile(itemId: itemId, fileId: 'single', url: url, token: token, onProgress: (p) => onFileProgress?.call('single', p));
      if (success) ok++;
    }
    notifyListeners();
    return ok;
  }

  Future<bool> _downloadAbsFile({required String itemId, required String fileId, required String url, required String token, Function(double)? onProgress}) async {
    final key = '${itemId}_$fileId';
    _downloadProgress[key] = DownloadProgress(trackId: key, progress: 0);
    notifyListeners();
    try {
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('Authorization', 'Bearer $token');
      final resp = await req.close();
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final mime = resp.headers.contentType?.mimeType ?? 'audio/mpeg';
      final ext = mime.contains('ogg') ? 'ogg' : mime.contains('flac') ? 'flac' : mime.contains('mp4') || mime.contains('m4a') ? 'm4a' : 'mp3';
      final filePath = '${_absCacheDir.path}/${itemId}_$fileId.$ext';
      final file = File(filePath);
      final sink = file.openWrite();
      int received = 0;
      final total = resp.contentLength;
      await resp.forEach((chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          final p = received / total;
          _downloadProgress[key] = _downloadProgress[key]!.copyWith(progress: p);
          onProgress?.call(p);
          notifyListeners();
        }
      });
      await sink.flush(); await sink.close(); client.close();
      _downloadProgress[key] = _downloadProgress[key]!.copyWith(progress: 1, isComplete: true);
      _downloadedTrackIds.add(key);
      notifyListeners();
      return true;
    } catch (e) {
      _downloadProgress[key] = _downloadProgress[key]!.copyWith(isError: true);
      _error = 'ABS download $fileId: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> deleteBook(String itemId) async {
    if (_cacheDirectory == null) return;
    if (!await _absCacheDir.exists()) return;
    await for (final e in _absCacheDir.list()) {
      if (e is File && e.path.contains(itemId)) {
        await e.delete();
        final key = e.uri.pathSegments.last.split('.').first;
        _downloadedTrackIds.remove(key);
      }
    }
    notifyListeners();
  }

  String? getLocalCoverArtPath(String albumId) {
    if (_cacheDirectory == null) return null;
    final file = File('${_cacheDirectory!.path}/cover_$albumId.jpg');
    return file.existsSync() ? file.path : null;
  }

  /// Локальная обложка для песни: пробуем cover_<albumId>, cover_<coverArt>,
  /// cover_<trackId> — скачивание кладёт все три ключа чтобы очередь/плеер
  /// находили файл независимо от того какое поле есть у Song в этом экране.
  String? getLocalCoverForSong({String? albumId, String? coverArt, String? trackId}) {
    if (_cacheDirectory == null) return null;
    for (final key in [albumId, coverArt, trackId]) {
      if (key == null || key.isEmpty) continue;
      final file = File('${_cacheDirectory!.path}/cover_$key.jpg');
      try {
        if (file.existsSync()) return file.path;
      } catch (_) {}
    }
    return null;
  }

  /// Скачать и сохранить обложку трека (best-effort, не роняет загрузку аудио).
  /// coverUrl уже содержит auth-параметры (getCoverArtUrl), качаем напрямую.
  Future<String?> ensureTrackCover({
    String? albumId,
    String? coverArt,
    String? trackId,
    String? coverUrl,
  }) async {
    if (_cacheDirectory == null) await _setupCacheDirectory();
    if (_cacheDirectory == null) return null;
    if (getLocalCoverForSong(albumId: albumId, coverArt: coverArt, trackId: trackId) != null) {
      return getLocalCoverForSong(albumId: albumId, coverArt: coverArt, trackId: trackId);
    }
    if (coverUrl == null || coverUrl.isEmpty) return null;
    final keys = <String>{};
    if (albumId != null && albumId.isNotEmpty) keys.add(albumId);
    if (coverArt != null && coverArt.isNotEmpty) keys.add(coverArt);
    if (trackId != null && trackId.isNotEmpty) keys.add(trackId);
    if (keys.isEmpty) return null;
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final req = await client.getUrl(Uri.parse(coverUrl));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b)).timeout(const Duration(seconds: 15));
      if (bytes.isEmpty) return null;
      String? saved;
      for (final k in keys) {
        try {
          final f = File('${_cacheDirectory!.path}/cover_$k.jpg');
          await f.writeAsBytes(bytes, flush: true);
          saved ??= f.path;
        } catch (_) {}
      }
      return saved;
    } catch (_) {
      return null;
    } finally {
      try { client?.close(force: true); } catch (_) {}
    }
  }

  String? getBookCoverPath(String itemId) {
    if (_cacheDirectory == null) return null;
    final file = File('${_cacheDirectory!.path}/abs_cache/cover_$itemId.jpg');
    return file.existsSync() ? file.path : null;
  }

  Future<String?> saveBookCover(String itemId, List<int> bytes) async {
    await _ensureAbsCacheDir();
    try {
      final file = File('${_absCacheDir.path}/cover_$itemId.jpg');
      await file.writeAsBytes(bytes, flush: true);
      notifyListeners();
      return file.path;
    } catch (_) {
      return null;
    }
  }

  bool isPlaylistDownloaded(String playlistId) {
    if (_cacheDirectory == null) return false;
    final marker = File('${_cacheDirectory!.path}/playlist_$playlistId.marker');
    if (marker.existsSync()) return true;
    return false;
  }

  Future<void> markPlaylistDownloaded(String playlistId) async {
    if (_cacheDirectory == null) await _setupCacheDirectory();
    final marker = File('${_cacheDirectory!.path}/playlist_$playlistId.marker');
    await marker.writeAsString(DateTime.now().toIso8601String());
    notifyListeners();
  }

  Future<bool> downloadPlaylist({required String playlistId, required List<dynamic> tracks, dynamic subsonicService}) async {
    if (!CacheSettingsService().getMusicCacheEnabled()) return false;
    if (tracks.isEmpty) return false;
    // Было строго последовательно: каждый висящий трек (30с+ на плохой сети)
    // тормозил весь плейлист. Качаем чанками по _parallelDownloads —
    // как startBackgroundDownload, плюс уже скачанные пропускаем сразу.
    _cancelRequested = false;
    int ok = 0;
    int done = 0;
    final parallelism = _parallelDownloads.clamp(1, 5);
    for (int i = 0; i < tracks.length; i += parallelism) {
      if (_cancelRequested) break;
      final chunk = tracks.skip(i).take(parallelism).toList();
      final results = await Future.wait(
        chunk.map((t) => downloadSong(t, subsonicService)),
      );
      for (final res in results) {
        if (res) ok++;
      }
      done += chunk.length;
      downloadState.value = DownloadState(isDownloading: done < tracks.length, currentProgress: done, totalCount: tracks.length, downloadedCount: getDownloadedCount());
      notifyListeners();
    }
    // Маркер — только когда скачаны ВСЕ треки (было: ok>0, т.е. частичный
    // плейлист считался скачанным). При частичном — маркер снимаем чтобы
    // иконка честно показывала «не загружено».
    if (ok == tracks.length && tracks.isNotEmpty) {
      await markPlaylistDownloaded(playlistId);
      return true;
    }
    await unmarkPlaylistDownloaded(playlistId);
    return false;
  }

  Future<void> unmarkPlaylistDownloaded(String playlistId) async {
    if (_cacheDirectory == null) return;
    try {
      final marker = File('${_cacheDirectory!.path}/playlist_$playlistId.marker');
      if (await marker.exists()) await marker.delete();
      notifyListeners();
    } catch (_) {}
  }

  /// Сколько треков списка реально лежат на диске (файл + регистрация).
  int countDownloadedTracks(List<dynamic> tracks) {
    var n = 0;
    for (final t in tracks) {
      final id = (t is Song) ? t.id : (t['id']?.toString() ?? t.toString());
      if (isTrackDownloaded(id) || getLocalPath(id) != null) n++;
    }
    return n;
  }

  // ── Scrobble queue — persistent offline queue (P0.7) ──
  static const _scrobbleQueueKey = 'offline_scrobble_queue_v1';
  final List<Map<String, dynamic>> _pendingScrobbles = [];

  Future<void> _loadScrobbleQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_scrobbleQueueKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        _pendingScrobbles
          ..clear()
          ..addAll(list.cast<Map<String, dynamic>>());
      }
    } catch (_) {}
  }

  Future<void> _saveScrobbleQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_scrobbleQueueKey, jsonEncode(_pendingScrobbles));
    } catch (_) {}
  }

  void queueScrobble(String trackId, {required bool submission}) {
    final entry = {
      'id': trackId,
      'submission': submission,
      'time': DateTime.now().millisecondsSinceEpoch,
    };
    _pendingScrobbles.add(entry);
    unawaited(_saveScrobbleQueue());
    debugPrint('[OfflineService] queued scrobble $trackId submission=$submission queue=${_pendingScrobbles.length}');
  }

  Future<void> flushPendingScrobbles(dynamic subsonicService) async {
    if (_pendingScrobbles.isEmpty) {
      await _loadScrobbleQueue();
      if (_pendingScrobbles.isEmpty) return;
    }
    if (subsonicService == null) return;
    final copy = List<Map<String, dynamic>>.from(_pendingScrobbles);
    for (final e in copy) {
      try {
        final id = e['id'] as String;
        final submission = e['submission'] as bool? ?? true;
        final time = e['time'] as int?;
        // ignore: avoid_dynamic_calls
        await (subsonicService as dynamic).scrobble(id, submission: submission, time: time);
        _pendingScrobbles.remove(e);
        await _saveScrobbleQueue();
        debugPrint('[OfflineService] flushed scrobble $id');
      } catch (err) {
        debugPrint('[OfflineService] flush failed ${e['id']}: $err');
        break; // stop on first failure to keep order and retry later
      }
    }
  }

  String? getPlayableUrl(String trackId) => getLocalPath(trackId);

  int getDownloadedCount() => _downloadedTrackIds.length;

  bool get isBackgroundDownloadActive => downloadState.value.isDownloading;

  int _parallelDownloads = 3;
  bool _cancelRequested = false;

  void cancelBackgroundDownload() {
    _cancelRequested = true;
    downloadState.value = DownloadState(
      isDownloading: false,
      currentProgress: downloadState.value.currentProgress,
      totalCount: downloadState.value.totalCount,
      downloadedCount: downloadState.value.downloadedCount,
    );
    notifyListeners();
  }

  Future<void> deleteAllDownloads() async {
    if (_cacheDirectory != null && await _cacheDirectory!.exists()) {
      await for (final entity in _cacheDirectory!.list()) {
        if (entity is File) await entity.delete();
      }
    }
    _downloadedTrackIds.clear();
    downloadState.value = const DownloadState();
    notifyListeners();
  }

  int getParallelDownloadsCount() => _parallelDownloads;
  bool getKeepScreenOn() => false;
  Future<void> setKeepScreenOn(bool value) async {}
  bool isSongDownloaded(String trackId) => _downloadedTrackIds.contains(trackId);
  Future<void> deleteSong(String trackId) async => deleteTrack(trackId);
  Future<bool> downloadSong(dynamic song, dynamic subsonicService, {Function(double)? onProgress}) async {
    try {
      final String id = (song is Song) ? song.id : (song['id']?.toString() ?? song.toString());
      final String title = (song is Song) ? song.title : (song['title']?.toString() ?? 'Track');
      final String artist = (song is Song) ? (song.artist ?? 'Unknown') : (song['artist']?.toString() ?? 'Unknown');
      final String? albumId = (song is Song) ? song.albumId : song['albumId']?.toString();
      final String? coverArt = (song is Song) ? song.coverArt : song['coverArt']?.toString();
      // Уже лежит на диске целиком — не качаем повторно, но обложку
      // до gaps докачиваем (без неё очередь/плеер в офлайне пустые).
      if (isTrackDownloaded(id) || getLocalPath(id) != null) {
        try {
          if (getLocalCoverForSong(albumId: albumId, coverArt: coverArt, trackId: id) == null &&
              subsonicService != null && coverArt != null && coverArt.isNotEmpty) {
            final coverUrl = (subsonicService as dynamic).getCoverArtUrl(coverArt, size: 300) as String;
            await ensureTrackCover(albumId: albumId, coverArt: coverArt, trackId: id, coverUrl: coverUrl);
          }
        } catch (_) {}
        return true;
      }
      if (subsonicService != null) syncFromSubsonic(subsonicService);
      final ok = await downloadTrack(trackId: id, title: title, artist: artist, albumId: albumId, subsonicService: subsonicService);
      // Аудио скачалось — тянем обложку следом (best-effort).
      try {
        if (ok && subsonicService != null && coverArt != null && coverArt.isNotEmpty) {
          final coverUrl = (subsonicService as dynamic).getCoverArtUrl(coverArt, size: 300) as String;
          await ensureTrackCover(albumId: albumId, coverArt: coverArt, trackId: id, coverUrl: coverUrl);
        }
      } catch (_) {}
      return ok;
    } catch (e) {
      debugPrint('[OfflineService] downloadSong error $e');
      return false;
    }
  }
  Future<void> setParallelDownloadsCount(int count) async {
    _parallelDownloads = count.clamp(1, 5);
    notifyListeners();
  }

  Future<void> startBackgroundDownload(dynamic songs, dynamic subsonicService) async {
    final List<dynamic> list = (songs is List) ? songs : [];
    if (list.isEmpty) return;
    if (subsonicService != null) syncFromSubsonic(subsonicService);
    if (_cacheDirectory == null) await _setupCacheDirectory();
    _cancelRequested = false;
    downloadState.value = DownloadState(isDownloading: true, totalCount: list.length, currentProgress: 0, downloadedCount: getDownloadedCount());
    notifyListeners();
    int done = 0;
    // Process in chunks of _parallelDownloads to respect parallelism
    for (int i = 0; i < list.length; i += _parallelDownloads) {
      if (_cancelRequested) break;
      final chunk = list.skip(i).take(_parallelDownloads).toList();
      final futures = chunk.map((s) => downloadSong(s, subsonicService)).toList();
      await Future.wait(futures);
      done += chunk.length;
      downloadState.value = DownloadState(
        isDownloading: !_cancelRequested && done < list.length,
        currentProgress: done,
        totalCount: list.length,
        downloadedCount: getDownloadedCount(),
      );
      notifyListeners();
      // small gap to avoid saturating network
      if (!_cancelRequested && i + _parallelDownloads < list.length) {
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
    if (!_cancelRequested) {
      downloadState.value = DownloadState(isDownloading: false, currentProgress: done, totalCount: list.length, downloadedCount: getDownloadedCount());
      notifyListeners();
    }
  }

  /// Предзагрузка следующих N песен из очереди для оффлайн-плеера
  Future<void> preloadNextSongs(List<Song> queue, int currentIndex, {dynamic subsonicService}) async {
    if (!CacheSettingsService().getMusicCacheEnabled()) return;
    final count = CacheSettingsService().getPreloadCount();
    if (count <= 0 || queue.isEmpty) return;
    if (currentIndex < 0 || currentIndex >= queue.length) return;
    if (subsonicService != null) syncFromSubsonic(subsonicService);
    final end = (currentIndex + 1 + count).clamp(0, queue.length);
    for (int i = currentIndex + 1; i < end; i++) {
      final song = queue[i];
      if (song.isLocal == true) continue;
      if (song.id.startsWith('abs_')) continue;
      if (isTrackDownloaded(song.id)) continue;
      if (getLocalPath(song.id) != null) continue;
      if (_cacheDirectory == null) await _setupCacheDirectory();
      if (_cacheDirectory == null) continue;
      // fire-and-forget with small gap, with auth via subsonicService
      unawaited(downloadTrack(trackId: song.id, title: song.title, artist: song.artist ?? 'Unknown', albumId: song.albumId, subsonicService: subsonicService));
      await Future.delayed(const Duration(milliseconds: 350));
    }
  }

  Future<Map<String, dynamic>?> getLocalLyrics(String songId) async => null;

  Future<int> getDownloadedSize() async {
    return await getCacheSize();
  }

  String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    super.dispose();
  }
}


