import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Comprehensive Yandex Music API client.
///
/// Features:
/// - Device Flow OAuth authorization
/// - All endpoints from OpenAPI spec
/// - Token management with auto-refresh
/// - Both public and authenticated endpoints
class YandexMusicApi {
  // ──────────────────────────────────────────────────────────────────────────
  // Constants
  // ──────────────────────────────────────────────────────────────────────────

  static const _baseUrl = 'https://api.music.yandex.net';
  static const _coverBaseUrl = 'https://avatars.yandex.net';
  static const _oauthUrl = 'https://oauth.yandex.ru';
  static const _authApiUrl = 'https://oauth.mobile.yandex.net';

  // OAuth credentials (public client)
  static const _clientId = '23cabbbdc6cd418abb4b39c32c41195d';
  static const _clientSecret = '53bc75238f0c4d08a118e51fe9203300';

  // Device info (pretend to be Yandex Music app)
  static const _deviceId = '377c5ae26b09fccd72deae0a95425559';
  static const _uuid = '3cfccdaf75dcf98b917a54afe50447ba';
  static const _packageName = 'ru.yandex.music';

  // Storage keys
  static const _kTokenKey = 'ym_access_token';
  static const _kRefreshTokenKey = 'ym_refresh_token';
  static const _kUidKey = 'ym_uid';
  static const _kExpiresKey = 'ym_token_expires';
  static const _kUsernameKey = 'ym_username';

  final Dio _dio;
  String? _token;
  int? _uid;

  YandexMusicApi({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options.headers['User-Agent'] = 'KumaFlow/3.1';
    _dio.options.headers['Accept'] = 'application/json';
    // Required by Yandex Music API - identifies as Android client
    _dio.options.headers['X-Yandex-Music-Client'] = 'YandexMusicAndroid/24023621';
    _dio.options.connectTimeout = const Duration(seconds: 10);
    _dio.options.receiveTimeout = const Duration(seconds: 10);
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Authorization — Device Flow
  // ──────────────────────────────────────────────────────────────────────────

  /// Initialize with existing token.
  Future<void> init({String? token, int? uid}) async {
    if (token != null && uid != null) {
      _token = token;
      _uid = uid;
      return;
    }

    // Try to load from storage
    await _loadToken();
  }

  /// Device Flow OAuth — get authorization URL and code.
  ///
  /// Returns a [DeviceAuthResult] with:
  /// - `verificationUrl` — URL to open in browser
  /// - `userCode` — code to enter
  /// - `deviceCode` — for polling
  /// - `interval` — polling interval in seconds
  /// - `expiresIn` — expiration in seconds
  Future<DeviceAuthResult> startDeviceAuth() async {
    try {
      final response = await _dio.post(
        '$_authApiUrl/1/device/code',
        data: {
          'client_id': _clientId,
          'client_secret': _clientSecret,
          'device_id': _deviceId,
          'uuid': _uuid,
          'package_name': _packageName,
        },
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
        ),
      );

      final data = response.data as Map<String, dynamic>;

      return DeviceAuthResult(
        verificationUrl: data['verification_url'] as String? ?? 'https://passport.yandex.ru',
        userCode: data['user_code'] as String? ?? '',
        deviceCode: data['device_code'] as String? ?? '',
        interval: data['interval'] as int? ?? 5,
        expiresIn: data['expires_in'] as int? ?? 300,
      );
    } catch (e) {
      debugPrint('[YandexMusicApi] Device auth start error: $e');
      rethrow;
    }
  }

  /// Poll for token after user authorizes.
  Future<bool> pollDeviceAuth(String deviceCode) async {
    try {
      final response = await _dio.post(
        '$_authApiUrl/1/token',
        data: {
          'grant_type': 'device_code',
          'client_id': _clientId,
          'client_secret': _clientSecret,
          'device_code': deviceCode,
        },
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
        ),
      );

      final data = response.data as Map<String, dynamic>;

      if (data.containsKey('access_token')) {
        _token = data['access_token'] as String;
        _uid = data['uid'] as int?;

        // Save token
        await _saveToken(
          token: _token!,
          uid: _uid,
          expiresIn: data['expires_in'] as int?,
        );

        return true;
      }

      return false;
    } on DioException catch (e) {
      if (e.response?.statusCode == 400) {
        // Authorization pending or expired
        return false;
      }
      rethrow;
    }
  }

  /// Login with username and password (alternative to Device Flow).
  Future<bool> loginWithPassword({
    required String username,
    required String password,
  }) async {
    try {
      final response = await _dio.post(
        '$_oauthUrl/token',
        data: {
          'grant_type': 'password',
          'username': username,
          'password': password,
          'client_id': _clientId,
          'client_secret': _clientSecret,
        },
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
        ),
      );

      final data = response.data as Map<String, dynamic>;

      if (data.containsKey('access_token')) {
        _token = data['access_token'] as String;
        _uid = data['uid'] as int?;

        await _saveToken(
          token: _token!,
          uid: _uid,
          expiresIn: data['expires_in'] as int?,
        );

        return true;
      }

      return false;
    } catch (e) {
      debugPrint('[YandexMusicApi] Password login error: $e');
      return false;
    }
  }

  /// Save token manually (from external source).
  Future<void> saveTokenManual(String token, {int? uid}) async {
    _token = token;
    _uid = uid;
    await _saveToken(token: token, uid: uid);
  }

  /// Refresh access token.
  Future<bool> refreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    final refreshToken = prefs.getString(_kRefreshTokenKey);

    if (refreshToken == null || refreshToken.isEmpty) {
      debugPrint('[YandexMusicApi] No refresh token available');
      return false;
    }

    try {
      final response = await _dio.post(
        '$_oauthUrl/token',
        data: {
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'client_id': _clientId,
        },
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
        ),
      );

      final data = response.data as Map<String, dynamic>;

      if (data.containsKey('access_token')) {
        _token = data['access_token'] as String;
        _uid = data['uid'] as int? ?? _uid;

        await _saveToken(
          token: _token!,
          uid: _uid,
          refreshToken: data['refresh_token'] as String? ?? refreshToken,
          expiresIn: data['expires_in'] as int?,
        );

        return true;
      }

      return false;
    } catch (e) {
      debugPrint('[YandexMusicApi] Token refresh error: $e');
      return false;
    }
  }

  /// Logout and clear stored token.
  Future<void> logout() async {
    _token = null;
    _uid = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kTokenKey);
    await prefs.remove(_kRefreshTokenKey);
    await prefs.remove(_kUidKey);
    await prefs.remove(_kExpiresKey);
    await prefs.remove(_kUsernameKey);
  }

  /// Check if user is authenticated.
  bool get isAuthenticated => _token != null && _token!.isNotEmpty;

  /// Get current user UID.
  int? get uid => _uid;

  // ──────────────────────────────────────────────────────────────────────────
  // Token management
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    // Try all known keys
    _token = prefs.getString(_kTokenKey) 
        ?? prefs.getString('yandex_music_oauth_token')
        ?? prefs.getString('yandex_oauth_token');
    _uid = prefs.getInt(_kUidKey);

    debugPrint('[YandexMusicApi] Loaded token: ${_token != null ? "yes (${_token!.substring(0, 10)}...)" : "no"}');

    // Check if token is expired
    final expiresStr = prefs.getString(_kExpiresKey);
    if (expiresStr != null) {
      final expires = DateTime.tryParse(expiresStr);
      if (expires != null && DateTime.now().isAfter(expires)) {
        debugPrint('[YandexMusicApi] Token expired, attempting refresh');
        await refreshToken();
      }
    }
  }

  Future<void> _saveToken({
    required String token,
    int? uid,
    String? refreshToken,
    int? expiresIn,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTokenKey, token);

    if (uid != null) {
      await prefs.setInt(_kUidKey, uid);
    }

    if (refreshToken != null) {
      await prefs.setString(_kRefreshTokenKey, refreshToken);
    }

    if (expiresIn != null) {
      final expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
      await prefs.setString(_kExpiresKey, expiresAt.toIso8601String());
    }
  }

  Map<String, String> get _authHeaders => {
    if (_token != null) 'Authorization': 'OAuth $_token',
  };

  // ──────────────────────────────────────────────────────────────────────────
  // Cover Art
  // ──────────────────────────────────────────────────────────────────────────

  String? getCoverUrl(String uri, {int size = 300}) {
    if (uri.isEmpty) return null;
    if (uri.startsWith('http')) return '$uri?size=$size';
    return '$_coverBaseUrl/$uri?size=$size';
  }

  String? extractCoverUrl(dynamic coverData) {
    if (coverData == null) return null;
    if (coverData is String) return getCoverUrl(coverData);
    if (coverData is Map<String, dynamic>) {
      final uri = coverData['uri'] as String?;
      if (uri != null) return getCoverUrl(uri);
      final small = coverData['small'] as String?;
      if (small != null) return getCoverUrl(small);
      final mini = coverData['mini'] as String?;
      if (mini != null) return getCoverUrl(mini);
    }
    return null;
  }

  String? extractTrackCoverUrl(Map<String, dynamic>? track) {
    if (track == null) return null;
    for (final size in ['cover1200', 'cover400', 'cover200']) {
      final uri = track[size] as String?;
      if (uri != null && uri.isNotEmpty) return getCoverUrl(uri);
    }
    final albums = track['albums'] as List?;
    if (albums != null && albums.isNotEmpty) {
      final first = albums.first as Map<String, dynamic>?;
      final coverUri = first?['coverUri'] as String?;
      if (coverUri != null) return getCoverUrl(coverUri);
    }
    return null;
  }

  String? extractArtistId(Map<String, dynamic>? track) {
    if (track == null) return null;
    final artists = track['artists'] as List?;
    if (artists != null && artists.isNotEmpty) {
      return (artists.first as Map<String, dynamic>?)?['id']?.toString();
    }
    return null;
  }

  String? extractArtistName(Map<String, dynamic>? track) {
    if (track == null) return null;
    final artists = track['artists'] as List?;
    if (artists != null && artists.isNotEmpty) {
      return (artists.first as Map<String, dynamic>?)?['name'] as String?;
    }
    return null;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Account
  // ──────────────────────────────────────────────────────────────────────────

  /// GET /account/status — Get account status.
  Future<Map<String, dynamic>?> getAccountStatus() async {
    if (!isAuthenticated) return null;
    try {
      final response = await _dio.get(
        '$_baseUrl/account/status',
        options: Options(headers: _authHeaders),
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexMusicApi] Account status error: $e');
      return null;
    }
  }

  /// GET /account/settings — Get account settings.
  Future<Map<String, dynamic>?> getAccountSettings() async {
    if (!isAuthenticated) return null;
    try {
      final response = await _dio.get(
        '$_baseUrl/account/settings',
        options: Options(headers: _authHeaders),
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexMusicApi] Account settings error: $e');
      return null;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Search
  // ──────────────────────────────────────────────────────────────────────────

  /// GET /search — Search artists, tracks, albums.
  Future<Map<String, dynamic>?> search(
    String query, {
    String type = 'all',
    int page = 0,
    bool nocorrect = false,
    int? pageSize,
  }) async {
    try {
      final params = <String, String>{
        'text': query,
        'type': type,
        'page': page.toString(),
        'nocorrect': nocorrect.toString(),
      };
      if (pageSize != null) params['pageSize'] = pageSize.toString();

      final response = await _dio.get(
        '$_baseUrl/search',
        queryParameters: params,
        options: Options(headers: _authHeaders),
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexMusicApi] Search error: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> searchArtists(String query, {int limit = 10}) async {
    final result = await search(query, type: 'artist');
    return ((result?['artists']?['results'] as List?) ?? []).take(limit).cast<Map<String, dynamic>>().toList();
  }

  Future<List<Map<String, dynamic>>> searchAlbums(String query, {int limit = 10}) async {
    final result = await search(query, type: 'album');
    return ((result?['albums']?['results'] as List?) ?? []).take(limit).cast<Map<String, dynamic>>().toList();
  }

  Future<List<Map<String, dynamic>>> searchTracks(String query, {int limit = 10}) async {
    final result = await search(query, type: 'track');
    return ((result?['tracks']?['results'] as List?) ?? []).take(limit).cast<Map<String, dynamic>>().toList();
  }

  /// GET /search/suggest — Search suggestions.
  Future<List<String>> searchSuggest(String part) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/search/suggest',
        queryParameters: {'part': part},
        options: Options(headers: _authHeaders),
      );
      final result = response.data['result'];
      if (result == null) return [];
      final suggestions = result['suggestions'] as List? ?? [];
      return suggestions.cast<String>().toList();
    } catch (e) {
      debugPrint('[YandexMusicApi] Search suggest error: $e');
      return [];
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Genres
  // ──────────────────────────────────────────────────────────────────────────

  /// GET /genres — Get list of music genres.
  Future<List<Map<String, dynamic>>> getGenres() async {
    try {
      final response = await _dio.get(
        '$_baseUrl/genres',
        options: Options(headers: _authHeaders),
      );
      final result = response.data['result'];
      if (result == null) return [];
      return (result as List? ?? []).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexMusicApi] Genres error: $e');
      return [];
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Radio / Rotor
  // ──────────────────────────────────────────────────────────────────────────

  /// Get tracks for a genre — tries Radio API first, falls back to search.
  ///
  /// [genreId] like 'rock', 'metal', 'jazz', etc.
  /// Returns up to 50 tracks.
  Future<List<Map<String, dynamic>>> getGenreTracks(String genreId) async {
    // Strategy 1: Try Radio API
    try {
      final radioTracks = await _getRadioTracks('genre:$genreId');
      if (radioTracks.isNotEmpty) return radioTracks;
    } catch (e) {
      debugPrint('[YandexMusicApi] Radio fallback needed: $e');
    }

    // Strategy 2: Search by genre name + get similar tracks
    return _getTracksBySearch(genreId);
  }

  /// Radio API endpoint.
  Future<List<Map<String, dynamic>>> _getRadioTracks(String stationId) async {
    final url = '$_baseUrl/rotor/station/$stationId/tracks';
    final response = await _dio.get(
      url,
      options: Options(headers: _authHeaders),
    );
    final result = response.data['result'];
    if (result == null || result['sequence'] == null) return [];
    final sequence = result['sequence'] as List? ?? [];
    return sequence
        .where((item) => item['track'] != null)
        .map((item) => item['track'] as Map<String, dynamic>)
        .toList();
  }

  /// Fallback: search for tracks by genre keywords + get similar tracks.
  Future<List<Map<String, dynamic>>> _getTracksBySearch(String genreId) async {
    // Map genre IDs to search keywords
    final keywords = {
      'rock': 'rock music hits',
      'metal': 'metal music',
      'jazz': 'jazz music',
      'pop': 'pop music hits',
      'electronic': 'electronic music',
      'rap': 'hip hop rap',
      'alternative': 'alternative rock',
      'indie': 'indie music',
      'classical': 'classical music',
      'blues': 'blues music',
      'reggae': 'reggae music',
      'country': 'country music',
      'punk': 'punk rock',
    };

    final query = keywords[genreId] ?? '$genreId music';
    final allTracks = <Map<String, dynamic>>[];
    final seenIds = <String>{};

    try {
      // Search for tracks
      final response = await _dio.get(
        '$_baseUrl/search',
        queryParameters: {'text': query, 'type': 'track'},
        options: Options(headers: _authHeaders),
      );
      final results = response.data['result'];
      if (results != null && results['tracks'] != null) {
        final tracks = results['tracks']['results'] as List? ?? [];
        for (final track in tracks) {
          final id = track['id']?.toString();
          if (id != null && !seenIds.contains(id)) {
            seenIds.add(id);
            allTracks.add(track);
          }
        }
      }
    } catch (e) {
      debugPrint('[YandexMusicApi] Search fallback error: $e');
    }

    // Get similar tracks for first few tracks to expand the list
    if (allTracks.length < 20 && allTracks.isNotEmpty) {
      for (final track in allTracks.take(3)) {
        try {
          final trackId = track['id']?.toString();
          if (trackId == null) continue;
          final similarResp = await _dio.get(
            '$_baseUrl/tracks/$trackId/similar',
            options: Options(headers: _authHeaders),
          );
          final similarResult = similarResp.data['result'];
          if (similarResult != null && similarResult['similarTracks'] != null) {
            final similar = similarResult['similarTracks'] as List? ?? [];
            for (final s in similar) {
              final id = s['id']?.toString();
              if (id != null && !seenIds.contains(id)) {
                seenIds.add(id);
                allTracks.add(s);
              }
            }
          }
        } catch (e) {
          // Skip on error
        }
      }
    }

    debugPrint('[YandexMusicApi] Search fallback: ${allTracks.length} tracks for $genreId');
    return allTracks;
  }

  /// GET /rotor/stations/list — Get all available radio stations.
  Future<List<Map<String, dynamic>>> getRadioStations() async {
    try {
      final response = await _dio.get(
        '$_baseUrl/rotor/stations/list',
        options: Options(headers: _authHeaders),
      );
      final result = response.data['result'];
      if (result == null) return [];
      return (result as List? ?? []).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexMusicApi] Radio stations error: $e');
      return [];
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Tracks
  // ──────────────────────────────────────────────────────────────────────────

  /// POST /tracks — Get tracks by IDs.
  Future<List<Map<String, dynamic>>> getTracks(List<String> trackIds) async {
    if (trackIds.isEmpty) return [];
    try {
      final response = await _dio.post(
        '$_baseUrl/tracks',
        data: {'track-ids': trackIds},
        queryParameters: {'with-positions': 'true'},
        options: Options(headers: _authHeaders),
      );
      final result = response.data['result'];
      if (result == null) return [];
      return (result as List? ?? []).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexMusicApi] Get tracks error: $e');
      return [];
    }
  }

  /// GET /tracks/{trackId}/similar — Get similar tracks.
  Future<List<Map<String, dynamic>>> getSimilarTracks(String trackId, {int limit = 10}) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/tracks/$trackId/similar',
        options: Options(headers: _authHeaders),
      );
      final result = response.data['result'];
      if (result == null) return [];
      final similar = result['similarTracks'] as List? ?? [];
      return similar.take(limit).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexMusicApi] Similar tracks error: $e');
      return [];
    }
  }

  /// GET /tracks/{trackId}/lyrics — Get track lyrics.
  Future<Map<String, dynamic>?> getTrackLyrics(String trackId) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/tracks/$trackId/lyrics',
        options: Options(headers: _authHeaders),
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexMusicApi] Track lyrics error: $e');
      return null;
    }
  }

  /// GET /tracks/{trackId}/supplement — Get track supplement (extra info).
  Future<Map<String, dynamic>?> getTrackSupplement(String trackId) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/tracks/$trackId/supplement',
        options: Options(headers: _authHeaders),
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexMusicApi] Track supplement error: $e');
      return null;
    }
  }

  /// GET /tracks/{trackId}/download-info — Get track download info.
  Future<List<Map<String, dynamic>>> getTrackDownloadInfo(String trackId) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/tracks/$trackId/download-info',
        options: Options(headers: _authHeaders),
      );
      final result = response.data['result'];
      if (result == null) return [];
      return (result as List? ?? []).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexMusicApi] Track download info error: $e');
      return [];
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Artists
  // ──────────────────────────────────────────────────────────────────────────

  /// GET /artists/{artistId}/brief-info — Get artist brief info.
  Future<Map<String, dynamic>?> getArtistInfo(String artistId) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/artists/$artistId/brief-info',
        options: Options(headers: _authHeaders),
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexMusicApi] Artist info error: $e');
      return null;
    }
  }

  /// GET /artists/{artistId}/top-tracks — Get artist top tracks.
  Future<List<Map<String, dynamic>>> getArtistTopTracks(String artistId, {int limit = 10}) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/artists/$artistId/top-tracks',
        queryParameters: {'chart': 'all-time'},
        options: Options(headers: _authHeaders),
      );
      final result = response.data['result'];
      if (result == null) return [];
      final tracks = result['tracks'] as List? ?? [];
      return tracks.take(limit).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexMusicApi] Artist top tracks error: $e');
      return [];
    }
  }

  /// GET /artists/{artistId}/tracks — Get artist tracks with pagination.
  Future<Map<String, dynamic>?> getArtistTracks(String artistId, {int page = 0, int? pageSize}) async {
    try {
      final params = <String, String>{'page': page.toString()};
      if (pageSize != null) params['pageSize'] = pageSize.toString();

      final response = await _dio.get(
        '$_baseUrl/artists/$artistId/tracks',
        queryParameters: params,
        options: Options(headers: _authHeaders),
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexMusicApi] Artist tracks error: $e');
      return null;
    }
  }

  /// GET /artists/{artistId}/direct-albums — Get artist albums.
  Future<List<Map<String, dynamic>>> getArtistAlbums(String artistId, {int page = 0, int pageSize = 10, String sortBy = 'year'}) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/artists/$artistId/direct-albums',
        queryParameters: {
          'page': page.toString(),
          'page-size': pageSize.toString(),
          'sort-by': sortBy,
        },
        options: Options(headers: _authHeaders),
      );
      final result = response.data['result'];
      if (result == null) return [];
      final albums = result['albums'] as List? ?? [];
      return albums.cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexMusicApi] Artist albums error: $e');
      return [];
    }
  }

  /// GET /artists/{artistId}/also-albums — Get artist also-albums (collections).
  Future<List<Map<String, dynamic>>> getArtistAlsoAlbums(String artistId, {int page = 0, int pageSize = 10}) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/artists/$artistId/also-albums',
        queryParameters: {
          'page': page.toString(),
          'page-size': pageSize.toString(),
          'sort-by': 'year',
        },
        options: Options(headers: _authHeaders),
      );
      final result = response.data['result'];
      if (result == null) return [];
      final albums = result['albums'] as List? ?? [];
      return albums.cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexMusicApi] Artist also-albums error: $e');
      return [];
    }
  }

  /// GET /artists/{artistId}/similar — Get similar artists.
  Future<List<Map<String, dynamic>>> getSimilarArtists(String artistId, {int limit = 10}) async {
    try {
      final info = await getArtistInfo(artistId);
      if (info == null) return [];
      final similar = info['similarArtists'] as List? ?? [];
      return similar.take(limit).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexMusicApi] Similar artists error: $e');
      return [];
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Albums
  // ──────────────────────────────────────────────────────────────────────────

  /// GET /albums/{albumId} — Get album info.
  Future<Map<String, dynamic>?> getAlbumInfo(String albumId, {bool withTracks = false}) async {
    try {
      final path = withTracks ? '/albums/$albumId/with-tracks' : '/albums/$albumId';
      final response = await _dio.get(
        '$_baseUrl$path',
        options: Options(headers: _authHeaders),
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexMusicApi] Album info error: $e');
      return null;
    }
  }

  /// POST /albums — Get albums by IDs.
  Future<List<Map<String, dynamic>>> getAlbumsByIds(List<String> albumIds) async {
    if (albumIds.isEmpty) return [];
    try {
      final response = await _dio.post(
        '$_baseUrl/albums',
        data: {'album-ids': albumIds.join(',')},
        options: Options(headers: _authHeaders),
      );
      final result = response.data['result'];
      if (result == null) return [];
      return (result as List? ?? []).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexMusicApi] Albums by IDs error: $e');
      return [];
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Landing / Feed
  // ──────────────────────────────────────────────────────────────────────────

  /// GET /landing3 — Get landing page blocks.
  Future<Map<String, dynamic>?> getLanding({String? blocks}) async {
    try {
      final params = <String, String>{};
      if (blocks != null) params['blocks'] = blocks;

      final response = await _dio.get(
        '$_baseUrl/landing3',
        queryParameters: params.isNotEmpty ? params : null,
        options: Options(headers: _authHeaders),
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexMusicApi] Landing error: $e');
      return null;
    }
  }

  /// GET /landing3/new-releases — Get new releases.
  Future<Map<String, dynamic>?> getNewReleases() async {
    try {
      final response = await _dio.get(
        '$_baseUrl/landing3/new-releases',
        options: Options(headers: _authHeaders),
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexMusicApi] New releases error: $e');
      return null;
    }
  }

  /// GET /landing3/new-playlists — Get new playlists.
  Future<Map<String, dynamic>?> getNewPlaylists() async {
    try {
      final response = await _dio.get(
        '$_baseUrl/landing3/new-playlists',
        options: Options(headers: _authHeaders),
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexMusicApi] New playlists error: $e');
      return null;
    }
  }

  /// GET /landing3/chart/{type} — Get chart (russia/world).
  Future<Map<String, dynamic>?> getChart({String type = 'russia'}) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/landing3/chart/$type',
        options: Options(headers: _authHeaders),
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexMusicApi] Chart error: $e');
      return null;
    }
  }

  /// GET /landing3/podcasts — Get podcasts.
  Future<Map<String, dynamic>?> getPodcasts() async {
    try {
      final response = await _dio.get(
        '$_baseUrl/landing3/podcasts',
        options: Options(headers: _authHeaders),
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexMusicApi] Podcasts error: $e');
      return null;
    }
  }

  /// GET /feed — Get user feed (requires auth).
  Future<Map<String, dynamic>?> getFeed() async {
    if (!isAuthenticated) return null;
    try {
      final response = await _dio.get(
        '$_baseUrl/feed',
        options: Options(headers: _authHeaders),
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexMusicApi] Feed error: $e');
      return null;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Playlists (auth required)
  // ──────────────────────────────────────────────────────────────────────────

  /// GET /users/{userId}/playlists/list — Get user playlists.
  Future<List<Map<String, dynamic>>> getUserPlaylists({int? userId}) async {
    if (!isAuthenticated) return [];
    final uid = userId ?? _uid;
    try {
      final response = await _dio.get(
        '$_baseUrl/users/$uid/playlists/list',
        options: Options(headers: _authHeaders),
      );
      final result = response.data['result'];
      if (result == null) return [];
      return (result as List? ?? []).cast<Map<String, dynamic>>().toList();
    } catch (e) {
      debugPrint('[YandexMusicApi] User playlists error: $e');
      return [];
    }
  }

  /// GET /users/{userId}/playlists/{kind} — Get playlist with tracks.
  Future<Map<String, dynamic>?> getPlaylist(String kind, {int? userId}) async {
    if (!isAuthenticated) return null;
    final uid = userId ?? _uid;
    try {
      final response = await _dio.get(
        '$_baseUrl/users/$uid/playlists/$kind',
        options: Options(headers: _authHeaders),
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexMusicApi] Playlist error: $e');
      return null;
    }
  }

  /// POST /users/{userId}/playlists/create — Create playlist.
  Future<Map<String, dynamic>?> createPlaylist(String title, {String visibility = 'private'}) async {
    if (!isAuthenticated) return null;
    try {
      final response = await _dio.post(
        '$_baseUrl/users/$_uid/playlists/create',
        data: {
          'title': title,
          'visibility': visibility,
        },
        options: Options(headers: _authHeaders),
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexMusicApi] Create playlist error: $e');
      return null;
    }
  }

  /// POST /users/{userId}/playlists/{kind}/delete — Delete playlist.
  Future<bool> deletePlaylist(String kind) async {
    if (!isAuthenticated) return false;
    try {
      await _dio.post(
        '$_baseUrl/users/$_uid/playlists/$kind/delete',
        options: Options(headers: _authHeaders),
      );
      return true;
    } catch (e) {
      debugPrint('[YandexMusicApi] Delete playlist error: $e');
      return false;
    }
  }

  /// POST /users/{userId}/playlists/{kind}/name — Rename playlist.
  Future<bool> renamePlaylist(String kind, String name) async {
    if (!isAuthenticated) return false;
    try {
      await _dio.post(
        '$_baseUrl/users/$_uid/playlists/$kind/name',
        data: {'value': name},
        options: Options(headers: _authHeaders),
      );
      return true;
    } catch (e) {
      debugPrint('[YandexMusicApi] Rename playlist error: $e');
      return false;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Likes (auth required)
  // ──────────────────────────────────────────────────────────────────────────

  /// GET /users/{userId}/likes/tracks — Get liked tracks.
  Future<List<String>> getLikedTracks() async {
    if (!isAuthenticated) return [];
    try {
      final response = await _dio.get(
        '$_baseUrl/users/$_uid/likes/tracks',
        options: Options(headers: _authHeaders),
      );
      final result = response.data['result'];
      if (result == null) return [];
      final library = result['library'] as Map<String, dynamic>?;
      if (library == null) return [];
      final tracks = library['tracks'] as List? ?? [];
      return tracks.map((t) => t['id']?.toString() ?? '').where((id) => id.isNotEmpty).toList();
    } catch (e) {
      debugPrint('[YandexMusicApi] Liked tracks error: $e');
      return [];
    }
  }

  /// POST /users/{userId}/likes/tracks/add-multiple — Like tracks.
  Future<bool> likeTracks(List<String> trackIds) async {
    if (!isAuthenticated || trackIds.isEmpty) return false;
    try {
      await _dio.post(
        '$_baseUrl/users/$_uid/likes/tracks/add-multiple',
        data: {'track-ids': trackIds},
        options: Options(headers: _authHeaders),
      );
      return true;
    } catch (e) {
      debugPrint('[YandexMusicApi] Like tracks error: $e');
      return false;
    }
  }

  /// POST /users/{userId}/likes/tracks/remove — Unlike tracks.
  Future<bool> unlikeTracks(List<String> trackIds) async {
    if (!isAuthenticated || trackIds.isEmpty) return false;
    try {
      await _dio.post(
        '$_baseUrl/users/$_uid/likes/tracks/remove',
        data: {'track-ids': trackIds},
        options: Options(headers: _authHeaders),
      );
      return true;
    } catch (e) {
      debugPrint('[YandexMusicApi] Unlike tracks error: $e');
      return false;
    }
  }

  /// GET /users/{userId}/dislikes/tracks — Get disliked tracks.
  Future<List<String>> getDislikedTracks() async {
    if (!isAuthenticated) return [];
    try {
      final response = await _dio.get(
        '$_baseUrl/users/$_uid/dislikes/tracks',
        options: Options(headers: _authHeaders),
      );
      final result = response.data['result'];
      if (result == null) return [];
      final tracks = result['library']?['tracks'] as List? ?? [];
      return tracks.map((t) => t['id']?.toString() ?? '').where((id) => id.isNotEmpty).toList();
    } catch (e) {
      debugPrint('[YandexMusicApi] Disliked tracks error: $e');
      return [];
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Tags
  // ──────────────────────────────────────────────────────────────────────────

  /// GET /tags/{tagId}/playlist-ids — Get playlists by tag.
  Future<Map<String, dynamic>?> getPlaylistsByTag(String tagId) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/tags/$tagId/playlist-ids',
        options: Options(headers: _authHeaders),
      );
      return response.data['result'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[YandexMusicApi] Playlists by tag error: $e');
      return null;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Wizard
  // ──────────────────────────────────────────────────────────────────────────

  /// GET /feed/wizard/is-passed — Check if wizard is passed.
  Future<bool> isWizardPassed() async {
    if (!isAuthenticated) return false;
    try {
      final response = await _dio.get(
        '$_baseUrl/feed/wizard/is-passed',
        options: Options(headers: _authHeaders),
      );
      final result = response.data['result'];
      return result?['isWizardPassed'] == true;
    } catch (e) {
      debugPrint('[YandexMusicApi] Wizard check error: $e');
      return false;
    }
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Models
// ──────────────────────────────────────────────────────────────────────────────

/// Device Flow authorization result.
class DeviceAuthResult {
  final String verificationUrl;
  final String userCode;
  final String deviceCode;
  final int interval;
  final int expiresIn;

  const DeviceAuthResult({
    required this.verificationUrl,
    required this.userCode,
    required this.deviceCode,
    required this.interval,
    required this.expiresIn,
  });
}
