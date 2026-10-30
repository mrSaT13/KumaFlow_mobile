part of '../player_provider.dart';

/// Fade in/out и плавная смена громкости (линейные + BPM-кривые).
extension PlayerFades on PlayerProvider {
  void _stopFade() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _isFading = false;
  }

  Future<void> _fadeIn() async {
    _stopFade();

    if (!_fadeSettingsService.getFadeEnabled()) {
      await _audioPlayer.setVolume(_volume);
      return;
    }

    // BPM-Aware Crossfade включён — длительность и кривая из BPM текущего
    // трека вместо линейного fade. Раньше тумблер BPM ни на что не влиял.
    try {
      final bpmDur =
          await BpmCrossfadeService().fadeDurationFor(_currentSong);
      if (bpmDur != null) {
        _isFading = true;
        await _audioPlayer.setVolume(0.0);
        final fut = BpmCrossfadeService().fadeSingle(
          from: 0.0,
          to: _volume,
          durationSeconds: bpmDur,
          onVolume: (v) => _audioPlayer.setVolume(v),
          isCancelled: () => !_isFading,
        ).then((_) {
          _isFading = false;
        });
        // Как и раньше: не ждём завершения — звук идёт сразу с 0.
        unawaited(fut);
        return;
      }
    } catch (_) {}
    _isFading = false;

    final fadeDurationMs = _fadeSettingsService.getFadeDurationMs();
    final steps = 20;
    final stepDurationMs = fadeDurationMs ~/ steps;
    final volumeStep = _volume / steps;

    _isFading = true;
    await _audioPlayer.setVolume(0.0);

    var currentStep = 0;
    final completer = Completer<void>();
    _fadeTimer =
        Timer.periodic(Duration(milliseconds: stepDurationMs), (timer) async {
      if (!_isFading) {
        timer.cancel();
        _isFading = false;
        if (!completer.isCompleted) completer.complete();
        return;
      }
      if (currentStep >= steps) {
        timer.cancel();
        _isFading = false;
        await _audioPlayer.setVolume(_volume);
        if (!completer.isCompleted) completer.complete();
        return;
      }
      currentStep++;
      final newVolume = volumeStep * currentStep;
      await _audioPlayer.setVolume(newVolume.clamp(0.0, _volume));
    });
    // Не ждем завершения фейда — play уже идет, звук появляется сразу с 0
    // Но громкость гарантированно дорастет до _volume в фоне
    unawaited(completer.future);
  }

  Future<void> _fadeOut({Future<void> Function()? onComplete}) async {
    _stopFade();

    if (!_fadeSettingsService.getFadeEnabled()) {
      await _audioPlayer.setVolume(0.0);
      if (onComplete != null) await onComplete();
      return;
    }

    // BPM-Aware Crossfade включён — затухание по BPM-кривой вместо линейного.
    try {
      final bpmDur =
          await BpmCrossfadeService().fadeDurationFor(_currentSong);
      if (bpmDur != null) {
        _isFading = true;
        final currentVolume = _audioPlayer.volume;
        if (currentVolume < 0.01) {
          _isFading = false;
          if (onComplete != null) await onComplete();
          return;
        }
        await BpmCrossfadeService().fadeSingle(
          from: currentVolume,
          to: 0.0,
          durationSeconds: bpmDur,
          onVolume: (v) => _audioPlayer.setVolume(v),
          isCancelled: () => !_isFading,
        );
        _isFading = false;
        await _audioPlayer.setVolume(0.0);
        if (onComplete != null) await onComplete();
        return;
      }
    } catch (_) {}
    _isFading = false;

    final fadeDurationMs = _fadeSettingsService.getFadeDurationMs();
    final steps = 20;
    final stepDurationMs = fadeDurationMs ~/ steps;
    final currentVolume = _audioPlayer.volume;
    if (currentVolume < 0.01) {
      if (onComplete != null) await onComplete();
      return;
    }
    final volumeStep = currentVolume / steps;

    _isFading = true;

    final completer = Completer<void>();
    var currentStep = 0;
    _fadeTimer =
        Timer.periodic(Duration(milliseconds: stepDurationMs), (timer) async {
      if (!_isFading) {
        timer.cancel();
        _isFading = false;
        if (!completer.isCompleted) completer.complete();
        return;
      }
      if (currentStep >= steps) {
        timer.cancel();
        _isFading = false;
        await _audioPlayer.setVolume(0.0);
        if (onComplete != null) await onComplete();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      currentStep++;
      final newVolume = currentVolume - (volumeStep * currentStep);
      await _audioPlayer.setVolume(newVolume.clamp(0.0, 1.0));
    });
    await completer.future;
  }

  void _smoothVolumeChange(double targetVolume, {int durationMs = 150}) {
    // Не прерывать активный fadeIn — иначе громкость застрянет на 0
    if (_isFading) return;

    final currentVolume = _audioPlayer.volume;
    if ((currentVolume - targetVolume).abs() < 0.01) return;

    final steps = 10;
    final stepDurationMs = durationMs ~/ steps;
    final volumeDiff = targetVolume - currentVolume;
    final volumeStep = volumeDiff / steps;

    _isFading = true;

    var currentStep = 0;
    _fadeTimer =
        Timer.periodic(Duration(milliseconds: stepDurationMs), (timer) async {
      if (!_isFading || currentStep >= steps) {
        timer.cancel();
        _isFading = false;
        return;
      }
      currentStep++;
      final newVolume = currentVolume + (volumeStep * currentStep);
      await _audioPlayer.setVolume(newVolume.clamp(0.0, 1.0));
    });
  }
}
