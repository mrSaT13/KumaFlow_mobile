import '../../models/ml/ml_types.dart';

/// Маппинг локальных ML-сущностей в формат KumaFlow Brain.
/// Трек: мобильный Navidrome song id = серверный Track.external_id.
/// Сервер принимает track_id как uuid или external_id, отвечает uuid +
/// title/artist — для игры маппить обратно через external_id.
/// Артист = имя (artist_name), не id.
class KumaFlowBrainMapper {
  /// ratings до 20000 за запрос — слать страницами (чанкование делает bridge).
  static Map<String, dynamic> ratingToJson(TrackRating r) {
    return {
      'external_id': r.songId,
      'like': r.like,
      'playCount': r.playCount,
      'skipCount': r.skipCount,
      'replayCount': r.replayCount,
      'seekBackCount': r.seekBackCount,
      'abandonCount': r.abandonCount,
      'score': r.score,
      'lastPlayed': r.lastPlayed,
    };
  }

  /// MLService.profile (lib/services/ml_service.dart) — у него есть
  /// bannedArtistNames (id -> name). KumaFlow Brain v0.2.9 банит по
  /// Navidrome-ID: шлём объекты {id, name} (см. test_tombstones.py),
  /// плюс legacy-список имён для совместимости.
  static Map<String, dynamic> profileToJson({
    required Map<String, double> preferredGenres,
    required Map<String, double> preferredArtists,
    required List<String> likedSongs,
    required List<String> dislikedSongs,
    required List<String> bannedArtists,
    required Map<String, String> bannedArtistNames,
    required Map<String, int> artistDislikeCounts,
  }) {
    final detailed = <Map<String, String>>[];
    final seenIds = <String>{};
    for (final id in bannedArtists) {
      final t = id.trim();
      if (t.isEmpty || !seenIds.add(t)) continue;
      final name = (bannedArtistNames[t] ?? t).trim();
      detailed.add({'id': t, 'name': name.isNotEmpty ? name : t});
    }
    final names = <String>{
      ...bannedArtistNames.values.where((e) => e.trim().isNotEmpty),
      ...bannedArtists.where((e) => e.trim().isNotEmpty),
    }.toList();
    return {
      'preferredGenres': preferredGenres,
      'preferredArtists': preferredArtists,
      'likedSongs': likedSongs,
      'dislikedSongs': dislikedSongs,
      'bannedArtists': detailed,
      'bannedArtistNames': names,
      'artistDislikeCounts': artistDislikeCounts,
    };
  }

  /// PlayEvent (локальный) -> событие KumaFlow Brain.
  /// Допустимые action KumaFlow Brain: play|complete|skip|replay|seek_back|abandon.
  static Map<String, dynamic>? playEventToJson(PlayEvent e) {
    final action = _normalizeAction(e.action);
    if (action == null) return null;
    return {
      'track_id': e.trackId,
      'action': action,
      'position_sec': e.position,
    };
  }

  static String? _normalizeAction(String raw) {
    final a = raw.toLowerCase().trim();
    switch (a) {
      case 'play':
      case 'complete':
      case 'skip':
      case 'replay':
      case 'seek_back':
      case 'seekback':
        return a == 'seekback' ? 'seek_back' : a;
      case 'abandon':
      case 'abandoned':
        return 'abandon';
      // Локальные внутренние события, которым нет аналога, — дропаем.
      default:
        return null;
    }
  }

  /// Ответ wave/continue: tracks[{track_id,external_id,title,artist(_name),
  /// score,reason,mood,moods[]}]. external_id = Navidrome song id.
  static List<KumaFlowBrainTrack> parseWaveTracks(Map<String, dynamic> res) {
    final raw = res['tracks'];
    if (raw is! List) return const [];
    final out = <KumaFlowBrainTrack>[];
    for (final t in raw) {
      if (t is! Map) continue;
      final m = Map<String, dynamic>.from(t);
      final id = (m['track_id'] ?? m['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final ext = (m['external_id'] ?? '').toString();
      final moods = <String>{};
      final single = (m['mood'] ?? '').toString().trim().toLowerCase();
      if (single.isNotEmpty) moods.add(single);
      final multi = m['moods'];
      if (multi is List) {
        for (final x in multi) {
          final v = x.toString().trim().toLowerCase();
          if (v.isNotEmpty) moods.add(v);
        }
      }
      out.add(KumaFlowBrainTrack(
        trackId: id,
        externalId: ext.isNotEmpty ? ext : null,
        title: (m['title'] ?? '').toString(),
        artist: (m['artist_name'] ?? m['artist'] ?? '').toString(),
        score: (m['score'] is num) ? (m['score'] as num).toDouble() : 0,
        reason: (m['reason'] ?? '').toString(),
        moods: moods.toList(),
      ));
    }
    return out;
  }

  /// Ответ wave/seed v0.3.4+: items[{track_id(uuid),external_id,title,
  /// artist_name,album_name,genre,duration_sec,cover_art_id}] в порядке tracks.
  /// Играть только по items[].external_id — tracks[] (uuid) для плеера бесполезны.
  /// Fallback: если items нет — пусто (вызывающий сам решит legacy через tracks).
  static List<KumaFlowBrainTrack> parseSeedItems(Map<String, dynamic> res) {
    final raw = res['items'];
    if (raw is! List) return const [];
    final out = <KumaFlowBrainTrack>[];
    for (final t in raw) {
      if (t is! Map) continue;
      final m = Map<String, dynamic>.from(t);
      final id = (m['track_id'] ?? m['id'] ?? '').toString();
      final ext = (m['external_id'] ?? '').toString();
      if (id.isEmpty && ext.isEmpty) continue;
      out.add(KumaFlowBrainTrack(
        trackId: id.isNotEmpty ? id : ext,
        externalId: ext.isNotEmpty ? ext : null,
        title: (m['title'] ?? '').toString(),
        artist: (m['artist_name'] ?? m['artist'] ?? '').toString(),
        score: (m['score'] is num) ? (m['score'] as num).toDouble() : 0,
        reason: 'seed-radio',
      ));
    }
    return out;
  }
}

class KumaFlowBrainTrack {
  final String trackId;
  final String? externalId;
  final String title;
  final String artist;
  final double score;
  final String reason;
  /// Метки настроения с сервера (могут быть пустыми).
  final List<String> moods;
  const KumaFlowBrainTrack({
    required this.trackId,
    this.externalId,
    required this.title,
    required this.artist,
    required this.score,
    required this.reason,
    this.moods = const [],
  });

  /// Играбельный id: Navidrome song id если есть, иначе uuid (legacy search).
  String get playableId => (externalId != null && externalId!.isNotEmpty) ? externalId! : trackId;
}
