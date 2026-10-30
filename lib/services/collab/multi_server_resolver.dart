import 'package:flutter/foundation.dart';
import '../../models/server_config.dart';
import '../../models/song.dart';
import '../subsonic_service.dart';
import 'collab_account.dart';

/// Резолвер URL для мульти-серверного коллаб-микса.
///
/// Трек1 может быть с основного сервера, трек2 — с сервера друга.
/// Плеер спрашивает резолвер: «каким клиентом играть этот Song?»
/// и получает правильный stream/cover URL + правильный клиент для scrobble.
///
/// Клиенты друзей ленивые: создаются 1 раз на аккаунт и переиспользуются.
/// Тяжелых списков не храним — только map id -> SubsonicService.
class MultiServerResolver extends ChangeNotifier {
  final SubsonicService _main;
  final Map<String, SubsonicService> _clients = {};
  final Map<String, String> _labels = {};

  MultiServerResolver(this._main);

  SubsonicService get main => _main;

  /// Зарегистрировать (или обновить) клиента друга. Легковесно:
  /// один Dio на аккаунт, создается один раз.
  Future<SubsonicService> registerAccount(CollabAccount account) async {
    final existing = _clients[account.id];
    if (existing != null) return existing;
    final svc = SubsonicService();
    await svc.configure(ServerConfig(
      serverUrl: account.serverUrl,
      username: account.username,
      password: account.password,
      name: account.displayLabel,
    ));
    _clients[account.id] = svc;
    _labels[account.id] = account.displayLabel;
    return svc;
  }

  void unregister(String accountId) {
    _clients.remove(accountId);
    _labels.remove(accountId);
    notifyListeners();
  }

  bool hasClient(String? serverId) =>
      serverId != null && serverId.isNotEmpty && _clients.containsKey(serverId);

  SubsonicService clientFor(Song song) {
    final id = song.sourceServerId;
    if (id == null || id.isEmpty) return _main;
    return _clients[id] ?? _main;
  }

  String labelFor(Song song) {
    if (!song.isRemoteCollab) return '';
    return song.sourceLabel ??
        _labels[song.sourceServerId] ??
        'друг';
  }

  /// Правильный stream URL с учетом сервера-владельца трека.
  Future<String> resolveStreamUrl(
    Song song, {
    int? maxBitRate,
    String? format,
  }) async {
    if (!song.isRemoteCollab) {
      if (maxBitRate != null || format != null) {
        return _main.getStreamUrl(song.id,
            maxBitRate: maxBitRate, format: format);
      }
      return _main.resolveStreamUrlAsync(song);
    }
    final client = _clients[song.sourceServerId];
    if (client == null) {
      debugPrint(
          '[Collab] no client for ${song.sourceServerId}, fallback to main for ${song.id}');
      return _main.resolveStreamUrlAsync(song);
    }
    if (maxBitRate != null || format != null) {
      return client.getStreamUrl(song.id,
          maxBitRate: maxBitRate, format: format);
    }
    // Subsonic-семья: синхронный URL. YouTube-ветка внутри клиента
    // сама разрулит асинхронный manifest.
    return client.resolveStreamUrlAsync(song);
  }

  /// Правильный cover URL с учетом сервера-владельца трека.
  String resolveCoverUrl(Song song, {int size = 300}) {
    final cover = song.coverArt;
    if (cover == null || cover.isEmpty) return '';
    if (cover.startsWith('http://') || cover.startsWith('https://')) {
      return cover;
    }
    if (!song.isRemoteCollab) return _main.getCoverArtUrl(cover, size: size);
    final client = _clients[song.sourceServerId];
    if (client == null) return _main.getCoverArtUrl(cover, size: size);
    return client.getCoverArtUrl(cover, size: size);
  }

  /// Scrobble на сервер-владелец трека. Для чужих — best effort, тихо.
  Future<void> scrobble(Song song, {bool submission = false}) async {
    try {
      if (!song.isRemoteCollab) {
        await _main.scrobble(song.id, submission: submission);
        return;
      }
      final client = _clients[song.sourceServerId];
      if (client == null) return;
      await client.scrobble(song.id, submission: submission);
    } catch (_) {}
  }
}
