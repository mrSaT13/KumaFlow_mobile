import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AccentColor {
  red,
  pink,
  orange,
  yellow,
  green,
  blue,
  purple,
  polar,
}

extension AccentColorExt on AccentColor {
  
  Color get color {
    switch (this) {
      case AccentColor.red:
        return const Color(0xFFFF6B00);
      case AccentColor.pink:
        return const Color(0xFFFC5C65);
      case AccentColor.orange:
        return const Color(0xFFFF9500);
      case AccentColor.yellow:
        return const Color(0xFFFFCC00);
      case AccentColor.green:
        return const Color(0xFF1DB954);
      case AccentColor.blue:
        return const Color(0xFF007AFF);
      case AccentColor.purple:
        return const Color(0xFF8B5CF6);
      case AccentColor.polar:
        return const Color(0xFF4E8CA8);
    }
  }

  String get persistKey {
    switch (this) {
      case AccentColor.red:
        return 'red';
      case AccentColor.pink:
        return 'pink';
      case AccentColor.orange:
        return 'orange';
      case AccentColor.yellow:
        return 'yellow';
      case AccentColor.green:
        return 'green';
      case AccentColor.blue:
        return 'blue';
      case AccentColor.purple:
        return 'purple';
      case AccentColor.polar:
        return 'polar';
    }
  }

  static AccentColor fromKey(String key) {
    switch (key) {
      case 'pink':
        return AccentColor.pink;
      case 'orange':
        return AccentColor.orange;
      case 'yellow':
        return AccentColor.yellow;
      case 'green':
        return AccentColor.green;
      case 'blue':
        return AccentColor.blue;
      case 'purple':
        return AccentColor.purple;
      case 'polar':
        return AccentColor.polar;
      default:
        return AccentColor.polar;
    }
  }
}

class ThemeService extends ChangeNotifier {
  static const String _keyThemeMode = 'app_theme_mode';
  static const String _keyAccentColor = 'app_accent_color';
  static const String _keyLiquidGlass = 'app_liquid_glass';
  static const String _keyAmoled = 'app_amoled';
  static const String _keyGradientIntensity = 'app_gradient_intensity';

  static int _cachedAccentInt = 0xFF4E8CA8;
  static int get cachedAccentInt => _cachedAccentInt;

  ThemeMode _themeMode = ThemeMode.system;
  AccentColor _accentColor = AccentColor.polar;
  bool _liquidGlass = false;
  bool _amoled = false;
  double _gradientIntensity = 1.0;

  ThemeMode get themeMode => _themeMode;
  AccentColor get accentColor => _accentColor;
  bool get liquidGlass => _liquidGlass;
  bool get amoled => _amoled;
  double get gradientIntensity => _gradientIntensity;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();

    final modeKey = prefs.getString(_keyThemeMode) ?? 'system';
    _themeMode = _themeModeFromKey(modeKey);

    final colorKey = prefs.getString(_keyAccentColor) ?? 'polar';
    _accentColor = AccentColorExt.fromKey(colorKey);
    _cachedAccentInt = _accentColor.color.toARGB32();

    _liquidGlass = prefs.getBool(_keyLiquidGlass) ?? false;
    _amoled = prefs.getBool(_keyAmoled) ?? false;
    _gradientIntensity = prefs.getDouble(_keyGradientIntensity) ?? 1.0;
    // clamp to valid range
    if (_gradientIntensity < 0) _gradientIntensity = 0;
    if (_gradientIntensity > 1) _gradientIntensity = 1;
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyThemeMode, _themeModeToKey(mode));
  }

  Future<void> setAccentColor(AccentColor color) async {
    _accentColor = color;
    _cachedAccentInt = color.color.toARGB32();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAccentColor, color.persistKey);
  }

  Future<void> setLiquidGlass(bool enabled) async {
    _liquidGlass = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyLiquidGlass, enabled);
  }

  Future<void> setAmoled(bool enabled) async {
    _amoled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAmoled, enabled);
  }

  Future<void> setGradientIntensity(double value) async {
    final v = value.clamp(0.0, 1.0);
    _gradientIntensity = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyGradientIntensity, v);
  }

  static ThemeMode _themeModeFromKey(String key) {
    switch (key) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static String _themeModeToKey(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      default:
        return 'system';
    }
  }
}
