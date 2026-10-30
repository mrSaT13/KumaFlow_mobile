import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/theme_service.dart';
import '../widgets/app_gradient_background.dart';

import '../l10n/app_localizations.dart';
import '../services/equalizer_service.dart';

class EqualizerScreen extends StatelessWidget {
  const EqualizerScreen({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const EqualizerScreen(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: context.read<EqualizerService>(),
      child: const _EqualizerContent(),
    );
  }
}

class _EqualizerContent extends StatefulWidget {
  const _EqualizerContent();

  @override
  State<_EqualizerContent> createState() => _EqualizerContentState();
}

class _EqualizerContentState extends State<_EqualizerContent> {
  final TextEditingController _presetNameController = TextEditingController();

  @override
  void dispose() {
    _presetNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final eq = context.watch<EqualizerService>();
    // Акцент из темы (перекраска на лету), вместо зашитого красного.
    final accent = context.watch<ThemeService>().accentColor.color;
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: Color(0xFF0A0A0A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          _buildDragHandle(),
          _buildHeader(eq, accent),
          if (!eq.engineSupported) _buildEngineNote(),
          const SizedBox(height: 8),
          _buildPresetChips(eq, accent),
          const SizedBox(height: 16),
          Expanded(child: _buildSliders(eq, accent)),
          _buildFooter(eq, bottomPadding, accent),
        ],
      ),
    );
  }

  /// Честный хинт: системный эквалайзер доступен только на Android.
  /// На остальных платформах ползунки сохраняются, но звук не меняют.
  Widget _buildEngineNote() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          children: [
            Icon(Icons.info_outline_rounded, color: Colors.orange, size: 16),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Системный эквалайзер недоступен на этом устройстве — ползунки звук не меняют',
                style: TextStyle(color: Colors.orange, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDragHandle() {    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Container(
        width: 36,
        height: 5,
        decoration: BoxDecoration(
          color: Colors.grey[700],
          borderRadius: BorderRadius.circular(2.5),
        ),
      ),
    );
  }

  Widget _buildHeader(EqualizerService eq, Color accent) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Row(
        children: [
          Icon(Icons.graphic_eq_rounded, color: accent, size: 24),
          const SizedBox(width: 10),
          const Text(
            'Эквалайзер',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          Row(
            children: [
              const Text('ВКЛ', style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(width: 6),
              Switch(
                value: eq.enabled,
                onChanged: (_) => eq.toggleEnabled(),
                activeColor: accent,
                activeTrackColor: accent.withAlpha(80),
                inactiveThumbColor: Colors.grey[600],
                inactiveTrackColor: Colors.grey[800],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPresetChips(EqualizerService eq, Color accent) {
    final allPresets = eq.allPresets;
    final presetNames = [
      ...EqualizerService.builtInPresets.keys,
      ...eq.customPresetsList.map((p) => p.name),
    ];

    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: presetNames.length + 1, // +1 for save button
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index == presetNames.length) {
            return _buildSavePresetChip(eq, accent);
          }
          final name = presetNames[index];
          final isActive = eq.currentPresetName == name;
          final isCustom = !EqualizerService.builtInPresets.containsKey(name);

          return GestureDetector(
            onLongPress: isCustom ? () => _confirmDeletePreset(eq, name) : null,
            child: FilterChip(
              label: Text(name),
              labelStyle: TextStyle(
                color: isActive ? Colors.white : Colors.grey[400],
                fontSize: 13,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              ),
              selected: isActive,
              selectedColor: accent,
              backgroundColor: const Color(0xFF1A1A1A),
              side: BorderSide(
                color: isActive ? accent : Colors.grey[800]!,
              ),
              checkmarkColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              visualDensity: VisualDensity.compact,
              onSelected: (_) => eq.selectPreset(name),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSavePresetChip(EqualizerService eq, Color accent) {
    return ActionChip(
      avatar: Icon(Icons.add, color: accent, size: 18),
      label: Text('Сохранить', style: TextStyle(color: accent, fontSize: 13)),
      backgroundColor: const Color(0xFF1A1A1A),
      side: BorderSide(color: accent, width: 1),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      visualDensity: VisualDensity.compact,
      onPressed: () => _showSavePresetDialog(eq, accent),
    );
  }

  Widget _buildSliders(EqualizerService eq, Color accent) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: List.generate(10, (i) => Expanded(child: _buildBandSlider(eq, i, accent))),
      ),
    );
  }

  Widget _buildBandSlider(EqualizerService eq, int index, Color accent) {
    final value = eq.bands[index];
    final label = EqualizerService.bandLabels[index];
    final normalized = (value - EqualizerService.minDb) /
        (EqualizerService.maxDb - EqualizerService.minDb);

    return Column(
      children: [
        Text(
          '${value.toStringAsFixed(1)}',
          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: RotatedBox(
            quarterTurns: -1,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: accent,
                inactiveTrackColor: const Color(0xFF1A1A1A),
                thumbColor: accent,
                overlayColor: accent.withAlpha(40),
                tickMarkShape: const RoundSliderTickMarkShape(),
              ),
              child: Slider(
                min: EqualizerService.minDb,
                max: EqualizerService.maxDb,
                value: value,
                onChanged: eq.enabled ? (v) => eq.setBand(index, v) : null,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: eq.enabled ? Colors.white70 : Colors.grey[600],
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildFooter(EqualizerService eq, double bottomPadding, Color accent) {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 12 + bottomPadding),
      decoration: const BoxDecoration(
        color: Color(0xFF0A0A0A),
        border: Border(top: BorderSide(color: Color(0xFF1A1A1A), width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: eq.resetToFlat,
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('Сбросить'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.grey[400],
                side: BorderSide(color: Colors.grey[700]!),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Готово'),
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showSavePresetDialog(EqualizerService eq, Color accent) {
    _presetNameController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(AppLocalizations.of(ctx)!.savePreset, style: const TextStyle(color: Colors.white)),
        content: TextField(
          controller: _presetNameController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: AppLocalizations.of(ctx)!.presetNameHint,
            hintStyle: TextStyle(color: Colors.grey[600]),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.grey[700]!),
            ),
            focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFFE8192C)),
            ),
          ),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppLocalizations.of(ctx)!.cancel, style: TextStyle(color: Colors.grey[400])),
          ),
          FilledButton(
            onPressed: () {
              final name = _presetNameController.text.trim();
              if (name.isNotEmpty) {
                eq.saveCustomPreset(name);
                Navigator.pop(ctx);
              }
            },
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE8192C)),
            child: Text(AppLocalizations.of(ctx)!.save),
          ),
        ],
      ),
    );
  }

  void _confirmDeletePreset(EqualizerService eq, String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(AppLocalizations.of(ctx)!.deletePresetConfirm(name), style: const TextStyle(color: Colors.white)),
        content: Text(
          AppLocalizations.of(ctx)!.presetPermanentlyRemoved,
          style: TextStyle(color: Colors.grey[400]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppLocalizations.of(ctx)!.cancel, style: TextStyle(color: Colors.grey[400])),
          ),
          FilledButton(
            onPressed: () {
              eq.deleteCustomPreset(name);
              Navigator.pop(ctx);
            },
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE8192C)),
            child: Text(AppLocalizations.of(ctx)!.delete),
          ),
        ],
      ),
    );
  }
}
