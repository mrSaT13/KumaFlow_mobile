// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member, avoid_dynamic_calls
// Part of the PlayerProvider library: extension calls notifyListeners()
// on its own instance — same library, no behavior change.
part of '../player_provider.dart';

/// Live-зеркало очереди (чек-лист handoff):
/// publish на смене/паузе/анпаузе/seek/reorder + heartbeat ~15с,
/// поля строго JSON-типами (paused — настоящий bool, не строка),
/// при старте — resume: seek(position_sec), игра по external_id,
/// paused=true открывается без автоплея, stale не автовоспроизводится.
extension PlayerLive on PlayerProvider {
  /// M3: стабильный UUID девайса (как web localStorage wave_device_id).
  /// Раньше слали строку 'android'/'ios' — два телефона делили один слот,
  /// last-writer-wins. Теперь слот = UUID, а платформа едет в device_name.
  static const _kWaveDeviceId = 'wave_device_id';
  static String? _cachedWaveDeviceId;

  String get _liveDevice {
    final cached = _cachedWaveDeviceId;
    if (cached != null && cached.isNotEmpty) return cached;
    // Синхронного SharedPreferences нет — возвращаем платформу до первой
    // асинхронной инициализации, затем UUID. Инициализация — в _ensureWaveDeviceId().
    unawaited(_ensureWaveDeviceId());
    return _liveDeviceName;
  }

  /// Человекочитаемое имя платформы для device_name (не слот!).
  String get _liveDeviceName {
    try {
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
      if (Platform.isMacOS) return 'macos';
      if (Platform.isWindows) return 'windows';
      if (Platform.isLinux) return 'linux';
    } catch (_) {}
    return 'app';
  }

  Future<String> _ensureWaveDeviceId() async {
    final cached = _cachedWaveDeviceId;
    if (cached != null && cached.isNotEmpty) return cached;
    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString(_kWaveDeviceId) ?? '';
      if (id.trim().isEmpty) {
        id = const Uuid().v4();
        await prefs.setString(_kWaveDeviceId, id);
      }
      _cachedWaveDeviceId = id;
      return id;
    } catch (_) {
      return _liveDeviceName;
    }
  }

  /// Зеркало очереди на веб (/api/wave/live + handoff-поля для /resume).
  /// force=true — явные события (трек/пауза/seek/reorder) мимо throttle;
  /// heartbeat идёт throttled (мост режет чаще 1 раза в 5с).
  void _brainPublish({bool force = false}) {
    try {
      if (_queue.isEmpty) return;
      // Slice from current like desktop q.slice(at): history before current is not published.
      final start =
          (_currentIndex >= 0 && _currentIndex < _queue.length) ? _currentIndex : 0;
      final ids = _queue.sublist(start).map((s) => s.id).toList();
      if (ids.isEmpty) return;
      String? cur;
      if (_currentIndex >= 0 && _currentIndex < _queue.length) {
        cur = _queue[_currentIndex].id;
      }
      final b = _brain;
      if (b == null) return;
      if (b.isActive != true) return;
      final posSec = _position.inSeconds;
      final int? durSec =
          _duration.inSeconds > 0 ? _duration.inSeconds : _currentSong?.duration;
      // paused — строгий bool: сервер делает bool(v),
      // строка "false" превратилась бы в True.
      // M3: device = стабильный UUID (слот), deviceName = платформа.
      // Природа ленты — как десктоп player.tsx: имя + isWave едут с каждым
      // publish, иначе принимающий снова покажет «Моя коллекция».
      final qName = _currentQueueName;
      final qIsWave = qName != null && isWavePlaylistName(qName);
      if (force) {
        b.publishQueueNow(ids, cur,
            positionSec: posSec,
            durationSec: durSec,
            device: _liveDevice,
            deviceName: _liveDeviceName,
            paused: !_isPlaying,
            isWave: qIsWave ? true : null,
            playlistName: qName);
      } else {
        b.publishQueueThrottled(ids, cur,
            positionSec: posSec,
            durationSec: durSec,
            device: _liveDevice,
            deviceName: _liveDeviceName,
            paused: !_isPlaying,
            isWave: qIsWave ? true : null,
            playlistName: qName);
      }
    } catch (_) {}
  }

  /// Явное событие зеркала (пауза/анпауз/seek/reorder/смена трека).
  void _brainPublishNow() => _brainPublish(force: true);

  void _startLiveHeartbeat() {
    _stopLiveHeartbeat();
    _liveHeartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      _brainPublish();
    });
  }

  void _stopLiveHeartbeat() {
    _liveHeartbeat?.cancel();
    _liveHeartbeat = null;
  }

  /// Resume для UI: что играет на другом устройстве (null = нечего продолжать).
  /// Тот же источник, что у стартового автоподхвата, — карточка «Продолжить»
  /// в hero пользуется этим, а не отдельным запросом.
  Future<dynamic> fetchServerResume() async {
    try {
      final dynamic b = _brain;
      if (b == null) return null;
      if (b.isActive != true) return null;
      // ownDeviceId подтягиваем лениво: без него resume вернёт свежайший
      // (часто свой) слот вместо чужого.
      try {
        if ((b.ownDeviceId ?? '').toString().isEmpty) {
          final id = await _ensureWaveDeviceId()
              .timeout(const Duration(seconds: 3));
          try {
            b.ownDeviceId = id;
          } catch (_) {}
        }
      } catch (_) {}
      return await b.fetchResumeInfo().timeout(const Duration(seconds: 7));
    } catch (_) {
      return null;
    }
  }

  /// Применить server resume: очередь + seek + play (respect paused).
  /// true = продолжили. Общее для стартового автоподхвата и карточки в hero.
  Future<bool> applyServerResume() async {
    try {
      final dynamic info = await fetchServerResume();
      if (info == null) return false;
      final String ext = (info.externalId ?? '').toString();
      final String tid = (info.trackId ?? '').toString();
      if (ext.isEmpty && tid.isEmpty) return false;
      int pos = 0;
      try {
        pos = (info.positionSec as num).toInt();
      } catch (_) {}
      final bool paused = info.paused == true;
      final List<String> restIds = <String>[];
      try {
        final q = info.queueIds;
        if (q is List) {
          for (final e in q) {
            final s = e.toString();
            if (s.isNotEmpty) restIds.add(s);
            if (restIds.length >= 30) break;
          }
        }
      } catch (_) {}
      final resolver = KumaFlowBrainWaveResolver(_subsonicService);
      final head = await resolver
          .resolve(
            [
              KumaFlowBrainTrack(
                trackId: tid.isNotEmpty ? tid : ext,
                externalId: ext.isNotEmpty ? ext : null,
                title: (info.title ?? '').toString(),
                artist: (info.artist ?? '').toString(),
                score: 0,
                reason: 'resume',
              )
            ],
            maxTracks: 1,
          )
          .timeout(const Duration(seconds: 8));
      if (head.found.isEmpty) return false;
      final rest = <Song>[];
      if (restIds.isNotEmpty) {
        try {
          final rr = await resolver
              .resolve(
                restIds
                    .map((id) => KumaFlowBrainTrack(
                          trackId: id,
                          externalId: id,
                          title: '',
                          artist: '',
                          score: 0,
                          reason: 'resume',
                        ))
                    .toList(),
                maxTracks: restIds.length,
              )
              .timeout(const Duration(seconds: 12));
          rest.addAll(rr.found.map((r) => r.song));
        } catch (_) {}
      }
      final songs = <Song>[head.found.first.song];
      final seen = <String>{songs.first.id};
      for (final s in rest) {
        if (seen.add(s.id)) songs.add(s);
      }
      // Природа ленты от мозга — источник истины (десктоп use-brain-handoff):
      // is_wave + playlist_name, иначе шапка напишет «Моя коллекция».
      try {
        final bool fromBrainWave = info.isWave == true;
        final String brainName = '${info.playlistName ?? ''}'.trim();
        final String dev = '${info.fromLabel ?? ''}'.trim();
        String resolvedName = fromBrainWave
            ? (isWavePlaylistName(brainName)
                ? brainName
                : '${brainName.isNotEmpty ? brainName : 'Продолжить${dev.isNotEmpty ? ' · $dev' : ''}'} · Моя волна')
            : (brainName.isNotEmpty
                ? brainName
                : 'Продолжить${dev.isNotEmpty ? ' · $dev' : ''}');
        _currentQueueName = resolvedName;
        _currentQueueHint = info.waveLabel?.toString();
        if (fromBrainWave) {
          await saveWaveContext(
            songs.map((s) => s.id).toList(),
            info.waveLabel?.toString() ?? '',
            'brain',
          );
        }
      } catch (_) {}
      _queue = songs;
      _currentIndex = 0;
      _currentSong = songs.first;
      final durSec = _currentSong!.duration ?? 0;
      _position = Duration(seconds: pos.clamp(0, durSec > 0 ? durSec : pos));
      if (durSec > 0) _duration = Duration(seconds: durSec);
      notifyListeners();
      _saveQueueState();
      _updateAllServices();
      _updateAndroidAuto();
      await _prepareCurrentSong();
      if (!paused) {
        await play();
      }
      _brainPublishNow();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Handoff при старте (вызывается один раз из attachBrain):
  /// читаем resume, seek(position_sec), игра по external_id.
  /// paused=true — открыться без автоплея; stale/пусто — тихо остаёмся
  /// на локальной очереди. Best-effort, очередь не рвём.
  Future<void> _maybeResumeFromBrain() async {
    if (_resumeDone) return;
    _resumeDone = true;
    // M3: греем UUID заранее, чтобы первый publish уже шёл в свой слот.
    try {
      final id =
          await _ensureWaveDeviceId().timeout(const Duration(seconds: 3));
      try {
        _brain?.ownDeviceId = id;
      } catch (_) {}
    } catch (_) {}
    await applyServerResume();
  }
}
