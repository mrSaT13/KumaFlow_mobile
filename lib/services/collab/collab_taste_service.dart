import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/song.dart';
import '../subsonic_service.dart';
import 'collab_account.dart';
import 'multi_server_resolver.dart';

/// Вкус одного друга: залайканные треки + гистограммы.
/// Хранится локально, собирается фоново строго по 1 аккаунту за раз.
class CollabTaste {
  final String accountId;
  final List<Song> starred;
  final Map<String, int> topArtists;
  final Map<String, int> topGenres;
  final DateTime? updatedAt;
  final String? error;

  const CollabTaste({
    required this.accountId,
    this.starred = const [],
    this.topArtists = const {},
    this.topGenres = const {},
    this.updatedAt,
    this.error,
  });

  bool get hasData => starred.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'starred': starred.map((s) => s.toJson()).toList(),
        'topArtists': topArtists,
        'topGenres': topGenres,
        'updatedAt': updatedAt?.toIso8601String(),
        'error': error,
      };

  factory CollabTaste.fromJson(Map<String, dynamic> json) {
    final songs = <Song>[];
    final raw = json['starred'] as List?;
    if (raw != null) {
      for (final e in raw) {
        try {
          songs.add(Song.fromJson(e as Map<String, dynamic>));
        } catch (_) {}
      }
    }
    return CollabTaste(
      accountId: json['accountId']?.toString() ?? '',
      starred: songs,
      topArtists: Map<String, int>.from(json['topArtists'] ?? {}),
      topGenres: Map<String, int>.from(json['topGenres'] ?? {}),
      updatedAt: json['updatedAt'] != null
          ? DateTime.tryParse(json['updatedAt'].toString())
          : null,
      error: json['error']?.toString(),
    );
  }
}

/// Фоновый сбор вкусов друзей — строго последовательно, с паузами и
/// лимитами, чтобы не словить OOM и не душить сервер(а).
class CollabTasteService extends ChangeNotifier {
  static const _kKey = 'collab_tastes_v1';
  static const int maxStarredPerAccount = 200;
  static const Duration staleAfter = Duration(hours: 24);

  static final CollabTasteService _instance = CollabTasteService._internal();
  factory CollabTasteService() => _instance;
  CollabTasteService._internal();

  final Map<String, CollabTaste> _tastes = {};
  bool _loaded = false;
  bool _refreshing = false;
  String? _refreshStatus;

  bool get isRefreshing => _refreshing;
  String? get refreshStatus => _refreshStatus;

  CollabTaste? tasteFor(String accountId) => _tastes[accountId];

  int get totalTracks =>
      _tastes.values.fold(0, (sum, t) => sum + t.starred.length);

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw != null && raw.isNotEmpty) {
        final map = json.decode(raw) as Map<String, dynamic>;
        _tastes.clear();
        for (final entry in map.entries) {
          try {
            _tastes[entry.key] =
                CollabTaste.fromJson(entry.value as Map<String, dynamic>);
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[Collab] load tastes failed: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kKey, json.encode(_tastes.map((k, v) => MapEntry(k, v.toJson()))));
    } catch (e) {
      debugPrint('[Collab] persist tastes failed: $e');
    }
  }

  bool isStale(String accountId) {
    final t = _tastes[accountId];
    if (t == null || t.updatedAt == null) return true;
    return DateTime.now().difference(t.updatedAt!) > staleAfter;
  }

  /// Обновить вкус одного аккаунта. Безопасно вызывать из UI.
  Future<CollabTaste> refreshAccount(
    CollabAccount account, {
    MultiServerResolver? resolver,
  }) async {
    await load();
    try {
      SubsonicService client;
      if (resolver != null) {
        client = await resolver.registerAccount(account);
      } else {
        client = SubsonicService();
        await client.configure(account.toServerConfig());
      }
      final starred = await client
          .getStarred()
          .timeout(const Duration(seconds: 25), onTimeout: () {
        throw TimeoutException('getStarred timeout for ${account.username}');
      });
      final songs = starred.songs
          .take(maxStarredPerAccount)
          .map((s) => s.copyWith(
                sourceServerId: account.id,
                sourceLabel: account.displayLabel,
              ))
          .toList();
      final artists = <String, int>{};
      final genres = <String, int>{};
      for (final s in songs) {
        final a = (s.artist ?? '').trim();
        if (a.isNotEmpty) artists[a] = (artists[a] ?? 0) + 1;
        final g = (s.genre ?? '').trim();
        if (g.isNotEmpty) genres[g] = (genres[g] ?? 0) + 1;
      }
      final taste = CollabTaste(
        accountId: account.id,
        starred: songs,
        topArtists: artists,
        topGenres: genres,
        updatedAt: DateTime.now(),
      );
      _tastes[account.id] = taste;
      await _persist();
      notifyListeners();
      return taste;
    } catch (e) {
      final prev = _tastes[account.id];
      final failed = CollabTaste(
        accountId: account.id,
        starred: prev?.starred ?? const [],
        topArtists: prev?.topArtists ?? const {},
        topGenres: prev?.topGenres ?? const {},
        updatedAt: prev?.updatedAt,
        error: e.toString().length > 140
            ? '${e.toString().substring(0, 140)}…'
            : e.toString(),
      );
      _tastes[account.id] = failed;
      await _persist();
      notifyListeners();
      return failed;
    }
  }

  /// Обновить вкусы всех включенных аккаунтов — строго по очереди.
  Future<void> refreshAll({
    MultiServerResolver? resolver,
    void Function(int done, int total, String label)? onProgress,
  }) async {
    if (_refreshing) return;
    await CollabAccountStore().load();
    final accounts = CollabAccountStore().enabledAccounts;
    _refreshing = true;
    notifyListeners();
    try {
      for (var i = 0; i < accounts.length; i++) {
        final acc = accounts[i];
        _refreshStatus = 'Читаю ${acc.displayLabel} (${i + 1}/${accounts.length})…';
        notifyListeners();
        onProgress?.call(i, accounts.length, acc.displayLabel);
        await refreshAccount(acc, resolver: resolver);
        // Пауза между серверами — не душим сеть/батарею.
        if (i < accounts.length - 1) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
    } finally {
      _refreshing = false;
      _refreshStatus = null;
      notifyListeners();
    }
  }

  /// Удалить кэш вкуса (например при удалении друга).
  Future<void> clearTaste(String accountId) async {
    _tastes.remove(accountId);
    await _persist();
    notifyListeners();
  }
}
