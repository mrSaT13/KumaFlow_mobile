import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'kumaflow_brain_client.dart';
import 'kumaflow_brain_mapper.dart';
import 'kumaflow_brain_options.dart';
import 'kumaflow_brain_settings.dart';
import '../ml_service.dart';

/// Best-effort мост мобила -> KumaFlow Brain. Никогда не бросает исключения наружу.
/// Сервер недоступен -> тихий локальный fallback, ретраи с backoff, очередь не рвём.
/// Идемпотентность: повторный sync-from-mobile безопасен (max-семантика на сервере).
class KumaFlowBrainBridge extends ChangeNotifier {
  final KumaFlowBrainSettings settings;
  KumaFlowBrainClient? _client;
  String _clientKey = '';

  final List<Map<String, dynamic>> _pendingEvents = [];
  int _failCount = 0;
  DateTime? _nextRetryAt;
  bool _syncing = false;

  /// missing из KumaFlowBrainWaveResolver — складываем в exclude_ids следующего
  /// waveContinue (по ТЗ 3b). Cap 500 как в вебе (brain-autodj.ts:16), dedup.
  final List<String> _pendingExcludeIds = [];
  List<String> get pendingExcludeIds => List.unmodifiable(_pendingExcludeIds);

  /// M1: кольцо последних 20 событий как в вебе (brain-events.ts:18 recentRing).
  /// reportEvent() кладёт одновременно в _pendingEvents (для POST /events
  /// с backoff) и в _recentRing (для waveContinue без ожидания синка).
  /// Сервер применяет их через apply_delta сразу в запросе волны.
  static const int _recentRingCap = 20;
  final List<Map<String, dynamic>> _recentRing = [];
  List<Map<String, dynamic>> get recentRing => List.unmodifiable(_recentRing);

  /// Дельта оценок для waveContinue: reportRate() пишет и в POST /rate,
  /// и сюда (cap 50). Сбрасывается после успешного waveContinue.
  static const int _ratingsDeltaCap = 50;
  final List<Map<String, dynamic>> _ratingsDelta = [];
  List<Map<String, dynamic>> get ratingsDelta => List.unmodifiable(_ratingsDelta);

  void noteMissing(Iterable<String> ids) {
    var changed = false;
    for (final id in ids) {
      final t = id.trim();
      if (t.isEmpty || _pendingExcludeIds.contains(t)) continue;
      _pendingExcludeIds.add(t);
      changed = true;
    }
    while (_pendingExcludeIds.length > 500) {
      _pendingExcludeIds.removeAt(0);
    }
    if (changed) notifyListeners();
  }

  void clearExcludeIds() {
    if (_pendingExcludeIds.isNotEmpty) {
      _pendingExcludeIds.clear();
      notifyListeners();
    }
  }

  /// Зеркало очереди на веб: throttle ~5с + дедуп по ключу как на десктопе
  /// (brain-wave.ts: ключ = user|current|len|первые 3|paused|posBucket 10с).
  /// Без дедупа heartbeat слал одинаковый payload каждые 15с и грузил сервер.
  /// Сервер без publish (старый деплой, 404) — молча игнорируем.
  /// paused — строгий bool (строка "false" на сервере стала бы True).
  DateTime? _lastPublishAt;
  String? _lastPublishKey;

  /// Слот этого девайса (UUID). Ставит плеер после _ensureWaveDeviceId():
  /// нужен чтобы resume брал ЧУЖОЙ слот, а не свежайший свой (heartbeat
  /// каждые 15с делал бы карточку «Продолжить» вечно своей).
  String? ownDeviceId;

  String _publishKey(
    List<String> queueIds,
    String? currentId,
    int? positionSec,
    int? durationSec,
    bool paused, {
    bool? isWave,
    String? playlistName,
  }) {
    final head = queueIds.take(3).join(',');
    final posBucket =
        positionSec != null ? positionSec ~/ 10 : -1;
    final dur = durationSec ?? -1;
    return '${currentId ?? ''}|${queueIds.length}|$head|${paused ? 1 : 0}|$posBucket|$dur|${isWave == true ? 1 : 0}|${playlistName ?? ''}';
  }

  void publishQueueThrottled(
    List<String> queueIds,
    String? currentId, {
    int? positionSec,
    int? durationSec,
    String? device,
    String? deviceName,
    bool paused = false,
    bool? isWave,
    String? playlistName,
    Map<String, dynamic>? waveSettings,
    String? radioSeed,
  }) {
    if (!isActive || queueIds.isEmpty || isOfflineNow) return;
    final now = DateTime.now();
    final key = _publishKey(
        queueIds, currentId, positionSec, durationSec, paused,
        isWave: isWave, playlistName: playlistName);
    if (_lastPublishAt != null &&
        now.difference(_lastPublishAt!) < const Duration(seconds: 5) &&
        key == _lastPublishKey) {
      return;
    }
    _lastPublishAt = now;
    _lastPublishKey = key;
    unawaited(() async {
      try {
        await _client!
            .publishQueue(
              userId: settings.userId,
              queue: queueIds.take(100).toList(),
              currentTrackId: currentId,
              positionSec: positionSec,
              durationSec: durationSec,
              device: device,
              deviceName: deviceName,
              paused: paused,
              isWave: isWave,
              playlistName: playlistName,
              waveSettings: waveSettings,
              radioSeed: radioSeed,
            )
            .timeout(const Duration(seconds: 6));
      } catch (_) {}
    }());
  }

  /// Явные события (пауза/анпауз/seek/reorder/смена трека): мимо throttle,
  /// но НЕ мимо дедупа — скраб сика десятью одинаковыми payload не грузит.
  /// Heartbeat (~15с из плеера) идёт через throttled-вариант выше.
  void publishQueueNow(
    List<String> queueIds,
    String? currentId, {
    int? positionSec,
    int? durationSec,
    String? device,
    String? deviceName,
    bool paused = false,
    bool? isWave,
    String? playlistName,
    Map<String, dynamic>? waveSettings,
    String? radioSeed,
  }) {
    if (!isActive || queueIds.isEmpty || isOfflineNow) return;
    final key = _publishKey(
        queueIds, currentId, positionSec, durationSec, paused,
        isWave: isWave, playlistName: playlistName);
    if (key == _lastPublishKey) return;
    _lastPublishAt = DateTime.now();
    _lastPublishKey = key;
    unawaited(() async {
      try {
        await _client!
            .publishQueue(
              userId: settings.userId,
              queue: queueIds.take(100).toList(),
              currentTrackId: currentId,
              positionSec: positionSec,
              durationSec: durationSec,
              device: device,
              deviceName: deviceName,
              paused: paused,
              isWave: isWave,
              playlistName: playlistName,
              waveSettings: waveSettings,
              radioSeed: radioSeed,
            )
            .timeout(const Duration(seconds: 6));
      } catch (_) {}
    }());
  }

  /// Handoff: сырой ответ /api/wave/resume. null = мост выкл, офлайн или сеть.
  Future<Map<String, dynamic>?> fetchResume({String? device}) async {
    if (!isActive || isOfflineNow) return null;
    try {
      return await _client!
          .fetchResume(settings.userId, device: device)
          .timeout(const Duration(seconds: 7));
    } catch (_) {
      return null;
    }
  }

  /// Имя слота для UI: display_name из /api/me/devices (то, что задано
  /// в вебе), иначе сырая метка device, иначе id слота.
  static String displayNameForSlot(
      List<Map<String, dynamic>> devices, String slot, String raw) {
    for (final d in devices) {
      if ((d['device_id'] ?? '').toString() == slot) {
        final disp = (d['display_name'] ?? '').toString().trim();
        if (disp.isNotEmpty) return disp;
        final r = (d['device'] ?? '').toString().trim();
        if (r.isNotEmpty) return r;
        return slot;
      }
    }
    if (raw.trim().isNotEmpty) return raw.trim();
    return slot;
  }

  static List<Map<String, dynamic>> _devicesOf(Map<String, dynamic> res) {
    final raw = res['devices'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
  }

  /// Парсеный resume для UI (карточка «Продолжить» в hero) и плеера.
  /// null = неактивно/сеть/нет данных/stale/нет трека.
  /// Условия показа (почему карточка «не всегда»):
  /// 1) мост активен + онлайн;
  /// 2) свежайший слот — ЧУЖОЙ (свой heartbeat каждые 15с иначе всегда
  ///    свежайший; тогда ищем свежайший чужой слот в devices[] и читаем
  ///    именно его через ?device=);
  /// 3) слот свежий (TTL сервера 10 мин, иначе stale → null);
  /// 4) трек известен мозгу (иначе available=false → null).
  /// Свой слот опознаём по ownDeviceId (ставит плеер); если не задан —
  /// старое поведение (свежайший слот, свой прячется сравнением трека в hero).
  Future<KumaFlowBrainResume?> fetchResumeInfo() async {
    final res = await fetchResume();
    if (res is! Map<String, dynamic>) return null;
    final devices = _devicesOf(res);
    final latestSlot = (res['device_id'] ?? '').toString();
    final own = ownDeviceId ?? '';
    Map<String, dynamic> picked = res;
    if (own.isNotEmpty && latestSlot.isNotEmpty && latestSlot == own) {
      // Свежайший — свой: ищем свежайший чужой живой слот.
      String? other;
      var bestAge = 1 << 30;
      for (final d in devices) {
        final slot = (d['device_id'] ?? '').toString();
        if (slot.isEmpty || slot == own) continue;
        final age = d['age_sec'];
        final ageSec = age is num ? age.toInt() : 1 << 30;
        if (ageSec < 600 && ageSec < bestAge) {
          bestAge = ageSec;
          other = slot;
        }
      }
      if (other == null) return null; // чужих живых слотов нет — нечего продолжать
      final otherRes = await fetchResume(device: other);
      if (otherRes is! Map<String, dynamic>) return null;
      picked = otherRes;
    }
    if (picked['available'] != true || picked['stale'] == true) return null;
    final t = picked['track'];
    if (t is! Map) return null;
    final tm = Map<String, dynamic>.from(t);
    final ext = (tm['external_id'] ?? '').toString();
    final tid = (tm['track_id'] ?? '').toString();
    if (ext.isEmpty && tid.isEmpty) return null;
    var pos = 0;
    if (picked['position_sec'] is num) {
      pos = (picked['position_sec'] as num).toInt();
    }
    int? dur;
    if (picked['duration_sec'] is num) {
      dur = (picked['duration_sec'] as num).toInt();
    }
    final q = picked['queue'];
    final queue = q is List
        ? q
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .take(50)
            .toList()
        : const <String>[];
    final slot = (picked['device_id'] ?? latestSlot).toString();
    final raw = (picked['device'] ?? '').toString();
    final devs = _devicesOf(picked);
    final ws = picked['wave_settings'];
    return KumaFlowBrainResume(
      trackId: tid.isNotEmpty ? tid : ext,
      externalId: ext.isNotEmpty ? ext : null,
      title: (tm['title'] ?? '').toString(),
      artist: (tm['artist_name'] ?? '').toString(),
      positionSec: pos,
      durationSec: dur,
      paused: picked['paused'] == true,
      queueIds: queue,
      device: raw,
      deviceId: slot,
      displayName: displayNameForSlot(
          devs.isNotEmpty ? devs : devices, slot, raw),
      ageSec:
          picked['age_sec'] is num ? (picked['age_sec'] as num).toInt() : null,
      isWave: picked['is_wave'] == true,
      playlistName: (picked['playlist_name'] ?? '').toString().trim().isEmpty
          ? null
          : (picked['playlist_name'] ?? '').toString(),
      waveSettings: ws is Map ? Map<String, dynamic>.from(ws) : null,
      radioSeed: (picked['radio_seed'] ?? '').toString().trim().isEmpty
          ? null
          : (picked['radio_seed'] ?? '').toString(),
    );
  }

  /// Последние auto_* ответы сервера для тостов:
  /// 3 скипа -> автодизлайк, 3 дизлайка артиста -> автобан.
  void Function(String message)? onAutoAction;

  KumaFlowBrainBridge(this.settings) {
    settings.addListener(_onSettingsChanged);
    _onSettingsChanged();
  }

  @override
  void dispose() {
    settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    final key = '${settings.normalizedBaseUrl}|${settings.userId}|${settings.apiToken}';
    if (key != _clientKey) {
      _clientKey = key;
      _client = settings.isActive
          ? KumaFlowBrainClient(settings.normalizedBaseUrl, authToken: settings.apiToken)
          : null;
      _pendingEvents.clear();
      _pendingExcludeIds.clear();
      _failCount = 0;
      _nextRetryAt = null;
      _loadCachedOptions();
      notifyListeners();
      // Каталог занятий — best-effort сразу при активации, без ожидания UI.
      if (isActive && !isOfflineNow) {
        unawaited(fetchWaveOptions());
        // Удаления вкусов с других устройств — тоже сразу, но только если
        // локальный ML уже загружен (иначе pull применится в пустоту).
        unawaited(() async {
          try {
            final ml = MLService();
            if (!ml.isInitialized) return;
            await pullTasteRemovals(ml);
          } catch (_) {}
        }());
      }
    } else if (!settings.isActive) {
      _client = null;
    }
  }

  // ---------- каталог волны /api/wave/options (занятия с сервера) ----------

  BrainWaveOptions _waveOptions = BrainWaveOptions.fallback;
  bool _optionsFetching = false;
  bool _optionsFromServer = false;

  /// Текущий каталог: серверный если загружен, иначе кеш, иначе fallback.
  BrainWaveOptions get waveOptions => _waveOptions;

  /// Каталог приехал с сервера в этой сессии (а не из кеша/фолбека).
  bool get waveOptionsFromServer => _optionsFromServer;

  /// Источник каталога для UI-диагностики: server/cache/builtin.
  String get waveOptionsSource {
    if (_optionsFromServer) return 'server';
    try {
      if (settings.cachedOptionsJson.trim().isNotEmpty) return 'cache';
    } catch (_) {}
    return 'builtin';
  }

  void _loadCachedOptions() {
    try {
      _waveOptions = settings.cachedWaveOptions;
    } catch (_) {
      _waveOptions = BrainWaveOptions.fallback;
    }
    _optionsFromServer = false;
  }

  /// Подгрузка каталога с сервера (best-effort, никогда не бросает наружу).
  /// Без force при свежем кеше (<24ч) сеть не трогаем.
  /// Офлайн — сразу отдаём кеш/fallback.
  Future<BrainWaveOptions> fetchWaveOptions({bool force = false}) async {
    _loadCachedOptions();
    if (!isActive || isOfflineNow) return _waveOptions;
    if (!force && settings.isOptionsCacheFresh) return _waveOptions;
    if (_optionsFetching) return _waveOptions;
    final c = _client;
    if (c == null) return _waveOptions;
    _optionsFetching = true;
    try {
      final res = await c
          .waveOptions()
          .timeout(const Duration(seconds: 10));
      final parsed = BrainWaveOptions.fromJson(
        res,
        fetchedAt: DateTime.now(),
      );
      if (parsed.isNotEmpty) {
        _waveOptions = parsed;
        _optionsFromServer = true;
        // Кеш персистим fire-and-forget: UI уже обновлён, диск догонит.
        unawaited(() async {
          try {
            await settings.cacheWaveOptions(res);
            _loadCachedOptions();
            // Серверный каталог полнее зашитого — держим его в памяти,
            // даже если кеш-парс дал fallback (напр. старый формат).
            _waveOptions = parsed;
            _optionsFromServer = true;
            notifyListeners();
          } catch (_) {}
        }());
        notifyListeners();
      }
    } catch (_) {
      // Тихий fallback на кеш — очередь/волна не рвутся.
    } finally {
      _optionsFetching = false;
    }
    return _waveOptions;
  }

  // ---------- общие настройки волны (одни на всех устройствах) ----------
  // GET/PUT /api/wave/settings. Пилюли, выбранные на любом плеере, хранятся
  // на мозге; чего нет в settings запроса continue — мозг доберёт отсюда.
  Map<String, dynamic> _sharedWave = const {};
  bool _sharedFetching = false;

  /// Последний известный общий снапшот (память; пусто = не грузили/нет).
  Map<String, dynamic> get sharedWaveSettings =>
      Map<String, dynamic>.unmodifiable(_sharedWave);

  /// Подтянуть общие настройки с мозга (best-effort). Без force при
  /// непустом кеше сеть не трогаем — GET дешёвый, но шит и так делает
  /// достаточно запросов.
  Future<Map<String, dynamic>> fetchSharedWaveSettings(
      {bool force = false}) async {
    if (!isActive || isOfflineNow) return sharedWaveSettings;
    if (!force && _sharedWave.isNotEmpty) return sharedWaveSettings;
    if (_sharedFetching) return sharedWaveSettings;
    final c = _client;
    if (c == null) return sharedWaveSettings;
    _sharedFetching = true;
    try {
      final res = await c
          .getWaveSettings(settings.userId)
          .timeout(const Duration(seconds: 10));
      final s = res['settings'];
      if (s is Map) {
        _sharedWave = Map<String, dynamic>.from(s);
        notifyListeners();
      }
    } catch (_) {
      // Тихий fallback: остаются локальные пилюли.
    } finally {
      _sharedFetching = false;
    }
    return sharedWaveSettings;
  }

  /// Записать общие настройки на мозг (best-effort). Пустая строка стирает
  /// пилюлю, пустой map = сброс для всех. Возвращает ok.
  Future<bool> pushSharedWaveSettings(Map<String, dynamic> wave) async {
    if (!isActive || isOfflineNow) return false;
    final c = _client;
    if (c == null) return false;
    try {
      await c
          .putWaveSettings(settings.userId, wave)
          .timeout(const Duration(seconds: 10));
      _sharedWave = Map<String, dynamic>.from(wave);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }
  // ---------- taste pull: удаления с сервера (tombstones, v0.3.0) ----------
  // Разбаны/анлайки, сделанные на другом устройстве, расходятся сюда через
  // since-курсор (server_now прошлого pull). Без курсора сервер отдаёт
  // только added — чистить нечего (свежему клиенту).
  static const _kSyncCursorPrefix = 'brain_sync_cursor_';

  /// Подтянуть удаления вкусов и применить к [ml]. Возвращает число
  /// применённых (для тоста/лога). Best-effort, никогда не бросает.
  Future<int> pullTasteRemovals(MLService ml) async {
    final c = client;
    if (c == null || isOfflineNow) return 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      final cursorKey = '$_kSyncCursorPrefix${settings.userId}';
      final since = prefs.getString(cursorKey);
      final res = await c
          .syncToMobile(settings.userId, since: since)
          .timeout(const Duration(seconds: 15));
      var applied = 0;
      final removed = res['removed'];
      if (removed is List) {
        for (final r in removed) {
          if (r is! Map) continue;
          final m = Map<String, dynamic>.from(r);
          try {
            final ok = ml.applyTasteRemoval(
              kind: (m['kind'] ?? '').toString(),
              key: (m['key'] ?? '').toString(),
              aux: (m['aux'] ?? '').toString(),
            );
            if (ok) applied++;
          } catch (_) {}
        }
      }
      final now = (res['server_now'] ?? '').toString();
      if (now.trim().isNotEmpty) {
        await prefs.setString(cursorKey, now.trim());
      }
      return applied;
    } catch (_) {
      return 0;
    }
  }

  // ---------- vault-check: статус сейфа без полного импорта ----------
  Map<String, dynamic> _vaultStatus = const {};
  bool _vaultChecking = false;

  /// Последний известный статус сейфа (пусто = не проверяли).
  Map<String, dynamic> get vaultStatus =>
      Map<String, dynamic>.unmodifiable(_vaultStatus);

  /// Человекочитаемый бейдж: ок / не запомнен / требует перезапомнить.
  /// null = не проверяли / мост выкл.
  String? get vaultBadge {
    if (!isActive || _vaultStatus.isEmpty) return null;
    final stored = _vaultStatus['stored'] == true;
    if (!stored) return 'не запомнен';
    final ok = _vaultStatus['auth_ok'] == true;
    return ok ? 'ок' : 'требует перезапомнить';
  }

  bool get vaultNeedsAttention {
    if (_vaultStatus.isEmpty) return false;
    if (_vaultStatus['stored'] != true) return false;
    return _vaultStatus['auth_ok'] != true;
  }

  Future<Map<String, dynamic>> fetchVaultStatus({bool force = false}) async {
    if (!isActive || isOfflineNow) return vaultStatus;
    if (!force && _vaultStatus.isNotEmpty) return vaultStatus;
    final c = _client;
    if (c == null || _vaultChecking) return vaultStatus;
    _vaultChecking = true;
    try {
      final res = await c
          .vaultCheck(settings.userId)
          .timeout(const Duration(seconds: 10));
      _vaultStatus = Map<String, dynamic>.from(res);
      notifyListeners();
    } catch (_) {
      // Тихий fallback: бейдж просто не покажем.
    } finally {
      _vaultChecking = false;
    }
    return vaultStatus;
  }

  void clearVaultStatus() {
    if (_vaultStatus.isNotEmpty) {
      _vaultStatus = const {};
      notifyListeners();
    }
  }

  bool get isActive => settings.isActive && _client != null;
  KumaFlowBrainClient? get client => isActive ? _client : null;
  bool get isSyncing => _syncing;

  /// Офлайн-гейт: плеер ставит сюда () => offlineService.isOfflineMode.
  /// В офлайне мост НЕ трогает сеть вообще: waveContinue/resume/publish/rate
  /// сразу идут по локальному пути, события копятся в буфере до онлайна.
  /// Иначе в офлайне каждый рефилл висел бы на таймаутах 6–18с и грузил плеер.
  bool Function()? isOffline;
  bool get isOfflineNow {
    try {
      return isOffline?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  bool _canTry() {
    if (!isActive) return false;
    if (_nextRetryAt == null) return true;
    return DateTime.now().isAfter(_nextRetryAt!);
  }

  void _noteSuccess() {
    _failCount = 0;
    _nextRetryAt = null;
  }

  void _noteFail() {
    _failCount++;
    final secs = (_failCount <= 1)
        ? 10
        : (_failCount == 2)
            ? 30
            : 120;
    _nextRetryAt = DateTime.now().add(Duration(seconds: secs));
  }

  void _handleAuto(Map<String, dynamic> res) {
    try {
      final dis = res['auto_dislikes'];
      final bans = res['auto_bans'];
      if (dis is List && dis.isNotEmpty) {
        onAutoAction?.call('KumaFlow Brain: автодизлайк (${dis.length})');
      }
      if (bans is List && bans.isNotEmpty) {
        onAutoAction?.call('KumaFlow Brain: автобан артиста (${(bans.firstOrNull ?? bans.first).toString()})');
      }
      final banned = res['auto_banned_artist'];
      if (banned != null && banned.toString().isNotEmpty) {
        onAutoAction?.call('KumaFlow Brain: забанен артист $banned');
      }
    } catch (_) {}
  }

  /// Прямой бан/разбан на сервер парой {name, id} (v0.2.9, tombstone сразу).
  /// Best-effort: локальный ML уже обновлён вызывающим, профиль дойдёт и синком.
  void banArtistRemote(String artistId, String artistName) {
    final c = client;
    if (c == null || isOfflineNow) return;
    unawaited(() async {
      try {
        await c
            .banArtist(settings.userId,
                artistName: artistName, artistId: artistId)
            .timeout(const Duration(seconds: 8));
      } catch (_) {}
    }());
  }

  void unbanArtistRemote(String artistId, String artistName) {
    final c = client;
    if (c == null || isOfflineNow) return;
    unawaited(() async {
      try {
        await c
            .unbanArtist(settings.userId,
                artistName: artistName, artistId: artistId)
            .timeout(const Duration(seconds: 8));
      } catch (_) {}
    }());
  }

  /// Подписка/отписка на артиста: плеер -> мозг -> внешний сервис.
  /// Best-effort, как banArtistRemote: локальный лайк уже применён
  /// вызывающим, сеть и старый сервер без роута — тихо.
  /// Состояние подписки — только здесь (колокольчик), лайк не трогаем:
  /// отписка колокольчиком из любимых не исключает.
  static const String _kSubsKey = 'brain_subscribed_v1';
  static const String _kSubsAuxKey = 'brain_subscribed_aux_v1';
  final Set<String> _subscribed = {};
  /// normName -> artist_external_id (Navidrome id): переживает refresh,
  /// чтобы отписка всегда уходила с id, даже если артист переименован
  /// на сервере в каноническое имя.
  final Map<String, String> _subsAux = {};
  bool _subsLoaded = false;

  static String _normSub(String s) => s.trim().toLowerCase();

  /// Синхронное состояние для колокольчика (слушает notifyListeners).
  bool isSubscribedSync(String artistName) =>
      _subscribed.contains(_normSub(artistName));

  /// Ленивая подгрузка: сначала локальный кеш (имена + external_id),
  /// затем best-effort сверка со списком сервера (имена там могут быть
  /// каноническими). external_id переживает refresh в _subsAux.
  Future<void> ensureSubscriptions() async {
    if (_subsLoaded) return;
    _subsLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final s in prefs.getStringList(_kSubsKey) ?? const <String>[]) {
        final k = _normSub(s);
        if (k.isNotEmpty) _subscribed.add(k);
      }
      try {
        final auxRaw = prefs.getString(_kSubsAuxKey);
        if (auxRaw != null && auxRaw.isNotEmpty) {
          final aux = jsonDecode(auxRaw);
          if (aux is Map) {
            aux.forEach((k, v) {
              if (k is String && v is String && k.isNotEmpty) {
                _subsAux[k] = v;
              }
            });
          }
        }
      } catch (_) {}
      notifyListeners();
    } catch (_) {}
    final c = client;
    if (c == null || !isActive) return;
    try {
      final res = await c
          .listSubscriptions(userId: settings.userId)
          .timeout(const Duration(seconds: 8));
      final list = res['subscriptions'];
      if (list is List) {
        // Сервер — истина: заменяем набор целиком (отписки с других
        // устройств тоже должны гасить колокольчик). external_id
        // забираем из ответа, чтобы не терять при refresh.
        final fresh = <String>{};
        final freshAux = <String, String>{};
        for (final raw in list) {
          if (raw is! Map) continue;
          final k = _normSub('${raw['artist_name'] ?? ''}');
          if (k.isNotEmpty) {
            fresh.add(k);
            final ext = '${raw['artist_external_id'] ?? ''}'.trim();
            if (ext.isNotEmpty) freshAux[k] = ext;
          }
        }
        // Локальные external_id, которых сервер не вернул (старые строки
        // без id), не теряем — пригодятся для отписки с id.
        for (final e in _subsAux.entries) {
          freshAux.putIfAbsent(e.key, () => e.value);
        }
        _subscribed
          ..clear()
          ..addAll(fresh);
        _subsAux
          ..clear()
          ..addAll(freshAux);
        notifyListeners();
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setStringList(_kSubsKey, _subscribed.toList());
          await prefs.setString(_kSubsAuxKey, jsonEncode(_subsAux));
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _rememberSub(String artistName, bool on,
      {String? externalId}) async {
    final k = _normSub(artistName);
    if (k.isEmpty) return;
    if (on) {
      _subscribed.add(k);
      final ext = (externalId ?? '').trim();
      if (ext.isNotEmpty) _subsAux[k] = ext;
    } else {
      _subscribed.remove(k);
      _subsAux.remove(k);
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kSubsKey, _subscribed.toList());
      await prefs.setString(_kSubsAuxKey, jsonEncode(_subsAux));
    } catch (_) {}
  }

  /// Возвращает provider-блок сервера ({ok, skipped, error}) или null при сети/мосте.
  /// Локальный колокольчик красим сразу, ошибку сервера показываем снеком.
  Future<Map<String, dynamic>?> subscribeArtistRemote(
      String artistId, String artistName) async {
    final c = client;
    if (c == null || isOfflineNow) return null;
    final name = artistName.trim();
    if (name.isEmpty) return null;
    unawaited(_rememberSub(name, true, externalId: artistId));
    try {
      final res = await c
          .subscribeArtist(
              userId: settings.userId,
              username: settings.username,
              artistName: name,
              artistExternalId: artistId)
          .timeout(const Duration(seconds: 8));
      final provider =
          res['provider'] is Map ? Map<String, dynamic>.from(res['provider']) : null;
      return provider;
    } catch (e) {
      debugPrint('[Brain] subscribe failed: $e');
      return null;
    }
  }

  Future<void> unsubscribeArtistRemote(
      String artistId, String artistName) async {
    final c = client;
    if (c == null || isOfflineNow) return;
    final name = artistName.trim();
    if (name.isEmpty) return;
    final ext = artistId.trim().isNotEmpty
        ? artistId.trim()
        : (_subsAux[_normSub(name)] ?? '');
    unawaited(_rememberSub(name, false));
    try {
      await c
          .unsubscribeArtist(
              userId: settings.userId,
              username: settings.username,
              artistName: name,
              artistExternalId: ext.isNotEmpty ? ext : null)
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('[Brain] unsubscribe failed: $e');
    }
  }

  // ---------- fire-and-forget из плеера ----------

  /// action: play|complete|skip|replay|seek_back|abandon.
  /// trackId = Navidrome song id = external_id KumaFlow Brain.
  /// M1: одновременно кладём в _pendingEvents (POST /events с backoff
  /// 10/30/120с) и в кольцо _recentRing (cap 20) для waveContinue —
  /// иначе сервер работает с отставшим вкусом на 12с–2мин.
  void reportEvent(String trackId, String action, {int positionSec = 0}) {
    if (!isActive || trackId.isEmpty) return;
    final ev = {
      'track_id': trackId,
      'action': action,
      'position_sec': positionSec,
    };
    _pendingEvents.add(Map<String, dynamic>.from(ev));
    if (_pendingEvents.length > 500) {
      _pendingEvents.removeRange(0, _pendingEvents.length - 500);
    }
    _recentRing.add(Map<String, dynamic>.from(ev));
    while (_recentRing.length > _recentRingCap) {
      _recentRing.removeAt(0);
    }
    // Офлайн: только буферизуем (флаш при онлайне), сеть не трогаем.
    if (isOfflineNow) return;
    unawaited(_flushEvents());
  }

  void reportRate(String trackId, bool? like) {
    if (!isActive || trackId.isEmpty) return;
    // M1: оценка сразу видна следующему waveContinue через ratings_delta,
    // не ждём отдельного синка.
    _ratingsDelta.add({'track_id': trackId, 'like': like});
    while (_ratingsDelta.length > _ratingsDeltaCap) {
      _ratingsDelta.removeAt(0);
    }
    if (isOfflineNow) return;
    unawaited(() async {
      if (!_canTry()) return;
      try {
        final res = await _client!
            .rate(settings.userId, trackId, like)
            .timeout(const Duration(seconds: 10));
        _noteSuccess();
        _handleAuto(res);
      } catch (_) {
        _noteFail();
      }
    }());
  }

  void reportHistory(String trackId, {DateTime? at}) {
    if (!isActive || trackId.isEmpty || isOfflineNow) return;
    unawaited(() async {
      if (!_canTry()) return;
      try {
        await _client!
            .postHistory(settings.userId, trackId,
                (at ?? DateTime.now()).toIso8601String())
            .timeout(const Duration(seconds: 10));
        _noteSuccess();
      } catch (_) {
        _noteFail();
      }
    }());
  }

  Future<void> _flushEvents() async {
    if (!isActive || _pendingEvents.isEmpty || !_canTry() || isOfflineNow) {
      return;
    }
    final batch = _pendingEvents.length > 50
        ? _pendingEvents.sublist(0, 50)
        : List<Map<String, dynamic>>.from(_pendingEvents);
    try {
      final res = await _client!
          .postEvents(settings.userId, batch)
          .timeout(const Duration(seconds: 12));
      _pendingEvents.removeRange(0, batch.length);
      _noteSuccess();
      _handleAuto(res);
    } catch (_) {
      _noteFail();
    }
  }

  // ---------- явные вызовы из UI (возвращают результат/ошибку) ----------

  /// После визарда, 1 раз. Страницами, идемпотентно.
  Future<Map<String, dynamic>> syncFromMobileFull(MLService ml) async {
    final c = client;
    if (c == null) throw KumaFlowBrainException('KumaFlow Brain выключен (тумблер/URL/user_id)');
    if (_syncing) throw KumaFlowBrainException('Синхронизация уже идёт');
    _syncing = true;
    notifyListeners();
    try {
      // MLService.TrackRating и ml_types.TrackRating — разные классы,
      // поэтому маппим через dynamic, а не через строгий тип.
      final ratingsAll = ml.ratings.values.map((r) {
        final d = r as dynamic;
        return <String, dynamic>{
          'external_id': (d.songId ?? '').toString(),
          'like': d.like as bool?,
          'playCount': (d.playCount ?? 0) as int,
          'skipCount': (d.skipCount ?? 0) as int,
          'replayCount': (d.replayCount ?? 0) as int,
          'seekBackCount': (d.seekBackCount ?? 0) as int,
          'abandonCount': (d.abandonCount ?? 0) as int,
          'score': d.score is num
              ? (d.score as num).toInt()
              : int.tryParse('${d.score ?? 0}') ?? 0,
          'lastPlayed': d.lastPlayed?.toString(),
        };
      }).toList();
      final profile = KumaFlowBrainMapper.profileToJson(
        preferredGenres: Map<String, double>.from(ml.profile.preferredGenres),
        preferredArtists: Map<String, double>.from(ml.profile.preferredArtists),
        likedSongs: List<String>.from(ml.profile.likedSongs),
        dislikedSongs: List<String>.from(ml.profile.dislikedSongs),
        bannedArtists: List<String>.from(ml.profile.bannedArtists),
        bannedArtistNames: Map<String, String>.from(ml.profile.bannedArtistNames),
        artistDislikeCounts: const {},
      );
      Map<String, dynamic> last = {'ok': true};
      // ratings страницами по 2000 (лимит сервера 20000)
      final chunks = <List<Map<String, dynamic>>>[];
      for (var i = 0; i < ratingsAll.length; i += 2000) {
        chunks.add(ratingsAll.sublist(
            i, i + 2000 > ratingsAll.length ? ratingsAll.length : i + 2000));
      }
      if (chunks.isEmpty) chunks.add(<Map<String, dynamic>>[]);
      for (final chunk in chunks) {
        last = await c.syncFromMobile(settings.userId,
            {'source': 'mobile', 'ratings': chunk, 'profile': profile, 'events': []});
      }
      // Сразу забираем удаления с сервера (курсор сохранится внутри pull).
      try {
        final pulled = await pullTasteRemovals(ml);
        if (pulled > 0) last['tombstones_applied'] = pulled;
      } catch (_) {}
      return last;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// Волна: очередь живёт в клиенте, KumaFlow Brain только докладывает.
  /// Возвращает треки KumaFlow Brain (uuid + title/artist) — маппить обратно через external_id.
  /// M1: свежие события и дельту оценок шлём ВНУТРИ waveContinue
  /// (recent_events + ratings_delta) — сервер применяет их через apply_delta
  /// сразу, не дожидаясь POST /events с backoff 10/30/120с.
  Future<List<KumaFlowBrainTrack>> waveContinue({    required List<String> queue,
    String? currentTrackId,
    int count = 20,
    Map<String, dynamic> settingsMap = const {},
    List<String> excludeIds = const [],
    List<Map<String, dynamic>>? recentEvents,
    List<Map<String, dynamic>>? ratingsDelta,
    String? device,
  }) async {
    final c = client;
    // Офлайн: никакого ожидания 15–18с — сразу пусто, вызывающий идёт
    // в дешёвый локальный fallback (шаффл из скачанного).
    if (c == null || isOfflineNow) return const [];
    try {
      final res = await c
          .waveContinue(
            userId: settings.userId,
            queue: queue,
            currentTrackId: currentTrackId,
            count: count,
            settings: settingsMap,
            excludeIds: excludeIds,
            recentEvents: recentEvents ?? List.unmodifiable(_recentRing),
            ratingsDelta: ratingsDelta ?? List.unmodifiable(_ratingsDelta),
            device: device ?? ownDeviceId,
          )
          .timeout(const Duration(seconds: 15));
      // Оценки сервер применил (apply_delta -> sync_from_mobile) — чистим дельту.
      // Кольцо событий оставляем: оно нужно для session_drift всего запроса.
      if ((ratingsDelta ?? _ratingsDelta).isNotEmpty) _ratingsDelta.clear();
      return KumaFlowBrainMapper.parseWaveTracks(res);
    } catch (_) {
      return const []; // тихий fallback на локальную логику
    }
  }
}

/// Handoff-инфо «где остановился»: трек + позиция + хвост очереди.
/// Общее для стартового автоподхвата плеера и карточки «Продолжить» в hero.
class KumaFlowBrainResume {
  final String trackId;
  final String? externalId;
  final String title;
  final String artist;
  final int positionSec;
  final int? durationSec;
  final bool paused;
  final List<String> queueIds;
  final String device;
  /// Слот сервера (UUID). Нужен чтобы прятать свой слот в hero.
  final String deviceId;
  /// Имя для UI: display_name из /api/me/devices (задано в вебе),
  /// иначе сырая метка device. Пустое = не показывать «с …».
  final String displayName;
  final int? ageSec;
  /// Природа ленты v0.3.2 (handoff): is_wave + playlist_name + wave_settings + radio_seed.
  final bool isWave;
  final String? playlistName;
  final Map<String, dynamic>? waveSettings;
  final String? radioSeed;

  const KumaFlowBrainResume({
    required this.trackId,
    this.externalId,
    this.title = '',
    this.artist = '',
    this.positionSec = 0,
    this.durationSec,
    this.paused = false,
    this.queueIds = const [],
    this.device = '',
    this.deviceId = '',
    this.displayName = '',
    this.ageSec,
    this.isWave = false,
    this.playlistName,
    this.waveSettings,
    this.radioSeed,
  });

  /// Что показать после «Продолжить»: имя девайса если есть.
  String get fromLabel => displayName.trim().isNotEmpty
      ? displayName.trim()
      : device.trim();

  /// Подпись природы ленты: «Моя волна» / имя плейлиста / сид радио.
  String get waveLabel {
    if (playlistName != null && playlistName!.trim().isNotEmpty) {
      return playlistName!.trim();
    }
    final seed = radioSeed?.trim() ?? '';
    if (seed.isNotEmpty) return 'Радио: $seed';
    return isWave ? 'Моя волна' : '';
  }

  /// Играбельный id: external_id (Navidrome) если есть, иначе uuid.
  String get playableId =>
      (externalId != null && externalId!.isNotEmpty) ? externalId! : trackId;

  /// Позиция мм:сс.
  String get positionLabel {
    final s = positionSec.clamp(0, 35999);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  /// Давность публикации человекочитаемо.
  String get ageLabel {
    final a = ageSec;
    if (a == null) return '';
    if (a < 60) return 'только что';
    if (a < 3600) return '${a ~/ 60} мин назад';
    return '${a ~/ 3600} ч назад';
  }
}
