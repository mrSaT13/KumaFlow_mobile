import 'dart:async';
import '../../models/song.dart';
import '../subsonic_service.dart';
import 'kumaflow_brain_bridge.dart';
import 'kumaflow_brain_client.dart';
import 'kumaflow_brain_mapper.dart';
import 'kumaflow_brain_wave_resolver.dart';

/// M5: радио/weekly в playback (не только тестовая кнопка).
/// POST /api/wave/seed (радио по артисту/треку) и weeklyDiscovery(n)
/// резолвятся через KumaFlowBrainWaveResolver как в _getKumaFlowBrainSongs:
/// серверные uuid обогащаем через getTrack() (title/artist) и ищем
/// в Navidrome через search — missing складываем в exclude следующего wave.
/// Всё best-effort: ошибка сети = KumaFlowBrainException наружу (UI покажет снэк).
class KumaFlowBrainPlayback {
  /// Обогатить серверный uuid человекочитаемыми полями для резолва.
  /// getTrack() не отдаёт external_id — резолв идёт через search(title+artist).
  static Future<KumaFlowBrainTrack?> _enrich(
    KumaFlowBrainClient client,
    String uuid, {
    String fallbackTitle = '',
    String reason = '',
  }) async {
    try {
      final d = await client
          .getTrack(uuid)
          .timeout(const Duration(seconds: 8));
      final title = (d['title'] ?? '').toString();
      final artist =
          (d['artist_name'] ?? d['artist'] ?? '').toString();
      final t = title.isNotEmpty ? title : fallbackTitle;
      if (t.isEmpty && artist.isEmpty) return null;
      return KumaFlowBrainTrack(
        trackId: uuid,
        title: t,
        artist: artist,
        score: 0,
        reason: reason.isNotEmpty ? reason : 'seed-radio',
      );
    } catch (_) {
      if (fallbackTitle.isEmpty) return null;
      return KumaFlowBrainTrack(
        trackId: uuid,
        title: fallbackTitle,
        artist: '',
        score: 0,
        reason: reason.isNotEmpty ? reason : 'seed-radio',
      );
    }
  }

  /// Радио по артисту: POST /api/wave/seed {kind: artist, artist_name}
  /// -> items[{track_id, external_id, ...}] v0.3.4 (+ автоплейлист «Волна по …»).
  /// Играем по items[].external_id напрямую; legacy tracks[uuid]+getTrack —
  /// только если items нет (старый сервер).
  static Future<List<Song>> startArtistRadio({
    required KumaFlowBrainBridge bridge,
    required SubsonicService subsonic,
    required String artistName,
  }) async {
    final client = bridge.client;
    if (client == null) {
      throw KumaFlowBrainException('KumaFlow Brain выключен (тумблер/URL/user_id)');
    }
    final name = artistName.trim();
    if (name.isEmpty) throw KumaFlowBrainException('Пустое имя артиста');
    final res = await client
        .waveSeedStart(userId: bridge.settings.userId, kind: 'artist', artistName: name)
        .timeout(const Duration(seconds: 25));
    var tracks = KumaFlowBrainMapper.parseSeedItems(res);
    if (tracks.isEmpty) {
      final raw = res['tracks'];
      final ids = raw is List
          ? raw.map((e) => e.toString()).where((e) => e.isNotEmpty).take(30).toList()
          : const <String>[];
      if (ids.isEmpty) {
        final err = (res['error'] ?? '').toString();
        throw KumaFlowBrainException(
            err.isNotEmpty ? err : 'Сид не нашёлся в играбельной библиотеке');
      }
      final enriched = await Future.wait(ids.map((id) => _enrich(client, id)));
      tracks = enriched.whereType<KumaFlowBrainTrack>().toList();
    }
    if (tracks.isEmpty) throw KumaFlowBrainException('Нечем играть (пусто)');
    final resolved = await KumaFlowBrainWaveResolver(subsonic)
        .resolve(tracks, maxTracks: 30)
        .timeout(const Duration(seconds: 60));
    if (resolved.missing.isNotEmpty) {
      bridge.noteMissing(resolved.missing.map((t) => t.trackId));
    }
    return resolved.found.map((r) => r.song).toList();
  }

  /// Радио по треку: POST /api/wave/seed {kind: track, track_id}.
  static Future<List<Song>> startTrackRadio({
    required KumaFlowBrainBridge bridge,
    required SubsonicService subsonic,
    required String trackId,
  }) async {
    final client = bridge.client;
    if (client == null) {
      throw KumaFlowBrainException('KumaFlow Brain выключен (тумблер/URL/user_id)');
    }
    final res = await client
        .waveSeedStart(userId: bridge.settings.userId, kind: 'track', trackId: trackId)
        .timeout(const Duration(seconds: 25));
    var tracks = KumaFlowBrainMapper.parseSeedItems(res);
    if (tracks.isEmpty) {
      final raw = res['tracks'];
      final ids = raw is List
          ? raw.map((e) => e.toString()).where((e) => e.isNotEmpty).take(30).toList()
          : const <String>[];
      if (ids.isEmpty) throw KumaFlowBrainException('Сид не нашёлся в библиотеке');
      final enriched = await Future.wait(ids.map((id) => _enrich(client, id)));
      tracks = enriched.whereType<KumaFlowBrainTrack>().toList();
    }
    if (tracks.isEmpty) throw KumaFlowBrainException('Нечем играть (пусто)');
    final resolved = await KumaFlowBrainWaveResolver(subsonic)
        .resolve(tracks, maxTracks: 30)
        .timeout(const Duration(seconds: 60));
    if (resolved.missing.isNotEmpty) {
      bridge.noteMissing(resolved.missing.map((t) => t.trackId));
    }
    return resolved.found.map((r) => r.song).toList();
  }

  /// Weekly Discovery: weeklyDiscovery(n) -> explanations -> резолв
  /// через KumaFlowBrainWaveResolver (как в _getKumaFlowBrainSongs).
  static Future<List<Song>> fetchWeekly({
    required KumaFlowBrainBridge bridge,
    required SubsonicService subsonic,
    int n = 30,
  }) async {
    final client = bridge.client;
    if (client == null) {
      throw KumaFlowBrainException('KumaFlow Brain выключен (тумблер/URL/user_id)');
    }
    final res = await client
        .weeklyDiscovery(bridge.settings.userId, n: n.clamp(5, 100))
        .timeout(const Duration(seconds: 30));
    final raw = res['explanations'];
    final expl = raw is List
        ? raw.whereType<Map>().map(Map<String, dynamic>.from).toList()
        : const <Map<String, dynamic>>[];
    if (expl.isEmpty) throw KumaFlowBrainException('Открытий пока нет');
    final tracks = <KumaFlowBrainTrack>[];
    // Обогащаем параллельно: uuid -> title/artist для search-резолва.
    final enriched = await Future.wait(expl.take(n).map((e) async {
      final id = (e['track_id'] ?? '').toString();
      if (id.isEmpty) return null;
      final reason = (e['text'] ?? '').toString();
      final fallback = (e['because_of_title'] ?? '').toString();
      final t = await _enrich(client, id,
          fallbackTitle: fallback, reason: reason);
      if (t == null) return null;
      if (reason.isNotEmpty) {
        return KumaFlowBrainTrack(
          trackId: t.trackId,
          title: t.title,
          artist: t.artist,
          score: (e['score'] is num)
              ? (e['score'] as num).toDouble()
              : t.score,
          reason: reason,
        );
      }
      return t;
    }));
    tracks.addAll(enriched.whereType<KumaFlowBrainTrack>());
    if (tracks.isEmpty) throw KumaFlowBrainException('Не резолвится (пусто)');
    final resolved = await KumaFlowBrainWaveResolver(subsonic)
        .resolve(tracks, maxTracks: n)
        .timeout(const Duration(seconds: 90));
    if (resolved.missing.isNotEmpty) {
      bridge.noteMissing(resolved.missing.map((t) => t.trackId));
    }
    final found = resolved.found.map((r) => r.song).toList();
    if (found.isEmpty) throw KumaFlowBrainException('Треков нет в библиотеке');
    return found;
  }
}
