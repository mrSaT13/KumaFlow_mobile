import '../models/song.dart';

/// Playlist Orchestrator - сортирует треки для плавных переходов
/// Порт с десктопной версии (playlist-orchestrator.ts)
class PlaylistOrchestrator {
  /// Оркестрирует плейлист для плавных переходов
  static List<Song> orchestrate(
    List<Song> songs, {
    String startWith = 'mixed',
    String endWith = 'calm',
  }) {
    if (songs.length <= 2) return songs;

    final scored = songs.map((s) {
      double energy = _estimateEnergy(s);
      return _ScoredSong(song: s, energy: energy);
    }).toList();

    if (startWith == 'energetic' && endWith == 'calm') {
      scored.sort((a, b) => b.energy.compareTo(a.energy));
    } else if (startWith == 'calm' && endWith == 'energetic') {
      scored.sort((a, b) => a.energy.compareTo(b.energy));
    } else if (startWith == 'energetic' && endWith == 'energetic') {
      scored.sort((a, b) {
        final aMid = (a.energy - 0.5).abs();
        final bMid = (b.energy - 0.5).abs();
        return bMid.compareTo(aMid);
      });
    } else {
      // Mixed: alternate high/low energy
      final sorted = List<_ScoredSong>.from(scored)
        ..sort((a, b) => b.energy.compareTo(a.energy));
      final result = <_ScoredSong>[];
      int left = 0;
      int right = sorted.length - 1;
      bool takeHigh = true;
      while (left <= right) {
        if (takeHigh) {
          result.add(sorted[left++]);
        } else {
          result.add(sorted[right--]);
        }
        takeHigh = !takeHigh;
      }
      return result.map((s) => s.song).toList();
    }

    return scored.map((s) => s.song).toList();
  }

  /// Публичная оценка энергии трека 0..1 (для коллаб-микса и др.).
  static double energyOf(Song song) => _estimateEnergy(song);

  /// Оценивает энергию трека — учитывает mood из метаданных (настроение важнее жанра)
  static double _estimateEnergy(Song song) {
    // Mood из метаданных имеет приоритет — он точнее жанра
    final mood = song.mood?.toLowerCase() ?? '';
    if (mood.isNotEmpty) {
      if (mood.contains('energetic') || mood.contains('hype') || mood.contains('party') || mood.contains('aggressive')) {
        return 0.85;
      } else if (mood.contains('happy') || mood.contains('upbeat') || mood.contains('cheerful')) {
        return 0.75;
      } else if (mood.contains('calm') || mood.contains('chill') || mood.contains('relax') || mood.contains('ambient')) {
        return 0.30;
      } else if (mood.contains('sad') || mood.contains('melancholic') || mood.contains('dark') || mood.contains('depressive')) {
        return 0.35;
      } else if (mood.contains('romantic') || mood.contains('love')) {
        return 0.50;
      }
    }

    double energy = 0.5;

    final genre = song.genre?.toLowerCase() ?? '';
    if (genre.contains('metal') || genre.contains('punk') || genre.contains('hardcore')) {
      energy = 0.85;
    } else if (genre.contains('electronic') || genre.contains('dance') || genre.contains('techno')) {
      energy = 0.8;
    } else if (genre.contains('rock') || genre.contains('pop')) {
      energy = 0.7;
    } else if (genre.contains('hip-hop') || genre.contains('rap')) {
      energy = 0.75;
    } else if (genre.contains('classical') || genre.contains('ambient') || genre.contains('new age')) {
      energy = 0.25;
    } else if (genre.contains('jazz') || genre.contains('blues')) {
      energy = 0.4;
    } else if (genre.contains('folk') || genre.contains('acoustic')) {
      energy = 0.35;
    }

    if (song.duration != null) {
      if (song.duration! < 180) {
        energy = (energy + 0.05).clamp(0.0, 1.0);
      } else if (song.duration! > 300) {
        energy = (energy - 0.05).clamp(0.0, 1.0);
      }
    }

    return energy;
  }

  /// Создаёт энергетическую волну (calm → energetic → calm)
  static List<Song> createEnergyWave(List<Song> songs, {int segments = 3}) {
    if (songs.length <= 2) return songs;

    final scored = songs.map((s) {
      double energy = _estimateEnergy(s);
      return _ScoredSong(song: s, energy: energy);
    }).toList();

    scored.sort((a, b) => a.energy.compareTo(b.energy));

    final result = <_ScoredSong>[];
    final segmentSize = (scored.length / segments).ceil();

    for (int i = 0; i < segments; i++) {
      final start = i * segmentSize;
      final end = (start + segmentSize).clamp(0, scored.length);
      final segment = scored.sublist(start, end);

      if (i % 2 == 0) {
        segment.sort((a, b) => a.energy.compareTo(b.energy));
      } else {
        segment.sort((a, b) => b.energy.compareTo(a.energy));
      }

      result.addAll(segment);
    }

    return result.map((s) => s.song).toList();
  }

  /// Проверяет плавность перехода между двумя треками — mood учитывается
  static bool isSmoothTransition(Song current, Song next) {
    // Если настроение совпадает — переход плавный независимо от жанра/энергии
    if (current.mood != null && next.mood != null && current.mood!.toLowerCase() == next.mood!.toLowerCase()) {
      return true;
    }
    final currentEnergy = _estimateEnergy(current);
    final nextEnergy = _estimateEnergy(next);
    final energyDiff = (currentEnergy - nextEnergy).abs();

    final currentGenre = current.genre?.toLowerCase() ?? '';
    final nextGenre = next.genre?.toLowerCase() ?? '';
    final genreMatch = currentGenre.isNotEmpty &&
        nextGenre.isNotEmpty &&
        (currentGenre.contains(nextGenre) || nextGenre.contains(currentGenre));

    // Также проверяем совпадение mood частично (chill ~ calm)
    final moodMatch = current.mood != null && next.mood != null && (
        current.mood!.toLowerCase().contains(next.mood!.toLowerCase()) ||
        next.mood!.toLowerCase().contains(current.mood!.toLowerCase()));

    return energyDiff < 0.3 || genreMatch || moodMatch;
  }

  /// Фильтрует треки по настроению из БД (гибрид — сначала точное совпадение mood, потом жанр)
  static List<Song> filterByMood(List<Song> songs, String mood) {
    final lower = mood.toLowerCase();
    final exact = songs.where((s) => s.mood?.toLowerCase() == lower).toList();
    if (exact.length >= 5) return exact;
    // Fallback: настроение в жанре или частичное совпадение
    final partial = songs.where((s) =>
        (s.mood?.toLowerCase().contains(lower) ?? false) ||
        (s.genre?.toLowerCase().contains(lower) ?? false)).toList();
    return partial.isNotEmpty ? partial : songs;
  }
}

class _ScoredSong {
  final Song song;
  final double energy;
  _ScoredSong({required this.song, required this.energy});
}
