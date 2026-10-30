import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AchievementCategory {
  listening,
  likes,
  playlists,
  discovery,
  streak,
}

class Achievement {
  final String id;
  final String title;
  final String description;
  final AchievementCategory category;
  final int threshold;
  final String icon;
  final bool unlocked;
  final DateTime? unlockedAt;
  final int currentProgress;

  const Achievement({
    required this.id,
    required this.title,
    required this.description,
    required this.category,
    required this.threshold,
    required this.icon,
    this.unlocked = false,
    this.unlockedAt,
    this.currentProgress = 0,
  });

  double get progress =>
      threshold > 0 ? (currentProgress / threshold).clamp(0.0, 1.0) : 0.0;

  bool get isJustUnlocked =>
      unlocked && unlockedAt != null &&
      DateTime.now().difference(unlockedAt!).inHours < 24;

  Achievement copyWith({
    String? id,
    String? title,
    String? description,
    AchievementCategory? category,
    int? threshold,
    String? icon,
    bool? unlocked,
    DateTime? unlockedAt,
    int? currentProgress,
  }) {
    return Achievement(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      category: category ?? this.category,
      threshold: threshold ?? this.threshold,
      icon: icon ?? this.icon,
      unlocked: unlocked ?? this.unlocked,
      unlockedAt: unlockedAt ?? this.unlockedAt,
      currentProgress: currentProgress ?? this.currentProgress,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'unlocked': unlocked,
        'unlockedAt': unlockedAt?.toIso8601String(),
        'currentProgress': currentProgress,
      };

  factory Achievement.fromJson(Map<String, dynamic> json) => Achievement(
        id: json['id'] ?? '',
        title: json['title'] ?? '',
        description: json['description'] ?? '',
        category: AchievementCategory.values.firstWhere(
          (e) => e.name == json['category'],
          orElse: () => AchievementCategory.listening,
        ),
        threshold: json['threshold'] ?? 0,
        icon: json['icon'] ?? 'emoji_events',
        unlocked: json['unlocked'] ?? false,
        unlockedAt: json['unlockedAt'] != null
            ? DateTime.tryParse(json['unlockedAt'])
            : null,
        currentProgress: json['currentProgress'] ?? 0,
      );
}

class AchievementsService extends ChangeNotifier {
  static const String _prefsKey = 'kumaflow_achievements_v1';
  static const String _statsKey = 'kumaflow_achievement_stats_v1';

  List<Achievement> _achievements = [];
  Map<String, dynamic> _stats = {};

  List<Achievement> get achievements => List.unmodifiable(_achievements);
  int get unlockedCount => _achievements.where((a) => a.unlocked).length;
  int get totalCount => _achievements.length;

  List<Achievement> get recentlyUnlocked =>
      _achievements.where((a) => a.isJustUnlocked).toList();

  List<Achievement> get achievementsByCategory {
    final sorted = List<Achievement>.from(_achievements);
    sorted.sort((a, b) {
      if (a.unlocked != b.unlocked) return a.unlocked ? -1 : 1;
      return b.currentProgress.compareTo(a.currentProgress);
    });
    return sorted;
  }

  static final List<Achievement> _defaultAchievements = [
    // Listening
    Achievement(
      id: 'listen_100',
      title: 'Getting Started',
      description: 'Listen to 100 tracks',
      category: AchievementCategory.listening,
      threshold: 100,
      icon: 'headphones',
    ),
    Achievement(
      id: 'listen_500',
      title: 'Avid Listener',
      description: 'Listen to 500 tracks',
      category: AchievementCategory.listening,
      threshold: 500,
      icon: 'music_note',
    ),
    Achievement(
      id: 'listen_1000',
      title: 'Music Devotee',
      description: 'Listen to 1,000 tracks',
      category: AchievementCategory.listening,
      threshold: 1000,
      icon: 'library_music',
    ),
    Achievement(
      id: 'listen_5000',
      title: 'Audio Legend',
      description: 'Listen to 5,000 tracks',
      category: AchievementCategory.listening,
      threshold: 5000,
      icon: 'equalizer',
    ),
    // Likes
    Achievement(
      id: 'likes_10',
      title: 'Taste Maker',
      description: 'Like 10 tracks',
      category: AchievementCategory.likes,
      threshold: 10,
      icon: 'favorite',
    ),
    Achievement(
      id: 'likes_50',
      title: 'Collector',
      description: 'Like 50 tracks',
      category: AchievementCategory.likes,
      threshold: 50,
      icon: 'favorite_border',
    ),
    Achievement(
      id: 'likes_100',
      title: 'Heart of Gold',
      description: 'Like 100 tracks',
      category: AchievementCategory.likes,
      threshold: 100,
      icon: 'favorite_rounded',
    ),
    // Playlists
    Achievement(
      id: 'playlists_5',
      title: 'Curator',
      description: 'Create 5 playlists',
      category: AchievementCategory.playlists,
      threshold: 5,
      icon: 'playlist_add',
    ),
    Achievement(
      id: 'playlists_10',
      title: 'Playlist Master',
      description: 'Create 10 playlists',
      category: AchievementCategory.playlists,
      threshold: 10,
      icon: 'queue_music',
    ),
    Achievement(
      id: 'playlists_25',
      title: 'DJ Supreme',
      description: 'Create 25 playlists',
      category: AchievementCategory.playlists,
      threshold: 25,
      icon: 'album',
    ),
    // Discovery
    Achievement(
      id: 'discovery_50',
      title: 'Explorer',
      description: 'Discover 50 unique tracks',
      category: AchievementCategory.discovery,
      threshold: 50,
      icon: 'explore',
    ),
    Achievement(
      id: 'discovery_100',
      title: 'Adventurer',
      description: 'Discover 100 unique tracks',
      category: AchievementCategory.discovery,
      threshold: 100,
      icon: 'explore_off',
    ),
    Achievement(
      id: 'discovery_500',
      title: 'Musical Voyager',
      description: 'Discover 500 unique tracks',
      category: AchievementCategory.discovery,
      threshold: 500,
      icon: 'flight_takeoff',
    ),
    // Streak
    Achievement(
      id: 'streak_7',
      title: 'On Fire',
      description: 'Listen 7 days in a row',
      category: AchievementCategory.streak,
      threshold: 7,
      icon: 'local_fire_department',
    ),
    Achievement(
      id: 'streak_30',
      title: 'Dedicated',
      description: 'Listen 30 days in a row',
      category: AchievementCategory.streak,
      threshold: 30,
      icon: 'whatshot',
    ),
    Achievement(
      id: 'streak_100',
      title: 'Unstoppable',
      description: 'Listen 100 days in a row',
      category: AchievementCategory.streak,
      threshold: 100,
      icon: 'bolt',
    ),
  ];

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _stats = jsonDecode(prefs.getString(_statsKey) ?? '{}');

    final savedJson = prefs.getString(_prefsKey);
    if (savedJson != null) {
      try {
        final list = jsonDecode(savedJson) as List;
        final saved = list.map((e) => Achievement.fromJson(e)).toList();
        _achievements = _defaultAchievements.map((def) {
          final existing = saved.where((s) => s.id == def.id).firstOrNull;
          if (existing != null) {
            return def.copyWith(
              unlocked: existing.unlocked,
              unlockedAt: existing.unlockedAt,
              currentProgress: existing.currentProgress,
            );
          }
          return def;
        }).toList();
      } catch (_) {
        _achievements = List.from(_defaultAchievements);
      }
    } else {
      _achievements = List.from(_defaultAchievements);
    }

    _applyStats();
    _checkNewUnlocks();
    await _save();
  }

  void _applyStats() {
    final totalPlayed = _stats['total_played'] as int? ?? 0;
    final totalLikes = _stats['total_likes'] as int? ?? 0;
    final totalPlaylists = _stats['total_playlists'] as int? ?? 0;
    final uniqueTracks = _stats['unique_tracks'] as int? ?? 0;
    final streak = _stats['current_streak'] as int? ?? 0;

    _updateProgress('listen_100', totalPlayed);
    _updateProgress('listen_500', totalPlayed);
    _updateProgress('listen_1000', totalPlayed);
    _updateProgress('listen_5000', totalPlayed);
    _updateProgress('likes_10', totalLikes);
    _updateProgress('likes_50', totalLikes);
    _updateProgress('likes_100', totalLikes);
    _updateProgress('playlists_5', totalPlaylists);
    _updateProgress('playlists_10', totalPlaylists);
    _updateProgress('playlists_25', totalPlaylists);
    _updateProgress('discovery_50', uniqueTracks);
    _updateProgress('discovery_100', uniqueTracks);
    _updateProgress('discovery_500', uniqueTracks);
    _updateProgress('streak_7', streak);
    _updateProgress('streak_30', streak);
    _updateProgress('streak_100', streak);
  }

  void _updateProgress(String id, int value) {
    final idx = _achievements.indexWhere((a) => a.id == id);
    if (idx >= 0) {
      _achievements[idx] = _achievements[idx].copyWith(currentProgress: value);
    }
  }

  void _checkNewUnlocks() {
    for (int i = 0; i < _achievements.length; i++) {
      final a = _achievements[i];
      if (!a.unlocked && a.currentProgress >= a.threshold) {
        _achievements[i] = a.copyWith(
          unlocked: true,
          unlockedAt: DateTime.now(),
        );
        debugPrint('[Achievements] Unlocked: ${a.title}');
      }
    }
  }

  Future<void> recordTrackPlayed() async {
    _stats['total_played'] = (_stats['total_played'] as int? ?? 0) + 1;
    await _applyAndSave();
  }

  Future<void> recordTrackLiked() async {
    _stats['total_likes'] = (_stats['total_likes'] as int? ?? 0) + 1;
    await _applyAndSave();
  }

  Future<void> recordTrackUnliked() async {
    final current = _stats['total_likes'] as int? ?? 0;
    if (current > 0) _stats['total_likes'] = current - 1;
    await _applyAndSave();
  }

  Future<void> recordPlaylistCreated() async {
    _stats['total_playlists'] = (_stats['total_playlists'] as int? ?? 0) + 1;
    await _applyAndSave();
  }

  Future<void> recordPlaylistDeleted() async {
    final current = _stats['total_playlists'] as int? ?? 0;
    if (current > 0) _stats['total_playlists'] = current - 1;
    await _applyAndSave();
  }

  Future<void> recordUniqueTrack(String trackId) async {
    final seen = Set<String>.from(
        (_stats['seen_tracks'] as List?)?.cast<String>() ?? []);
    if (!seen.contains(trackId)) {
      seen.add(trackId);
      _stats['seen_tracks'] = seen.toList();
      _stats['unique_tracks'] = seen.length;
      await _applyAndSave();
    }
  }

  Future<void> recordListeningDay() async {
    final today = DateTime.now();
    final todayStr =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final days = Set<String>.from(
        (_stats['listening_days'] as List?)?.cast<String>() ?? []);

    final lastDay = _stats['last_listening_day'] as String?;
    int streak = _stats['current_streak'] as int? ?? 0;

    if (lastDay != null && lastDay != todayStr) {
      final lastDate = DateTime.tryParse(lastDay);
      if (lastDate != null) {
        final diff = DateTime(today.year, today.month, today.day)
            .difference(DateTime(lastDate.year, lastDate.month, lastDate.day))
            .inDays;
        if (diff == 1) {
          streak++;
        } else if (diff > 1) {
          streak = 1;
        }
      } else {
        streak = 1;
      }
    } else if (lastDay == null) {
      streak = 1;
    }

    days.add(todayStr);
    _stats['listening_days'] = days.toList();
    _stats['last_listening_day'] = todayStr;
    _stats['current_streak'] = streak;
    _stats['max_streak'] =
        max(streak, _stats['max_streak'] as int? ?? 0);

    await _applyAndSave();
  }

  int _max(int a, int b) => a > b ? a : b;

  Future<void> _applyAndSave() async {
    _applyStats();
    _checkNewUnlocks();
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_achievements.map((a) => a.toJson()).toList()),
    );
    await prefs.setString(_statsKey, jsonEncode(_stats));
  }

  Map<String, dynamic> getStats() {
    return {
      'total_played': _stats['total_played'] ?? 0,
      'total_likes': _stats['total_likes'] ?? 0,
      'total_playlists': _stats['total_playlists'] ?? 0,
      'unique_tracks': _stats['unique_tracks'] ?? 0,
      'current_streak': _stats['current_streak'] ?? 0,
      'max_streak': _stats['max_streak'] ?? 0,
      'listening_days_count':
          (_stats['listening_days'] as List?)?.length ?? 0,
      'unlocked_count': unlockedCount,
      'total_count': totalCount,
    };
  }

  List<Achievement> getByCategory(AchievementCategory category) {
    return _achievements.where((a) => a.category == category).toList();
  }

  Achievement? getById(String id) {
    try {
      return _achievements.firstWhere((a) => a.id == id);
    } catch (_) {
      return null;
    }
  }

  double get overallProgress {
    if (_achievements.isEmpty) return 0.0;
    final total =
        _achievements.fold<double>(0.0, (sum, a) => sum + a.progress);
    return total / _achievements.length;
  }

  Future<void> reset() async {
    _achievements = List.from(_defaultAchievements);
    _stats = {};
    await _save();
    notifyListeners();
  }
}
