import 'dart:math';
import '../../models/song.dart';

class CollabMixSettings {
  final double selfWeight;
  final int limit;

  const CollabMixSettings({this.selfWeight = 0.5, this.limit = 30});

  CollabMixSettings copyWith({double? selfWeight, int? limit}) =>
      CollabMixSettings(
        selfWeight: selfWeight ?? this.selfWeight,
        limit: limit ?? this.limit,
      );
}

class MergedTrack {
  final Song song;
  final double score;
  final String contributorId;
  final String contributorLabel;
  final bool shared;
  final Set<String> sources;

  const MergedTrack({
    required this.song,
    required this.score,
    required this.contributorId,
    required this.contributorLabel,
    this.shared = false,
    this.sources = const {},
  });
}

class CollabMergeService {
  static const String selfId = 'self';

  static List<MergedTrack> merge({
    required List<Song> ownPool,
    required Map<String, List<Song>> friendTracks,
    required Map<String, String> contributorLabels,
    required Set<String> dislikedIds,
    required Set<String> bannedArtistIds,
    required Set<String> bannedArtistNamesLower,
    required Set<String> ownTopArtistsLower,
    required double Function(Song) ownScore,
    required CollabMixSettings settings,
  }) {
    final random = Random();
    final selfW = settings.selfWeight.clamp(0.0, 1.0);

    final scoredOwn = ownPool.map((s) => MapEntry(s, ownScore(s))).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final ownTop = scoredOwn.take(min(150, scoredOwn.length)).toList();

    final topAvg = ownTop.isEmpty
        ? 1.0
        : ownTop
                .take(min(20, ownTop.length))
                .map((e) => e.value)
                .reduce((a, b) => a + b) /
            min(20, ownTop.length);
    final normBase = (topAvg <= 0 ? 50.0 : topAvg).clamp(10.0, 500.0);

    final lanes = <String, List<MergedTrack>>{};
    void addLane(String id, MergedTrack t) =>
        lanes.putIfAbsent(id, () => []).add(t);

    for (final e in ownTop) {
      if (_vetoed(e.key, dislikedIds, bannedArtistIds, bannedArtistNamesLower)) {
        continue;
      }
      final norm = (e.value / normBase).clamp(0.0, 3.0);
      final score = (0.35 + 0.65 * (norm / (1 + norm))) * (0.4 + selfW);
      addLane(
        selfId,
        MergedTrack(
          song: e.key,
          score: score + random.nextDouble() * 0.02,
          contributorId: selfId,
          contributorLabel: contributorLabels[selfId] ?? 'You',
          sources: const {selfId},
        ),
      );
    }

    friendTracks.forEach((accountId, songs) {
      final label = contributorLabels[accountId] ?? 'Friend';
      for (final s in songs) {
        if (_vetoed(s, dislikedIds, bannedArtistIds, bannedArtistNamesLower)) {
          continue;
        }
        double score = 0.65 * (1.6 - selfW);
        final artistLower = (s.artist ?? '').toLowerCase();
        if (artistLower.isNotEmpty && ownTopArtistsLower.contains(artistLower)) {
          score += 0.2;
        }
        addLane(
          accountId,
          MergedTrack(
            song: s,
            score: score + random.nextDouble() * 0.02,
            contributorId: accountId,
            contributorLabel: label,
            sources: {accountId},
          ),
        );
      }
    });

    if (lanes.isEmpty) return [];

    final byKey = <String, List<MergedTrack>>{};
    for (final lane in lanes.values) {
      for (final t in lane) {
        byKey.putIfAbsent(_trackKey(t.song), () => []).add(t);
      }
    }
    final keys = byKey.keys.toList();
    for (var i = 0; i < keys.length; i++) {
      for (var j = i + 1; j < keys.length; j++) {
        final a = keys[i];
        final b = keys[j];
        if (!byKey.containsKey(a) || !byKey.containsKey(b)) continue;
        if (_fuzzySameKey(a, b, byKey[a]!.first.song, byKey[b]!.first.song)) {
          byKey[a]!.addAll(byKey[b]!);
          byKey.remove(b);
        }
      }
    }
    final deduped = <String, List<MergedTrack>>{};
    byKey.forEach((key, tracks) {
      tracks.sort((a, b) => b.score.compareTo(a.score));
      final best = tracks.first;
      final sources = tracks.map((t) => t.contributorId).toSet();
      final bonus = 1.0 + 0.5 * (sources.length - 1);
      deduped[key] = [
        MergedTrack(
          song: best.song,
          score: best.score * bonus,
          contributorId: best.contributorId,
          contributorLabel: best.contributorLabel,
          shared: sources.length > 1,
          sources: sources,
        ),
      ];
    });

    final fairLanes = <String, List<MergedTrack>>{};
    final sharedFirst = <MergedTrack>[];
    final rest = <MergedTrack>[];
    for (final list in deduped.values) {
      final t = list.first;
      if (t.shared) {
        sharedFirst.add(t);
      } else {
        rest.add(t);
      }
    }
    sharedFirst.sort((a, b) => b.score.compareTo(a.score));
    for (final t in rest) {
      fairLanes.putIfAbsent(t.contributorId, () => []).add(t);
    }
    for (final lane in fairLanes.values) {
      lane.sort((a, b) => b.score.compareTo(a.score));
    }

    final laneIds = fairLanes.keys.toList()..shuffle(random);
    final result = <MergedTrack>[...sharedFirst];
    final usedKeys = result.map((t) => _trackKey(t.song)).toSet();
    final recentArtists = <String>[];
    final limit = settings.limit.clamp(5, 100);

    bool progress = true;
    while (result.length < limit && progress) {
      progress = false;
      for (final laneId in laneIds) {
        if (result.length >= limit) break;
        final lane = fairLanes[laneId]!;
        final idx = lane.indexWhere((t) {
          if (usedKeys.contains(_trackKey(t.song))) return false;
          final a = (t.song.artist ?? '').toLowerCase();
          if (a.isNotEmpty &&
              recentArtists.length >= 2 &&
              recentArtists[recentArtists.length - 1] == a &&
              recentArtists[recentArtists.length - 2] == a) {
            return false;
          }
          return true;
        });
        if (idx != -1) {
          final t = lane.removeAt(idx);
          result.add(t);
          usedKeys.add(_trackKey(t.song));
          recentArtists.add((t.song.artist ?? '').toLowerCase());
          if (recentArtists.length > 4) recentArtists.removeAt(0);
          progress = true;
        }
      }
    }
    return result.take(limit).toList();
  }

  static bool _vetoed(
    Song s,
    Set<String> dislikedIds,
    Set<String> bannedArtistIds,
    Set<String> bannedNamesLower,
  ) {
    if (dislikedIds.contains(s.id) || dislikedIds.contains(s.queueKey)) {
      return true;
    }
    if (s.artistId != null && bannedArtistIds.contains(s.artistId)) {
      return true;
    }
    final name = (s.artist ?? '').toLowerCase();
    if (name.isNotEmpty && bannedNamesLower.contains(name)) return true;
    return false;
  }

  static String _normText(String s) {
    var t = s.toLowerCase().trim();
    t = t.replaceAll(RegExp(r'\s*\(\s*(feat\.?|ft\.?|with)\s+[^)]*\)\s*$'), '').trim();
    t = t.replaceAll(RegExp(r'[\s_]+'), ' ');
    t = t.replaceAll(RegExp(r'[^a-z0-9\u00e0-\u00ff\u0400-\u04ff ]'), '');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  static String _trackKey(Song s) {
    final title = _normText(s.title);
    final artist = _normText(s.artist ?? '');
    final ids = (s.artistId != null && s.albumId != null)
        ? '|${s.artistId}|${s.albumId}'
        : '';
    return '$title - $artist$ids';
  }

  static bool _fuzzySameKey(String a, String b, Song sa, Song sb) {
    if (a == b) return true;
    final sim = _stringSimilarity(a, b);
    if (sim < 0.85) return false;
    final da = sa.duration;
    final db = sb.duration;
    if (da != null && db != null && (da - db).abs() > 10) return false;
    return true;
  }

  static double _stringSimilarity(String a, String b) {
    if (a == b) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;
    final n = a.length;
    final m = b.length;
    if ((n - m).abs() > (n * 0.3).ceil() + 3) return 0.0;
    var prev = List<int>.generate(m + 1, (j) => j);
    var curr = List<int>.filled(m + 1, 0);
    for (var i = 1; i <= n; i++) {
      curr[0] = i;
      for (var j = 1; j <= m; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        curr[j] = min(
          min(prev[j] + 1, curr[j - 1] + 1),
          prev[j - 1] + cost,
        );
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    final dist = prev[m];
    final maxLen = max(n, m);
    return (1.0 - dist / maxLen).clamp(0.0, 1.0);
  }
}
