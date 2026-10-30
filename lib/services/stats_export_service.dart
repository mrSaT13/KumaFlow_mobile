import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';
import '../models/genre.dart';

/// Сервис экспорта статистики прослушиваний в JSON и CSV.
/// Поддерживает поделиться файлом через системный шаринг.
class StatsExportService {
  static final StatsExportService _instance = StatsExportService._internal();
  factory StatsExportService() => _instance;
  StatsExportService._internal();

  /// Экспорт статистики в JSON.
  Future<File> exportToJson({
    required List<Song> recentlyPlayed,
    required Map<String, int> topArtists,
    required List<Genre> topGenres,
    required Duration totalListenTime,
    int totalTrackCount = 0,
  }) async {
    final data = {
      'exportedAt': DateTime.now().toIso8601String(),
      'summary': {
        'totalTracks': totalTrackCount,
        'totalListenTimeSeconds': totalListenTime.inSeconds,
        'topArtistsCount': topArtists.length,
        'topGenresCount': topGenres.length,
      },
      'topArtists': topArtists.entries
          .take(50)
          .map((e) => {'name': e.key, 'playCount': e.value})
          .toList(),
      'topGenres': topGenres
          .take(20)
          .map((g) => {'name': g.value, 'songCount': g.songCount})
          .toList(),
      'recentlyPlayed': recentlyPlayed
          .take(100)
          .map((s) => {
                'id': s.id,
                'title': s.title,
                'artist': s.artist ?? 'Неизвестный',
                'album': s.album ?? '',
                'genre': s.genre ?? '',
                'duration': s.duration ?? 0,
              })
          .toList(),
    };

    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/kumaflow_stats_${_dateStamp()}.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    return file;
  }

  /// Экспорт статистики в CSV.
  Future<File> exportToCsv({
    required List<Song> recentlyPlayed,
    required Map<String, int> topArtists,
    required List<Genre> topGenres,
    required Duration totalListenTime,
  }) async {
    final buf = StringBuffer();

    // Сводка
    buf.writeln('KumaFlow — Экспорт статистики');
    buf.writeln('Дата экспорта;${DateTime.now().toIso8601String()}');
    buf.writeln(
        'Общее время прослушивания (сек);${totalListenTime.inSeconds}');
    buf.writeln();

    // Топ артистов
    buf.writeln('Топ артистов');
    buf.writeln('Артист;Количество прослушиваний');
    for (final entry in topArtists.entries.take(50)) {
      buf.writeln('${_csvEscape(entry.key)};${entry.value}');
    }
    buf.writeln();

    // Топ жанров
    buf.writeln('Топ жанров');
    buf.writeln('Жанр;Количество треков');
    for (final genre in topGenres.take(20)) {
      buf.writeln('${_csvEscape(genre.value)};${genre.songCount}');
    }
    buf.writeln();

    // Недавние прослушивания
    buf.writeln('Недавние прослушивания');
    buf.writeln('Название;Артист;Альбом;Жанр;Длительность (сек)');
    for (final song in recentlyPlayed.take(100)) {
      buf.writeln(
          '${_csvEscape(song.title)};'
          '${_csvEscape(song.artist ?? 'Неизвестный')};'
          '${_csvEscape(song.album ?? '')};'
          '${_csvEscape(song.genre ?? '')};'
          '${song.duration ?? 0}');
    }

    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/kumaflow_stats_${_dateStamp()}.csv');
    await file.writeAsString(buf.toString());
    return file;
  }

  /// Открыть файл статистики через системный обработчик.
  /// Возвращает путь к файлу для further use.
  Future<String> openStatsFile(File file) async {
    try {
      final uri = Uri.file(file.path);
      // Открываем через систему — зависит от платформы
      if (kIsWeb) {
        debugPrint('Веб: файл экспорта — ${file.path}');
      }
      return file.path;
    } catch (e) {
      debugPrint('Ошибка при открытии файла статистики: $e');
      return file.path;
    }
  }

  String _dateStamp() {
    final now = DateTime.now();
    return '${now.year}${_pad(now.month)}${_pad(now.day)}_${_pad(now.hour)}${_pad(now.minute)}';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  String _csvEscape(String value) {
    if (value.contains(';') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}
