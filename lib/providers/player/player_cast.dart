// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// Part of the PlayerProvider library: extension calls notifyListeners()
// on its own instance — same library, no behavior change.
part of '../player_provider.dart';

/// Cast / UPnP: громкость на рендере, смена состояния, потеря рендера.
extension PlayerCast on PlayerProvider {
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    await _storageService.saveVolume(_volume);
    if (_castService.isConnected) {
      await _castService.setVolume(_volume);
    } else if (_upnpService.isConnected) {
      await _upnpService.setVolume((_volume * 100).round());
    } else {
      await _applyReplayGain(_currentSong);
    }
    notifyListeners();
  }

  void _onRemoteVolumeChange(int volume) {
    if (_castService.isConnected) {
      _castService.setVolume(volume / 100.0);
    } else if (_upnpService.isConnected) {
      if (_upnpVolumeWriteInProgress) return;
      _applyUpnpVolume(volume);
    }
  }

  Future<void> _applyUpnpVolume(int volume) async {
    _upnpVolumeWriteInProgress = true;
    _volume = (volume / 100.0).clamp(0.0, 1.0);
    notifyListeners();
    try {
      await _upnpService.setVolume(volume);
      final actual = await _upnpService.getVolume();
      if (actual >= 0) {
        _volume = actual / 100.0;
        _androidSystemService.updateRemoteVolume(actual);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('UPnP setVolume error: $e');
    } finally {
      _upnpVolumeWriteInProgress = false;
    }
  }

  void _onCastStateChanged() {
    notifyListeners();
    if (_castService.isConnected) {
      _audioPlayer.pause();
      _androidSystemService.setRemotePlayback(isRemote: true, volume: 50);
      if (_currentSong != null) {
        final song = _currentSong!;
        _currentSong = null;
        playSong(song);
      }
    } else {
      _isRenderingRemotely = false;
      _androidSystemService.setRemotePlayback(isRemote: false);
      _isPlaying = false;
      notifyListeners();
      _updateAndroidAuto();
    }
  }

  void _onUpnpStateChanged() {
    final connected = _upnpService.isConnected;

    if (connected && !_upnpWasConnected) {
      _upnpWasConnected = true;
      _upnpWasPlaying = false;
      if (_audioPlayer.playing) _audioPlayer.pause();
      final vol = _upnpService.volume;

      if (vol >= 0) _volume = vol / 100.0;
      _androidSystemService.setRemotePlayback(
        isRemote: true,
        volume: vol >= 0 ? vol : 50,
      );
      if (_currentSong != null) {
        final song = _currentSong!;
        _currentSong = null;
        playSong(song);
      }
      return;
    }

    if (!connected && _upnpWasConnected) {
      _upnpWasConnected = false;
      _upnpWasPlaying = false;
      _isRenderingRemotely = false;
      _isPlaying = false;
      // Preserve _position and _duration so the UI shows where we were.
      _androidSystemService.setRemotePlayback(isRemote: false);
      notifyListeners();
      _updateAndroidAuto();
      return;
    }

    if (!connected) return;

    final pos = _upnpService.rendererPosition;
    final dur = _upnpService.rendererDuration;
    final playing = _upnpService.isRendererPlaying;
    final rendererState = _upnpService.rendererState;

    if (_upnpWasPlaying && rendererState == 'STOPPED') {
      // _upnpWasPlaying is reset to false in playSong() and stop() before
      // any Stop command is sent, so this only fires for a *natural* track
      // end.  We don't check duration > 0 here because many renderers
      // (including moode/upmpdcli) return 0:00:00 from GetPositionInfo once
      // the transport is stopped, which would cause the check to silently fail.
      debugPrint(
          'UPnP: Track ended (pos=${pos.inSeconds}s, dur=${dur.inSeconds}s) — advancing');
      _upnpWasPlaying = false;
      _onSongComplete()
          .catchError((e) => debugPrint('[Player] _onSongComplete error: $e'));
      return;
    }

    _upnpWasPlaying = playing;

    bool changed = false;

    if ((_position - pos).abs() > const Duration(milliseconds: 500)) {
      _position = pos;
      changed = true;
    }
    if (dur != _duration) {
      _duration = dur;
      changed = true;
    }
    if (playing != _isPlaying) {
      _isPlaying = playing;
      changed = true;
    }

    final vol = _upnpService.volume;
    if (vol >= 0 && !_upnpVolumeWriteInProgress) {
      final normalized = vol / 100.0;
      if ((_volume - normalized).abs() > 0.005) {
        _volume = normalized;
        changed = true;
        _androidSystemService.updateRemoteVolume(vol);
      }
    }

    if (changed) {
      _positionController.add(_position);
      notifyListeners();
      _updateAndroidAuto();
    }
  }

  /// Called by [UpnpService] after 30 consecutive poll failures (~30 s).
  /// [_onUpnpStateChanged] has already switched us off remote playback and
  /// preserved [_position]. Load the song into the local player at the last
  /// known position, paused, so the user can resume wherever they want.
  /// Android routes audio to a connected A2DP device automatically.
  Future<void> _onUpnpRendererLost() async {
    final lastPosition = _position;
    final lastSong = _currentSong;

    debugPrint(
      'UPnP: renderer lost — A2DP audio active: $_isA2dpAudioActive, '
      'last position: ${lastPosition.inSeconds}s, song: "${lastSong?.title}"',
    );

    if (lastSong == null) return;

    final playUrl = lastSong.isLocal == true && lastSong.path != null
        ? Uri.file(lastSong.path!).toString()
        : _offlineService.getPlayableUrl(lastSong.id) ?? '';

    _isLoading = true;
    notifyListeners();

    try {
      await _audioPlayer.setUrl(playUrl);
      _position = lastPosition;
      await _audioPlayer.seek(lastPosition);
      // Leave paused — let the user consciously resume on their new output.
    } catch (e) {
      debugPrint('UPnP fallback: failed to reload local player: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
      _updateAndroidAuto();
    }
  }
}
