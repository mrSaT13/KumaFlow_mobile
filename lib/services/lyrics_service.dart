import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/lyrics.dart';
import '../models/song.dart';
import 'subsonic_service.dart';

/// Unified lyrics service — fetches from LRCLIB and Subsonic, parses LRC,
/// and caches results in SharedPreferences.
class LyricsService {
  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: 'https://lrclib.net/api',
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  SubsonicService? _subsonic;
  SharedPreferences? _prefs;

  /// In-memory cache keyed by "artist::title".
  final Map<String, _CachedLyrics> _memoryCache = {};

  static const _cachePrefix = 'lyrics_cache_';
  static const _cacheExpiry = Duration(hours: 24);

  void configure(SubsonicService subsonic) {
    _subsonic = subsonic;
  }

  Future<SharedPreferences> _getPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Loads lyrics for [song]. Returns `null` when nothing is available.
  ///
  /// Strategy:
  /// 1. Check in-memory cache.
  /// 2. Check SharedPreferences disk cache.
  /// 3. Try Subsonic `getLyricsBySongId` (synced preferred).
  /// 4. Try LRCLIB API.
  /// 5. Persist to disk cache.
  Future<SyncedLyrics?> loadLyrics(Song song) async {
    final cacheKey = _cacheKey(song);

    // 1. Memory cache
    final mem = _memoryCache[cacheKey];
    if (mem != null && !mem.isExpired) return mem.lyrics;

    // 2. Disk cache
    final disk = await _readDiskCache(cacheKey);
    if (disk != null) {
      _memoryCache[cacheKey] = _CachedLyrics(disk);
      return disk;
    }

    // 3. Subsonic
    final subsonic = await _fetchFromSubsonic(song);
    if (subsonic != null) {
      await _writeDiskCache(cacheKey, subsonic);
      _memoryCache[cacheKey] = _CachedLyrics(subsonic);
      return subsonic;
    }

    // 4. LRCLIB
    final lrcLib = await _fetchFromLrcLib(song);
    if (lrcLib != null) {
      await _writeDiskCache(cacheKey, lrcLib);
      _memoryCache[cacheKey] = _CachedLyrics(lrcLib);
      return lrcLib;
    }

    return null;
  }

  /// Clears all cached lyrics.
  Future<void> clearCache() async {
    _memoryCache.clear();
    final prefs = await _getPrefs();
    final keys = prefs.getKeys().where((k) => k.startsWith(_cachePrefix));
    for (final key in keys) {
      await prefs.remove(key);
    }
  }

  // ---------------------------------------------------------------------------
  // Subsonic
  // ---------------------------------------------------------------------------

  Future<SyncedLyrics?> _fetchFromSubsonic(Song song) async {
    if (_subsonic == null) return null;
    try {
      final data = await _subsonic!.getLyricsBySongId(song.id);
      if (data == null) return null;

      final list = data['structuredLyrics'] as List?;
      if (list == null || list.isEmpty) return null;

      for (final entry in list) {
        final synced = entry['synced'] == true;
        final lines = entry['line'] as List?;
        if (lines == null || lines.isEmpty) continue;

        if (synced) {
          return _parseStructuredLyrics(lines);
        }
      }

      // Fallback: plain text from value field
      final plain = data['value'] as String?;
      if (plain != null && plain.isNotEmpty) {
        return SyncedLyrics.fromPlainText(plain);
      }

      return null;
    } catch (e) {
      debugPrint('[LyricsService] Subsonic error: $e');
      return null;
    }
  }

  SyncedLyrics _parseStructuredLyrics(List<dynamic> lines) {
    final result = <LyricLine>[];
    for (final entry in lines) {
      final startMs = entry['start'] as int? ?? 0;
      final text = entry['value'] as String? ?? '';
      if (text.isEmpty) continue;
      result.add(LyricLine(
        timestamp: Duration(milliseconds: startMs),
        text: text,
      ));
    }
    result.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return SyncedLyrics(lines: result);
  }

  // ---------------------------------------------------------------------------
  // LRCLIB
  // ---------------------------------------------------------------------------

  Future<SyncedLyrics?> _fetchFromLrcLib(Song song) async {
    try {
      final params = <String, dynamic>{
        'artist_name': song.artist,
        'track_name': song.title,
      };
      final durationSec = song.duration;
      if (durationSec != null && durationSec > 0) {
        params['duration'] = durationSec;
      }

      final response = await _dio.get('/get', queryParameters: params);
      if (response.statusCode != 200 || response.data == null) return null;

      final data = response.data as Map<String, dynamic>;

      // Synced LRC preferred
      final synced = data['syncedLyrics'] as String?;
      if (synced != null && synced.isNotEmpty) {
        return SyncedLyrics.fromLrc(synced);
      }

      // Plain lyrics fallback
      final plain = data['plainLyrics'] as String?;
      if (plain != null && plain.isNotEmpty) {
        return SyncedLyrics.fromPlainText(plain);
      }

      return null;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        debugPrint('[LyricsService] LRCLIB: no match for "${song.title}"');
      } else {
        debugPrint('[LyricsService] LRCLIB error: $e');
      }
      return null;
    } catch (e) {
      debugPrint('[LyricsService] LRCLIB unexpected: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // LRC parsing (standalone helper for raw LRC strings)
  // ---------------------------------------------------------------------------

  /// Parses a raw LRC string into [SyncedLyrics].
  static SyncedLyrics parseLrc(String lrcContent) {
    return SyncedLyrics.fromLrc(lrcContent);
  }

  /// Parses plain text lyrics.
  static SyncedLyrics parsePlainText(String text) {
    return SyncedLyrics.fromPlainText(text);
  }

  // ---------------------------------------------------------------------------
  // Disk cache
  // ---------------------------------------------------------------------------

  String _cacheKey(Song song) {
    final artist = (song.artist ?? '').toLowerCase().trim();
    final title = (song.title ?? '').toLowerCase().trim();
    return '$artist::$title';
  }

  Future<SyncedLyrics?> _readDiskCache(String key) async {
    try {
      final prefs = await _getPrefs();
      final raw = prefs.getString('$_cachePrefix$key');
      if (raw == null) return null;

      final data = jsonDecode(raw) as Map<String, dynamic>;
      final ts = data['cached_at'] as int? ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - ts;
      if (age > _cacheExpiry.inMilliseconds) {
        await prefs.remove('$_cachePrefix$key');
        return null;
      }

      final lrcContent = data['lrc'] as String?;
      if (lrcContent != null && lrcContent.isNotEmpty) {
        return SyncedLyrics.fromLrc(lrcContent);
      }

      final plainText = data['plain'] as String?;
      if (plainText != null && plainText.isNotEmpty) {
        return SyncedLyrics.fromPlainText(plainText);
      }

      return null;
    } catch (e) {
      debugPrint('[LyricsService] cache read error: $e');
      return null;
    }
  }

  Future<void> _writeDiskCache(String key, SyncedLyrics lyrics) async {
    try {
      final prefs = await _getPrefs();
      final data = <String, dynamic>{
        'cached_at': DateTime.now().millisecondsSinceEpoch,
      };

      // Rebuild LRC content from lines for storage
      final buf = StringBuffer();
      for (final line in lyrics.lines) {
        final ms = line.timestamp.inMilliseconds;
        final min = ms ~/ 60000;
        final sec = (ms ~/ 1000) % 60;
        final frac = ms % 1000;
        buf.writeln('[$min:${sec.toString().padLeft(2, '0')}.${frac.toString().padLeft(3, '0')}]${line.text}');
      }

      if (lyrics.lines.isNotEmpty && lyrics.lines.first.timestamp > Duration.zero) {
        data['lrc'] = buf.toString();
      } else {
        data['plain'] = lyrics.lines.map((l) => l.text).join('\n');
      }

      await prefs.setString('$_cachePrefix$key', jsonEncode(data));
    } catch (e) {
      debugPrint('[LyricsService] cache write error: $e');
    }
  }
}

class _CachedLyrics {
  final SyncedLyrics lyrics;
  final DateTime cachedAt;

  _CachedLyrics(this.lyrics) : cachedAt = DateTime.now();

  bool get isExpired =>
      DateTime.now().difference(cachedAt) > LyricsService._cacheExpiry;
}
