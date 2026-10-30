import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service to manage favorite playlists
/// Stores favorite playlist IDs locally using SharedPreferences
class FavoritePlaylistsService extends ChangeNotifier {
  static const String _prefsKey = 'favorite_playlist_ids';
  
  final Set<String> _favoriteIds = {};
  bool _initialized = false;
  
  static final FavoritePlaylistsService _instance = FavoritePlaylistsService._internal();
  factory FavoritePlaylistsService() => _instance;
  FavoritePlaylistsService._internal();
  
  /// Initialize the service and load saved favorites
  Future<void> initialize() async {
    if (_initialized) return;
    
    final prefs = await SharedPreferences.getInstance();
    final savedIds = prefs.getStringList(_prefsKey);
    if (savedIds != null) {
      _favoriteIds.addAll(savedIds);
    }
    _initialized = true;
    notifyListeners();
  }
  
  /// Check if a playlist is marked as favorite
  bool isFavorite(String playlistId) {
    return _favoriteIds.contains(playlistId);
  }
  
  /// Toggle favorite status for a playlist
  Future<void> toggleFavorite(String playlistId) async {
    if (_favoriteIds.contains(playlistId)) {
      _favoriteIds.remove(playlistId);
    } else {
      _favoriteIds.add(playlistId);
    }
    
    await _saveFavorites();
    notifyListeners();
  }
  
  /// Add a playlist to favorites
  Future<void> addFavorite(String playlistId) async {
    if (!_favoriteIds.contains(playlistId)) {
      _favoriteIds.add(playlistId);
      await _saveFavorites();
      notifyListeners();
    }
  }
  
  /// Remove a playlist from favorites
  Future<void> removeFavorite(String playlistId) async {
    if (_favoriteIds.contains(playlistId)) {
      _favoriteIds.remove(playlistId);
      await _saveFavorites();
      notifyListeners();
    }
  }
  
  /// Get all favorite playlist IDs
  List<String> getFavoriteIds() {
    return List.unmodifiable(_favoriteIds);
  }
  
  /// Get the count of favorite playlists
  int get favoriteCount => _favoriteIds.length;
  
  /// Check if there are any favorite playlists
  bool get hasFavorites => _favoriteIds.isNotEmpty;
  
  /// Save favorites to SharedPreferences
  Future<void> _saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, _favoriteIds.toList());
  }
  
  /// Clear all favorites (for testing/debugging)
  Future<void> clearAll() async {
    _favoriteIds.clear();
    await _saveFavorites();
    notifyListeners();
  }
}
