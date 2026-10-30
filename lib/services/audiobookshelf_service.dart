import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';

class AudiobookshelfService {
  static const _kEnabled = 'abs_enabled';
  static const _kUrl = 'abs_url';
  static const _kToken = 'abs_token';

  static final AudiobookshelfService _instance = AudiobookshelfService._internal();
  factory AudiobookshelfService() => _instance;
  AudiobookshelfService._internal();

  final ValueNotifier<bool> enabledNotifier = ValueNotifier(false);
  SharedPreferences? _prefs;

  bool get enabled => enabledNotifier.value;
  Future<void> initialize() async {
    _prefs ??= await SharedPreferences.getInstance();
    enabledNotifier.value = _prefs!.getBool(_kEnabled) ?? false;
  }

  Future<void> setEnabled(bool v) async {
    await initialize();
    await _prefs!.setBool(_kEnabled, v);
    enabledNotifier.value = v;
  }

  Future<void> setUrl(String url) async {
    await initialize();
    await _prefs!.setString(_kUrl, url);
  }
  String getUrl() => _prefs?.getString(_kUrl) ?? '';

  Future<void> setToken(String t) async {
    await initialize();
    await _prefs!.setString(_kToken, t);
  }
  String getToken() => _prefs?.getString(_kToken) ?? '';

  bool get isConfigured => enabled && getUrl().isNotEmpty && getToken().isNotEmpty;

  String getCoverUrl(String itemId, {int width = 400}) {
    if (!isConfigured || itemId.isEmpty) return '';
    final base = getUrl().replaceAll(RegExp(r'/+$'), '');
    final token = getToken();
    // Support both header and token query for CachedNetworkImage
    return '$base/api/items/$itemId/cover?width=$width&token=$token';
  }

  // Direct cover URL with auth header (for CachedNetworkImage httpHeaders)
  Map<String, String> get authHeaders => {'Authorization': 'Bearer ${getToken()}'};

  /// Extract chapters from expanded item: media.chapters or media.audioFiles[].chapters (lissen fallback)
  List<Map<String, dynamic>> extractChapters(Map<String, dynamic> item) {
    return extractBookChapters(item).map((c) => c.toJson()).toList();
  }

  /// Typed version — returns BookChapter list (Lissen PlayingChapter)
  List<BookChapter> extractBookChapters(Map<String, dynamic> item) {
    final media = item['media'] as Map<String, dynamic>?;
    if (media == null) return [];
    // Prefer media.chapters (top-level)
    final chapters = media['chapters'] as List?;
    if (chapters != null && chapters.isNotEmpty) {
      return chapters.map((e) => BookChapter.fromJson((e as Map).cast<String, dynamic>())).toList();
    }
    // Fallback: audioFiles -> chapters (demo Pi case: audioFiles[0].chapters)
    final audioFiles = media['audioFiles'] as List?;
    if (audioFiles != null && audioFiles.isNotEmpty) {
      final all = <Map<String, dynamic>>[];
      for (final f in audioFiles) {
        final fm = f as Map<String, dynamic>;
        final fChaps = fm['chapters'] as List?;
        if (fChaps != null && fChaps.isNotEmpty) {
          all.addAll(fChaps.cast<Map<String, dynamic>>());
        }
      }
      if (all.isNotEmpty) return all.map((e) => BookChapter.fromJson(e)).toList();
      // If no embedded chapters, treat each file as a chapter (BookResponseConverter.filesAsChapters)
      if (audioFiles.length > 1) {
        double acc = 0;
        final filesAsChaps = <BookChapter>[];
        for (final f in audioFiles) {
          final fm = f as Map<String, dynamic>;
          final dur = (fm['duration'] as num?)?.toDouble() ?? 0;
          final fname = fm['metadata']?['filename'] as String? ?? fm['ino']?.toString() ?? 'Track';
          filesAsChaps.add(BookChapter(id: fm['ino']?.toString() ?? acc.toString(), title: fname, start: acc, end: acc + dur, duration: dur));
          acc += dur;
        }
        return filesAsChaps;
      }
    }
    return [];
  }

  /// Get audioFiles raw list
  List<Map<String, dynamic>> getAudioFiles(Map<String, dynamic> item) {
    final media = item['media'] as Map<String, dynamic>?;
    if (media == null) return [];
    final af = media['audioFiles'] as List?;
    if (af == null) return [];
    return af.cast<Map<String, dynamic>>();
  }

  /// Build MediaProgress from item + progress data (Lissen mergeLocalItemProgress)
  MediaProgress? extractMediaProgress(Map<String, dynamic> item, {double? totalDuration}) {
    final dur = totalDuration ?? extractTotalDuration(item);
    // Try embedded userMediaProgress first
    final embedded = item['userMediaProgress'] as Map<String, dynamic>?;
    if (embedded != null) {
      return MediaProgress.fromJson(embedded, totalDuration: dur);
    }
    final prog = item['progress'] as Map<String, dynamic>?;
    if (prog != null) return MediaProgress.fromJson(prog, totalDuration: dur);
    return null;
  }

  double extractTotalDuration(Map<String, dynamic> item) {
    final media = item['media'] as Map<String, dynamic>?;
    if (media == null) return 0;
    return (media['duration'] as num?)?.toDouble() ?? 0;
  }

  Future<Map<String, dynamic>?> fetchBookDetail(String itemId) async {
    if (!isConfigured) return null;
    final base = getUrl().replaceAll(RegExp(r'/+$'), '');
    final url = Uri.parse('$base/api/items/$itemId?expanded=1&include=progress');
    final resp = await http.get(url, headers: authHeaders).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> fetchContinueListening() async {
    if (!isConfigured) return [];
    final base = getUrl().replaceAll(RegExp(r'/+$'), '');
    final url = Uri.parse('$base/api/me/items-in-progress');
    final resp = await http.get(url, headers: authHeaders).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return [];
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (data['items'] ?? data['libraryItems'] ?? data['results'] ?? []) as List;
    final list = items.cast<Map<String, dynamic>>();
    if (list.isNotEmpty) return list;
    // Fallback: some ABS versions nest under 'data'
    if (data['data'] is List) return (data['data'] as List).cast<Map<String, dynamic>>();
    return list;
  }

  /// Fallback for Continue Listening: if items-in-progress empty, filter library items by progress locally
  Future<List<Map<String, dynamic>>> fetchContinueListeningWithFallback() async {
    final primary = await fetchContinueListening();
    if (primary.isNotEmpty) return primary;
    // Fallback: fetch library books and filter by not finished & started
    try {
      final books = await fetchBooks();
      final filtered = <Map<String, dynamic>>[];
      for (final b in books) {
        final mp = extractMediaProgress(b, totalDuration: extractTotalDuration(b));
        double prog = mp?.progress ?? (b['userMediaProgress']?['progress'] as num?)?.toDouble() ?? 0;
        bool isFin = mp?.isFinished ?? (b['userMediaProgress']?['isFinished'] as bool? ?? prog >= 0.99);
        if (prog > 0 && !isFin) filtered.add(b);
      }
      // Sort by lastUpdate desc
      filtered.sort((a, b) {
        final la = (a['userMediaProgress']?['lastUpdate'] as num?)?.toInt() ?? 0;
        final lb = (b['userMediaProgress']?['lastUpdate'] as num?)?.toInt() ?? 0;
        return lb.compareTo(la);
      });
      return filtered.take(20).toList();
    } catch (_) {
      return primary;
    }
  }

  Future<Map<String, dynamic>?> fetchProgressRaw(String itemId) async {
    if (!isConfigured) return null;
    final base = getUrl().replaceAll(RegExp(r'/+$'), '');
    final url = Uri.parse('$base/api/me/progress/$itemId');
    final resp = await http.get(url, headers: authHeaders).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<double> fetchProgress(String itemId) async {
    final data = await fetchProgressRaw(itemId);
    if (data == null) return 0;
    // lissen MediaProgressResponse: currentTime / progress
    if (data.containsKey('currentTime')) return (data['currentTime'] as num?)?.toDouble() ?? 0;
    if (data.containsKey('progress')) {
      final p = (data['progress'] as num).toDouble();
      // if progress is 0-1, need duration to convert; return normalized 0-1 for now, caller can handle
      if (p <= 1.0) return p; // normalized — caller should multiply by duration
      return p;
    }
    return 0;
  }

  /// Typed progress fetch — returns MediaProgress with isFinished (Lissen logic)
  Future<MediaProgress?> fetchMediaProgress(String itemId, {double totalDuration = 0}) async {
    final raw = await fetchProgressRaw(itemId);
    if (raw == null) return null;
    // raw may be {currentTime, progress, isFinished, duration, lastUpdate}
    return MediaProgress.fromJson(raw, totalDuration: totalDuration);
  }

  /// Sync progress — lissen uses POST api/session/{itemId}/sync with {currentTime, timeListened}
  /// ABS also accepts PATCH api/me/progress/{itemId} via library sync. Try both.
  /// Also sends isFinished like ABS does (progress>=0.99)
  Future<void> syncProgress(String itemId, double currentTime, double duration, {double timeListened = 15}) async {
    if (!isConfigured) return;
    final base = getUrl().replaceAll(RegExp(r'/+$'), '');
    final isFinished = MediaProgress.computeIsFinished(currentTime, duration);
    // Try session sync first (lissen path)
    try {
      final url = Uri.parse('$base/api/session/$itemId/sync');
      final resp = await http.post(url,
          headers: {...authHeaders, 'Content-Type': 'application/json'},
          body: jsonEncode({'currentTime': currentTime, 'timeListened': timeListened, 'duration': duration})).timeout(const Duration(seconds: 5));
      if (resp.statusCode < 400) return;
    } catch (_) {}
    // Fallback: PATCH /api/me/progress/{itemId} — include isFinished for ABS filtering
    try {
      final url = Uri.parse('$base/api/me/progress/$itemId');
      await http.patch(url,
          headers: {...authHeaders, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'currentTime': currentTime,
            'duration': duration,
            'progress': duration > 0 ? currentTime / duration : 0,
            'isFinished': isFinished,
            'lastUpdate': DateTime.now().millisecondsSinceEpoch,
          })).timeout(const Duration(seconds: 5));
    } catch (_) {}
    // Also try POST for newer ABS
    try {
      final url = Uri.parse('$base/api/me/progress/$itemId');
      await http.post(url,
          headers: {...authHeaders, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'currentTime': currentTime,
            'duration': duration,
            'progress': duration > 0 ? currentTime / duration : 0,
            'isFinished': isFinished,
          })).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> startPlaybackSession(String itemId, {double currentTime = 0}) async {
    if (!isConfigured) return null;
    final base = getUrl().replaceAll(RegExp(r'/+$'), '');
    final url = Uri.parse('$base/api/items/$itemId/play');
    try {
      final resp = await http.post(url,
          headers: {...authHeaders, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'deviceInfo': {'clientName': 'KumaFlow', 'deviceId': 'kumaflow', 'deviceName': 'KumaFlow'},
            'supportedMimeTypes': ['audio/mpeg', 'audio/mp4', 'audio/ogg', 'audio/flac'],
            'mediaPlayer': 'KumaFlow',
            'forceTranscode': false,
            'forceDirectPlay': false,
          })).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {}
    return null;
  }

  Future<List<Map<String, dynamic>>> searchBooks(String query, {String libraryId = ''}) async {
    if (!isConfigured || query.trim().isEmpty) return [];
    final base = getUrl().replaceAll(RegExp(r'/+$'), '');
    String lid = libraryId;
    if (lid.isEmpty) {
      final libs = await fetchLibraries();
      if (libs.isNotEmpty) lid = libs.first['id'] as String? ?? '';
    }
    if (lid.isEmpty) return [];
    final url = Uri.parse('$base/api/libraries/$lid/search?q=${Uri.encodeComponent(query)}&limit=20');
    final resp = await http.get(url, headers: authHeaders).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return [];
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final books = (data['book'] ?? data['results'] ?? data['items'] ?? []) as List;
    return books.cast<Map<String, dynamic>>();
  }

  String getStreamUrl(String itemId, {String? fileId}) {
    if (!isConfigured || itemId.isEmpty) return '';
    final base = getUrl().replaceAll(RegExp(r'/+$'), '');
    final token = getToken();
    // Direct stream with token query — just_audio can fetch without header
    if (fileId != null && fileId.isNotEmpty) {
      return '$base/api/items/$itemId/file/$fileId?token=$token';
    }
    return '$base/api/items/$itemId/play?token=$token';
  }

  Future<List<Map<String, dynamic>>> fetchLibraries() async {
    if (!isConfigured) return [];
    final url = Uri.parse('${getUrl().replaceAll(RegExp(r'/+$'), '')}/api/libraries');
    final resp = await http.get(url, headers: {'Authorization': 'Bearer ${getToken()}' }).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) throw Exception('ABS ${resp.statusCode}');
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return (data['libraries'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  Future<List<Map<String, dynamic>>> fetchBooks({String libraryId = '', int limit = 200}) async {
    if (!isConfigured) return [];
    final base = getUrl().replaceAll(RegExp(r'/+$'), '');
    // If no libraryId, fetch from all libraries (merge) — previous impl hit /api/libraries which returns libs, not books
    if (libraryId.isEmpty) {
      try {
        final libs = await fetchLibraries();
        final all = <Map<String, dynamic>>[];
        for (final lib in libs) {
          final id = lib['id'] as String? ?? '';
          if (id.isEmpty) continue;
          final chunk = await fetchBooks(libraryId: id, limit: limit);
          all.addAll(chunk);
          if (all.length >= limit) break;
        }
        return all.take(limit).toList();
      } catch (_) {
        return [];
      }
    }
    final path = '/api/libraries/$libraryId/items';
    // expanded=1 ensures userMediaProgress is included (ABS needs it for progress/isFinished)
    final url = Uri.parse('$base$path?limit=$limit&expanded=1&include=progress,media');
    final resp = await http.get(url, headers: {'Authorization': 'Bearer ${getToken()}'}).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return [];
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (data['results'] ?? data['items'] ?? data['libraries'] ?? data['books'] ?? []) as List;
    return items.cast<Map<String, dynamic>>();
  }
}
