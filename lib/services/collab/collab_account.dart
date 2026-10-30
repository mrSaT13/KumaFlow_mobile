import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/server_config.dart';

/// Collab-аккаунт друга: отдельный Subsonic/Navidrome сервер.
/// Основной аккаунт не трогаем — эти креды используются только для
/// фонового чтения вкуса + стриминга чужих треков в коллаб-миксе.
class CollabAccount {
  final String id;
  final String serverUrl;
  final String username;
  final String password;
  final String label;
  final bool enabled;

  const CollabAccount({
    required this.id,
    required this.serverUrl,
    required this.username,
    required this.password,
    this.label = '',
    this.enabled = true,
  });

  String get displayLabel => label.isNotEmpty ? label : username;

  /// Конфиг для SubsonicService-клиента этого друга.
  ServerConfig toServerConfig() => ServerConfig(
        serverUrl: serverUrl,
        username: username,
        password: password,
        name: displayLabel,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'serverUrl': serverUrl,
        'username': username,
        'password': password,
        'label': label,
        'enabled': enabled,
      };

  factory CollabAccount.fromJson(Map<String, dynamic> json) => CollabAccount(
        id: json['id']?.toString() ?? '',
        serverUrl: json['serverUrl']?.toString() ?? '',
        username: json['username']?.toString() ?? '',
        password: json['password']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        enabled: json['enabled'] as bool? ?? true,
      );

  CollabAccount copyWith({
    String? serverUrl,
    String? username,
    String? password,
    String? label,
    bool? enabled,
  }) {
    return CollabAccount(
      id: id,
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      label: label ?? this.label,
      enabled: enabled ?? this.enabled,
    );
  }
}

/// Хранилище collab-аккаунтов (SharedPreferences, пароли — как у основного
/// конфига, без доп. шифрования на MVP).
class CollabAccountStore extends ChangeNotifier {
  static const _kKey = 'collab_accounts_v1';

  static final CollabAccountStore _instance = CollabAccountStore._internal();
  factory CollabAccountStore() => _instance;
  CollabAccountStore._internal();

  final List<CollabAccount> _accounts = [];
  bool _loaded = false;

  List<CollabAccount> get accounts => List.unmodifiable(_accounts);
  List<CollabAccount> get enabledAccounts =>
      _accounts.where((a) => a.enabled).toList();
  bool get isLoaded => _loaded;
  bool get hasAccounts => _accounts.isNotEmpty;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw != null && raw.isNotEmpty) {
        final list = json.decode(raw) as List;
        _accounts.clear();
        for (final e in list) {
          try {
            _accounts.add(CollabAccount.fromJson(e as Map<String, dynamic>));
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[Collab] load accounts failed: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kKey, json.encode(_accounts.map((a) => a.toJson()).toList()));
    } catch (e) {
      debugPrint('[Collab] persist accounts failed: $e');
    }
  }

  Future<CollabAccount> add({
    required String serverUrl,
    required String username,
    required String password,
    String label = '',
  }) async {
    await load();
    final acc = CollabAccount(
      id: 'collab_${DateTime.now().millisecondsSinceEpoch}',
      serverUrl: serverUrl.trim(),
      username: username.trim(),
      password: password,
      label: label.trim(),
    );
    _accounts.add(acc);
    await _persist();
    notifyListeners();
    return acc;
  }

  Future<void> remove(String id) async {
    _accounts.removeWhere((a) => a.id == id);
    await _persist();
    notifyListeners();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final i = _accounts.indexWhere((a) => a.id == id);
    if (i == -1) return;
    _accounts[i] = _accounts[i].copyWith(enabled: enabled);
    await _persist();
    notifyListeners();
  }

  CollabAccount? byId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final a in _accounts) {
      if (a.id == id) return a;
    }
    return null;
  }
}
