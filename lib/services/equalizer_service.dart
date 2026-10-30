import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'equalizer_engine.dart';

class EqualizerPreset {
  final String name;
  final List<double> bands; // 10 values, each ±12 dB

  const EqualizerPreset({required this.name, required this.bands});

  EqualizerPreset copyWith({String? name, List<double>? bands}) {
    return EqualizerPreset(
      name: name ?? this.name,
      bands: bands ?? List.from(this.bands),
    );
  }

  Map<String, dynamic> toJson() => {'name': name, 'bands': bands};

  factory EqualizerPreset.fromJson(Map<String, dynamic> json) {
    return EqualizerPreset(
      name: json['name'] as String,
      bands: (json['bands'] as List<dynamic>).map((e) => (e as num).toDouble()).toList(),
    );
  }
}

class EqualizerService extends ChangeNotifier {
  /// Global access for the player (re-push on track start, no BuildContext).
  static EqualizerService? _instance;
  static EqualizerService? get instanceOrNull => _instance;

  EqualizerService() {
    _instance = this;
  }
  static const List<String> bandLabels = [
    '32', '64', '125', '250', '500', '1K', '2K', '4K', '8K', '16K',
  ];

  static const _prefsKeyEnabled = 'eq_enabled';
  static const _prefsKeyBands = 'eq_bands';
  static const _prefsKeyPreset = 'eq_preset';
  static const _prefsKeyCustomPresets = 'eq_custom_presets';

  static const double minDb = -12.0;
  static const double maxDb = 12.0;

  static const Map<String, EqualizerPreset> builtInPresets = {
    'Flat': EqualizerPreset(name: 'Flat', bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    'Bass Boost': EqualizerPreset(name: 'Bass Boost', bands: [8, 6, 4, 2, 0, 0, 0, 0, 0, 0]),
    'Treble Boost': EqualizerPreset(name: 'Treble Boost', bands: [0, 0, 0, 0, 0, 0, 2, 4, 6, 8]),
    'Rock': EqualizerPreset(name: 'Rock', bands: [4, 3, -2, -4, -1, 1, 3, 5, 6, 6]),
    'Pop': EqualizerPreset(name: 'Pop', bands: [-1, 2, 4, 5, 4, 1, -1, -1, 1, 2]),
    'Jazz': EqualizerPreset(name: 'Jazz', bands: [3, 1, 0, 2, -2, -2, 0, 2, 4, 5]),
    'Classical': EqualizerPreset(name: 'Classical', bands: [0, 0, 0, 0, 0, 0, -4, -4, -4, -6]),
    'Electronic': EqualizerPreset(name: 'Electronic', bands: [5, 4, 1, 0, -2, 1, 0, 2, 4, 5]),
    'Vocal': EqualizerPreset(name: 'Vocal', bands: [-2, -1, 0, 3, 5, 5, 3, 1, 0, -2]),
  };

  bool _enabled = false;
  String _currentPresetName = 'Flat';
  List<double> _bands = List.filled(10, 0.0);
  Map<String, EqualizerPreset> _customPresets = {};

  /// True once the native effect confirmed caps. False = sliders do not
  /// change the sound (non-Android / init failed) — UI shows a hint.
  bool _engineSupported = false;
  bool get engineSupported => _engineSupported;
  int _deviceBands = 0;
  int get deviceBands => _deviceBands;

  bool get enabled => _enabled;
  String get currentPresetName => _currentPresetName;
  List<double> get bands => List.unmodifiable(_bands);

  Map<String, EqualizerPreset> get allPresets => {
        ...builtInPresets,
        ..._customPresets,
      };

  List<EqualizerPreset> get customPresetsList =>
      _customPresets.values.toList();

  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefsKeyEnabled) ?? false;
      _currentPresetName = prefs.getString(_prefsKeyPreset) ?? 'Flat';

      final bandsJson = prefs.getString(_prefsKeyBands);
      if (bandsJson != null) {
        final decoded = jsonDecode(bandsJson) as List<dynamic>;
        _bands = decoded.map((e) => (e as num).toDouble()).toList();
      } else {
        _applyPreset(builtInPresets[_currentPresetName] ?? builtInPresets['Flat']!);
      }

      final customJson = prefs.getString(_prefsKeyCustomPresets);
      if (customJson != null) {
        final decoded = jsonDecode(customJson) as Map<String, dynamic>;
        _customPresets = decoded.map(
          (k, v) => MapEntry(k, EqualizerPreset.fromJson(v as Map<String, dynamic>)),
        );
      }

      notifyListeners();
    } catch (e) {
      debugPrint('Failed to initialize equalizer service: $e');
    }
    // Probe the native effect (Android only). Best-effort, never throws.
    try {
      final caps = await EqualizerEngine.init();
      _engineSupported = caps != null;
      _deviceBands = (caps?['numBands'] as num?)?.toInt() ?? 0;
      notifyListeners();
      await pushToEngine();
    } catch (_) {
      _engineSupported = false;
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKeyEnabled, _enabled);
      await prefs.setString(_prefsKeyPreset, _currentPresetName);
      await prefs.setString(_prefsKeyBands, jsonEncode(_bands));
      await prefs.setString(
        _prefsKeyCustomPresets,
        jsonEncode(_customPresets.map((k, v) => MapEntry(k, v.toJson()))),
      );
    } catch (e) {
      debugPrint('Failed to save equalizer state: $e');
    }
  }

  void _applyPreset(EqualizerPreset preset) {
    _bands = preset.bands.map((e) => e.clamp(EqualizerService.minDb, EqualizerService.maxDb)).toList();
    _currentPresetName = preset.name;
  }

  /// Push current state to the native audio effect (fire-and-forget).
  /// Called after every audible change + on every track start: if the
  /// player session was not ready yet, the next push applies it.
  Future<void> pushToEngine() async {
    try {
      await EqualizerEngine.apply(enabled: _enabled, bandsDb: List.from(_bands));
    } catch (_) {}
  }

  void toggleEnabled() {
    _enabled = !_enabled;
    notifyListeners();
    _save();
    unawaited(pushToEngine());
  }

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    _save();
    unawaited(pushToEngine());
  }

  void setBand(int index, double value) {
    if (index < 0 || index >= 10) return;
    final clamped = value.clamp(minDb, maxDb);
    if (_bands[index] == clamped) return;
    _bands[index] = clamped;
    _currentPresetName = 'Custom';
    notifyListeners();
    _save();
    unawaited(pushToEngine());
  }

  void selectPreset(String name) {
    final preset = allPresets[name];
    if (preset == null) return;
    _applyPreset(preset);
    notifyListeners();
    _save();
    unawaited(pushToEngine());
  }

  void resetToFlat() {
    _applyPreset(builtInPresets['Flat']!);
    notifyListeners();
    _save();
    unawaited(pushToEngine());
  }

  void saveCustomPreset(String name) {
    final preset = EqualizerPreset(name: name, bands: List.from(_bands));
    _customPresets[name] = preset;
    _currentPresetName = name;
    notifyListeners();
    _save();
  }

  void deleteCustomPreset(String name) {
    if (!builtInPresets.containsKey(name) && _customPresets.containsKey(name)) {
      _customPresets.remove(name);
      if (_currentPresetName == name) {
        _applyPreset(builtInPresets['Flat']!);
      }
      notifyListeners();
      _save();
      unawaited(pushToEngine());
    }
  }
}
