import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/ml/ml_types.dart';

class MoodDriftDetector {
  static const String _kSkipsKey = 'kumaflow:consecutive-skips';
  static const String _kHistoryKey = 'kumaflow:mood-history';
  static const String _kProfileKey = 'kumaflow:current-mood-profile';
  static const int _maxHistory = 100;
  static const int _maxRecentSkips = 50;

  int _consecutiveSkips = 0;
  int? _lastSkipTime;
  MoodProfile? _currentProfile;
  final List<Map<String, dynamic>> _moodHistory = [];
  final List<TempBan> _tempBans = [];
  final Map<String, Map<String, dynamic>> _skipPatterns = {};
  // Recently skipped tracks (trackId + timestamp) for playlist exclusion.
  final List<Map<String, dynamic>> _recentSkips = [];
  Timer? _persistTimer;

  Future<void> logSkip(String trackId, dynamic song) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastSkipTime != null && now - _lastSkipTime! < 600000) {
      _consecutiveSkips++;
    } else {
      _consecutiveSkips = 1;
    }
    _lastSkipTime = now;

    // Track recent skips so wave generation can exclude them (1h window).
    _recentSkips.add({'trackId': trackId, 'timestamp': now});
    if (_recentSkips.length > _maxRecentSkips) {
      _recentSkips.removeAt(0);
    }

    if (song?.genre != null) {
      final genre = song.genre as String;
      _skipPatterns.putIfAbsent(genre, () => {'skipCount': 0, 'lastSkipTime': 0});
      _skipPatterns[genre]!['skipCount'] = (_skipPatterns[genre]!['skipCount'] as int) + 1;
      _skipPatterns[genre]!['lastSkipTime'] = now;

      if ((_skipPatterns[genre]!['skipCount'] as int) >= 3) {
        addTempBan(genre, 'genre', 30 * 60 * 1000, 'Too many skips in short time');
        _skipPatterns[genre]!['skipCount'] = 0;
      }
    }

    if (_consecutiveSkips >= 2) {
      _applyMoodDrift();
    }
    _schedulePersist();
  }

  void logPositiveInteraction(String trackId) {
    _consecutiveSkips = 0;
    _schedulePersist();
  }

  void _applyMoodDrift() {
    final now = DateTime.now();
    final hour = now.hour;

    double energyShift = 0;
    double valenceShift = 0;
    double tempoShift = 0;
    String severity;

    if (_consecutiveSkips >= 7) {
      severity = 'strong';
      energyShift = -0.3;
      valenceShift = -0.15;
      tempoShift = -30;
    } else if (_consecutiveSkips >= 5) {
      severity = 'moderate';
      energyShift = -0.2;
      valenceShift = -0.1;
      tempoShift = -20;
    } else if (_consecutiveSkips >= 3) {
      severity = 'mild';
      energyShift = -0.1;
      valenceShift = -0.05;
      tempoShift = -10;
    } else {
      return;
    }

    double timeEnergyAdj = 0;
    double timeTempoAdj = 0;
    if (hour >= 6 && hour < 9) {
      timeEnergyAdj = 0.1;
      timeTempoAdj = 5;
    } else if (hour >= 12 && hour < 14) {
      timeEnergyAdj = 0.05;
    } else if (hour >= 14 && hour < 17) {
      timeEnergyAdj = -0.05;
    } else if (hour >= 18 && hour < 22) {
      timeEnergyAdj = -0.1;
      valenceShift -= 0.05;
    } else {
      timeEnergyAdj = -0.2;
      timeTempoAdj = -15;
    }

    final currentEnergy = _currentProfile?.energy ?? 0.5;
    final currentValence = _currentProfile?.valence ?? 0.5;
    final currentTempo = _currentProfile?.tempo ?? 120;

    if (_consecutiveSkips >= 7) {
      // Strong drift: full reset to the time-of-day baseline profile
      // instead of shifting the current one.
      final baseEnergy = (0.5 + timeEnergyAdj).clamp(0.0, 1.0).toDouble();
      final baseValence =
          (0.5 + (hour >= 18 && hour < 22 ? -0.05 : 0)).clamp(0.0, 1.0).toDouble();
      final baseTempo = (120.0 + timeTempoAdj).clamp(60.0, 200.0).toDouble();
      _currentProfile = MoodProfile(
        energy: baseEnergy,
        valence: baseValence,
        tempo: baseTempo,
        mood: _determineMood(baseEnergy, baseValence),
        activity: _getActivityFromTime(hour),
      );
    } else {
      _currentProfile = MoodProfile(
        energy: (currentEnergy + energyShift + timeEnergyAdj).clamp(0.0, 1.0),
        valence: (currentValence + valenceShift).clamp(0.0, 1.0),
        tempo: (currentTempo + tempoShift + timeTempoAdj).clamp(60, 200),
        mood: _determineMood(currentEnergy + energyShift, currentValence + valenceShift),
        activity: _getActivityFromTime(hour),
      );
    }

    _moodHistory.add({
      'timestamp': now.millisecondsSinceEpoch,
      'severity': severity,
      'consecutiveSkips': _consecutiveSkips,
      'newMood': _currentProfile!.toJson(),
    });
    if (_moodHistory.length > _maxHistory) {
      _moodHistory.removeAt(0);
    }
  }

  String _determineMood(double energy, double valence) {
    if (energy > 0.7 && valence > 0.6) return 'energetic';
    if (energy > 0.5 && valence > 0.7) return 'happy';
    if (energy < 0.4 && valence < 0.4) return 'sad';
    if (energy < 0.5) return 'calm';
    if (energy < 0.6 && valence > 0.5) return 'relaxed';
    if (energy > 0.6 && valence < 0.5) return 'focused';
    return 'calm';
  }

  String _getActivityFromTime(int hour) {
    if (hour >= 6 && hour < 9) return 'wakeup';
    if (hour >= 9 && hour < 12) return 'work';
    if (hour >= 12 && hour < 14) return 'break';
    if (hour >= 14 && hour < 18) return 'work';
    if (hour >= 18 && hour < 22) return 'evening';
    return 'sleep';
  }

  MoodProfile? getCurrentProfile() => _currentProfile;

  List<Map<String, dynamic>> getMoodHistory() => List.unmodifiable(_moodHistory);

  int getConsecutiveSkipCount() => _consecutiveSkips;

  bool needsPlaylistReset() => _consecutiveSkips >= 7;

  Map<String, dynamic> getPlaylistAdjustments() {
    final adjustments = <String, dynamic>{};
    if (_currentProfile != null) {
      adjustments['energyMax'] = _currentProfile!.energy + 0.2;
      adjustments['tempoMax'] = _currentProfile!.tempo + 30;
      adjustments['moodFilter'] = _currentProfile!.mood;
    }
    adjustments['skipRecentTrackIds'] = _getRecentlySkippedTrackIds();
    return adjustments;
  }

  List<String> _getRecentlySkippedTrackIds() {
    final cutoff =
        DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch;
    _recentSkips.removeWhere((e) => (e['timestamp'] as int) <= cutoff);
    return _recentSkips
        .map((e) => e['trackId'] as String? ?? '')
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
  }

  void addTempBan(String targetId, String type, int durationMs, String reason) {
    _tempBans.removeWhere((b) => b.targetId == targetId && b.type == type);
    _tempBans.add(TempBan(
      targetId: targetId,
      type: type,
      expiresAt: DateTime.now().millisecondsSinceEpoch + durationMs,
      reason: reason,
    ));
  }

  bool isTempBanned(String targetId, String type) {
    _tempBans.removeWhere((b) => b.isExpired);
    return _tempBans.any((b) => b.targetId == targetId && b.type == type && !b.isExpired);
  }

  List<TempBan> getActiveTempBans() {
    _tempBans.removeWhere((b) => b.isExpired);
    return List.unmodifiable(_tempBans);
  }

  void resetProfile() {
    _persistTimer?.cancel();
    _persistTimer = null;
    _currentProfile = null;
    _consecutiveSkips = 0;
    _lastSkipTime = null;
    _recentSkips.clear();
    save();
  }

  // ─── Persistence (SharedPreferences) ───────────────────────────────

  /// Load persisted state. Safe to call fire-and-forget at startup.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _consecutiveSkips = prefs.getInt(_kSkipsKey) ?? 0;
      _lastSkipTime = null; // stale skip windows must not survive restart
      if (_consecutiveSkips < 0) _consecutiveSkips = 0;
      final profileJson = prefs.getString(_kProfileKey);
      if (profileJson != null && profileJson.isNotEmpty) {
        try {
          _currentProfile = MoodProfile.fromJson(
            jsonDecode(profileJson) as Map<String, dynamic>,
          );
        } catch (_) {
          _currentProfile = null;
        }
      }
      final historyJson = prefs.getString(_kHistoryKey);
      if (historyJson != null && historyJson.isNotEmpty) {
        try {
          final list = jsonDecode(historyJson) as List;
          _moodHistory.clear();
          _moodHistory.addAll(
            list
                .take(_maxHistory)
                .map((e) => Map<String, dynamic>.from(e as Map)),
          );
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Persist state immediately.
  Future<void> save() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSkipsKey, _consecutiveSkips);
      if (_currentProfile != null) {
        await prefs.setString(
          _kProfileKey,
          jsonEncode(_currentProfile!.toJson()),
        );
      } else {
        await prefs.remove(_kProfileKey);
      }
      await prefs.setString(_kHistoryKey, jsonEncode(_moodHistory));
    } catch (_) {}
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(seconds: 2), () {
      _persistTimer = null;
      save();
    });
  }
}
