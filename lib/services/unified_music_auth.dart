import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Unified music service authentication.
///
/// Supports two auth methods:
/// 1. Yandex OAuth (free account) — for recommendations, playlists, likes
/// 2. MTS ID (KION Music) — for premium features (for MTS subscribers)
///
/// Both methods use the same Yandex Music API backend.
enum MusicAuthProvider { yandex, mts, none }

/// Authentication status for each provider.
class AuthStatus {
  final bool isConnected;
  final bool isPremium;
  final String? username;
  final String? token;
  final DateTime? expiresAt;
  final String? error;

  const AuthStatus({
    this.isConnected = false,
    this.isPremium = false,
    this.username,
    this.token,
    this.expiresAt,
    this.error,
  });

  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);
}

/// Unified authentication service for Yandex Music API.
class UnifiedMusicAuth {
  static const _kYandexTokenKey = 'yandex_oauth_token';
  static const _kYandexRefreshTokenKey = 'yandex_refresh_token';
  static const _kYandexUsernameKey = 'yandex_username';
  static const _kYandexExpiresKey = 'yandex_token_expires';
  static const _kYandexPremiumKey = 'yandex_is_premium';

  static const _kMtsTokenKey = 'mts_id_token';
  static const _kMtsRefreshTokenKey = 'mts_refresh_token';
  static const _kMtsUsernameKey = 'mts_username';
  static const _kMtsExpiresKey = 'mts_token_expires';
  static const _kMtsPremiumKey = 'mts_is_premium';

  static const _kActiveProviderKey = 'active_music_provider';

  // Yandex OAuth credentials (public client)
  static const _yandexClientId = '23cabbbdc6b442b034acfc5f293569b6';
  static const _yandexClientSecret = '';

  // MTS Music API endpoints
  static const _mtsAuthUrl = 'https://api.music.yandex.net';
  static const _mtsTokenUrl = 'https://api.music.yandex.net/handlers/auth-mts.jsx';

  final Dio _dio;

  UnifiedMusicAuth({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options.connectTimeout = const Duration(seconds: 10);
    _dio.options.receiveTimeout = const Duration(seconds: 10);
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Status
  // ──────────────────────────────────────────────────────────────────────────

  /// Get current auth status for Yandex.
  Future<AuthStatus> getYandexStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_kYandexTokenKey);
    final username = prefs.getString(_kYandexUsernameKey);
    final expiresStr = prefs.getString(_kYandexExpiresKey);
    final isPremium = prefs.getBool(_kYandexPremiumKey) ?? false;

    if (token == null || token.isEmpty) {
      return const AuthStatus(isConnected: false);
    }

    DateTime? expires;
    if (expiresStr != null) {
      expires = DateTime.tryParse(expiresStr);
    }

    return AuthStatus(
      isConnected: true,
      isPremium: isPremium,
      username: username,
      token: token,
      expiresAt: expires,
    );
  }

  /// Get current auth status for MTS.
  Future<AuthStatus> getMtsStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_kMtsTokenKey);
    final username = prefs.getString(_kMtsUsernameKey);
    final expiresStr = prefs.getString(_kMtsExpiresKey);
    final isPremium = prefs.getBool(_kMtsPremiumKey) ?? false;

    if (token == null || token.isEmpty) {
      return const AuthStatus(isConnected: false);
    }

    DateTime? expires;
    if (expiresStr != null) {
      expires = DateTime.tryParse(expiresStr);
    }

    return AuthStatus(
      isConnected: true,
      isPremium: isPremium,
      username: username,
      token: token,
      expiresAt: expires,
    );
  }

  /// Get active provider.
  Future<MusicAuthProvider> getActiveProvider() async {
    final prefs = await SharedPreferences.getInstance();
    final providerStr = prefs.getString(_kActiveProviderKey);
    if (providerStr == null) return MusicAuthProvider.none;

    return MusicAuthProvider.values.firstWhere(
      (p) => p.name == providerStr,
      orElse: () => MusicAuthProvider.none,
    );
  }

  /// Set active provider.
  Future<void> setActiveProvider(MusicAuthProvider provider) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActiveProviderKey, provider.name);
  }

  /// Get the best available token (active provider or fallback).
  Future<String?> getBestToken() async {
    final activeProvider = await getActiveProvider();

    switch (activeProvider) {
      case MusicAuthProvider.yandex:
        final status = await getYandexStatus();
        return status.isConnected ? status.token : null;
      case MusicAuthProvider.mts:
        final status = await getMtsStatus();
        return status.isConnected ? status.token : null;
      case MusicAuthProvider.none:
        // Try any available token
        final yandexStatus = await getYandexStatus();
        if (yandexStatus.isConnected) return yandexStatus.token;
        final mtsStatus = await getMtsStatus();
        if (mtsStatus.isConnected) return mtsStatus.token;
        return null;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Yandex OAuth
  // ──────────────────────────────────────────────────────────────────────────

  /// Get Yandex OAuth URL for user to authorize.
  String getYandexOAuthUrl({required String redirectUri}) {
    return 'https://oauth.yandex.ru/authorize'
        '?response_type=token'
        '&client_id=$_yandexClientId'
        '&redirect_uri=${Uri.encodeComponent(redirectUri)}'
        '&force_confirm=yes';
  }

  /// Save Yandex OAuth token from redirect URL. Синхронизирует все хранилища.
  Future<bool> saveYandexToken({
    required String accessToken,
    String? refreshToken,
    String? username,
    int? expiresIn,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kYandexTokenKey, accessToken);
      // Совместимость с YandexMusicProvider и YandexMusicApi (десктоп-токен)
      await prefs.setString('yandex_music_oauth_token', accessToken);
      await prefs.setString('ym_access_token', accessToken);
      await prefs.setString('yandex_music_token', accessToken);

      if (refreshToken != null) {
        await prefs.setString(_kYandexRefreshTokenKey, refreshToken);
      }

      if (username != null) {
        await prefs.setString(_kYandexUsernameKey, username);
      }

      if (expiresIn != null) {
        final expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
        await prefs.setString(_kYandexExpiresKey, expiresAt.toIso8601String());
      }

      // Check premium status
      final isPremium = await _checkYandexPremium(accessToken);
      await prefs.setBool(_kYandexPremiumKey, isPremium);

      // Set as active if no other provider
      final currentProvider = await getActiveProvider();
      if (currentProvider == MusicAuthProvider.none) {
        await setActiveProvider(MusicAuthProvider.yandex);
      }

      debugPrint('[UnifiedAuth] Yandex token saved, premium: $isPremium (synced to provider keys)');
      return true;
    } catch (e) {
      debugPrint('[UnifiedAuth] Error saving Yandex token: $e');
      return false;
    }
  }

  /// Save Yandex token from existing source (e.g., exported from Yandex Music app).
  Future<bool> saveYandexTokenDirect(String token) async {
    return saveYandexToken(accessToken: token);
  }

  /// Check if Yandex account has premium.
  Future<bool> _checkYandexPremium(String token) async {
    try {
      final response = await _dio.get(
        'https://api.music.yandex.net/account/status',
        options: Options(
          headers: {'Authorization': 'OAuth $token'},
        ),
      );

      final result = response.data['result'];
      if (result == null) return false;

      final subscription = result['subscription'];
      if (subscription == null) return false;

      final status = subscription['status'] as String?;
      return status == 'paid' || status == 'trial';
    } catch (e) {
      debugPrint('[UnifiedAuth] Premium check error: $e');
      return false;
    }
  }

  /// Logout from Yandex. Чистит все ключи синхронизации.
  Future<void> logoutYandex() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kYandexTokenKey);
    await prefs.remove(_kYandexRefreshTokenKey);
    await prefs.remove(_kYandexUsernameKey);
    await prefs.remove(_kYandexExpiresKey);
    await prefs.remove(_kYandexPremiumKey);
    await prefs.remove('yandex_music_oauth_token');
    await prefs.remove('ym_access_token');
    await prefs.remove('yandex_music_token');

    final currentProvider = await getActiveProvider();
    if (currentProvider == MusicAuthProvider.yandex) {
      await setActiveProvider(MusicAuthProvider.none);
    }

    debugPrint('[UnifiedAuth] Yandex logged out (all keys cleared)');
  }

  // ──────────────────────────────────────────────────────────────────────────
  // MTS ID Auth
  // ──────────────────────────────────────────────────────────────────────────

  /// Get MTS ID OAuth URL for user to authorize.
  String getMtsAuthUrl({required String redirectUri}) {
    // MTS uses their own SSO system
    // This is a simplified version - actual MTS auth requires MTS ID SDK
    return 'https://login.mts.ru/auth/realms/mmts/protocol/openid-connect/auth'
        '?client_id=music-mobile'
        '&redirect_uri=${Uri.encodeComponent(redirectUri)}'
        '&response_type=code'
        '&scope=openid+profile+email';
  }

  /// Exchange MTS auth code for token.
  Future<bool> exchangeMtsCode({
    required String code,
    required String redirectUri,
  }) async {
    try {
      final response = await _dio.post(
        'https://login.mts.ru/auth/realms/mmts/protocol/openid-connect/token',
        data: {
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': redirectUri,
          'client_id': 'music-mobile',
        },
      );

      final accessToken = response.data['access_token'] as String?;
      final refreshToken = response.data['refresh_token'] as String?;
      final expiresIn = response.data['expires_in'] as int?;

      if (accessToken == null) return false;

      // Get MTS Music OAuth token
      final mtsTokenResponse = await _dio.get(
        '$_mtsTokenUrl',
        queryParameters: {'task_id': accessToken},
      );

      final mtsToken = mtsTokenResponse.data['access_token'] as String?;
      if (mtsToken == null) return false;

      return saveMtsToken(
        accessToken: mtsToken,
        refreshToken: refreshToken,
        username: 'MTS User',
        expiresIn: expiresIn,
      );
    } catch (e) {
      debugPrint('[UnifiedAuth] MTS code exchange error: $e');
      return false;
    }
  }

  /// Save MTS token.
  Future<bool> saveMtsToken({
    required String accessToken,
    String? refreshToken,
    String? username,
    int? expiresIn,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kMtsTokenKey, accessToken);

      if (refreshToken != null) {
        await prefs.setString(_kMtsRefreshTokenKey, refreshToken);
      }

      if (username != null) {
        await prefs.setString(_kMtsUsernameKey, username);
      }

      if (expiresIn != null) {
        final expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
        await prefs.setString(_kMtsExpiresKey, expiresAt.toIso8601String());
      }

      // MTS subscribers typically have premium
      await prefs.setBool(_kMtsPremiumKey, true);

      // Set as active if no other provider
      final currentProvider = await getActiveProvider();
      if (currentProvider == MusicAuthProvider.none) {
        await setActiveProvider(MusicAuthProvider.mts);
      }

      debugPrint('[UnifiedAuth] MTS token saved');
      return true;
    } catch (e) {
      debugPrint('[UnifiedAuth] Error saving MTS token: $e');
      return false;
    }
  }

  /// Save MTS token directly (for manual entry).
  Future<bool> saveMtsTokenDirect(String token) async {
    return saveMtsToken(accessToken: token);
  }

  /// Logout from MTS.
  Future<void> logoutMts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kMtsTokenKey);
    await prefs.remove(_kMtsRefreshTokenKey);
    await prefs.remove(_kMtsUsernameKey);
    await prefs.remove(_kMtsExpiresKey);
    await prefs.remove(_kMtsPremiumKey);

    final currentProvider = await getActiveProvider();
    if (currentProvider == MusicAuthProvider.mts) {
      await setActiveProvider(MusicAuthProvider.none);
    }

    debugPrint('[UnifiedAuth] MTS logged out');
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Token refresh
  // ──────────────────────────────────────────────────────────────────────────

  /// Refresh Yandex token.
  Future<bool> refreshYandexToken() async {
    final prefs = await SharedPreferences.getInstance();
    final refreshToken = prefs.getString(_kYandexRefreshTokenKey);

    if (refreshToken == null || refreshToken.isEmpty) {
      debugPrint('[UnifiedAuth] No Yandex refresh token');
      return false;
    }

    try {
      final response = await _dio.post(
        'https://oauth.yandex.ru/token',
        data: {
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'client_id': _yandexClientId,
        },
      );

      final accessToken = response.data['access_token'] as String?;
      final newRefreshToken = response.data['refresh_token'] as String?;
      final expiresIn = response.data['expires_in'] as int?;

      if (accessToken == null) return false;

      return saveYandexToken(
        accessToken: accessToken,
        refreshToken: newRefreshToken ?? refreshToken,
        expiresIn: expiresIn,
      );
    } catch (e) {
      debugPrint('[UnifiedAuth] Yandex token refresh error: $e');
      return false;
    }
  }

  /// Refresh MTS token.
  Future<bool> refreshMtsToken() async {
    final prefs = await SharedPreferences.getInstance();
    final refreshToken = prefs.getString(_kMtsRefreshTokenKey);

    if (refreshToken == null || refreshToken.isEmpty) {
      debugPrint('[UnifiedAuth] No MTS refresh token');
      return false;
    }

    try {
      final response = await _dio.post(
        'https://login.mts.ru/auth/realms/mmts/protocol/openid-connect/token',
        data: {
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'client_id': 'music-mobile',
        },
      );

      final accessToken = response.data['access_token'] as String?;
      final newRefreshToken = response.data['refresh_token'] as String?;
      final expiresIn = response.data['expires_in'] as int?;

      if (accessToken == null) return false;

      // Get MTS Music token
      final mtsTokenResponse = await _dio.get(
        '$_mtsTokenUrl',
        queryParameters: {'task_id': accessToken},
      );

      final mtsToken = mtsTokenResponse.data['access_token'] as String?;
      if (mtsToken == null) return false;

      return saveMtsToken(
        accessToken: mtsToken,
        refreshToken: newRefreshToken ?? refreshToken,
        expiresIn: expiresIn,
      );
    } catch (e) {
      debugPrint('[UnifiedAuth] MTS token refresh error: $e');
      return false;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Available features
  // ──────────────────────────────────────────────────────────────────────────

  /// Get available features based on current auth status.
  Future<Map<String, bool>> getAvailableFeatures() async {
    final yandexStatus = await getYandexStatus();
    final mtsStatus = await getMtsStatus();
    final activeProvider = await getActiveProvider();

    final hasYandex = yandexStatus.isConnected;
    final hasMts = mtsStatus.isConnected;
    final hasPremium = yandexStatus.isPremium || mtsStatus.isPremium;

    return {
      // Public API features (always available)
      'search': true,
      'artist_info': true,
      'similar_tracks': true,
      'cover_art': true,
      'lyrics': true,
      'new_releases': true,
      'genres': true,

      // Auth-required features
      'playlists': hasYandex || hasMts,
      'likes': hasYandex || hasMts,
      'playlist_of_day': hasYandex || hasMts,
      'my_wave': hasYandex || hasMts,
      'listening_history': hasYandex || hasMts,

      // Premium features
      'high_quality': hasPremium,
      'unlimited_skips': hasPremium,
      'offline_mode': hasPremium,
      'no_ads': hasPremium,

      // Provider status
      'yandex_connected': hasYandex,
      'yandex_premium': yandexStatus.isPremium,
      'mts_connected': hasMts,
      'mts_premium': mtsStatus.isPremium,
    };
  }
}
