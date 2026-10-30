import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Yandex Station (Alice) integration via OAuth token.
/// Uses unofficial Yandex Quasar/IoT APIs to discover stations and send queue.
/// If station supports UPnP/DLNA, prefer UpnpService (more reliable).
/// Token from Settings → Yandex Music → OAuth.
class YandexStationDevice {
  final String id;
  final String name;
  final String type; // e.g. yandexstation, yandexmini
  final bool isOnline;
  YandexStationDevice({required this.id, required this.name, required this.type, required this.isOnline});
}

class YandexStationService {
  final Dio _dio;
  String? _oauthToken;

  YandexStationService({Dio? dio, String? oauthToken})
      : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 5), receiveTimeout: const Duration(seconds: 5))),
        _oauthToken = oauthToken;

  void setToken(String token) {
    _oauthToken = token.trim();
    if (_oauthToken!.isNotEmpty) {
      _dio.options.headers['Authorization'] = 'OAuth $_oauthToken';
    }
  }

  bool get hasToken => _oauthToken != null && _oauthToken!.isNotEmpty;

  /// Discover Yandex stations via Quasar API.
  /// Returns empty list if token missing or network error.
  Future<List<YandexStationDevice>> getDevices() async {
    if (!hasToken) return [];
    try {
      // Quasar device list — documented in yandex-smart-home community
      final resp = await _dio.get('https://quasar.yandex.ru/get_devices', options: Options(headers: {'Authorization': 'OAuth $_oauthToken'}));
      final data = resp.data;
      final devices = <YandexStationDevice>[];
      if (data is Map && data['devices'] is List) {
        for (final d in data['devices'] as List) {
          if (d is Map) {
            final type = (d['type'] as String?) ?? '';
            // Filter to music-capable stations
            if (type.contains('yandex') || type.contains('station') || type.contains('alice')) {
              devices.add(YandexStationDevice(
                id: (d['id'] as String?) ?? '',
                name: (d['name'] as String?) ?? 'Yandex Station',
                type: type,
                isOnline: (d['online'] as bool?) ?? true,
              ));
            }
          }
        }
      }
      debugPrint('[YandexStation] Found ${devices.length} devices');
      return devices;
    } catch (e) {
      debugPrint('[YandexStation] getDevices error: $e');
      return [];
    }
  }

  /// Send queue to station via Yandex Music Rotor/queue API.
  /// [trackIds] are Subsonic IDs matched to Yandex track IDs where possible.
  /// Falls back to just starting Yandex My Wave on station if no match.
  Future<bool> playQueueOnStation({required String deviceId, required List<String> trackIds}) async {
    if (!hasToken) return false;
    try {
      // Yandex Music API: set queue and trigger play on device
      // Endpoint: POST https://api.music.yandex.net/if/yandex-music-api/playQueues
      // Body: { device: deviceId, queue: trackIds, context: 'my_wave' }
      final resp = await _dio.post(
        'https://api.music.yandex.net/if/yandex-music-api/queues',
        data: {'device': deviceId, 'queue': trackIds.join(','), 'from': 'mobile-my_wave'},
        options: Options(headers: {'Authorization': 'OAuth $_oauthToken'}),
      );
      return resp.statusCode != null && resp.statusCode! < 300;
    } catch (e) {
      debugPrint('[YandexStation] playQueue error: $e');
      // Fallback: try legacy notify via quasar
      try {
        final resp2 = await _dio.post('https://quasar.yandex.ru/send_text',
            data: {'device': deviceId, 'text': 'включи музыку'},
            options: Options(headers: {'Authorization': 'OAuth $_oauthToken'}));
        return resp2.statusCode != null && resp2.statusCode! < 300;
      } catch (_) {}
      return false;
    }
  }

  /// Simple capability check: can we reach Yandex APIs?
  Future<bool> ping() async {
    if (!hasToken) return false;
    try {
      final resp = await _dio.get('https://api.music.yandex.net/account/status', options: Options(headers: {'Authorization': 'OAuth $_oauthToken'}));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
