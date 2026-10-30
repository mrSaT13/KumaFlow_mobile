import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';

enum AiProvider { ollama, ollamaCloud, openai, anthropic, google, custom }

extension AiProviderX on AiProvider {
  String get label {
    switch (this) {
      case AiProvider.ollama:
        return 'Ollama (local)';
      case AiProvider.ollamaCloud:
        return 'Ollama Cloud';
      case AiProvider.openai:
        return 'OpenAI';
      case AiProvider.anthropic:
        return 'Anthropic';
      case AiProvider.google:
        return 'Google Gemini';
      case AiProvider.custom:
        return 'Custom (OpenAI-compat)';
    }
  }

  String get defaultModel {
    switch (this) {
      case AiProvider.ollama:
        return 'llama3.1:8b';
      case AiProvider.ollamaCloud:
        return 'gpt-oss:20b';
      case AiProvider.openai:
        return 'gpt-4o-mini';
      case AiProvider.anthropic:
        return 'claude-3-5-sonnet-latest';
      case AiProvider.google:
        return 'gemini-1.5-flash';
      case AiProvider.custom:
        return 'gpt-4o-mini';
    }
  }

  String get defaultBaseUrl {
    switch (this) {
      case AiProvider.ollama:
        return 'http://localhost:11434';
      case AiProvider.ollamaCloud:
        return 'https://ollama.com';
      case AiProvider.openai:
        return 'https://api.openai.com/v1';
      case AiProvider.anthropic:
        return 'https://api.anthropic.com';
      case AiProvider.google:
        return 'https://generativelanguage.googleapis.com';
      case AiProvider.custom:
        return '';
    }
  }
}

class AiService {
  static const _kProvider = 'ai_provider';
  static const _kModel = 'ai_model';
  static const _kToken = 'ai_token';
  static const _kBaseUrl = 'ai_base_url';
  static const _kEnabled = 'ai_enabled';

  static final AiService _instance = AiService._internal();
  factory AiService() => _instance;
  AiService._internal();

  final ValueNotifier<AiProvider> providerNotifier = ValueNotifier(AiProvider.ollama);
  final ValueNotifier<String> modelNotifier = ValueNotifier('llama3.1:8b');
  final ValueNotifier<bool> enabledNotifier = ValueNotifier(false);

  SharedPreferences? _prefs;

  AiProvider get provider => providerNotifier.value;
  String get model => modelNotifier.value;
  bool get enabled => enabledNotifier.value;

  Future<void> initialize() async {
    _prefs ??= await SharedPreferences.getInstance();
    final p = _prefs!.getString(_kProvider);
    if (p != null) {
      providerNotifier.value = AiProvider.values.firstWhere(
        (e) => e.name == p,
        orElse: () => AiProvider.ollama,
      );
    }
    modelNotifier.value = _prefs!.getString(_kModel) ?? providerNotifier.value.defaultModel;
    enabledNotifier.value = _prefs!.getBool(_kEnabled) ?? false;
  }

  Future<void> setProvider(AiProvider p) async {
    await initialize();
    await _prefs!.setString(_kProvider, p.name);
    providerNotifier.value = p;
    // Reset model to default if not custom
    if ((_prefs!.getString(_kModel) ?? '').isEmpty) {
      await setModel(p.defaultModel);
    }
  }

  Future<void> setModel(String m) async {
    await initialize();
    await _prefs!.setString(_kModel, m);
    modelNotifier.value = m;
  }

  Future<void> setToken(String t) async {
    await initialize();
    await _prefs!.setString(_kToken, t);
  }

  String getToken() => _prefs?.getString(_kToken) ?? '';

  Future<void> setBaseUrl(String url) async {
    await initialize();
    await _prefs!.setString(_kBaseUrl, url);
  }

  String getBaseUrl() => _prefs?.getString(_kBaseUrl) ?? providerNotifier.value.defaultBaseUrl;

  Future<void> setEnabled(bool v) async {
    await initialize();
    await _prefs!.setBool(_kEnabled, v);
    enabledNotifier.value = v;
  }

  bool get isConfigured {
    if (!enabled) return false;
    if (provider == AiProvider.ollama) return getBaseUrl().isNotEmpty;
    if (provider == AiProvider.ollamaCloud) return getToken().isNotEmpty && getBaseUrl().isNotEmpty;
    return getToken().isNotEmpty;
  }

  String get unconfiguredReason {
    if (!enabled) return 'ИИ выключен в настройках (Настройки → ИИ → Включить ИИ-названия)';
    if (provider == AiProvider.ollama && getBaseUrl().isEmpty) return 'Ollama: пустой Base URL (должен быть http://localhost:11434 или https://ollama.com)';
    if (provider == AiProvider.ollamaCloud && getToken().isEmpty) return 'Ollama Cloud: нет токена (Настройки → ИИ → Токен с ollama.com/settings/keys)';
    if (provider == AiProvider.ollamaCloud && getBaseUrl().isEmpty) return 'Ollama Cloud: пустой Base URL';
    if (getToken().isEmpty) return '${provider.label}: нет API-ключа/токена';
    if (getBaseUrl().isEmpty && provider == AiProvider.custom) return 'Custom: пустой Base URL (например https://api.openrouter.ai/api/v1)';
    return 'Неизвестная причина';
  }

  /// Generate a creative playlist/mix name from a list of songs.
  /// Falls back to a deterministic name if AI is not configured or fails.
  Future<String> generateMixName(List<Song> songs, {String hint = 'mix', String locale = 'en'}) async {
    if (!isConfigured || songs.isEmpty) return _fallbackName(songs, hint, locale);
    try {
      final prompt = _buildPrompt(songs, hint, locale);
      final name = await _callAi(prompt);
      if (name.trim().isEmpty) return _fallbackName(songs, hint);
      // Clean up quotes / newlines
      var clean = name.trim().replaceAll(RegExp(r'^["\x27]+|["\x27]+$'), '').split('\n').first.trim();
      if (clean.length > 40) clean = clean.substring(0, 40);
      return clean;
    } catch (e) {
      final msg = e.toString();
      debugPrint('AI mix name failed: ${msg.length > 120 ? msg.substring(0,120) : msg}');
      return _fallbackName(songs, hint);
    }
  }

  String _fallbackName(List<Song> songs, String hint, [String locale = 'en']) {
    // Simple deterministic fallback: use top genre/artist, in UI locale.
    final genre = songs.first.genre ?? hint;
    final artist = songs.first.artist ?? '';
    final isRu = locale.toLowerCase().startsWith('ru');
    if (artist.contains('/')) {
      final a = artist.split('/').first.trim();
      return isRu ? 'Микс: $a' : '$a Mix';
    }
    if (genre.isNotEmpty) {
      final g = '${genre[0].toUpperCase()}${genre.substring(1)}';
      return isRu ? 'Микс: $g' : '$g Mix';
    }
    if (hint.isNotEmpty) return '${hint[0].toUpperCase()}${hint.substring(1)}';
    return isRu ? 'Мой микс' : 'My Mix';
  }

  String _buildPrompt(List<Song> songs, String hint, [String locale = 'en']) {
    final sample = songs.take(10).map((s) => '${s.title} — ${s.artist ?? "Unknown"} (${s.genre ?? "unknown"})').join(', ');
    if (locale.toLowerCase().startsWith('ru')) {
      return 'Ты придумываешь названия плейлистов. Треки: $sample. '
          'Подсказка: $hint. Ответь ТОЛЬКО коротким названием плейлиста на русском (2-3 слова, без кавычек и пояснений).';
    }
    return 'You are a music playlist namer. Given these tracks: $sample. '
        'Hint: $hint. Reply with ONLY a short creative playlist title (2-3 words, no quotes, no explanation).';
  }

  /// Универсальный chat вызов с настраиваемым maxTokens/temperature для AI миксов
  Future<String> generateText(String prompt, {int maxTokens = 400, double temperature = 0.7, Duration timeout = const Duration(seconds: 30)}) async {
    if (!isConfigured) throw Exception('AI not configured');
    return _callAi(prompt, maxTokens: maxTokens, temperature: temperature, timeout: timeout);
  }

  Future<String> _callAi(String prompt, {int maxTokens = 20, double temperature = 0.8, Duration timeout = const Duration(seconds: 15)}) async {
    final token = getToken();
    final baseUrl = getBaseUrl();
    final m = model.isEmpty ? provider.defaultModel : model;

    switch (provider) {
      case AiProvider.ollama:
      case AiProvider.ollamaCloud:
        // Try Ollama chat endpoint first (works for both local and cloud), fallback to generate
        final isCloud = provider == AiProvider.ollamaCloud;
        final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
        // Normalize cloud base: if user entered https://ollama.com, API is at same host /api/chat
        // Some cloud deployments use https://api.ollama.ai — handle both
        final chatUrl = Uri.parse('$base/api/chat');
        final headers = <String, String>{'Content-Type': 'application/json'};
        final ollamaToken = token.trim();
        if (ollamaToken.isNotEmpty) headers['Authorization'] = 'Bearer $ollamaToken';
        try {
          final resp = await http.post(chatUrl,
              headers: headers,
              body: jsonEncode({
                'model': m,
                'messages': [
                  {'role': 'user', 'content': prompt}
                ],
                'stream': false,
                'options': {'temperature': temperature, 'num_predict': maxTokens}
              })).timeout(timeout);
          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body) as Map<String, dynamic>;
            final msg = data['message'] as Map<String, dynamic>?;
            if (msg != null && msg['content'] is String) return msg['content'] as String;
            if (data['response'] is String) return data['response'] as String;
          }
          if (resp.statusCode == 401) throw Exception('Ollama 401 Unauthorized - check token/baseUrl');
          if (isCloud && resp.statusCode != 200) throw Exception('Ollama Cloud ${resp.statusCode}: ${resp.body}');
          // Fallback to /api/generate for local ollama if chat failed non-401
          if (!isCloud) {
            final genUrl = Uri.parse('$base/api/generate');
            final genResp = await http.post(genUrl,
                headers: headers,
                body: jsonEncode({'model': m, 'prompt': prompt, 'stream': false, 'options': {'temperature': temperature, 'num_predict': maxTokens}})).timeout(timeout);
            if (genResp.statusCode == 401) throw Exception('Ollama 401 Unauthorized - check token/baseUrl');
            if (genResp.statusCode != 200) throw Exception('Ollama ${genResp.statusCode}: ${genResp.body}');
            final data = jsonDecode(genResp.body) as Map<String, dynamic>;
            return (data['response'] as String?) ?? '';
          }
          throw Exception('Ollama Cloud ${resp.statusCode}: ${resp.body}');
        } catch (e) {
          if (e.toString().contains('401') || e.toString().contains('Ollama Cloud')) rethrow;
          // last resort: try generate
          if (!isCloud) {
            final genUrl = Uri.parse('$base/api/generate');
            final genResp = await http.post(genUrl,
                headers: headers,
                body: jsonEncode({'model': m, 'prompt': prompt, 'stream': false})).timeout(timeout);
            if (genResp.statusCode != 200) throw Exception('Ollama ${genResp.statusCode}: ${genResp.body}');
            final data = jsonDecode(genResp.body) as Map<String, dynamic>;
            return (data['response'] as String?) ?? '';
          }
          rethrow;
        }

      case AiProvider.openai:
      case AiProvider.custom:
        final url = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions');
        final resp = await http.post(url,
            headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
            body: jsonEncode({
              'model': m,
              'messages': [
                {'role': 'user', 'content': prompt}
              ],
              'max_tokens': maxTokens,
              'temperature': temperature
            })).timeout(timeout);
        if (resp.statusCode != 200) throw Exception('OpenAI ${resp.statusCode}: ${resp.body}');
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        return (data['choices']?[0]?['message']?['content'] as String?) ?? '';

      case AiProvider.anthropic:
        final url = Uri.parse('https://api.anthropic.com/v1/messages');
        final resp = await http.post(url,
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': token,
              'anthropic-version': '2023-06-01'
            },
            body: jsonEncode({
              'model': m,
              'max_tokens': maxTokens,
              'messages': [
                {'role': 'user', 'content': prompt}
              ]
            })).timeout(timeout);
        if (resp.statusCode != 200) throw Exception('Anthropic ${resp.statusCode}: ${resp.body}');
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final content = data['content'] as List?;
        return (content?.first?['text'] as String?) ?? '';

      case AiProvider.google:
        final url = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$m:generateContent?key=$token');
        final resp = await http.post(url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'contents': [
                {
                  'parts': [
                    {'text': prompt}
                  ]
                }
              ],
              'generationConfig': {'maxOutputTokens': maxTokens, 'temperature': temperature}
            })).timeout(timeout);
        if (resp.statusCode != 200) throw Exception('Gemini ${resp.statusCode}: ${resp.body}');
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        return (data['candidates']?[0]?['content']?['parts']?[0]?['text'] as String?) ?? '';
    }
  }

  /// Классификация настроения по лирике — используется LyricsMoodService.
  Future<String> classifyMood(String prompt) async {
    if (!isConfigured) throw Exception('AI not configured');
    return _callAi(prompt);
  }

  Future<bool> testConnection() async {
    try {
      await generateMixName([Song(id: 'test', title: 'Test Track', album: 'Test', artist: 'Test Artist', genre: 'Pop', duration: 180)], hint: 'test');
      return true;
    } catch (_) {
      return false;
    }
  }
}


