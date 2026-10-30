import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/ml/ml_types.dart';
import 'behavior_tracker.dart';

class ItemSimilarityService {
  static const _kItemSimKey = 'item_similarity_v1';
  static const _kMaxPerTrack = 50;
  static const _kMaxEventsForBuild = 1500;

  final Map<String, Map<String, double>> _similar = {};
  final Map<String, int> _trackPlayCount = {};
  bool _loaded = false;

  bool get isReady => _loaded && _similar.isNotEmpty;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kItemSimKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in decoded.entries) {
          final inner = (e.value as Map<String, dynamic>).map(
            (k, v) => MapEntry(k, (v as num).toDouble()),
          );
          _similar[e.key] = inner;
          _trackPlayCount[e.key] = inner.length;
        }
      } catch (_) {
        // ignore corrupt cache
      }
    }
    _loaded = true;
  }

  Future<void> rebuildFromEvents(List<PlayEvent> events) async {
    if (events.length < 5) return;
    final take = events.length > _kMaxEventsForBuild
        ? events.sublist(events.length - _kMaxEventsForBuild)
        : events;

    final played = take.where((e) =>
        e.action == 'play' || e.action == 'complete' ||
        e.action == 'like' || e.action == 'replay').toList();

    final bySession = <String, List<String>>{};
    for (final e in played) {
      final sid = e.sessionId.isEmpty ? 'no_session' : e.sessionId;
      bySession.putIfAbsent(sid, () => <String>[]).add(e.trackId);
    }

    final co = <String, Map<String, int>>{};
    for (final sessionPlays in bySession.values) {
      if (sessionPlays.length < 2) continue;
      final unique = <String>{};
      for (final t in sessionPlays) {
        unique.add(t);
      }
      final list = unique.toList();
      for (int i = 0; i < list.length; i++) {
        co.putIfAbsent(list[i], () => <String, int>{});
        for (int j = 0; j < list.length; j++) {
          if (i == j) continue;
          final other = list[j];
          if (i + 1 == j || j + 1 == i) {
            co[list[i]]![other] = (co[list[i]]![other] ?? 0) + 3;
          } else {
            co[list[i]]![other] = (co[list[i]]![other] ?? 0) + 1;
          }
        }
      }
    }

    final playCount = <String, int>{};
    for (final list in bySession.values) {
      for (final t in list) {
        playCount[t] = (playCount[t] ?? 0) + 1;
      }
    }

    final newSim = <String, Map<String, double>>{};
    for (final entry in co.entries) {
      final a = entry.key;
      final playsA = (playCount[a] ?? 1).toDouble();
      final others = entry.value;
      if (others.isEmpty) continue;
      final sorted = others.entries.toList()
        ..sort((x, y) => y.value.compareTo(x.value));
      final top = sorted.take(_kMaxPerTrack).toList();
      final norm = <String, double>{};
      double maxSim = 0;
      for (final t in top) {
        final playsB = (playCount[t.key] ?? 1).toDouble();
        final cosine = t.value / (playsA * playsB);
        norm[t.key] = cosine;
        if (cosine > maxSim) maxSim = cosine;
      }
      if (maxSim > 0) {
        for (final t in norm.entries.toList()) {
          norm[t.key] = t.value / maxSim;
        }
      }
      newSim[a] = norm;
    }

    _similar
      ..clear()
      ..addAll(newSim);
    _trackPlayCount
      ..clear()
      ..addAll(playCount);

    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_similar);
    await prefs.setString(_kItemSimKey, encoded);
  }

  /// Returns item-to-item similarity scores for [targetTrackId].
  /// Items never co-played with [targetTrackId] are absent.
  Map<String, double> scoresFor(String targetTrackId) {
    return _similar[targetTrackId] ?? const {};
  }

  /// Returns aggregated scores across multiple seed tracks (e.g. last 20 plays).
  /// Each candidate gets the MAX similarity across all seeds.
  Map<String, double> aggregateForSeeds(Iterable<String> seedTrackIds) {
    final result = <String, double>{};
    for (final seed in seedTrackIds) {
      final s = _similar[seed];
      if (s == null) continue;
      for (final entry in s.entries) {
        final cur = result[entry.key];
        if (cur == null || entry.value > cur) {
          result[entry.key] = entry.value;
        }
      }
    }
    result.removeWhere((k, _) => seedTrackIds.contains(k));
    return result;
  }

  void clear() {
    _similar.clear();
    _trackPlayCount.clear();
    _loaded = false;
  }
}