import 'package:flutter/material.dart';
import 'kumaflow_brain_section.dart';
import 'settings_music_auth_tab.dart';
import 'settings_ai_tab.dart';
import 'yandex_music_section.dart';

/// Вкладка «Интеграции»: всё внешнее в одном месте —
/// KumaFlow Brain, музыкальные сервисы (Яндекс/MTS), Яндекс-интеграция
/// публичного API и облачный ИИ. Раньше было размазано по трём вкладкам
/// (ML, Музыка, ИИ) + дубль Яндекса в Playback.
class SettingsIntegrationsTab extends StatelessWidget {
  const SettingsIntegrationsTab({super.key});

  bool _isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  Widget _header(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFF4E8CA8),
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _header(context, 'KUMAFLOW BRAIN'),
        KumaFlowBrainSection(isDark: isDark),
        const SizedBox(height: 24),
        _header(context, 'МУЗЫКАЛЬНЫЕ СЕРВИСЫ'),
        const SettingsMusicAuthTab(embedded: true),
        const SizedBox(height: 24),
        _header(context, 'ЯНДЕКС-ИНТЕГРАЦИЯ (API)'),
        const YandexMusicSection(),
        const SizedBox(height: 24),
        _header(context, 'ОБЛАЧНЫЙ ИИ'),
        const SettingsAiTab(embedded: true),
        const SizedBox(height: 40),
      ],
    );
  }
}
