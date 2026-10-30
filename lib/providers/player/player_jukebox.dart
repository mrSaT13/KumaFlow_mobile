// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// Part of the PlayerProvider library: extension calls notifyListeners()
// on its own instance — same library, no behavior change.
part of '../player_provider.dart';

/// Jukebox mode: включение, polling статуса, синхронизация состояния.
extension PlayerJukebox on PlayerProvider {
  void _onJukeboxEnabledChanged() {
    if (_jukeboxService.enabled) {
      _startJukeboxPolling();
    } else {
      _stopJukeboxPolling();
    }
  }

  void _startJukeboxPolling() {
    _stopJukeboxPolling();
    _jukeboxPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _pollJukebox();
    });
    _pollJukebox();
  }

  void _stopJukeboxPolling() {
    _jukeboxPollTimer?.cancel();
    _jukeboxPollTimer = null;
  }

  Future<void> _pollJukebox() async {
    if (!_jukeboxService.enabled) return;
    try {
      await _jukeboxService.refresh(_subsonicService);
      _syncFromJukeboxStatus();
    } catch (e) {
      debugPrint('Jukebox poll error: $e');
    }
  }

  void _syncFromJukeboxStatus() {
    if (!_jukeboxService.enabled) return;
    final status = _jukeboxService.status;
    final song = status.currentSong;

    bool changed = false;
    if (song != null && song.id != _currentSong?.id) {
      _currentSong = song;
      _resolvedArtworkUrl = null;
      changed = true;
    }
    if (_isPlaying != status.playing) {
      _isPlaying = status.playing;
      changed = true;
    }
    if (_position != status.position) {
      _position = status.position;
      changed = true;
    }
    if (status.playlist.isNotEmpty && !identical(_queue, status.playlist)) {
      _queue = List.from(status.playlist);
      changed = true;
    }
    final clampedIndex = status.currentIndex.clamp(
      0,
      (_queue.length - 1).clamp(0, double.maxFinite.toInt()),
    );
    if (_currentIndex != clampedIndex) {
      _currentIndex = clampedIndex;
      changed = true;
    }
    if (changed) {
      notifyListeners();
      _updateAllServices();
      _trackPlay();
      _updateAndroidAuto();
    }
  }
}
