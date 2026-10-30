import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/ml/ml_types.dart';

class MultiArmedBandit {
  static const String storageKey = 'ml_bandit_v1';
  static const int _maxContextRewards = 100;
  static const int _maxArms = 2000;

  final Map<String, Map<String, dynamic>> _arms = {};
  final Random _random = Random();
  double _epsilon = 0.15;
  final double _decayRate = 0.995;
  final double _minEpsilon = 0.05;
  int _totalPulls = 0;
  String _strategy = 'epsilon-greedy';
  Timer? _persistTimer;

  MABArm selectArm(List<MABArm> arms, MABContext context) {
    if (arms.isEmpty) {
      return MABArm(id: 'empty', type: 'genre', name: 'Unknown');
    }

    _totalPulls++;
    _epsilon = max(_minEpsilon, _epsilon * pow(_decayRate, _totalPulls));

    switch (_strategy) {
      case 'thompson-sampling':
        return _thompsonSampling(arms, context);
      case 'ucb':
        return _ucb(arms, context);
      default:
        return _epsilonGreedy(arms, context);
    }
  }

  MABArm _epsilonGreedy(List<MABArm> arms, MABContext context) {
    if (_random.nextDouble() < _epsilon) {
      return _explore(arms);
    }
    return _exploit(arms, context);
  }

  MABArm _thompsonSampling(List<MABArm> arms, MABContext context) {
    MABArm? best;
    double bestSample = -1;

    for (final arm in arms) {
      final contextKey = '${context.timeOfDay}-${context.dayOfWeek}';
      final armData = _arms[arm.id];
      List<double> rewards = [];
      if (armData != null && armData['contextRewards'] != null) {
        rewards = List<double>.from((armData['contextRewards'] as Map<String, List<dynamic>>?)?[contextKey] ?? []);
      }

      final successes = rewards.where((r) => r > 0).length.toDouble() + 1;
      final failures = rewards.where((r) => r <= 0).length.toDouble() + 1;

      final mean = successes / (successes + failures);
      final variance = (successes * failures) / ((successes + failures) * (successes + failures) * (successes + failures + 1));
      final sample = mean + _random.nextGaussian() * sqrt(max(0, variance));

      if (sample > bestSample) {
        bestSample = sample;
        best = arm;
      }
    }

    return best ?? arms.first;
  }

  MABArm _ucb(List<MABArm> arms, MABContext context) {
    MABArm? best;
    double bestScore = -1;

    for (final arm in arms) {
      if (arm.totalPlays == 0) return arm;

      final ucbScore = arm.avgReward + 1.41 * sqrt(log(_totalPulls) / arm.totalPlays);
      if (ucbScore > bestScore) {
        bestScore = ucbScore;
        best = arm;
      }
    }

    return best ?? arms.first;
  }

  MABArm _explore(List<MABArm> arms) {
    final newArms = arms.where((a) => a.totalPlays < 3).toList();
    if (newArms.isNotEmpty && _random.nextDouble() < 0.5) {
      return newArms[_random.nextInt(newArms.length)];
    }
    return arms[_random.nextInt(arms.length)];
  }

  MABArm _exploit(List<MABArm> arms, MABContext context) {
    final contextKey = '${context.timeOfDay}-${context.dayOfWeek}';
    MABArm? best;
    double bestScore = -1;

    for (final arm in arms) {
      double contextBonus = 0;
      final armData = _arms[arm.id];
      if (armData != null && armData['contextRewards'] != null) {
        final contextRewards = List<double>.from((armData['contextRewards'] as Map<String, List<dynamic>>?)?[contextKey] ?? []);
        if (contextRewards.isNotEmpty) {
          contextBonus = contextRewards.reduce((a, b) => a + b) / contextRewards.length;
        }
      }

      final score = arm.avgReward + contextBonus;
      if (score > bestScore) {
        bestScore = score;
        best = arm;
      }
    }

    return best ?? arms.first;
  }

  void recordReward(String armId, double reward, MABContext context, String armType, String? armName) {
    final contextKey = '${context.timeOfDay}-${context.dayOfWeek}';

    if (!_arms.containsKey(armId)) {
      _arms[armId] = {
        'arm': MABArm(id: armId, type: armType, name: armName ?? armId),
        'contextRewards': <String, List<double>>{},
      };
    }

    final armData = _arms[armId]!;
    final arm = armData['arm'] as MABArm;
    arm.totalPlays++;
    arm.totalRewards += reward;
    arm.avgReward = arm.totalRewards / arm.totalPlays;
    arm.lastPlayed = DateTime.now().millisecondsSinceEpoch;

    final contextRewards = armData['contextRewards'] as Map<String, List<double>>;
    contextRewards.putIfAbsent(contextKey, () => []);
    contextRewards[contextKey]!.add(reward);
    if (contextRewards[contextKey]!.length > _maxContextRewards) {
      contextRewards[contextKey]!.removeAt(0);
    }
    _schedulePersist();
  }

  /// Seed arms from cold-start onboarding answers (genres/artists the user
  /// picked + artists of liked songs). Rewards: genre +1, artist +2.
  /// Each seed counts as one pull so averages start at the seed value.
  void seedFromColdStart({
    required Set<String> genres,
    required Map<String, String> artistNames,
    double genreReward = 1.0,
    double artistReward = 2.0,
  }) {
    final ctx = getCurrentContext();
    for (final g in genres) {
      final id = g.trim();
      if (id.isEmpty) {
        continue;
      }
      recordReward(id, genreReward, ctx, 'genre', id);
    }
    artistNames.forEach((id, name) {
      if (id.isEmpty) {
        return;
      }
      recordReward(id, artistReward, ctx, 'artist', name);
    });
  }

  // ─── Persistence (SharedPreferences, key ml_bandit_v1) ─────────────

  Map<String, dynamic> toJson() => {
    'totalPulls': _totalPulls,
    'epsilon': _epsilon,
    'strategy': _strategy,
    'arms': _arms.map((id, data) {
      final arm = data['arm'] as MABArm;
      final rewards = data['contextRewards'] as Map<String, List<double>>;
      return MapEntry(id, {
        'arm': arm.toJson(),
        'contextRewards': rewards.map((k, v) => MapEntry(k, v.toList())),
      });
    }),
  };

  void loadFromJson(Map<String, dynamic> json) {
    _arms.clear();
    _totalPulls = (json['totalPulls'] as num?)?.toInt() ?? 0;
    _epsilon = ((json['epsilon'] as num?)?.toDouble() ?? 0.15)
        .clamp(_minEpsilon, 1.0);
    final strategy = json['strategy'] as String?;
    if (strategy != null && strategy.isNotEmpty) _strategy = strategy;
    final arms = json['arms'] as Map<String, dynamic>?;
    if (arms == null) return;
    for (final entry in arms.entries.take(_maxArms)) {
      try {
        final data = entry.value as Map<String, dynamic>;
        final arm = MABArm.fromJson(data['arm'] as Map<String, dynamic>);
        final rewards = <String, List<double>>{};
        final raw = data['contextRewards'] as Map<String, dynamic>?;
        raw?.forEach((k, v) {
          final list =
              (v as List).map((e) => (e as num).toDouble()).toList();
          rewards[k] = list.length > _maxContextRewards
              ? list.sublist(list.length - _maxContextRewards)
              : list;
        });
        _arms[entry.key] = {'arm': arm, 'contextRewards': rewards};
      } catch (_) {}
    }
  }

  /// Load persisted state. Safe to call fire-and-forget.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return;
      loadFromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {}
  }

  /// Persist state immediately.
  Future<void> save() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, jsonEncode(toJson()));
    } catch (_) {}
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(seconds: 2), () {
      _persistTimer = null;
      save();
    });
  }

  MABContext getCurrentContext() {
    final now = DateTime.now();
    final hour = now.hour;
    String timeOfDay;
    if (hour >= 6 && hour < 12) timeOfDay = 'morning';
    else if (hour >= 12 && hour < 17) timeOfDay = 'day';
    else if (hour >= 17 && hour < 22) timeOfDay = 'evening';
    else timeOfDay = 'night';

    final dayOfWeek = now.weekday >= 6 ? 'weekend' : 'weekday';
    final recentMood = 'neutral';

    return MABContext(
      timeOfDay: timeOfDay,
      dayOfWeek: dayOfWeek,
      sessionHistory: [],
      recentMood: recentMood,
      hour: hour,
    );
  }

  double calculateReward(String action) {
    switch (action) {
      case 'like': return 10.0;
      case 'dislike': return -10.0;
      case 'skip_early': return -5.0;
      case 'skip_late': return -2.0;
      case 'full_play': return 5.0;
      case 'replay': return 15.0;
      case 'seek_back': return 8.0;
      case 'abandon': return -3.0;
      default: return 0.0;
    }
  }

  List<MABArm> getTopArms(int count) {
    final allArms = _arms.values.map((d) => d['arm'] as MABArm).toList();
    allArms.sort((a, b) => b.avgReward.compareTo(a.avgReward));
    return allArms.take(count).toList();
  }

  double getCurrentEpsilon() => _epsilon;

  void setStrategy(String strategy) {
    _strategy = strategy;
  }

  Map<String, dynamic> getStats() {
    return {
      'totalPulls': _totalPulls,
      'epsilon': _epsilon,
      'strategy': _strategy,
      'totalArms': _arms.length,
    };
  }

  void reset() {
    _persistTimer?.cancel();
    _persistTimer = null;
    _arms.clear();
    _totalPulls = 0;
    _epsilon = 0.15;
    save();
  }
}

extension on Random {
  double nextGaussian() {
    final u1 = nextDouble();
    final u2 = nextDouble();
    return sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2);
  }
}
