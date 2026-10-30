import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/song.dart';

/// Сервис интеграции с ListenBrainz API.
/// Поддерживает токен-аутентификацию, отправку прослушиваний и проверку токена.
class ListenBrainzService {
  static final ListenBrainzService _instance = ListenBrainzService._internal();
  factory ListenBrainzService() => _instance;
  ListenBrainzService._internal();

  static const String _baseUrl = 'https://api.listenbrainz.org/1';
  String? _userToken;
  bool _isEnabled = false;

  String? get userToken => _userToken;
  bool get isEnabled => _isEnabled;

  /// Установить пользовательский токен.
  void setToken(String token) {
    _userToken = token.trim();
    _isEnabled = _userToken != null && _userToken!.isNotEmpty;
  }

  /// Убрать токен (отключение).
  void clearToken() {
    _userToken = null;
    _isEnabled = false;
  }

  /// Проверить токен — возвращает имя пользователя или null.
  Future<String?> validateToken() async {
    if (_userToken == null || _userToken!.isEmpty) return null;

    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/user/validate'),
        headers: {
          'Authorization': 'Token $_userToken',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['username']?.toString();
      }
      return null;
    } catch (e) {
      debugPrint('ListenBrainz: ошибка проверки токена: $e');
      return null;
    }
  }

  /// Отправить одно прослушивание (submit-listens).
  Future<bool> submitListen({
    required Song song,
    required DateTime timestamp,
  }) async {
    if (!isEnabled || _userToken == null) return false;

    final payload = {
      'listen_type': 'single',
      'payload': [
        {
          'listened_at': timestamp.millisecondsSinceEpoch ~/ 1000,
          'track_metadata': {
            'track_name': song.title,
            'artist_name': song.artist ?? 'Неизвестный',
            if (song.album != null)
              'release_name': song.album,
            'additional_info': {
              if (song.genre != null) 'tags': [song.genre],
              if (song.duration != null) 'duration': song.duration,
              'media_player': 'KumaFlow',
              'submission_client': 'KumaFlow Flutter',
            },
          },
        },
      ],
    };

    return _sendRequest('submit-listens', payload);
  }

  /// Отправить пакет прослушиваний.
  Future<bool> submitMultiple(ListensBatch batch) async {
    if (!isEnabled || _userToken == null) return false;

    final listens = batch.items.map((item) {
      return {
        'listened_at': item.timestamp.millisecondsSinceEpoch ~/ 1000,
        'track_metadata': {
          'track_name': item.song.title,
          'artist_name': item.song.artist ?? 'Неизвестный',
          if (item.song.album != null)
            'release_name': item.song.album,
          'additional_info': {
            if (item.song.genre != null) 'tags': [item.song.genre],
            if (item.song.duration != null) 'duration': item.song.duration,
            'media_player': 'KumaFlow',
            'submission_client': 'KumaFlow Flutter',
          },
        },
      };
    }).toList();

    final payload = {
      'listen_type': 'import',
      'payload': listens,
    };

    return _sendRequest('submit-listens', payload);
  }

  Future<bool> _sendRequest(String endpoint, Map<String, dynamic> body) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/$endpoint'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Token $_userToken',
        },
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 10));

      final success = response.statusCode == 200 || response.statusCode == 201;
      if (!success) {
        debugPrint(
            'ListenBrainz: ошибка отправки ($endpoint): '
            '${response.statusCode} — ${response.body}');
      }
      return success;
    } catch (e) {
      debugPrint('ListenBrainz: сетевая ошибка ($endpoint): $e');
      return false;
    }
  }
}

/// Элемент пакета прослушиваний для пакетной отправки.
class ListenItem {
  final Song song;
  final DateTime timestamp;

  const ListenItem({required this.song, required this.timestamp});
}

/// Пакет прослушиваний.
class ListensBatch {
  final List<ListenItem> items;

  const ListensBatch(this.items);

  bool get isEmpty => items.isEmpty;
  int get length => items.length;
}
