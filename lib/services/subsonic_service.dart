import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:uuid/uuid.dart';
import '../models/models.dart';
import 'jellyfin_service.dart';
import 'youtube_service.dart';

class PingResult {
  final bool success;
  final String? error;
  final String? serverType;
  final String? serverVersion;

  PingResult({
    required this.success,
    this.error,
    this.serverType,
    this.serverVersion,
  });
}

/// Isolate-парсинг search3 страниц: тяжёлый fromJson не должен жечь main-поток
/// во время воспроизведения. В isolate едут только plain-data (List of Maps).
List<Map<String, dynamic>> _parseAlbumsIsolate(List<dynamic> raw) => raw
    .map((a) => Map<String, dynamic>.from(a as Map))
    .toList();
List<Map<String, dynamic>> _parseSongsIsolate(List<dynamic> raw) => raw
    .map((s) => Map<String, dynamic>.from(s as Map))
    .toList();

class SubsonicService {
  Dio _dio;
  ServerConfig? _config;
  JellyfinService? _jellyfin;
  YoutubeService? _youtube;
  CancelToken? _activeCancelToken;
  final Set<CancelToken> _activeCancelTokens = {};

  /// Отменяет висящие запросы (вызывается из AuthProvider.cancelAuth).
  /// Каждый запрос получает свой токен, параллельные запросы друг друга не гасят.
  void cancelPendingRequests([String reason = 'cancelled by user']) {
    try {
      _activeCancelToken?.cancel(reason);
      for (final t in _activeCancelTokens) {
        if (!t.isCancelled) t.cancel(reason);
      }
    } catch (_) {}
    _activeCancelToken = null;
    _activeCancelTokens.clear();
  }

  CancelToken _newCancelToken() {
    final token = CancelToken();
    _activeCancelToken = token;
    _activeCancelTokens.add(token);
    return token;
  }

  static const String _clientName = 'KumaFlow(Mobile)';
  static const String _apiVersion = '1.16.1';

  SubsonicService() : _dio = Dio() {
    _dio.options.connectTimeout = const Duration(seconds: 10);
    _dio.options.receiveTimeout = const Duration(seconds: 10);
    _dio.options.sendTimeout = const Duration(seconds: 10);
    _addLogInterceptor(_dio);
    // 12.10.2026: БЕЗ кастомного connectionFactory — НАВСЕГДА.
    // Фабрика отдавала предподключённый сокет на IP, TLS уходил без
    // правильного SNI → облако Keenetic отвечало 410 Unknown Name на ВСЕ
    // запросы (100% корреляция за день: любой стек с фабрикой = 410,
    // любой без неё = 200). Сертификаты — через контекст, см. ниже.
  }

  static String _sanitizeUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final q = Map<String, String>.from(uri.queryParameters);
      for (final key in const ['p', 't', 's']) {
        if (q.containsKey(key)) q[key] = '***';
      }
      return uri.replace(queryParameters: q).toString();
    } catch (_) {
      return url;
    }
  }

  /// Dio 5 в e.message кладёт эссе на абзац (ссылки на mozilla и т.п.) —
  /// через KeenDNS-прокси 403 сыплются пачками и топят лог. Режем до сути.
  static String _shortMsg(String? m) {
    final s = (m ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.length <= 220) return s;
    return '${s.substring(0, 220)}…';
  }

  void _addLogInterceptor(Dio dio) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.extra['_logSw'] = Stopwatch()..start();
          final safe = _sanitizeUrl(options.uri.toString());
          debugPrint('[KumaFlow] → ${options.method} $safe');
          handler.next(options);
        },
        onResponse: (response, handler) {
          final sw = response.requestOptions.extra['_logSw'] as Stopwatch?;
          sw?.stop();
          final ms = sw?.elapsedMilliseconds ?? 0;
          final safe = _sanitizeUrl(response.requestOptions.uri.toString());
          debugPrint('[KumaFlow] ← ${response.statusCode} $safe (${ms}ms)');
          handler.next(response);
        },
        onError: (e, handler) {
          final sw = e.requestOptions.extra['_logSw'] as Stopwatch?;
          sw?.stop();
          final ms = sw?.elapsedMilliseconds ?? 0;
          final safe = _sanitizeUrl(e.requestOptions.uri.toString());
          debugPrint('[KumaFlow] ✗ ${e.type.name} $safe (${ms}ms) — ${_shortMsg(e.message)}');
          if (e.error != null) debugPrint('[KumaFlow]   cause: ${e.error}');
          // Диагностика 4xx/5xx: кто режет — видно по Server-заголовку и телу.
          try {
            final resp = e.response;
            if (resp != null) {
              debugPrint('[KumaFlow]   headers: ${resp.headers.map}');
              final body = '${resp.data}';
              debugPrint('[KumaFlow]   body[${body.length}]: ${body.substring(0, body.length > 400 ? 400 : body.length)}');
            }
          } catch (_) {}
          // Ретраи на чужой 410 от облака Keenetic (NDM NDNS Unknown Name)
          // и на таймаут соединения: 410 транзиентный (тот же IP через минуту
          // отдаёт 200), повтор идёт через новое соединение. Без банов —
          // как в эталоне, только просьба повторить.
          // NB: бана IP тут НЕТ специально (12.10.2026): бан превращал
          // транзиентные 410 в 10-минутный простой.
          final ndnsTries =
              (e.requestOptions.extra['_ndnsRetried'] as int?) ?? 0;
          final is410 = _isNdns410(e);
          final isTimeout = e.type == DioExceptionType.connectionTimeout ||
              e.type == DioExceptionType.connectionError;
          final maxTries = is410 ? 3 : (isTimeout ? 1 : 0);
          if ((is410 || isTimeout) && ndnsTries < maxTries) {
            final host = e.requestOptions.uri.host;
            debugPrint('[Net] retry ${ndnsTries + 1}/$maxTries after ${is410 ? 'NDNS-410' : e.type.name} for $host');
            e.requestOptions.extra['_ndnsRetried'] = ndnsTries + 1;
            _dio
                .fetch<Map<String, dynamic>>(e.requestOptions)
                .then((r) => handler.resolve(r))
                .catchError((Object err) =>
                    handler.next(err is DioException ? err : e));
            return;
          }
          handler.next(e);
        },
      ),
    );
  }

  /// Чужой 410 от облака Keenetic: server NDM NDNS + x-detail/Unknown Name.
  static bool _isNdns410(DioException e) {
    try {
      if (e.response?.statusCode != 410) return false;
      final h = e.response?.headers.map ?? const {};
      for (final k in h.keys) {
        final kl = k.toLowerCase();
        if (kl == 'server' || kl == 'x-detail') {
          final v = h[k]?.join(' ').toLowerCase() ?? '';
          if (v.contains('ndm') ||
              v.contains('ndns') ||
              v.contains('unknown name')) {
            return true;
          }
        }
      }
      final body = '${e.response?.data}'.toLowerCase();
      return body.contains('unknown name') && body.contains('ndns');
    } catch (_) {
      return false;
    }
  }

  Future<void> configure(ServerConfig config) async {
    _config = config;
    _stableAuthParams = null;
    if (config.isJellyfin) {
      _jellyfin ??= JellyfinService();
      _jellyfin!.configure(config);
      _youtube?.dispose();
      _youtube = null;
      // } else if (config.serverFamily == 'youtube') {
      //   _youtube ??= YoutubeService();
      //   _jellyfin = null;
    } else {
      _jellyfin = null;
      _youtube?.dispose();
      _youtube = null;
      await _configureCertificateValidation(
        config.allowSelfSignedCertificates,
        customCertPath: config.customCertificatePath,
        clientCertPath: config.clientCertificatePath,
        clientCertPassword: config.clientCertificatePassword,
      );
    }
  }

  bool get isYoutube => _youtube != null;

  bool get isJellyfin => _jellyfin != null;

  /// For YouTube songs, returns a pre-warmed [StreamAudioSource] that proxies
  /// audio through youtube_explode_dart's HTTP client (avoids ExoPlayer's 403).
  /// Returns null for Subsonic / Jellyfin (use [resolveStreamUrlAsync]).
  Future<StreamAudioSource?> getYoutubeAudioSource(Song song) async {
    if (_youtube != null) return _youtube!.buildAudioSource(song.id);
    return null;
  }

  /// Resolves the playable URL for [song]. For YouTube this calls the async
  /// manifest extraction; for other families it returns the pre-built URL.
  Future<String> resolveStreamUrlAsync(Song song) async {
    if (_youtube != null) {
      return _youtube!.resolveStreamUrl(song.id);
    }
    return getStreamUrl(song.id);
  }

  Future<void> _configureCertificateValidation(
    bool allowSelfSigned, {
    String? customCertPath,
    String? clientCertPath,
    String? clientCertPassword,
  }) async {
    _dio = Dio();
    // connectTimeout длинный (30с, как в эталоне): медленный туннель/PoP
    // отвечает по 9–20с, короткий таймаут рвал живые bulk-запросы (12.10.2026).
    // receive/send длинные (стриминг/качалки). Без кастомных фабрик.
    _dio.options.connectTimeout = const Duration(seconds: 30);
    _dio.options.receiveTimeout = const Duration(seconds: 30);
    _dio.options.sendTimeout = const Duration(seconds: 30);
    _addLogInterceptor(_dio);

    final hasCustomServerCert =
        customCertPath != null && customCertPath.isNotEmpty;
    final hasClientCert = clientCertPath != null && clientCertPath.isNotEmpty;

    if (hasCustomServerCert || allowSelfSigned || hasClientCert) {
      // Pre-load certificate files asynchronously to avoid blocking UI
      Uint8List? customServerCertBytes;
      Uint8List? clientCertBytes;

      if (hasCustomServerCert) {
        try {
          final file = File(customCertPath);
          if (await file.exists()) {
            customServerCertBytes = await file.readAsBytes();
          }
        } catch (e) {
          debugPrint('Failed to load custom server certificate: $e');
        }
      }

      if (hasClientCert) {
        try {
          final file = File(clientCertPath);
          if (await file.exists()) {
            clientCertBytes = await file.readAsBytes();
          }
        } catch (e) {
          debugPrint('Failed to load client certificate: $e');
        }
      }

      HttpClient createClient() {
        HttpClient buildClient(SecurityContext context) {
          return HttpOverrides.runWithHttpOverrides(() {
            final client = HttpClient(context: context);
            client.connectionTimeout = const Duration(seconds: 15);
            client.idleTimeout = const Duration(seconds: 15);
            // БЕЗ connectionFactory (12.10.2026): фабрика ломала SNI.
            // Только контекст + callback самоподписанных.
            if (allowSelfSigned) {
              client.badCertificateCallback = (cert, host, port) => true;
            }
            return client;
          }, _RealHttpOverrides());
        }

        try {
          final context = SecurityContext(withTrustedRoots: true);

          if (hasCustomServerCert && customServerCertBytes != null) {
            context.setTrustedCertificatesBytes(customServerCertBytes);
          }

          if (hasClientCert && clientCertBytes != null) {
            final password = clientCertPassword;

            context.useCertificateChainBytes(clientCertBytes,
                password: password);

            context.usePrivateKeyBytes(clientCertBytes, password: password);
          }

          return buildClient(context);
        } catch (e) {
          debugPrint('Failed to configure TLS: $e');
          return buildClient(SecurityContext(withTrustedRoots: true));
        }
      }

      HttpOverrides.global = _TlsHttpOverrides(createClient);

      (_dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient =
          createClient;
    } else {
      HttpOverrides.global = null;
    }
  }

  ServerConfig? get config => _config;

  bool get isConfigured => _config != null && _config!.isValid;

  Map<String, String> _getAuthParams() {
    if (_config == null) throw Exception('Server not configured');

    final params = <String, String>{
      'u': _config!.username,
      'v': _apiVersion,
      'c': _clientName,
      'f': 'json',
    };

    if (_config!.useLegacyAuth) {
      params['p'] = _config!.password;
    } else {
      final salt = const Uuid().v4().substring(0, 8);
      final token =
          md5.convert(utf8.encode('${_config!.password}$salt')).toString();
      params['t'] = token;
      params['s'] = salt;
    }

    return params;
  }

  Map<String, String>? _stableAuthParams;

  void _ensureStableAuthParams() {
    if (_stableAuthParams != null) return;
    if (_config == null) return;

    final params = <String, String>{
      'u': _config!.username,
      'v': _apiVersion,
      'c': _clientName,
      'f': 'json',
    };

    if (_config!.useLegacyAuth) {
      params['p'] = _config!.password;
    } else {
      const salt = 'kumaflow_v3';
      final token =
          md5.convert(utf8.encode('${_config!.password}$salt')).toString();
      params['t'] = token;
      params['s'] = salt;
    }
    _stableAuthParams = params;
  }

  String _buildUrl(String endpoint, [Map<String, String>? extraParams]) {
    if (_config == null) throw Exception('Server not configured');

    final params = _getAuthParams();
    if (extraParams != null) {
      params.addAll(extraParams);
    }

    if (_config!.selectedMusicFolderIds.isNotEmpty) {
      params['musicFolderId'] = _config!.selectedMusicFolderIds.first;
    }

    final queryString = params.entries
        .map(
          (e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
        )
        .join('&');

    return '${_config!.normalizedUrl}/rest/$endpoint?$queryString';
  }

  Future<Map<String, dynamic>> _request(
    String endpoint, [
    Map<String, String>? params,
  ]) async {
    final url = _buildUrl(endpoint, params);
    final token = _newCancelToken();

    try {
      final response = await _dio.get(url, cancelToken: token);
      final data = response.data;

      if (data is String) {
        return json.decode(data);
      }

      final subsonicResponse = data['subsonic-response'];
      if (subsonicResponse == null) {
        throw Exception('Invalid response format');
      }

      if (subsonicResponse['status'] != 'ok') {
        final error = subsonicResponse['error'];
        throw Exception(error?['message'] ?? 'Unknown error');
      }

      return subsonicResponse;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw Exception('Cancelled by user.');
      }
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          throw Exception('Connection timed out. Check your server URL.');
        case DioExceptionType.connectionError:
          final cause = e.error?.toString() ?? '';
          if (cause.contains('HandshakeException') ||
              cause.contains('CERTIFICATE_VERIFY_FAILED') ||
              cause.contains('SSL')) {
            throw Exception(
                'SSL certificate error. Enable "Allow Self-Signed Certificates" for custom CA servers.');
          }
          throw Exception(
              'Cannot connect to server. Check the URL and your internet connection.');
        case DioExceptionType.badResponse:
          final status = e.response?.statusCode;
          if (status == 401 || status == 403)
            throw Exception('Invalid username or password.');
          if (status == 404)
            throw Exception('Server not found. Check your URL path.');
          if (status != null && status >= 500)
            throw Exception(
                'Server error ($status). The server failed to process the request.');
          throw Exception('Request failed (HTTP $status).');
        default:
          throw Exception('Network error. Check your connection.');
      }
    } finally {
      _activeCancelTokens.remove(token);
      if (identical(_activeCancelToken, token)) _activeCancelToken = null;
    }
  }

  Future<bool> ping() async {
    try {
      await _request('ping');
      return true;
    } catch (e) {
      return false;
    }
  }

  // ── OpenSubsonic extensions detect — как в Airdrome/src/api/service.ts + aonsoku/utils/servers.ts
  bool? _songLyricsEnabledCached;
  bool get songLyricsEnabled => _songLyricsEnabledCached ?? true;

  Future<bool> detectSongLyricsExtension() async {
    if (_jellyfin != null || _youtube != null) return true;
    if (_songLyricsEnabledCached != null) return _songLyricsEnabledCached!;
    try {
      final res = await _request('getOpenSubsonicExtensions').timeout(const Duration(seconds: 4));
      // Navidrome returns { openSubsonicExtensions: [{name:'songLyrics', versions:[1]}] }
      final exts = res['openSubsonicExtensions'] as List?;
      if (exts != null) {
        _songLyricsEnabledCached =
            exts.any((e) => (e is Map && (e['name'] == 'songLyrics' || e['name'] == 'structuredLyrics')));
        debugPrint('[Subsonic] songLyrics extension: $_songLyricsEnabledCached');
        return _songLyricsEnabledCached!;
      }
      // Fallback: some servers return { extensions: [...] }
      final alt = res['extensions'] as List?;
      if (alt != null) {
        _songLyricsEnabledCached = alt.any((e) => e.toString().contains('songLyrics'));
        return _songLyricsEnabledCached!;
      }
      _songLyricsEnabledCached = false;
      return false;
    } catch (e) {
      // Если endpoint не поддерживается (404) — считаем выключенным чтобы не ждать 5s каждый раз
      if (e.toString().contains('404') || e.toString().contains('Not Found')) {
        _songLyricsEnabledCached = false;
        debugPrint('[Subsonic] getOpenSubsonicExtensions 404 -> songLyrics disabled');
        return false;
      }
      // Иначе считаем включенным (fail-open)
      _songLyricsEnabledCached = true;
      return true;
    }
  }

  /// Поэтапный замер сети для экрана «долго подключается»:
  /// DNS (lookup), TCP (сокет к первому IPv4), TLS (SecureSocket).
  /// Возвращает миллисекунды или -1 если этап провалился. Не бросает.
  Future<Map<String, int>> probeStages() async {
    final out = <String, int>{'dns': -1, 'tcp': -1, 'tls': -1};
    try {
      final cfg = _config;
      if (cfg == null) return out;
      final uri = Uri.parse(cfg.normalizedUrl);
      final host = uri.host;
      if (host.isEmpty) return out;
      final isHttps = uri.scheme == 'https';
      final port = uri.hasPort ? uri.port : (isHttps ? 443 : 80);

      var sw = Stopwatch()..start();
      List<InternetAddress> addrs;
      try {
        addrs = await InternetAddress.lookup(host)
            .timeout(const Duration(seconds: 5));
        out['dns'] = sw.elapsedMilliseconds;
      } catch (_) {
        return out;
      }
      if (addrs.isEmpty) return out;
      // IPv4 первым: битый корпоративный IPv6 — главная причина виса.
      addrs.sort((a, b) {
        final ai = a.type == InternetAddressType.IPv4 ? 0 : 1;
        final bi = b.type == InternetAddressType.IPv4 ? 0 : 1;
        return ai.compareTo(bi);
      });

      sw = Stopwatch()..start();
      // Щупаем ВСЕ IPv4 (KeenDNS ротирует A-записи, одна может быть
      // протухшей): лучший TCP в зачёт, плюс какой IP победил — в лог.
      var tcpOk = false;
      for (final a in addrs.where(
          (x) => x.type == InternetAddressType.IPv4)) {
        final t = Stopwatch()..start();
        try {
          final sock = await Socket.connect(a, port,
              timeout: const Duration(seconds: 4));
          final ms = t.elapsedMilliseconds;
          debugPrint('[Net] probe TCP OK ${a.address}:$port ${ms}ms');
          if (!tcpOk || ms < out['tcp']!) out['tcp'] = ms;
          tcpOk = true;
          try {
            sock.destroy();
          } catch (_) {}
          break;
        } catch (e) {
          debugPrint(
              '[Net] probe TCP FAIL ${a.address}:$port ${t.elapsedMilliseconds}ms ($e)');
        }
      }
      if (!tcpOk) return out;

      if (!isHttps) {
        out['tls'] = 0;
        return out;
      }
      sw = Stopwatch()..start();
      try {
        final allowSelf = cfg.allowSelfSignedCertificates;
        final sec = await SecureSocket.connect(host, port,
            timeout: const Duration(seconds: 8),
            onBadCertificate: allowSelf ? (_) => true : null);
        out['tls'] = sw.elapsedMilliseconds;
        try {
          await sec.close();
        } catch (_) {}
      } catch (_) {}
      return out;
    } catch (_) {
      return out;
    }
  }

  /// Smart Connect удалён 12.10.2026 (как в эталоне): гонка LAN/WAN молча
  /// перезаписывала сохранённый serverUrl — воспринималось как
  /// «сброс выбора сервера». Поле localUrl в настройках сохранено,
  /// автоподмена URL выключена.
  /// Честная классификация ошибки подключения (идея yuzic addressProbe):
  /// сертификат — чинить серт, а не адрес; остальное — сеть/адрес.
  static String classifyConnectionError(Object e) {
    final s = e.toString().toLowerCase();
    const certMarks = [
      'trust anchor',
      'certpathvalidator',
      'certificateexception',
      'sslhandshake',
      'certificate',
      'self signed',
      'self-signed',
      'cert_',
      'err_cert',
      'handshakeexception',
    ];
    for (final m in certMarks) {
      if (s.contains(m)) return 'cert';
    }
    return 'net';
  }

  Future<PingResult> pingWithError() async {    if (_jellyfin != null) return _jellyfin!.pingWithError();
    if (_youtube != null) return _youtube!.pingWithError();
    try {
      final response = await _request('ping');
      // Попытка определить расширения в фоне
      unawaited(detectSongLyricsExtension());
      return PingResult(
        success: true,
        serverType: response['type'],
        serverVersion: response['serverVersion'],
      );
    } catch (e) {
      return PingResult(success: false, error: e.toString());
    }
  }

  Future<List<MusicFolder>> getMusicFolders() async {
    try {
      final response = await _request('getMusicFolders');
      final folders = <MusicFolder>[];

      final foldersData = response['musicFolders']?['musicFolder'];
      if (foldersData is List) {
        folders.addAll(
          foldersData.map(
            (f) => MusicFolder.fromJson(f as Map<String, dynamic>),
          ),
        );
      }

      return folders;
    } catch (e) {
      return [];
    }
  }

  String getCoverArtUrl(String? coverArt, {int size = 300}) {
    if (_jellyfin != null)
      return _jellyfin!.getCoverArtUrl(coverArt, size: size);
    if (_youtube != null) return _youtube!.getCoverArtUrl(coverArt, size: size);
    if (coverArt == null || _config == null) {
      return '';
    }
    _ensureStableAuthParams();

    final params = Map<String, String>.from(
      _stableAuthParams ?? _getAuthParams(),
    );
    params['id'] = coverArt;
    if (size > 0) {
      params['size'] = size.toString();
    }

    if (_config!.selectedMusicFolderIds.isNotEmpty) {
      params['musicFolderId'] = _config!.selectedMusicFolderIds.first;
    }

    final queryString = params.entries
        .map(
          (e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
        )
        .join('&');

    return '${_config!.normalizedUrl}/rest/getCoverArt?$queryString';
  }

  String getStreamUrl(String songId, {int? maxBitRate, String? format}) {
    if (_jellyfin != null)
      return _jellyfin!
          .getStreamUrl(songId, maxBitRate: maxBitRate, format: format);
    if (_youtube != null) return _youtube!.getStreamUrl(songId);
    final params = <String, String>{'id': songId};
    if (maxBitRate != null) {
      params['maxBitRate'] = maxBitRate.toString();
    }
    if (format != null) {
      params['format'] = format;
    }
    return _buildUrl('stream', params);
  }

  Future<List<Artist>> getArtists() async {
    if (_jellyfin != null) return _jellyfin!.getArtists();
    if (_youtube != null) return _youtube!.getArtists();
    final response = await _request('getArtists');
    final artists = <Artist>[];

    final artistsData = response['artists']?['index'];
    // Navidrome/Subsonic may return a single Map instead of a List when
    // there is only one index or one artist in it — normalize both cases.
    final List<dynamic> indexes;
    if (artistsData is List) {
      indexes = artistsData;
    } else if (artistsData is Map) {
      indexes = [artistsData];
    } else {
      return artists;
    }
    for (final index in indexes) {
      final indexArtists = (index as Map?)?['artist'];
      final List<dynamic> list;
      if (indexArtists is List) {
        list = indexArtists;
      } else if (indexArtists is Map) {
        list = [indexArtists];
      } else {
        continue;
      }
      for (final a in list) {
        try {
          artists.add(
            Artist.fromJson((a as Map).cast<String, dynamic>()),
          );
        } catch (_) {}
      }
    }

    return artists;
  }

  Future<List<Song>> getAllSongs() async {
    if (_jellyfin != null) return _jellyfin!.getAllSongs();
    // Subsonic has no direct "get all songs" endpoint.
    return [];
  }

  Future<Artist> getArtist(String id) async {
    final response = await _request('getArtist', {'id': id});
    return Artist.fromJson(response['artist'] as Map<String, dynamic>);
  }

  Future<List<Album>> getAlbumList({
    String type = 'recent',
    int size = 20,
    int offset = 0,
  }) async {
    if (_jellyfin != null)
      return _jellyfin!.getAlbumList(type: type, size: size, offset: offset);
    if (_youtube != null)
      return _youtube!.getAlbumList(type: type, size: size, offset: offset);
    final response = await _request('getAlbumList2', {
      'type': type,
      'size': size.toString(),
      'offset': offset.toString(),
    });

    final albumsData = response['albumList2']?['album'];
    if (albumsData is List) {
      return albumsData
          .map((a) => Album.fromJson(a as Map<String, dynamic>))
          .toList();
    }

    return [];
  }

  Future<Album> getAlbum(String id) async {
    if (_jellyfin != null) return _jellyfin!.getAlbum(id);
    if (_youtube != null) return _youtube!.getAlbum(id);
    final response = await _request('getAlbum', {'id': id});
    return Album.fromJson(response['album'] as Map<String, dynamic>);
  }

  Future<List<Song>> getAlbumSongs(String albumId) async {
    if (_jellyfin != null) return _jellyfin!.getAlbumSongs(albumId);
    if (_youtube != null) return _youtube!.getAlbumSongs(albumId);
    final response = await _request('getAlbum', {'id': albumId});
    final songsData = response['album']?['song'];
    if (songsData is List) {
      return songsData
          .map((s) => Song.fromJson(s as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  Future<List<Album>> getArtistAlbums(String artistId) async {
    if (_jellyfin != null) return _jellyfin!.getArtistAlbums(artistId);
    if (_youtube != null) return _youtube!.getArtistAlbums(artistId);
    final response = await _request('getArtist', {'id': artistId});
    final albumsData = response['artist']?['album'];
    if (albumsData is List) {
      return albumsData
          .map((a) => Album.fromJson(a as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  Future<List<Playlist>> getPlaylists() async {
    if (_jellyfin != null) return _jellyfin!.getPlaylists();
    if (_youtube != null) return _youtube!.getPlaylists();
    final response = await _request('getPlaylists');
    final playlistsData = response['playlists']?['playlist'];
    if (playlistsData is List) {
      return playlistsData
          .map((p) => Playlist.fromJson(p as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  Future<Playlist> getPlaylist(String id) async {
    if (_jellyfin != null) return _jellyfin!.getPlaylist(id);
    if (_youtube != null) return _youtube!.getPlaylist(id);
    final response = await _request('getPlaylist', {'id': id});
    return Playlist.fromJson(response['playlist'] as Map<String, dynamic>);
  }

  Future<void> createPlaylist({
    required String name,
    String? comment,
    List<String>? songIds,
  }) async {
    if (_jellyfin != null) {
      await _jellyfin!
          .createPlaylist(name: name, comment: comment, songIds: songIds);
      return;
    }
    if (_youtube != null) {
      await _youtube!
          .createPlaylist(name: name, comment: comment, songIds: songIds);
      return;
    }
    // comment is official OpenSubsonic param, Navidrome stores it as Playlist.comment
    final params = <String, String>{'name': name};
    if (comment != null && comment.isNotEmpty) params['comment'] = comment;
    // songId must be appended directly, using it as a map key would produce
    // songId[i]=x which Navidrome doesn't recognize
    String url = _buildUrl('createPlaylist', params);
    if (songIds != null && songIds.isNotEmpty) {
      for (final songId in songIds) {
        url += '&songId=${Uri.encodeComponent(songId)}';
      }
    }

    try {
      final response = await _dio.get(url);
      final data = response.data;

      final decoded = data is String ? json.decode(data) : data;
      final subsonicResponse = decoded['subsonic-response'];
      if (subsonicResponse == null) {
        throw Exception('Invalid response format');
      }

      if (subsonicResponse['status'] != 'ok') {
        final error = subsonicResponse['error'];
        throw Exception(error?['message'] ?? 'Unknown error');
      }
    } on DioException catch (e) {
      throw Exception('Network error: ${e.message}');
    }
  }

  Future<void> updatePlaylist({
    required String playlistId,
    String? name,
    String? comment,
    List<String>? songIdsToAdd,
    List<int>? songIndexesToRemove,
  }) async {
    final params = <String, String>{'playlistId': playlistId};
    if (name != null) params['name'] = name;
    if (comment != null) params['comment'] = comment;

    String url = _buildUrl('updatePlaylist', params);

    if (songIdsToAdd != null && songIdsToAdd.isNotEmpty) {
      for (final songId in songIdsToAdd) {
        url += '&songIdToAdd=${Uri.encodeComponent(songId)}';
      }
    }

    if (songIndexesToRemove != null && songIndexesToRemove.isNotEmpty) {
      for (final index in songIndexesToRemove) {
        url += '&songIndexToRemove=${Uri.encodeComponent(index.toString())}';
      }
    }

    debugPrint('updatePlaylist URL: ${_sanitizeUrl(url)}');

    try {
      final response = await _dio.get(url);
      final data = response.data;

      final decoded = data is String ? json.decode(data) : data;
      final subsonicResponse = decoded['subsonic-response'];
      if (subsonicResponse == null) {
        throw Exception('Invalid response format');
      }

      if (subsonicResponse['status'] != 'ok') {
        final error = subsonicResponse['error'];
        throw Exception(error?['message'] ?? 'Unknown error');
      }

      debugPrint('updatePlaylist successful');
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status != null && status >= 500)
        throw Exception(
            'Server error ($status). The server failed to process the request.');
      throw Exception('Network error. Check your connection.');
    }
  }

  Future<void> deletePlaylist(String id) async {
    if (_jellyfin != null) {
      await _jellyfin!.deletePlaylist(id);
      return;
    }
    if (_youtube != null) {
      await _youtube!.deletePlaylist(id);
      return;
    }
    await _request('deletePlaylist', {'id': id});
  }

  Future<SearchResult> search(
    String query, {
    int artistCount = 20,
    int albumCount = 20,
    int songCount = 20,
    int artistOffset = 0,
    int albumOffset = 0,
    int songOffset = 0,
  }) async {
    if (_jellyfin != null) {
      return _jellyfin!.search(
        query,
        songCount: songCount,
        albumCount: albumCount,
        artistCount: artistCount,
        songOffset: songOffset,
        albumOffset: albumOffset,
        artistOffset: artistOffset,
      );
    }
    if (_youtube != null) {
      return _youtube!.search(
        query,
        songCount: songCount,
        albumCount: albumCount,
        artistCount: artistCount,
      );
    }
    final response = await _request('search3', {
      'query': query,
      'artistCount': artistCount.toString(),
      'artistOffset': artistOffset.toString(),
      'albumCount': albumCount.toString(),
      'albumOffset': albumOffset.toString(),
      'songCount': songCount.toString(),
      'songOffset': songOffset.toString(),
    });

    final searchResult = response['searchResult3'];
    debugPrint('SubsonicService: search3 response: searchResult=$searchResult');

    // Handle both single item and list responses
    var artistList = searchResult?['artist'];
    var albumList = searchResult?['album'];
    var songList = searchResult?['song'];

    // Normalize to lists
    if (artistList != null && artistList is! List) {
      artistList = [artistList];
    }
    if (albumList != null && albumList is! List) {
      albumList = [albumList];
    }
    if (songList != null && songList is! List) {
      songList = [songList];
    }

    final artists = (artistList as List?)
            ?.map((a) => Artist.fromJson(a as Map<String, dynamic>))
            .toList() ??
        [];

    final albums = (albumList as List?)
            ?.map((a) => Album.fromJson(a as Map<String, dynamic>))
            .toList() ??
        [];

    final songs = (songList as List?)
            ?.map((s) => Song.fromJson(s as Map<String, dynamic>))
            .toList() ??
        [];

    debugPrint(
        'SubsonicService: search3 parsed: ${artists.length} artists, ${albums.length} albums, ${songs.length} songs');
    return SearchResult(artists: artists, albums: albums, songs: songs);
  }

  Future<List<Song>> getRandomSongs({int size = 20, String? genre}) async {
    if (_jellyfin != null)
      return _jellyfin!.getRandomSongs(size: size, genre: genre);
    if (_youtube != null)
      return _youtube!.getRandomSongs(size: size, genre: genre);
    final params = <String, String>{'size': size.toString()};
    if (genre != null) params['genre'] = genre;

    final response = await _request('getRandomSongs', params);
    final songsData = response['randomSongs']?['song'];
    if (songsData is List) {
      return songsData
          .map((s) => Song.fromJson(s as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  Future<void> star({String? id, String? albumId, String? artistId}) async {
    if (_jellyfin != null) {
      await _jellyfin!.star(id: id, albumId: albumId, artistId: artistId);
      return;
    }
    if (_youtube != null) {
      await _youtube!.star(id: id, albumId: albumId, artistId: artistId);
      return;
    }
    final params = <String, String>{};
    if (id != null) params['id'] = id;
    if (albumId != null) params['albumId'] = albumId;
    if (artistId != null) params['artistId'] = artistId;
    await _request('star', params);
  }

  Future<void> unstar({String? id, String? albumId, String? artistId}) async {
    if (_jellyfin != null) {
      await _jellyfin!.unstar(id: id, albumId: albumId, artistId: artistId);
      return;
    }
    if (_youtube != null) {
      await _youtube!.unstar(id: id, albumId: albumId, artistId: artistId);
      return;
    }
    final params = <String, String>{};
    if (id != null) params['id'] = id;
    if (albumId != null) params['albumId'] = albumId;
    if (artistId != null) params['artistId'] = artistId;
    await _request('unstar', params);
  }

  Future<void> setRating(String id, int rating) async {
    if (rating < 0 || rating > 5) {
      throw ArgumentError('Rating must be between 0 and 5');
    }
    await _request('setRating', {'id': id, 'rating': rating.toString()});
  }

  Future<SearchResult> getStarred() async {
    if (_jellyfin != null) return _jellyfin!.getStarred();
    if (_youtube != null) return _youtube!.getStarred();
    final response = await _request('getStarred2');
    final starred = response['starred2'];

    final artists = (starred?['artist'] as List?)
            ?.map((a) => Artist.fromJson(a as Map<String, dynamic>))
            .toList() ??
        [];

    final albums = (starred?['album'] as List?)
            ?.map((a) => Album.fromJson(a as Map<String, dynamic>))
            .toList() ??
        [];

    final songs = (starred?['song'] as List?)
            ?.map((s) => Song.fromJson(s as Map<String, dynamic>))
            .toList() ??
        [];

    return SearchResult(artists: artists, albums: albums, songs: songs);
  }

  Future<void> scrobble(String id, {bool submission = true, int? time}) async {
    if (_jellyfin != null) {
      await _jellyfin!.scrobble(id, submission: submission);
      return;
    }
    if (_youtube != null) {
      await _youtube!.scrobble(id, submission: submission);
      return;
    }
    final params = <String, String>{'id': id, 'submission': submission.toString()};
    // Subsonic api spec: time in milliseconds since 1 Jan 1970 (Navidrome docs: scrobble time ms)
    if (submission) {
      final t = time ?? DateTime.now().millisecondsSinceEpoch;
      params['time'] = t.toString();
    } else {
      // nowPlaying also benefits from explicit time on some Navidrome versions
      params['time'] = (time ?? DateTime.now().millisecondsSinceEpoch).toString();
    }
    try {
      await _request('scrobble', params);
      debugPrint('[KumaFlow] scrobble ${submission ? 'submission' : 'nowPlaying'} ok id=$id c=$_clientName');
    } catch (e) {
      debugPrint('[KumaFlow] scrobble ${submission ? 'submission' : 'nowPlaying'} failed id=$id: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> getLyrics({
    String? artist,
    String? title,
    String? id,
  }) async {
    if (_jellyfin != null && id != null) {
      final result = await _jellyfin!.getLyrics(id);
      if (result != null && result.containsKey('value')) return result;
      return null;
    }
    try {
      final params = <String, String>{};
      if (artist != null) params['artist'] = artist;
      if (title != null) params['title'] = title;

      final response = await _request('getLyrics', params);
      return response['lyrics'] as Map<String, dynamic>?;
    } catch (e) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> getLyricsBySongId(String songId) async {
    if (_jellyfin != null) {
      final result = await _jellyfin!.getLyrics(songId);
      if (result != null && result.containsKey('structuredLyrics'))
        return result;
      return null;
    }
    try {
      final response = await _request('getLyricsBySongId', {'id': songId});
      return response['lyricsList'] as Map<String, dynamic>?;
    } catch (e) {
      return null;
    }
  }

  Future<List<Genre>> getGenres() async {
    if (_jellyfin != null) return _jellyfin!.getGenres();
    if (_youtube != null) return _youtube!.getGenres();
    final response = await _request('getGenres');
    final genresData = response['genres']?['genre'];
    if (genresData is List) {
      return genresData
          .map((g) => Genre.fromJson(g as Map<String, dynamic>))
          .where((g) => g.value.isNotEmpty)
          .toList()
        ..sort((a, b) => a.value.compareTo(b.value));
    }
    return [];
  }

  Future<List<Song>> getSongsByGenre(
    String genre, {
    int count = 50,
    int offset = 0,
  }) async {
    if (_jellyfin != null)
      return _jellyfin!.getSongsByGenre(genre, size: count, offset: offset);
    if (_youtube != null)
      return _youtube!.getSongsByGenre(genre, size: count, offset: offset);
    final response = await _request('getSongsByGenre', {
      'genre': genre,
      'count': count.toString(),
      'offset': offset.toString(),
    });
    final songsData = response['songsByGenre']?['song'];
    // Single-song responses come as a Map, not a List.
    final List<dynamic> songsList;
    if (songsData is List) {
      songsList = songsData;
    } else if (songsData is Map) {
      songsList = [songsData];
    } else {
      return [];
    }
    final out = <Song>[];
    for (final s in songsList) {
      try {
        out.add(Song.fromJson((s as Map).cast<String, dynamic>()));
      } catch (_) {}
    }
    return out;
  }

  Future<List<Album>> getAlbumsByGenre(
    String genre, {
    int size = 50,
    int offset = 0,
  }) async {
    if (_jellyfin != null)
      return _jellyfin!.getAlbumsByGenre(genre, size: size, offset: offset);
    if (_youtube != null)
      return _youtube!.getAlbumsByGenre(genre, size: size, offset: offset);
    try {
      final response = await _request('getAlbumList2', {
        'type': 'byGenre',
        'genre': genre,
        'size': size.toString(),
        'offset': offset.toString(),
      });
      final albumsData = response['albumList2']?['album'];
      final List<dynamic> albumsList;
      if (albumsData is List) {
        albumsList = albumsData;
      } else if (albumsData is Map) {
        albumsList = [albumsData];
      } else {
        return [];
      }
      final out = <Album>[];
      for (final a in albumsList) {
        try {
          out.add(Album.fromJson((a as Map).cast<String, dynamic>()));
        } catch (_) {}
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  Future<Map<String, dynamic>> jukeboxControl(
    String action, {
    int? index,
    int? offset,
    List<String>? ids,
    double? gain,
  }) async {
    final params = <String, String>{'action': action};
    if (index != null) params['index'] = index.toString();
    if (offset != null) params['offset'] = offset.toString();
    if (gain != null) params['gain'] = gain.toStringAsFixed(2);

    String url = _buildUrl('jukeboxControl', params);
    if (ids != null) {
      for (final id in ids) {
        url += '&id=${Uri.encodeComponent(id)}';
      }
    }

    try {
      final response = await _dio.get(url);
      final data = response.data;
      final sr = data is String
          ? json.decode(data)['subsonic-response']
          : data['subsonic-response'];
      if (sr == null || sr['status'] != 'ok') {
        throw Exception(sr?['error']?['message'] ?? 'Jukebox error');
      }
      return sr['jukeboxStatus'] as Map<String, dynamic>? ??
          sr['jukeboxPlaylist'] as Map<String, dynamic>? ??
          {};
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status != null && status >= 500)
        throw Exception(
            'Server error ($status). The server failed to process the request.');
      throw Exception('Network error. Check your connection.');
    }
  }

  Future<Map<String, dynamic>> jukeboxGet() => jukeboxControl('get');
  Future<Map<String, dynamic>> jukeboxStatus() => jukeboxControl('status');
  Future<Map<String, dynamic>> jukeboxStart() => jukeboxControl('start');
  Future<Map<String, dynamic>> jukeboxStop() => jukeboxControl('stop');
  Future<Map<String, dynamic>> jukeboxSkip(int index, {int offset = 0}) =>
      jukeboxControl('skip', index: index, offset: offset);
  Future<Map<String, dynamic>> jukeboxAdd(List<String> ids) =>
      jukeboxControl('add', ids: ids);
  Future<Map<String, dynamic>> jukeboxClear() => jukeboxControl('clear');
  Future<Map<String, dynamic>> jukeboxSet(List<String> ids) =>
      jukeboxControl('set', ids: ids);
  Future<Map<String, dynamic>> jukeboxShuffle() => jukeboxControl('shuffle');
  Future<Map<String, dynamic>> jukeboxRemove(int index) =>
      jukeboxControl('remove', index: index);
  Future<Map<String, dynamic>> jukeboxSetGain(double gain) =>
      jukeboxControl('setGain', gain: gain);

  Future<List<RadioStation>> getInternetRadioStations() async {
    try {
      final response = await _request('getInternetRadioStations');
      final stationsData =
          response['internetRadioStations']?['internetRadioStation'];
      if (stationsData is List) {
        return stationsData
            .map((s) => RadioStation.fromJson(s as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  Future<void> createInternetRadioStation({
    required String name,
    required String streamUrl,
    String? homePageUrl,
  }) async {
    final params = <String, String>{'name': name, 'streamUrl': streamUrl};
    if (homePageUrl != null && homePageUrl.isNotEmpty) {
      params['homepageUrl'] = homePageUrl;
    }
    await _request('createInternetRadioStation', params);
  }

  Future<void> updateInternetRadioStation({
    required String id,
    required String name,
    required String streamUrl,
    String? homePageUrl,
  }) async {
    final params = <String, String>{
      'id': id,
      'name': name,
      'streamUrl': streamUrl,
    };
    if (homePageUrl != null && homePageUrl.isNotEmpty) {
      params['homepageUrl'] = homePageUrl;
    }
    await _request('updateInternetRadioStation', params);
  }

  Future<void> deleteInternetRadioStation(String id) async {
    await _request('deleteInternetRadioStation', {'id': id});
  }

  /// Navidrome/OpenSubsonic: getSimilarSongs* и getTopSongs требуют Last.fm —
  /// без него сервер отвечает ошибкой/пусто после долгого ожидания.
  /// Кэшируем негатив на час, чтобы не жечь по 8с на каждый трек
  /// (как делают Aonsoku/другие плееры — один быстрый запрос, дальше локально).
  bool? _similarSupported;
  DateTime? _similarUnsupportedUntil;

  bool get isSimilarSupported {
    if (_similarSupported == false) return false;
    if (_similarUnsupportedUntil != null &&
        DateTime.now().isBefore(_similarUnsupportedUntil!)) return false;
    return true;
  }

  Future<List<Song>> getSimilarSongs(String id, {int count = 50}) async {
    if (_jellyfin != null) return _jellyfin!.getSimilarSongs(id, count: count);
    if (_youtube != null) return _youtube!.getSimilarSongs(id, count: count);
    if (!isSimilarSupported) return <Song>[];
    // Один вариант (ID3), короткий таймаут. Раньше били в оба эндпоинта
    // параллельно по 8с — на Navidrome без Last.fm это стабильные 8с виса.
    try {
      final response = await _request('getSimilarSongs2', {
        'id': id,
        'count': count.toString(),
      }).timeout(const Duration(seconds: 4));
      final songsData = response['similarSongs2']?['song'];
      List<Song> out = const [];
      if (songsData is List) {
        out = songsData
            .map((s) => Song.fromJson(s as Map<String, dynamic>))
            .toList();
      } else if (songsData is Map) {
        out = [Song.fromJson(songsData.cast<String, dynamic>())];
      }
      if (out.isEmpty) {
        // Пусто дважды подряд — считаем неподдерживаемым на час.
        _similarUnsupportedUntil = DateTime.now().add(const Duration(hours: 1));
      } else {
        _similarSupported = true;
        _similarUnsupportedUntil = null;
      }
      return out;
    } catch (_) {
      _similarUnsupportedUntil = DateTime.now().add(const Duration(hours: 1));
      return <Song>[];
    }
  }

  Future<List<Song>> getArtistTopSongs(
    String artistId, {
    int count = 50,
  }) async {
    if (_jellyfin != null)
      return _jellyfin!.getArtistTopSongs(artistId, count: count);
    if (_youtube != null)
      return _youtube!.getArtistTopSongs(artistId, count: count);
    try {
      // getTopSongs тоже требует Last.fm — быстрые таймауты + кэш негатива
      // через isSimilarSupported (оба завязаны на Last.fm).
      if (!isSimilarSupported) throw Exception('Last.fm features unsupported');
      final artist = await getArtist(artistId).timeout(
        const Duration(seconds: 4),
      );

      final response = await _request('getTopSongs', {
        'artist': artist.name,
        'count': count.toString(),
      }).timeout(const Duration(seconds: 4));
      final songsData = response['topSongs']?['song'];
      if (songsData is List) {
        return songsData
            .map((s) => Song.fromJson(s as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      try {
        final albums = await getArtistAlbums(
          artistId,
        ).timeout(const Duration(seconds: 8));
        if (albums.isEmpty) return [];

        // Parallel fetch instead of sequential: much faster on remote servers
        final chunk = albums.take(3).toList();
        final results = await Future.wait(
          chunk.map(
            (a) => getAlbumSongs(
              a.id,
            ).timeout(const Duration(seconds: 8), onTimeout: () => <Song>[]),
          ),
        );
        return results.expand((s) => s).take(count).toList();
      } catch (_) {
        return [];
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════
  // Missing Subsonic API methods
  // ══════════════════════════════════════════════════════════════════════

  /// getSong - Returns details for a song by ID
  Future<Song?> getSong(String id) async {
    try {
      final response = await _request('getSong', {'id': id});
      final songData = response['song'];
      if (songData != null) {
        return Song.fromJson(songData as Map<String, dynamic>);
      }
      return null;
    } catch (e) {
      debugPrint('getSong error: $e');
      return null;
    }
  }

  /// getIndexes - Returns indexed structure of all artists (file-based)
  Future<Map<String, dynamic>> getIndexes({String? musicFolderId}) async {
    try {
      final params = <String, String>{};
      if (musicFolderId != null) params['musicFolderId'] = musicFolderId;
      return await _request('getIndexes', params);
    } catch (e) {
      debugPrint('getIndexes error: $e');
      return {};
    }
  }

  /// getMusicDirectory - Returns listing of files in a music directory
  Future<Map<String, dynamic>> getMusicDirectory(String id) async {
    try {
      return await _request('getMusicDirectory', {'id': id});
    } catch (e) {
      debugPrint('getMusicDirectory error: $e');
      return {};
    }
  }

  /// getSimilarSongs2 - Similar songs using ID3 tags
  Future<List<Song>> getSimilarSongs2(String id, {int count = 50}) async {
    try {
      final response = await _request('getSimilarSongs2', {
        'id': id,
        'count': count.toString(),
      });
      final songsData = response['similarSongs2']?['song'];
      if (songsData is List) {
        return songsData
            .map((s) => Song.fromJson(s as Map<String, dynamic>))
            .toList();
      }
      return await getSimilarSongs(id, count: count);
    } catch (e) {
      return await getSimilarSongs(id, count: count);
    }
  }

  /// getAlbumList2 - Album list using ID3 tags
  Future<List<Album>> getAlbumList2({
    required String type,
    int size = 20,
    int offset = 0,
  }) async {
    try {
      final response = await _request('getAlbumList2', {
        'type': type,
        'size': size.toString(),
        'offset': offset.toString(),
      });
      final albumData = response['albumList2']?['album'];
      if (albumData is List) {
        return albumData
            .map((a) => Album.fromJson(a as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      debugPrint('getAlbumList2 error: $e');
      return [];
    }
  }

  /// Probes whether the server supports search3 with albumOffset/songOffset.
  /// Returns true if search3 returns albums with an empty query.
  /// Navidrome поддерживает только простые autocomplete-запросы — пустой
  /// query может висеть, поэтому короткий таймаут 4с (раньше висел 10с+).
  Future<bool> probeSearch3() async {
    try {
      final response = await _request('search3', {
        'query': '',
        'albumCount': '1',
        'albumOffset': '0',
      }).timeout(const Duration(seconds: 4));
      final searchResult = response['searchResult3'];
      final albumList = searchResult?['album'];
      if (albumList is List && albumList.isNotEmpty) return true;
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Fetches a page of albums via search3 (empty query = all albums).
  /// Небольшие страницы (<=1000): сервер не строит гигантский ответ и не падает.
  Future<List<Album>> search3AlbumsPage({
    required int offset,
    int count = 1000,
  }) async {
    try {
      final response = await _request('search3', {
        'query': '',
        'albumCount': count.toString(),
        'albumOffset': offset.toString(),
      });
      final searchResult = response['searchResult3'];
      var albumList = searchResult?['album'];
      if (albumList != null && albumList is! List) {
        albumList = [albumList];
      }
      final raw = albumList as List?;
      if (raw == null || raw.isEmpty) return [];
      // Большие списки парсим в isolate, маленькие — inline (дешевле).
      final maps = raw.length > 200
          ? await compute(_parseAlbumsIsolate, raw)
          : raw.map((a) => Map<String, dynamic>.from(a as Map)).toList();
      return maps.map((a) => Album.fromJson(a)).toList();
    } catch (e) {
      debugPrint('search3AlbumsPage error: $e');
      return [];
    }
  }

  /// Fetches a page of songs via search3 (empty query = all songs).
  /// Небольшие страницы (<=1000): сервер не строит гигантский ответ и не падает.
  Future<List<Song>> search3SongsPage({
    required int offset,
    int count = 1000,
  }) async {
    try {
      final response = await _request('search3', {
        'query': '',
        'songCount': count.toString(),
        'songOffset': offset.toString(),
      });
      final searchResult = response['searchResult3'];
      var songList = searchResult?['song'];
      if (songList != null && songList is! List) {
        songList = [songList];
      }
      final raw = songList as List?;
      if (raw == null || raw.isEmpty) return [];
      final maps = raw.length > 200
          ? await compute(_parseSongsIsolate, raw)
          : raw.map((s) => Map<String, dynamic>.from(s as Map)).toList();
      return maps.map((s) => Song.fromJson(s)).toList();
    } catch (e) {
      debugPrint('search3SongsPage error: $e');
      return [];
    }
  }

  /// Fetches a page of artists via search3 (empty query = all artists).
  /// Covers the missing artistOffset pagination (albums/songs have it).
  Future<List<Artist>> search3ArtistsPage({
    required int offset,
    int count = 1000,
  }) async {
    if (_jellyfin != null) {
      return _jellyfin!.search(
        '',
        artistCount: count,
        artistOffset: offset,
        albumCount: 0,
        songCount: 0,
      ).then((r) => r.artists);
    }
    if (_youtube != null) return [];
    try {
      final response = await _request('search3', {
        'query': '',
        'artistCount': count.toString(),
        'artistOffset': offset.toString(),
      });
      final searchResult = response['searchResult3'];
      var artistList = searchResult?['artist'];
      if (artistList != null && artistList is! List) {
        artistList = [artistList];
      }
      return (artistList as List?)
              ?.map((a) {
                try {
                  return Artist.fromJson((a as Map).cast<String, dynamic>());
                } catch (_) {
                  return null;
                }
              })
              .whereType<Artist>()
              .toList() ??
          [];
    } catch (e) {
      debugPrint('search3ArtistsPage error: $e');
      return [];
    }
  }

  /// getNowPlaying - Returns what is currently being played
  Future<List<Map<String, dynamic>>> getNowPlaying() async {
    try {
      final response = await _request('getNowPlaying', {});
      final nowPlayingData = response['nowPlaying'];
      if (nowPlayingData is List) {
        return nowPlayingData.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      debugPrint('getNowPlaying error: $e');
      return [];
    }
  }

  /// search2 - Search using file structure
  Future<SearchResult> search2(
    String query, {
    int artistCount = 20,
    int albumCount = 20,
    int songCount = 20,
  }) async {
    return search(
      query,
      artistCount: artistCount,
      albumCount: albumCount,
      songCount: songCount,
    );
  }

  /// download - Download a media file (returns URL)
  String getDownloadUrl(String id) {
    return _buildUrl('download', {'id': id});
  }

  /// getBookmarks - Returns all bookmarks for this user
  Future<List<Map<String, dynamic>>> getBookmarks() async {
    try {
      final response = await _request('getBookmarks', {});
      final bookmarksData = response['bookmarks']?['bookmark'];
      if (bookmarksData is List) {
        return bookmarksData.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      debugPrint('getBookmarks error: $e');
      return [];
    }
  }

  /// createBookmark - Create or update a bookmark
  Future<void> createBookmark(
    String songId, {
    required int position,
    String? comment,
  }) async {
    try {
      final params = <String, String>{
        'id': songId,
        'position': position.toString(),
      };
      if (comment != null) params['comment'] = comment;
      await _request('createBookmark', params);
    } catch (e) {
      debugPrint('createBookmark error: $e');
    }
  }

  /// deleteBookmark - Delete a bookmark
  Future<void> deleteBookmark(String songId) async {
    try {
      await _request('deleteBookmark', {'id': songId});
    } catch (e) {
      debugPrint('deleteBookmark error: $e');
    }
  }

  /// getPlayQueue - Get saved play queue
  Future<Map<String, dynamic>> getPlayQueue() async {
    try {
      return await _request('getPlayQueue', {});
    } catch (e) {
      debugPrint('getPlayQueue error: $e');
      return {};
    }
  }

  /// savePlayQueue - Save play queue
  Future<void> savePlayQueue({
    required List<String> songIds,
    String? currentSongId,
    int? position,
  }) async {
    try {
      final params = <String, String>{};
      for (final id in songIds) {
        params['id'] = id;
      }
      if (currentSongId != null) params['current'] = currentSongId;
      if (position != null) params['position'] = position.toString();
      await _request('savePlayQueue', params);
    } catch (e) {
      debugPrint('savePlayQueue error: $e');
    }
  }

  /// getScanStatus - Get media library scan status
  Future<Map<String, dynamic>> getScanStatus() async {
    try {
      return await _request('getScanStatus', {});
    } catch (e) {
      debugPrint('getScanStatus error: $e');
      return {};
    }
  }

  /// startScan - Initiate media library rescan
  Future<void> startScan({bool fullScan = false}) async {
    try {
      final params = <String, String>{};
      if (fullScan) params['fullScan'] = 'true';
      await _request('startScan', params);
    } catch (e) {
      debugPrint('startScan error: $e');
    }
  }

  /// getAvatar - Get user avatar
  String getAvatarUrl(String username) {
    return _buildUrl('getAvatar', {'username': username});
  }

  /// getUser - Get user details
  Future<Map<String, dynamic>> getUser() async {
    try {
      return await _request('getUser', {});
    } catch (e) {
      debugPrint('getUser error: $e');
      return {};
    }
  }

  /// getShares - Get shared media
  Future<List<Map<String, dynamic>>> getShares() async {
    try {
      final response = await _request('getShares', {});
      final sharesData = response['shares']?['share'];
      if (sharesData is List) {
        return sharesData.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      debugPrint('getShares error: $e');
      return [];
    }
  }

  /// getChatMessages - Get chat messages
  Future<List<Map<String, dynamic>>> getChatMessages({int? since}) async {
    try {
      final params = <String, String>{};
      if (since != null) params['since'] = since.toString();
      final response = await _request('getChatMessages', params);
      final messagesData = response['chatMessages']?['chatMessage'];
      if (messagesData is List) {
        return messagesData.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      debugPrint('getChatMessages error: $e');
      return [];
    }
  }

  /// addChatMessage - Add a chat message
  Future<void> addChatMessage(String message) async {
    try {
      await _request('addChatMessage', {'message': message});
    } catch (e) {
      debugPrint('addChatMessage error: $e');
    }
  }

  /// getUsers - Get all users (admin only)
  Future<List<Map<String, dynamic>>> getUsers() async {
    try {
      final response = await _request('getUsers', {});
      final usersData = response['users']?['user'];
      if (usersData is List) {
        return usersData.cast<Map<String, dynamic>>();
      }
      return [];
    } catch (e) {
      debugPrint('getUsers error: $e');
      return [];
    }
  }
}

class SearchResult {
  final List<Artist> artists;
  final List<Album> albums;
  final List<Song> songs;

  SearchResult({
    required this.artists,
    required this.albums,
    required this.songs,
  });

  bool get isEmpty => artists.isEmpty && albums.isEmpty && songs.isEmpty;
}

class _TlsHttpOverrides extends HttpOverrides {
  final HttpClient Function() _factory;

  _TlsHttpOverrides(this._factory);

  @override
  HttpClient createHttpClient(SecurityContext? context) => _factory();
}

/// Bypasses [HttpOverrides.global] to create a real [HttpClient].
class _RealHttpOverrides extends HttpOverrides {}
