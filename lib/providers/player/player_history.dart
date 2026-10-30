part of '../player_provider.dart';

/// История и аналитика: старт трека, порог прослушивания, запись статистики.
extension PlayerHistory on PlayerProvider {
  void _trackPlay() {
    if (_currentSong == null) return;

    _seekBackLoggedSongId = null;
    final song = _currentSong!;
    _lastTrackPlayKey = song.queueKey;
    _lastTrackPlayMs = DateTime.now().millisecondsSinceEpoch;
    // Real EQ: сессия уже жива — дотолкнуть состояние в системный эквалайзер.
    // Если сессии ещё не было, push вернёт false и применится следующим.
    try {
      final eq = EqualizerService.instanceOrNull;
      if (eq != null) unawaited(eq.pushToEngine());
    } catch (_) {}
    // Тяжёлая часть (ML-счётчики, vibe-анализ, записи на диск) — не в момент
    // переключения трека, а следующим событием: иначе главный поток занят
    // синхронной работой прямо во время скипа (вклад в ANR).
    Future(() {
      try {
        _mlService.incrementPlayCount(song.id, song: song);
        _behaviorTracker.logPlay(song.id, genre: song.genre);
        _mlStore.incrementPlayCount(song.id, null);
        _timeAwareHistory.logPlay(song.id, DateTime.now().hour);
        _brainEvent(song.id, 'play');
        _brainHistory(song.id);
        _brainPublish(force: true);

        final vibeFeatures = _vibeSimilarity.analyzeTrack(song);
        _sonicFingerprint.updateFingerprint(song.id, vibeFeatures.toJson());
        _moodDriftDetector.logPositiveInteraction(song.id);
      } catch (e) {
        debugPrint('[Player] _trackPlay deferred error: $e');
      }
    });
  }

  /// Порог истории: трек считается прослушанным при ≥30с или ≥50% длительности.
  /// Подкасты в музыкальную историю KumaFlow Brain не пишем (только в аналитику).
  /// [force]=true — полное дослушивание (gapless-переход, onComplete).
  void _maybeCommitHistory(Song song, int playedSec, int totalSec, {bool force = false}) {
    if (_isPodcastSong(song)) return;
    if (_recommendationService == null) return;
    final half = totalSec > 0 ? playedSec >= totalSec * 0.5 : false;
    final significant = force || playedSec >= 30 || half;
    if (!significant) return;
    final completed = force || (totalSec > 0 && playedSec >= totalSec * 0.8);
    unawaited(_recommendationService!.trackSongPlay(
      song,
      durationPlayed: playedSec,
      completed: completed,
    ));
    unawaited(_recordAnalytics(song, playedSec * 1000, completed));
    if (completed) _brainEvent(song.id, 'complete', positionSec: playedSec);
  }

  /// Аналитика «что я слушал уже» (экран статистики). Пишем и музыку,
  /// и подкасты/книги — в отличие от музыкального KumaFlow Brain.
  /// Троттлится внутри LocalAnalyticsService, ошибок наружу не кидаем.
  Future<void> _recordAnalytics(Song song, int durationMs, bool completed) async {
    try {
      await LocalAnalyticsService().recordListen(
        songId: song.id,
        songTitle: song.title,
        artistId: song.artistId,
        artistName: song.artist,
        albumId: song.albumId,
        albumTitle: song.album,
        genre: song.genre,
        durationMs: durationMs,
        completed: completed,
      );
    } catch (_) {}
  }
}
