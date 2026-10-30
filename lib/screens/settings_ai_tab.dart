import 'dart:ui';
import 'package:flutter/material.dart';
import '../widgets/app_gradient_background.dart';
import 'package:flutter/cupertino.dart';
import '../services/ai_service.dart';
import '../theme/app_theme.dart';
import '../services/theme_service.dart';

class SettingsAiTab extends StatefulWidget {
  /// embedded=true — карточка внутри вкладки «Интеграции» (без собственного
  /// скролла, скроллит родитель).
  final bool embedded;
  const SettingsAiTab({super.key, this.embedded = false});

  @override
  State<SettingsAiTab> createState() => _SettingsAiTabState();
}

class _SettingsAiTabState extends State<SettingsAiTab> {
  final _ai = AiService();
  final _tokenCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _baseUrlCtrl = TextEditingController();
  bool _enabled = false;
  AiProvider _provider = AiProvider.ollama;
  bool _saving = false;
  String? _testResult;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _ai.initialize();
    _tokenCtrl.text = _ai.getToken();
    _modelCtrl.text = _ai.model;
    _baseUrlCtrl.text = _ai.getBaseUrl();
    setState(() {
      _enabled = _ai.enabled;
      _provider = _ai.provider;
    });
  }

  @override
  void dispose() {
    _tokenCtrl.dispose();
    _modelCtrl.dispose();
    _baseUrlCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await _ai.setProvider(_provider);
    await _ai.setModel(_modelCtrl.text.trim().isEmpty ? _provider.defaultModel : _modelCtrl.text.trim());
    await _ai.setToken(_tokenCtrl.text.trim());
    await _ai.setBaseUrl(_baseUrlCtrl.text.trim().isEmpty ? _provider.defaultBaseUrl : _baseUrlCtrl.text.trim());
    await _ai.setEnabled(_enabled);
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _test() async {
    await _save();
    setState(() => _testResult = 'Проверка...');
    final ok = await _ai.testConnection().timeout(const Duration(seconds: 16), onTimeout: () => false);
    if (!mounted) return;
    setState(() => _testResult = ok ? '✓ Успешно' : '✗ Ошибка — проверь токен/URL/модель');
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      shrinkWrap: widget.embedded,
      physics:
          widget.embedded ? const NeverScrollableScrollPhysics() : null,
      children: [
        _buildSection(title: 'ИИ МИКСЫ', children: [_buildEnabledTile()]),
        const SizedBox(height: 24),
        _buildSection(title: 'ПРОВАЙДЕР', children: [_buildProviderPicker()]),
        const SizedBox(height: 24),
        _buildSection(title: 'МОДЕЛЬ', children: [_buildModelField()]),
        const SizedBox(height: 24),
        _buildSection(title: 'ТОКЕН', children: [_buildTokenField()]),
        const SizedBox(height: 24),
        _buildSection(title: 'BASE URL', children: [_buildBaseUrlField()]),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_rounded),
                  label: const Text('Сохранить'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _test,
                  icon: const Icon(Icons.wifi_tethering_rounded),
                  label: const Text('Тест'),
                ),
              ),
            ],
          ),
        ),
        if (_testResult != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(_testResult!, style: TextStyle(color: _testResult!.startsWith('✓') ? Colors.green : Colors.red)),
          ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Ollama local: `ollama serve` → http://localhost:11434, модель llama3.1:8b, токен не нужен.\nOllama Cloud: Base URL https://ollama.com, вставь токен с https://ollama.com/settings/keys, модель gpt-oss:20b.\nOpenAI/Custom: токен sk-... и Base URL https://api.openai.com/v1',
            style: TextStyle(fontSize: 12, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText),
          ),
        ),
      ],
    );
  }

  Widget _buildSection({required String title, required List<Widget> children}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
      ),
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: _isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _isDark ? AppTheme.darkDivider : AppTheme.lightDivider, width: 0.5),
        ),
        child: Column(children: children),
      ),
    ]);
  }

  Widget _buildEnabledTile() {
    return SwitchListTile(
      title: const Text('Включить ИИ-названия'),
      subtitle: Text('Миксы получат креативные названия от нейросети', style: TextStyle(fontSize: 12, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
      value: _enabled,
      onChanged: (v) async { setState(() => _enabled = v); await _ai.setEnabled(v); },
    );
  }

  Widget _buildProviderPicker() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: DropdownButtonFormField<AiProvider>(
        value: _provider,
        decoration: const InputDecoration(labelText: 'Провайдер', border: OutlineInputBorder()),
        items: AiProvider.values.map((p) => DropdownMenuItem(value: p, child: Text(p.label))).toList(),
        onChanged: (v) { if (v != null) setState(() { _provider = v; _modelCtrl.text = v.defaultModel; _baseUrlCtrl.text = v.defaultBaseUrl; }); },
      ),
    );
  }

  static const _modelsByProvider = {
    AiProvider.ollama: ['llama3.1:8b', 'llama3.2:3b', 'llama3.1:70b', 'mistral:7b', 'gemma2:9b', 'qwen2.5:7b', 'deepseek-r1:8b', 'codellama:7b'],
    AiProvider.ollamaCloud: ['gpt-oss:20b', 'gpt-oss:120b', 'llama3.1:8b', 'llama3.3:70b', 'deepseek-v3', 'qwen2.5:72b', 'gemma2:27b'],
    AiProvider.openai: ['gpt-4o-mini', 'gpt-4o', 'gpt-4-turbo', 'gpt-3.5-turbo', 'o1-mini', 'o1-preview', 'o3-mini', 'gpt-4.1-mini'],
    AiProvider.anthropic: ['claude-3-5-sonnet-latest', 'claude-3-haiku-20240307', 'claude-3-opus-latest', 'claude-3-5-haiku-latest'],
    AiProvider.google: ['gemini-1.5-flash', 'gemini-1.5-pro', 'gemini-2.0-flash-exp', 'gemini-2.0-flash', 'gemini-pro'],
    AiProvider.custom: ['gpt-4o-mini', 'meta-llama/llama-3.1-8b-instruct:free', 'google/gemini-flash-1.5-8b:free', 'mistralai/mistral-7b-instruct:free', 'deepseek/deepseek-r1:free', 'qwen/qwen-2.5-72b-instruct:free', 'anthropic/claude-3-haiku:free', 'custom'],
  };

  bool _isCustomSelected = false;
  Widget _buildModelField() {
    final models = _modelsByProvider[_provider] ?? [_provider.defaultModel];
    final current = _modelCtrl.text.isEmpty ? _provider.defaultModel : _modelCtrl.text;
    final isCustom = _isCustomSelected || !models.contains(current);
    // Синхронизируем флаг при загрузке
    if (!models.contains(current) && !_isCustomSelected) {
      _isCustomSelected = true;
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          DropdownButtonFormField<String>(
            value: isCustom ? 'custom' : current,
            decoration: const InputDecoration(labelText: 'Модель', border: OutlineInputBorder()),
            items: [
              ...models.where((m) => m != 'custom').map((m) => DropdownMenuItem(value: m, child: Text(m))),
              const DropdownMenuItem(value: 'custom', child: Text('Своя...')),
            ],
            onChanged: (v) {
              if (v == null) return;
              if (v == 'custom') {
                setState(() {
                  _isCustomSelected = true;
                  // не трогаем текст, показываем поле
                  if (models.contains(_modelCtrl.text)) _modelCtrl.text = '';
                });
              } else {
                setState(() {
                  _isCustomSelected = false;
                  _modelCtrl.text = v;
                });
              }
            },
          ),
          if (isCustom) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _modelCtrl,
              autofocus: _modelCtrl.text.isEmpty,
              decoration: InputDecoration(
                labelText: 'Своя модель',
                hintText: _provider == AiProvider.custom ? 'openai/gpt-4o-mini или meta-llama/...:free' : 'my-model:7b',
                border: const OutlineInputBorder(),
                helperText: _provider == AiProvider.custom ? 'Для OpenRouter/бесплатных: полный ID с / и :free' : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTokenField() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: TextField(
        controller: _tokenCtrl,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'Токен / API Key', hintText: 'sk-... или ollama не нужен', border: OutlineInputBorder()),
      ),
    );
  }

  Widget _buildBaseUrlField() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: TextField(
        controller: _baseUrlCtrl,
        decoration: InputDecoration(labelText: 'Base URL', hintText: _provider.defaultBaseUrl, border: const OutlineInputBorder()),
      ),
    );
  }
}
