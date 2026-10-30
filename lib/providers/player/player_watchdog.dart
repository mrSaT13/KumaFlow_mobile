// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// Part of the PlayerProvider library: extension calls notifyListeners()
// on its own instance — same library, no behavior change.
part of '../player_provider.dart';

/// Сторож мёртвого стрима: трек встал (403/обрыв/вечный buffering) —
/// перепрыгиваем дальше вместо тишины.
extension PlayerWatchdog on PlayerProvider {
  void _startStallWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogPosition = Duration.zero;
    _stallTicks = 0;
    _watchdogTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _watchdogTick()
          .catchError((e) => debugPrint('[Player] watchdog error: $e'));
    });
  }

  Future<void> _watchdogTick() async {
    if (_isRenderingRemotely) return;
    final song = _currentSong;
    if (song == null || _queue.isEmpty || _isLoading) {
      _stallTicks = 0;
      return;
    }
    // Локальное/офлайн/подкасты не стримятся — сторожить нечего.
    if (song.isLocal == true) return;
    if (_isPodcastSong(song)) return;
    if (_offlineService.getLocalPath(song.queueKey) != null ||
        _offlineService.getLocalPath(song.id) != null) {
      return;
    }

    final playing = _audioPlayer.playing;
    final st = _audioPlayer.processingState;
    final pos = _audioPlayer.position;
    if (playing) _lastPlayingTime = DateTime.now();

    final frozen =
        (pos - _watchdogPosition).abs() < const Duration(milliseconds: 500);
    _watchdogPosition = pos;
    if (playing && !frozen) {
      // Живой прогресс — сбрасываем счетчики.
      _stallTicks = 0;
      _consecutiveStreamFailures = 0;
      return;
    }
    // Треки короче/в самом начале не судим (стартовый buffering — норма).
    final started = pos > const Duration(seconds: 3);
    final bufferingStall =
        playing && st == ProcessingState.buffering && frozen && started;
    final canJudge = _duration.inSeconds > 30;
    final idleAfterPlay = !playing &&
        st == ProcessingState.idle &&
        frozen &&
        started &&
        canJudge &&
        _position.inMilliseconds < _duration.inMilliseconds * 0.9 &&
        _lastPlayingTime != null &&
        DateTime.now().difference(_lastPlayingTime!) <
            const Duration(seconds: 30) &&
        (_lastUserStopTime == null ||
            _lastPlayingTime!.isAfter(_lastUserStopTime!));
    if (bufferingStall || idleAfterPlay) {
      _stallTicks++;
      if (_stallTicks >= 3) {
        _stallTicks = 0;
        await _skipDeadStream(bufferingStall ? 'stall' : 'idle');
      }
    } else {
      _stallTicks = 0;
    }
  }

  Future<void> _skipDeadStream(String reason) async {
    final song = _currentSong;
    if (song == null || _queue.isEmpty) return;
    if (_consecutiveStreamFailures >= 3) {
      debugPrint('[Player] 3 dead streams in a row — stopping');
      _consecutiveStreamFailures = 0;
      try {
        await _audioPlayer.stop();
      } catch (_) {}
      _isPlaying = false;
      notifyListeners();
      return;
    }
    _consecutiveStreamFailures++;
    _deadStreamKeys.add(song.queueKey);
    debugPrint('[Player] Stream died ($reason): "${song.title}" — skipping');
    try {
      await skipNext();
    } catch (e) {
      debugPrint('[Player] auto-skip failed: $e');
    }
  }
}
