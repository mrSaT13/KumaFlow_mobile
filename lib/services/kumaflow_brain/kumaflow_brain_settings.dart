import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'kumaflow_brain_options.dart';

/// Настройки связки с KumaFlow Brain.
/// По умолчанию ВЫКЛ — мобила работает чисто локально.
/// Включение + URL (например http://192.168.1.10:3030) активирует KumaFlowBrainBridge.
class KumaFlowBrainSettings extends ChangeNotifier {
  static const _kEnabled = 'brain_enabled';
  static const _kBaseUrl = 'brain_base_url';
  static const _kToken = 'brain_api_token';
  static const _kUserId = 'brain_user_id';
  static const _kUsername = 'brain_username';
  static const _kWaveEnabled = 'brain_wave_enabled';
  static const _kWaveCount = 'brain_wave_count';
  static const _kWaveActivity = 'brain_wave_activity';
  static const _kWaveCharacteristic = 'brain_wave_characteristic';
  static const _kWaveMood = 'brain_wave_mood';
  static const _kWaveLanguage = 'brain_wave_language';
  static const _kWaveLanguageStrict = 'brain_wave_language_strict';
  static const _kWaveOptionsJson = 'brain_wave_options_json';
  static const _kWaveOptionsAt = 'brain_wave_options_at';
  static const _kOptionsTtlHours = 24;

  bool _enabled = false;
  String _baseUrl = '';
  String _apiToken = '';
  String _userId = '';
  String _username = '';
  bool _loaded = false;
  // Волна как источник: отдельный тумблер + N. По умолчанию ВЫКЛ.
  bool _waveEnabled = false;
  int _waveCount = 10;
  String _waveActivity = '';
  String _waveCharacteristic = '';
  String _waveMood = '';
  String _waveLanguage = '';
  bool _languageStrict = false;
  String _optionsJson = '';
  int _optionsAtMs = 0;

  bool get enabled => _enabled;
  String get baseUrl => _baseUrl;
  String get apiToken => _apiToken;
  String get userId => _userId;
  String get username => _username;
  bool get loaded => _loaded;
  bool get waveEnabled => _waveEnabled;
  int get waveCount => _waveCount;
  String get waveActivity => _waveActivity;
  String get waveCharacteristic => _waveCharacteristic;
  String get waveMood => _waveMood;
  String get waveLanguage => _waveLanguage;
  bool get languageStrict => _languageStrict;

  /// Кеш каталога /api/wave/options (сырой JSON + время записи).
  /// Парсинг/merge с fallback — через [cachedWaveOptions].
  String get cachedOptionsJson => _optionsJson;
  int get cachedOptionsAtMs => _optionsAtMs;
  bool get isOptionsCacheFresh {
    if (_optionsJson.trim().isEmpty || _optionsAtMs <= 0) return false;
    final age =
        DateTime.now().millisecondsSinceEpoch - _optionsAtMs;
    return age < _kOptionsTtlHours * 3600 * 1000;
  }

  BrainWaveOptions get cachedWaveOptions {
    if (_optionsJson.trim().isEmpty) return BrainWaveOptions.fallback;
    try {
      final j = jsonDecode(_optionsJson);
      if (j is! Map<String, dynamic>) return BrainWaveOptions.fallback;
      final o = BrainWaveOptions.fromJson(j);
      return o.isEmpty ? BrainWaveOptions.fallback : o;
    } catch (_) {
      return BrainWaveOptions.fallback;
    }
  }

  /// Настройки волны для /api/wave/continue (пустые = не слать).
  /// activity/characteristic/language — кодами каталога (старые RU-пилюли
  /// нормализуются в коды, неизвестное уходит как есть — сервер без бонусов).
  Map<String, dynamic> get waveSettingsMap => {
        if (_waveActivity.trim().isNotEmpty) 'activity': _waveActivity.trim(),
        if (_waveCharacteristic.trim().isNotEmpty)
          'characteristic': _waveCharacteristic.trim(),
        if (_waveMood.trim().isNotEmpty) 'mood': _waveMood.trim(),
        if (_waveLanguage.trim().isNotEmpty) 'language': _waveLanguage.trim(),
        if (_languageStrict) 'language_strict': true,
      };

  /// Активен только когда тумблер ВКЛ + задан URL + задан userId.
  /// Токен опционален (если пуст — сервер без auth, доверенная LAN).
  bool get isActive => _enabled && _baseUrl.trim().isNotEmpty && _userId.trim().isNotEmpty;

  /// Ловушка docker-хоста: 'backend' резолвится только внутри compose-сети.
  /// С телефона это всегда ошибка — подсказываем LAN-IP.
  bool get isDockerHostname =>
      _baseUrl.contains('://backend') || _baseUrl.contains('://bridge');

  /// URL без завершающего слеша.
  String get normalizedBaseUrl {
    var u = _baseUrl.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _enabled = p.getBool(_kEnabled) ?? false;
    _baseUrl = p.getString(_kBaseUrl) ?? '';
    _apiToken = p.getString(_kToken) ?? '';
    _userId = p.getString(_kUserId) ?? '';
    _username = p.getString(_kUsername) ?? '';
    _waveEnabled = p.getBool(_kWaveEnabled) ?? false;
    _waveCount = p.getInt(_kWaveCount) ?? 10;
    _waveActivity = p.getString(_kWaveActivity) ?? '';
    _waveCharacteristic = p.getString(_kWaveCharacteristic) ?? '';
    _waveMood = p.getString(_kWaveMood) ?? '';
    _waveLanguage = p.getString(_kWaveLanguage) ?? '';
    _languageStrict = p.getBool(_kWaveLanguageStrict) ?? false;
    _optionsJson = p.getString(_kWaveOptionsJson) ?? '';
    _optionsAtMs = p.getInt(_kWaveOptionsAt) ?? 0;
    // Миграция старых RU-пилюль в коды каталога (ff5249d).
    _waveActivity = normalizeBrainActivity(_waveActivity);
    _waveCharacteristic = normalizeBrainCharacteristic(_waveCharacteristic);
    _waveMood = normalizeBrainMood(_waveMood);
    _waveLanguage = normalizeBrainLanguage(_waveLanguage);
    _loaded = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool v) async {
    _enabled = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, v);
    notifyListeners();
  }

  Future<void> setBaseUrl(String v) async {
    _baseUrl = v.trim();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kBaseUrl, _baseUrl);
    notifyListeners();
  }

  Future<void> setApiToken(String v) async {
    _apiToken = v.trim();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kToken, _apiToken);
    notifyListeners();
  }

  Future<void> setUser(String userId, String username) async {
    _userId = userId.trim();
    _username = username.trim();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kUserId, _userId);
    await p.setString(_kUsername, _username);
    notifyListeners();
  }

  Future<void> clearUser() async {
    _userId = '';
    _username = '';
    final p = await SharedPreferences.getInstance();
    await p.remove(_kUserId);
    await p.remove(_kUsername);
    notifyListeners();
  }

  Future<void> setWaveEnabled(bool v) async {
    _waveEnabled = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kWaveEnabled, v);
    notifyListeners();
  }

  Future<void> setWaveCount(int v) async {
    _waveCount = v.clamp(5, 30);
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kWaveCount, _waveCount);
    notifyListeners();
  }

  Future<void> setWaveFilters(
      {String? activity, String? characteristic, String? mood, String? language}) async {
    if (activity != null) {
      _waveActivity = normalizeBrainActivity(activity);
    }
    if (characteristic != null) {
      _waveCharacteristic = normalizeBrainCharacteristic(characteristic);
    }
    if (mood != null) _waveMood = normalizeBrainMood(mood);
    if (language != null) _waveLanguage = normalizeBrainLanguage(language);
    final p = await SharedPreferences.getInstance();
    await p.setString(_kWaveActivity, _waveActivity);
    await p.setString(_kWaveCharacteristic, _waveCharacteristic);
    await p.setString(_kWaveMood, _waveMood);
    await p.setString(_kWaveLanguage, _waveLanguage);
    notifyListeners();
  }

  Future<void> setLanguageStrict(bool v) async {
    _languageStrict = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kWaveLanguageStrict, v);
    notifyListeners();
  }

  /// Положить каталог /api/wave/options в кеш (сырой ответ сервера).
  Future<void> cacheWaveOptions(Map<String, dynamic> json) async {
    try {
      _optionsJson = jsonEncode(json);
    } catch (_) {
      return;
    }
    _optionsAtMs = DateTime.now().millisecondsSinceEpoch;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kWaveOptionsJson, _optionsJson);
    await p.setInt(_kWaveOptionsAt, _optionsAtMs);
    notifyListeners();
  }
}
