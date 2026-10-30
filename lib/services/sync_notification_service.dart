import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../providers/library_provider.dart';
import 'offline_service.dart';

/// Android progress notifications for library sync and track downloads.
///
/// Shows determinate-progess ongoing notifications while work runs and a
/// final summary when it finishes. Desktop platforms are skipped (the app
/// already shows in-app banners there). Updates are throttled so the
/// notification tray is not spammed.
class SyncNotificationService {
  static final SyncNotificationService instance = SyncNotificationService._();
  SyncNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _ready = false;
  bool _permChecked = false;
  bool _permGranted = false;

  static const String _syncChannelId = 'kumaflow_sync';
  static const String _downloadChannelId = 'kumaflow_download';
  static const int _syncNotifId = 1001;
  static const int _downloadNotifId = 1002;

  DateTime _lastSyncPush = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastSyncPct = -1;
  int _lastSyncDone = -1;
  bool _syncVisible = false;

  DateTime _lastDownloadPush = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastDownloadPct = -1;
  int _lastDownloadDone = -1;
  bool _downloadVisible = false;
  bool _attached = false;
  VoidCallback? _syncListener;
  VoidCallback? _downloadListener;
  LibraryProvider? _attachedLib;
  OfflineService? _attachedOffline;

  /// Акцент для иконки уведомления (монохромный drawable красится системой).
  static const Color _notifAccent = Color(0xFF7C4DFF);

  Future<void> _init() async {
    if (_ready) return;
    try {
      // Монохромная иконка для статус-бара (Android 8+ режет цветной launcher
      // в серый квадрат — поэтому отдельный drawable ic_stat_sync).
      const android = AndroidInitializationSettings('@drawable/ic_stat_sync');
      const darwin = DarwinInitializationSettings();
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: android,
          iOS: darwin,
          macOS: darwin,
        ),
      );
      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidPlugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          _syncChannelId,
          'Синхронизация библиотеки',
          importance: Importance.low,
        ),
      );
      await androidPlugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          _downloadChannelId,
          'Скачивание музыки',
          importance: Importance.low,
        ),
      );
      _ready = true;
    } catch (e) {
      debugPrint('[SyncNotif] init failed: $e');
    }
  }

  Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid) return false;
    if (_permChecked) return _permGranted;
    try {
      var status = await Permission.notification.status;
      if (!status.isGranted && !status.isLimited && !status.isPermanentlyDenied) {
        status = await Permission.notification.request();
      }
      _permGranted = status.isGranted || status.isLimited;
    } catch (_) {
      _permGranted = false;
    }
    _permChecked = true;
    return _permGranted;
  }

  /// Subscribes to sync + download progress. Fire-and-forget from main().
  Future<void> attach(LibraryProvider lib, OfflineService offline) async {
    if (!Platform.isAndroid) return;
    if (_attached) return;
    _attached = true;
    _attachedLib = lib;
    _attachedOffline = offline;
    await _init();
    _syncListener = () => _onSync(lib);
    _downloadListener = () => _onDownload(offline);
    lib.addListener(_syncListener!);
    offline.downloadState.addListener(_downloadListener!);
  }

  /// Отписка — чтобы не было дублей при повторном attach.
  void detach() {
    if (_syncListener != null && _attachedLib != null) {
      _attachedLib!.removeListener(_syncListener!);
    }
    if (_downloadListener != null && _attachedOffline != null) {
      try {
        _attachedOffline!.downloadState.removeListener(_downloadListener!);
      } catch (_) {}
    }
    _syncListener = null;
    _downloadListener = null;
    _attachedLib = null;
    _attachedOffline = null;
    _attached = false;
  }

  bool _throttleOk(
    DateTime last,
    int pct,
    int lastPct,
    int done,
    int lastDone,
  ) {
    // Раньше троттлинг шел только по процентам: при total=231200 один процент
    // это 2312 песен — уведомление висело на "0 / 231200", хотя в приложении
    // счётчик уже "1214 / 231200". Теперь смотрим на сам счётчик done:
    // любое изменение счётчика + не чаще раза в 500мс = живой прогресс.
    if (done == lastDone && pct == lastPct) return false;
    if (pct >= 100) return true;
    if (DateTime.now().difference(last).inMilliseconds < 500) return false;
    return true;
  }

  Future<void> _showProgress({
    required int id,
    required String channelId,
    required String channelName,
    required String title,
    required String body,
    required int done,
    required int total,
  }) async {
    if (!_ready) return;
    if (!await _ensurePermission()) return;
    try {
      final androidDetails = AndroidNotificationDetails(
        channelId,
        channelName,
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        autoCancel: false,
        onlyAlertOnce: true,
        showProgress: true,
        maxProgress: total > 0 ? total : 1,
        progress: done.clamp(0, total > 0 ? total : 1),
        indeterminate: total <= 0,
        enableVibration: false,
        playSound: false,
        icon: 'ic_stat_sync',
        // Монохром в статус-бар, цветной лаунчер — крупной иконкой в шторке.
        largeIcon: const DrawableResourceAndroidBitmap('ic_notif_large'),
        color: _notifAccent,
      );
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(android: androidDetails),
      );
    } catch (e) {
      debugPrint('[SyncNotif] show failed: $e');
    }
  }

  Future<void> _showDone({
    required int id,
    required String channelId,
    required String channelName,
    required String title,
    required String body,
  }) async {
    if (!_ready) return;
    if (!await _ensurePermission()) return;
    try {
      final androidDetails = AndroidNotificationDetails(
        channelId,
        channelName,
        importance: Importance.low,
        priority: Priority.low,
        ongoing: false,
        autoCancel: true,
        onlyAlertOnce: true,
        enableVibration: false,
        playSound: false,
        icon: 'ic_stat_sync',
        largeIcon: const DrawableResourceAndroidBitmap('ic_notif_large'),
        color: _notifAccent,
      );
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(android: androidDetails),
      );
    } catch (e) {
      debugPrint('[SyncNotif] done failed: $e');
    }
  }

  Future<void> _cancel(int id) async {
    try {
      await _plugin.cancel(id: id);
    } catch (_) {}
  }

  void _onSync(LibraryProvider lib) {
    if (!lib.isSyncing) {
      if (!_syncVisible) return;
      _syncVisible = false;
      _lastSyncPct = -1;
      _lastSyncDone = -1;
      final phase = lib.syncPhase;
      if (phase == 'done') {
        final n = lib.syncedSongs;
        _showDone(
          id: _syncNotifId,
          channelId: _syncChannelId,
          channelName: 'Синхронизация библиотеки',
          title: 'Библиотека обновлена',
          body: n > 0 ? 'Синхронизировано треков: $n' : 'Все уже актуально',
        );
      } else {
        _cancel(_syncNotifId);
      }
      return;
    }
    final done = lib.syncedSongs;
    final total = lib.totalSongsEstimate;
    final pct = total > 0 ? ((done * 100) ~/ total).clamp(0, 100) : -1;
    if (!_throttleOk(_lastSyncPush, pct, _lastSyncPct, done, _lastSyncDone)) {
      return;
    }
    _lastSyncPush = DateTime.now();
    _lastSyncPct = pct;
    _lastSyncDone = done;
    _syncVisible = true;
    _showProgress(
      id: _syncNotifId,
      channelId: _syncChannelId,
      channelName: 'Синхронизация библиотеки',
      title: 'Синхронизация библиотеки',
      body: total > 0 ? '$done / $total' : 'Подготовка...',
      done: done,
      total: total,
    );
  }

  void _onDownload(OfflineService offline) {
    final st = offline.downloadState.value;
    if (!st.isDownloading) {
      if (!_downloadVisible) return;
      _downloadVisible = false;
      _lastDownloadPct = -1;
      _lastDownloadDone = -1;
      if (st.totalCount > 0) {
        _showDone(
          id: _downloadNotifId,
          channelId: _downloadChannelId,
          channelName: 'Скачивание музыки',
          title: 'Скачивание завершено',
          body: 'Файлов: ${st.currentProgress}',
        );
      } else {
        _cancel(_downloadNotifId);
      }
      return;
    }
    final done = st.currentProgress;
    final total = st.totalCount;
    final pct = total > 0 ? ((done * 100) ~/ total).clamp(0, 100) : -1;
    if (!_throttleOk(
      _lastDownloadPush,
      pct,
      _lastDownloadPct,
      done,
      _lastDownloadDone,
    )) {
      return;
    }
    _lastDownloadPush = DateTime.now();
    _lastDownloadPct = pct;
    _lastDownloadDone = done;
    _downloadVisible = true;
    _showProgress(
      id: _downloadNotifId,
      channelId: _downloadChannelId,
      channelName: 'Скачивание музыки',
      title: 'Скачивание музыки',
      body: total > 0 ? '$done / $total' : 'Подготовка...',
      done: done,
      total: total,
    );
  }
}
