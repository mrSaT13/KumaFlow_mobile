class ServerConfig {
  final String serverUrl;
  final String username;
  final String password;
  final bool useLegacyAuth;
  final bool allowSelfSignedCertificates;
  final List<String> selectedMusicFolderIds;
  final String? serverType;
  final String? serverVersion;
  final String?
  customCertificatePath;
  final String?
  clientCertificatePath;
  final String?
  clientCertificatePassword;
  final String? name;
  final String serverFamily;
  final String? apiToken;
  final String? userId;
  /// Домашний URL (LAN) для Smart Connect: дома ходим напрямую без
  /// KeenDNS-hairpin, снаружи — по основному serverUrl. Пусто = выкл.
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
    this.localUrl,
  });

  bool get isJellyfin => serverFamily == 'jellyfin';

  /// Все кандидаты для гонки Smart Connect (LAN первым).
  List<String> get connectCandidates {
    final out = <String>[];
    final lan = (localUrl ?? '').trim();
    if (lan.isNotEmpty) out.add(lan);
    if (serverUrl.trim().isNotEmpty &&
        !out.contains(serverUrl.trim())) {
      out.add(serverUrl.trim());
    }
    return out;
  }

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      serverUrl: json['serverUrl'] ?? '',
      username: json['username'] ?? '',
      password: json['password'] ?? '',
      useLegacyAuth: json['useLegacyAuth'] ?? false,
      allowSelfSignedCertificates: json['allowSelfSignedCertificates'] ?? false,
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
      localUrl: json['localUrl'] as String?,
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
      'localUrl': localUrl,
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
      localUrl: clearLocalUrl ? null : (localUrl ?? this.localUrl),
    );
  }

  String get normalizedUrl {
    String url = serverUrl.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  static String normalizeOther(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return '';
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  bool get isValid {
    return serverUrl.isNotEmpty && username.isNotEmpty && password.isNotEmpty;
  }
}
