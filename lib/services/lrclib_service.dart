import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

/// Service that searches LRCLIB (https://lrclib.net) for lyrics when the
/// Subsonic / Navidrome server does not provide them.
class LrcLibService {
  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: 'https://lrclib.net/api',
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      headers: {
        'Lrclib-Client': 'KumaFlow/3.4.0 (https://kumaflow.app)',
        'User-Agent': 'KumaFlow/3.4.0',
      },
    ),
  );

  /// Searches LRCLIB for a track matching [artist] and [title].
  ///
  /// Порт из `C:\aonsoku-main\aonsoku-main\KumaFlow\src\service\lyrics.ts:134`
  /// - `album_name` + `isLms artist.split(',')[0]` как в десктопе/Chora
  /// - без токена, бесплатно
  Future<Map<String, dynamic>?> searchLyrics({
    required String artist,
    required String title,
    String? album,
    int? durationSeconds,
  }) async {
    // LMS артисты склеены "Cartoon, Jeja, ..." — как в desktop isLms ? split(',')[0]
    String normArtist = artist;
    if (artist.contains(',')) {
      normArtist = artist.split(',').first.trim();
    }

    Future<Map<String, dynamic>?> tryFetch({int? dur, String? alb}) async {
      final response = await _dio.get(
        '/get',
        queryParameters: {
          'artist_name': normArtist,
          'track_name': title,
          if (dur != null) 'duration': dur,
          if (alb != null && alb.isNotEmpty) 'album_name': alb,
        },
      );
      if (response.statusCode != 200 || response.data == null) return null;
      final data = response.data as Map<String, dynamic>;
      final synced = data['syncedLyrics'] as String?;
      if (synced != null && synced.isNotEmpty) {
        return _buildStructuredLyrics(synced);
      }
      final plain = data['plainLyrics'] as String?;
      if (plain != null && plain.isNotEmpty) {
        return {'value': plain};
      }
      return null;
    }

    try {
      // Как в desktop: сначала с duration+album, потом без duration (расширенный поиск)
      if (durationSeconds != null) {
        try {
          final withDur = await tryFetch(dur: durationSeconds, alb: album);
          if (withDur != null) return withDur;
        } on DioException catch (e) {
          if (e.response?.statusCode != 404) {
            debugPrint('[LRCLIB] Error with duration: $e');
            rethrow;
          }
          debugPrint('[LRCLIB] 404 with duration $durationSeconds, retry without duration for "$title"');
        }
      }
      // Ретрай без duration, с album
      final noDurWithAlbum = await tryFetch(dur: null, alb: album);
      if (noDurWithAlbum != null) return noDurWithAlbum;
      // Последний шанс: без album тоже
      if (album != null && album.isNotEmpty) {
        return await tryFetch(dur: null, alb: null);
      }
      return noDurWithAlbum;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        debugPrint('[LRCLIB] No lyrics found for "$title" by "$artist"');
      } else {
        debugPrint('[LRCLIB] Error: $e');
      }
      return null;
    } catch (e) {
      debugPrint('[LRCLIB] Unexpected error: $e');
      return null;
    }
  }

  /// Converts an LRC string into the Subsonic structured-lyrics format.
  Map<String, dynamic> _buildStructuredLyrics(String lrcText) {
    final lines = <Map<String, dynamic>>[];
    for (final raw in LineSplitter.split(lrcText)) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      // Parse [mm:ss.xx] or [mm:ss.xxx] tags
      final match = RegExp(r'\[(\d+):(\d{2})\.(\d{2,3})\](.*)').firstMatch(line);
      if (match == null) continue;

      final minutes = int.tryParse(match.group(1) ?? '');
      final seconds = int.tryParse(match.group(2) ?? '');
      final fracStr = match.group(3);
      final text = match.group(4)?.trim() ?? '';
      if (minutes == null || seconds == null || fracStr == null) continue;
      final fracRaw = int.tryParse(fracStr);
      if (fracRaw == null) continue;
      if (text.isEmpty) continue;

      // Normalise fractional seconds to milliseconds
      final fracMs = fracStr.length == 2
          ? fracRaw * 10
          : fracRaw;

      final startMs =
          (minutes * 60 + seconds) * 1000 + fracMs.clamp(0, 999);

      lines.add({
        'start': startMs,
        'value': text,
      });
    }

    if (lines.isEmpty) {
      // No valid LRC lines — return as plain text instead
      return {'value': lrcText};
    }

    return {
      'structuredLyrics': [
        {
          'synced': true,
          'line': lines,
        },
      ],
    };
  }
}
