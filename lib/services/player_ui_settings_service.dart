import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import '../widgets/wave/wave_mood.dart';

class PlayerUiSettingsService {
  static const String _keyShowVolumeSlider = 'player_show_volume_slider';
  static const String _keyShowStarRatings = 'player_show_star_ratings';
  static const String _keyShowMiniPlayerHeart = 'mini_player_show_heart';
  static const String _keyShowMiniPlayerRepeat = 'mini_player_show_repeat';
  static const String _keyShowMiniPlayerShuffle = 'mini_player_show_shuffle';
  // Стиль мини-плеера: false = классика, true = в стиле нижней панели ПК.
  static const String _keyMiniPlayerPcStyle = 'mini_player_pc_style';
  static const String _keyAlbumArtCornerRadius = 'artwork_corner_radius';
  static const String _keyArtworkShape = 'artwork_shape';
  static const String _keyArtworkShadow = 'artwork_shadow';
  static const String _keyArtworkShadowColor = 'artwork_shadow_color';
  static const String _keyLiveSearch = 'search_live_search';
  static const String _keySwipeUpForQueue = 'player_swipe_up_for_queue';
  // Progress bar customization
  static const String _keyProgressBarColor = 'progress_bar_color';
  static const String _keyProgressBarStyle = 'progress_bar_style';
  static const String _keyProgressBarHeight = 'progress_bar_height';
  static const String _keyProgressBarAnimation = 'progress_bar_animation';
  static const String _keyProgressBarThumbVisible = 'progress_bar_thumb_visible';
  static const String _keyProgressBarThumbSize = 'progress_bar_thumb_size';
  static const String _keyProgressBarThumbColor = 'progress_bar_thumb_color';
  static const String _keyProgressBarVariant = 'progress_bar_variant';
  // Home visibility
  static const String _keyHomeShowMyWave = 'home_show_mywave';
  static const String _keyHomeShowMixes = 'home_show_mixes';
  static const String _keyHomeShowRecent = 'home_show_recent';
  static const String _keyHomeShowPersonalized = 'home_show_personalized';
  static const String _keyHomeShowYandex = 'home_show_yandex';
  static const String _keyHomeShowGenre = 'home_show_genre';
  static const String _keyHomeShowAiMix = 'home_show_ai_mix';
  // New sections (added Aug 2026) - separate toggles for each home block
  static const String _keyHomeShowRecentlyPlayed = 'home_show_recently_played';
  static const String _keyHomeShowYourPlaylists = 'home_show_your_playlists';
  static const String _keyHomeShowLatestReleases = 'home_show_latest_releases';
  static const String _keyHomeShowArtistMixes = 'home_show_artist_mixes';
  static const String _keyHomeShowGenreMixes = 'home_show_genre_mixes';
  static const String _keyHomeShowDailyPlaylist = 'home_show_daily_playlist';
  static const String _keyHomeShowAiDaily = 'home_show_ai_daily';
  static const String _keyHomeShowYandexSimilar = 'home_show_yandex_similar';
  static const String _keyHomeShowMyWaveShuffle = 'home_show_mywave_shuffle';
  static const String _keyHomeMyWaveAnimated = 'home_mywave_animated';
  // Вид волны: v1 — статичный градиент (для слабых), v2 — танцующие блобы,
  // v3 — WebGL-шейдер с десктопа (для мощных). Порт vibe-worker.js.
  static const String _keyHomeMyWaveVariant = 'home_mywave_variant';
  // KumaHeroV2: карточка как на ПК (светлая/тёмная + динамика), включается тумблером.
  static const String _keyHomeMyWaveV2 = 'home_mywave_v2';
  // Счётчик «N треков» в hero Моей волны.
  static const String _keyHomeMyWaveShowCount = 'home_mywave_show_count';

  static final PlayerUiSettingsService _instance =
      PlayerUiSettingsService._internal();
  factory PlayerUiSettingsService() => _instance;
  PlayerUiSettingsService._internal();

  SharedPreferences? _prefs;

  final ValueNotifier<bool> showStarRatingsNotifier = ValueNotifier(false);
  final ValueNotifier<bool> showMiniPlayerHeartNotifier = ValueNotifier(false);
  final ValueNotifier<bool> showMiniPlayerRepeatNotifier = ValueNotifier(false);
  final ValueNotifier<bool> showMiniPlayerShuffleNotifier = ValueNotifier(false);
  final ValueNotifier<bool> miniPlayerPcStyleNotifier = ValueNotifier(true);
  final ValueNotifier<bool> liveSearchNotifier = ValueNotifier(true);
  final ValueNotifier<double> albumArtCornerRadiusNotifier = ValueNotifier(8.0);

  final ValueNotifier<String> artworkShapeNotifier = ValueNotifier('rounded');

  final ValueNotifier<String> artworkShadowNotifier = ValueNotifier('soft');

  final ValueNotifier<String> artworkShadowColorNotifier = ValueNotifier(
    'black',
  );
  final ValueNotifier<bool> swipeUpForQueueNotifier = ValueNotifier(true);

  // Progress bar customization notifiers
  final ValueNotifier<int> progressBarColorNotifier = ValueNotifier(0xFF4E8CA8);
  final ValueNotifier<String> progressBarStyleNotifier = ValueNotifier('rounded');
  final ValueNotifier<double> progressBarHeightNotifier = ValueNotifier(4.0);
  final ValueNotifier<bool> progressBarAnimationNotifier = ValueNotifier(true);
  final ValueNotifier<bool> progressBarThumbVisibleNotifier = ValueNotifier(true);
  final ValueNotifier<double> progressBarThumbSizeNotifier = ValueNotifier(10.0);
  final ValueNotifier<int> progressBarThumbColorNotifier = ValueNotifier(0xFFFFFFFF);
  // KumaFlow (default) / Slim / Squiggly(Wavy) / Yoyo — как в Navic
  final ValueNotifier<String> progressBarVariantNotifier = ValueNotifier('kumaflow');
  final ValueNotifier<bool> homeShowMyWaveNotifier = ValueNotifier(true);
  final ValueNotifier<bool> homeShowMixesNotifier = ValueNotifier(false);
  final ValueNotifier<bool> homeShowRecentNotifier = ValueNotifier(false);
  final ValueNotifier<bool> homeShowPersonalizedNotifier = ValueNotifier(false);
  final ValueNotifier<bool> homeShowYandexNotifier = ValueNotifier(false);
  final ValueNotifier<bool> homeShowGenreNotifier = ValueNotifier(false);
  final ValueNotifier<bool> homeShowAiMixNotifier = ValueNotifier(false);
  final ValueNotifier<bool> homeShowRecentlyPlayedNotifier = ValueNotifier(false);
  final ValueNotifier<bool> homeShowYourPlaylistsNotifier = ValueNotifier(false);
  final ValueNotifier<bool> homeShowLatestReleasesNotifier = ValueNotifier(false);
  final ValueNotifier<bool> homeShowArtistMixesNotifier = ValueNotifier(false);
  final ValueNotifier<bool> homeShowGenreMixesNotifier = ValueNotifier(false);
  final ValueNotifier<bool> homeShowDailyPlaylistNotifier = ValueNotifier(false);
  final ValueNotifier<bool> homeShowAiDailyNotifier = ValueNotifier(false);
  final ValueNotifier<bool> homeShowYandexSimilarNotifier = ValueNotifier(false);
  final ValueNotifier<bool> homeShowMyWaveShuffleNotifier = ValueNotifier(false);
  final ValueNotifier<bool> homeMyWaveAnimatedNotifier = ValueNotifier(false);
  final ValueNotifier<bool> homeMyWaveV2Notifier = ValueNotifier(false);
  final ValueNotifier<bool> homeMyWaveShowCountNotifier = ValueNotifier(true);
  /// v1 | v2 | v3 — вид фона «Моей волны» (как Hero на ПК).
  final ValueNotifier<String> homeMyWaveVariantNotifier =
      ValueNotifier('v2');
  // Жанровые эффекты волны (как гейты effects на ПК): поштучные тумблеры.
  // Изменение любого — инкремент версии, hero перечитывает сет.
  final ValueNotifier<int> waveFxVersionNotifier = ValueNotifier(0);

  static const String _kHomeMigratedV2 = 'home_migrated_v2_light';
  static const String _kHomeMigratedV3 = 'home_migrated_v3_wave_animated';

  Future<void> initialize() async {
    _prefs ??= await SharedPreferences.getInstance();
    // Migration v2: разгрузить главную без очистки данных (по умолчанию только Моя волна)
    if (_prefs!.getBool(_kHomeMigratedV2) != true) {
      final hasAnyHomePref = _kHomeAllKeys.any((k) => _prefs!.containsKey(k));
      if (hasAnyHomePref) {
        await _prefs!.setBool(_keyHomeShowMyWave, true);
        for (final k in [_keyHomeShowMixes, _keyHomeShowRecent, _keyHomeShowPersonalized, _keyHomeShowYandex, _keyHomeShowGenre, _keyHomeShowAiMix, _keyHomeShowRecentlyPlayed, _keyHomeShowYourPlaylists, _keyHomeShowLatestReleases, _keyHomeShowArtistMixes, _keyHomeShowGenreMixes, _keyHomeShowDailyPlaylist, _keyHomeShowYandexSimilar]) {
          await _prefs!.setBool(k, false);
        }
        await _prefs!.setBool(_keyHomeMyWaveAnimated, false);
      }
      await _prefs!.setBool(_kHomeMigratedV2, true);
    }
    if (_prefs!.getBool(_kHomeMigratedV3) != true) {
      if (!_prefs!.containsKey(_keyHomeMyWaveAnimated)) {
        await _prefs!.setBool(_keyHomeMyWaveAnimated, false);
      }
      await _prefs!.setBool(_kHomeMigratedV3, true);
    }
    showStarRatingsNotifier.value = getShowStarRatings();
    showMiniPlayerHeartNotifier.value = getShowMiniPlayerHeart();
    showMiniPlayerRepeatNotifier.value = getShowMiniPlayerRepeat();
    showMiniPlayerShuffleNotifier.value = getShowMiniPlayerShuffle();
    miniPlayerPcStyleNotifier.value = getMiniPlayerPcStyle();
    albumArtCornerRadiusNotifier.value = getAlbumArtCornerRadius();
    artworkShapeNotifier.value = getArtworkShape();
    artworkShadowNotifier.value = getArtworkShadow();
    artworkShadowColorNotifier.value = getArtworkShadowColor();
    liveSearchNotifier.value = getLiveSearch();
    swipeUpForQueueNotifier.value = getSwipeUpForQueue();
    progressBarColorNotifier.value = getProgressBarColor();
    progressBarStyleNotifier.value = getProgressBarStyle();
    progressBarHeightNotifier.value = getProgressBarHeight();
    progressBarAnimationNotifier.value = getProgressBarAnimation();
    progressBarThumbVisibleNotifier.value = getProgressBarThumbVisible();
    progressBarThumbSizeNotifier.value = getProgressBarThumbSize();
    progressBarThumbColorNotifier.value = getProgressBarThumbColor();
    progressBarVariantNotifier.value = getProgressBarVariant();
    homeShowMyWaveNotifier.value = getHomeShowMyWave();
    homeShowMixesNotifier.value = getHomeShowMixes();
    homeShowRecentNotifier.value = getHomeShowRecent();
    homeShowPersonalizedNotifier.value = getHomeShowPersonalized();
    homeShowYandexNotifier.value = getHomeShowYandex();
    homeShowGenreNotifier.value = getHomeShowGenre();
    homeShowAiMixNotifier.value = getHomeShowAiMix();
    homeShowRecentlyPlayedNotifier.value = getHomeShowRecentlyPlayed();
    homeShowYourPlaylistsNotifier.value = getHomeShowYourPlaylists();
    homeShowLatestReleasesNotifier.value = getHomeShowLatestReleases();
    homeShowArtistMixesNotifier.value = getHomeShowArtistMixes();
    homeShowGenreMixesNotifier.value = getHomeShowGenreMixes();
    homeShowDailyPlaylistNotifier.value = getHomeShowDailyPlaylist();
    homeShowAiDailyNotifier.value = getHomeShowAiDaily();
    homeShowYandexSimilarNotifier.value = getHomeShowYandexSimilar();
    homeShowMyWaveShuffleNotifier.value = getHomeShowMyWaveShuffle();
    homeMyWaveAnimatedNotifier.value = getHomeMyWaveAnimated();
    homeMyWaveV2Notifier.value = getHomeMyWaveV2();
    homeMyWaveShowCountNotifier.value = getHomeMyWaveShowCount();
    final variant = getHomeMyWaveVariant();
    homeMyWaveVariantNotifier.value =
        (variant == 'v1' || variant == 'v3') ? variant : 'v2';
  }

  static const List<String> _kHomeAllKeys = [
    _keyHomeShowMyWave, _keyHomeShowMixes, _keyHomeShowRecent, _keyHomeShowPersonalized, _keyHomeShowYandex, _keyHomeShowGenre, _keyHomeShowAiMix,
    _keyHomeShowRecentlyPlayed, _keyHomeShowYourPlaylists, _keyHomeShowLatestReleases, _keyHomeShowArtistMixes, _keyHomeShowGenreMixes,     _keyHomeShowDailyPlaylist, _keyHomeShowYandexSimilar, _keyHomeShowMyWaveShuffle, _keyHomeMyWaveAnimated, _keyHomeMyWaveV2, _keyHomeShowAiDaily, _keyHomeMyWaveVariant,
  ];

  Future<void> resetHomeToLightDefaults() async {
    await initialize();
    await _prefs!.setBool(_keyHomeShowMyWave, true);
    for (final k in [_keyHomeShowMixes, _keyHomeShowRecent, _keyHomeShowPersonalized, _keyHomeShowYandex, _keyHomeShowGenre, _keyHomeShowAiMix, _keyHomeShowRecentlyPlayed, _keyHomeShowYourPlaylists, _keyHomeShowLatestReleases, _keyHomeShowArtistMixes, _keyHomeShowGenreMixes, _keyHomeShowDailyPlaylist, _keyHomeShowYandexSimilar, _keyHomeShowAiDaily]) {
      await _prefs!.setBool(k, false);
    }
    // Notifiers
    homeShowMyWaveNotifier.value = true;
    homeShowMixesNotifier.value = false;
    homeShowRecentNotifier.value = false;
    homeShowPersonalizedNotifier.value = false;
    homeShowYandexNotifier.value = false;
    homeShowGenreNotifier.value = false;
    homeShowAiMixNotifier.value = false;
    homeShowRecentlyPlayedNotifier.value = false;
    homeShowYourPlaylistsNotifier.value = false;
    homeShowLatestReleasesNotifier.value = false;
    homeShowArtistMixesNotifier.value = false;
    homeShowGenreMixesNotifier.value = false;
    homeShowDailyPlaylistNotifier.value = false;
    homeShowYandexSimilarNotifier.value = false;
    homeShowAiDailyNotifier.value = false;
  }

  Future<void> setShowVolumeSlider(bool show) async {
    await initialize();
    await _prefs!.setBool(_keyShowVolumeSlider, show);
  }

  bool getShowVolumeSlider() {
    return _prefs?.getBool(_keyShowVolumeSlider) ?? true;
  }

  Future<void> setShowStarRatings(bool show) async {
    await initialize();
    await _prefs!.setBool(_keyShowStarRatings, show);
    showStarRatingsNotifier.value = show;
  }

  bool getShowStarRatings() {
    return _prefs?.getBool(_keyShowStarRatings) ?? false;
  }

  Future<void> setShowMiniPlayerHeart(bool show) async {
    await initialize();
    await _prefs!.setBool(_keyShowMiniPlayerHeart, show);
    showMiniPlayerHeartNotifier.value = show;
  }

  bool getShowMiniPlayerHeart() {
    return _prefs?.getBool(_keyShowMiniPlayerHeart) ?? false;
  }

  Future<void> setShowMiniPlayerRepeat(bool show) async {
    await initialize();
    await _prefs!.setBool(_keyShowMiniPlayerRepeat, show);
    showMiniPlayerRepeatNotifier.value = show;
  }

  bool getShowMiniPlayerRepeat() {
    return _prefs?.getBool(_keyShowMiniPlayerRepeat) ?? false;
  }

  Future<void> setShowMiniPlayerShuffle(bool show) async {
    await initialize();
    await _prefs!.setBool(_keyShowMiniPlayerShuffle, show);
    showMiniPlayerShuffleNotifier.value = show;
  }

  bool getShowMiniPlayerShuffle() {
    return _prefs?.getBool(_keyShowMiniPlayerShuffle) ?? false;
  }

  Future<void> setMiniPlayerPcStyle(bool v) async {
    await initialize();
    await _prefs!.setBool(_keyMiniPlayerPcStyle, v);
    miniPlayerPcStyleNotifier.value = v;
  }

  bool getMiniPlayerPcStyle() {
    return _prefs?.getBool(_keyMiniPlayerPcStyle) ?? true;
  }

  Future<void> setAlbumArtCornerRadius(double radius) async {
    await initialize();
    await _prefs!.setDouble(_keyAlbumArtCornerRadius, radius);
    albumArtCornerRadiusNotifier.value = radius;
  }

  double getAlbumArtCornerRadius() {
    return _prefs?.getDouble(_keyAlbumArtCornerRadius) ?? 8.0;
  }

  Future<void> setArtworkShape(String shape) async {
    await initialize();
    await _prefs!.setString(_keyArtworkShape, shape);
    artworkShapeNotifier.value = shape;
  }

  String getArtworkShape() {
    return _prefs?.getString(_keyArtworkShape) ?? 'rounded';
  }

  Future<void> setArtworkShadow(String shadow) async {
    await initialize();
    await _prefs!.setString(_keyArtworkShadow, shadow);
    artworkShadowNotifier.value = shadow;
  }

  String getArtworkShadow() {
    return _prefs?.getString(_keyArtworkShadow) ?? 'soft';
  }

  Future<void> setArtworkShadowColor(String color) async {
    await initialize();
    await _prefs!.setString(_keyArtworkShadowColor, color);
    artworkShadowColorNotifier.value = color;
  }

  String getArtworkShadowColor() {
    return _prefs?.getString(_keyArtworkShadowColor) ?? 'black';
  }

  Future<void> setLiveSearch(bool enabled) async {
    await initialize();
    await _prefs!.setBool(_keyLiveSearch, enabled);
    liveSearchNotifier.value = enabled;
  }

  bool getLiveSearch() {
    return _prefs?.getBool(_keyLiveSearch) ?? true;
  }

  Future<void> setSwipeUpForQueue(bool enabled) async {
    await initialize();
    await _prefs!.setBool(_keySwipeUpForQueue, enabled);
    swipeUpForQueueNotifier.value = enabled;
  }

  bool getSwipeUpForQueue() {
    return _prefs?.getBool(_keySwipeUpForQueue) ?? true;
  }

  // Progress bar customization
  Future<void> setProgressBarColor(int color) async {
    await initialize();
    await _prefs!.setInt(_keyProgressBarColor, color);
    progressBarColorNotifier.value = color;
  }

  int getProgressBarColor() {
    return _prefs?.getInt(_keyProgressBarColor) ?? 0xFF4E8CA8;
  }

  Future<void> setProgressBarStyle(String style) async {
    await initialize();
    await _prefs!.setString(_keyProgressBarStyle, style);
    progressBarStyleNotifier.value = style;
  }

  String getProgressBarStyle() {
    return _prefs?.getString(_keyProgressBarStyle) ?? 'rounded';
  }

  Future<void> setProgressBarHeight(double height) async {
    await initialize();
    await _prefs!.setDouble(_keyProgressBarHeight, height);
    progressBarHeightNotifier.value = height;
  }

  double getProgressBarHeight() {
    return _prefs?.getDouble(_keyProgressBarHeight) ?? 4.0;
  }

  Future<void> setProgressBarAnimation(bool enabled) async {
    await initialize();
    await _prefs!.setBool(_keyProgressBarAnimation, enabled);
    progressBarAnimationNotifier.value = enabled;
  }

  bool getProgressBarAnimation() {
    return _prefs?.getBool(_keyProgressBarAnimation) ?? true;
  }

  Future<void> setProgressBarThumbVisible(bool v) async {
    await initialize();
    await _prefs!.setBool(_keyProgressBarThumbVisible, v);
    progressBarThumbVisibleNotifier.value = v;
  }

  bool getProgressBarThumbVisible() => _prefs?.getBool(_keyProgressBarThumbVisible) ?? true;

  Future<void> setProgressBarThumbSize(double s) async {
    await initialize();
    await _prefs!.setDouble(_keyProgressBarThumbSize, s);
    progressBarThumbSizeNotifier.value = s;
  }

  double getProgressBarThumbSize() => _prefs?.getDouble(_keyProgressBarThumbSize) ?? 10.0;

  Future<void> setProgressBarThumbColor(int c) async {
    await initialize();
    await _prefs!.setInt(_keyProgressBarThumbColor, c);
    progressBarThumbColorNotifier.value = c;
  }

  int getProgressBarThumbColor() => _prefs?.getInt(_keyProgressBarThumbColor) ?? 0xFFFFFFFF;

  Future<void> setProgressBarVariant(String v) async {
    await initialize();
    await _prefs!.setString(_keyProgressBarVariant, v);
    progressBarVariantNotifier.value = v;
  }

  String getProgressBarVariant() => _prefs?.getString(_keyProgressBarVariant) ?? 'kumaflow';

  Future<void> setHomeShowMyWave(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeShowMyWave, v); homeShowMyWaveNotifier.value = v; }
  bool getHomeShowMyWave() => _prefs?.getBool(_keyHomeShowMyWave) ?? true;
  Future<void> setHomeShowMixes(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeShowMixes, v); homeShowMixesNotifier.value = v; }
  bool getHomeShowMixes() => _prefs?.getBool(_keyHomeShowMixes) ?? false;
  Future<void> setHomeShowRecent(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeShowRecent, v); homeShowRecentNotifier.value = v; }
  bool getHomeShowRecent() => _prefs?.getBool(_keyHomeShowRecent) ?? false;
  Future<void> setHomeShowPersonalized(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeShowPersonalized, v); homeShowPersonalizedNotifier.value = v; }
  bool getHomeShowPersonalized() => _prefs?.getBool(_keyHomeShowPersonalized) ?? false;
  Future<void> setHomeShowYandex(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeShowYandex, v); homeShowYandexNotifier.value = v; }
  bool getHomeShowYandex() => _prefs?.getBool(_keyHomeShowYandex) ?? false;
  Future<void> setHomeShowGenre(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeShowGenre, v); homeShowGenreNotifier.value = v; }
  bool getHomeShowGenre() => _prefs?.getBool(_keyHomeShowGenre) ?? false;
  Future<void> setHomeShowAiMix(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeShowAiMix, v); homeShowAiMixNotifier.value = v; }
  bool getHomeShowAiMix() => _prefs?.getBool(_keyHomeShowAiMix) ?? false;
  Future<void> setHomeShowRecentlyPlayed(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeShowRecentlyPlayed, v); homeShowRecentlyPlayedNotifier.value = v; }
  bool getHomeShowRecentlyPlayed() => _prefs?.getBool(_keyHomeShowRecentlyPlayed) ?? false;
  Future<void> setHomeShowYourPlaylists(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeShowYourPlaylists, v); homeShowYourPlaylistsNotifier.value = v; }
  bool getHomeShowYourPlaylists() => _prefs?.getBool(_keyHomeShowYourPlaylists) ?? false;
  Future<void> setHomeShowLatestReleases(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeShowLatestReleases, v); homeShowLatestReleasesNotifier.value = v; }
  bool getHomeShowLatestReleases() => _prefs?.getBool(_keyHomeShowLatestReleases) ?? false;
  Future<void> setHomeShowArtistMixes(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeShowArtistMixes, v); homeShowArtistMixesNotifier.value = v; }
  bool getHomeShowArtistMixes() => _prefs?.getBool(_keyHomeShowArtistMixes) ?? false;
  Future<void> setHomeShowGenreMixes(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeShowGenreMixes, v); homeShowGenreMixesNotifier.value = v; }
  bool getHomeShowGenreMixes() => _prefs?.getBool(_keyHomeShowGenreMixes) ?? false;
  Future<void> setHomeShowDailyPlaylist(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeShowDailyPlaylist, v); homeShowDailyPlaylistNotifier.value = v; }
  bool getHomeShowDailyPlaylist() => _prefs?.getBool(_keyHomeShowDailyPlaylist) ?? false;
  Future<void> setHomeShowAiDaily(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeShowAiDaily, v); homeShowAiDailyNotifier.value = v; }
  bool getHomeShowAiDaily() => _prefs?.getBool(_keyHomeShowAiDaily) ?? false;
  Future<void> setHomeShowYandexSimilar(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeShowYandexSimilar, v); homeShowYandexSimilarNotifier.value = v; }
  bool getHomeShowYandexSimilar() => _prefs?.getBool(_keyHomeShowYandexSimilar) ?? false;
  Future<void> setHomeShowMyWaveShuffle(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeShowMyWaveShuffle, v); homeShowMyWaveShuffleNotifier.value = v; }
  bool getHomeShowMyWaveShuffle() => _prefs?.getBool(_keyHomeShowMyWaveShuffle) ?? false;
  Future<void> setHomeMyWaveAnimated(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeMyWaveAnimated, v); homeMyWaveAnimatedNotifier.value = v; }
  bool getHomeMyWaveAnimated() => _prefs?.getBool(_keyHomeMyWaveAnimated) ?? false;
  Future<void> setHomeMyWaveV2(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeMyWaveV2, v); homeMyWaveV2Notifier.value = v; }
  bool getHomeMyWaveV2() => _prefs?.getBool(_keyHomeMyWaveV2) ?? false;
  Future<void> setHomeMyWaveShowCount(bool v) async { await initialize(); await _prefs!.setBool(_keyHomeMyWaveShowCount, v); homeMyWaveShowCountNotifier.value = v; }
  bool getHomeMyWaveShowCount() => _prefs?.getBool(_keyHomeMyWaveShowCount) ?? true;
  Future<void> setHomeMyWaveVariant(String v) async {
    final safe = (v == 'v1' || v == 'v3') ? v : 'v2';
    await initialize();
    await _prefs!.setString(_keyHomeMyWaveVariant, safe);
    homeMyWaveVariantNotifier.value = safe;
  }
  String getHomeMyWaveVariant() => _prefs?.getString(_keyHomeMyWaveVariant) ?? 'v2';

  static const String _keyWaveFxPrefix = 'wave_fx_';
  bool getWaveFx(WaveMood m) =>
      _prefs?.getBool('$_keyWaveFxPrefix${m.name}') ?? true;
  Future<void> setWaveFx(WaveMood m, bool v) async {
    await initialize();
    await _prefs!.setBool('$_keyWaveFxPrefix${m.name}', v);
    waveFxVersionNotifier.value++;
  }

  Set<WaveMood> getWaveFxEnabled() => {
        for (final m in WaveMood.values)
          if (m != WaveMood.none && getWaveFx(m)) m
      };

  void dispose() {
    showStarRatingsNotifier.dispose();
    showMiniPlayerHeartNotifier.dispose();
    showMiniPlayerRepeatNotifier.dispose();
    showMiniPlayerShuffleNotifier.dispose();
    miniPlayerPcStyleNotifier.dispose();
    liveSearchNotifier.dispose();
    albumArtCornerRadiusNotifier.dispose();
    artworkShapeNotifier.dispose();
    artworkShadowNotifier.dispose();
    artworkShadowColorNotifier.dispose();
    swipeUpForQueueNotifier.dispose();
    progressBarColorNotifier.dispose();
    progressBarStyleNotifier.dispose();
    progressBarHeightNotifier.dispose();
    progressBarAnimationNotifier.dispose();
    progressBarThumbVisibleNotifier.dispose();
    progressBarThumbSizeNotifier.dispose();
    progressBarThumbColorNotifier.dispose();
    progressBarVariantNotifier.dispose();
    homeShowMyWaveNotifier.dispose();
    homeShowMixesNotifier.dispose();
    homeShowRecentNotifier.dispose();
    homeShowPersonalizedNotifier.dispose();
    homeShowYandexNotifier.dispose();
    homeShowGenreNotifier.dispose();
    homeShowAiMixNotifier.dispose();
    homeShowRecentlyPlayedNotifier.dispose();
    homeShowYourPlaylistsNotifier.dispose();
    homeShowLatestReleasesNotifier.dispose();
    homeShowArtistMixesNotifier.dispose();
    homeShowGenreMixesNotifier.dispose();
    homeShowDailyPlaylistNotifier.dispose();
    homeShowAiDailyNotifier.dispose();
    homeShowYandexSimilarNotifier.dispose();
    homeShowMyWaveShuffleNotifier.dispose();
    homeMyWaveAnimatedNotifier.dispose();
    homeMyWaveV2Notifier.dispose();
    homeMyWaveShowCountNotifier.dispose();
    homeMyWaveVariantNotifier.dispose();
    waveFxVersionNotifier.dispose();
  }
}
