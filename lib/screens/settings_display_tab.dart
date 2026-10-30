import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'package:url_launcher/url_launcher.dart';
import '../services/player_ui_settings_service.dart';
import '../widgets/wave/wave_mood.dart';
import '../services/theme_service.dart';
import '../services/locale_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../l10n/app_localizations.dart';
import 'theme_manager_screen.dart';

class SettingsDisplayTab extends StatefulWidget {
  const SettingsDisplayTab({super.key});

  @override
  State<SettingsDisplayTab> createState() => _SettingsDisplayTabState();
}

class _SettingsDisplayTabState extends State<SettingsDisplayTab> {
  final _playerUiSettings = PlayerUiSettingsService();
  bool _showVolumeSlider = true;
  bool _showStarRatings = false;
  bool _showMiniPlayerHeart = false;
  bool _showMiniPlayerRepeat = false;
  bool _showMiniPlayerShuffle = false;
  bool _miniPlayerPcStyle = true;
  double _albumArtCornerRadius = 8.0;
  String _artworkShape = 'rounded';
  String _artworkShadow = 'soft';
  String _artworkShadowColor = 'black';
  bool _liveSearch = true;

  // Progress bar customization
  int _progressBarColor = 0xFF4E8CA8;
  String _progressBarStyle = 'rounded';
  double _progressBarHeight = 4.0;
  bool _progressBarAnimation = true;
  String _progressBarVariant = 'kumaflow';

  // Home visibility
  bool _homeShowMyWave = true;
  bool _homeShowMixes = true;
  bool _homeShowRecent = true;
  bool _homeShowPersonalized = true;
  bool _homeShowYandex = true;
  bool _homeShowGenre = true;
  bool _homeShowAiMix = true;
  bool _homeShowRecentlyPlayed = true;
  bool _homeShowYourPlaylists = true;
  bool _homeShowLatestReleases = true;
  bool _homeShowArtistMixes = true;
  bool _homeShowGenreMixes = true;
  bool _homeShowDailyPlaylist = true;
  bool _homeShowAiDaily = false;
  bool _homeShowYandexSimilar = true;
  bool _homeShowMyWaveShuffle = true;
  bool _homeMyWaveAnimated = false;
  bool _homeMyWaveV2 = false;
  bool _homeMyWaveShowCount = true;
  String _homeMyWaveVariant = 'v2';

  ThemeMode _themeMode = ThemeMode.system;
  AccentColor _accentColor = AccentColor.polar;
  bool _liquidGlass = false;
  double _gradientIntensity = 1.0;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    await _playerUiSettings.initialize();

    if (!mounted) return;
    final themeService = Provider.of<ThemeService>(context, listen: false);

    setState(() {
      _showVolumeSlider = _playerUiSettings.getShowVolumeSlider();
      _showStarRatings = _playerUiSettings.getShowStarRatings();
      _showMiniPlayerHeart = _playerUiSettings.getShowMiniPlayerHeart();
      _showMiniPlayerRepeat = _playerUiSettings.getShowMiniPlayerRepeat();
      _showMiniPlayerShuffle = _playerUiSettings.getShowMiniPlayerShuffle();
      _miniPlayerPcStyle = _playerUiSettings.getMiniPlayerPcStyle();
      _albumArtCornerRadius = _playerUiSettings.getAlbumArtCornerRadius();
      _artworkShape = _playerUiSettings.getArtworkShape();
      _artworkShadow = _playerUiSettings.getArtworkShadow();
      _artworkShadowColor = _playerUiSettings.getArtworkShadowColor();
      _liveSearch = _playerUiSettings.getLiveSearch();
      _progressBarColor = _playerUiSettings.getProgressBarColor();
      _progressBarStyle = _playerUiSettings.getProgressBarStyle();
      _progressBarHeight = _playerUiSettings.getProgressBarHeight();
      _progressBarAnimation = _playerUiSettings.getProgressBarAnimation();
      _progressBarVariant = _playerUiSettings.getProgressBarVariant();
      _homeShowMyWave = _playerUiSettings.getHomeShowMyWave();
      _homeShowMixes = _playerUiSettings.getHomeShowMixes();
      _homeShowRecent = _playerUiSettings.getHomeShowRecent();
      _homeShowPersonalized = _playerUiSettings.getHomeShowPersonalized();
      _homeShowYandex = _playerUiSettings.getHomeShowYandex();
      _homeShowGenre = _playerUiSettings.getHomeShowGenre();
      _homeShowAiMix = _playerUiSettings.getHomeShowAiMix();
      _homeShowRecentlyPlayed = _playerUiSettings.getHomeShowRecentlyPlayed();
      _homeShowYourPlaylists = _playerUiSettings.getHomeShowYourPlaylists();
      _homeShowLatestReleases = _playerUiSettings.getHomeShowLatestReleases();
      _homeShowArtistMixes = _playerUiSettings.getHomeShowArtistMixes();
      _homeShowGenreMixes = _playerUiSettings.getHomeShowGenreMixes();
      _homeShowDailyPlaylist = _playerUiSettings.getHomeShowDailyPlaylist();
      _homeShowAiDaily = _playerUiSettings.getHomeShowAiDaily();
      _homeShowYandexSimilar = _playerUiSettings.getHomeShowYandexSimilar();
      _homeShowMyWaveShuffle = _playerUiSettings.getHomeShowMyWaveShuffle();
      _homeMyWaveAnimated = _playerUiSettings.getHomeMyWaveAnimated();
      _homeMyWaveV2 = _playerUiSettings.getHomeMyWaveV2();
      _homeMyWaveShowCount = _playerUiSettings.getHomeMyWaveShowCount();
      _homeMyWaveVariant = _playerUiSettings.getHomeMyWaveVariant();
      _themeMode = themeService.themeMode;
      _accentColor = themeService.accentColor;
      _liquidGlass = themeService.liquidGlass;
      _gradientIntensity = themeService.gradientIntensity;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        _buildSection(
          title: AppLocalizations.of(context)!.appearanceSection.toUpperCase(),
          children: [_buildAppearanceEditor()],
        ),
        const SizedBox(height: 24),
        _buildSection(
          title: AppLocalizations.of(context)!.language.toUpperCase(),
          children: [
            _buildLanguageSelector(),
            _buildDivider(),
            _buildTranslationCredit(),
          ],
        ),
        const SizedBox(height: 24),
        _buildSection(
          title: AppLocalizations.of(context)!.playerInterface.toUpperCase(),
          children: [
            _buildVolumeSliderToggle(),
            _buildDivider(),
            _buildStarRatingsToggle(),
            _buildDivider(),
            _buildMiniPlayerHeartToggle(),
            _buildDivider(),
            _buildMiniPlayerRepeatToggle(),
            _buildDivider(),
            _buildMiniPlayerShuffleToggle(),
            _buildDivider(),
            _buildMiniPlayerPcStyleToggle(),
            _buildDivider(),
            _buildSwipeUpForQueueToggle(),
          ],
        ),
        const SizedBox(height: 24),
        _buildSection(
          title: 'NOW PLAYING THEMES',
          children: [
            _buildNowPlayingThemesButton(),
          ],
        ),
        const SizedBox(height: 24),
        _buildSection(
          title: AppLocalizations.of(context)!.liveSearchSection.toUpperCase(),
          children: [
            _buildLiveSearchToggle(),
          ],
        ),
        const SizedBox(height: 24),
        _buildSection(
          title: AppLocalizations.of(
            context,
          )!.artworkStyleSection.toUpperCase(),
          children: [_buildArtworkStyleEditor()],
        ),
        const SizedBox(height: 24),
        _buildSection(
          title: 'ГЛАВНАЯ СТРАНИЦА',
          children: [
            _buildHomeToggle(
              label: 'Моя волна',
              subtitle: 'Герой-карточка KION',
              value: _homeShowMyWave,
              onChanged: (v) async {
                setState(() => _homeShowMyWave = v);
                await _playerUiSettings.setHomeShowMyWave(v);
              },
            ),
            _buildDivider(),
            _buildHomeToggle(
              label: 'Перемешивание в Моей волне',
              subtitle: 'Показывает Shuffle 40 рядом с Play',
              value: _homeShowMyWaveShuffle,
              onChanged: (v) async {
                setState(() => _homeShowMyWaveShuffle = v);
                await _playerUiSettings.setHomeShowMyWaveShuffle(v);
              },
            ),
            _buildDivider(),
            _buildHomeToggle(
              label: 'Анимация «Моя волна»',
              subtitle: 'Плавные танцующие блобы (изолированный контейнер, 60fps)',
              value: _homeMyWaveAnimated,
              onChanged: (v) async {
                setState(() => _homeMyWaveAnimated = v);
                await _playerUiSettings.setHomeMyWaveAnimated(v);
              },
            ),
            _buildDivider(),
            _buildHomeToggle(
              label: 'Моя волна V2 (как на ПК)',
              subtitle: 'Светлая/тёмная карточка + динамика, кнопки наши',
              value: _homeMyWaveV2,
              onChanged: (v) async {
                setState(() => _homeMyWaveV2 = v);
                await _playerUiSettings.setHomeMyWaveV2(v);
              },
            ),
            _buildDivider(),
            _buildWaveVariantSelector(),
            _buildDivider(),
            _buildHomeToggle(
              label: 'Счётчик треков в Моей волне',
              subtitle: 'Подпись «N треков» в hero-карточке',
              value: _homeMyWaveShowCount,
              onChanged: (v) async {
                setState(() => _homeMyWaveShowCount = v);
                await _playerUiSettings.setHomeMyWaveShowCount(v);
              },
            ),
            _buildDivider(),
            _buildWaveFxToggles(),
            _buildDivider(),
            _buildHomeToggle(
              label: 'Миксы',
              subtitle: 'Quick Picks, Discover и все миксы',
              value: _homeShowMixes,
              onChanged: (v) async {
                setState(() => _homeShowMixes = v);
                await _playerUiSettings.setHomeShowMixes(v);
              },
            ),
            _buildDivider(),
            _buildHomeToggle(
              label: 'Недавнее',
              subtitle: 'Альбомы и плейлисты — быстрый доступ',
              value: _homeShowRecent,
              onChanged: (v) async {
                setState(() => _homeShowRecent = v);
                await _playerUiSettings.setHomeShowRecent(v);
              },
            ),
            _buildDivider(),
            _buildHomeToggle(
              label: 'Персонально',
              subtitle: 'Подборка «Для вас»',
              value: _homeShowPersonalized,
              onChanged: (v) async {
                setState(() => _homeShowPersonalized = v);
                await _playerUiSettings.setHomeShowPersonalized(v);
              },
            ),
            _buildDivider(),
            _buildHomeToggle(
              label: 'Яндекс',
              subtitle: 'Моя волна Яндекса и плейлисты',
              value: _homeShowYandex,
              onChanged: (v) async {
                setState(() => _homeShowYandex = v);
                await _playerUiSettings.setHomeShowYandex(v);
              },
            ),
            _buildDivider(),
            _buildHomeToggle(
              label: 'Жанры',
              subtitle: 'Карусель жанров',
              value: _homeShowGenre,
              onChanged: (v) async {
                setState(() => _homeShowGenre = v);
                await _playerUiSettings.setHomeShowGenre(v);
              },
            ),
            _buildDivider(),
            _buildHomeToggle(
              label: 'ИИ Микс',
              subtitle: 'Отдельный микс от нейросети',
              value: _homeShowAiMix,
              onChanged: (v) async {
                setState(() => _homeShowAiMix = v);
                await _playerUiSettings.setHomeShowAiMix(v);
              },
            ),
            _buildDivider(),
            _buildHomeToggle(
              label: 'Недавно играли',
              subtitle: 'Горизонтальная лента последних альбомов',
              value: _homeShowRecentlyPlayed,
              onChanged: (v) async {
                setState(() => _homeShowRecentlyPlayed = v);
                await _playerUiSettings.setHomeShowRecentlyPlayed(v);
              },
            ),
            _buildDivider(),
            _buildHomeToggle(
              label: 'Ваши плейлисты',
              subtitle: 'Горизонтальная лента плейлистов',
              value: _homeShowYourPlaylists,
              onChanged: (v) async {
                setState(() => _homeShowYourPlaylists = v);
                await _playerUiSettings.setHomeShowYourPlaylists(v);
              },
            ),
            _buildDivider(),
            _buildHomeToggle(
              label: 'Последние релизы',
              subtitle: 'Блок новых альбомов',
              value: _homeShowLatestReleases,
              onChanged: (v) async {
                setState(() => _homeShowLatestReleases = v);
                await _playerUiSettings.setHomeShowLatestReleases(v);
              },
            ),
            _buildDivider(),
            _buildHomeToggle(
              label: 'Миксы по исполнителям',
              subtitle: 'Радио-миксы по артистам',
              value: _homeShowArtistMixes,
              onChanged: (v) async {
                setState(() => _homeShowArtistMixes = v);
                await _playerUiSettings.setHomeShowArtistMixes(v);
              },
            ),
            _buildDivider(),
            _buildHomeToggle(
              label: 'Миксы по жанрам',
              subtitle: 'Сетки жанровых миксов',
              value: _homeShowGenreMixes,
              onChanged: (v) async {
                setState(() => _homeShowGenreMixes = v);
                await _playerUiSettings.setHomeShowGenreMixes(v);
              },
            ),
            _buildDivider(),
            _buildHomeToggle(
              label: 'Плейлист дня',
              subtitle: 'Персональный плейлист на 20 треков',
              value: _homeShowDailyPlaylist,
              onChanged: (v) async {
                setState(() => _homeShowDailyPlaylist = v);
                await _playerUiSettings.setHomeShowDailyPlaylist(v);
              },
            ),
            _buildDivider(),
            _buildHomeToggle(
              label: 'ИИ-микс дня',
              subtitle: 'Ежедневный микс от нейросети на главной',
              value: _homeShowAiDaily,
              onChanged: (v) async {
                setState(() => _homeShowAiDaily = v);
                await _playerUiSettings.setHomeShowAiDaily(v);
              },
            ),
            _buildDivider(),
            _buildHomeToggle(
              label: 'Яндекс похожие артисты (ИИ)',
              subtitle: 'Подменяет похожих на Yandex-версию для инъекций',
              value: _homeShowYandexSimilar,
              onChanged: (v) async {
                setState(() => _homeShowYandexSimilar = v);
                await _playerUiSettings.setHomeShowYandexSimilar(v);
              },
            ),
            _buildDivider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Сбросить главную к лёгкому виду (только Моя волна)'),
                  onPressed: () async {
                    await _playerUiSettings.resetHomeToLightDefaults();
                    setState(() {
                      _homeShowMyWave = true;
                      _homeShowMixes = false;
                      _homeShowRecent = false;
                      _homeShowPersonalized = false;
                      _homeShowYandex = false;
                      _homeShowGenre = false;
                      _homeShowAiMix = false;
                      _homeShowRecentlyPlayed = false;
                      _homeShowYourPlaylists = false;
                      _homeShowLatestReleases = false;
                      _homeShowArtistMixes = false;
                      _homeShowGenreMixes = false;
                      _homeShowDailyPlaylist = false;
                      _homeShowAiDaily = false;
                      _homeShowYandexSimilar = false;
                    });
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Главная разгружена — только Моя волна')));

                  },
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _buildSection(
          title: 'PROGRESS BAR',
          children: [_buildProgressBarEditor()],
        ),
        const SizedBox(height: 24),
        _buildSection(
          title: 'PLAYER DESIGN',
          children: [
            _buildPlayerDesignToggle(),
          ],
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildAppearanceEditor() {
    final themeService = Provider.of<ThemeService>(context, listen: false);
    final isDark = _isDark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildEditorRow(
            icon: CupertinoIcons.moon_stars_fill,
            iconColor: const Color(0xFF5856D6),
            label: AppLocalizations.of(context)!.themeLabel,
            child: _ThemeModeSelector(
              value: _themeMode,
              isDark: isDark,
              onChanged: (mode) async {
                setState(() => _themeMode = mode);
                await themeService.setThemeMode(mode);
              },
            ),
          ),

          const SizedBox(height: 20),

          _buildEditorRow(
            icon: Icons.palette_rounded,
            iconColor: const Color(0xFFFF9500),
            label: AppLocalizations.of(context)!.accentColorLabel,
            child: _AccentColorPicker(
              selected: _accentColor,
              onChanged: (color) async {
                setState(() => _accentColor = color);
                await themeService.setAccentColor(color);
              },
            ),
          ),

          const SizedBox(height: 20),

          _buildEditorRow(
            icon: CupertinoIcons.sparkles,
            iconColor: const Color(0xFF64D2FF),
            label: AppLocalizations.of(context)!.circularDesignLabel,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.of(context)!.circularDesignSubtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? AppTheme.darkSecondaryText
                        : AppTheme.lightSecondaryText,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Spacer(),
                    CupertinoSwitch(
                      value: _liquidGlass,
                      activeTrackColor: const Color(0xFF64D2FF),
                      onChanged: (value) async {
                        setState(() => _liquidGlass = value);
                        await themeService.setLiquidGlass(value);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          _buildEditorRow(
            icon: Icons.gradient_rounded,
            iconColor: const Color(0xFFAF52DE),
            label: 'Интенсивность градиента',
            trailing: Text(
              '${(_gradientIntensity * 100).round()}%',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Фон как на главной — 0% однотон, 100% ярко',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? AppTheme.darkSecondaryText
                        : AppTheme.lightSecondaryText,
                  ),
                ),
                const SizedBox(height: 8),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: Theme.of(context).colorScheme.primary,
                    inactiveTrackColor: isDark
                        ? AppTheme.darkDivider
                        : AppTheme.lightDivider,
                    thumbColor: Theme.of(context).colorScheme.primary,
                    overlayColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                  ),
                  child: Slider(
                    value: _gradientIntensity,
                    min: 0.0,
                    max: 1.0,
                    divisions: 10,
                    onChanged: (v) {
                      setState(() => _gradientIntensity = v);
                      themeService.setGradientIntensity(v);
                    },
                  ),
                ),
                const SizedBox(height: 8),
                // preview bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    height: 28,
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF121212) : Colors.white,
                      border: Border.all(
                        color: isDark ? AppTheme.darkDivider : AppTheme.lightDivider,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Theme.of(context).colorScheme.primary.withValues(alpha: 0.50 * _gradientIntensity),
                                Theme.of(context).colorScheme.primary.withValues(alpha: 0.30 * _gradientIntensity),
                                Theme.of(context).colorScheme.primary.withValues(alpha: 0.05 * _gradientIntensity),
                                Colors.transparent,
                              ],
                              stops: const [0.0, 0.3, 0.7, 1.0],
                            ),
                          ),
                        ),
                        Center(
                          child: Text(
                            _gradientIntensity == 0
                                ? 'Без градиента'
                                : _gradientIntensity < 0.4
                                    ? 'Едва заметно'
                                    : _gradientIntensity < 0.8
                                        ? 'Умеренно'
                                        : 'Ярко',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: isDark ? Colors.white : Colors.black,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('0%', style: TextStyle(fontSize: 10, color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
                    Text('100%', style: TextStyle(fontSize: 10, color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
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

  Widget _buildVolumeSliderToggle() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF007AFF), Color(0xFF5AC8FA)],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          CupertinoIcons.speaker_2,
          color: Colors.white,
          size: 18,
        ),
      ),
      title: Text(
        AppLocalizations.of(context)!.showVolumeSlider,
        style: const TextStyle(fontSize: 16),
      ),
      subtitle: Text(
        AppLocalizations.of(context)!.showVolumeSliderSubtitle,
        style: TextStyle(
          fontSize: 13,
          color: _isDark
              ? AppTheme.darkSecondaryText
              : AppTheme.lightSecondaryText,
        ),
      ),
      trailing: CupertinoSwitch(
        value: _showVolumeSlider,
        activeTrackColor: Theme.of(context).colorScheme.primary,
        onChanged: (value) async {
          setState(() => _showVolumeSlider = value);
          await _playerUiSettings.setShowVolumeSlider(value);
        },
      ),
    );
  }

  Widget _buildStarRatingsToggle() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFFFD700), Color(0xFFFFA500)],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          CupertinoIcons.star_fill,
          color: Colors.white,
          size: 18,
        ),
      ),
      title: Text(
        AppLocalizations.of(context)!.showStarRatings,
        style: const TextStyle(fontSize: 16),
      ),
      subtitle: Text(
        AppLocalizations.of(context)!.showStarRatingsSubtitle,
        style: TextStyle(
          fontSize: 13,
          color: _isDark
              ? AppTheme.darkSecondaryText
              : AppTheme.lightSecondaryText,
        ),
      ),
      trailing: CupertinoSwitch(
        value: _showStarRatings,
        activeTrackColor: Theme.of(context).colorScheme.primary,
        onChanged: (value) async {
          setState(() => _showStarRatings = value);
          await _playerUiSettings.setShowStarRatings(value);
        },
      ),
    );
  }

  Widget _buildMiniPlayerHeartToggle() {
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
          CupertinoIcons.heart_fill,
          color: Colors.white,
          size: 18,
        ),
      ),
      title: Text(
        AppLocalizations.of(context)!.showMiniPlayerHeart,
        style: const TextStyle(fontSize: 16),
      ),
      subtitle: Text(
        AppLocalizations.of(context)!.showMiniPlayerHeartSubtitle,
        style: TextStyle(
          fontSize: 13,
          color: _isDark
              ? AppTheme.darkSecondaryText
              : AppTheme.lightSecondaryText,
        ),
      ),
      trailing: CupertinoSwitch(
        value: _showMiniPlayerHeart,
        activeTrackColor: Theme.of(context).colorScheme.primary,
        onChanged: (value) async {
          setState(() => _showMiniPlayerHeart = value);
          await _playerUiSettings.setShowMiniPlayerHeart(value);
        },
      ),
    );
  }

  Widget _buildMiniPlayerRepeatToggle() {
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
          CupertinoIcons.repeat,
          color: Colors.white,
          size: 18,
        ),
      ),
      title: Text(
        AppLocalizations.of(context)!.showMiniPlayerRepeat,
        style: const TextStyle(fontSize: 16),
      ),
      subtitle: Text(
        AppLocalizations.of(context)!.showMiniPlayerRepeatSubtitle,
        style: TextStyle(
          fontSize: 13,
          color: _isDark
              ? AppTheme.darkSecondaryText
              : AppTheme.lightSecondaryText,
        ),
      ),
      trailing: CupertinoSwitch(
        value: _showMiniPlayerRepeat,
        activeTrackColor: Theme.of(context).colorScheme.primary,
        onChanged: (value) async {
          setState(() => _showMiniPlayerRepeat = value);
          await _playerUiSettings.setShowMiniPlayerRepeat(value);
        },
      ),
    );
  }

  Widget _buildMiniPlayerShuffleToggle() {
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
          CupertinoIcons.shuffle,
          color: Colors.white,
          size: 18,
        ),
      ),
      title: Text(
        AppLocalizations.of(context)!.showMiniPlayerShuffle,
        style: const TextStyle(fontSize: 16),
      ),
      subtitle: Text(
        AppLocalizations.of(context)!.showMiniPlayerShuffleSubtitle,
        style: TextStyle(
          fontSize: 13,
          color: _isDark
              ? AppTheme.darkSecondaryText
              : AppTheme.lightSecondaryText,
        ),
      ),
      trailing: CupertinoSwitch(
        value: _showMiniPlayerShuffle,
        activeTrackColor: Theme.of(context).colorScheme.primary,
        onChanged: (value) async {
          setState(() => _showMiniPlayerShuffle = value);
          await _playerUiSettings.setShowMiniPlayerShuffle(value);
        },
      ),
    );
  }

  Widget _buildMiniPlayerPcStyleToggle() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF1DB954), Color(0xFF4E8CA8)],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          Icons.smartphone_rounded,
          color: Colors.white,
          size: 18,
        ),
      ),
      title: const Text(
        'Мини-плеер как на ПК',
        style: TextStyle(fontSize: 16),
      ),
      subtitle: Text(
        'Зелёный круг play, стрик и очередь. Выкл — классический вид',
        style: TextStyle(
          fontSize: 13,
          color: _isDark
              ? AppTheme.darkSecondaryText
              : AppTheme.lightSecondaryText,
        ),
      ),
      trailing: CupertinoSwitch(
        value: _miniPlayerPcStyle,
        activeTrackColor: Theme.of(context).colorScheme.primary,
        onChanged: (value) async {
          setState(() => _miniPlayerPcStyle = value);
          await _playerUiSettings.setMiniPlayerPcStyle(value);
        },
      ),
    );
  }

  Widget _buildSwipeUpForQueueToggle() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF34C759), Color(0xFF30B350)],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          CupertinoIcons.list_bullet,
          color: Colors.white,
          size: 18,
        ),
      ),
      title: const Text(
        'Swipe up for queue',
        style: TextStyle(fontSize: 16),
      ),
      subtitle: Text(
        'Swipe up on Now Playing to show queue',
        style: TextStyle(
          fontSize: 13,
          color: _isDark
              ? AppTheme.darkSecondaryText
              : AppTheme.lightSecondaryText,
        ),
      ),
      trailing: CupertinoSwitch(
        value: _playerUiSettings.getSwipeUpForQueue(),
        activeTrackColor: Theme.of(context).colorScheme.primary,
        onChanged: (value) async {
          await _playerUiSettings.setSwipeUpForQueue(value);
          setState(() {});
        },
      ),
    );
  }

  Widget _buildHomeToggle({
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(CupertinoIcons.home, color: Theme.of(context).colorScheme.primary, size: 18),
      ),
      title: Text(label, style: const TextStyle(fontSize: 16)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 13, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
      trailing: CupertinoSwitch(value: value, activeTrackColor: Theme.of(context).colorScheme.primary, onChanged: onChanged),
    );
  }

  /// Вид волны: KumaWave V1 / V2 / V3 — как Hero на ПК.
  /// V1 — статичный градиент (для слабых), V2 — блобы, V3 — шейдер с десктопа.
  Widget _buildWaveVariantSelector() {
    const labels = {
      'v1': 'KumaWave V1',
      'v2': 'KumaWave V2',
      'v3': 'KumaWave V3',
    };
    const hints = {
      'v1': 'Статичный градиент, почти 0 затрат',
      'v2': 'Танцующие блобы в такт музыке',
      'v3': 'Шейдер как на ПК (для мощных)',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Вид волны',
              style: TextStyle(fontSize: 16)),
          const SizedBox(height: 2),
          Text('Тот же центр, фон — как Hero на ПК',
              style: TextStyle(
                  fontSize: 13,
                  color: _isDark
                      ? AppTheme.darkSecondaryText
                      : AppTheme.lightSecondaryText)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final v in const ['v1', 'v2', 'v3'])
                ChoiceChip(
                  label: Text(labels[v]!),
                  selected: _homeMyWaveVariant == v,
                  onSelected: (_) async {
                    setState(() => _homeMyWaveVariant = v);
                    await _playerUiSettings.setHomeMyWaveVariant(v);
                  },
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(hints[_homeMyWaveVariant] ?? '',
              style: TextStyle(
                  fontSize: 12,
                  color: _isDark
                      ? AppTheme.darkSecondaryText
                      : AppTheme.lightSecondaryText)),
        ],
      ),
    );
  }

  /// Жанровые эффекты капли V2 (Огонь, Варп, Дым…) — чипы-выключатели,
  /// как гейты effects на ПК. Выключенный эффект = только капля без него.
  Widget _buildWaveFxToggles() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Эффекты волны V2',
              style: TextStyle(fontSize: 16)),
          const SizedBox(height: 2),
          Text('Облачка и анимации по жанрам (тап — вкл/выкл)',
              style: TextStyle(
                  fontSize: 13,
                  color: _isDark
                      ? AppTheme.darkSecondaryText
                      : AppTheme.lightSecondaryText)),
          const SizedBox(height: 8),
          ValueListenableBuilder<int>(
            valueListenable:
                _playerUiSettings.waveFxVersionNotifier,
            builder: (_, __, ___) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in WaveMood.values)
                  if (m != WaveMood.none)
                    FilterChip(
                      label: Text(waveMoodLabels[m] ?? m.name),
                      selected: _playerUiSettings.getWaveFx(m),
                      onSelected: (v) =>
                          _playerUiSettings.setWaveFx(m, v),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNowPlayingThemesButton() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF8B5CF6), AppTheme.appleMusicRed],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          CupertinoIcons.paintbrush,
          color: Colors.white,
          size: 18,
        ),
      ),
      title: const Text(
        'Customize Now Playing Screen (Beta)',
        style: TextStyle(fontSize: 16),
      ),
      subtitle: const Text(
        'Create and manage custom themes',
        style: TextStyle(
          fontSize: 13,
          color: Colors.grey,
        ),
      ),
      trailing: const Icon(
        CupertinoIcons.chevron_right,
        color: Colors.grey,
        size: 18,
      ),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const ThemeManagerScreen(),
          ),
        );
      },
    );
  }

  Widget _buildLiveSearchToggle() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFFF9500), Color(0xFFFFCC00)],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          CupertinoIcons.search,
          color: Colors.white,
          size: 18,
        ),
      ),
      title: Text(
        AppLocalizations.of(context)!.liveSearch,
        style: const TextStyle(fontSize: 16),
      ),
      subtitle: Text(
        AppLocalizations.of(context)!.liveSearchSubtitle,
        style: TextStyle(
          fontSize: 13,
          color: _isDark
              ? AppTheme.darkSecondaryText
              : AppTheme.lightSecondaryText,
        ),
      ),
      trailing: CupertinoSwitch(
        value: _liveSearch,
        activeTrackColor: Theme.of(context).colorScheme.primary,
        onChanged: (value) async {
          setState(() => _liveSearch = value);
          await _playerUiSettings.setLiveSearch(value);
        },
      ),
    );
  }

  double _artworkPreviewRadius() {
    const previewSize = 108.0;
    const referenceSize = 50.0;
    if (_artworkShape == 'circle' || _artworkShape == 'stadium') return 9999.0;
    if (_artworkShape == 'square') return 0.0;
    if (_artworkShape == 'diamond' || _artworkShape == 'hexagon' || _artworkShape == 'octagon') return 12.0;
    if (_artworkShape == 'squircle') return 18.0;
    return (_albumArtCornerRadius * previewSize / referenceSize)
        .clamp(0.0, previewSize / 2);
  }

  List<BoxShadow>? _artworkPreviewShadow() {
    if (_artworkShadow == 'none') return null;
    const previewSize = 108.0;
    final Color color = _artworkShadowColor == 'accent'
        ? Theme.of(context).colorScheme.primary
        : Colors.black;
    double opacity;
    double blur;
    Offset offset;
    switch (_artworkShadow) {
      case 'medium':
        opacity = _isDark ? 0.35 : 0.25;
        blur = previewSize / 6;
        offset = Offset(0, previewSize / 20);
        break;
      case 'strong':
        opacity = _isDark ? 0.55 : 0.40;
        blur = previewSize / 4;
        offset = Offset(0, previewSize / 12);
        break;
      default:
        opacity = _isDark ? 0.22 : 0.14;
        blur = previewSize / 10;
        offset = Offset(0, previewSize / 30);
    }
    return [
      BoxShadow(
        color: color.withValues(alpha: opacity),
        blurRadius: blur,
        offset: offset,
      ),
    ];
  }

  Widget _buildArtworkStyleEditor() {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Column(
              children: [
                Text(
                  l10n.artworkPreview,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: _isDark
                        ? AppTheme.darkSecondaryText
                        : AppTheme.lightSecondaryText,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 14),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  width: 108,
                  height: 108,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Theme.of(context).colorScheme.primary,
                        Theme.of(context).colorScheme.primary.withValues(alpha: 180),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(
                      _artworkPreviewRadius().clamp(0.0, 54.0),
                    ),
                    boxShadow: _artworkPreviewShadow(),
                  ),
                  child: const Icon(
                    Icons.music_note_rounded,
                    color: Colors.white,
                    size: 44,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          _buildEditorRow(
            icon: Icons.crop_square_rounded,
            iconColor: const Color(0xFF5856D6),
            label: l10n.artworkShape,
            child: _buildChips(
              options: [
                (value: 'rounded', label: l10n.artworkShapeRounded),
                (value: 'circle', label: l10n.artworkShapeCircle),
                (value: 'square', label: l10n.artworkShapeSquare),
                (value: 'squircle', label: 'Squircle'),
                (value: 'diamond', label: 'Diamond'),
                (value: 'hexagon', label: 'Hexagon'),
                (value: 'octagon', label: 'Octagon'),
                (value: 'stadium', label: 'Stadium'),
              ],
              selected: _artworkShape,
              onSelected: (v) {
                setState(() => _artworkShape = v);
                _playerUiSettings.setArtworkShape(v);
              },
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: _artworkShape == 'rounded'
                ? Column(
                    children: [
                      const SizedBox(height: 16),
                      _buildEditorRow(
                        icon: Icons.rounded_corner,
                        iconColor: const Color(0xFFFF9500),
                        label: l10n.artworkCornerRadius,
                        trailing: Text(
                          _albumArtCornerRadius.round() == 0
                              ? l10n.artworkCornerRadiusNone
                              : '${_albumArtCornerRadius.round()}px',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: Theme.of(context).colorScheme.primary,
                            inactiveTrackColor: _isDark
                                ? AppTheme.darkDivider
                                : AppTheme.lightDivider,
                            thumbColor: Theme.of(context).colorScheme.primary,
                            overlayColor: Theme.of(context).colorScheme.primary.withValues(
                              alpha: 0.12,
                            ),
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 7,
                            ),
                          ),
                          child: Slider(
                            value: _albumArtCornerRadius,
                            min: 0,
                            max: 24,
                            divisions: 24,
                            onChanged: (v) {
                              setState(() => _albumArtCornerRadius = v);
                              _playerUiSettings.setAlbumArtCornerRadius(v);
                            },
                          ),
                        ),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(height: 16),
          _buildEditorRow(
            icon: Icons.blur_on_rounded,
            iconColor: const Color(0xFF34AADC),
            label: l10n.artworkShadow,
            child: _buildChips(
              options: [
                (value: 'none', label: l10n.artworkShadowNone),
                (value: 'soft', label: l10n.artworkShadowSoft),
                (value: 'medium', label: l10n.artworkShadowMedium),
                (value: 'strong', label: l10n.artworkShadowStrong),
              ],
              selected: _artworkShadow,
              onSelected: (v) {
                setState(() => _artworkShadow = v);
                _playerUiSettings.setArtworkShadow(v);
              },
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: _artworkShadow != 'none'
                ? Column(
                    children: [
                      const SizedBox(height: 16),
                      _buildEditorRow(
                        icon: Icons.palette_outlined,
                        iconColor: const Color(0xFFFF2D55),
                        label: l10n.artworkShadowColor,
                        child: _buildChips(
                          options: [
                            (
                              value: 'black',
                              label: l10n.artworkShadowColorBlack,
                            ),
                            (
                              value: 'accent',
                              label: l10n.artworkShadowColorAccent,
                            ),
                          ],
                          selected: _artworkShadowColor,
                          onSelected: (v) {
                            setState(() => _artworkShadowColor = v);
                            _playerUiSettings.setArtworkShadowColor(v);
                          },
                        ),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildEditorRow({
    required IconData icon,
    required Color iconColor,
    required String label,
    required Widget child,
    Widget? trailing,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, color: iconColor, size: 16),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (trailing != null) ...[const Spacer(), trailing],
          ],
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }

  Widget _buildChips({
    required List<({String value, String label})> options,
    required String selected,
    required ValueChanged<String> onSelected,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.map((opt) {
        final isSelected = opt.value == selected;
        return GestureDetector(
          onTap: () => onSelected(opt.value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : (_isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.06)),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isSelected ? Theme.of(context).colorScheme.primary : Colors.transparent,
              ),
            ),
            child: Text(
              opt.label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected
                    ? Colors.white
                    : (_isDark ? Colors.white70 : Colors.black87),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildProgressBarEditor() {
    final isDark = _isDark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildEditorRow(
            icon: Icons.linear_scale_rounded,
            iconColor: const Color(0xFF00C7BE),
            label: 'Стиль ползунка (KumaFlow / Navic)',
            child: _buildChips(
              options: [
                (value: 'kumaflow', label: 'KumaFlow'),
                (value: 'slim', label: 'Slim'),
                (value: 'squiggly', label: 'Wavy'),
                (value: 'yoyo', label: 'Yoyo'),
                (value: 'waveform', label: 'Waveform'),
              ],
              selected: _progressBarVariant,
              onSelected: (v) {
                setState(() => _progressBarVariant = v);
                _playerUiSettings.setProgressBarVariant(v);
              },
            ),
          ),
          const SizedBox(height: 20),
          _buildEditorRow(
            icon: Icons.color_lens_rounded,
            iconColor: AppTheme.appleMusicRed,
            label: 'Progress Bar Color',
            child: _buildColorPicker(),
          ),
          const SizedBox(height: 20),
          _buildEditorRow(
            icon: Icons.rounded_corner,
            iconColor: const Color(0xFF5856D6),
            label: 'Progress Bar Style',
            child: _buildChips(
              options: [
                (value: 'rounded', label: 'Rounded'),
                (value: 'square', label: 'Square'),
              ],
              selected: _progressBarStyle,
              onSelected: (v) {
                setState(() => _progressBarStyle = v);
                _playerUiSettings.setProgressBarStyle(v);
              },
            ),
          ),
          const SizedBox(height: 20),
          _buildEditorRow(
            icon: Icons.height_rounded,
            iconColor: const Color(0xFF007AFF),
            label: 'Progress Bar Height',
            trailing: Text(
              '${_progressBarHeight.round()}px',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: Theme.of(context).colorScheme.primary,
                inactiveTrackColor: _isDark
                    ? AppTheme.darkDivider
                    : AppTheme.lightDivider,
                thumbColor: Theme.of(context).colorScheme.primary,
                overlayColor: Theme.of(context).colorScheme.primary.withValues(
                  alpha: 0.12,
                ),
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 7,
                ),
              ),
              child: Slider(
                value: _progressBarHeight,
                min: 2,
                max: 12,
                divisions: 10,
                onChanged: (v) {
                  setState(() => _progressBarHeight = v);
                  _playerUiSettings.setProgressBarHeight(v);
                },
              ),
            ),
          ),
          const SizedBox(height: 20),
          _buildEditorRow(
            icon: Icons.animation_rounded,
            iconColor: const Color(0xFF34C759),
            label: 'Progress Bar Animation',
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Enable smooth progress bar animation',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? AppTheme.darkSecondaryText
                          : AppTheme.lightSecondaryText,
                    ),
                  ),
                ),
                const Spacer(),
                CupertinoSwitch(
                  value: _progressBarAnimation,
                  activeTrackColor: Theme.of(context).colorScheme.primary,
                  onChanged: (value) async {
                    setState(() => _progressBarAnimation = value);
                    await _playerUiSettings.setProgressBarAnimation(value);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _buildProgressBarPreview(),
        ],
      ),
    );
  }

  Widget _buildColorPicker() {
    final colors = [
      0xFF4E8CA8,
      0xFFFF6B00,
      0xFF1DB954,
      0xFF007AFF,
      0xFF5856D6,
      0xFFFF9500,
      0xFF00C7BE,
      0xFFFF2D55,
      0xFFAF52DE,
    ];

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: colors.map((color) {
        final isSelected = _progressBarColor == color;
        return GestureDetector(
          onTap: () {
            setState(() => _progressBarColor = color);
            _playerUiSettings.setProgressBarColor(color);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Color(color),
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? Colors.white : Colors.transparent,
                width: 3,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: Color(color).withValues(alpha: 0.5),
                        blurRadius: 8,
                        spreadRadius: 2,
                      )
                    ]
                  : null,
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildProgressBarPreview() {
    final isDark = _isDark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? Colors.black12 : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Preview',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: isDark
                  ? AppTheme.darkSecondaryText
                  : AppTheme.lightSecondaryText,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 12),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            height: _progressBarHeight,
            decoration: BoxDecoration(
              color: isDark ? Colors.grey[800] : Colors.grey[200],
              borderRadius: BorderRadius.circular(
                _progressBarStyle == 'rounded' ? 999 : 0,
              ),
            ),
            child: FractionallySizedBox(
              widthFactor: 0.65,
              alignment: Alignment.centerLeft,
              child: AnimatedContainer(
                duration: _progressBarAnimation ? const Duration(milliseconds: 800) : Duration.zero,
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  color: Color(_progressBarColor),
                  borderRadius: BorderRadius.circular(
                    _progressBarStyle == 'rounded' ? 999 : 0,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerDesignToggle() {
    final storageService = StorageService();
    final styles = [
      ('default', 'Default Player', 'Classic KumaFlow style', Icons.play_circle_rounded, const Color(0xFF007AFF)),
      ('kumaflow_new', 'KumaFlow New', 'Desktop fullscreen port, queue swipe-up', Icons.auto_awesome_rounded, const Color(0xFF4E8CA8)),
      ('yandex', 'Yandex Music Player Style', 'Dynamic gradients, hover animations', Icons.palette_rounded, AppTheme.appleMusicRed),
      ('spotify', 'Spotify Style', 'Dark green, rounded controls', Icons.music_note_rounded, const Color(0xFF1DB954)),
      ('apple', 'Apple Music Style', 'Clean white, blur effects', Icons.apple, const Color(0xFFFA243C)),
      ('youtube', 'YouTube Music Style', 'Red black, bold typography', Icons.play_arrow_rounded, const Color(0xFFFF0000)),
      ('vinyl', 'Vinyl Style', 'Spinning disc, warm sound', Icons.album_rounded, const Color(0xFF9C6B30)),
      ('neon', 'Neon Style', 'Glass card, neon glow', Icons.bolt_rounded, const Color(0xFF00B8D4)),
      ('deezer', 'Deezer Style', 'Purple gradient, flow design', Icons.waves_rounded, const Color(0xFF8E2DE2)),
      ('soundcloud', 'SoundCloud Style', 'Orange wave, minimal', Icons.cloud_rounded, const Color(0xFFFF5500)),
    ];
    return FutureBuilder<String>(
      future: storageService.getPlayerStyle(),
      builder: (context, snapshot) {
        final current = snapshot.data ?? 'default';
        return Column(
          children: styles.map((s) {
            final id = s.$1;
            final title = s.$2;
            final subtitle = s.$3;
            final icon = s.$4;
            final color = s.$5;
            final selected = current == id;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: InkWell(
                onTap: () async {
                  await storageService.setPlayerStyle(id);
                  setState(() {});
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$title selected')));
                },
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: selected ? color.withValues(alpha: 0.12) : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: selected ? color.withValues(alpha: 0.3) : Colors.transparent),
                  ),
                  child: Row(
                    children: [
                      Container(width: 36, height: 36, decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)), child: Icon(icon, color: color, size: 20)),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : Colors.black)), Text(subtitle, style: TextStyle(fontSize: 11, color: _isDark ? Colors.white54 : Colors.black54))])),
                      Radio<String>(value: id, groupValue: current, onChanged: (v) async { if (v != null) { await storageService.setPlayerStyle(v); setState(() {}); }}, activeColor: color),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildLanguageSelector() {
    return Consumer<LocaleService>(
      builder: (context, localeService, _) {
        final currentLocale = localeService.currentLocale;
        final currentLanguageCode = currentLocale?.languageCode ?? 'en';
        final currentLanguageName =
            LocaleService.supportedLanguages[currentLanguageCode] ?? 'English';

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
                colors: [Color(0xFF34C759), Color(0xFF30D158)],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              CupertinoIcons.globe,
              color: Colors.white,
              size: 18,
            ),
          ),
          title: Text(
            AppLocalizations.of(context)!.language,
            style: const TextStyle(fontSize: 16),
          ),
          subtitle: Text(
            currentLanguageName,
            style: TextStyle(
              fontSize: 13,
              color: _isDark
                  ? AppTheme.darkSecondaryText
                  : AppTheme.lightSecondaryText,
            ),
          ),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () => _showLanguagePicker(context, localeService),
        );
      },
    );
  }

  Widget _buildTranslationCredit() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: const Color(0xFF5AC8FA).withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          CupertinoIcons.heart_fill,
          color: Color(0xFFFF3B30),
          size: 18,
        ),
      ),
      title: Text(
        AppLocalizations.of(context)!.communityTranslations,
        style: const TextStyle(fontSize: 16),
      ),
      subtitle: Text(
        AppLocalizations.of(context)!.communityTranslationsSubtitle,
        style: TextStyle(
          fontSize: 13,
          color: _isDark
              ? AppTheme.darkSecondaryText
              : AppTheme.lightSecondaryText,
        ),
      ),
trailing: const Icon(Icons.open_in_new_rounded, size: 18),
      onTap: () => _launchUrl('https://crowdin.com/project/kumaflow'),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _showLanguagePicker(BuildContext context, LocaleService localeService) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: BoxDecoration(
          color: _isDark ? AppTheme.darkSurface : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: _isDark ? Colors.grey[600] : Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(CupertinoIcons.globe, size: 24),
                  const SizedBox(width: 12),
                  Text(
                    AppLocalizations.of(context)!.selectLanguage,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(CupertinoIcons.device_phone_portrait),
              title: Text(AppLocalizations.of(context)!.systemDefault),
              trailing: localeService.currentLocale == null
                  ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
                  : null,
              onTap: () {
                localeService.setLocale(null);
                Navigator.pop(context);
              },
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: LocaleService.supportedLanguages.entries.map((entry) {
                  final isSelected =
                      localeService.currentLocale?.languageCode == entry.key;
                  return ListTile(
                    leading: Text(
                      _getFlagEmoji(entry.key),
                      style: const TextStyle(fontSize: 24),
                    ),
                    title: Text(entry.value),
                    trailing: isSelected
                        ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
                        : null,
                    onTap: () {
                      localeService.setLocale(Locale(entry.key));
                      Navigator.pop(context);
                    },
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getFlagEmoji(String languageCode) {
    const Map<String, String> flagMap = {
      'en': '🇬🇧',
      'sq': '🇦🇱',
      'it': '🇮🇹',
      'bn': '🇧🇩',
      'zh': '🇨🇳',
      'da': '🇩🇰',
      'fi': '🇫🇮',
      'fr': '🇫🇷',
      'de': '🇩🇪',
      'el': '🇬🇷',
      'hi': '🇮🇳',
      'id': '🇮🇩',
      'ga': '🇮🇪',
      'no': '🇳🇴',
      'pl': '🇵🇱',
      'pt': '🇵🇹',
      'ro': '🇷🇴',
      'ru': '🇷🇺',
      'es': '🇪🇸',
      'sv': '🇸🇪',
      'te': '🇮🇳',
      'tr': '🇹🇷',
      'uk': '🇺🇦',
      'vi': '🇻🇳',
    };
    return flagMap[languageCode] ?? '🌐';
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Top-level widget classes
// ──────────────────────────────────────────────────────────────────────────

class _ThemeModeSelector extends StatelessWidget {
  const _ThemeModeSelector({
    required this.value,
    required this.isDark,
    required this.onChanged,
  });

  final ThemeMode value;
  final bool isDark;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = [
      (mode: ThemeMode.system, label: AppLocalizations.of(context)!.themeModeSystem, icon: CupertinoIcons.device_phone_portrait),
      (mode: ThemeMode.light, label: AppLocalizations.of(context)!.themeModeLight, icon: CupertinoIcons.sun_max_fill),
      (mode: ThemeMode.dark, label: AppLocalizations.of(context)!.themeModeDark, icon: CupertinoIcons.moon_fill),
    ];

    final accent = Theme.of(context).colorScheme.primary;

    return Row(
      children: options.map((opt) {
        final selected = value == opt.mode;
        return Expanded(
          child: GestureDetector(
            onTap: () => onChanged(opt.mode),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: selected
                    ? accent
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.06)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    opt.icon,
                    size: 18,
                    color: selected
                        ? Colors.white
                        : (isDark ? Colors.white70 : Colors.black54),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    opt.label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected
                          ? Colors.white
                          : (isDark ? Colors.white70 : Colors.black54),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _AccentColorPicker extends StatelessWidget {
  const _AccentColorPicker({
    required this.selected,
    required this.onChanged,
  });

  final AccentColor selected;
  final ValueChanged<AccentColor> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: AccentColor.values.map((color) {
        final isSelected = selected == color;
        return GestureDetector(
          onTap: () => onChanged(color),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.color,
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? Colors.white : Colors.transparent,
                width: 2.5,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: color.color.withValues(alpha: 0.6),
                        blurRadius: 8,
                        spreadRadius: 1,
                      )
                    ]
                  : null,
            ),
            child: isSelected
                ? const Icon(Icons.check, color: Colors.white, size: 16)
                : null,
          ),
        );
      }).toList(),
    );
  }
}

