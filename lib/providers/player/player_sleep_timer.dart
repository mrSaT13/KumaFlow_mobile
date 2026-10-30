// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// Part of the PlayerProvider library: extension calls notifyListeners()
// on its own instance — same library, no behavior change.
part of '../player_provider.dart';

/// Sleep timer: getters, set/cancel, fade-out, stop.
extension PlayerSleepTimer on PlayerProvider {
  bool get hasSleepTimer => _sleepTimer != null;
  bool get sleepTimerEndCurrentSong => _sleepTimerEndCurrentSong;
  bool get sleepTimerFadeOut => _sleepTimerFadeOut;
  int get sleepTimerFadeDurationSeconds => _sleepTimerFadeDurationSeconds;

  Duration? get sleepTimerRemaining {
    if (_sleepTimerEnd == null) return null;
    final remaining = _sleepTimerEnd!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void setSleepTimer(
    Duration duration, {
    bool endCurrentSong = false,
    bool fadeOut = false,
    int fadeDurationSeconds = 30,
  }) {
    _sleepTimer?.cancel();
    _sleepTimerFadeTimer?.cancel();
    _sleepTimerFadePeriodicTimer?.cancel();
    _sleepTimerFadePeriodicTimer = null;
    _sleepTimer = null;
    _sleepTimerEnd = null;
    _sleepTimerEndCurrentSong = endCurrentSong;
    _sleepTimerFadeOut = fadeOut;
    _sleepTimerFadeDurationSeconds = fadeDurationSeconds;

    if (duration > Duration.zero) {
      _sleepTimerEnd = DateTime.now().add(duration);

      if (fadeOut) {
        final fadeStart = duration - Duration(seconds: fadeDurationSeconds);
        if (fadeStart > Duration.zero) {
          _sleepTimerFadeTimer =
              Timer(fadeStart, () => _startFadeOut(fadeDurationSeconds));
        } else {
          _startFadeOut(fadeDurationSeconds);
        }
      }

      _sleepTimer = Timer(duration, () {
        if (endCurrentSong) {
          _sleepTimerEndCurrentSong = true;
          _sleepTimer = null;
          _sleepTimerEnd = null;
          notifyListeners();
        } else {
          _doSleepTimerStop();
        }
      });
    }
    notifyListeners();
  }

  /// Cancel the active sleep timer.
  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimerFadeTimer?.cancel();
    _sleepTimerFadePeriodicTimer?.cancel();
    _sleepTimerFadePeriodicTimer = null;
    _audioPlayer.setVolume(_volume);
    _sleepTimer = null;
    _sleepTimerEnd = null;
    _sleepTimerFadeOut = false;
    _sleepTimerFadeDurationSeconds = 30;
    _sleepTimerEndCurrentSong = false;
    notifyListeners();
  }

  void _startFadeOut([int fadeDurationSeconds = 30]) {
    _sleepTimerFadePeriodicTimer?.cancel();
    final steps = fadeDurationSeconds.clamp(5, 300);
    const stepDuration = Duration(seconds: 1);
    final originalVolume = _volume;
    int step = 0;
    _sleepTimerFadePeriodicTimer = Timer.periodic(stepDuration, (t) {
      step++;
      final newVolume = originalVolume * (1.0 - step / steps);
      _audioPlayer.setVolume(newVolume.clamp(0.0, 1.0));
      if (step >= steps) {
        t.cancel();
        _sleepTimerFadePeriodicTimer = null;
      }
    });
  }

  void _doSleepTimerStop() {
    _sleepTimerFadePeriodicTimer?.cancel();
    _sleepTimerFadePeriodicTimer = null;
    _audioPlayer.setVolume(_volume);
    pause();
    _sleepTimer = null;
    _sleepTimerEnd = null;
    _sleepTimerFadeOut = false;
    _sleepTimerFadeDurationSeconds = 30;
    _sleepTimerEndCurrentSong = false;
    notifyListeners();
  }
}
