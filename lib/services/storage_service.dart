import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/server_config.dart';

class StorageService {
  static const String _serverConfigKey = 'server_config';
  static const String _serverProfilesKey = 'server_profiles';
  static const String _lastPlayedKey = 'last_played';
  static const String _queueKey = 'queue';
  static const String _queueIndexKey = 'queue_index';
  static const String _shuffleModeKey = 'shuffle_mode';
  static const String _repeatModeKey = 'repeat_mode';
  static const String _gaplessPlaybackKey = 'gapless_playback';
  static const String _crossfadeEnabledKey = 'crossfade_enabled';
  static const String _crossfadeSecondsKey = 'crossfade_seconds';
  static const String _lrcLibFallbackKey = 'lrclib_fallback';
  static const String _preferSyncedLyricsKey = 'prefer_synced_lyrics';
  static const String _volumeKey = 'volume';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<void> saveServerConfig(ServerConfig config) async {
    final prefs = await _prefs;
    await prefs.setString(_serverConfigKey, json.encode(config.toJson()));
  }

  Future<ServerConfig?> getServerConfig() async {
    final prefs = await _prefs;
    final configJson = prefs.getString(_serverConfigKey);
    if (configJson != null) {
      return ServerConfig.fromJson(json.decode(configJson));
    }
    return null;
  }

  Future<void> clearServerConfig() async {
    final prefs = await _prefs;
    await prefs.remove(_serverConfigKey);
  }

  Future<List<ServerConfig>> getSavedProfiles() async {
    final prefs = await _prefs;
    final json = prefs.getString(_serverProfilesKey);
    if (json == null) return [];
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => ServerConfig.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveProfile(ServerConfig config) async {
    final profiles = await getSavedProfiles();
    final idx = profiles.indexWhere(
      (p) => p.serverUrl == config.serverUrl && p.username == config.username,
    );
    if (idx >= 0) {
      profiles[idx] = config;
    } else {
      profiles.add(config);
    }
    final prefs = await _prefs;
    await prefs.setString(
      _serverProfilesKey,
      jsonEncode(profiles.map((p) => p.toJson()).toList()),
    );
  }

  Future<void> deleteProfile(ServerConfig config) async {
    final profiles = await getSavedProfiles();
    profiles.removeWhere(
      (p) => p.serverUrl == config.serverUrl && p.username == config.username,
    );
    final prefs = await _prefs;
    await prefs.setString(
      _serverProfilesKey,
      jsonEncode(profiles.map((p) => p.toJson()).toList()),
    );
  }

  Future<void> saveLastPlayed(String songId) async {
    final prefs = await _prefs;
    await prefs.setString(_lastPlayedKey, songId);
  }

  Future<String?> getLastPlayed() async {
    final prefs = await _prefs;
    return prefs.getString(_lastPlayedKey);
  }

  Future<void> saveQueue(List<Map<String, dynamic>> queue) async {
    final prefs = await _prefs;
    await prefs.setString(_queueKey, json.encode(queue));
  }

  Future<List<Map<String, dynamic>>> getQueue() async {
    final prefs = await _prefs;
    final queueJson = prefs.getString(_queueKey);
    if (queueJson != null) {
      final list = json.decode(queueJson) as List;
      return list.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<void> saveQueueIndex(int index) async {
    final prefs = await _prefs;
    await prefs.setInt(_queueIndexKey, index);
  }

  Future<int> getQueueIndex() async {
    final prefs = await _prefs;
    return prefs.getInt(_queueIndexKey) ?? 0;
  }

  Future<void> saveShuffleMode(bool enabled) async {
    final prefs = await _prefs;
    await prefs.setBool(_shuffleModeKey, enabled);
  }

  Future<bool> getShuffleMode() async {
    final prefs = await _prefs;
    return prefs.getBool(_shuffleModeKey) ?? false;
  }

  Future<void> saveRepeatMode(int mode) async {
    final prefs = await _prefs;
    await prefs.setInt(_repeatModeKey, mode);
  }

  Future<int> getRepeatMode() async {
    final prefs = await _prefs;
    return prefs.getInt(_repeatModeKey) ?? 0;
  }

  Future<void> saveGaplessPlayback(bool enabled) async {
    final prefs = await _prefs;
    await prefs.setBool(_gaplessPlaybackKey, enabled);
  }

  Future<bool> getGaplessPlayback() async {
    final prefs = await _prefs;
    return prefs.getBool(_gaplessPlaybackKey) ?? true;
  }

  Future<void> saveCrossfadeEnabled(bool enabled) async {
    final prefs = await _prefs;
    await prefs.setBool(_crossfadeEnabledKey, enabled);
  }

  Future<bool> getCrossfadeEnabled() async {
    final prefs = await _prefs;
    return prefs.getBool(_crossfadeEnabledKey) ?? true;
  }

  Future<void> saveCrossfadeSeconds(int seconds) async {
    final prefs = await _prefs;
    await prefs.setInt(_crossfadeSecondsKey, seconds);
  }

  Future<int> getCrossfadeSeconds() async {
    final prefs = await _prefs;
    return prefs.getInt(_crossfadeSecondsKey) ?? 5;
  }

  Future<void> saveLrcLibFallback(bool enabled) async {
    final prefs = await _prefs;
    await prefs.setBool(_lrcLibFallbackKey, enabled);
  }

  Future<bool> getLrcLibFallback() async {
    final prefs = await _prefs;
    return prefs.getBool(_lrcLibFallbackKey) ?? true;
  }

  Future<void> savePreferSyncedLyrics(bool enabled) async {
    final prefs = await _prefs;
    await prefs.setBool(_preferSyncedLyricsKey, enabled);
  }

  Future<bool> getPreferSyncedLyrics() async {
    final prefs = await _prefs;
    return prefs.getBool(_preferSyncedLyricsKey) ?? true;
  }

  Future<void> saveVolume(double volume) async {
    final prefs = await _prefs;
    await prefs.setDouble(_volumeKey, volume);
  }

  Future<double> getVolume() async {
    final prefs = await _prefs;
    return prefs.getDouble(_volumeKey) ?? 1.0;
  }

  Future<void> saveDiscordRpcEnabled(bool enabled) async {
    final prefs = await _prefs;
    await prefs.setBool('discord_rpc_enabled', enabled);
  }

  Future<bool> getDiscordRpcEnabled() async {
    final prefs = await _prefs;
    return prefs.getBool('discord_rpc_enabled') ?? true; 
  }

  Future<void> saveDiscordRpcStateStyle(String style) async {
    final prefs = await _prefs;
    await prefs.setString('discord_rpc_state_style', style);
  }

  Future<String> getDiscordRpcStateStyle() async {
    final prefs = await _prefs;
    return prefs.getString('discord_rpc_state_style') ?? 'artist';
  }

  Future<void> clearAll() async {
    final prefs = await _prefs;
    await prefs.clear();
  }

  // ── Dislike tracking ──

  static const String _dislikedSongsKey = 'disliked_songs';
  static const String _usernameKey = 'display_username';

  Future<void> saveUsername(String username) async {
    final prefs = await _prefs;
    await prefs.setString(_usernameKey, username);
  }

  Future<String?> getUsername() async {
    final prefs = await _prefs;
    return prefs.getString(_usernameKey);
  }

  Future<void> saveDislike(String songId, bool disliked) async {
    final prefs = await _prefs;
    final list = prefs.getStringList(_dislikedSongsKey) ?? [];
    if (disliked) {
      if (!list.contains(songId)) list.add(songId);
    } else {
      list.remove(songId);
    }
    await prefs.setStringList(_dislikedSongsKey, list);
  }

  Future<bool> isDisliked(String songId) async {
    final prefs = await _prefs;
    final disliked = prefs.getStringList(_dislikedSongsKey) ?? [];
    return disliked.contains(songId);
  }

  Future<List<String>> getDislikedSongIds() async {
    final prefs = await _prefs;
    return prefs.getStringList(_dislikedSongsKey) ?? [];
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Player Design Style
  // ──────────────────────────────────────────────────────────────────────────

  static const String _useYandexPlayerStyleKey = 'use_yandex_player_style';
  static const String _playerStyleKey = 'player_style';

  Future<bool> getUseYandexPlayerStyle() async {
    final prefs = await _prefs;
    return prefs.getBool(_useYandexPlayerStyleKey) ?? false;
  }

  Future<void> setUseYandexPlayerStyle(bool value) async {
    final prefs = await _prefs;
    await prefs.setBool(_useYandexPlayerStyleKey, value);
    if (value) await prefs.setString(_playerStyleKey, 'yandex');
  }

  Future<String> getPlayerStyle() async {
    final prefs = await _prefs;
    return prefs.getString(_playerStyleKey) ?? 'default';
  }

  Future<void> setPlayerStyle(String style) async {
    final prefs = await _prefs;
    await prefs.setString(_playerStyleKey, style);
    await prefs.setBool(_useYandexPlayerStyleKey, style == 'yandex');
  }
}
