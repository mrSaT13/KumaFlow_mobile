import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../models/server_config.dart';
import '../services/services.dart';
import '../services/safe_image_cache_manager.dart';

enum AuthState {
  unknown,
  unauthenticated,
  authenticating,
  authenticated,
  offlineMode,
  serverUnreachable,
  error,
}

class AuthProvider extends ChangeNotifier {
  final SubsonicService _subsonicService;
  final StorageService _storageService;

  AuthState _state = AuthState.unknown;
  String? _error;
  ServerConfig? _config;
  bool _hasOfflineContent = false;

  AuthProvider(this._subsonicService, this._storageService) {
    _loadSavedConfig();
  }

  AuthState get state => _state;
  String? get error => _error;
  ServerConfig? get config => _config;
  bool get isAuthenticated => _state == AuthState.authenticated;
  bool get hasOfflineContent => _hasOfflineContent;
  bool _verifying = false;
  int _loginGeneration = 0;
  // Поколение проверки связи: повторный retry отменяет зависший цикл,
  // иначе кнопка «Повторить» молча ничего не делала (guard _verifying).
  int _verifyGen = 0;
  String? _lastError;
  String? get lastError => _lastError;

  Future<void> _loadSavedConfig() async {
    final config = await _storageService.getServerConfig();
    if (config != null && config.isValid) {
      _config = config;

      if (config.serverType == 'local') {
        OfflineService(
          baseUrl: config.serverUrl,
          subsonicUser: config.username,
          onOnlineRestored: retryConnection,
        ).setOfflineMode(true);
        _state = AuthState.offlineMode;
        notifyListeners();
        return;
      }

      await _subsonicService.configure(config);
      await _verifyConnection();
    } else {
      _state = AuthState.unauthenticated;
      notifyListeners();
    }
  }

  /// silent=true — тихая перепроверка поверх живого MainScreen (возврат сети):
  /// `authenticating` наружу не выставляем, сплэш не мигает. notify только
  /// если итог реально меняет экран (упал в unreachable / поднялся из офлайна).
  Future<void> _verifyConnection({bool silent = false}) async {
    // Новый вызов отменяет предыдущий зависший цикл вместо молчаливого return.
    _verifyGen++;
    final gen = _verifyGen;
    if (_verifying) {
      debugPrint('[Auth] _verifyConnection: restarting, previous cancelled');
    }
    _verifying = true;
    _lastError = null;
    final bool quiet =
        silent && (_state == AuthState.authenticated || _state == AuthState.offlineMode);
    try {
      // Как в эталоне: сохранённый serverUrl не трогаем и ни на что не
      // перезаписываем. Авто-гонка Smart Connect с перезаписью URL убрана
      // 12.10.2026 — она молча подменяла введённый адрес (воспринималось как
      // «сброс выбора сервера на исходный»).
      debugPrint('[Auth] _verifyConnection: pinging ${_config?.serverUrl}${quiet ? ' (silent re-auth, no splash)' : ''}');
      if (!quiet) {
        _state = AuthState.authenticating;
        notifyListeners();
      }

    PingResult? pingResult;
    // Было 3x10с + паузы = до ~34с виса на сплеше, потом 2x10с (~21с),
    // потом 2x12с. Теперь: первая попытка короткая (5с) — транзиент
    // (протухший A KeenDNS, залипший сокет) отваливается быстро и вторая
    // попытка идёт через свежий DNS-резолв; вторая длинная (12с) — для
    // медленных туннелей/PoP (9–20с, факт 12.10.2026). Как браузер:
    // залипшее соединение не держит UI, победа обычно за ~1–6с.
    // С 12.10.2026: интерсептор делает +1 ретрай на таймаут и до 3 на
    // чужой 410 NDNS внутри каждой попытки.
    const attemptTimeouts = [Duration(seconds: 5), Duration(seconds: 12)];
    final maxAttempts = attemptTimeouts.length;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      if (gen != _verifyGen) {
        debugPrint('[Auth] _verifyConnection aborted (stale gen)');
        return;
      }
      pingResult = await _subsonicService.pingWithError().timeout(
            attemptTimeouts[attempt - 1],
            onTimeout: () =>
                PingResult(success: false, error: 'Connection timed out'),
          );
      if (gen != _verifyGen) {
        debugPrint('[Auth] _verifyConnection aborted (stale gen)');
        return;
      }
      if (pingResult.success) break;
      debugPrint(
          '[Auth] Ping attempt $attempt/$maxAttempts failed: ${pingResult.error}');
      if (attempt < maxAttempts) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    if (gen != _verifyGen) {
      debugPrint('[Auth] _verifyConnection aborted (stale gen)');
      return;
    }
    if (pingResult!.success) {
      debugPrint(
          '[Auth] Ping OK — type=${pingResult.serverType} version=${pingResult.serverVersion}');
      if (_config != null) {
        final updatedConfig = _config!.copyWith(
          serverType: pingResult.serverType,
          serverVersion: pingResult.serverVersion,
        );
        if (updatedConfig.serverType != _config!.serverType ||
            updatedConfig.serverVersion != _config!.serverVersion) {
          _config = updatedConfig;
          await _storageService.saveServerConfig(updatedConfig);
        }
      }
      debugPrint('[Auth] State: authenticating → authenticated');
      _state = AuthState.authenticated;
      notifyListeners();

      // Тяжёлое (скан кэша, scrobbles) — строго в фон: экран должен
      // открыться мгновенно после ответа пинга, а не после init.
      unawaited(
        Future(() async {
          try {
            final offlineService = OfflineService(
              baseUrl: _config!.serverUrl,
              subsonicUser: _config!.username,
              onOnlineRestored: retryConnection,
            );
            await offlineService.initialize();
            offlineService.setOfflineMode(false);
            await offlineService.flushPendingScrobbles(_subsonicService);
          } catch (e) {
            debugPrint('[Auth] background online init error: $e');
          }
        }),
      );
    } else {
      // Сохраняем реальную ошибку чтобы экран показал её + URL,
      // а не generic «зависла». Подсказка про браузер/Keenetic:
      // чаще всего это IPv6/DNS или HTTPS через KeenDNS.
      _lastError = pingResult.error;
      debugPrint('[Auth] Ping failed: $_lastError');

      // Экран serverUnreachable (с кнопкой офлайна) — СРАЗУ, не после
      // скана кэша: hasOfflineContent подтянем фоном и обновим.
      // В тихом режиме экран не дёргаем: остаёмся на живом MainScreen,
      // следующий флэп сети или ручной повтор разрулит.
      if (quiet) {
        debugPrint('[Auth] silent re-auth failed, staying on MainScreen: $_lastError');
      } else {
        _state = AuthState.serverUnreachable;
        notifyListeners();
      }
      unawaited(
        Future(() async {
          try {
            final offlineService = OfflineService(
              baseUrl: _config!.serverUrl,
              subsonicUser: _config!.username,
              onOnlineRestored: retryConnection,
            );
            await offlineService.initialize();
            if (gen != _verifyGen) return;
            final hasContent = offlineService.getDownloadedCount() > 0;
            if (hasContent != _hasOfflineContent) {
              _hasOfflineContent = hasContent;
              notifyListeners();
            }
            debugPrint(
                '[Auth] offline content ready: $_hasOfflineContent');
          } catch (e) {
            debugPrint('[Auth] background offline init error: $e');
          }
        }),
      );
    }
    } finally {
      // Флаг сбрасывает только актуальный вызов, отменённый — нет.
      if (gen == _verifyGen) _verifying = false;
    }
  }

  void enterOfflineMode() {
    // Гасим висящий пинг: офлайн открывается мгновенно, stale-результат
    // пинга потом не выдернет экран обратно.
    _verifyGen++;
    try {
      _subsonicService.cancelPendingRequests('enter offline mode');
    } catch (_) {}
    OfflineService(
      baseUrl: _config?.serverUrl ?? '',
      subsonicUser: _config?.username ?? '',
      onOnlineRestored: retryConnection,
    ).setOfflineMode(true);
    _state = AuthState.offlineMode;
    notifyListeners();
  }

  Future<void> retryConnection({bool silent = false}) async {
    if (_config == null) return;
    await _subsonicService.configure(_config!);
    await _verifyConnection(silent: silent);
  }

  /// Тихая перепроверка для OfflineService.onOnlineRestored (VoidCallback):
  /// возврат сети обновляет фоном, без сплэша.
  void retryConnectionSilent() {
    retryConnection(silent: true);
  }

  /// Smart Connect: задать/очистить домашний LAN-URL (пусто = выкл).
  Future<void> setLocalUrl(String raw) async {
    if (_config == null) return;
    final v = ServerConfig.normalizeOther(raw);
    if (v.isEmpty) {
      _config = _config!.copyWith(clearLocalUrl: true);
    } else {
      _config = _config!.copyWith(localUrl: v);
    }
    await _storageService.saveServerConfig(_config!);
    await _storageService.saveProfile(_config!);
    notifyListeners();
  }

  Future<void> disconnect() async {
    _config = null;
    _state = AuthState.unauthenticated;
    await _storageService.clearAll();
    notifyListeners();
  }

  Future<bool> login({
    required String serverUrl,
    required String username,
    required String password,
    bool useLegacyAuth = false,
    bool allowSelfSignedCertificates = false,
    String? customCertificatePath,
    String? clientCertificatePath,
    String? clientCertificatePassword,
    String? profileName,
    String serverFamily = 'subsonic',
  }) async {
    debugPrint(
        '[Auth] login: user=$username server=$serverUrl family=$serverFamily');
    _loginGeneration++;
    final loginGen = _loginGeneration;
    _state = AuthState.authenticating;
    _error = null;
    notifyListeners();

    // YouTube Music: no server URL / credentials required
    if (serverFamily == 'youtube') {
      serverUrl = 'https://music.youtube.com';
    }

    // Local folder: skip server validation
    if (serverFamily == 'local') {
      final config = ServerConfig(
        serverUrl: 'local://localhost',
        username: 'local',
        password: '',
        serverFamily: 'local',
      );
      _config = config;
      await _storageService.saveServerConfig(config);
      debugPrint('[Auth] State: authenticating → authenticated (local mode)');
      _state = AuthState.authenticated;
      notifyListeners();
      return true;
    }

    final isJellyfin = serverFamily == 'jellyfin';
    String? jellyfinToken;
    String? jellyfinUserId;

    if (isJellyfin) {
      final tmpConfig = ServerConfig(
        serverUrl: serverUrl,
        username: username,
        password: password,
        allowSelfSignedCertificates: allowSelfSignedCertificates,
        serverFamily: 'jellyfin',
      );
      final jf = JellyfinService()..configure(tmpConfig);
      final authResp = await jf.authenticate(username, password);
      if (authResp == null) {
        _error = 'Jellyfin authentication failed. Check your credentials.';
        _state = AuthState.error;
        notifyListeners();
        return false;
      }
      jellyfinToken = authResp['AccessToken'] as String?;
      final user = authResp['User'] as Map<String, dynamic>?;
      jellyfinUserId = user?['Id'] as String?;
      if (jellyfinToken == null || jellyfinUserId == null) {
        _error = 'Jellyfin returned an unexpected response.';
        _state = AuthState.error;
        notifyListeners();
        return false;
      }
    }

    final config = ServerConfig(
      serverUrl: serverUrl,
      username: username,
      password: password,
      useLegacyAuth: useLegacyAuth,
      allowSelfSignedCertificates: allowSelfSignedCertificates,
      customCertificatePath: customCertificatePath,
      clientCertificatePath: clientCertificatePath,
      clientCertificatePassword: clientCertificatePassword,
      name: profileName,
      serverFamily: serverFamily,
      apiToken: jellyfinToken,
      userId: jellyfinUserId,
    );

    await _subsonicService.configure(config);

    try {
      final pingResult = await _subsonicService.pingWithError().timeout(
            const Duration(seconds: 12),
            onTimeout: () =>
                PingResult(success: false, error: 'Connection timed out'),
          );
      // Login был отменён/перезапущен пока висел ping — stale-результат игнорируем.
      if (loginGen != _loginGeneration) {
        debugPrint('[Auth] login: stale result ignored (gen $loginGen)');
        return false;
      }
      if (pingResult.success) {
        debugPrint(
            '[Auth] Login OK — type=${pingResult.serverType} version=${pingResult.serverVersion}');
        debugPrint('[Auth] State: authenticating → authenticated');
        final updatedConfig = config.copyWith(
          serverType: pingResult.serverType,
          serverVersion: pingResult.serverVersion,
        );
        _config = updatedConfig;
        await _storageService.saveServerConfig(updatedConfig);
        await _storageService.saveUsername(username);
        _state = AuthState.authenticated;
        notifyListeners();

        _storageService.saveProfile(updatedConfig).catchError(
              (e) => debugPrint('Error saving profile: $e'),
            );

        // Тяжёлую пост-синхронизацию (скан кэша, scrobbles) — в фон,
        // чтобы UI разблокировался сразу после верного пароля.
        unawaited(
          Future(() async {
            try {
              final offlineService = OfflineService(
                baseUrl: _config!.serverUrl,
                subsonicUser: _config!.username,
                onOnlineRestored: retryConnectionSilent,
              );
              await offlineService.initialize();
              await offlineService.flushPendingScrobbles(_subsonicService);
            } catch (e) {
              debugPrint('[Auth] background sync error: $e');
            }
          }),
        );
        return true;
      } else {
        _error =
            _formatError(pingResult.error ?? 'Failed to connect to server');
        debugPrint('[Auth] Login failed: $_error');
        debugPrint('[Auth] State: authenticating → error');
        _state = AuthState.error;
        notifyListeners();
        return false;
      }
    } catch (e) {
      if (loginGen != _loginGeneration) {
        debugPrint('[Auth] login: stale exception ignored (gen $loginGen)');
        return false;
      }
      _error = _formatError(e);
      debugPrint('[Auth] Login exception: $e');
      debugPrint('[Auth] State: authenticating → error (formatted: $_error)');
      _state = AuthState.error;
      notifyListeners();
      return false;
    }
  }

  String _formatError(dynamic error) {
    final errorStr = error.toString();
    if (errorStr.contains('Cancelled by user')) {
      return 'Login cancelled.';
    }
    if (errorStr.contains('SocketException') ||
        errorStr.contains('Connection refused') ||
        errorStr.contains('Connection failed') ||
        errorStr.contains('connection errored') ||
        errorStr.contains('Cannot connect')) {
      return 'Cannot connect to server. Check the URL and your internet connection.';
    } else if (errorStr.contains('HandshakeException') ||
        errorStr.contains('CERTIFICATE_VERIFY_FAILED') ||
        errorStr.contains('SSL certificate')) {
      return 'SSL certificate error. Enable "Allow Self-Signed Certificates" for custom CA servers.';
    } else if (errorStr.contains('TimeoutException') ||
        errorStr.contains('timed out')) {
      return 'Connection timed out. Check your server URL.';
    } else if (errorStr.contains('FormatException')) {
      return 'Invalid server URL format.';
    } else if (errorStr.contains('401') ||
        errorStr.contains('Unauthorized') ||
        errorStr.contains('Invalid username or password')) {
      return 'Invalid username or password.';
    } else if (errorStr.contains('404') ||
        errorStr.contains('Not Found') ||
        errorStr.contains('Server not found')) {
      return 'Server not found. Check your URL path.';
    } else {
      return errorStr
          .replaceAll('Exception:', '')
          .replaceAll('Network error:', '')
          .replaceAll(
              'This indicates an error which most likely cannot be solved by the library.',
              '')
          .trim();
    }
  }

  Future<void> setLocalOnlyMode(bool enabled) async {
    if (enabled) {
      _config = ServerConfig(
        serverUrl: 'local',
        username: 'local',
        password: '',
        serverType: 'local',
      );
      await _storageService.saveServerConfig(_config!);
      _state = AuthState.offlineMode;
    } else {
      _config = null;
      _state = AuthState.unauthenticated;
      await _storageService.clearAll();
    }
    notifyListeners();
  }

  bool get isLocalOnlyMode => _config?.serverType == 'local';

  void cancelAuth() {
    _loginGeneration++;
    try {
      _subsonicService.cancelPendingRequests();
    } catch (_) {}
    if (_state == AuthState.authenticating) {
      _state = AuthState.unauthenticated;
      _error = null;
      notifyListeners();
    }
  }

  Future<List<ServerConfig>> getSavedProfiles() =>
      _storageService.getSavedProfiles();

  Future<void> deleteProfile(ServerConfig profile) =>
      _storageService.deleteProfile(profile);

  Future<void> switchProfile(ServerConfig profile) async {
    _config = profile;
    await _storageService.saveServerConfig(profile);
    await _subsonicService.configure(profile);
    await _verifyConnection();
  }

  Future<void> updateSelectedMusicFolderIds(List<String> ids) async {
    if (_config == null) return;
    final updated = _config!.copyWith(selectedMusicFolderIds: ids);
    _config = updated;
    await _subsonicService.configure(updated);
    await _storageService.saveServerConfig(updated);
    notifyListeners();
  }

  Future<void> logout() async {
    final offlineService = OfflineService();
    if (offlineService.isBackgroundDownloadActive) {
      offlineService.cancelBackgroundDownload();
    }

    try {
      await DefaultCacheManager().emptyCache();
    } catch (_) {}
    try {
      await SafeImageCacheManager.instance.emptyCache();
    } catch (_) {}
    try {
      await BpmAnalyzerService().clearCache();
    } catch (_) {}
    try {
      await offlineService.deleteAllDownloads();
    } catch (_) {}
    try {
      await AndroidAutoService().dispose();
    } catch (_) {}
    try {
      await AndroidSystemService().dispose();
    } catch (_) {}
    try {
      await SamsungIntegrationService().dispose();
    } catch (_) {}
    try {
      await BluetoothAvrcpService().dispose();
    } catch (_) {}

    await _storageService.clearAll();

    _config = null;
    _state = AuthState.unauthenticated;
    notifyListeners();
  }
}
