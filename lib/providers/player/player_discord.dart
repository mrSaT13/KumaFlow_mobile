// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// Part of the PlayerProvider library: extension calls notifyListeners()
// on its own instance — same library, no behavior change.
part of '../player_provider.dart';

/// Discord Rich Presence: текст состояния, обновление, настройки.
extension PlayerDiscord on PlayerProvider {
  bool get discordRpcEnabled => _discordRpcService.enabled;

  String get discordRpcStateStyle => _discordRpcStateStyle;

  Future<void> loadDiscordRpcStateStyle() async {
    _discordRpcStateStyle = await _storageService.getDiscordRpcStateStyle();
  }

  Future<void> setDiscordRpcStateStyle(String style) async {
    _discordRpcStateStyle = style;
    await _storageService.saveDiscordRpcStateStyle(style);
    _updateDiscordRpc();
    notifyListeners();
  }

  Future<void> setDiscordRpcEnabled(bool enabled) async {
    try {
      await _discordRpcService.setEnabled(enabled);
      if (enabled) {
        _updateDiscordRpc();
      }
    } catch (_) {}
  }

  String _discordStateText() {
    switch (_discordRpcStateStyle) {
      case 'song_title':
        return _currentSong?.title ?? 'Unknown Song';
      case 'app_name':
        return 'KumaFlow';
      case 'artist':
      default:
        return _currentSong?.artist ?? 'Unknown Artist';
    }
  }

  void _updateDiscordRpc() {
    try {
      if (_currentSong == null) {
        _discordRpcService.clearPresence();
        return;
      }

      final int now = DateTime.now().millisecondsSinceEpoch;
      final int startTimestamp = now - _position.inMilliseconds;
      final int? endTimestamp = _isPlaying && _duration.inMilliseconds > 0
          ? startTimestamp + _duration.inMilliseconds
          : null;

      final stateText = _discordStateText();

      _discordRpcService.updatePresence(
        state: stateText,
        details: _currentSong!.title,
        largeImageKey: 'kumaflow_logo',
        largeImageText: _currentSong!.album,
        smallImageKey: 'kumaflow_logo',
        smallImageText: _isPlaying ? 'Playing' : 'Paused',
        startTime: startTimestamp,
        endTime: endTimestamp,
      );
    } catch (_) {}
  }
}
