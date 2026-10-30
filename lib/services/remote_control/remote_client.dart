import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'remote_device.dart';

/// Состояние плеера десктопа (зеркало /remote.tsx PlayerState + очередь).
class RemotePlayerState {
  final bool isPlaying;
  final String title;
  final String artist;
  final String album;
  final String coverArt;
  final double duration;
  final double progress;
  final double volume;
  final bool isLiked;
  final bool isShuffle;
  final String repeatMode;
  final List<Map<String, dynamic>> queue;

  const RemotePlayerState({
    this.isPlaying = false,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.coverArt = '',
    this.duration = 0,
    this.progress = 0,
    this.volume = 50,
    this.isLiked = false,
    this.isShuffle = false,
    this.repeatMode = 'off',
    this.queue = const [],
  });

  factory RemotePlayerState.fromJson(Map<String, dynamic> j) {
    List<Map<String, dynamic>> q = const [];
    final rawQ = j['queue'];
    if (rawQ is List) {
      q = rawQ
          .whereType<Map>()
          .map(Map<String, dynamic>.from)
          .toList();
    }
    double toNum(dynamic v) =>
        v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
    return RemotePlayerState(
      isPlaying: j['isPlaying'] == true,
      title: (j['title'] ?? '').toString(),
      artist: (j['artist'] ?? '').toString(),
      album: (j['album'] ?? '').toString(),
      coverArt: (j['coverArt'] ?? '').toString(),
      duration: toNum(j['duration']),
      progress: toNum(j['progress']),
      volume: toNum(j['volume']),
      isLiked: j['isLiked'] == true,
      isShuffle: j['isShuffle'] == true,
      repeatMode: (j['repeatMode'] ?? 'off').toString(),
      queue: q,
    );
  }

  String get positionLabel {
    final s = progress.toInt().clamp(0, 99999);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  String get durationLabel {
    final s = duration.toInt().clamp(0, 99999);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

/// WebSocket-клиент к десктопу (`ws://host:port/remote-ws[?pin=]`).
/// Протокол remote-control.ts: `{event, data?}`; сервер шлёт
/// `{event:'state-update', state}`, `{message:'Connected...'}`.
/// Стрелка «назад» = disconnect() (сессия только пока открыта страница).
class RemoteClient extends ChangeNotifier {
  WebSocket? _ws;
  StreamSubscription? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;

  RemoteDevice? _device;
  String _pin = '';
  bool _connected = false;
  bool _connecting = false;
  String? _error;
  RemotePlayerState _state = const RemotePlayerState();
  bool _manualClose = false;
  // 4401 = сервер отверг PIN: авто-реконнект бессмысленен (будет тот же
  // отказ по кругу), ждём ручной ввод нового PIN через connect().
  bool _authFailed = false;

  RemoteDevice? get device => _device;
  bool get isConnected => _connected;
  bool get isConnecting => _connecting;
  String? get error => _error;
  RemotePlayerState get state => _state;
  String get pin => _pin;
  bool get authFailed => _authFailed;

  /// Закрытие сокета с дедлайном: close() полумёртвого сокета может висеть
  /// вечно и тогда следующий connect() висит вместе с ним (вечный спиннер).
  Future<void> _closeSocket() async {
    final ws = _ws;
    _ws = null;
    if (ws == null) return;
    try {
      await ws.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      try {
        // ignore: avoid_dynamic_calls
        (ws as dynamic).destroy();
      } catch (_) {}
    }
  }

  Future<bool> connect(RemoteDevice device, {String pin = ''}) async {
    if (_opening) return false;
    _opening = true;
    try {
      // Ручной коннект гасит фоновый автопереподключ (иначе два коннекта
      // рвут друг друга, а зомби-сокеты вешают close() навсегда).
      _manualClose = true;
      _reconnectTimer?.cancel();
      // cancel() зомби-подписки может не завершиться никогда → вечный
      // спиннер «Открываем пульт…» (подозрение 13.10.2026). Ограничиваем
      // 2с: сокет всё равно жёстко закроем ниже в _closeSocket().
      try {
        await _sub?.cancel().timeout(const Duration(seconds: 2));
      } catch (_) {}
      _sub = null;
      await _closeSocket();
      // Ручной коннект держим _manualClose=true до конца _open(): при ошибке
      // _open() НЕ должен планировать фоновый ретрай (12.10.2026 — зомби-_open
      // из _scheduleReconnect дрался с диалогом подключения и жил вечно).
      // Авто-переподключ разрешаем только после успеха (для будущих обрывов).
      _manualClose = true;
      _device = device;
      _pin = pin;
      _authFailed = false;
      _connecting = true;
      _error = null;
      _reconnectAttempt = 0;
      notifyListeners();
      final ok = await _open();
      if (ok) _manualClose = false;
      _connecting = false;
      notifyListeners();
      return ok;
    } finally {
      _opening = false;
    }
  }

  bool _opening = false;
  Completer<bool>? _hello;

  void _failHello(String e) {
    try {
      if (_hello != null && !_hello!.isCompleted) _hello!.complete(false);
    } catch (_) {}
    // 'pin' = сервер отбил 4401 (обработаем ниже в _open).
    if (e == 'pin') _error = 'pin';
  }

  Future<bool> _open() async {
    final d = _device;
    if (d == null) return false;
    _hello = Completer<bool>();
    try {
      final ws = await WebSocket.connect(d.wsUrl(pin: _pin))
          .timeout(const Duration(seconds: 8));
      _ws = ws;
      _sub = ws.listen(_onMessage,
          onError: (_) {
            _failHello('Связь оборвалась');
            _onDrop();
          },
          onDone: () {
            // Сервер без верного PIN режет сразу кодом 4401 — handshake при
            // этом УЖЕ прошёл, поэтому верить ему нельзя, ждём 'connected'.
            if (ws.closeCode == 4401) {
              _failHello('pin');
            } else {
              _failHello('Связь закрыта');
            }
            _onDrop();
          });
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        _send('ping');
      });
      _send('get-state');
      _send('get-queue');
      // Ждём настоящее 'connected' от сервера (до 4с).
      var ok = false;
      try {
        ok = await _hello!.future.timeout(const Duration(seconds: 4));
      } catch (_) {
        ok = false;
      } finally {
        _hello = null;
      }
      if (ok && _ws != null && _ws!.closeCode == null) {
        _connected = true;
        _error = null;
        _authFailed = false;
        _reconnectAttempt = 0;
        notifyListeners();
        return true;
      }
      // Сервер не подтвердил: неверный PIN или молчит.
      if (_ws?.closeCode == 4401 || _error == 'pin') {
        _error = 'Неверный PIN — посмотри код в настройках пульта на ПК';
        _authFailed = true;
      } else if (_error == null || _error!.isEmpty) {
        _error = 'ПК не подтвердил подключение (таймаут)';
      }
      _connected = false;
      await _closeSocket();
      _scheduleReconnect();
      notifyListeners();
      return false;
    } catch (e) {
      _connected = false;
      await _closeSocket();
      // 401/403 или обрыв на handshake при неверном PIN — показываем честно.
      _error = '$e';
      _scheduleReconnect();
      notifyListeners();
      return false;
    } finally {
      _hello = null;
    }
  }

  void _onDrop() {
    if (_manualClose) return;
    _connected = false;
    // 4401 = неверный PIN (remote-server.ts isPinAuthorized).
    try {
      if (_ws?.closeCode == 4401) {
        _error = 'Неверный PIN — посмотри код в настройках пульта на ПК';
        _authFailed = true;
      }
    } catch (_) {}
    try {
      _sub?.cancel();
    } catch (_) {}
    _sub = null;
    _pingTimer?.cancel();
    _scheduleReconnect();
    notifyListeners();
  }

  void _scheduleReconnect() {
    if (_manualClose || _device == null) return;
    // PIN отвергнут — долбить тот же PIN по кругу нельзя, ждём ручной ввод.
    if (_authFailed) return;
    _reconnectTimer?.cancel();
    _reconnectAttempt++;
    final wait = Duration(
        seconds: (_reconnectAttempt * 2).clamp(2, 30).toInt());
    _reconnectTimer = Timer(wait, () async {
      if (_manualClose || _connected) return;
      await _open();
      notifyListeners();
    });
  }

  void _onMessage(dynamic data) {
    try {
      final j = jsonDecode(data.toString());
      if (j is! Map) return;
      final m = Map<String, dynamic>.from(j);
      final event = (m['event'] ?? '').toString();
      if (event == 'connected') {
        // Сервер подтвердил сессию (с верным PIN) — handshake засчитан.
        try {
          if (_hello != null && !_hello!.isCompleted) {
            _hello!.complete(true);
          }
        } catch (_) {}
        return;
      }
      if (event == 'state-update' && (m['state'] is Map || m['data'] is Map)) {
        // origin/main: {event, state:{...}}; 1.6.6: {event, data:{...}}.
        final raw =
            (m['state'] is Map ? m['state'] : m['data']) as Map;
        _state = RemotePlayerState.fromJson(
            Map<String, dynamic>.from(raw));
        notifyListeners();
      } else if (event == 'queue-data' || event == 'queue-update') {
        // origin/main: {event:'queue-data', queue:[...]};
        // 1.6.6: {event:'queue-update', data:[...]}.
        final raw = m['queue'] ?? m['data'];
        if (raw is List) {
          final q = raw
              .whereType<Map>()
              .map(Map<String, dynamic>.from)
              .toList();
          _state = RemotePlayerState(
            isPlaying: _state.isPlaying,
            title: _state.title,
            artist: _state.artist,
            album: _state.album,
            coverArt: _state.coverArt,
            duration: _state.duration,
            progress: _state.progress,
            volume: _state.volume,
            isLiked: _state.isLiked,
            isShuffle: _state.isShuffle,
            repeatMode: _state.repeatMode,
            queue: q,
          );
          notifyListeners();
        }
      }
      // {message:'Connected...'} — просто знак живого соединения.
    } catch (e) {
      debugPrint('[RemoteClient] bad message: $e');
    }
  }

  void _send(String event, [Map<String, dynamic>? data]) {
    try {
      final ws = _ws;
      if (ws == null || ws.closeCode != null) return;
      ws.add(jsonEncode({
        'event': event,
        if (data != null) 'data': data,
      }));
    } catch (_) {}
  }

  // ---------- транспорт (зеркало /remote.tsx) ----------
  void toggle() => _send('toggle');
  void play() => _send('play');
  void pause() => _send('pause');
  void next() => _send('next');
  void previous() => _send('previous');
  void seek(double positionSec) =>
      _send('seek', {'position': positionSec});
  void setVolume(double v) =>
      _send('volume', {'value': v.clamp(0, 100)});
  void toggleLike() => _send(_state.isLiked ? 'dislike' : 'like');
  void like() => _send('like');
  void dislike() => _send('dislike');
  void toggleShuffle() => _send('shuffle');
  void cycleRepeat() => _send('repeat');
  void refresh() {
    _send('get-state');
    _send('get-queue');
  }

  Future<void> disconnect() async {
    _manualClose = true;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    await _closeSocket();
    _connected = false;
    _connecting = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _manualClose = true;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    try {
      _sub?.cancel();
    } catch (_) {}
    try {
      _ws?.close();
    } catch (_) {}
    super.dispose();
  }
}
