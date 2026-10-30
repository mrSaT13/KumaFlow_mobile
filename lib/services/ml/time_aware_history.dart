import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class TimeAwareHistory {
  static const String _kDataKey = 'kumaflow:time-aware-hourly-data';
  static const int _maxEntries = 5000;
  static const int _maxAgeDays = 30;

  final Map<int, Map<String, Map<String, dynamic>>> _hourlyData = {};
  bool _loaded = false;
  int _lastSaveMs = 0;

  void logPlay(String trackId, int hour, {bool liked = false, bool skipped = false}) {
    _hourlyData.putIfAbsent(hour, () => {});
    _hourlyData[hour]!.putIfAbsent(trackId, () => {
      'playCount': 0, 'lastPlayed': 0, 'likeCount': 0, 'skipCount': 0,
    });

    final entry = _hourlyData[hour]![trackId]!;
    entry['playCount'] = (entry['playCount'] as int) + 1;
    entry['lastPlayed'] = DateTime.now().millisecondsSinceEpoch;
    if (liked) entry['likeCount'] = (entry['likeCount'] as int) + 1;
    if (skipped) entry['skipCount'] = (entry['skipCount'] as int) + 1;
    _maybeSave();
  }

  /// Persist at most once a minute (plays are frequent).
  void _maybeSave() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSaveMs < 60000) return;
    _lastSaveMs = now;
    save();
  }

  double getTimeBonus(String trackId, int currentHour) {
    double bonus = 0;
    for (final hourOffset in [-1, 0, 1]) {
      final hour = (currentHour + hourOffset) % 24;
      final data = _hourlyData[hour]?[trackId];
      if (data == null) continue;

      final playCount = data['playCount'] as int;
      final lastPlayed = data['lastPlayed'] as int;
      final now = DateTime.now().millisecondsSinceEpoch;
      final daysSince = (now - lastPlayed) / (1000 * 60 * 60 * 24);

      double recencyWeight;
      if (daysSince < 1) recencyWeight = 1.0;
      else if (daysSince < 2) recencyWeight = 0.8;
      else if (daysSince < 4) recencyWeight = 0.6;
      else if (daysSince < 8) recencyWeight = 0.3;
      else if (daysSince < 31) recencyWeight = 0.1;
      else recencyWeight = 0.05;

      bonus += 10 * (1 + playCount / 5) * recencyWeight;
    }
    return bonus.clamp(0.0, 50.0);
  }

  List<String> getPreferredHours(String trackId) {
    final hours = <String>[];
    for (int hour = 0; hour < 24; hour++) {
      if (_hourlyData[hour]?.containsKey(trackId) == true) {
        final data = _hourlyData[hour]![trackId]!;
        if ((data['playCount'] as int) >= 2) {
          hours.add(_hourToContext(hour));
        }
      }
    }
    return hours.toSet().toList();
  }

  /// Preferred listening hours for a track (alias for UI layers).
  List<int> getTrackPreferredHours(String trackId) {
    final hours = <int>[];
    for (int hour = 0; hour < 24; hour++) {
      final data = _hourlyData[hour]?[trackId];
      if (data != null && (data['playCount'] as int) >= 2) {
        hours.add(hour);
      }
    }
    return hours;
  }

  /// Top tracks for the current hour by time bonus (for "often at this time").
  List<String> getTopTracksForCurrentTime(int limit, {int? hour}) {
    final currentHour = hour ?? DateTime.now().hour;
    final scored = <String, double>{};
    for (final hourOffset in [-1, 0, 1]) {
      final h = (currentHour + hourOffset) % 24;
      final tracks = _hourlyData[h];
      if (tracks == null) continue;
      for (final trackId in tracks.keys) {
        scored[trackId] = getTimeBonus(trackId, currentHour);
      }
    }
    final sorted = scored.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted
        .where((e) => e.value >= 5)
        .take(limit)
        .map((e) => e.key)
        .toList();
  }

  /// Play counts per time-of-day slot (for stats UI).
  Map<String, int> getHourlyStats() {
    final stats = {'morning': 0, 'day': 0, 'evening': 0, 'night': 0};
    _hourlyData.forEach((hour, tracks) {
      final slot = _hourToContext(hour);
      var total = 0;
      for (final data in tracks.values) {
        total += (data['playCount'] as int? ?? 0);
      }
      stats[slot] = (stats[slot] ?? 0) + total;
    });
    return stats;
  }

  String _hourToContext(int hour) {
    if (hour >= 6 && hour < 12) return 'morning';
    if (hour >= 12 && hour < 17) return 'day';
    if (hour >= 17 && hour < 22) return 'evening';
    return 'night';
  }

  void cleanup({int maxEntries = _maxEntries}) {
    int totalEntries = 0;
    for (final hourData in _hourlyData.values) {
      totalEntries += hourData.length;
    }
    if (totalEntries <= maxEntries) return;

    final allEntries = <Map<String, dynamic>>[];
    for (final hour in _hourlyData.keys) {
      for (final trackId in _hourlyData[hour]!.keys) {
        allEntries.add({
          'hour': hour,
          'trackId': trackId,
          'lastPlayed': _hourlyData[hour]![trackId]!['lastPlayed'],
        });
      }
    }
    allEntries.sort((a, b) => (a['lastPlayed'] as int).compareTo(b['lastPlayed'] as int));

    int toRemove = totalEntries - maxEntries;
    for (int i = 0; i < toRemove && i < allEntries.length; i++) {
      final entry = allEntries[i];
      _hourlyData[entry['hour'] as int]?.remove(entry['trackId'] as String);
    }
  }

  // ─── Persistence (SharedPreferences) ───────────────────────────────

  /// Load persisted data (drops entries older than 30 days).
  /// Safe to call fire-and-forget at startup.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kDataKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final cutoff = DateTime.now()
          .subtract(const Duration(days: _maxAgeDays))
          .millisecondsSinceEpoch;
      decoded.forEach((hourStr, tracks) {
        final hour = int.tryParse(hourStr);
        if (hour == null || hour < 0 || hour > 23) return;
        final map = (tracks as Map).map(
          (k, v) => MapEntry(k as String, Map<String, dynamic>.from(v as Map)),
        );
        // Drop stale tracks right away.
        map.removeWhere((_, data) {
          final last = data['lastPlayed'] as int? ?? 0;
          return last < cutoff;
        });
        if (map.isNotEmpty) _hourlyData[hour] = map;
      });
      cleanup();
    } catch (_) {}
  }

  /// Persist data (capped at 5000 entries).
  Future<void> save() async {
    try {
      cleanup();
      final prefs = await SharedPreferences.getInstance();
      final encoded = _hourlyData.map(
        (hour, tracks) => MapEntry(hour.toString(), tracks),
      );
      await prefs.setString(_kDataKey, jsonEncode(encoded));
    } catch (_) {}
  }
}
