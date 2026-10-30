import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import 'bpm_analyzer_service.dart';
import 'storage_service.dart';

/// Easing для crossfade — порт D:\kumaflow-1.6.1\src\service\crossfade-service.ts
enum CrossfadeEasing {
  linear,
  easeIn,
  easeOut,
  easeInOut,
}

/// Service for BPM-aware crossfade with easing.
///
/// Calculates optimal crossfade timing based on track BPM and applies
/// 50ms interpolated volume fading (linear/ease-in/out/in-out) как в desktop.
class BpmCrossfadeService {
  static final BpmCrossfadeService _instance = BpmCrossfadeService._internal();
  factory BpmCrossfadeService() => _instance;
  BpmCrossfadeService._internal();

  static const _kEnabledKey = 'bpm_crossfade_enabled';
  static const _kMinDurationKey = 'bpm_crossfade_min_duration';
  static const _kMaxDurationKey = 'bpm_crossfade_max_duration';
  static const _kEasingKey = 'bpm_crossfade_easing';

  bool _isEnabled = false;
  double _minDuration = 2.0; // seconds
  double _maxDuration = 8.0; // seconds
  CrossfadeEasing _easing = CrossfadeEasing.easeInOut;

  final _bpmAnalyzer = BpmAnalyzerService();
  Timer? _fadeTimer;
  bool _isFading = false;
  bool _isSingleFading = false;

  bool get isEnabled => _isEnabled;
  double get minDuration => _minDuration;
  double get maxDuration => _maxDuration;
  CrossfadeEasing get easing => _easing;
  bool get isFading => _isFading;

  bool _gaplessCache = true;
  bool _crossfadeCache = true;
  bool get isEffectivelyEnabled => _isEnabled && _gaplessCache && _crossfadeCache;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final storage = StorageService();
    final savedEnabled = prefs.getBool(_kEnabledKey) ?? false;
    _isEnabled = savedEnabled;
    final gapless = await storage.getGaplessPlayback();
    final crossfadeEnabled = await storage.getCrossfadeEnabled();
    final crossfadeSec = await storage.getCrossfadeSeconds();
    _gaplessCache = gapless;
    _crossfadeCache = crossfadeEnabled;
    _minDuration = prefs.getDouble(_kMinDurationKey) ?? 2.0;
    _maxDuration = prefs.getDouble(_kMaxDurationKey) ?? 8.0;
    // Центрируем диапазон вокруг crossfadeSeconds (не трогаем savedEnabled, используем effective)
    if (gapless && crossfadeEnabled) {
      _minDuration = (crossfadeSec - 2).clamp(1.0, 6.0).toDouble();
      _maxDuration = (crossfadeSec + 3).clamp(3.0, 12.0).toDouble();
    }
    final easingStr = prefs.getString(_kEasingKey) ?? 'easeInOut';
    _easing = _parseEasing(easingStr);
    await _bpmAnalyzer.initialize();
    debugPrint('[BpmCrossfade] init gapless=$gapless crossfade=$crossfadeEnabled sec=$crossfadeSec -> $_minDuration-$_maxDuration $_easing saved=$_isEnabled effective=$isEffectivelyEnabled');
  }

  Future<void> syncGaplessCrossfade({bool? gapless, bool? crossfadeEnabled, int? crossfadeSec}) async {
    if (gapless != null) _gaplessCache = gapless;
    if (crossfadeEnabled != null) _crossfadeCache = crossfadeEnabled;
    if (crossfadeSec != null && _gaplessCache && _crossfadeCache) {
      _minDuration = (crossfadeSec - 2).clamp(1.0, 6.0).toDouble();
      _maxDuration = (crossfadeSec + 3).clamp(3.0, 12.0).toDouble();
    }
  }

  Future<void> setEnabled(bool value) async {
    _isEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey, value);
  }

  Future<void> setDurationBounds(double min, double max) async {
    _minDuration = min;
    _maxDuration = max;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kMinDurationKey, min);
    await prefs.setDouble(_kMaxDurationKey, max);
  }

  Future<void> setEasing(CrossfadeEasing easing) async {
    _easing = easing;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kEasingKey, easing.name);
  }

  void configure({double? duration, CrossfadeEasing? easing}) {
    if (duration != null) {
      _minDuration = duration.clamp(1.0, 8.0);
      _maxDuration = (_minDuration + 4).clamp(2.0, 12.0);
    }
    if (easing != null) _easing = easing;
    debugPrint('[BpmCrossfade] Configured: ${_minDuration.toStringAsFixed(1)}-${_maxDuration.toStringAsFixed(1)}s, $_easing');
  }

  /// Calculate optimal crossfade duration for transition between two tracks.
  Future<double> calculateCrossfadeDuration({
    required Song currentTrack,
    required Song nextTrack,
    required String currentAudioUrl,
    required String nextAudioUrl,
  }) async {
    if (!isEffectivelyEnabled) return _minDuration;

    try {
      final currentBpm = await _bpmAnalyzer.getBPM(currentTrack, currentAudioUrl);
      final nextBpm = await _bpmAnalyzer.getBPM(nextTrack, nextAudioUrl);

      final avgBpm = (currentBpm + nextBpm) / 2.0;
      final avgBps = avgBpm / 60.0;

      double crossfadeBeats;
      if (avgBpm >= 120) {
        crossfadeBeats = 2.5;
      } else if (avgBpm >= 90) {
        crossfadeBeats = 3.0;
      } else {
        crossfadeBeats = 3.5;
      }

      double crossfadeSeconds = crossfadeBeats / avgBps;
      crossfadeSeconds = crossfadeSeconds.clamp(_minDuration, _maxDuration);

      debugPrint('[BpmCrossfade] BPM: $currentBpm -> $nextBpm, '
          'Crossfade: ${crossfadeSeconds.toStringAsFixed(1)}s '
          '(${crossfadeBeats.toStringAsFixed(1)} beats) easing=$_easing');

      return crossfadeSeconds;
    } catch (e) {
      debugPrint('[BpmCrossfade] Error calculating crossfade: $e');
      return _minDuration;
    }
  }

  double getRecommendedDuration(int bpm) {
    double crossfadeBeats;
    if (bpm >= 120) {
      crossfadeBeats = 2.5;
    } else if (bpm >= 90) {
      crossfadeBeats = 3.0;
    } else {
      crossfadeBeats = 3.5;
    }
    final bps = bpm / 60.0;
    double seconds = crossfadeBeats / bps;
    return seconds.clamp(_minDuration, _maxDuration);
  }

  /// 50мс интерполяция громкости с easing — аналог desktop crossfade-service.ts:106-155
  /// Принимает коллбеки установки громкости, чтобы не зависеть от конкретного плеера.
  Future<void> performCrossfade({
    required double fromVolume,
    required double toVolume,
    required double durationSeconds,
    CrossfadeEasing? easing,
    required void Function(double currentVol, double nextVol) onVolumes,
    VoidCallback? onComplete,
  }) async {
    if (_isFading) {
      debugPrint('[BpmCrossfade] Already fading, skip');
      return;
    }
    _isFading = true;
    final fadeEasing = easing ?? _easing;
    final fadeMs = (durationSeconds * 1000).round();
    const interval = 50; // ms как в desktop
    final steps = (fadeMs / interval).ceil();
    int currentStep = 0;

    final completer = Completer<void>();
    _fadeTimer?.cancel();
    _fadeTimer = Timer.periodic(const Duration(milliseconds: interval), (timer) {
      currentStep++;
      final progress = (currentStep / steps).clamp(0.0, 1.0);
      final eased = _applyEasing(progress, fadeEasing);
      final currentGain = fromVolume * (1 - eased);
      final nextGain = toVolume * eased;
      onVolumes(currentGain.clamp(0.0, 1.0), nextGain.clamp(0.0, 1.0));

      if (currentStep >= steps) {
        timer.cancel();
        _isFading = false;
        onComplete?.call();
        if (!completer.isCompleted) completer.complete();
      }
    });

    return completer.future;
  }

  /// BPM-длительность для одиночного фейда текущего трека.
  /// Возвращает null, когда фича эффективно выключена (тумблер/ gapless/
  /// crossfade) — вызыватель тогда использует обычный fade.
  /// BPM берётся из локального кэша/эвристики жанра, сети нет.
  Future<double?> fadeDurationFor(Song? song) async {
    if (!isEffectivelyEnabled || song == null) return null;
    try {
      final bpm = await _bpmAnalyzer
          .getBPM(song, '')
          .timeout(const Duration(seconds: 1));
      return getRecommendedDuration(bpm);
    } catch (_) {
      return (_minDuration + _maxDuration) / 2.0;
    }
  }

  /// Одиночный фейд громкости одного плеера с easing (50мс тики как в desktop).
  /// В отличие от performCrossfade (два плеера), коллбек асинхронный и ждётся
  /// каждый тик — порядок setVolume не инвертируется.
  Future<void> fadeSingle({
    required double from,
    required double to,
    required double durationSeconds,
    CrossfadeEasing? easing,
    required Future<void> Function(double volume) onVolume,
    bool Function()? isCancelled,
  }) async {
    // Свой флаг, не общий _isFading от двухплеерного performCrossfade.
    if (_isSingleFading) {
      debugPrint('[BpmCrossfade] Already fading, skip');
      return;
    }
    _isSingleFading = true;
    try {
      final fadeEasing = easing ?? _easing;
      final fadeMs = (durationSeconds * 1000).round().clamp(100, 12000);
      const interval = 50; // ms как в desktop
      final steps = (fadeMs / interval).ceil();
      for (var step = 1; step <= steps; step++) {
        if (isCancelled != null && isCancelled()) break;
        final progress = (step / steps).clamp(0.0, 1.0);
        final eased = _applyEasing(progress, fadeEasing);
        final vol = (from + (to - from) * eased).clamp(0.0, 1.0);
        try {
          await onVolume(vol);
        } catch (e) {
          debugPrint('[BpmCrossfade] setVolume error: $e');
          break;
        }
        if (step < steps) {
          await Future.delayed(const Duration(milliseconds: interval));
        }
      }
    } finally {
      _isSingleFading = false;
    }
  }

  /// Совместимость с just_audio: фейд одного плеера (out) + второго (in) через setVolume
  Future<void> crossfadePlayers({
    required dynamic currentPlayer, // AudioPlayer
    required dynamic nextPlayer, // AudioPlayer
    double? durationSeconds,
    CrossfadeEasing? easing,
  }) async {
    final dur = durationSeconds ?? _minDuration;
    final fromVol = (currentPlayer.volume as double?) ?? 1.0;
    final toVol = (nextPlayer.volume as double?) ?? 1.0;
    // Подготавливаем next как muted
    try {
      nextPlayer.setVolume(0.0);
    } catch (_) {}
    await performCrossfade(
      fromVolume: fromVol,
      toVolume: toVol,
      durationSeconds: dur,
      easing: easing,
      onVolumes: (cur, nxt) {
        try {
          currentPlayer.setVolume(cur);
          nextPlayer.setVolume(nxt);
        } catch (e) {
          debugPrint('[BpmCrossfade] setVolume error: $e');
        }
      },
    );
  }

  void cancelFade() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _isFading = false;
    _isSingleFading = false;
  }

  double _applyEasing(double progress, CrossfadeEasing easing) {
    switch (easing) {
      case CrossfadeEasing.linear:
        return progress;
      case CrossfadeEasing.easeIn:
        return progress * progress;
      case CrossfadeEasing.easeOut:
        return progress * (2 - progress);
      case CrossfadeEasing.easeInOut:
        return progress < 0.5
            ? 2 * progress * progress
            : -1 + (4 - 2 * progress) * progress;
    }
  }

  CrossfadeEasing _parseEasing(String s) {
    switch (s) {
      case 'linear': return CrossfadeEasing.linear;
      case 'easeIn': return CrossfadeEasing.easeIn;
      case 'easeOut': return CrossfadeEasing.easeOut;
      case 'easeInOut':
      default:
        return CrossfadeEasing.easeInOut;
    }
  }

  bool areTracksMixable(int bpm1, int bpm2, {double tolerance = 10.0}) {
    return (bpm1 - bpm2).abs() <= tolerance;
  }

  String getBpmCategory(int bpm) {
    if (bpm >= 140) return 'Very Fast';
    if (bpm >= 120) return 'Fast';
    if (bpm >= 100) return 'Medium';
    if (bpm >= 80) return 'Slow';
    return 'Very Slow';
  }

  void dispose() {
    cancelFade();
  }
}
