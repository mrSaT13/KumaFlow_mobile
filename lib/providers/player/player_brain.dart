part of '../player_provider.dart';

/// KumaFlow Brain: опциональный best-effort мост. null = выключен.
/// Очередь живёт в клиенте, KumaFlow Brain только докладывает — плеер не зависит от него.
extension PlayerBrainMirror on PlayerProvider {
  void attachBrain(dynamic bridge) {
    _brain = bridge;
    // KumaFlow Brain как источник AutoDJ: та же очередь, тот же движок.
    try {
      // ignore: avoid_dynamic_calls
      final bset = _brain?.settings;
      if (bset != null) _autoDjService.setBrain(_brain, bset);
    } catch (_) {}
    // Офлайн-гейт: в офлайне мост не трогает сеть (сразу локальный путь),
    // события копятся и уходят при возврате онлайна.
    try {
      // ignore: avoid_dynamic_calls
      _brain?.isOffline = () {
        try {
          return _offlineService.isOfflineMode;
        } catch (_) {
          return false;
        }
      };
    } catch (_) {}
    // Handoff при старте: один раз подтягиваем resume (seek/пауза/stale — внутри).
    try {
      unawaited(_maybeResumeFromBrain());
    } catch (_) {}
  }

  void _brainEvent(String trackId, String action, {int positionSec = 0}) {
    try {
      // ignore: avoid_dynamic_calls
      _brain?.reportEvent(trackId, action, positionSec: positionSec);
    } catch (_) {}
  }

  void _brainRate(String trackId, bool? like) {
    try {
      // ignore: avoid_dynamic_calls
      _brain?.reportRate(trackId, like);
    } catch (_) {}
  }

  void _brainHistory(String trackId) {
    try {
      // ignore: avoid_dynamic_calls
      _brain?.reportHistory(trackId);
    } catch (_) {}
  }

  // Зеркало очереди: метод переехал в part player/player_live.dart
  // (_brainPublish/_brainPublishNow + heartbeat + resume).
}
