class ServerConfig {
  /// Основной (исходный) URL профиля. Используется как идентификатор профиля
  /// (serverUrl + username) и как адрес по умолчанию.
  final String serverUrl;
  final String username;
  final String password;
  final bool useLegacyAuth;
  final bool allowSelfSignedCertificates;
  final List<String> selectedMusicFolderIds;
  final String? serverType;
  final String? serverVersion;
  final String? customCertificatePath;
  final String? clientCertificatePath;
  final String? clientCertificatePassword;
  final String? name;
  final String serverFamily;
  final String? apiToken;
  final String? userId;

  /// Дополнительные (запасные) адреса того же сервера.
  final List<String> backupUrls;

  /// Текущий активный адрес. Если null/пусто — используется [serverUrl].
  final String? activeUrl;

  /// Устаревшее поле (домашний/LAN URL из старого Smart Connect). Читается
  /// для миграции и пишется для обратной совместимости.
  final String? localUrl;

  ServerConfig({
    required this.serverUrl,
    required this.username,
    required this.password,
    this.useLegacyAuth = false,
    this.allowSelfSignedCertificates = false,
    this.selectedMusicFolderIds = const [],
    this.serverType,
    this.serverVersion,
    this.customCertificatePath,
    this.clientCertificatePath,
    this.clientCertificatePassword,
    this.name,
    this.serverFamily = 'subsonic',
    this.apiToken,
    this.userId,
    this.backupUrls = const [],
    this.activeUrl,
    this.localUrl,
  });

  bool get isJellyfin => serverFamily == 'jellyfin';

  /// Эффективный (активный) адрес для подключений.
  String get effectiveUrl {
    final active = activeUrl?.trim() ?? '';
    return active.isNotEmpty ? active : serverUrl;
  }

  /// Нормализованный эффективный URL — используется всеми запросами.
  String get normalizedUrl => _normalizeBase(effectiveUrl, httpsByDefault: true);

  /// Нормализованный основной (исходный) URL.
  String get normalizedPrimaryUrl =>
      _normalizeBase(serverUrl, httpsByDefault: true);

  /// Все известные адреса: основной + запасные (без дублей, в порядке).
  List<String> get allServerUrls {
    final result = <String>[];
    void add(String? url) {
      final v = (url ?? '').trim();
      if (v.isEmpty) return;
      if (!result.contains(v)) result.add(v);
    }

    add(serverUrl);
    for (final b in backupUrls) {
      add(b);
    }
    return result;
  }

  /// Совместимость: кандидаты для подключения (активный первым, затем остальные).
  List<String> get connectCandidates {
    final active = effectiveUrl.trim();
    final result = <String>[];
    if (active.isNotEmpty) result.add(active);
    for (final u in allServerUrls) {
      if (!result.contains(u)) result.add(u);
    }
    return result;
  }

  static String _normalizeBase(String raw, {required bool httpsByDefault}) {
    var url = raw.trim();
    if (url.isEmpty) return '';
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = '${httpsByDefault ? 'https' : 'http'}://$url';
    }
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// Нормализация произвольного URL (без схемы → http://), как раньше для LAN.
  static String normalizeOther(String raw) =>
      _normalizeBase(raw, httpsByDefault: false);

  /// Нормализация адреса сервера (без схемы → https://).
  static String normalizeServerUrl(String raw) =>
      _normalizeBase(raw, httpsByDefault: true);

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    final rawBackups = (json['backupUrls'] as List<dynamic>?)
            ?.map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList() ??
        <String>[];

    // Миграция: старый одиночный localUrl -> первый запасной.
    final legacyLocal = (json['localUrl'] as String?)?.trim() ?? '';
    final backups = [...rawBackups];
    if (legacyLocal.isNotEmpty && !backups.contains(legacyLocal)) {
      backups.insert(0, legacyLocal);
    }

    final active = (json['activeUrl'] as String?)?.trim();

    return ServerConfig(
      serverUrl: json['serverUrl'] ?? '',
      username: json['username'] ?? '',
      password: json['password'] ?? '',
      useLegacyAuth: json['useLegacyAuth'] ?? false,
      allowSelfSignedCertificates:
          json['allowSelfSignedCertificates'] ?? false,
      selectedMusicFolderIds:
          (json['selectedMusicFolderIds'] as List<dynamic>?)
                  ?.map((e) => e.toString())
                  .toList() ??
              [],
      serverType: json['serverType'],
      serverVersion: json['serverVersion'],
      customCertificatePath: json['customCertificatePath'],
      clientCertificatePath: json['clientCertificatePath'],
      clientCertificatePassword: json['clientCertificatePassword'],
      name: json['name'] as String?,
      serverFamily: json['serverFamily'] as String? ?? 'subsonic',
      apiToken: json['apiToken'] as String?,
      userId: json['userId'] as String?,
      backupUrls: backups,
      activeUrl: (active != null && active.isNotEmpty) ? active : null,
      // Для обратной совместимости оставляем localUrl, если был.
      localUrl: legacyLocal.isNotEmpty ? legacyLocal : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'serverUrl': serverUrl,
      'username': username,
      'password': password,
      'useLegacyAuth': useLegacyAuth,
      'allowSelfSignedCertificates': allowSelfSignedCertificates,
      'selectedMusicFolderIds': selectedMusicFolderIds,
      'serverType': serverType,
      'serverVersion': serverVersion,
      'customCertificatePath': customCertificatePath,
      'clientCertificatePath': clientCertificatePath,
      'clientCertificatePassword': clientCertificatePassword,
      'name': name,
      'serverFamily': serverFamily,
      'apiToken': apiToken,
      'userId': userId,
      'backupUrls': backupUrls,
      'activeUrl': activeUrl,
      // Совместимость со старыми версиями: localUrl = первый запасной, если есть.
      'localUrl': localUrl ?? (backupUrls.isNotEmpty ? backupUrls.first : null),
    };
  }

  ServerConfig copyWith({
    String? serverUrl,
    String? username,
    String? password,
    bool? useLegacyAuth,
    bool? allowSelfSignedCertificates,
    List<String>? selectedMusicFolderIds,
    String? serverType,
    String? serverVersion,
    String? customCertificatePath,
    String? clientCertificatePath,
    String? clientCertificatePassword,
    String? name,
    String? serverFamily,
    String? apiToken,
    String? userId,
    List<String>? backupUrls,
    String? activeUrl,
    bool clearActiveUrl = false,
    String? localUrl,
    bool clearLocalUrl = false,
  }) {
    return ServerConfig(
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      useLegacyAuth: useLegacyAuth ?? this.useLegacyAuth,
      allowSelfSignedCertificates:
          allowSelfSignedCertificates ?? this.allowSelfSignedCertificates,
      selectedMusicFolderIds:
          selectedMusicFolderIds ?? this.selectedMusicFolderIds,
      serverType: serverType ?? this.serverType,
      serverVersion: serverVersion ?? this.serverVersion,
      customCertificatePath:
          customCertificatePath ?? this.customCertificatePath,
      clientCertificatePath:
          clientCertificatePath ?? this.clientCertificatePath,
      clientCertificatePassword:
          clientCertificatePassword ?? this.clientCertificatePassword,
      name: name ?? this.name,
      serverFamily: serverFamily ?? this.serverFamily,
      apiToken: apiToken ?? this.apiToken,
      userId: userId ?? this.userId,
      backupUrls: backupUrls ?? this.backupUrls,
      activeUrl: clearActiveUrl ? null : (activeUrl ?? this.activeUrl),
      localUrl: clearLocalUrl ? null : (localUrl ?? this.localUrl),
    );
  }

  bool get isValid {
    return serverUrl.isNotEmpty && username.isNotEmpty && password.isNotEmpty;
  }
}
