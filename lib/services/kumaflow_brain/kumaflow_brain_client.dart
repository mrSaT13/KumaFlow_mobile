import 'package:dio/dio.dart';

class KumaFlowBrainException implements Exception {
  final String message;
  final int? statusCode;
  KumaFlowBrainException(this.message, [this.statusCode]);
  @override
  String toString() => 'KumaFlowBrainException($statusCode): $message';
}

/// Тонкий HTTP-клиент к mlbrainKF. Без состояния, без синглтонов.
/// Все пути — от baseUrl, полный список в http://<сервер>:3030/api/docs.
/// Если на сервере задан BRAIN_API_TOKEN — слать его через authToken.
/// Пароль Navidrome НЕ храним: мобила уже залогинена в Navidrome,
/// KumaFlow Brain отдаём только username + external_id треков.
class KumaFlowBrainClient {
  final String baseUrl;
  final String? authToken;
  final Dio _dio;

  KumaFlowBrainClient(this.baseUrl, {Dio? dio, this.authToken})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 15),
              headers: {
                'Content-Type': 'application/json',
                if (authToken != null && authToken.isNotEmpty)
                  'Authorization': 'Bearer $authToken',
              },
            ));

  String get _b => baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  Future<Map<String, dynamic>> _get(String path,
      [Map<String, dynamic>? query, Duration? receiveTimeout]) async {
    try {
      final r = await _dio.get('$_b$path',
          queryParameters: query,
          options: receiveTimeout == null
              ? null
              : Options(receiveTimeout: receiveTimeout));
      return _asMap(r.data);
    } on DioException catch (e) {
      throw KumaFlowBrainException(_dioMsg(e), e.response?.statusCode);
    }
  }

  Future<Map<String, dynamic>> _post(String path, [Object? body]) async {
    try {
      final r = await _dio.post('$_b$path', data: body ?? {});
      return _asMap(r.data);
    } on DioException catch (e) {
      throw KumaFlowBrainException(_dioMsg(e), e.response?.statusCode);
    }
  }

  Future<Map<String, dynamic>> _delete(String path) async {
    try {
      final r = await _dio.delete('$_b$path');
      return _asMap(r.data);
    } on DioException catch (e) {
      throw KumaFlowBrainException(_dioMsg(e), e.response?.statusCode);
    }
  }

  Future<Map<String, dynamic>> _put(String path, [Object? body]) async {
    try {
      final r = await _dio.put('$_b$path', data: body ?? {});
      return _asMap(r.data);
    } on DioException catch (e) {
      throw KumaFlowBrainException(_dioMsg(e), e.response?.statusCode);
    }
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return {'data': data};
  }

  String _dioMsg(DioException e) {
    final d = e.response?.data;
    if (d is Map && d['error'] != null) return d['error'].toString();
    if (d is Map && d['detail'] != null) return d['detail'].toString();
    return e.message ?? e.toString();
  }

  /// Быстрая проверка доступности (docs всегда есть).
  Future<bool> ping() async {
    try {
      final r = await _dio.get('$_b/api/docs',
          options: Options(receiveTimeout: const Duration(seconds: 5)));
      return (r.statusCode ?? 500) < 500;
    } catch (_) {
      return false;
    }
  }

  // ---------- users ----------
  Future<Map<String, dynamic>> byCredentials(String username, String password,
      {bool remember = false}) {
    return _post('/api/users/by-credentials',
        {'username': username, 'password': password, 'remember': remember});
  }

  Future<Map<String, dynamic>> syncFromMobile(
      String userId, Map<String, dynamic> payload) {
    return _post('/api/users/$userId/sync-from-mobile', payload);
  }

  // ---------- taste sync pull (tombstones, v0.3.0) ----------
  /// Слепок сервера для мобилы + удаления новее курсора.
  /// since — server_now из прошлого ответа; без него только added.
  /// Ответ: {likedSongs, dislikedSongs, bannedArtists, ...,
  /// removed[{kind, key, aux, deleted_at}], server_now}.
  /// kind: ban = разбан (key=artist_name, aux=artist_external_id),
  /// like/dislike = снятие оценки (key=external_id трека).
  Future<Map<String, dynamic>> syncToMobile(String userId,
      {String? since}) {
    return _get('/api/users/$userId/sync-to-mobile', {
      if (since != null && since.trim().isNotEmpty) 'since': since.trim(),
    });
  }

  Future<Map<String, dynamic>> postEvents(
      String userId, List<Map<String, dynamic>> events) {
    return _post('/api/users/$userId/events', {'events': events});
  }

  Future<Map<String, dynamic>> rate(String userId, String trackId, bool? like) {
    return _post('/api/users/$userId/rate', {'track_id': trackId, 'like': like});
  }

  /// Баны по Navidrome-ID (v0.2.9): шлём пару {artist_name, artist_id} где есть ID.
  /// Разбан — тем же (ID достаточно), сервер пишет tombstone `ban`.
  Future<Map<String, dynamic>> banArtist(String userId,
      {String artistName = '', String artistId = ''}) {
    return _post('/api/users/$userId/ban-artist', {
      'artist_name': artistName,
      'artist_id': artistId,
    });
  }

  Future<Map<String, dynamic>> unbanArtist(String userId,
      {String artistName = '', String artistId = ''}) {
    return _post('/api/users/$userId/unban-artist', {
      'artist_name': artistName,
      'artist_id': artistId,
    });
  }

  // ---------- library subscriptions (подписки на артистов) ----------
  /// Лайк артиста в плеере -> мозг сохраняет локально и ретранслирует
  /// внешнему сервису. Best-effort: сервер может быть старше и не знать
  /// роут (404) — вызывающий глотает ошибку.
  Future<Map<String, dynamic>> subscribeArtist({
    String? userId,
    String? username,
    required String artistName,
    String? artistExternalId,
  }) {
    return _post('/api/library-sync/subscriptions', {
      if (userId != null && userId.isNotEmpty) 'user_id': userId,
      if (username != null && username.isNotEmpty) 'username': username,
      'artist_name': artistName,
      if (artistExternalId != null && artistExternalId.isNotEmpty)
        'artist_external_id': artistExternalId,
    });
  }

  /// Снятие подписки. DELETE с JSON-body (сервер читает payload из body).
  /// artistExternalId — Navidrome id артиста: сервер сверяет по имени,
  /// id едет для будущей точной сверки и для обновления локального кеша.
  Future<Map<String, dynamic>> unsubscribeArtist({
    String? userId,
    String? username,
    required String artistName,
    String? artistExternalId,
  }) async {
    try {
      final r = await _dio.delete('$_b/api/library-sync/subscriptions', data: {
        if (userId != null && userId.isNotEmpty) 'user_id': userId,
        if (username != null && username.isNotEmpty) 'username': username,
        'artist_name': artistName,
        if (artistExternalId != null && artistExternalId.isNotEmpty)
          'artist_external_id': artistExternalId,
      });
      return _asMap(r.data);
    } on DioException catch (e) {
      throw KumaFlowBrainException(_dioMsg(e), e.response?.statusCode);
    }
  }

  Future<Map<String, dynamic>> listSubscriptions({String? userId}) =>
      _get('/api/library-sync/subscriptions', {
        if (userId != null && userId.isNotEmpty) 'user_id': userId,
      });

  Future<Map<String, dynamic>> postHistory(
      String userId, String trackId, String playedAtIso) {
    return _post('/api/users/$userId/history',
        {'track_id': trackId, 'played_at': playedAtIso});
  }

  Future<Map<String, dynamic>> getProfile(String userId) => _get('/api/users/$userId/profile');

  Future<Map<String, dynamic>> getHistory(String userId,
      {int limit = 50, int offset = 0}) {
    return _get('/api/users/$userId/history', {'limit': limit, 'offset': offset});
  }

  Future<Map<String, dynamic>> getRecentEvents(String userId) =>
      _get('/api/users/$userId/recent-events');

  Future<Map<String, dynamic>> getWrapped(String userId, {int? year, int? month}) {
    return _get('/api/users/$userId/wrapped',
        {if (year != null) 'year': year, if (month != null) 'month': month});
  }

  Future<Map<String, dynamic>> getDrift(String userId, {int weeksAgo = 4}) =>
      _get('/api/users/$userId/drift', {'weeks_ago': weeksAgo});

  Future<Map<String, dynamic>> postDriftSnapshot(String userId) =>
      _post('/api/users/$userId/drift/snapshot');

  Future<Map<String, dynamic>> getActivity(String userId, {int? year}) =>
      _get('/api/users/$userId/activity', {if (year != null) 'year': year});

  // ---------- vault (opt-in, Fernet, TASTE_VAULT_KEY на сервере) ----------
  Future<Map<String, dynamic>> getVault(String userId) => _get('/api/users/$userId/vault');

  Future<Map<String, dynamic>> postVault(String userId, String password) =>
      _post('/api/users/$userId/vault', {'password': password});

  Future<Map<String, dynamic>> deleteVault(String userId) =>
      _delete('/api/users/$userId/vault');

  // ---------- vault-check (v0.2.6): лёгкий пинг сейфа без импорта ----------
  /// GET /api/users/{id}/vault-check -> {stored, auth_ok, key_source, error?}.
  /// stored=false = пароль не запомнен; auth_ok=false = 401/decrypt fail,
  /// надо перезапомнить. Best-effort проверка перед ночным синком.
  Future<Map<String, dynamic>> vaultCheck(String userId) =>
      _get('/api/users/$userId/vault-check');

  Future<Map<String, dynamic>> refreshNow(String userId) =>
      _post('/api/users/$userId/refresh-now');

  Future<Map<String, dynamic>> refreshAsync(String userId) =>
      _post('/api/users/$userId/refresh-async');

  Future<Map<String, dynamic>> scanCurrent() => _get('/api/scan/runs/current');

  // ---------- tracks ----------
  Future<Map<String, dynamic>> getTrack(String trackId) =>
      _get('/api/tracks/$trackId');
  Future<Map<String, dynamic>> waveContinue({
    required String userId,
    required List<String> queue,
    String? currentTrackId,
    int count = 20,
    Map<String, dynamic> settings = const {},
    List<String> excludeIds = const [],
    List<Map<String, dynamic>> recentEvents = const [],
    List<Map<String, dynamic>> ratingsDelta = const [],
    String? device,
  }) {
    return _post('/api/wave/continue', {
      'user_id': userId,
      'queue': queue,
      if (currentTrackId != null) 'current_track_id': currentTrackId,
      'count': count,
      'settings': settings,
      'exclude_ids': excludeIds,
      'recent_events': recentEvents,
      'ratings_delta': ratingsDelta,
      if (device != null && device.isNotEmpty) 'device': device,
    });
  }

  /// Зеркало очереди на веб (in-memory, TTL 10 мин, читается через
  /// GET /api/wave/live?user_id=...). Fire-and-forget, best-effort.
  /// queue — external_id (Navidrome song id) или uuid.
  /// ВАЖНО: paused — строгий JSON-bool. Сервер делает bool(v):
  /// строка "false" превратилась бы в True (wave.py).
  Future<Map<String, dynamic>> publishQueue({
    required String userId,
    required List<String> queue,
    String? currentTrackId,
    int? positionSec,
    int? durationSec,
    String? device,
    String? deviceName,
    bool paused = false,
    bool? isWave,
    String? playlistName,
    Map<String, dynamic>? waveSettings,
    String? radioSeed,
  }) {
    return _post('/api/wave/publish', {
      'user_id': userId,
      'queue': queue.take(100).toList(),
      if (currentTrackId != null) 'current_track_id': currentTrackId,
      if (positionSec != null) 'position_sec': positionSec,
      if (durationSec != null) 'duration_sec': durationSec,
      if (device != null && device.isNotEmpty) 'device': device,
      if (deviceName != null && deviceName.isNotEmpty) 'device_name': deviceName,
      'paused': paused,
      if (isWave != null) 'is_wave': isWave,
      if (playlistName != null && playlistName.isNotEmpty)
        'playlist_name': playlistName.substring(
            0, playlistName.length > 120 ? 120 : playlistName.length),
      if (waveSettings != null && waveSettings.isNotEmpty)
        'wave_settings': waveSettings,
      if (radioSeed != null && radioSeed.isNotEmpty)
        'radio_seed': radioSeed.substring(
            0, radioSeed.length > 160 ? 160 : radioSeed.length),
    });
  }

  /// Handoff: откуда продолжить на этом устройстве
  /// (трек + позиция + хвост очереди + stale). null при ошибке сети.
  /// device: конкретный слот; без него сервер отдаёт самый свежий слот.
  Future<Map<String, dynamic>?> fetchResume(String userId,
      {String? device}) async {
    try {
      return await _get('/api/wave/resume', {
        'user_id': userId,
        if (device != null && device.isNotEmpty) 'device': device,
      });
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> waveSeeds(String userId,
      {String? characteristic, int limit = 5}) {
    return _get('/api/wave/seeds', {
      'user_id': userId,
      if (characteristic != null) 'characteristic': characteristic,
      'limit': limit,
    });
  }

  /// M5: радио по сиду. POST /api/wave/seed {user_id, kind, artist_name|track_id}
  /// -> {seed, playlist_id, tracks[uuid], items[{track_id,external_id,...}], similar_artists}.
  /// Играть по items[].external_id (v0.3.4+); tracks[uuid] оставлены для совместимости.
  Future<Map<String, dynamic>> waveSeedStart({
    required String userId,
    required String kind,
    String? artistName,
    String? trackId,
  }) {
    return _post('/api/wave/seed', {
      'user_id': userId,
      'kind': kind,
      if (artistName != null && artistName.isNotEmpty) 'artist_name': artistName,
      if (trackId != null && trackId.isNotEmpty) 'track_id': trackId,
    });
  }

  Future<Map<String, dynamic>> waveSeedGet(String userId) =>
      _get('/api/wave/seed', {'user_id': userId});

  // ---------- wave options (каталог занятий/характера/языков, ff5249d v0.2.8) ----------
  /// Канон опций волны для плеера: activities[{code,label,hint}],
  /// characteristics, languages, moods[{name,count}] (живые из соник-анализа).
  /// Плеер кеширует; без мозга — зашитый fallback (см. BrainWaveOptions.fallback).
  Future<Map<String, dynamic>> waveOptions() => _get('/api/wave/options');

  // ---------- tracks + library moods (v0.2.9 exact-match, v0.3.3 коды) ----------
  /// Каталог настроений для фильтра: GET /api/library/moods
  /// -> {moods:[{name,count}]}. name — нормализованный (strip+lower, RU тоже).
  Future<Map<String, dynamic>> libraryMoods() => _get('/api/library/moods');

  /// Треки с фильтром настроения: GET /api/tracks?...&mood=
  /// mood — exact-match по всем лейблам; пустой после чистки НЕ слать
  /// (сервер отдаст 400 invalid mood). Нет хитов -> {items:[],total:0}.
  Future<Map<String, dynamic>> libraryTracks({
    String? mood,
    String? artist,
    String? genre,
    String? source,
    int limit = 50,
    int offset = 0,
  }) {
    final q = <String, dynamic>{
      'limit': limit.clamp(1, 200),
      'offset': offset < 0 ? 0 : offset,
    };
    if (mood != null) {
      var m = mood.trim().toLowerCase().replaceAll(RegExp(r'["%_\\]'), '').trim();
      if (m.length > 64) m = m.substring(0, 64).trim();
      if (m.isNotEmpty) q['mood'] = m;
    }
    if (artist != null && artist.trim().isNotEmpty) q['artist'] = artist.trim();
    if (genre != null && genre.trim().isNotEmpty) q['genre'] = genre.trim();
    if (source != null && source.trim().isNotEmpty) q['source'] = source.trim();
    return _get('/api/tracks', q);
  }

  /// Слушатели артиста (v0.3.8): GET /api/library/artists/listeners
  /// -> {ok,name,monthly_listeners,plays_30d,total_listeners,track_count}.
  /// days clamp 1..365, нужен name или artist_id. Нет треков -> нули с ok:true.
  Future<Map<String, dynamic>> libraryArtistListeners({
    String? name,
    String? artistId,
    int days = 30,
  }) {
    return _get('/api/library/artists/listeners', {
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      if (artistId != null && artistId.trim().isNotEmpty)
        'artist_id': artistId.trim(),
      'days': days.clamp(1, 365),
    });
  }

  // ---------- shared wave settings (одни на всех устройствах) ----------
  Future<Map<String, dynamic>> getWaveSettings(String userId) =>
      _get('/api/wave/settings', {'user_id': userId});

  Future<Map<String, dynamic>> putWaveSettings(
          String userId, Map<String, dynamic> settings) =>
      _put('/api/wave/settings', {'user_id': userId, 'settings': settings});

  // ---------- rec-tuning (свой overlay: era/depth, мозг 0.3.32+) ----------
  /// Читать эффективный тюнинг: {effective: {character: {era_weight, depth...}}}.
  Future<Map<String, dynamic>> getRecTuning(String userId) =>
      _get('/api/settings/rec-tuning', {'user_id': userId});

  /// Писать свой overlay: group = {'character': {'era_weight': x, 'depth': y}}.
  /// Мозг клампит в диапазоны сам. Без user_id (глобал) — только админ.
  Future<Map<String, dynamic>> putRecTuning(
      String userId, Map<String, dynamic> group) {
    final payload = <String, dynamic>{'user_id': userId};
    payload.addAll(group);
    return _put('/api/settings/rec-tuning', payload);
  }

  // ---------- collab ----------
  Future<Map<String, dynamic>> similarUsers(String userId) =>
      _get('/api/collab/similar-users/$userId');

  Future<Map<String, dynamic>> collabRecommend(String userId, {int n = 20}) =>
      _get('/api/collab/recommend/$userId', {'n': n});

  // ---------- sonar (узнавание трека через микрофон) ----------
  /// GET /api/sonar/ -> {ok, enabled, coverage{fingerprinted, tracks_total,
  /// hashes_total, coverage_pct}}. enabled=false = сонар выключен тумблером
  /// (Настройки → Автоматизация → Сонар), кнопку микрофона не показываем.
  /// ВАЖНО: путь — /api/sonar/ БЕЗ /status (такого роута на сервере нет,
  /// server/app/api/sonar.py + docs/mobile-integration.md).
  Future<Map<String, dynamic>> sonarStatus() => _get('/api/sonar/');

  /// POST /api/sonar/recognize (multipart, поле audio, запись ~10с).
  /// Ответ: {ok, match{track_id, external_id, title, artist_name,...}|null,
  /// query_hashes, took_ms}. match=null = не узнал.
  Future<Map<String, dynamic>> sonarRecognize(
    List<int> bytes, {
    String filename = 'query.m4a',
  }) async {
    try {
      final form = FormData.fromMap({
        'audio': MultipartFile.fromBytes(bytes, filename: filename),
      });
      final r = await _dio.post('$_b/api/sonar/recognize', data: form);
      return _asMap(r.data);
    } on DioException catch (e) {
      throw KumaFlowBrainException(_dioMsg(e), e.response?.statusCode);
    }
  }
  // ---------- now-playing (read-only: что играет + next-N с reason) ----------
  /// GET /api/now-playing?user_id&n&offset&seed
  /// -> {playing{external_id,track_id,...}, next[{track_id,title,artist_name,
  /// album_name,genre,cover_art_id,score,reason}], source}.
  /// Только чтение, состояние волны не меняет.
  Future<Map<String, dynamic>> nowPlaying(String userId,
      {int n = 5, int offset = 0, String? seed}) {
    return _get('/api/now-playing', {
      'user_id': userId,
      'n': n,
      'offset': offset,
      if (seed != null && seed.isNotEmpty) 'seed': seed,
    });
  }

  // ---------- weekly discovery (CLAP или cold_start_fallback) ----------
  Future<Map<String, dynamic>> weeklyDiscovery(String userId, {int n = 30}) =>
      _post('/api/playlists/weekly-discovery', {'user_id': userId, 'n': n});

  // ---------- notifications ----------
  // Список может быть медленным на большом сервере — даём 25с + ретрай
  // меньшим лимитом делает сервис.
  Future<Map<String, dynamic>> notifications(
          {String? userId, int limit = 50}) =>
      _get(
          '/api/notifications/',
          {
            if (userId != null) 'user_id': userId,
            'limit': limit,
          },
          const Duration(seconds: 25));

  Future<Map<String, dynamic>> unreadCount({String? userId}) =>
      _get('/api/notifications/unread-count',
          {if (userId != null) 'user_id': userId},
          const Duration(seconds: 15));

  Future<Map<String, dynamic>> markRead(String notifId) =>
      _post('/api/notifications/$notifId/read');

  Future<Map<String, dynamic>> markAllRead({String? userId}) => _post(
      '/api/notifications/read-all', {if (userId != null) 'user_id': userId});

  // ---------- covers (ETag + 304 — кешировать агрессивно, греть пачками по 8) ----------
  String coverUrl(String trackId, {int size = 300}) {
    final t = (authToken != null && authToken!.isNotEmpty) ? '&token=$authToken' : '';
    return '$_b/api/covers/track/$trackId?size=$size$t';
  }

  /// Прогрев кеша обложек пачками (серверный POST /api/covers/prefetch).
  Future<Map<String, dynamic>> prefetchCovers(List<String> trackIds,
      {int size = 300}) {
    return _post('/api/covers/prefetch',
        {'track_ids': trackIds, 'size': size});
  }
}
