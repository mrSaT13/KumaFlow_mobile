import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../services/theme_service.dart';
import '../widgets/app_gradient_background.dart';
import '../l10n/app_localizations.dart';
import '../providers/player_provider.dart';
import '../services/recommendation_service.dart';
import '../services/remote_control/remote_client.dart';
import '../services/remote_control/remote_discovery.dart';
import '../services/replay_gain_service.dart';
import '../services/auto_dj_service.dart';
import '../services/transcoding_service.dart';
import '../services/storage_service.dart';
import '../services/fade_settings_service.dart';
import '../services/bpm_crossfade_service.dart';
import '../theme/app_theme.dart';
import 'remote_control_screen.dart';
import 'settings_screen.dart';

class SettingsPlaybackTab extends StatefulWidget {
  const SettingsPlaybackTab({super.key});

  @override
  State<SettingsPlaybackTab> createState() => _SettingsPlaybackTabState();
}

class _SettingsPlaybackTabState extends State<SettingsPlaybackTab> {
  final _replayGainService = ReplayGainService();
  final _fadeSettingsService = FadeSettingsService();

  ReplayGainMode _replayGainMode = ReplayGainMode.off;
  double _replayGainPreamp = 0.0;
  bool _replayGainPreventClipping = true;
  double _replayGainFallback = -6.0;
  bool _lrcLibFallback = true;
  bool _preferSyncedLyrics = true;
  AutoDjMode _autoDjMode = AutoDjMode.off;
  int _autoDjSongsToAdd = 5;
  int _autoDjThreshold = 2;
  bool _fadeEnabled = false;
  int _fadeDurationMs = 300;
  CrossfadeEasing _crossfadeEasing = CrossfadeEasing.easeInOut;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
    await _replayGainService.initialize();
    await _fadeSettingsService.initialize();

    final storageService = StorageService();
    final lrcLibFallback = await storageService.getLrcLibFallback();
    final preferSynced = await storageService.getPreferSyncedLyrics();
    await BpmCrossfadeService().initialize();
    final easing = BpmCrossfadeService().easing;
    setState(() {
      _replayGainMode = _replayGainService.getMode();
      _replayGainPreamp = _replayGainService.getPreampGain();
      _replayGainPreventClipping = _replayGainService.getPreventClipping();
      _replayGainFallback = _replayGainService.getFallbackGain();
      _lrcLibFallback = lrcLibFallback;
      _preferSyncedLyrics = preferSynced;
      _autoDjMode = playerProvider.autoDjService.mode;
      _autoDjSongsToAdd = playerProvider.autoDjService.songsToAdd;
      _autoDjThreshold = playerProvider.autoDjService.triggerThreshold;
      _fadeEnabled = _fadeSettingsService.getFadeEnabled();
      _fadeDurationMs = _fadeSettingsService.getFadeDurationMs();
      _crossfadeEasing = easing;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        _buildRemoteSection(),
        const SizedBox(height: 24),
        _buildSection(
          title: AppLocalizations.of(context)!.sectionAutoDj,
          children: [
            _buildAutoDjModeSelector(),
            if (_autoDjMode != AutoDjMode.off) ...[
              _buildDivider(),
              _buildAutoDjSongsSlider(),
              _buildDivider(),
              _buildAutoDjThresholdSlider(),
              _buildDivider(),
              _buildAutoDjInfoTile(),
            ],
            _buildDivider(),
            _buildAudiobookAutoDjToggle(),
          ],
        ),
        const SizedBox(height: 24),
        _buildGaplessSection(),
        const SizedBox(height: 24),
        _buildFadeSection(),
        const SizedBox(height: 24),
        _buildBpmCrossfadeSection(),
        const SizedBox(height: 24),
        _buildLrcLibSection(),
        const SizedBox(height: 24),
        _buildRecommendationsSection(),
        const SizedBox(height: 24),
        _buildYandexMusicSection(),
        const SizedBox(height: 24),
        _buildSection(
          title: AppLocalizations.of(context)!.sectionVolumeNormalization,
          children: [
            _buildReplayGainModeSelector(),
            if (_replayGainMode != ReplayGainMode.off) ...[
              _buildDivider(),
              _buildReplayGainPreampSlider(),
              _buildDivider(),
              _buildReplayGainClippingToggle(),
              _buildDivider(),
              _buildReplayGainFallbackSlider(),
            ],
          ],
        ),
        const SizedBox(height: 24),
        _buildTranscodingSection(),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildSection({
    required String title,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: _isDark
                  ? AppTheme.darkSecondaryText
                  : AppTheme.lightSecondaryText,
              letterSpacing: 0.2,
            ),
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: _isDark ? AppTheme.darkSurface : Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Column(children: children),
          ),
        ),
      ],
    );
  }

  Widget _buildDivider() {
    return Padding(
      padding: const EdgeInsets.only(left: 56),
      child: Container(
        height: 0.5,
        color: _isDark ? AppTheme.darkDivider : AppTheme.lightDivider,
      ),
    );
  }

  /// Пульт: десктоп KumaFlow в LAN (WebSocket 4334 + PIN).
  Widget _buildRemoteSection() {
    return Consumer2<RemoteDiscovery, RemoteClient>(
      builder: (context, discovery, client, _) {
        final n = discovery.found.length + discovery.saved.length;
        final subtitle = client.isConnected
            ? 'Подключено: ${client.device?.name ?? ''}'
            : (n > 0
                ? 'Устройств рядом: $n — открыть пульт'
                : 'ПК в одной Wi-Fi сети — найти и управлять');
        return _buildSection(
          title: 'Пульт · ПК в сети',
          children: [
            ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              leading: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF4E8CA8), Color(0xFF2E5A74)],
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(CupertinoIcons.desktopcomputer,
                    color: Colors.white, size: 18),
              ),
              title: const Text('Управлять ПК',
                  style: TextStyle(fontSize: 16)),
              subtitle: Text(subtitle,
                  style: TextStyle(
                      fontSize: 13,
                      color: _isDark
                          ? AppTheme.darkSecondaryText
                          : AppTheme.lightSecondaryText)),
              trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const RemoteControlScreen()),
                );
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildAutoDjModeSelector() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFFF2D55), Color(0xFFFF6B6B)],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          CupertinoIcons.wand_stars,
          color: Colors.white,
          size: 18,
        ),
      ),
      title: Text(
        AppLocalizations.of(context)!.autoDjMode,
        style: const TextStyle(fontSize: 16),
      ),
      trailing: DropdownButton<AutoDjMode>(
        value: _autoDjMode,
        underline: const SizedBox(),
        items: AutoDjMode.values.map((mode) {
          return DropdownMenuItem(
            value: mode,
            child: Text(_getAutoDjModeLabel(mode)),
          );
        }).toList(),
        onChanged: (value) {
          if (value != null) _setAutoDjMode(value);
        },
      ),
    );
  }

  String _getAutoDjModeLabel(AutoDjMode mode) {
    final l10n = AppLocalizations.of(context)!;
    switch (mode) {
      case AutoDjMode.flowEveryOther:
        return l10n.autoDjFlowEveryOther;
      case AutoDjMode.flowDouble:
        return l10n.autoDjFlowDouble;
      case AutoDjMode.flowArtist:
        return l10n.autoDjFlowArtist;
      case AutoDjMode.flowEra:
        return l10n.autoDjFlowEra;
      default:
        return AutoDjService.getModeDisplayName(mode);
    }
  }

  void _setAutoDjMode(AutoDjMode mode) {
    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
    playerProvider.autoDjService.setMode(mode);
    setState(() => _autoDjMode = mode);
  }

  Widget _buildAutoDjSongsSlider() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF5856D6), Color(0xFF7B68EE)],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          CupertinoIcons.music_note_list,
          color: Colors.white,
          size: 18,
        ),
      ),
      title: Text(
        AppLocalizations.of(context)!.autoDjSongsToAdd(_autoDjSongsToAdd),
        style: const TextStyle(fontSize: 16),
      ),
      subtitle: Slider(
        value: _autoDjSongsToAdd.toDouble(),
        min: 1,
        max: 20,
        divisions: 19,
        activeColor: Theme.of(context).colorScheme.primary,
        onChanged: (value) {
          final count = value.round();
          final playerProvider = Provider.of<PlayerProvider>(
            context,
            listen: false,
          );
          playerProvider.autoDjService.setSongsToAdd(count);
          setState(() => _autoDjSongsToAdd = count);
        },
      ),
    );
  }

  Widget _buildAutoDjThresholdSlider() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32, height: 32,
        decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF007AFF), Color(0xFF34C759)]), borderRadius: BorderRadius.circular(8)),
        child: const Icon(CupertinoIcons.arrow_right_arrow_left, color: Colors.white, size: 18),
      ),
      title: Text('Порог срабатывания: $_autoDjThreshold треков до конца', style: const TextStyle(fontSize: 16)),
      subtitle: Slider(
        value: _autoDjThreshold.toDouble(), min: 1, max: 5, divisions: 4,
        activeColor: Theme.of(context).colorScheme.primary,
        label: '$_autoDjThreshold',
        onChanged: (v) {
          final th = v.round();
          Provider.of<PlayerProvider>(context, listen: false).autoDjService.setTriggerThreshold(th);
          setState(() => _autoDjThreshold = th);
        },
      ),
    );
  }

  Widget _buildAutoDjInfoTile() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('SmartAutoDJ 2.0: vibe 60% фильтр, GENRE_BRIDGES +0.12, anniversary +0.15, ≤2/артиста', style: TextStyle(fontSize: 12, color: _isDark ? Colors.white54 : Colors.black54)),
        const SizedBox(height: 4),
        Text('ML Powered также учитывает твой MAB (час/дня недели)', style: TextStyle(fontSize: 11, color: _isDark ? Colors.white38 : Colors.black38)),
      ]),
    );
  }

  Widget _buildAudiobookAutoDjToggle() {
    final autoDj = AutoDjService();
    return ListenableBuilder(
      listenable: autoDj,
      builder: (context, _) {
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              autoDj.audiobookEnabled ? Icons.queue_music_rounded : Icons.stop_circle_outlined,
              color: autoDj.audiobookEnabled ? Theme.of(context).colorScheme.primary : Colors.grey,
              size: 18,
            ),
          ),
          title: const Text('Автодиджей для аудиокниг', style: TextStyle(fontSize: 16)),
          subtitle: Text(
            autoDj.audiobookEnabled ? 'После книги добавится музыка' : 'Книга закончится — плеер остановится (по умолчанию)',
            style: TextStyle(fontSize: 13, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText),
          ),
          trailing: CupertinoSwitch(
            value: autoDj.audiobookEnabled,
            activeTrackColor: Theme.of(context).colorScheme.primary,
            onChanged: (v) => autoDj.setAudiobookEnabled(v),
          ),
        );
      },
    );
  }

  Widget _buildReplayGainModeSelector() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF34C759), Color(0xFF30D158)],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          CupertinoIcons.speaker_2,
          color: Colors.white,
          size: 18,
        ),
      ),
      title: Text(AppLocalizations.of(context)!.replayGainMode,
          style: const TextStyle(fontSize: 16)),
      trailing: DropdownButton<ReplayGainMode>(
        value: _replayGainMode,
        underline: const SizedBox(),
        items: ReplayGainMode.values.map((mode) {
          return DropdownMenuItem(
            value: mode,
            child: Text(_getReplayGainModeLabel(mode)),
          );
        }).toList(),
        onChanged: (value) {
          if (value != null) _setReplayGainMode(value);
        },
      ),
    );
  }

  String _getReplayGainModeLabel(ReplayGainMode mode) {
    final l10n = AppLocalizations.of(context)!;
    switch (mode) {
      case ReplayGainMode.off:
        return l10n.replayGainModeOff;
      case ReplayGainMode.track:
        return l10n.replayGainModeTrack;
      case ReplayGainMode.album:
        return l10n.replayGainModeAlbum;
    }
  }

  void _setReplayGainMode(ReplayGainMode mode) async {
    await _replayGainService.setMode(mode);
    setState(() => _replayGainMode = mode);
  }

  Widget _buildReplayGainPreampSlider() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Text(AppLocalizations.of(context)!
          .replayGainPreamp(_replayGainPreamp.toStringAsFixed(1))),
      subtitle: Slider(
        value: _replayGainPreamp,
        min: -12,
        max: 12,
        divisions: 24,
        activeColor: Theme.of(context).colorScheme.primary,
        onChanged: (value) async {
          await _replayGainService.setPreampGain(value);
          setState(() => _replayGainPreamp = value);
        },
      ),
    );
  }

  Widget _buildReplayGainClippingToggle() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Text(AppLocalizations.of(context)!.replayGainPreventClipping),
      trailing: CupertinoSwitch(
        value: _replayGainPreventClipping,
        activeTrackColor: Theme.of(context).colorScheme.primary,
        onChanged: (value) async {
          await _replayGainService.setPreventClipping(value);
          setState(() => _replayGainPreventClipping = value);
        },
      ),
    );
  }

  Widget _buildReplayGainFallbackSlider() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Text(
        AppLocalizations.of(context)!
            .replayGainFallbackGain(_replayGainFallback.toStringAsFixed(1)),
      ),
      subtitle: Slider(
        value: _replayGainFallback,
        min: -12,
        max: 0,
        divisions: 12,
        activeColor: Theme.of(context).colorScheme.primary,
        onChanged: (value) async {
          await _replayGainService.setFallbackGain(value);
          setState(() => _replayGainFallback = value);
        },
      ),
    );
  }

  Widget _buildLrcLibSection() {
    final accent = Theme.of(context).colorScheme.primary;
    return _buildSection(
      title: 'Lyrics',
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [accent, accent.withValues(alpha: 0.6)],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              CupertinoIcons.text_quote,
              color: Colors.white,
              size: 18,
            ),
          ),
          title: Text(
            AppLocalizations.of(context)!.enableLrcLibFallback,
            style: const TextStyle(fontSize: 16),
          ),
          subtitle: Text(
            AppLocalizations.of(context)!.lrcLibFallbackSubtitle,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white.withValues(alpha: 0.5)
                  : Colors.black.withValues(alpha: 0.5),
            ),
          ),
          trailing: CupertinoSwitch(
            value: _lrcLibFallback,
            activeTrackColor: accent,
            onChanged: (v) async {
              final storage = StorageService();
              await storage.saveLrcLibFallback(v);
              setState(() => _lrcLibFallback = v);
            },
          ),
        ),
        _buildDivider(),
        // aonsoku/src/app/components/settings/pages/audio/lyrics.tsx preferSynced
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Colors.purple, Colors.purple.withValues(alpha: 0.6)]),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(CupertinoIcons.music_note, color: Colors.white, size: 18),
          ),
          title: const Text('Prefer Synced Lyrics', style: TextStyle(fontSize: 16)),
          subtitle: Text(
            'Приоритет синхронных [mm:ss.xx] над plain текстом (как в aonsoku)',
            style: TextStyle(fontSize: 13, color: Theme.of(context).brightness == Brightness.dark ? Colors.white.withValues(alpha: 0.5) : Colors.black.withValues(alpha: 0.5)),
          ),
          trailing: CupertinoSwitch(
            value: _preferSyncedLyrics,
            activeTrackColor: accent,
            onChanged: (v) async {
              final storage = StorageService();
              await storage.savePreferSyncedLyrics(v);
              setState(() => _preferSyncedLyrics = v);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildGaplessSection() {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        final accent = Theme.of(context).colorScheme.primary;
        return _buildSection(
          title: 'Gapless Playback',
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              leading: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [accent, accent.withValues(alpha: 0.6)],
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  CupertinoIcons.link,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              title: const Text(
                'Gapless Playback',
                style: TextStyle(fontSize: 16),
              ),
              subtitle: Text(
                'Eliminate silence between songs',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white.withValues(alpha: 0.5)
                      : Colors.black.withValues(alpha: 0.5),
                ),
              ),
              trailing: CupertinoSwitch(
                value: player.gaplessEnabled,
                activeTrackColor: accent,
                onChanged: (_) => player.toggleGaplessPlayback(),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFadeSection() {
    final l10n = AppLocalizations.of(context)!;
    return _buildSection(
      title: l10n.sectionFadeInOut,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Theme.of(context).colorScheme.primary,
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.6),
                ],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              CupertinoIcons.waveform,
              color: Colors.white,
              size: 18,
            ),
          ),
          title: Text(
            l10n.fadeInOutEnable,
            style: const TextStyle(fontSize: 16),
          ),
          subtitle: Text(
            l10n.fadeInOutSubtitle,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white.withValues(alpha: 0.5)
                  : Colors.black.withValues(alpha: 0.5),
            ),
          ),
          trailing: CupertinoSwitch(
            value: _fadeEnabled,
            activeTrackColor: Theme.of(context).colorScheme.primary,
            onChanged: (v) async {
              await _fadeSettingsService.setFadeEnabled(v);
              setState(() => _fadeEnabled = v);
            },
          ),
        ),
        if (_fadeEnabled) ...[
          _buildDivider(),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            title: Text(
              l10n.fadeDuration(_fadeDurationMs),
              style: const TextStyle(fontSize: 16),
            ),
            subtitle: Slider(
              value: _fadeDurationMs.toDouble(),
              min: 100,
              max: 1000,
              divisions: 18,
              activeColor: Theme.of(context).colorScheme.primary,
              onChanged: (value) async {
                final duration = value.round();
                await _fadeSettingsService.setFadeDurationMs(duration);
                setState(() => _fadeDurationMs = duration);
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTranscodingSection() {
    return Consumer<TranscodingService>(
      builder: (context, ts, _) {
        final accent = Theme.of(context).colorScheme.primary;
        final secondaryText =
            _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText;

        Widget connectionBadge() {
          final isWifi = ts.currentConnectionType == ConnectionType.wifi;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: (isWifi ? Colors.green : Colors.orange)
                  .withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isWifi ? Icons.wifi_rounded : Icons.signal_cellular_alt,
                  size: 12,
                  color: isWifi ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 4),
                Text(
                  isWifi ? 'WiFi' : 'Mobile',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isWifi ? Colors.green : Colors.orange,
                  ),
                ),
              ],
            ),
          );
        }

        return _buildSection(
          title: AppLocalizations.of(context)!.sectionStreamingQuality,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              leading: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF9500), Color(0xFFFF3B30)],
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  CupertinoIcons.waveform,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              title: Text(
                AppLocalizations.of(context)!.transcodingEnable,
                style: const TextStyle(fontSize: 16),
              ),
              subtitle: Text(
                AppLocalizations.of(context)!.transcodingEnableSubtitle,
                style: TextStyle(fontSize: 13, color: secondaryText),
              ),
              trailing: CupertinoSwitch(
                value: ts.enabled,
                activeTrackColor: accent,
                onChanged: (v) => ts.setEnabled(v),
              ),
            ),
            if (ts.enabled) ...[
              _buildDivider(),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                leading: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [accent, accent.withValues(alpha: 0.6)],
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.auto_fix_high_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                title: Text(
                  AppLocalizations.of(context)!.smartTranscoding,
                  style: const TextStyle(fontSize: 16),
                ),
                subtitle: Text(
                  AppLocalizations.of(context)!.smartTranscodingSubtitle,
                  style: TextStyle(fontSize: 13, color: secondaryText),
                ),
                trailing: CupertinoSwitch(
                  value: ts.smartEnabled,
                  activeTrackColor: accent,
                  onChanged: (v) => ts.setSmartEnabled(v),
                ),
              ),
              if (ts.smartEnabled)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: WrappedRowSmartInfo(
                    detectedLabel: AppLocalizations.of(context)!.smartTranscodingDetectedNetwork,
                    badge: connectionBadge(),
                    bitrateLabel: AppLocalizations.of(context)!.smartTranscodingActiveBitrate(
                      ts.getCurrentBitrate() != null
                          ? '${ts.getCurrentBitrate()} kbps'
                          : AppLocalizations.of(context)!.transcodingFormatOriginal,
                    ),
                    secondaryText: secondaryText,
                  ),
                ),
              _buildDivider(),
              _TranscodingRow(
                icon: Icons.wifi_rounded,
                title: AppLocalizations.of(context)!.transcodingWifiQuality,
                subtitle: ts.smartEnabled
                    ? AppLocalizations.of(context)!.transcodingWifiQualitySubtitleSmart
                    : AppLocalizations.of(context)!.transcodingWifiQualitySubtitle,
                secondaryText: secondaryText,
                dropdown: DropdownButton<int>(
                  value: ts.wifiBitrate,
                  underline: const SizedBox(),
                  isDense: true,
                  style: TextStyle(fontSize: 13, color: _isDark ? Colors.white : Colors.black),
                  items: TranscodeBitrate.options.map((bitrate) {
                    final label = bitrate == TranscodeBitrate.original
                        ? AppLocalizations.of(context)!.transcodingBitrateOriginal
                        : '$bitrate kbps';
                    return DropdownMenuItem(value: bitrate, child: Text(label, overflow: TextOverflow.ellipsis));
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) ts.setWifiBitrate(v);
                  },
                ),
              ),
              _buildDivider(),
              _TranscodingRow(
                icon: Icons.signal_cellular_alt_rounded,
                title: AppLocalizations.of(context)!.transcodingMobileQuality,
                subtitle: ts.smartEnabled
                    ? AppLocalizations.of(context)!.transcodingMobileQualitySubtitleSmart
                    : AppLocalizations.of(context)!.transcodingMobileQualitySubtitle,
                secondaryText: secondaryText,
                dropdown: DropdownButton<int>(
                  value: ts.mobileBitrate,
                  underline: const SizedBox(),
                  isDense: true,
                  style: TextStyle(fontSize: 13, color: _isDark ? Colors.white : Colors.black),
                  items: TranscodeBitrate.options.map((bitrate) {
                    final label = bitrate == TranscodeBitrate.original
                        ? AppLocalizations.of(context)!.transcodingBitrateOriginal
                        : '$bitrate kbps';
                    return DropdownMenuItem(value: bitrate, child: Text(label, overflow: TextOverflow.ellipsis));
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) ts.setMobileBitrate(v);
                  },
                ),
              ),
              _buildDivider(),
              _TranscodingRow(
                icon: Icons.audio_file_rounded,
                title: AppLocalizations.of(context)!.transcodingFormat,
                subtitle: AppLocalizations.of(context)!.transcodingFormatSubtitle,
                secondaryText: secondaryText,
                dropdown: DropdownButton<String>(
                  value: ts.format,
                  underline: const SizedBox(),
                  isDense: true,
                  style: TextStyle(fontSize: 13, color: _isDark ? Colors.white : Colors.black),
                  items: TranscodeFormat.options.map((format) {
                    final label = format == TranscodeFormat.original
                        ? AppLocalizations.of(context)!.transcodingFormatOriginal
                        : format.toUpperCase();
                    return DropdownMenuItem(value: format, child: Text(label));
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) ts.setFormat(v);
                  },
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // BPM Crossfade Section
  // ──────────────────────────────────────────────────────────────────────────

  Widget _buildBpmCrossfadeSection() {
    return _buildSection(
      title: 'BPM CROSSFADE',
      children: [
        _buildBpmCrossfadeToggle(),
        _buildDivider(),
        _buildBpmCrossfadeEasingSelector(),
        _buildDivider(),
        _buildBpmCrossfadeDurationInfo(),
        _buildDivider(),
        _buildBpmCrossfadeInfo(),
      ],
    );
  }

  Widget _buildBpmCrossfadeEasingSelector() {
    final svc = BpmCrossfadeService();
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(width: 32, height: 32, decoration: BoxDecoration(color: Colors.cyan.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.tune_rounded, color: Colors.cyan, size: 18)),
      title: const Text('Кривая фейда', style: TextStyle(fontSize: 16)),
      subtitle: Text('50мс интерполяция', style: TextStyle(fontSize: 12, color: _isDark ? Colors.white54 : Colors.black54)),
      trailing: DropdownButton<CrossfadeEasing>(
        value: _crossfadeEasing, underline: const SizedBox(),
        items: CrossfadeEasing.values.map((e) => DropdownMenuItem(value: e, child: Text(e.name))).toList(),
        onChanged: (v) async {
          if (v == null) return;
          await svc.setEasing(v);
          setState(() => _crossfadeEasing = v);
        },
      ),
    );
  }

  Widget _buildBpmCrossfadeDurationInfo() {
    final svc = BpmCrossfadeService();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.timer_outlined, size: 14, color: _isDark ? Colors.white54 : Colors.black54),
          const SizedBox(width: 6),
          Text('Длительность: ${svc.minDuration.toStringAsFixed(1)}–${svc.maxDuration.toStringAsFixed(1)}с', style: TextStyle(fontSize: 12, color: _isDark ? Colors.white70 : Colors.black54)),
        ]),
        const SizedBox(height: 4),
        Text('Fast ≥120 BPM → 2.5 beats, Medium 90–120 → 3.0, Slow <90 → 3.5 beats (clamp 2–8с). areTracksMixable ±10 BPM', style: TextStyle(fontSize: 11, color: _isDark ? Colors.white38 : Colors.black38)),
      ]),
    );
  }

  Widget _buildBpmCrossfadeToggle() {
    final bpmCrossfadeService = BpmCrossfadeService();

    // Было: Switch показывал сохранённый isEnabled, а реально фича требует
    // ещё включённый Gapless — тумблер горел, но ничего не делал.
    // Теперь: показываем эффективное состояние, при включении дотягиваем
    // зависимость (Gapless), иначе честно пишем что выключено.
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        // BPM-фейды применяются поверх обычного fade in/out — без него
        // тумблеру нечего формировать.
        final effective =
            bpmCrossfadeService.isEffectivelyEnabled && _fadeEnabled;
        final blocked = !player.gaplessEnabled && !bpmCrossfadeService.isEnabled;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.cyan.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.speed_rounded,
                  color: Colors.cyan,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'BPM-Aware Crossfade',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: _isDark ? Colors.white : Colors.black,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      blocked
                          ? 'Требует включённый Gapless Playback'
                          : (!_fadeEnabled && bpmCrossfadeService.isEnabled
                              ? 'Включи «Плавное появление/затухание» ниже — BPM формирует его кривую'
                              : (effective
                                  ? 'Активно: фейды по темпу (${bpmCrossfadeService.minDuration.toStringAsFixed(1)}–${bpmCrossfadeService.maxDuration.toStringAsFixed(1)}с, ${bpmCrossfadeService.easing.name})'
                                  : 'Beat-matched transitions based on tempo')),
                      style: TextStyle(
                        fontSize: 12,
                        color: _isDark ? Colors.white54 : Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: effective,
                onChanged: (value) async {
                  await bpmCrossfadeService.setEnabled(value);
                  if (value && !player.gaplessEnabled) {
                    player.toggleGaplessPlayback();
                  }
                  try {
                    await bpmCrossfadeService.syncGaplessCrossfade(
                        gapless: player.gaplessEnabled);
                  } catch (_) {}
                  setState(() {});
                },
                activeColor: AppTheme.appleMusicRed,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBpmCrossfadeInfo() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 20,
                color: _isDark ? Colors.white70 : Colors.black54,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'How it works',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: _isDark ? Colors.white : Colors.black,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildBpmFeatureItem('Analyzes BPM of current and next track'),
          _buildBpmFeatureItem('Calculates optimal crossfade duration'),
          _buildBpmFeatureItem('Aligns transitions with beat boundaries'),
          _buildBpmFeatureItem('Fast tracks (120+ BPM): shorter crossfade'),
          _buildBpmFeatureItem('Slow tracks (<90 BPM): longer crossfade'),
        ],
      ),
    );
  }

  Widget _buildBpmFeatureItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 32, top: 4),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 14,
            color: Colors.cyan.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: _isDark ? Colors.white70 : Colors.black54,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecommendationsSection() {
    return _buildSection(
      title: 'SMART RECOMMENDATIONS',
      children: [
        _buildRecommendationsToggle(),
        _buildDivider(),
        _buildRecommendationsStats(),
        _buildDivider(),
        _buildClearRecommendationsButton(),
      ],
    );
  }

  /// Яндекс переехал во вкладку «Интеграции» (рядом с МТС и Brain) —
  /// здесь только ссылка, чтобы не было двух расходящихся настроек.
  Widget _buildYandexMusicSection() {
    return _buildSection(
      title: 'YANDEX MUSIC',
      children: [
        ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: const Color(0xFFFFCC00).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.explore_rounded,
              color: Color(0xFFFFCC00),
              size: 18,
            ),
          ),
          title: const Text('Настраивается в «Интеграциях»',
              style: TextStyle(fontSize: 16)),
          subtitle: Text(
            'Включение, токен и функции — в одном месте',
            style: TextStyle(
              fontSize: 13,
              color: _isDark
                  ? AppTheme.darkSecondaryText
                  : AppTheme.lightSecondaryText,
            ),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const SettingsScreen(initialTab: 6),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRecommendationsToggle() {
    return Consumer<RecommendationService>(
      builder: (context, service, _) {
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFFF2D55), Color(0xFFFF6B6B)],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              CupertinoIcons.sparkles,
              color: Colors.white,
              size: 18,
            ),
          ),
          title: Text(
            AppLocalizations.of(context)!.enableRecommendations,
            style: const TextStyle(fontSize: 16),
          ),
          subtitle: Text(
            AppLocalizations.of(context)!.enableRecommendationsSubtitle,
            style: TextStyle(
              fontSize: 13,
              color: _isDark
                  ? AppTheme.darkSecondaryText
                  : AppTheme.lightSecondaryText,
            ),
          ),
          trailing: CupertinoSwitch(
            value: service.enabled,
            activeTrackColor: Theme.of(context).colorScheme.primary,
            onChanged: (value) => service.setEnabled(value),
          ),
        );
      },
    );
  }

  Widget _buildRecommendationsStats() {
    return Consumer<RecommendationService>(
      builder: (context, service, _) {
        final stats = service.getListeningStats();
        final uniqueSongs = stats['uniqueSongs'] ?? 0;
        final totalPlays = stats['totalPlays'] ?? 0;
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          title: Text(
            AppLocalizations.of(context)!.listeningData,
            style: const TextStyle(fontSize: 16),
          ),
          subtitle: Text(
            AppLocalizations.of(context)!.totalPlays(totalPlays),
            style: TextStyle(
              fontSize: 13,
              color: _isDark
                  ? AppTheme.darkSecondaryText
                  : AppTheme.lightSecondaryText,
            ),
          ),
          trailing: Text(
            AppLocalizations.of(context)!.songsCount(uniqueSongs),
            style: TextStyle(
              fontSize: 14,
              color: _isDark
                  ? AppTheme.darkSecondaryText
                  : AppTheme.lightSecondaryText,
            ),
          ),
        );
      },
    );
  }

  Widget _buildClearRecommendationsButton() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Text(
        AppLocalizations.of(context)!.clearListeningHistory,
        style: const TextStyle(fontSize: 16, color: Color(0xFFFF3B30)),
      ),
      onTap: () {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(AppLocalizations.of(context)!.clearListeningHistory),
            content: Text(AppLocalizations.of(context)!.confirmClearHistory),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppLocalizations.of(context)!.cancel),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  Provider.of<RecommendationService>(
                    context,
                    listen: false,
                  ).clearData();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        AppLocalizations.of(context)!.historyCleared,
                      ),
                    ),
                  );
                },
                child: Text(
                  AppLocalizations.of(context)!.delete,
                  style: const TextStyle(color: Color(0xFFFF3B30)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

}

class WrappedRowSmartInfo extends StatelessWidget {
  final String detectedLabel;
  final Widget badge;
  final String bitrateLabel;
  final Color secondaryText;
  const WrappedRowSmartInfo({super.key, required this.detectedLabel, required this.badge, required this.bitrateLabel, required this.secondaryText});
  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 6,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text(detectedLabel, style: TextStyle(fontSize: 12, color: secondaryText)),
          const SizedBox(width: 6),
          badge,
        ]),
        Text(bitrateLabel, style: TextStyle(fontSize: 12, color: secondaryText, fontWeight: FontWeight.w500)),
      ],
    );
  }
}

class _TranscodingRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color secondaryText;
  final Widget dropdown;
  const _TranscodingRow({required this.icon, required this.title, required this.subtitle, required this.secondaryText, required this.dropdown});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Colors.black54),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 12, color: secondaryText), maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Flexible(child: dropdown),
        ],
      ),
    );
  }
}
