import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/models.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/yandex_music_provider.dart';
import '../services/subsonic_service.dart';
import '../services/kumaflow_brain/kumaflow_brain_bridge.dart';
import '../services/wave_identity.dart';
import '../services/kumaflow_brain/kumaflow_brain_options.dart';
import '../services/kumaflow_brain/kumaflow_brain_settings.dart';
import '../services/kumaflow_brain/kumaflow_brain_wave_resolver.dart';
import '../services/recommendation_service.dart';
import '../services/storage_service.dart';
import '../services/theme_service.dart';
import '../services/yandex_music_service.dart';
import '../services/player_ui_settings_service.dart';
import '../services/ai_service.dart';
import '../services/ai_mix_service.dart';
import 'ai_daily_detail_screen.dart';
import '../services/audiobookshelf_service.dart';
import '../services/offline_service.dart';
import '../services/mix_cache_service.dart';
import '../widgets/sync_progress_banner.dart';
import '../widgets/arrivals_bell.dart';
import '../services/ml_service.dart';
import '../services/playlist_orchestrator.dart';
import '../services/ml/vibe_similarity.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/audiobook_helper.dart';
import 'audiobook_detail_screen.dart';
import '../theme/app_theme.dart';
import '../utils/navigation_helper.dart';
import '../widgets/widgets.dart';
import '../widgets/artist_collage_card.dart';
import '../widgets/yandex_playlists_section.dart';
import '../widgets/yandex_my_wave_section.dart';
import '../widgets/kumaflow_my_wave_hero.dart';
import '../widgets/kuma_hero_v2.dart';
import '../widgets/genre_carousel.dart';
import 'album_screen.dart';
import 'genre_playlist_screen.dart';
import 'sonar_screen.dart';
import 'remote_control_screen.dart';
import '../services/remote_control/remote_client.dart';
import '../services/remote_control/remote_discovery.dart';
import 'artist_screen.dart';
import 'playlist_screen.dart';
import 'history_screen.dart';
import '../l10n/app_localizations.dart';

/// Локализация названия микса (ключи сервиса стабильно английские).
String _localizedMixTitle(BuildContext context, String key) {
  final l10n = AppLocalizations.of(context)!;
  switch (key) {
    case 'Quick Picks':
      return l10n.quickPicks;
    case 'Discover Mix':
      return l10n.discoverMix;
    case 'Mood Mix':
      return l10n.moodMix;
    case 'Tempo Mix':
      return l10n.tempoMix;
    case 'Era Mix':
      return l10n.eraMix;
    case 'Deep Cut Mix':
      return l10n.deepCutMix;
    case 'Artist Fusion':
      return l10n.artistFusion;
    case 'Local Mix':
      return l10n.localMix;
    case 'Time of Day Mix':
      return l10n.timeOfDayMix;
    case 'My Wave':
      return l10n.myWave;
  }
  if (key.endsWith(' Mix') && key.length > 4) {
    return l10n.artistMixWithName(key.substring(0, key.length - 4));
  }
  if (key.endsWith(' Vibes') && key.length > 6) {
    return l10n.timeVibesWithName(key.substring(0, key.length - 6));
  }
  return key;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, List<Song>> _cachedMixes = const {};
  List<Song> _cachedPersonalized = const [];
  List<Song> _cachedMyWave = const [];
  // Генерация волны в полёте: hero рисует спиннер как на ПК (isGenerating).
  bool _waveGenerating = false;
  // Версия фильтров волны для hero-пилюль: +1 после закрытия «Настроить».
  int _waveFiltersVersion = 0;
  List<Song> _cachedAiMix = const [];
  String _cachedAiMixName = 'AI Mix';
  String _lastRandomKey = '';
  final Set<String> _collapsedSections = {};
  List<Song> _cachedDaily = const [];
  String _dailyCacheKey = '';
  bool _dailyLoading = false;
  Future<List<Map<String, dynamic>>>? _booksFuture;
  DateTime _booksFetchedAt = DateTime.fromMillisecondsSinceEpoch(0);

  String? _username;
  final ScrollController _scrollController = ScrollController();
  bool _showScrollToTop = false;
  DateTime _lastEnrichAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _loadUsername();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.offset > 300 && !_showScrollToTop) {
      setState(() => _showScrollToTop = true);
    } else if (_scrollController.offset <= 300 && _showScrollToTop) {
      setState(() => _showScrollToTop = false);
    }
  }

  void _scrollToTop() {
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOut,
    );
  }

  void _toggleSection(String sectionId) {
    setState(() {
      if (_collapsedSections.contains(sectionId)) {
        _collapsedSections.remove(sectionId);
      } else {
        _collapsedSections.add(sectionId);
      }
    });
  }

  /// Force regeneration of My Wave and personalized mixes.
  void _refreshMyWave() {
    setState(() {
      _lastRandomKey = '';
      _dailyCacheKey = '';
      _cachedDaily = const [];
    });
    MixCacheService().invalidateDaily();
  }

  void _showMyWaveCustomize(BuildContext ctx, List<Song> songs) {
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Theme.of(ctx).brightness == Brightness.dark ? const Color(0xFF1E1E1E) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      // Шторка больше не уезжает под статус-бар и гасится свайпом вниз:
      // DraggableScrollableSheet отдаёт скролл контенту, а свайп от верха —
      // закрытию. Плюс явный крестик (назад — не единственный выход).
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        snap: true,
        snapSizes: const [0.4, 0.85, 0.92],
        builder: (_, scrollCtrl) =>
            _MyWaveCustomizeSheet(songs: songs, scrollCtrl: scrollCtrl),
      ),
    ).then((_) {
      // Шторка закрыта — hero перезагружает пилюли фильтров из prefs.
      if (mounted) setState(() => _waveFiltersVersion++);
    });
  }

  String _dailyKeyFor(List<Song> pool, String bannedKey) {
    final date = DateTime.now().toIso8601String().substring(0, 10); // YYYY-MM-DD
    return 'daily:$date:$bannedKey:${pool.length}';
  }

  /// Автогенерация ежедневного ИИ-микса: срабатывает сама при смене суток.
  /// Раньше этот метод никто не вызывал (только ручная кнопка force:true),
  /// поэтому микс «не обновлялся». Фон, без setState — результат виден
  /// на экране ИИ-миксов через getLastDailyInfo().
  void _ensureAiDailyMix(List<Song> pool) {
    if (pool.isEmpty) return;
    unawaited(AiMixService().generateDailyAutoMix(library: pool).then((res) {
      if (res != null && mounted) {
        // Триггерим перестройку FutureBuilder'ов на экране ИИ-миксов при
        // следующем открытии; здесь setState не нужен.
        debugPrint('[Home] daily AI mix ready: ${res.name} • ${res.songs.length}');
      }
    }).catchError((e) {
      debugPrint('[Home] daily AI mix failed: $e');
    }));
  }

  void _ensureDailyPlaylist(List<Song> pool, RecommendationService rec) {
    final key = _dailyKeyFor(pool, rec.bannedArtistsKey);
    if (_dailyCacheKey == key && _cachedDaily.isNotEmpty) return;
    if (_dailyLoading) {
      // Ключ сменился (наступили сутки / изменился пул), а старая загрузка
      // ещё висит — её результат уже не нужен, разрешаем новый прогон.
      if (_dailyCacheKey == key) return;
    }
    _dailyLoading = true;
    _dailyCacheKey = key;
    final requestKey = key;
    MixCacheService().loadDailyMix(key, pool).then((cached) {
      if (!mounted || _dailyCacheKey != requestKey) return;
      if (cached != null && cached.isNotEmpty) {
        setState(() {
          _cachedDaily = cached;
          _dailyLoading = false;
        });
        return;
      }
      // generate fresh daily mix (20)
      final fresh = rec.getPersonalizedFeed(pool, limit: 20);
      MixCacheService().saveDailyMix(key, fresh);
      if (mounted && _dailyCacheKey == requestKey) {
        setState(() { _cachedDaily = fresh; _dailyLoading = false; });
      }
    }).catchError((_) {
      if (mounted && _dailyCacheKey == requestKey) {
        final fresh = rec.getPersonalizedFeed(pool, limit: 20);
        setState(() { _cachedDaily = fresh; _dailyLoading = false; });
      }
    });
  }

  Future<List<Map<String, dynamic>>> _getBooksFuture() {
    final off = OfflineService();
    if (off.isOfflineMode) {
      // Офлайн — возвращаем скачанные книги как continue listening
      _booksFuture = off.getDownloadedBooks().catchError((_) => <Map<String, dynamic>>[]);
      return _booksFuture!;
    }
    final now = DateTime.now();
    if (_booksFuture != null && now.difference(_booksFetchedAt).inMinutes < 5) {
      return _booksFuture!;
    }
    _booksFetchedAt = now;
    _booksFuture = AudiobookshelfService().fetchContinueListeningWithFallback().catchError((_) => <Map<String, dynamic>>[]);
    return _booksFuture!;
  }

  Future<void> _loadUsername() async {
    // Try saved username first
    final storage = StorageService();
    final name = await storage.getUsername();
    if (mounted && name != null && name.isNotEmpty) {
      setState(() => _username = name);
      return;
    }
    // Fallback: get from auth config
    if (mounted) {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final configName = authProvider.config?.username;
      if (configName != null && configName.isNotEmpty && configName != 'local') {
        setState(() => _username = configName);
        // Save for next time
        await storage.saveUsername(configName);
      }
    }
  }

  String _getGreeting() {
    final hour = DateTime.now().hour;
    final base = hour < 12
        ? AppLocalizations.of(context)!.goodMorning
        : hour < 17
            ? AppLocalizations.of(context)!.goodAfternoon
            : AppLocalizations.of(context)!.goodEvening;
    if (_username != null && _username!.isNotEmpty) {
      return '$base, $_username';
    }
    return base;
  }

  String _computeRandomKey(List<Song> songs) {
    if (songs.isEmpty) return '';

    return songs.map((s) => s.id).join('|');
  }

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isDesktop = _isDesktop;
    final hPad = isDesktop ? 32.0 : 16.0;

    // Get accent color from theme settings (listen: true to rebuild on change)
    final accentColor = context.select<ThemeService, Color>((t) => t.accentColor.color);
    final intensity = context.select<ThemeService, double>((t) => t.gradientIntensity);

    return Stack(
      children: [
        // Gradient background (outside Scaffold) - longer, more visible
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  accentColor.withValues(alpha: 0.5),
                  accentColor.withValues(alpha: 0.3),
                  accentColor.withValues(alpha: 0.15),
                  accentColor.withValues(alpha: 0.05),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.15, 0.35, 0.6, 1.0],
              ),
            ),
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          body: RefreshIndicator(
            onRefresh: () async {
              _refreshMyWave();
              // Also refresh library if needed
              await context.read<LibraryProvider>().refresh();
            },
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
              SliverToBoxAdapter(child: SyncProgressBanner()),
              SliverAppBar(
                pinned: true,
                floating: true,
                expandedHeight: isDesktop ? 64 : 56,
                collapsedHeight: isDesktop ? 64 : 56,
                backgroundColor: isDark
                    ? const Color(0xFF121212).withValues(alpha: 0.72)
                    : Colors.white.withValues(alpha: 0.82),
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 8,
                shadowColor: Colors.black.withValues(alpha: 0.35),
                flexibleSpace: ClipRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            accentColor.withValues(alpha: (isDark ? 0.40 : 0.20) * intensity),
                            accentColor.withValues(alpha: (isDark ? 0.16 : 0.08) * intensity),
                            (isDark ? Colors.black : Colors.white)
                                .withValues(alpha: 0.0),
                          ],
                          stops: const [0.0, 0.55, 1.0],
                        ),
                        border: Border(
                          bottom: BorderSide(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.08)
                                : Colors.black.withValues(alpha: 0.07),
                            width: 1,
                          ),
                        ),
                      ),
                      child: FlexibleSpaceBar(
                        titlePadding: EdgeInsets.only(left: hPad, bottom: 14, right: 56),
                        title: Text(
                          _getGreeting(),
                          style: TextStyle(
                            fontSize: isDesktop ? 22 : 18,
                            fontWeight: FontWeight.w800,
                            color: isDark ? Colors.white : Colors.black,
                            letterSpacing: -0.3,
                            shadows: [
                              Shadow(
                                color: Colors.black.withValues(alpha: isDark ? 0.65 : 0.22),
                                blurRadius: 12,
                                offset: const Offset(0, 1),
                              ),
                              if (isDark)
                                Shadow(
                                  color: Colors.black.withValues(alpha: 0.9),
                                  blurRadius: 20,
                                  offset: const Offset(0, 0),
                                ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ),
                actions: [
                  // Sonar: кнопка микрофона → редирект на страницу узнавания.
                  IconButton(
                    icon: Icon(
                      CupertinoIcons.mic_fill,
                      color: isDark ? Colors.white : Colors.black,
                      shadows: [
                        Shadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.6 : 0.15),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    onPressed: () {
                      NavigationHelper.push(context, const SonarScreen());
                    },
                  ),
                  IconButton(
                    icon: Icon(
                      CupertinoIcons.clock,
                      color: isDark ? Colors.white : Colors.black,
                      shadows: [
                        Shadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.6 : 0.15),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    onPressed: () {
                      NavigationHelper.push(context, const HistoryScreen());
                    },
                  ),
                  // Пульт: точка — найден/сохранён ПК рядом, акцент — подключено.
                  // Тап сразу открывает страницу управления.
                  Consumer2<RemoteDiscovery, RemoteClient>(
                    builder: (context, discovery, client, _) {
                      final connected = client.isConnected;
                      final hasDevices = discovery.found.isNotEmpty ||
                          discovery.saved.isNotEmpty;
                      final base =
                          isDark ? Colors.white : Colors.black;
                      final iconColor = connected
                          ? const Color(0xFF4E8CA8)
                          : base;
                      return Stack(
                        alignment: Alignment.topRight,
                        children: [
                          IconButton(
                            icon: Icon(
                              connected
                                  ? CupertinoIcons.desktopcomputer
                                  : CupertinoIcons.tv,
                              color: iconColor,
                              shadows: [
                                Shadow(
                                  color: Colors.black.withValues(
                                      alpha: isDark ? 0.6 : 0.15),
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                            tooltip: connected
                                ? 'Пульт · подключено'
                                : (hasDevices
                                    ? 'Пульт · ПК рядом'
                                    : 'Пульт · найти ПК'),
                            onPressed: () {
                              NavigationHelper.push(context,
                                  const RemoteControlScreen());
                            },
                          ),
                          if (!connected && hasDevices)
                            Positioned(
                              right: 10,
                              top: 10,
                              child: Container(
                                width: 9,
                                height: 9,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF4E8CA8),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          if (connected)
                            Positioned(
                              right: 10,
                              top: 10,
                              child: Container(
                                width: 9,
                                height: 9,
                                decoration: const BoxDecoration(
                                  color: Colors.green,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  if (isDesktop) const SizedBox(width: 8),
                  ArrivalsBell(
                      iconColor: isDark ? Colors.white : Colors.black),
                ],
              ),
          SliverToBoxAdapter(
            child: Consumer4<LibraryProvider, RecommendationService, YandexMusicProvider, MLService>(
              builder: (context, libraryProvider, recommendationService, yandexProvider, mlService, _) {
                if (libraryProvider.isLoading &&
                    !libraryProvider.isInitialized) {
                  return _buildLoadingState(isDesktop, hPad);
                }

                final allSongs = libraryProvider.randomSongs;
                final key = _computeRandomKey(allSongs) +
                    '|' +
                    recommendationService.bannedArtistsKey;

                if (recommendationService.enabled && key.isNotEmpty) {
                  if (key != _lastRandomKey) {
                    // В офлайне — только играемое (скачанное/локальное),
                    // иначе волна генерилась из серверных треков без файлов.
                    final sourceSongs = libraryProvider.isOfflineNow
                        ? libraryProvider.playablePool()
                        : (libraryProvider.cachedAllSongs.isNotEmpty
                            ? libraryProvider.cachedAllSongs
                            : allSongs);
                    var filteredSongs = libraryProvider.mergeLocalLibrary
                        ? sourceSongs
                        : sourceSongs.where((s) => !s.isLocal).toList();
                    // Fallback to source if filtering emptied the pool (e.g. only locals in DB)
                    if (filteredSongs.isEmpty && sourceSongs.isNotEmpty) {
                      filteredSongs = sourceSongs;
                    }
                    // Стадия 1 — волна сразу (дешёвая, 30 шт): hero играет мгновенно.
                    // Старые кэши не сбрасываем в пустоту — волна остаётся тапабельной.
                    // Стадия 2 — миксы только после синка, из синхронизированной БД.
                    final wavePool = List<Song>.from(filteredSongs);
                    final waveKey = key;
                    final libRef = libraryProvider;
                    final recRef = recommendationService;
                    final mlRef = mlService;
                    // Генерация волны со спиннером как на ПК (isGenerating):
                    // кадр N+1 рисует спиннер, тяжёлый скоринг — после его
                    // отрисовки (иначе спиннер не успевает показаться).
                    _waveGenerating = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      setState(() {});
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted || _lastRandomKey != waveKey) return;
                        final myWave = mlRef.generateLocalMyWave(
                          songs: wavePool,
                          count: 30,
                        );
                        if (!mounted || _lastRandomKey != waveKey) return;
                        setState(() {
                          _cachedMyWave = myWave;
                          _waveGenerating = false;
                        });
                      try {
                        MixCacheService().saveHome(
                          waveKey, const {}, const [], myWave);
                      } catch (_) {}
                      final myWaveIds = myWave.map((s) => s.id).toSet();
                      final remaining = wavePool.where((s) => !myWaveIds.contains(s.id)).toList();
                      final poolForMixes = remaining.length >= 15 ? remaining : wavePool;
                      // Персоналка асинхронно — убирает лаг 5с при тапе звезд.
                      final cachedPool = List<Song>.from(poolForMixes);
                      Future.microtask(() {
                        final feed = recRef.getPersonalizedFeed(cachedPool, limit: 10);
                        if (!mounted || _lastRandomKey != waveKey) return;
                        setState(() => _cachedPersonalized = feed);
                      });
                      // Миксы — только когда синк не пишет в БД.
                      Future(() async {
                        for (var i = 0; i < 90; i++) {
                          if (!mounted || _lastRandomKey != waveKey) return;
                          if (!libRef.isSyncing) break;
                          await Future.delayed(const Duration(seconds: 1));
                        }
                        if (!mounted || _lastRandomKey != waveKey) return;
                        if (libRef.isSyncing) return;
                        final freshPool = await libRef.getPoolForMix(limit: 700);
                        final pool = freshPool.length >= 15 ? freshPool : poolForMixes;
                        final mixes = pool.length >= 400
                            ? await recRef.generateMixesIsolated(pool)
                            : await recRef.generateMixes(pool);
                        if (!mounted || _lastRandomKey != waveKey) return;
                        setState(() => _cachedMixes = mixes);
                        try {
                          await MixCacheService().saveAllMixes(waveKey, mixes);
                        } catch (_) {}
                      });
                      });
                    });
                    // AI Mix: 12 diverse tracks under My Wave
                    if (PlayerUiSettingsService().getHomeShowAiMix()) {
                      final aiPool = List<Song>.from(filteredSongs)..shuffle();
                      final aiMix = <Song>[];
                      final seenAiArtists = <String>{};
                      for (final s in aiPool) {
                        if (s.artist != null && seenAiArtists.add(s.artist!.toLowerCase())) aiMix.add(s);
                        else if (s.artist == null) aiMix.add(s);
                        if (aiMix.length >= 12) break;
                      }
                      if (aiMix.length < 12) {
                        for (final s in aiPool) {
                          if (!aiMix.any((r) => r.id == s.id)) {
                            aiMix.add(s);
                            if (aiMix.length >= 12) break;
                          }
                        }
                      }
                      _cachedAiMix = aiMix;
                      _cachedAiMixName = 'AI Mix';
                      if (aiMix.isNotEmpty && AiService().isConfigured) {
                        final ai = AiService();
                        Future(() async {
                          try {
                            final aiName = await ai.generateMixName(aiMix, hint: 'AI mix');
                            if (mounted && _lastRandomKey == key && aiName.isNotEmpty) {
                              setState(() => _cachedAiMixName = aiName);
                            }
                          } catch (_) {}
                        });
                      }
                    } else {
                      _cachedAiMix = const [];
                      _cachedAiMixName = 'AI Mix';
                    }
                    _lastRandomKey = key;
                    // Ежедневный ИИ-микс: раньше generateDailyAutoMix никто не
                    // вызывал автоматически (только кнопка force:true), поэтому
                    // «следующий день» никогда не наступал. Пианим фоном —
                    // внутри self-guard через shouldGenerateDaily (раз в сутки).
                    _ensureAiDailyMix(filteredSongs);
                  }
                } else {
                  _cachedMixes = const {};
                  _cachedPersonalized = const [];
                  _cachedMyWave = const [];
                  _waveGenerating = false;
                  _cachedAiMix = const [];
                  _cachedAiMixName = 'AI Mix';
                  _lastRandomKey = '';
                }

                final mixes = _cachedMixes;
                final personalizedFeed = _cachedPersonalized;
                final myWaveSongs = _cachedMyWave;

                // Фоновая Yandex-обогащение — троттлим до 1 раза в 60с, иначе каждый build спамит getAlbum (лог Enrich skip)
                if (libraryProvider.cachedAllSongs.isNotEmpty &&
                    DateTime.now().difference(_lastEnrichAt).inSeconds > 60) {
                  _lastEnrichAt = DateTime.now();
                  Future.microtask(() {
                    mlService.enrichMissingGenres(libraryProvider.cachedAllSongs, limit: 15);
                  });
                }

                return Padding(
                  padding: EdgeInsets.symmetric(horizontal: isDesktop ? 0 : 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Hero: Моя волна. V1 (KION) и V2 (как на ПК) — независимые
                      // тумблеры: выключенный KION больше не гасит V2.
                      if (libraryProvider.randomSongs.isNotEmpty)
                        ListenableBuilder(
                          listenable: Listenable.merge([
                            PlayerUiSettingsService().homeMyWaveV2Notifier,
                            PlayerUiSettingsService().homeShowMyWaveNotifier,
                          ]),
                          builder: (lctx, __) {
                            final ui = PlayerUiSettingsService();
                            final v1 = ui.getHomeShowMyWave();
                            final v2 = ui.getHomeMyWaveV2();
                            if (!v1 && !v2) {
                              return const SizedBox.shrink();
                            }
                            final subsonicService =
                                Provider.of<SubsonicService>(lctx, listen: false);
                            final displaySongs = myWaveSongs.isNotEmpty
                                ? myWaveSongs
                                : libraryProvider.randomSongs;
                            void playWave() {
                              final player = lctx.read<PlayerProvider>();
                              final curId = player.currentSong?.id;
                              // Волна активна — по имени очереди как на ПК
                              // (continue/resume подменяет очередь, трека уже
                              // может не быть в hero-списке).
                              final isWavePlaying = isWavePlayingNow(
                                isPlaying: player.isPlaying,
                                currentSongId: curId,
                                heroIds: [for (final s in displaySongs) s.id],
                                queueName: player.currentQueueName,
                              );
                              if (isWavePlaying) {
                                player.pause();
                                return;
                              }
                              if (player.currentSong != null && displaySongs.any((s) => s.id == curId)) {
                                player.togglePlayPause();
                                return;
                              }
                              // Обычная волна гасит сид (десктоп clearWaveSeed).
                              clearWaveSeed();
                              saveWaveContext(
                                  displaySongs.map((s) => s.id).toList(),
                                  '',
                                  'local');
                              final randomIndex = (displaySongs.length > 1) ? (DateTime.now().millisecondsSinceEpoch % displaySongs.length) : 0;
                              player.playSong(
                                  displaySongs[randomIndex],
                                  playlist: displaySongs,
                                  startIndex: randomIndex,
                                  playlistName: 'Моя волна',
                                  isWave: true);
                            }

                            void shuffleWave() {
                              final songs = List<Song>.from(displaySongs)..shuffle();
                              clearWaveSeed();
                              saveWaveContext(
                                  songs.map((s) => s.id).toList(), '', 'local');
                              lctx.read<PlayerProvider>().playSong(
                                  songs.first,
                                  playlist: songs,
                                  playlistName: 'Моя волна',
                                  isWave: true);
                            }

                            String? coverFor(List<Song> songs) =>
                                songs.isNotEmpty
                                    ? subsonicService.getCoverArtUrl(
                                        songs.first.coverArt ?? '',
                                        size: 600,
                                      )
                                    : null;

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 16),
                                // Заголовок секции — только у V1 (у V2 как на ПК
                                // его нет: приветствие отдельно, hero самодостаточен).
                                if (v1)
                                  _SectionTitle(
                                    title: 'Моя волна',
                                    subtitle: 'Персональный микс',
                                    icon: Icons.waves_rounded,
                                    hPad: hPad,
                                    trailing: IconButton(
                                      icon: const Icon(Icons.refresh_rounded, size: 20),
                                      tooltip: 'Обновить волну',
                                      onPressed: _refreshMyWave,
                                    ),
                                  ),
                                if (v2)
                                  Consumer<PlayerProvider>(
                                    builder: (pctx, player, __) {
                                      final cur = player.currentSong;
                                      return KumaHeroV2(
                                        songs: displaySongs,
                                        filtersVersion: _waveFiltersVersion,
                                        coverUrl: coverFor(displaySongs),
                                        isGenerating: _waveGenerating,
                                        currentCoverArt: cur?.coverArt,
                                        currentGenre: cur?.genre,
                                        onPlay: playWave,
                                        onShuffle: shuffleWave,
                                        onCustomize: () =>
                                            _showMyWaveCustomize(lctx, displaySongs),
                                      );
                                    },
                                  )
                                else
                                  KumaFlowMyWaveHero(
                                    songs: displaySongs,
                                    filtersVersion: _waveFiltersVersion,
                                    coverUrl: coverFor(displaySongs),
                                    isGenerating: _waveGenerating,
                                    onPlay: playWave,
                                    onShuffle: shuffleWave,
                                    onCustomize: () =>
                                        _showMyWaveCustomize(lctx, displaySongs),
                                  ),
                              ],
                            );
                          },
                        ),
                      // AI Mix carousel — теперь независим от Моя волна
                      if (PlayerUiSettingsService().getHomeShowAiMix() && _cachedAiMix.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _SectionTitle(
                          title: _cachedAiMixName,
                          subtitle: 'ИИ подборка',
                          icon: Icons.auto_awesome_rounded,
                          hPad: hPad,
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 160,
                          child: ListView.separated(
                            padding: EdgeInsets.symmetric(horizontal: hPad),
                            scrollDirection: Axis.horizontal,
                            itemCount: _cachedAiMix.length,
                            separatorBuilder: (_, __) => const SizedBox(width: 12),
                            itemBuilder: (ctx, i) {
                              final song = _cachedAiMix[i];
                              final subsonic = Provider.of<SubsonicService>(ctx, listen: false);
                              final cover = subsonic.getCoverArtUrl(song.coverArt ?? '', size: 300);
                              return GestureDetector(
                                onTap: () => ctx.read<PlayerProvider>().playSong(song, playlist: _cachedAiMix, startIndex: i),
                                child: SizedBox(
                                  width: 120,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(12),
                                        child: cover.isNotEmpty
                                            ? CachedNetworkImage(imageUrl: cover, width: 120, height: 120, fit: BoxFit.cover, errorWidget: (_, __, ___) => Container(width: 120, height: 120, color: Colors.grey[800], child: const Icon(Icons.music_note, color: Colors.white54)))
                                            : Container(width: 120, height: 120, color: Colors.grey[800], child: const Icon(Icons.music_note, color: Colors.white54)),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                                      Text(song.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],

                      // Yandex My Wave section — только при включённой интеграции.
                      if (PlayerUiSettingsService().getHomeShowYandex() &&
                          yandexProvider.isEnabled) ...[
                        const SizedBox(height: 16),
                        YandexMyWaveSection(
                          hPad: hPad,
                          isDesktop: isDesktop,
                        ),
                      ],

                      // Genre carousel — независим от Моя волна
                      if (PlayerUiSettingsService().getHomeShowGenre()) ...[
                        const SizedBox(height: 24),
                        GenreCarousel(
                          hPad: hPad,
                          isDesktop: isDesktop,
                          onGenreTap: (genreId, genreName, color) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => GenrePlaylistScreen(
                                  genreId: genreId,
                                  genreName: genreName,
                                  genreColor: color,
                                ),
                              ),
                            );
                          },
                        ),
                      ],

                      // Continue Listening — Books (outside MyWave)
                      ValueListenableBuilder<bool>(
                        valueListenable: AudiobookshelfService().enabledNotifier,
                        builder: (ctx, absEnabled, __) {
                          if (!absEnabled || !AudiobookshelfService().isConfigured) return const SizedBox.shrink();
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 16),
                              _SectionTitle(
                                title: 'Продолжить слушать',
                                subtitle: 'Книги',
                                icon: Icons.menu_book_rounded,
                                hPad: hPad,
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 170,
                                child: FutureBuilder<List<Map<String, dynamic>>>(
                                  future: _getBooksFuture(),
                                  builder: (ctx, snap) {
                                    if (snap.connectionState == ConnectionState.waiting) {
                                      return const Center(child: CircularProgressIndicator());
                                    }
                                    final books = snap.data ?? [];
                                    if (books.isEmpty) {
                                      return const Center(child: Text('Нет книг в прогрессе', style: TextStyle(fontSize: 12, color: Colors.grey)));
                                    }
                                    return ListView.separated(
                                      padding: EdgeInsets.symmetric(horizontal: hPad),
                                      scrollDirection: Axis.horizontal,
                                      itemCount: books.length,
                                      separatorBuilder: (_, __) => const SizedBox(width: 12),
                                      itemBuilder: (c, i) {
                                        final b = books[i];
                                        final id = b['id'] as String? ?? b['libraryItemId'] as String? ?? '';
                                        final media = b['media'] ?? b['libraryItem']?['media'];
                                        final title = media?['metadata']?['title'] ?? b['media']?['metadata']?['title'] ?? b['title'] ?? 'Unknown';
                                        final author = media?['metadata']?['authorName'] ?? b['media']?['metadata']?['authorName'] ?? '';
                                        final cover = AudiobookshelfService().getCoverUrl(id, width: 200);
                                        final headers = AudiobookshelfService().authHeaders;
                                        // Robust progress extraction
                                        double progRaw = 0;
                                        bool isFinishedRaw = false;
                                        double curTime = 0;
                                        double durForCur = 0;
                                        try {
                                          durForCur = (media?['duration'] as num?)?.toDouble() ?? (b['media']?['duration'] as num?)?.toDouble() ?? 0;
                                          final embedded = b['userMediaProgress'] as Map<String, dynamic>?;
                                          if (embedded != null) {
                                            progRaw = (embedded['progress'] as num?)?.toDouble() ?? 0;
                                            isFinishedRaw = embedded['isFinished'] as bool? ?? false;
                                            curTime = (embedded['currentTime'] as num?)?.toDouble() ?? 0;
                                            if (durForCur > 0 && progRaw == 0 && curTime > 0) progRaw = (curTime / durForCur).clamp(0,1).toDouble();
                                            if (curTime == 0 && progRaw > 0 && durForCur > 0) curTime = progRaw * durForCur;
                                            if (curTime == 0 && progRaw == 0) {
                                              // Try alternative currentTime location
                                              curTime = (b['progress'] as num?)?.toDouble() ?? 0;
                                              if (curTime > 0 && curTime <= 1 && durForCur > 0) { progRaw = curTime; curTime = progRaw * durForCur; }
                                            }
                                          }
                                          if (progRaw == 0) {
                                            progRaw = (b['progress'] as num?)?.toDouble() ?? 0;
                                            if (progRaw > 0 && curTime == 0 && durForCur > 0) curTime = progRaw * durForCur;
                                          }
                                        } catch (_) {}
                                        final isFinished = isFinishedRaw || progRaw >= 0.99;
                                        final prog = progRaw.clamp(0, 1).toDouble();
                                        return SizedBox(
                                          width: 130,
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Stack(
                                                children: [
                                                  GestureDetector(
                                                    onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => AudiobookDetailScreen(itemId: id, initialData: b))),
                                                    child: ClipRRect(
                                                      borderRadius: BorderRadius.circular(12),
                                                      child: cover.isNotEmpty
                                                          ? CachedNetworkImage(imageUrl: cover, httpHeaders: headers, width: 130, height: 110, fit: BoxFit.cover, errorWidget: (_, __, ___) => Container(width: 130, height: 110, color: Colors.grey[800], child: const Icon(Icons.menu_book, color: Colors.white54)))
                                                          : Container(width: 130, height: 110, color: Colors.grey[800], child: const Icon(Icons.menu_book, color: Colors.white54)),
                                                    ),
                                                  ),
                                                  Positioned(
                                                    bottom: 6,
                                                    right: 6,
                                                    child: Material(
                                                      color: Theme.of(c).colorScheme.primary,
                                                      elevation: 4,
                                                      shape: const CircleBorder(),
                                                      child: InkWell(
                                                        customBorder: const CircleBorder(),
                                                        onTap: () async {
                                                          final messenger = ScaffoldMessenger.of(c);
                                                          try {
                                                            // Use curTime if >5 sec, else try to derive from progress
                                                            double st = curTime;
                                                            if (st == 0 && prog > 0 && durForCur > 0) st = prog * durForCur;
                                                            // If still 0 and book has progress, pass null to let helper fetch fresh progress
                                                            final double? toPass = st > 5 ? st : null;
                                                            if (toPass != null) {
                                                              await AudiobookHelper.playBook(c, id, b, startTime: toPass);
                                                            } else {
                                                              await AudiobookHelper.playBook(c, id, b);
                                                            }
                                                          } catch (e) {
                                                            messenger.showSnackBar(SnackBar(content: Text('Ошибка: $e')));
                                                          }
                                                        },
                                                        child: const Padding(padding: EdgeInsets.all(10), child: Icon(Icons.play_arrow_rounded, size: 28, color: Colors.white)),
                                                      ),
                                                    ),
                                                  ),
                                                  Positioned(
                                                    top: 4,
                                                    right: 4,
                                                    child: PopupMenuButton<String>(
                                                      padding: EdgeInsets.zero,
                                                      icon: Container(padding: const EdgeInsets.all(4), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.more_horiz, size: 12, color: Colors.white)),
                                                      onSelected: (v) async {
                                                        if (v == 'detail') Navigator.push(c, MaterialPageRoute(builder: (_) => AudiobookDetailScreen(itemId: id, initialData: b)));
                                                        if (v == 'download') {
                                                          final svc = AudiobookshelfService();
                                                          final detail = await svc.fetchBookDetail(id) ?? b;
                                                          final files = svc.getAudioFiles(detail);
                                                          final off = OfflineService(); await off.init();
                                                          await off.downloadBook(itemId: id, audioFiles: files, baseUrl: svc.getUrl(), token: svc.getToken());
                                                          if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('Книга скачана')));
                                                        }
                                                        if (v == 'delete') {
                                                          final off = OfflineService(); await off.init(); await off.deleteBook(id);
                                                          if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('Кэш удалён')));
                                                        }
                                                      },
                                                      itemBuilder: (_) => const [
                                                        PopupMenuItem(value: 'detail', child: Text('Подробнее')),
                                                        PopupMenuItem(value: 'download', child: Text('Скачать')),
                                                        PopupMenuItem(value: 'delete', child: Text('Удалить кэш')),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 6),
                                              Text(title.toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                                              Text(author.toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                                              if (prog > 0) Padding(padding: const EdgeInsets.only(top: 4), child: LinearProgressIndicator(value: prog, minHeight: 2, backgroundColor: Colors.grey[300], valueColor: AlwaysStoppedAnimation(isFinished ? Colors.green : Theme.of(c).colorScheme.primary))),
                                              if (isFinished) const Padding(padding: EdgeInsets.only(top: 2), child: Text('Завершено', style: TextStyle(fontSize: 9, color: Colors.green))),
                                            ],
                                          ),
                                        );
                                      },
                                    );
                                  },
                                ),
                              ),
                            ],
                          );
                        },
                      ),

                      if (PlayerUiSettingsService().getHomeShowRecent()) ...[
                        Builder(builder: (ctx) {
                          final off = OfflineService();
                          final isOffline = off.isOfflineMode;
                          final playlists = isOffline
                              ? libraryProvider.playlists.where((p) => off.isPlaylistDownloaded(p.id)).toList()
                              : libraryProvider.playlists;
                          final albums = libraryProvider.recentAlbums;
                          if (isOffline && playlists.isEmpty && albums.isEmpty) return const SizedBox.shrink();
                          if (!isOffline && albums.isEmpty && playlists.isEmpty) return const SizedBox.shrink();
                          return Column(children: [
                            const SizedBox(height: 16),
                            _QuickAccessGrid(
                              albums: albums.take(isDesktop ? 6 : 4).toList(),
                              playlists: playlists.take(isDesktop ? 3 : 2).toList(),
                              isDesktop: isDesktop,
                              hPad: hPad,
                            ),
                          ]);
                        }),
                      ],

                      const SizedBox(height: 24),

                      // Favorite Playlists перенесены в Миксы (home разгрузка, визуальная иерархия)
                      // const FavoritePlaylistsSection() — теперь в mixes_screen.dart

                      // Yandex Music Playlists Section — только при интеграции.
                      if (PlayerUiSettingsService().getHomeShowYandex() &&
                          yandexProvider.isEnabled)
                        YandexPlaylistsSection(
                          hPad: hPad,
                          isDesktop: isDesktop,
                        ),
                      if (PlayerUiSettingsService().getHomeShowYandex() &&
                          yandexProvider.isEnabled)
                        const SizedBox(height: 24),

                      if (PlayerUiSettingsService().getHomeShowPersonalized() &&
                          recommendationService.enabled &&
                          personalizedFeed.isNotEmpty) ...[
                        _SectionTitle(
                          title: AppLocalizations.of(context)!.forYou,
                          icon: Icons.stars_rounded,
                          hPad: hPad,
                          isCollapsed: _collapsedSections.contains('forYou'),
                          onToggle: () => _toggleSection('forYou'),
                        ),
                        if (!_collapsedSections.contains('forYou')) ...[
                          if (isDesktop) _DesktopSongTableHeader(hPad: hPad),
                          ...personalizedFeed.take(5).map((song) {
                            if (isDesktop) {
                              return _DesktopSongRow(
                                song: song,
                                playlist: personalizedFeed,
                                index: personalizedFeed.indexOf(song),
                                hPad: hPad,
                              );
                            }
                            return SongTile(
                              song: song,
                              playlist: personalizedFeed,
                              index: personalizedFeed.indexOf(song),
                              showAlbum: true,
                            );
                          }),
                        ],
                        const SizedBox(height: 24),
                      ],

                      if (PlayerUiSettingsService().getHomeShowMixes() && mixes.containsKey('Quick Picks')) ...[
                        _SectionTitle(
                          title: AppLocalizations.of(context)!.quickPicks,
                          icon: Icons.bolt_rounded,
                          hPad: hPad,
                          isCollapsed: _collapsedSections.contains('quickPicks'),
                          onToggle: () => _toggleSection('quickPicks'),
                        ),
                        if (!_collapsedSections.contains('quickPicks')) ...[
                          if (isDesktop) _DesktopSongTableHeader(hPad: hPad),
                          ...mixes['Quick Picks']!.take(5).map((song) {
                            if (isDesktop) {
                              return _DesktopSongRow(
                                song: song,
                                playlist: mixes['Quick Picks']!,
                                index: mixes['Quick Picks']!.indexOf(song),
                                hPad: hPad,
                              );
                            }
                            return SongTile(
                              song: song,
                              playlist: mixes['Quick Picks']!,
                              index: mixes['Quick Picks']!.indexOf(song),
                              showAlbum: true,
                            );
                          }),
                        ],
                        const SizedBox(height: 24),
                      ],

                      if (PlayerUiSettingsService().getHomeShowMixes() && mixes.containsKey('Discover Mix')) ...[
                        _SectionTitle(
                          title: AppLocalizations.of(context)!.discoverMix,
                          icon: Icons.explore_rounded,
                          hPad: hPad,
                          isCollapsed: _collapsedSections.contains('discoverMix'),
                          onToggle: () => _toggleSection('discoverMix'),
                        ),
                        if (!_collapsedSections.contains('discoverMix')) ...[
                          if (isDesktop) _DesktopSongTableHeader(hPad: hPad),
                          ...mixes['Discover Mix']!.take(5).map((song) {
                            if (isDesktop) {
                              return _DesktopSongRow(
                                song: song,
                                playlist: mixes['Discover Mix']!,
                                index: mixes['Discover Mix']!.indexOf(song),
                                hPad: hPad,
                              );
                            }
                            return SongTile(
                              song: song,
                              playlist: mixes['Discover Mix']!,
                              index: mixes['Discover Mix']!.indexOf(song),
                              showAlbum: true,
                            );
                          }),
                        ],
                        const SizedBox(height: 24),
                      ],

                      if (PlayerUiSettingsService().getHomeShowMixes())
                        for (final entry in mixes.entries.where(
                          (e) =>
                              e.key != 'Quick Picks' &&
                              e.key != 'Discover Mix' &&
                              !e.key.contains('Vibes'),
                        )) ...[
                        _SectionTitle(
                          title: _localizedMixTitle(context, entry.key),
                          icon: Icons.album_rounded,
                          hPad: hPad,
                        ),
                        if (isDesktop) _DesktopSongTableHeader(hPad: hPad),
                        ...entry.value.take(5).map((song) {
                          if (isDesktop) {
                            return _DesktopSongRow(
                              song: song,
                              playlist: entry.value,
                              index: entry.value.indexOf(song),
                              hPad: hPad,
                            );
                          }
                          return SongTile(
                            song: song,
                            playlist: entry.value,
                            index: entry.value.indexOf(song),
                            showAlbum: true,
                          );
                        }),
                        const SizedBox(height: 24),
                      ],

                      if (PlayerUiSettingsService().getHomeShowMixes())
                        for (final entry in mixes.entries.where(
                          (e) => e.key.contains('Vibes'),
                        )) ...[
                        _SectionTitle(
                          title: _localizedMixTitle(context, entry.key),
                          icon: Icons.nightlight_round,
                          hPad: hPad,
                        ),
                        if (isDesktop) _DesktopSongTableHeader(hPad: hPad),
                        ...entry.value.take(5).map((song) {
                          if (isDesktop) {
                            return _DesktopSongRow(
                              song: song,
                              playlist: entry.value,
                              index: entry.value.indexOf(song),
                              hPad: hPad,
                            );
                          }
                          return SongTile(
                            song: song,
                            playlist: entry.value,
                            index: entry.value.indexOf(song),
                            showAlbum: true,
                          );
                        }),
                        const SizedBox(height: 24),
                      ],

                      if (PlayerUiSettingsService().getHomeShowRecentlyPlayed() && libraryProvider.recentAlbums.isNotEmpty) ...[
                        HorizontalScrollSection(
                          title: AppLocalizations.of(context)!.recentlyPlayed,
                          padding: EdgeInsets.symmetric(horizontal: hPad),
                          cardSize: isDesktop ? 180 : 150,
                          children: libraryProvider.recentAlbums
                              .take(10)
                              .map(
                                (album) => AlbumCard(
                                  album: album,
                                  size: isDesktop ? 180 : 150,
                                  onTap: () => _openAlbum(context, album.id),
                                ),
                              )
                              .toList(),
                        ),
                        const SizedBox(height: 24),
                      ],

                      if (PlayerUiSettingsService().getHomeShowYourPlaylists() && libraryProvider.playlists.isNotEmpty) ...[
                        HorizontalScrollSection(
                          title: AppLocalizations.of(context)!.yourPlaylists,
                          padding: EdgeInsets.symmetric(horizontal: hPad),
                          cardSize: isDesktop ? 180 : 150,
                          children: libraryProvider.playlists
                              .take(10)
                              .map(
                                (playlist) => _PlaylistCard(
                                  playlist: playlist,
                                  size: isDesktop ? 180 : 150,
                                  onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => PlaylistScreen(
                                        playlistId: playlist.id,
                                        playlistName: playlist.name,
                                      ),
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                        const SizedBox(height: 24),
                      ],

                      // === NEW SECTIONS ===

                      // Latest Releases
                      if (PlayerUiSettingsService().getHomeShowLatestReleases() && libraryProvider.randomSongs.isNotEmpty) ...[
                        _SectionTitle(
                          title: 'Последние релизы',
                          icon: Icons.new_releases_rounded,
                          hPad: hPad,
                        ),
                        _LatestReleasesSection(
                          libraryProvider: libraryProvider,
                          hPad: hPad,
                        ),
                        const SizedBox(height: 24),
                      ],

                      // Artist Mixes (Radio by Artist)
                      if (PlayerUiSettingsService().getHomeShowArtistMixes() &&
                          recommendationService.enabled &&
                          libraryProvider.randomSongs.isNotEmpty) ...[
                        _SectionTitle(
                          title: 'Миксы по исполнителям',
                          subtitle: 'Похожее на треки артиста',
                          icon: Icons.wifi_tethering_rounded,
                          hPad: hPad,
                        ),
                        _ArtistMixesSection(
                          recommendationService: recommendationService,
                          hPad: hPad,
                        ),
                        const SizedBox(height: 24),
                      ],

                      // Genre Mixes
                      if (PlayerUiSettingsService().getHomeShowGenreMixes() && libraryProvider.cachedAllSongs.isNotEmpty) ...[
                        _SectionTitle(
                          title: 'Миксы по жанрам',
                          subtitle: 'Начните с этого',
                          icon: Icons.library_music_rounded,
                          hPad: hPad,
                          isCollapsed: _collapsedSections.contains('genreMixes'),
                          onToggle: () => _toggleSection('genreMixes'),
                        ),
                        if (!_collapsedSections.contains('genreMixes'))
                          _GenreMixesSection(
                            songs: libraryProvider.cachedAllSongs,
                            hPad: hPad,
                          ),
                        const SizedBox(height: 24),
                      ],

                      // Daily Playlist — с кэшем 24ч по дате (MixCacheService)
                      if (PlayerUiSettingsService().getHomeShowDailyPlaylist() &&
                          recommendationService.enabled &&
                          libraryProvider.randomSongs.isNotEmpty) ...[
                        _SectionTitle(
                          title: 'Плейлист дня',
                          subtitle: 'На основе ваших предпочтений',
                          icon: Icons.calendar_today_rounded,
                          hPad: hPad,
                          isCollapsed: _collapsedSections.contains('dailyPlaylist'),
                          onToggle: () => _toggleSection('dailyPlaylist'),
                        ),
                        if (!_collapsedSections.contains('dailyPlaylist'))
                          Builder(builder: (ctx) {
                            final pool = libraryProvider.cachedAllSongs.isNotEmpty
                                ? libraryProvider.cachedAllSongs
                                : libraryProvider.randomSongs;
                            _ensureDailyPlaylist(pool, recommendationService);
                            // Было: getPersonalizedFeed() на КАЖДЫЙ build — тяжёлый
                            // скоринг всей библиотеки (лаг) + jitter, т.е. список
                            // прыгал при каждой перестройке. Пока кэш грузится —
                            // стабильный срез пула, затем _cachedDaily.
                            final dailySongs = _cachedDaily.isNotEmpty
                                ? _cachedDaily
                                : pool.take(20).toList();
                            return _DailyPlaylistSection(songs: dailySongs, hPad: hPad);
                          }),
                        const SizedBox(height: 24),
                      ],

                      // ИИ-микс дня — ежедневный микс от нейросети.
                      // Тумблер: Настройки → Оформление → Главная → «ИИ-микс дня».
                      // Тап — детали (слушать/сохранить/обновить); новый
                      // несохранённый стирает предыдущий, сохранённые живут
                      // в Плейлистах сами по себе.
                      if (PlayerUiSettingsService().getHomeShowAiDaily()) ...[
                        _SectionTitle(
                          title: 'ИИ-микс дня',
                          subtitle: 'Ежедневный микс от нейросети',
                          icon: Icons.auto_awesome_rounded,
                          hPad: hPad,
                          isCollapsed: _collapsedSections.contains('aiDaily'),
                          onToggle: () => _toggleSection('aiDaily'),
                        ),
                        if (!_collapsedSections.contains('aiDaily'))
                          _AiDailyHomeCard(hPad: hPad),
                        const SizedBox(height: 24),
                      ],

                      // Yandex Music: Similar Artists
                      if (PlayerUiSettingsService().getHomeShowYandexSimilar() &&
                          yandexProvider.isEnabled &&
                          yandexProvider.hasToken &&
                          libraryProvider.artists.isNotEmpty) ...[
                        _SectionTitle(
                          title: 'Похожие исполнители',
                          subtitle: 'из Yandex Music',
                          icon: Icons.explore_rounded,
                          hPad: hPad,
                        ),
                        _YandexSimilarArtistsSection(
                          artists: libraryProvider.artists,
                          hPad: hPad,
                        ),
                        const SizedBox(height: 24),
                      ],

                      if (!recommendationService.enabled &&
                          libraryProvider.randomSongs.isNotEmpty) ...[
                        _SectionTitle(
                          title: AppLocalizations.of(context)!.madeForYou,
                          hPad: hPad,
                        ),
                        if (isDesktop) _DesktopSongTableHeader(hPad: hPad),
                        ...libraryProvider.randomSongs.take(5).map((song) {
                          final index = libraryProvider.randomSongs.indexOf(
                            song,
                          );
                          if (isDesktop) {
                            return _DesktopSongRow(
                              song: song,
                              playlist: libraryProvider.randomSongs,
                              index: index,
                              hPad: hPad,
                            );
                          }
                          return SongTile(
                            song: song,
                            playlist: libraryProvider.randomSongs,
                            index: index,
                            showAlbum: true,
                          );
                        }),
                        const SizedBox(height: 24),
                      ],

                      if (libraryProvider.recentAlbums.isEmpty &&
                          libraryProvider.playlists.isEmpty &&
                          libraryProvider.randomSongs.isEmpty &&
                          mixes.isEmpty) ...[
                        const SizedBox(height: 48),
                        Center(
                          child: Column(
                            children: [
                              Icon(
                                Icons.music_note_rounded,
                                size: 64,
                                color: Colors.grey[600],
                              ),
                              const SizedBox(height: 16),
                              Text(
                                AppLocalizations.of(
                                  context,
                                )!
                                    .noContentAvailable,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey[600],
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                AppLocalizations.of(context)!.tryRefreshing,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.grey[500],
                                ),
                              ),
                              const SizedBox(height: 24),
                              ElevatedButton.icon(
                                onPressed: () => libraryProvider.refresh(),
                                icon: const Icon(Icons.refresh),
                                label: Text(
                                  AppLocalizations.of(context)!.refresh,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      const SizedBox(height: 150),
                    ],
                  ),
                );
              },
            ),
          ),
            ],
          ),
        ),
      ), // close Scaffold
      // Scroll to top button overlay
        if (_showScrollToTop)
          Positioned(
            right: 16,
            bottom: 100,
            child: FloatingActionButton(
              onPressed: _scrollToTop,
              backgroundColor: isDark ? AppTheme.darkCard : Colors.grey[200],
              mini: true,
              child: Icon(
                Icons.keyboard_arrow_up,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildLoadingState(bool isDesktop, double hPad) {
    return Column(
      children: [
        const SizedBox(height: 16),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: hPad),
          child: GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: isDesktop ? 3 : 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 3.5,
            children: List.generate(
              isDesktop ? 6 : 6,
              (_) => Container(
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        HorizontalShimmerList(
          count: 5,
          child: AlbumCardShimmer(size: isDesktop ? 180 : 150),
        ),
      ],
    );
  }

  void _openAlbum(BuildContext context, String albumId) {
    NavigationHelper.push(context, AlbumScreen(albumId: albumId));
  }
}

class _QuickAccessGrid extends StatelessWidget {
  final List<dynamic> albums;
  final List<dynamic> playlists;
  final bool isDesktop;
  final double hPad;

  const _QuickAccessGrid({
    required this.albums,
    required this.playlists,
    this.isDesktop = false,
    this.hPad = 16,
  });

  @override
  Widget build(BuildContext context) {
    final raw = [...albums, ...playlists].take(isDesktop ? 9 : 6).toList();

    final items =
        (!isDesktop && raw.length.isOdd) ? raw.sublist(0, raw.length - 1) : raw;

    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final subsonicService = Provider.of<SubsonicService>(
      context,
      listen: false,
    );

    if (isDesktop) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: hPad),
        child: GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 280,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 3.2,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) =>
              _buildTile(context, items[index], subsonicService),
        ),
      );
    }

    const tileHeight = 56.0;
    const spacing = 8.0;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tileWidth = (constraints.maxWidth - spacing) / 2;
          final ratio = tileWidth / tileHeight;
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
              childAspectRatio: ratio,
            ),
            itemCount: items.length,
            itemBuilder: (context, index) =>
                _buildTile(context, items[index], subsonicService),
          );
        },
      ),
    );
  }

  Widget _buildTile(
    BuildContext context,
    dynamic item,
    SubsonicService subsonicService,
  ) {
    final isPlaylist = item.runtimeType.toString().contains('Playlist');
    String? imageUrl;
    String title;
    VoidCallback onTap;

    if (isPlaylist) {
      title = item.name;
      imageUrl = item.coverArt != null
          ? (isLocalFilePath(item.coverArt)
              ? item.coverArt
              : subsonicService.getCoverArtUrl(item.coverArt!, size: 100))
          : null;
      onTap = () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  PlaylistScreen(playlistId: item.id, playlistName: item.name),
            ),
          );
    } else {
      title = item.name;
      imageUrl = item.coverArt != null
          ? (isLocalFilePath(item.coverArt)
              ? item.coverArt
              : subsonicService.getCoverArtUrl(item.coverArt!, size: 100))
          : null;
      onTap = () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (context) => AlbumScreen(albumId: item.id)),
          );
    }

    return _QuickAccessTile(title: title, imageUrl: imageUrl, onTap: onTap);
  }
}

class _QuickAccessTile extends StatefulWidget {
  final String title;
  final String? imageUrl;
  final VoidCallback onTap;

  const _QuickAccessTile({
    required this.title,
    this.imageUrl,
    required this.onTap,
  });

  @override
  State<_QuickAccessTile> createState() => _QuickAccessTileState();
}

class _QuickAccessTileState extends State<_QuickAccessTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: isDark
              ? (_isHovered ? AppTheme.darkElevated : AppTheme.darkCard)
              : (_isHovered ? Colors.grey[300] : Colors.grey[200]),
          borderRadius: BorderRadius.circular(4),
          boxShadow: _isHovered
              ? [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ]
              : [],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(4),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(4),
                  ),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: widget.imageUrl != null
                        ? (isLocalFilePath(widget.imageUrl)
                            ? Image.file(
                                File(widget.imageUrl!),
                                fit: BoxFit.cover,
                                errorBuilder: (ctx, e, _) => Container(
                                  color: Colors.grey[800],
                                  child: const Icon(
                                    Icons.music_note,
                                    color: Colors.white30,
                                  ),
                                ),
                              )
                            : CachedNetworkImage(
                                imageUrl: widget.imageUrl!,
                                fit: BoxFit.cover,
                                placeholder: (ctx, e) =>
                                    Container(color: Colors.grey[800]),
                                errorWidget: (ctx, e, _) => Container(
                                  color: Colors.grey[800],
                                  child: const Icon(
                                    Icons.music_note,
                                    color: Colors.white30,
                                  ),
                                ),
                              ))
                        : Container(
                            color: Colors.grey[800],
                            child: const Icon(
                              Icons.music_note,
                              color: Colors.white30,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title,
                    style: TextStyle(
                      color: isDark ? Colors.white : Colors.black,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  final dynamic playlist;
  final VoidCallback? onTap;
  final double size;

  const _PlaylistCard({required this.playlist, this.onTap, this.size = 150});

  @override
  Widget build(BuildContext context) {
    final subsonicService = Provider.of<SubsonicService>(
      context,
      listen: false,
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final coverArtUrl = playlist.coverArt != null
        ? subsonicService.getCoverArtUrl(playlist.coverArt!, size: 300)
        : null;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: size,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: coverArtUrl != null
                    ? CachedNetworkImage(
                        imageUrl: coverArtUrl,
                        fit: BoxFit.cover,
                        placeholder: (ctx, url) => Container(
                          color: isDark
                              ? const Color(0xFF2C2C2E)
                              : Colors.grey[300],
                          child: const Center(
                            child: Icon(
                              Icons.queue_music_rounded,
                              size: 50,
                              color: Colors.white30,
                            ),
                          ),
                        ),
                        errorWidget: (ctx, err, stack) => Container(
                          color: isDark
                              ? const Color(0xFF2C2C2E)
                              : Colors.grey[300],
                          child: const Center(
                            child: Icon(
                              Icons.queue_music_rounded,
                              size: 50,
                              color: Colors.white30,
                            ),
                          ),
                        ),
                      )
                    : Container(
                        color:
                            isDark ? const Color(0xFF2C2C2E) : Colors.grey[300],
                        child: const Center(
                          child: Icon(
                            Icons.queue_music_rounded,
                            size: 50,
                            color: Colors.white30,
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              playlist.name,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            if (playlist.songCount != null)
              Text(
                '${playlist.songCount} songs',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final double hPad;
  final bool isCollapsed;
  final VoidCallback? onToggle;
  final Widget? trailing;

  const _SectionTitle({
    required this.title,
    this.subtitle,
    this.icon,
    this.hPad = 16,
    this.isCollapsed = false,
    this.onToggle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onToggle,
      child: Padding(
        padding: EdgeInsets.fromLTRB(hPad, 4, hPad, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white54 : Colors.black45,
                  ),
                ),
              ),
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black,
                      letterSpacing: -0.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onToggle != null) ...[
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: isCollapsed ? -0.25 : 0.25,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: isDark ? Colors.white54 : Colors.black45,
                    ),
                  ),
                ],
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  trailing!,
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopSongTableHeader extends StatelessWidget {
  final double hPad;
  const _DesktopSongTableHeader({this.hPad = 16});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final labelStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.1,
      color: isDark ? Colors.white38 : Colors.black38,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(hPad, 4, hPad, 4),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Text('#', style: labelStyle, textAlign: TextAlign.center),
          ),
          const SizedBox(width: 12),
          const SizedBox(width: 40),
          const SizedBox(width: 12),
          Expanded(flex: 5, child: Text('TITLE', style: labelStyle)),
          Expanded(flex: 3, child: Text('ALBUM', style: labelStyle)),
          const SizedBox(width: 40),
          SizedBox(
            width: 52,
            child: Text('TIME', style: labelStyle, textAlign: TextAlign.right),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _DesktopSongRow extends StatefulWidget {
  final Song song;
  final List<Song> playlist;
  final int index;
  final double hPad;

  const _DesktopSongRow({
    required this.song,
    required this.playlist,
    required this.index,
    this.hPad = 16,
  });

  @override
  State<_DesktopSongRow> createState() => _DesktopSongRowState();
}

class _DesktopSongRowState extends State<_DesktopSongRow> {
  bool _hovered = false;

  String _formatDuration(int? seconds) {
    if (seconds == null) return '--:--';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final song = widget.song;
    final subsonicService = Provider.of<SubsonicService>(
      context,
      listen: false,
    );

    final isPlaying = context.select<PlayerProvider, bool>(
      (p) => (p.currentSong?.id == song.id) && p.isPlaying,
    );

    final rowBg = _hovered
        ? (isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.04))
        : Colors.transparent;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => context.read<PlayerProvider>().playSong(
              song,
              playlist: widget.playlist,
              startIndex: widget.index,
            ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          color: rowBg,
          padding: EdgeInsets.fromLTRB(widget.hPad, 6, widget.hPad, 6),
          child: Row(
            children: [
              SizedBox(
                width: 32,
                child: Center(
                  child: _hovered
                      ? Icon(
                          Icons.play_arrow_rounded,
                          size: 18,
                          color: isDark ? Colors.white : Colors.black,
                        )
                      : isPlaying
                          ? Icon(
                              Icons.bar_chart_rounded,
                              size: 18,
                              color: AppTheme.appleMusicRed,
                            )
                          : Text(
                              '${widget.index + 1}',
                              style: TextStyle(
                                fontSize: 13,
                                color: isPlaying
                                    ? AppTheme.appleMusicRed
                                    : (isDark
                                        ? Colors.white60
                                        : Colors.black54),
                              ),
                              textAlign: TextAlign.center,
                            ),
                ),
              ),
              const SizedBox(width: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: song.coverArt != null
                      ? CachedNetworkImage(
                          imageUrl: subsonicService.getCoverArtUrl(
                            song.coverArt!,
                            size: 80,
                          ),
                          fit: BoxFit.cover,
                          placeholder: (ctx, url) =>
                              Container(color: Colors.grey[800]),
                          errorWidget: (ctx, err, stack) => Container(
                            color: Colors.grey[800],
                            child: const Icon(
                              Icons.music_note,
                              size: 16,
                              color: Colors.white30,
                            ),
                          ),
                        )
                      : Container(
                          color: Colors.grey[800],
                          child: const Icon(
                            Icons.music_note,
                            size: 16,
                            color: Colors.white30,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      song.title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: isPlaying
                            ? AppTheme.appleMusicRed
                            : (isDark ? Colors.white : Colors.black),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (song.artist != null)
                      Text(
                        song.artist!,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white54 : Colors.black54,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  song.album ?? '',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(
                width: 40,
                child: _hovered || song.starred == true
                    ? IconButton(
                        icon: Icon(
                          song.starred == true
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          size: 16,
                          color: song.starred == true
                              ? AppTheme.appleMusicRed
                              : (isDark ? Colors.white38 : Colors.black38),
                        ),
                        padding: EdgeInsets.zero,
                        onPressed: () {
                          context.read<PlayerProvider>().toggleFavoriteForSong(
                                song,
                              );
                        },
                      )
                    : const SizedBox.shrink(),
              ),
              SizedBox(
                width: 52,
                child: Text(
                  _formatDuration(song.duration),
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

// === NEW SECTIONS ===

class _LatestReleasesSection extends StatelessWidget {
  final LibraryProvider libraryProvider;
  final double hPad;

  const _LatestReleasesSection({required this.libraryProvider, this.hPad = 16});

  @override
  Widget build(BuildContext context) {
    final albums = libraryProvider.newestAlbums.isNotEmpty
        ? libraryProvider.newestAlbums
        : libraryProvider.recentAlbums;
    if (albums.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 200,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: hPad),
        itemCount: albums.take(10).length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final album = albums[index];
          return GestureDetector(
            onTap: () => NavigationHelper.push(
              context,
              AlbumScreen(albumId: album.id),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: const Color(0xFF282828),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: album.coverArt != null
                      ? CachedNetworkImage(
                          imageUrl: Provider.of<SubsonicService>(context, listen: false)
                              .getCoverArtUrl(album.coverArt!, size: 300),
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => const Icon(
                            Icons.album_rounded,
                            color: Colors.white38,
                            size: 48,
                          ),
                        )
                      : const Icon(
                          Icons.album_rounded,
                          color: Colors.white38,
                          size: 48,
                        ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: 150,
                  child: Text(
                    album.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  album.artist ?? '',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ArtistMixesSection extends StatelessWidget {
  final RecommendationService recommendationService;
  final double hPad;

  const _ArtistMixesSection({required this.recommendationService, this.hPad = 16});

  @override
  Widget build(BuildContext context) {
    final topArtists = recommendationService.getTopFavoriteArtists(limit: 10);
    if (topArtists.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 180,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: hPad),
        itemCount: topArtists.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final artistName = topArtists[index];
          return SizedBox(
            width: 160,
            child: ArtistCollageCard(artistName: artistName),
          );
        },
      ),
    );
  }
}

class _ArtistRadioCard extends StatefulWidget {
  final String artistName;
  const _ArtistRadioCard({required this.artistName});

  @override
  State<_ArtistRadioCard> createState() => _ArtistRadioCardState();
}

class _ArtistRadioCardState extends State<_ArtistRadioCard> {
  String? _coverUrl;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadArtistCover();
  }

  Future<void> _loadArtistCover() async {
    try {
      final subsonicService = Provider.of<SubsonicService>(context, listen: false);
      final results = await subsonicService.search(
        widget.artistName,
        artistCount: 1,
        albumCount: 3,
        songCount: 0,
      );
      if (results.albums.isNotEmpty && results.albums.first.coverArt != null) {
        if (mounted) {
          setState(() {
            _coverUrl = subsonicService.getCoverArtUrl(
              results.albums.first.coverArt!,
              size: 300,
            );
            _isLoading = false;
          });
        }
      } else if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _playArtistRadio(context),
      child: Column(
        children: [
          Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF282828),
            ),
            clipBehavior: Clip.antiAlias,
            child: _isLoading
                ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                : _coverUrl != null
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          CachedNetworkImage(
                            imageUrl: _coverUrl!,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => _buildPlaceholder(),
                          ),
                          // Radio icon overlay
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.4),
                            ),
                            child: Icon(
                              Icons.wifi_tethering_rounded,
                              color: Colors.white.withValues(alpha: 0.9),
                              size: 28,
                            ),
                          ),
                        ],
                      )
                    : _buildPlaceholder(),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 90,
            child: Text(
              widget.artistName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: const Color(0xFF282828),
      child: Center(
        child: Text(
          widget.artistName.isNotEmpty ? widget.artistName[0].toUpperCase() : '?',
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  void _playArtistRadio(BuildContext context) async {
    final provider = context.read<PlayerProvider>();
    final subsonicService = Provider.of<SubsonicService>(context, listen: false);
    
    // First try to find songs by this artist via search
    try {
      final results = await subsonicService.search(
        widget.artistName,
        artistCount: 0,
        albumCount: 0,
        songCount: 25,
      );
      
      if (results.songs.isNotEmpty) {
        // Shuffle for radio-like experience
        final shuffled = List<Song>.from(results.songs)..shuffle();
        provider.playSong(
          shuffled.first,
          playlist: shuffled,
          startIndex: 0,
        );
        return;
      }
    } catch (e) {
      debugPrint('Error searching artist songs: $e');
    }
    
    // Fallback: use random songs from library
    final allSongs = Provider.of<LibraryProvider>(context, listen: false).randomSongs;
    final artistSongs = allSongs.where((s) => s.artist == widget.artistName).toList();
    if (artistSongs.isNotEmpty) {
      final shuffled = List<Song>.from(artistSongs)..shuffle();
      provider.playSong(
        shuffled.first,
        playlist: shuffled,
        startIndex: 0,
      );
    }
  }
}

/// Карточка ежедневного ИИ-микса на главной: имя + счётчик + дата.
/// Тап — детали (а не сразу играть): там Слушать/Сохранить/Обновить.
class _AiDailyHomeCard extends StatelessWidget {
  final double hPad;

  const _AiDailyHomeCard({this.hPad = 16});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: AiMixService().getLastDailyInfo(),
      builder: (ctx, snap) {
        final info = snap.data;
        final name = info?['name']?.toString() ?? 'ИИ-микс дня';
        final ids = ((info?['ids'] as List?) ?? const []).length;
        final date = info?['date']?.toString() ?? '';
        return GestureDetector(
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const AiDailyDetailScreen()),
            );
          },
          child: Container(
            margin: EdgeInsets.symmetric(horizontal: hPad),
            height: 120,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF007AFF), Color(0xFF7C3AED)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.auto_awesome_rounded,
                      color: Color(0xFF007AFF),
                      size: 30,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          ids > 0
                              ? 'ИИ-микс · $ids треков${date.isNotEmpty ? ' · $date' : ''}'
                              : 'Открой — соберём свежий микс',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded,
                      color: Colors.white70, size: 28),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DailyPlaylistSection extends StatelessWidget {
  final List<Song> songs;
  final double hPad;

  const _DailyPlaylistSection({required this.songs, this.hPad = 16});

  @override
  Widget build(BuildContext context) {
    if (songs.isEmpty) return const SizedBox.shrink();
    final dailySongs = songs.take(20).toList();

    return GestureDetector(
      onTap: () {
        final provider = context.read<PlayerProvider>();
        provider.playSong(
          dailySongs.first,
          playlist: dailySongs,
          startIndex: 0,
        );
      },
      child: Container(
        margin: EdgeInsets.symmetric(horizontal: hPad),
        height: 120,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF7C3AED), Color(0xFF4F46E5)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.play_arrow_rounded,
                  color: Color(0xFF7C3AED),
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'Плейлист дня',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Ежедневно обновляемый микс · ${dailySongs.length} треков',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GenreMixesSection extends StatelessWidget {
  final List<Song> songs;
  final double hPad;

  const _GenreMixesSection({required this.songs, this.hPad = 16});

  static const Map<String, List<Color>> _genreColors = {
    'rock': [Color(0xFFDC2626), Color(0xFFEA580C)],
    'metal': [Color(0xFF374151), Color(0xFF111827)],
    'pop': [Color(0xFFEC4899), Color(0xFF8B5CF6)],
    'hip-hop': [Color(0xFFF59E0B), Color(0xFFDC2626)],
    'hip hop': [Color(0xFFF59E0B), Color(0xFFDC2626)],
    'electronic': [Color(0xFF3B82F6), Color(0xFF8B5CF6)],
    'jazz': [Color(0xFFB45309), Color(0xFFD97706)],
    'classical': [Color(0xFF4338CA), Color(0xFF6D28D9)],
    'r&b': [Color(0xFF7C3AED), Color(0xFFDB2777)],
    'latin': [Color(0xFFDC2626), Color(0xFFF59E0B)],
    'indie': [Color(0xFF10B981), Color(0xFF059669)],
    'folk': [Color(0xFF15803D), Color(0xFF059669)],
    'rap': [Color(0xFFDC2626), Color(0xFFEA580C)],
    'рэп-рок': [Color(0xFFEF4444), Color(0xFFB91C1C)],
    'punk': [Color(0xFFEF4444), Color(0xFFDC2626)],
    'reggae': [Color(0xFF22C55E), Color(0xFFEAB308)],
    'blues': [Color(0xFF2563EB), Color(0xFF1D4ED8)],
    'country': [Color(0xFFD97706), Color(0xFF92400E)],
    'soundtrack': [Color(0xFF7C3AED), Color(0xFF4F46E5)],
    'alternative': [Color(0xFF6366F1), Color(0xFF8B5CF6)],
    'k-pop': [Color(0xFFF472B6), Color(0xFFA855F7)],
    'dance': [Color(0xFF06B6D4), Color(0xFF3B82F6)],
    'house': [Color(0xFF8B5CF6), Color(0xFFA855F7)],
    'techno': [Color(0xFF6B7280), Color(0xFF4B5563)],
    'ambient': [Color(0xFF38BDF8), Color(0xFF22D3EE)],
    'lo-fi': [Color(0xFFC084FC), Color(0xFFF472B6)],
    'lofi': [Color(0xFFC084FC), Color(0xFFF472B6)],
  };

  static List<Color> _getColorsForGenre(String genre) {
    final lower = genre.toLowerCase().trim();
    if (_genreColors.containsKey(lower)) return _genreColors[lower]!;
    for (final entry in _genreColors.entries) {
      if (lower.contains(entry.key) || entry.key.contains(lower)) return entry.value;
    }
    // hash fallback to avoid always grey
    final hash = lower.hashCode.abs();
    final keys = _genreColors.keys.toList();
    return _genreColors[keys[hash % keys.length]]!;
  }

  @override
  Widget build(BuildContext context) {
    final genreCounts = <String, int>{};
    for (final song in songs) {
      final genre = song.genre ?? 'Другое';
      genreCounts[genre] = (genreCounts[genre] ?? 0) + 1;
    }

    final topGenres = genreCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final genres = topGenres.take(8).toList();

    if (genres.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 140,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: hPad),
        itemCount: genres.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final genre = genres[index].key;
          final colors = _getColorsForGenre(genre);

          return GestureDetector(
            onTap: () {
              final genreSongs = songs.where((s) => s.genre == genre).toList()..shuffle();
              if (genreSongs.isNotEmpty) {
                context.read<PlayerProvider>().playSong(
                  genreSongs.first,
                  playlist: genreSongs,
                  startIndex: 0,
                );
              }
            },
            child: Container(
              width: 150,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: colors,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: colors[0].withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Микс по жанру',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        genre,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Yandex Music: Similar Artists Section
// ──────────────────────────────────────────────────────────────────────────

class _YandexSimilarArtistsSection extends StatefulWidget {
  final List<Artist> artists;
  final double hPad;

  const _YandexSimilarArtistsSection({
    required this.artists,
    this.hPad = 16,
  });

  @override
  State<_YandexSimilarArtistsSection> createState() =>
      _YandexSimilarArtistsSectionState();
}

class _YandexSimilarArtistsSectionState
    extends State<_YandexSimilarArtistsSection> {
  List<RelatedArtistMatch> _matches = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadSimilarArtists();
  }

  Future<void> _loadSimilarArtists() async {
    if (widget.artists.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      final provider = Provider.of<YandexMusicProvider>(context, listen: false);

      // Get similar artists for the first few artists
      final allMatches = <RelatedArtistMatch>[];
      for (final artist in widget.artists.take(3)) {
        final matches = await provider.getRelatedArtists(
          artistName: artist.name,
          localArtists: widget.artists,
          limit: 5,
        );
        allMatches.addAll(matches);
      }

      // Deduplicate by local artist ID
      final seen = <String>{};
      final uniqueMatches = allMatches.where((m) {
        if (seen.contains(m.localArtist.id)) return false;
        seen.add(m.localArtist.id);
        return true;
      }).toList();

      if (mounted) {
        setState(() {
          _matches = uniqueMatches.take(10).toList();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return SizedBox(
        height: 140,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppTheme.appleMusicRed.withValues(alpha: 0.6),
            ),
          ),
        ),
      );
    }

    if (_matches.isEmpty) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SizedBox(
      height: 140,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: widget.hPad),
        itemCount: _matches.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final match = _matches[index];
          return GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ArtistScreen(artistId: match.localArtist.id),
                ),
              );
            },
            child: SizedBox(
              width: 100,
              child: Column(
                children: [
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: _buildAvatar(match, isDark),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    match.localArtist.name,
                    style: TextStyle(
                      color: isDark ? Colors.white : Colors.black,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAvatar(RelatedArtistMatch match, bool isDark) {
    // Try Yandex Music cover first
    final yandexCover = match.yandexArtist.getMediumCoverUrl();

    if (yandexCover != null) {
      return CachedNetworkImage(
        imageUrl: yandexCover,
        fit: BoxFit.cover,
        placeholder: (_, __) => _buildPlaceholder(isDark),
        errorWidget: (_, __, ___) {
          // Fallback to local cover
          if (match.localArtist.coverArt != null) {
            return CachedNetworkImage(
              imageUrl: match.localArtist.coverArt!,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => _buildPlaceholder(isDark),
            );
          }
          return _buildPlaceholder(isDark);
        },
      );
    }

    // Use local cover art
    if (match.localArtist.coverArt != null) {
      return CachedNetworkImage(
        imageUrl: match.localArtist.coverArt!,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => _buildPlaceholder(isDark),
      );
    }

    return _buildPlaceholder(isDark);
  }

  Widget _buildPlaceholder(bool isDark) {
    return Container(
      color: isDark ? const Color(0xFF282828) : Colors.grey[300],
      child: const Center(
        child: Icon(
          Icons.person,
          color: Colors.white38,
          size: 40,
        ),
      ),
    );
  }
}

class _MyWaveCustomizeSheet extends StatefulWidget {
  final List<Song> songs;
  final ScrollController? scrollCtrl;
  const _MyWaveCustomizeSheet({required this.songs, this.scrollCtrl});
  @override
  State<_MyWaveCustomizeSheet> createState() => _MyWaveCustomizeSheetState();
}

/// Подпись источника каталога для диагностики:
/// «с сервера (9)» / «кеш (9)» / «встроенный (9)».
String _optionsSourceLabel(BuildContext context, BrainWaveOptions opts) {
  String src = 'встроенный';
  try {
    final bridge =
        Provider.of<KumaFlowBrainBridge>(context, listen: false);
    src = switch (bridge.waveOptionsSource) {
      'server' => 'с сервера',
      'cache' => 'кеш',
      _ => 'встроенный',
    };
  } catch (_) {}
  return '$src (${opts.activities.length})';
}

class _MyWaveCustomizeSheetState extends State<_MyWaveCustomizeSheet> {
  String _activity = '';
  String _character = '';
  String _mood = '';
  String _lang = '';
  bool _isApplying = false;
  // Настроения с сервера мозга (wave/continue count 5, только метки).
  // Показываются отдельной строкой, стиль — те же пилюли, чтобы не ломать вид.
  List<String> _serverMoods = const [];
  bool _serverMoodsLoading = false;

  static const _kPrefActivity = 'mywave_activity';
  static const _kPrefCharacter = 'mywave_character';
  static const _kPrefMood = 'mywave_mood';
  static const _kPrefLang = 'mywave_lang';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        // Храним коды каталога; старые RU-пилюли мигрируют в коды.
        _activity = normalizeBrainActivity(p.getString(_kPrefActivity) ?? '');
        _character =
            normalizeBrainCharacteristic(p.getString(_kPrefCharacter) ?? '');
        _mood = p.getString(_kPrefMood) ?? '';
        _lang = normalizeBrainLanguage(p.getString(_kPrefLang) ?? '');
      });
      _adoptSharedWaveSettings();
    });
    _loadServerMoods();
  }

  /// Общие пилюли с мозга (одни на всех устройствах): если мозг активен и
  /// там есть непустые значения — забираем их в шит и в локальные префы.
  /// Best-effort, молча.
  Future<void> _adoptSharedWaveSettings() async {
    try {
      final bridge =
          Provider.of<KumaFlowBrainBridge>(context, listen: false);
      if (!bridge.isActive || bridge.isOfflineNow) return;
      final shared = await bridge
          .fetchSharedWaveSettings()
          .timeout(const Duration(seconds: 12));
      if (shared.isEmpty || !mounted) return;
      final act = normalizeBrainActivity((shared['activity'] ?? '').toString());
      final cha = normalizeBrainCharacteristic(
          (shared['characteristic'] ?? '').toString());
      final mood = (shared['mood'] ?? '').toString().trim();
      final lang =
          normalizeBrainLanguage((shared['language'] ?? '').toString());
      if (act.isEmpty && cha.isEmpty && mood.isEmpty && lang.isEmpty) return;
      setState(() {
        _activity = act;
        _character = cha;
        _mood = mood;
        _lang = lang;
      });
      await _persistSelection();
    } catch (_) {}
  }

  /// Настроения с сервера: сначала из каталога /api/wave/options (дешёво,
  /// без waveContinue), иначе — один лёгкий waveContinue(count 5) как раньше.
  /// Ошибка/пусто — молча, остаются стандартные 4 настроения.
  Future<void> _loadServerMoods() async {
    try {
      final bridge =
          Provider.of<KumaFlowBrainBridge>(context, listen: false);
      // 1) каталог (кеш/fallback мгновенно, сервер — best-effort следом).
      try {
        final opts = bridge.waveOptions;
        final fromCatalog = opts.moods
            .map((m) => m.name.trim())
            .where((m) => m.isNotEmpty)
            .take(6)
            .toList();
        if (fromCatalog.isNotEmpty && mounted) {
          setState(() => _serverMoods = fromCatalog);
        }
        if (bridge.isActive && !bridge.isOfflineNow) {
          final fresh = await bridge
              .fetchWaveOptions()
              .timeout(const Duration(seconds: 12));
          final got = fresh.moods
              .map((m) => m.name.trim())
              .where((m) => m.isNotEmpty)
              .take(6)
              .toList();
          if (got.isNotEmpty && mounted) {
            setState(() => _serverMoods = got);
            return;
          }
        } else if (fromCatalog.isNotEmpty) {
          return;
        }
      } catch (_) {}
      // 2) legacy: метки из waveContinue(count 5), только если каталог пуст.
      if (_serverMoods.isNotEmpty) return;
      if (!bridge.isActive) return;
      if (!mounted) return;
      setState(() => _serverMoodsLoading = true);
      final tracks = await bridge
          .waveContinue(queue: const [], count: 5)
          .timeout(const Duration(seconds: 15));
      final got = <String>{};
      for (final t in tracks) {
        for (final m in t.moods) {
          final v = m.trim();
          if (v.isNotEmpty) got.add(v);
          if (got.length >= 6) break;
        }
        if (got.length >= 6) break;
      }
      // Убираем дубли стандартных (регистр/язык не важен — сравнение в лоб).
      got.removeWhere((m) =>
          ['бодрое', 'весёлое', 'спокойное', 'грустное'].contains(m.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _serverMoods = got.take(6).toList();
        _serverMoodsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _serverMoodsLoading = false);
    }
  }

  Future<void> _persistSelection() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kPrefActivity, _activity);
      await p.setString(_kPrefCharacter, _character);
      await p.setString(_kPrefMood, _mood);
      await p.setString(_kPrefLang, _lang);
    } catch (_) {}
  }

  /// Целевой вайб из настроения + занятия (шкалы как в Song Alchemy:
  /// energy/danceability/valence/acousticness 0..1).
  VibeFeatures? _vibeTarget() {
    double? e, v, d, ac;
    switch (_mood) {
      case 'Бодрое':
        e = 0.85; v = 0.7; d = 0.85; ac = 0.15;
        break;
      case 'Весёлое':
        e = 0.65; v = 0.85; d = 0.75; ac = 0.3;
        break;
      case 'Спокойное':
        e = 0.3; v = 0.55; d = 0.3; ac = 0.65;
        break;
      case 'Грустное':
        e = 0.35; v = 0.3; d = 0.35; ac = 0.5;
        break;
    }
    // Занятие — дельта поверх настроения (или самостоятельный пресет).
    // Коды каталога /api/wave/options; старые RU-пилюли нормализуем.
    switch (normalizeBrainActivity(_activity)) {
      case 'wakeup':
        e = (e ?? 0.55) - 0.1; v = v ?? 0.65; d = d ?? 0.5; ac = (ac ?? 0.4) + 0.1;
        break;
      case 'commute':
      case 'walk':
        e = (e ?? 0.65) + 0.1; v = v ?? 0.6; d = (d ?? 0.6) + 0.1; ac = ac ?? 0.25;
        break;
      case 'work':
      case 'study':
        e = (e ?? 0.45) - 0.1; v = v ?? 0.55; d = d ?? 0.35; ac = (ac ?? 0.5) + 0.2;
        break;
      case 'workout':
      case 'party':
        e = (e ?? 0.75) + 0.1; v = v ?? 0.7; d = (d ?? 0.75) + 0.1; ac = ac ?? 0.2;
        break;
      case 'rest':
      case 'sleep':
        e = (e ?? 0.35) - 0.1; v = v ?? 0.5; d = d ?? 0.3; ac = (ac ?? 0.5) + 0.2;
        break;
    }
    if (e == null) return null;
    double cl(double x) => x.clamp(0.05, 0.95).toDouble();
    final act = normalizeBrainActivity(_activity);
    return VibeFeatures(
      energy: cl(e), valence: cl(v!), danceability: cl(d!),
      bpm: 110, acousticness: cl(ac!), instrumentalness: (act == 'work' || act == 'study') ? 0.6 : 0.2,
    );
  }

  /// Полный пайплайн: весь каталог -> фильтры -> вкус -> алхимия -> порядок.
  List<Song> _buildWave() {
    final lib = context.read<LibraryProvider>();
    final rec = context.read<RecommendationService>();
    final ml = MLService();
    final vibe = VibeSimilarity();

    // 1) Полный пул, а не 30 треков hero-карточки.
    List<Song> base = lib.cachedAllSongs.isNotEmpty
        ? lib.cachedAllSongs
        : widget.songs;
    try {
      if (lib.isOfflineNow) base = lib.playablePool();
    } catch (_) {}
    if (base.isEmpty) base = widget.songs;

    // 2) Баны/дизлайки out — гарантирует "артист не забанен".
    var pool = ml.filterSongs(base);

    // 3) Характер (коды каталога; RU-пилюли нормализуем).
    if (_character.isNotEmpty) {
      switch (normalizeBrainCharacteristic(_character)) {
        case 'favorite':
          pool = pool.where((s) =>
              s.starred == true ||
              (s.userRating != null && s.userRating! >= 4) ||
              (s.playCount != null && s.playCount! > 3) ||
              ml.calculateTrackScore(s.id) > 20).toList();
          break;
        case 'unfamiliar':
          // Никогда не слушанные: серверные поля + ML-рейтинг + recent + без лайков.
          // Баны уже выкинуты шагом выше через ml.filterSongs.
          final recent = rec.recentlyPlayed.toSet();
          pool = pool.where((s) {
            final neverServer =
                (s.playCount == null || s.playCount == 0) && s.played == null;
            final r = ml.ratings[s.id];
            final neverMl =
                (r == null || ((r.playCount) == 0 && r.lastPlayed == null)) &&
                (r?.like != true);
            return neverServer && neverMl && s.starred != true && !recent.contains(s.id);
          }).toList();
          break;
        case 'popular':
          if (pool.isNotEmpty) {
            pool.sort((a, b) => (b.playCount ?? 0).compareTo(a.playCount ?? 0));
            // На полном каталоге берём топ-3000, дальше вкус/вайб их переранжируют.
            final keep = pool.length > 3000
                ? 3000
                : (pool.length * 0.35).ceil().clamp(1, pool.length);
            pool = pool.take(keep).toList();
          }
          break;
      }
    }

    // 4) Язык (расширенный: title+artist+album; Без слов через instrumentalness).
    // Коды каталога (ru/foreign/instrumental), RU-пилюли нормализуем.
    if (_lang.isNotEmpty) {
      final cyr = RegExp(r'[а-яёА-ЯЁ]');
      switch (normalizeBrainLanguage(_lang)) {
        case 'ru':
          pool = pool.where((s) =>
              cyr.hasMatch(s.title) ||
              cyr.hasMatch(s.artist ?? '') ||
              cyr.hasMatch(s.album ?? '')).toList();
          break;
        case 'foreign':
          pool = pool.where((s) {
            final txt = '${s.title} ${s.artist ?? ''} ${s.album ?? ''}';
            if (cyr.hasMatch(txt)) return false;
            final g = (s.genre ?? '').toLowerCase();
            if (g.contains('instrumental') || g.contains('classical')) return false;
            return true;
          }).toList();
          break;
        case 'instrumental':
          pool = pool.where((s) {
            final g = (s.genre ?? '').toLowerCase();
            final t = s.title.toLowerCase();
            if (g.contains('instrumental') || g.contains('classical') ||
                g.contains('soundtrack') || g.contains('ambient') ||
                g.contains('lo-fi') || g.contains('lofi') ||
                t.contains('instrumental') || t.contains('без слов')) return true;
            // Алхимия-проверка: инструментальность по вайб-профилю жанра.
            return vibe.analyzeTrack(s).instrumentalness > 0.6;
          }).toList();
          break;
      }
    }

    // 5) Грубая предфильтрация по настроению/занятию (mood часто пустой —
    // не отсекаем в ноль: если после фильтра <50, возвращаем пул до него).
    if (_mood.isNotEmpty || _activity.isNotEmpty) {
      final before = pool;
      pool = pool.where((s) {
        final m = (s.mood ?? '').toLowerCase();
        final g = (s.genre ?? '').toLowerCase();
        bool okMood = true, okAct = true;
        if (_mood.isNotEmpty) {
          switch (_mood) {
            case 'Бодрое':
              okMood = m.contains('energetic') || m.contains('excited') || g.contains('dance') || g.contains('electronic') || g.contains('edm') || g.contains('house') || g.contains('pop') || g.contains('rock') || g.contains('hip');
              break;
            case 'Спокойное':
              okMood = m.contains('calm') || m.contains('relax') || g.contains('ambient') || g.contains('classical') || g.contains('acoustic') || g.contains('jazz') || g.contains('chill') || g.contains('folk') || g.contains('lofi') || g.contains('lo-fi');
              break;
            case 'Грустное':
              okMood = m.contains('sad') || m.contains('melanchol') || g.contains('blues') || g.contains('folk') || g.contains('ballad');
              break;
            case 'Весёлое':
              okMood = m.contains('happy') || m.contains('upbeat') || g.contains('disco') || g.contains('funk') || g.contains('pop') || g.contains('dance') || g.contains('latin');
              break;
          }
        }
        if (_activity.isNotEmpty) {
          final act = normalizeBrainActivity(_activity);
          switch (act) {
            case 'wakeup':
              okAct = m.contains('calm') || m.contains('happy') || g.contains('pop') || g.contains('acoustic') || g.contains('ambient') || g.contains('chill') || g.contains('folk');
              break;
            case 'commute':
            case 'walk':
              okAct = g.contains('rock') || g.contains('electronic') || g.contains('hip') || g.contains('rap') || g.contains('dance') || g.contains('pop') || m.contains('energetic');
              break;
            case 'work':
            case 'study':
              okAct = g.contains('classical') || g.contains('jazz') || g.contains('ambient') || g.contains('instrumental') || g.contains('lofi') || g.contains('lo-fi') || g.contains('chill') || m.contains('calm') || m.contains('focus');
              break;
            case 'workout':
            case 'party':
              okAct = m.contains('energetic') || g.contains('dance') || g.contains('electronic') || g.contains('rock') || g.contains('hip') || m.contains('excited');
              break;
            case 'rest':
            case 'sleep':
              okAct = m.contains('calm') || m.contains('relax') || g.contains('ambient') || g.contains('classical') || g.contains('acoustic') || g.contains('chill');
              break;
            default:
              okAct = true;
          }
        }
        return okMood && okAct;
      }).toList();
      if (pool.length < 50) pool = before;
    }

    if (pool.isEmpty) return [];

    // 6) Вкус: персоналка поверх отфильтрованного (учитывает лайки/скипы/бандit).
    // На 80к пуле полный скоринг вешает UI — сэмплируем до 5000 дешёвым шаффлом.
    List<Song> ranked;
    try {
      var tastePool = pool;
      if (tastePool.length > 5000) {
        final sample = List<Song>.from(tastePool)..shuffle();
        tastePool = sample.take(5000).toList();
      }
      ranked = rec.getPersonalizedFeed(
          tastePool, limit: tastePool.length > 300 ? 300 : tastePool.length);
    } catch (_) {
      ranked = ml.scoreAndSort(pool.length > 2000 ? pool.take(2000).toList() : pool);
    }
    if (ranked.isEmpty) return [];

    // 7) Алхимия: цель (настроение+занятие) 60% + свежесть порядка 40%,
    // плюс continuity к последним 10 трекам очереди (как в AutoDJ).
    final target = _vibeTarget();
    if (target != null && ranked.length > 5) {
      VibeFeatures? recentProfile;
      try {
        final player = context.read<PlayerProvider>();
        final q = player.queue;
        final curId = player.currentSong?.id;
        if (q.isNotEmpty) {
          int idx = curId != null ? q.indexWhere((s) => s.id == curId) : q.length;
          if (idx < 0) idx = q.length;
          final start = (idx - 10).clamp(0, q.length);
          final end = idx.clamp(0, q.length);
          final recent = q.sublist(start, end);
          if (recent.length >= 3) {
            double e = 0, va = 0, d = 0, b = 0, ac = 0, ins = 0;
            for (final s in recent) {
              final f = vibe.analyzeTrack(s);
              e += f.energy; va += f.valence; d += f.danceability;
              b += f.bpm; ac += f.acousticness; ins += f.instrumentalness;
            }
            final n = recent.length.toDouble();
            recentProfile = VibeFeatures(energy: e / n, valence: va / n, danceability: d / n, bpm: b / n, acousticness: ac / n, instrumentalness: ins / n);
          }
        }
      } catch (_) {}
      // Индексная карта вместо ranked.indexOf(s) — было O(n^2).
      final orderIdx = <String, int>{};
      for (var i = 0; i < ranked.length; i++) {
        orderIdx.putIfAbsent(ranked[i].id, () => i);
      }
      final scored = ranked.map((s) {
        final f = vibe.analyzeTrack(s);
        final simTarget = vibe.vibeSimilarity(target, f);
        final origIdx = orderIdx[s.id] ?? 0;
        final origScore = 1.0 - (origIdx / ranked.length);
        double score = simTarget * 0.6 + origScore * 0.4;
        if (recentProfile != null) {
          final simRecent = vibe.vibeSimilarity(recentProfile, f);
          score = simTarget * 0.55 + simRecent * 0.25 + origScore * 0.2;
        }
        return MapEntry(s, score);
      }).toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      ranked = scored.take(scored.length > 200 ? 200 : scored.length).map((x) => x.key).toList();
    }

    // 8) Порядок под занятие + дайверсити артиста (макс 2 подряд/на волну).
    // Коды каталога; неизвестные — mixed.
    String startWith = 'mixed', endWith = 'mixed';
    switch (normalizeBrainActivity(_activity)) {
      case 'wakeup':
        startWith = 'calm'; endWith = 'energetic';
        break;
      case 'work':
      case 'study':
      case 'rest':
      case 'sleep':
        startWith = 'calm'; endWith = 'calm';
        break;
      case 'commute':
      case 'walk':
      case 'workout':
      case 'party':
        startWith = 'energetic'; endWith = 'energetic';
        break;
      default:
        if (_mood == 'Бодрое' || _mood == 'Весёлое') { startWith = 'energetic'; endWith = 'mixed'; }
        if (_mood == 'Спокойное' || _mood == 'Грустное') { startWith = 'calm'; endWith = 'calm'; }
    }
    try {
      ranked = PlaylistOrchestrator.orchestrate(ranked, startWith: startWith, endWith: endWith);
    } catch (_) {}

    final out = <Song>[];
    final artistCount = <String, int>{};
    for (final s in ranked) {
      if (out.length >= 50) break;
      final key = (s.artistId ?? s.artist?.toLowerCase() ?? s.id);
      final c = artistCount[key] ?? 0;
      if (c >= 2) continue;
      if (out.any((r) => r.id == s.id)) continue;
      out.add(s);
      artistCount[key] = c + 1;
    }
    return out;
  }

  /// Маппинг пилюль «по характеру» в characteristic сервера.
  /// Храним и шлём коды каталога (favorite/unfamiliar/popular);
  /// старые RU-пилюли нормализуются. activity/mood/language сервер
  /// нормализует сам, но шлём уже кодами.
  String? get _characteristicServerValue {
    final c = normalizeBrainCharacteristic(_character);
    return switch (c) {
      'favorite' || 'unfamiliar' || 'popular' => c,
      _ => null,
    };
  }

  /// Человекочитаемые подписи выбранного для снэкбаров (коды -> label).
  /// Без моста — сырые значения (старые RU-пилюли уже читаемы).
  String get _hintLine {
    String act = _activity, cha = _character, lan = _lang;
    try {
      final opts = Provider.of<KumaFlowBrainBridge>(context, listen: false)
          .waveOptions;
      if (act.isNotEmpty) act = opts.activityLabel(act);
      if (cha.isNotEmpty) cha = opts.characteristicLabel(cha);
      if (lan.isNotEmpty) lan = opts.languageLabel(lan);
    } catch (_) {}
    return [act, cha, _mood, lan].where((e) => e.isNotEmpty).join(' • ');
  }
  /// Генерация волны через KumaFlow Brain. Возвращает null, если мост
  /// неактивен, сервер ошибся/пуст — вызывающий падает назад
  /// на локальный _buildWave(). Пустой список сюда не возвращаем:
  /// тихий fallback на локальный пайплайн вместо пустого экрана.
  Future<List<Song>?> _buildKumaFlowBrainWave() async {
    try {
      final bridge = Provider.of<KumaFlowBrainBridge>(context, listen: false);
      if (!bridge.isActive) return null;
      final player = context.read<PlayerProvider>();
      final subsonic = Provider.of<SubsonicService>(context, listen: false);
      final queueIds = player.queue.map((s) => s.id).toList();
      bool languageStrict = false;
      try {
        languageStrict = Provider.of<KumaFlowBrainSettings>(context,
                listen: false)
            .languageStrict;
      } catch (_) {}
      final settingsMap = <String, dynamic>{
        if (normalizeBrainActivity(_activity).isNotEmpty)
          'activity': normalizeBrainActivity(_activity),
        if (_characteristicServerValue != null)
          'characteristic': _characteristicServerValue,
        if (_mood.trim().isNotEmpty) 'mood': _mood.trim(),
        if (normalizeBrainLanguage(_lang).isNotEmpty)
          'language': normalizeBrainLanguage(_lang),
        if (languageStrict) 'language_strict': true,
      };
      final tracks = await bridge
          .waveContinue(
            queue: queueIds,
            currentTrackId: player.currentSong?.id,
            count: 50,
            settingsMap: settingsMap,
            excludeIds: bridge.pendingExcludeIds,
          )
          .timeout(const Duration(seconds: 25));
      if (tracks.isEmpty) return null;
      final resolved = await KumaFlowBrainWaveResolver(subsonic)
          .resolve(tracks, maxTracks: 55)
          .timeout(const Duration(seconds: 90));
      if (resolved.missing.isNotEmpty) {
        bridge.noteMissing(resolved.missing.map((t) =>
            (t.externalId != null && t.externalId!.isNotEmpty)
                ? t.externalId!
                : t.trackId));
      }
      final found = resolved.found.map((r) => r.song).toList();
      return found.isEmpty ? null : found;
    } catch (_) {
      return null;
    }
  }

  Future<void> _applyWave() async {
    if (_isApplying) return;
    // Провайдеры — до первого await (use_build_context_synchronously).
    final bridgeRef = Provider.of<KumaFlowBrainBridge>(context, listen: false);
    KumaFlowBrainSettings? brainSettings;
    try {
      brainSettings =
          Provider.of<KumaFlowBrainSettings>(context, listen: false);
    } catch (_) {}
    setState(() => _isApplying = true);
    try {
      // Даём спиннеру отрисоваться; тяжёлый скоринг — в следующем кадре.
      await Future.delayed(const Duration(milliseconds: 60));
      await _persistSelection();
      // Пилюли — общие для всех устройств: пушим на мозг best-effort
      // (не ждём — волна строится параллельно, снэк покажет итог).
      try {
        final languageStrict = brainSettings?.languageStrict ?? false;
        final shared = <String, dynamic>{
          if (normalizeBrainActivity(_activity).isNotEmpty)
            'activity': normalizeBrainActivity(_activity),
          if (_characteristicServerValue != null)
            'characteristic': _characteristicServerValue,
          if (_mood.trim().isNotEmpty) 'mood': _mood.trim(),
          if (normalizeBrainLanguage(_lang).isNotEmpty)
            'language': normalizeBrainLanguage(_lang),
          if (languageStrict) 'language_strict': true,
        };
        unawaited(bridgeRef.pushSharedWaveSettings(shared));
      } catch (_) {}
      if (!mounted) return;
      // Сервер выбран (мост KumaFlow Brain активен) — запрос уходит в KumaFlow Brain,
      // а не считается локально. null = мост выкл/ошибка -> локальный путь.
      final brainSongs = await _buildKumaFlowBrainWave();
      if (!mounted) return;
      if (brainSongs != null) {
        final hint = _hintLine;
        final player = context.read<PlayerProvider>();
        final messenger = ScaffoldMessenger.of(context);
        Navigator.pop(context);
        player.playSong(brainSongs.first, playlist: brainSongs);
        messenger.showSnackBar(
          SnackBar(content: Text(hint.isEmpty ? 'Моя волна запущена (${brainSongs.length} треков) • KumaFlow Brain' : 'Волна: $hint • ${brainSongs.length} треков • KumaFlow Brain')),
        );
        return;
      }
      // Мост активен, но сервер треков не дал — честно показываем,
      // что играет локальная волна (диагностика, а не молчание).
      final brainWasActive = bridgeRef.isActive;
      final result = _buildWave();
      if (!mounted) return;
      final hint = _hintLine;
      Navigator.pop(context);
      final localMark =
          brainWasActive ? ' • локально (KumaFlow Brain не ответил)' : '';
      if (result.isNotEmpty) {
        context.read<PlayerProvider>().playSong(result.first, playlist: result);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(hint.isEmpty ? 'Моя волна запущена (${result.length} треков)$localMark' : 'Волна: $hint • ${result.length} треков$localMark')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ничего не нашлось — попробуйте смягчить фильтры')),
        );
      }
    } finally {
      if (mounted) setState(() => _isApplying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Каталог с сервера (канон): занятия/характер/язык. До загрузки —
    // зашитый fallback 1в1 с сервером, офлайн — он же.
    final brainOpts = context.watch<KumaFlowBrainBridge>().waveOptions;
    final brainOn = context.watch<KumaFlowBrainBridge>().isActive;
    final brainSettings = context.watch<KumaFlowBrainSettings>();
    final acts = brainOpts.activities.isNotEmpty
        ? brainOpts.activities
        : BrainWaveOptions.fallback.activities;
    final chars = brainOpts.characteristics.isNotEmpty
        ? brainOpts.characteristics
        : BrainWaveOptions.fallback.characteristics;
    final langs = brainOpts.languages.isNotEmpty
        ? brainOpts.languages
        : BrainWaveOptions.fallback.languages;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: SingleChildScrollView(
        controller: widget.scrollCtrl,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Container(width: 40, height: 4, decoration: BoxDecoration(color: isDark ? Colors.white24 : Colors.black12, borderRadius: BorderRadius.circular(2))),
                Positioned(
                  right: 0,
                  child: IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Настроить Мою волну', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            if (brainOn)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                    'пилюли общие для всех устройств 🧠 • каталог: ${_optionsSourceLabel(context, brainOpts)}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ),
            const SizedBox(height: 16),
            _catalogWrap(
              brainOn ? 'по занятию • с сервера 🧠' : 'по занятию',
              acts,
              _activity,
              (code) => setState(
                  () => _activity = code == _activity ? '' : code),
            ),
            const SizedBox(height: 12),
            _catalogWrap(
              'по характеру',
              chars,
              _character,
              (code) => setState(
                  () => _character = code == _character ? '' : code),
              icons: const {'favorite': '❤️', 'unfamiliar': '✨', 'popular': '⚡'},
            ),
            const SizedBox(height: 12),
            _group('под настроение', ['Бодрое', 'Весёлое', 'Спокойное', 'Грустное'], _mood, (v) => setState(() => _mood = v == _mood ? '' : v), colors: const [Color(0xFFFF6B00), Color(0xFF7ED321), Color(0xFF00C2FF), Color(0xFF3A5BFF)]),
            if (_serverMoodsLoading)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Center(
                  child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              ),
            if (!_serverMoodsLoading && _serverMoods.isNotEmpty) ...[
              const SizedBox(height: 12),
              _serverMoodRow(),
            ],
            const SizedBox(height: 12),
            _catalogWrap(
              'по языку',
              langs,
              _lang,
              (code) =>
                  setState(() => _lang = code == _lang ? '' : code),
            ),
            if (brainOn) ...[
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Строго по языку',
                      style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 8),
                  Switch(
                    value: brainSettings.languageStrict,
                    onChanged: (v) => brainSettings.setLanguageStrict(v),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Row(children: [
              TextButton(onPressed: () => setState(() { _activity=''; _character=''; _mood=''; _lang=''; }), child: const Text('Сбросить')),
              const Spacer(),
              FilledButton(
                onPressed: _isApplying ? null : _applyWave,
                child: _isApplying
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Применить'),
              ),
            ]),
          ],
        ),
        ),
      ),
    );
  }

  /// Пилюли из каталога сервера (9 занятий не влезают в Row — Wrap).
  /// selected/возврат — коды; подпись — label, hint — в Tooltip.
  Widget _catalogWrap(
    String title,
    List<BrainOption> items,
    String selected,
    void Function(String code) onTap, {
    Map<String, String>? icons,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Center(
          child: Text(title,
              style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[600],
                  fontWeight: FontWeight.w600))),
      const SizedBox(height: 8),
      Center(
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: items.map((o) {
            final sel = o.code == selected;
            final emoji = icons?[o.code];
            final pill = Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: sel
                    ? (isDark ? Colors.white : Colors.black)
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.grey[100]),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: sel
                        ? (isDark ? Colors.white : Colors.black)
                        : (isDark ? Colors.white24 : Colors.black12)),
              ),
              child: Text(
                emoji != null ? '$emoji ${o.display}' : o.display,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                    color: sel
                        ? (isDark ? Colors.black : Colors.white)
                        : (isDark ? Colors.white : Colors.black)),
              ),
            );
            final withTip = o.hint.trim().isNotEmpty
                ? Tooltip(message: o.hint, child: pill)
                : pill;
            return GestureDetector(onTap: () => onTap(o.code), child: withTip);
          }).toList(),
        ),
      ),
    ]);
  }

    /// Строка настроений с сервера мозга: те же пилюли, что в _group,
  /// но через Wrap (меток может быть до 6 — в Row не влезут).
  /// Тап пишет значение в _mood как есть (сервер нормализует сам).
  Widget _serverMoodRow() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Center(
          child: Text('настроение с сервера 🧠',
              style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[600],
                  fontWeight: FontWeight.w600))),
      const SizedBox(height: 8),
      Center(
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: _serverMoods.map((it) {
            final sel = it == _mood;
            return GestureDetector(
              onTap: () => setState(() => _mood = sel ? '' : it),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: sel
                      ? (isDark ? Colors.white : Colors.black)
                      : (isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.grey[100]),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: sel
                          ? (isDark ? Colors.white : Colors.black)
                          : (isDark ? Colors.white24 : Colors.black12)),
                ),
                child: Text(it,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            sel ? FontWeight.w700 : FontWeight.w500,
                        color: sel
                            ? (isDark ? Colors.black : Colors.white)
                            : (isDark ? Colors.white : Colors.black))),
              ),
            );
          }).toList(),
        ),
      ),
    ]);
  }

  Widget _group(String title, List<String> items, String selected, Function(String) onTap, {List<String>? icons, List<Color>? colors}) {    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Center(child: Text(title, style: TextStyle(fontSize: 11, color: Colors.grey[600], fontWeight: FontWeight.w600))),
      const SizedBox(height: 8),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: List.generate(items.length, (i) {
        final it = items[i];
        final sel = it == selected;
        Widget child;
        if (colors != null) {
          child = Column(children: [Container(width: 48, height: 48, decoration: BoxDecoration(shape: BoxShape.circle, color: colors[i], border: sel ? Border.all(color: isDark ? Colors.white : Colors.black, width: 2.5) : null, boxShadow: sel ? [BoxShadow(color: colors[i].withValues(alpha: 0.5), blurRadius: 8)] : null)), const SizedBox(height: 4), Text(it, style: TextStyle(fontSize: 11, fontWeight: sel ? FontWeight.w700 : FontWeight.w500))]);
        } else if (icons != null) {
          child = Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), decoration: BoxDecoration(color: sel ? (isDark ? Colors.white : Colors.black) : (isDark ? Colors.white10 : Colors.grey[100]), borderRadius: BorderRadius.circular(12), border: sel ? Border.all(color: isDark ? Colors.white : Colors.black, width: 1.5) : null), child: Column(children: [Text(icons[i], style: const TextStyle(fontSize: 20)), const SizedBox(height: 2), Text(it, style: TextStyle(fontSize: 11, color: sel ? (isDark ? Colors.black : Colors.white) : (isDark ? Colors.white : Colors.black), fontWeight: sel ? FontWeight.w700 : FontWeight.w500))]));
        } else {
          // pills "по занятию" / "по языку" — явная инверсия без ChoiceChip (фикс черный текст на черном)
          child = AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: sel ? (isDark ? Colors.white : Colors.black) : (isDark ? Colors.white.withValues(alpha: 0.08) : Colors.grey[100]),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: sel ? (isDark ? Colors.white : Colors.black) : (isDark ? Colors.white24 : Colors.black12)),
            ),
            child: Text(it, style: TextStyle(fontSize: 12, fontWeight: sel ? FontWeight.w700 : FontWeight.w500, color: sel ? (isDark ? Colors.black : Colors.white) : (isDark ? Colors.white : Colors.black))),
          );
        }
        return Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: GestureDetector(onTap: () => onTap(it), child: child));
      })),
    ]);
  }
}

