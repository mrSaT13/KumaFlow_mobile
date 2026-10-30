import 'dart:io';

import 'package:flutter/services.dart';

/// Thin bridge to the native system equalizer (Android audiofx Equalizer
/// attached to just_audio's ExoPlayer session).
///
/// Non-Android platforms have no hook: every call returns null/false and
/// the UI shows an honest "unavailable" hint instead of fake sliders.
class EqualizerEngine {
  static const _ch = MethodChannel('com.kumaflow.app/equalizer');

  static bool get isSupportedPlatform {
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// Probe native side. Returns caps map or null when unavailable.
  static Future<Map<String, dynamic>?> init() async {
    if (!isSupportedPlatform) return null;
    try {
      final r = await _ch.invokeMethod<Map>('init');
      if (r == null) return null;
      return Map<String, dynamic>.from(r);
    } catch (_) {
      return null;
    }
  }

  /// Push enabled flag + 10 band values (dB) to the native effect.
  /// Best-effort: false = not applied (no session yet / unsupported).
  /// Dart re-pushes on every track start, so a false here self-heals.
  static Future<bool> apply({
    required bool enabled,
    required List<double> bandsDb,
  }) async {
    if (!isSupportedPlatform) return false;
    try {
      final r = await _ch.invokeMethod<Map>(
        'apply',
        {'enabled': enabled, 'bandsDb': List<double>.from(bandsDb)},
      );
      if (r == null) return false;
      return (r['ok'] as bool?) ?? false;
    } catch (_) {
      return false;
    }
  }
}
