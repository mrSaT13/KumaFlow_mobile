import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Модель одного scrobble-записи
class ScrobbleEntry {
  final String trackId;
  final String title;
  final String artist;
  final String album;
  final int duration; // длительность в секундах
  final DateTime timestamp;
  bool isNowPlaying;
  bool isSent;
  int retryCount;

  ScrobbleEntry({
    required this.trackId,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    DateTime? timestamp,
    this.isNowPlaying = false,
    this.isSent = false,
    this.retryCount = 0,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'trackId': trackId,
        'title': title,
        'artist': artist,
        'album': album,
        'duration': duration,
        'timestamp': timestamp.toIso8601String(),
        'isNowPlaying': isNowPlaying,
        'isSent': isSent,
        'retryCount': retryCount,
      };

  factory ScrobbleEntry.fromJson(Map<String, dynamic> json) {
    DateTime ts;
    try {
      ts = DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
    } catch (_) {
      ts = DateTime.fromMillisecondsSinceEpoch(0);
    }
    return ScrobbleEntry(
      trackId: json['trackId'] as String? ?? '',
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      album: json['album'] as String? ?? '',
      duration: (json['duration'] as num?)?.toInt() ?? 0,
      timestamp: ts,
      isNowPlaying: json['isNowPlaying'] as bool? ?? false,
      isSent: json['isSent'] as bool? ?? false,
      retryCount: json['retryCount'] as int? ?? 0,
    );
  }
}

/// Сервис scrobble для Subsonic-compatible серверов
/// Отправляет now-playing и completed уведомления
class ScrobbleService extends ChangeNotifier {
  ScrobbleService({
    required this.baseUrl,
    required this.subsonicUser,
    required this.subsonicToken,
    this.isEnabled = true,
    this.maxRetries = 3,
    this.retryDelaySeconds = 30,
  });

  /// Базовый URL сервера
  final String baseUrl;

  /// Имя пользователя
  final String subsonicUser;

  /// Токен аутентификации (pass или token)
  final String subsonicToken;

  /// Включена ли отправка scrobble
  bool isEnabled;

  /// Максимальное количество повторных попыток
  final int maxRetries;

  /// Задержка между повторами (секунды)
  final int retryDelaySeconds;

  // Очередь неотправленных scrobbles
  final List<ScrobbleEntry> _queue = [];
  List<ScrobbleEntry> get queue => List.unmodifiable(_queue);

  // Текущий воспроизводимый трек
  ScrobbleEntry? _currentTrack;
  ScrobbleEntry? get currentTrack => _currentTrack;

  // Состояние
  bool _isSending = false;
  bool get isSending => _isSending;

  String? _lastError;
  String? get lastError => _lastError;

  Timer? _retryTimer;

  /// Инициализация - загрузка очереди из памяти
  Future<void> init() async {
    await _loadQueue();
    _startRetryTimer();
  }

  /// Загрузка очереди из SharedPreferences
  Future<void> _loadQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final queueJson = prefs.getString('scrobble_queue');

    if (queueJson != null) {
      final List<dynamic> decoded = jsonDecode(queueJson);
      _queue.clear();
      for (final item in decoded) {
        final entry = ScrobbleEntry.fromJson(item as Map<String, dynamic>);
        if (!entry.isSent) {
          _queue.add(entry);
        }
      }
      notifyListeners();
    }
  }

  /// Сохранение очереди в SharedPreferences
  Future<void> _saveQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final queueJson = jsonEncode(_queue.map((e) => e.toJson()).toList());
    await prefs.setString('scrobble_queue', queueJson);
  }

  /// Запуск таймера повторных попыток
  void _startRetryTimer() {
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(
      Duration(seconds: retryDelaySeconds),
      (_) => _processQueue(),
    );
  }

  /// Уведомление о воспроизведении трека (now-playing)
  Future<void> nowPlaying({
    required String trackId,
    required String title,
    required String artist,
    required String album,
    required int duration,
  }) async {
    if (!isEnabled) return;

    // Отменяем предыдущий now-playing
    if (_currentTrack != null && !_currentTrack!.isSent) {
      _currentTrack = null;
    }

    final entry = ScrobbleEntry(
      trackId: trackId,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      isNowPlaying: true,
    );

    _currentTrack = entry;
    notifyListeners();

    await _sendScrobble(entry, isNowPlaying: true);
  }

  /// Отправка завершённого scrobble
  Future<void> scrobble({
    required String trackId,
    required String title,
    required String artist,
    required String album,
    required int duration,
  }) async {
    if (!isEnabled) return;

    final entry = ScrobbleEntry(
      trackId: trackId,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
    );

    // Добавляем в очередь
    _queue.add(entry);
    await _saveQueue();
    notifyListeners();

    // Пытаемся отправить сразу
    await _processQueue();

    _currentTrack = null;
    notifyListeners();
  }

  /// Отправка scrobble на сервер
  Future<bool> _sendScrobble(
    ScrobbleEntry entry, {
    bool isNowPlaying = false,
  }) async {
    final timestamp = (entry.timestamp.millisecondsSinceEpoch ~/ 1000).toString();

    final params = {
      'id': entry.trackId,
      'submission': isNowPlaying ? 'false' : 'true',
      'u': subsonicUser,
      't': subsonicToken,
      'v': '1.16.1',
      'c': 'KumaFlow',
    };

    if (!isNowPlaying) {
      params['submission'] = 'true';
    }

    try {
      final uri = Uri.parse('$baseUrl/rest/scrobble').replace(
        queryParameters: params,
      );

      final response = await http.get(uri).timeout(
            const Duration(seconds: 10),
          );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        if (body['subsonic-response']?['status'] == 'ok') {
          if (!isNowPlaying) {
            entry.isSent = true;
            await _saveQueue();
          }
          return true;
        }
      }

      _lastError = 'Ошибка сервера: ${response.statusCode}';
      notifyListeners();
      return false;
    } catch (e) {
      _lastError = 'Ошибка сети: $e';
      notifyListeners();
      return false;
    }
  }

  /// Обработка очереди неотправленных scrobbles
  Future<void> _processQueue() async {
    if (_isSending || _queue.isEmpty || !isEnabled) return;

    _isSending = true;
    notifyListeners();

    final pendingEntries =
        _queue.where((e) => !e.isSent && e.retryCount < maxRetries).toList();

    for (final entry in pendingEntries) {
      final success = await _sendScrobble(entry);
      if (!success) {
        entry.retryCount++;
        if (entry.retryCount >= maxRetries) {
          _queue.remove(entry);
        }
      }
    }

    // Удаляем отправленные
    _queue.removeWhere((e) => e.isSent);

    await _saveQueue();
    _isSending = false;
    notifyListeners();
  }

  /// Включение/отключение scrobble
  void setEnabled(bool value) {
    isEnabled = value;
    notifyListeners();
  }

  /// Очистка очереди
  Future<void> clearQueue() async {
    _queue.clear();
    await _saveQueue();
    notifyListeners();
  }

  /// Ручная отправка всей очереди
  Future<void> sendAll() async {
    await _processQueue();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }
}

/// Провайдер для доступа к ScrobbleService из виджетов
class ScrobbleServiceProvider extends StatelessWidget {
  const ScrobbleServiceProvider({
    super.key,
    required this.child,
    required this.baseUrl,
    required this.subsonicUser,
    required this.subsonicToken,
    this.isEnabled = true,
    this.maxRetries = 3,
    this.retryDelaySeconds = 30,
  });

  final Widget child;
  final String baseUrl;
  final String subsonicUser;
  final String subsonicToken;
  final bool isEnabled;
  final int maxRetries;
  final int retryDelaySeconds;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ScrobbleService>(
      create: (_) => ScrobbleService(
        baseUrl: baseUrl,
        subsonicUser: subsonicUser,
        subsonicToken: subsonicToken,
        isEnabled: isEnabled,
        maxRetries: maxRetries,
        retryDelaySeconds: retryDelaySeconds,
      )..init(),
      child: child,
    );
  }
}
