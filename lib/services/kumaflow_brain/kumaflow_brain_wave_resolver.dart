import '../../models/song.dart';
import '../subsonic_service.dart';
import 'kumaflow_brain_mapper.dart';

/// Резолвер треков KumaFlow Brain -> играбельные Song.
/// Сервер теперь отдаёт external_id (Navidrome song id) — играем напрямую.
/// Legacy (без external_id): getSong(track_id) -> search("title artist").
/// Ненайденное НЕ рвёт очередь — возвращается в missing.
class KumaFlowBrainResolved {
  final Song song;
  final KumaFlowBrainTrack brain;
  const KumaFlowBrainResolved(this.song, this.brain);
}

class KumaFlowBrainWaveResolved {
  final List<KumaFlowBrainResolved> found;
  final List<KumaFlowBrainTrack> missing;
  const KumaFlowBrainWaveResolved({required this.found, required this.missing});
}

class KumaFlowBrainWaveResolver {
  final SubsonicService subsonic;
  KumaFlowBrainWaveResolver(this.subsonic);

  String _norm(String s) => s.trim().toLowerCase();

  bool _titleMatch(String songTitle, String brainTitle) {
    final a = _norm(songTitle);
    final b = _norm(brainTitle);
    if (a.isEmpty || b.isEmpty) return false;
    return a == b || a.contains(b) || b.contains(a);
  }

  Future<KumaFlowBrainWaveResolved> resolve(
    List<KumaFlowBrainTrack> tracks, {
    int maxTracks = 30,
    Future<void> Function(int done, int total)? onProgress,
  }) async {
    final found = <KumaFlowBrainResolved>[];
    final missing = <KumaFlowBrainTrack>[];
    final list = tracks.take(maxTracks).toList();
    var done = 0;
    for (final t in list) {
      Song? song;
      // 0) external_id есть — прямой getSong, без поиска. Точный путь.
      final ext = t.externalId;
      if (ext != null && ext.isNotEmpty) {
        try {
          song = await subsonic.getSong(ext).timeout(const Duration(seconds: 6));
        } catch (_) {
          song = null;
        }
        // external_id не найден на сервере (трек удалён?) — сразу в missing,
        // search не делаем чтобы не подменить трек похожим.
        if (song == null) {
          missing.add(t);
          done++;
          try {
            await onProgress?.call(done, list.length);
          } catch (_) {}
          continue;
        }
      } else {
        // 1) legacy: прямой getSong — дёшево, вдруг id совпал.
        try {
          song = await subsonic
              .getSong(t.trackId)
              .timeout(const Duration(seconds: 6));
        } catch (_) {
          song = null;
        }
      }
      // 2) поиск по title + artist.
      if (song == null && (t.title.isNotEmpty || t.artist.isNotEmpty)) {
        try {
          final q = '${t.title} ${t.artist}'.trim();
          final res = await subsonic
              .search(q, songCount: 5, artistCount: 0, albumCount: 0)
              .timeout(const Duration(seconds: 8));
          if (res.songs.isNotEmpty) {
            Song? best;
            for (final s in res.songs) {
              if (_titleMatch(s.title, t.title)) {
                final sa = _norm(s.artist ?? '');
                final ba = _norm(t.artist);
                if (ba.isEmpty || sa.contains(ba) || ba.contains(sa)) {
                  best = s;
                  break;
                }
                best ??= s;
              }
            }
            song = best ?? res.songs.first;
          }
        } catch (_) {
          song = null;
        }
      }
      if (song != null) {
        found.add(KumaFlowBrainResolved(song, t));
      } else {
        missing.add(t);
      }
      done++;
      try {
        await onProgress?.call(done, list.length);
      } catch (_) {}
    }
    return KumaFlowBrainWaveResolved(found: found, missing: missing);
  }
}
