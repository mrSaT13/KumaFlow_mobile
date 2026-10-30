import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/providers.dart';
import '../services/local_music_service.dart';
import '../services/ml_service.dart';
import '../services/recommendation_service.dart';
import '../services/theme_service.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../utils/navigation_helper.dart';
import '../widgets/widgets.dart';
import '../widgets/app_gradient_background.dart';
import '../l10n/app_localizations.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'search_screen.dart';
import 'mixes_screen.dart';
import 'settings_screen.dart';
import 'now_playing_screen.dart';
import 'fantasy_screen.dart';
import 'tv_home_screen.dart';
import 'audiobookshelf_screen.dart';
import '../services/audiobookshelf_service.dart';
import '../services/ai_mix_service.dart';
import '../services/offline_service.dart';
import '../services/remote_control/remote_discovery.dart';
import '../services/remote_control/remote_device.dart';
import '../services/remote_control/remote_notify.dart';
import '../services/subsonic_service.dart';
import 'remote_control_screen.dart';

Future<AiMixService> importAiMix() async => AiMixService();

class MainScreen extends StatefulWidget {
  final bool isOfflineMode;

  const MainScreen({super.key, this.isOfflineMode = false});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  int _searchTapCount = 0;
  DateTime _lastSearchTap = DateTime.fromMillisecondsSinceEpoch(0);
  bool _showRightSidebar = true;
  final Set<String> _remoteBannerDismissed = {};

  List<Widget> get _screens {
    final base = <Widget>[
      const HomeScreen(),
      const LibraryScreen(),
      const SearchScreen(),
      const MixesScreen(),
    ];
    if (AudiobookshelfService().enabled) {
      base.add(const AudiobookshelfScreen());
    }
    base.add(const SettingsScreen());
    return base;
  }

  int get _settingsIndex => _screens.length - 1;
  int get _absIndex => AudiobookshelfService().enabled ? _screens.length - 2 : -1;

  void _onAbsToggled() {
    if (!mounted) return;
    final max = _screens.length - 1;
    if (_currentIndex > max) setState(() => _currentIndex = max);
  }

  /// Бесшовный возврат сети: сбрасываем залипший серверный флаг и тихо
  /// тянем свежие данные (музыка не прерывается, рестарт не нужен).
  void _onOfflineChanged() {
    if (!mounted) return;
    try {
      final lib = Provider.of<LibraryProvider>(context, listen: false);
      final off = OfflineService().isOfflineMode;
      lib.setServerOfflineMode(off);
      if (!off) {
        lib.refreshOnline();
      } else {
        setState(() {});
      }
    } catch (_) {}
  }

  /// Пилюля «Найден KumaFlow в сети» — тап ведёт на страницу пульта.
  /// Новое несохранённое + сохранённое-в-сети (проба прошла, свежее 10 мин).
  Widget _buildRemoteFoundBanner() {
    try {
      final discovery = context.watch<RemoteDiscovery>();
      final savedIds = discovery.saved.map((e) => e.id).toSet();
      final savedHosts = discovery.saved.map((e) => e.host).toSet();
      final freshNew = discovery.found.where((d) {
        if (savedIds.contains(d.id)) return false;
        if (_remoteBannerDismissed.contains(d.id)) return false;
        return DateTime.now().difference(d.lastSeen) <
            const Duration(minutes: 10);
      }).toList();
      final freshSaved = discovery.found.where((d) {
        if (_remoteBannerDismissed.contains('saved:${d.host}')) return false;
        final known = savedIds.contains(d.id) || savedHosts.contains(d.host);
        if (!known) return false;
        return DateTime.now().difference(d.lastSeen) <
            const Duration(minutes: 10);
      }).toList();
      RemoteDevice? d;
      String? label;
      String? dismissKey;
      if (freshNew.isNotEmpty) {
        d = freshNew.first;
        label = 'Найден KumaFlow: ${d.name} — управлять?';
        dismissKey = d.id;
      } else if (freshSaved.isNotEmpty) {
        d = freshSaved.first;
        label = 'Пульт в сети: ${d.name} — открыть управление?';
        dismissKey = 'saved:${d.host}';
      }
      if (d == null) return const SizedBox.shrink();
      final dd = d;
      final dk = dismissKey!;
      return Container(
        width: double.infinity,
        color: const Color(0xFF4E8CA8),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
            child: Row(
              children: [
                const Icon(CupertinoIcons.desktopcomputer,
                    color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label!,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const RemoteControlScreen()),
                    );
                  },
                  child: const Text('Пульт',
                      style: TextStyle(color: Colors.white)),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: Colors.white70, size: 18),
                  onPressed: () => setState(
                      () => _remoteBannerDismissed.add(dk)),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (_) {
      return const SizedBox.shrink();
    }
  }

  @override
  void dispose() {
    AudiobookshelfService().enabledNotifier.removeListener(_onAbsToggled);
    try {
      OfflineService().removeListener(_onOfflineChanged);
    } catch (_) {}
    super.dispose();
  }

  @override
  void initState() {
    super.initState();

    _checkTvMode();
    AudiobookshelfService().enabledNotifier.addListener(_onAbsToggled);
    try {
      OfflineService().addListener(_onOfflineChanged);
    } catch (_) {}
    // Системное уведомление о найденном ПК (in-app пилюля — сама по себе).
    // onSavedOnline — только уведомления про сохранённый в сети, коннект не трогаем.
    try {
      final discovery =
          Provider.of<RemoteDiscovery>(context, listen: false);
      discovery.onFound = (d) {
        RemoteFoundNotify.instance.showFound(d);
      };
      discovery.onSavedOnline = (d) {
        RemoteFoundNotify.instance.showFound(d);
      };
      discovery.autoDiscoverOnce();
    } catch (_) {}
    NavigationHelper.registerTabChangeCallback((index) {
      setState(() => _currentIndex = index);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final libraryProvider = Provider.of<LibraryProvider>(
        context,
        listen: false,
      );
      final playerProvider = Provider.of<PlayerProvider>(
        context,
        listen: false,
      );
      final recommendationService = Provider.of<RecommendationService>(
        context,
        listen: false,
      );

      playerProvider.setLibraryProvider(libraryProvider);
      playerProvider.setRecommendationService(recommendationService);
      // Синк не душит сервер/стрим пока играет: LibraryProvider ждёт 3с
      // и идёт мелкими батчами с паузами.
      libraryProvider.playingCheck = () => playerProvider.isPlaying;
      // Wire banned-artist → queue cleanup (chain with existing main.dart sync)
      final mlSvc = Provider.of<MLService>(context, listen: false);
      final prevBannedCb = mlSvc.onBannedArtistsChanged;
      mlSvc.onBannedArtistsChanged = (ids, names) {
        prevBannedCb?.call(ids, names);
        playerProvider.cleanQueueFromBannedArtists(ids, names);
      };

      final localMusicService = Provider.of<LocalMusicService>(
        context,
        listen: false,
      );

      // Always wire local music service so ML/DJ/search can include local songs
      playerProvider.setLocalMusicService(localMusicService);

      if (authProvider.isLocalOnlyMode) {
        libraryProvider.setLocalMusicService(localMusicService, mergeWithServer: false);
        libraryProvider.setLocalOnlyMode(true);

        if (localMusicService.isEmpty && !localMusicService.isScanning) {
          localMusicService.scanForMusic();
        } else if (!localMusicService.isScanning) {
          libraryProvider.initialize();
        }
      } else {
        libraryProvider.setLocalOnlyMode(false);
        libraryProvider.setServerOfflineMode(widget.isOfflineMode);
        // Respect saved merge preference — don't force-enable on every restart
        final prefs = await SharedPreferences.getInstance();
        final savedMerge = prefs.getBool('merge_local_library') ?? false;
        libraryProvider.setLocalMusicService(localMusicService, mergeWithServer: savedMerge);
        libraryProvider.initialize();
      }

      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) _checkForUpdate();
      });

      // Daily AI mix (раз в день, не блокирует UI)
      Future.delayed(const Duration(seconds: 6), () async {
        if (!mounted) return;
        try {
          final lib = Provider.of<LibraryProvider>(context, listen: false);
          // wait until library has songs
          for (int i=0; i<10; i++) {
            if (lib.cachedAllSongs.isNotEmpty || lib.randomSongs.isNotEmpty) break;
            await Future.delayed(const Duration(seconds: 1));
          }
          final pool = await lib.getPoolForMix(limit: 700);
          if (pool.isEmpty) return;
          final aiMix = await importAiMix();
          final res = await aiMix.generateDailyAutoMix(library: pool);
          if (res != null && mounted) {
            // create server playlist silently
            try {
              final sub = Provider.of<SubsonicService>(context, listen: false);
              await aiMix.createServerPlaylist(subsonic: sub, result: res);
              await lib.loadPlaylists();
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ежедневный ИИ-микс "${res.name}" создан'), duration: const Duration(seconds: 3)));
            } catch (_) {}
          }
        } catch (e) { debugPrint('[DailyAI] error: $e'); }
      });
    });
  }

  Future<void> _checkForUpdate() async {
    final release = await UpdateService.checkForUpdate();
    if (release == null || !mounted) return;
    _showUpdateDialog(release);
  }

  void _showUpdateDialog(ReleaseInfo release) {
    final l10n = AppLocalizations.of(context)!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final changelog = UpdateService.stripMarkdown(release.body);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 600),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppTheme.appleMusicRed, AppTheme.appleMusicPink],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      CupertinoIcons.arrow_up_circle_fill,
                      color: Colors.white,
                      size: 40,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.updateAvailable,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.updateAvailableSubtitle,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _VersionBadge(
                          label: l10n.updateCurrentVersion(
                            UpdateService.currentVersion,
                          ),
                          color: Colors.white24,
                        ),
                        const SizedBox(width: 8),
                        const Icon(
                          CupertinoIcons.arrow_right,
                          color: Colors.white70,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        _VersionBadge(
                          label: l10n.updateLatestVersion(release.version),
                          color: Colors.white.withValues(alpha: 0.3),
                          bold: true,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (changelog.isNotEmpty)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          l10n.whatsNew,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: isDark ? Colors.white54 : Colors.black45,
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Flexible(
                          child: Scrollbar(
                            thumbVisibility: true,
                            child: SingleChildScrollView(
                              child: Text(
                                changelog,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.5,
                                  color:
                                      isDark ? Colors.white70 : Colors.black87,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(l10n.remindLater),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          Navigator.of(ctx).pop();
                          // Прямая ссылка на APK из релиза если есть —
                          // браузер скачает, система предложит установку.
                          // Иначе открываем страницу релиза.
                          final uri = Uri.parse(release.downloadUrl);
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(
                              uri,
                              mode: LaunchMode.externalApplication,
                            );
                          }
                        },
                        icon: Icon(
                          release.hasDirectApk
                              ? CupertinoIcons.cloud_download
                              : CupertinoIcons.arrow_up_right,
                          size: 18,
                        ),
                        label: Text(release.hasDirectApk
                            ? 'Скачать APK'
                            : l10n.downloadUpdate),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          backgroundColor: AppTheme.appleMusicRed,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
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

  void _openNowPlaying() {
    Navigator.of(context)
        .push(
      PageRouteBuilder(
        opaque: true,
        barrierColor: Colors.transparent,
        pageBuilder: (context, animation, secondaryAnimation) {
          return const NowPlayingScreen();
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(0.0, 1.0);
          const end = Offset.zero;
          const curve = Curves.easeOutCubic;

          var tween = Tween(
            begin: begin,
            end: end,
          ).chain(CurveTween(curve: curve));

          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 400),
      ),
    )
        .then((_) async {
      if (!mounted) return;
      if (Platform.isIOS) {
        // Wait longer for the transition to complete and audio session to stabilize
        await Future.delayed(const Duration(milliseconds: 300));
        if (!mounted) return;
        Provider.of<PlayerProvider>(context, listen: false)
            .reactivateAudioSession();
      }
    });
  }

  bool get _isDesktop {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  bool _isTvMode = false;

  Future<void> _checkTvMode() async {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) return;
    try {
      // Check if this is a TV device by looking for TV-specific features
      // Android TV typically has a touchscreen=false feature.
      // The method lives on the AndroidSystemPlugin channel; a MissingPlugin
      // or exception simply means we are not on a TV device.
      const channel = MethodChannel('com.kumaflow.app/android_system');
      final isTv = await channel.invokeMethod<bool>('isTvDevice') ?? false;
      if (mounted && isTv) {
        setState(() => _isTvMode = true);
      }
    } catch (_) {
      // Not a TV device or method not available
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final isLocalMode = authProvider.isLocalOnlyMode;

    // TV mode
    if (_isTvMode) {
      return const TvHomeScreen();
    }

    if (_isDesktop) {
      return AppGradientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    DesktopNavigationSidebar(
                      selectedIndex: _currentIndex,
                      onDestinationSelected: (index) {
                        setState(() => _currentIndex = index);
                        NavigationHelper.desktopNavigatorKey.currentState
                            ?.popUntil((route) => route.isFirst);
                      },
                      navigatorKey: NavigationHelper.desktopNavigatorKey,
                    ),
                    Expanded(
                      child: Navigator(
                        key: NavigationHelper.desktopNavigatorKey,
                        onGenerateRoute: (settings) {
                          return PageRouteBuilder(
                            pageBuilder: (ctx, anim, _) => IndexedStack(
                              index: _currentIndex,
                              children: _screens,
                            ),
                            transitionsBuilder: (ctx, animation, _, child) {
                              return FadeTransition(
                                opacity: animation,
                                child: child,
                              );
                            },
                          );
                        },
                      ),
                    ),
                  if (_showRightSidebar)
                    Selector<PlayerProvider, bool>(
                      selector: (_, p) =>
                          p.currentSong != null || p.isPlayingRadio,
                      builder: (context, hasCurrentSong, _) {
                        return hasCurrentSong
                            ? const RightSidebar()
                            : const SizedBox.shrink();
                      },
                    ),
                ],
              ),
            ),
              Selector<PlayerProvider, bool>(
                selector: (_, p) => p.currentSong != null || p.isPlayingRadio,
                builder: (context, hasCurrentSong, _) {
                  return hasCurrentSong
                      ? DesktopPlayerBar(
                          navigatorKey: NavigationHelper.desktopNavigatorKey,
                        )
                      : const SizedBox.shrink();
                },
              ),
            ],
          ),
        ),
      );
    }

    final bool liquidGlass = Provider.of<ThemeService>(context).liquidGlass;
    return Selector<PlayerProvider, bool>(
      selector: (_, p) => p.currentSong != null || p.isPlayingRadio,
      builder: (context, hasCurrentSong, _) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _handleBackButton();
          },
          child: AppGradientBackground(
            child: Scaffold(
              backgroundColor: Colors.transparent,
              resizeToAvoidBottomInset: false,
              body: Column(
              children: [
                if (widget.isOfflineMode || isLocalMode)                  Container(
                    width: double.infinity,
                    color: isLocalMode ? Colors.indigo : Colors.orange,
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 16,
                    ),
                    child: SafeArea(
                      bottom: false,
                      child: Row(
                        children: [
                          Icon(
                            isLocalMode
                                ? CupertinoIcons.folder_fill
                                : CupertinoIcons.wifi_slash,
                            color: Colors.white,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              isLocalMode
                                  ? AppLocalizations.of(
                                      context,
                                    )!
                                      .localFilesModeBanner
                                  : AppLocalizations.of(
                                      context,
                                    )!
                                      .offlineModeBanner,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (!isLocalMode)
                            IconButton(
                              icon: const Icon(
                                CupertinoIcons.refresh,
                                color: Colors.white,
                                size: 18,
                              ),
                              tooltip: 'Проверить соединение',
                              onPressed: () async {
                                try {
                                  final auth = Provider.of<AuthProvider>(
                                      context,
                                      listen: false);
                                  await auth.retryConnection();
                                } catch (_) {}
                                try {
                                  final lib = Provider.of<LibraryProvider>(
                                      context,
                                      listen: false);
                                  lib.setServerOfflineMode(
                                      OfflineService().isOfflineMode);
                                  await lib.refreshOnline();
                                } catch (_) {}
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                _buildRemoteFoundBanner(),
                if (isLocalMode)
                  Selector<LocalMusicService, (bool, double, String)>(
                    selector: (_, s) =>
                        (s.isScanning, s.scanProgress, s.scanStatus),
                    builder: (context, data, _) {
                      final (isScanning, progress, status) = data;
                      if (!isScanning) return const SizedBox.shrink();
                      return Container(
                        color: Theme.of(context)
                            .colorScheme
                            .primaryContainer
                            .withValues(alpha: 0.85),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                status,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            if (progress > 0)
                              Text(
                                '${(progress * 100).toStringAsFixed(0)}%',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                Expanded(
                  child: Navigator(
                    key: NavigationHelper.mobileNavigatorKey,
                    onGenerateRoute: (settings) {
                      return MaterialPageRoute(
                        builder: (_) => IndexedStack(
                          index: _currentIndex,
                          children: _screens,
                        ),
                      );
                    },
                  ),
                ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasCurrentSong) MiniPlayer(onTap: _openNowPlaying),
                      liquidGlass
                          ? _buildGlassBottomNav(context)
                          : _buildBottomNav(context),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _handleBackButton() {
    final navigatorState = NavigationHelper.mobileNavigatorKey.currentState;
    if (navigatorState != null && navigatorState.canPop()) {
      navigatorState.pop();
      return;
    }

    if (_currentIndex != 0) {
      setState(() => _currentIndex = 0);
      return;
    }

    SystemNavigator.pop();
  }

  Widget _buildGlassBottomNav(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = theme.colorScheme.primary;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final l10n = AppLocalizations.of(context)!;

    final items = [
      (
        icon: Icons.home_outlined,
        activeIcon: Icons.home_rounded,
        label: l10n.home,
      ),
      (
        icon: Icons.grid_view_outlined,
        activeIcon: Icons.grid_view_rounded,
        label: l10n.library,
      ),
      (
        icon: Icons.search_outlined,
        activeIcon: Icons.search_rounded,
        label: l10n.search,
      ),
      (
        icon: Icons.graphic_eq_rounded,
        activeIcon: Icons.graphic_eq_rounded,
        label: l10n.mixtapes,
      ),
      if (AudiobookshelfService().enabled)
        (
          icon: Icons.menu_book_outlined,
          activeIcon: Icons.menu_book_rounded,
          label: 'Книги',
        ),
      (
        icon: Icons.settings_outlined,
        activeIcon: Icons.settings_rounded,
        label: l10n.settings,
      ),
    ];

    return Padding(
      padding: EdgeInsets.fromLTRB(12, 4, 12, safeBottom > 0 ? safeBottom : 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.14),
              blurRadius: 28,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              height: 62,
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.5)
                    : Colors.white.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.1)
                      : Colors.white.withValues(alpha: 0.8),
                  width: 0.8,
                ),
              ),
              child: Row(
                children: List.generate(items.length, (idx) {
                  final item = items[idx];
                  final isSelected = _currentIndex == idx;
                  return Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        final navigatorState =
                            NavigationHelper.mobileNavigatorKey.currentState;
                        navigatorState?.popUntil((route) => route.isFirst);

                        if (idx == 2) {
                          final now = DateTime.now();
                          if (now.difference(_lastSearchTap).inSeconds > 3) {
                            _searchTapCount = 0;
                          }
                          _searchTapCount++;
                          _lastSearchTap = now;
                          if (_searchTapCount >= 11) {
                            _searchTapCount = 0;
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const FantasyScreen(),
                              ),
                            );
                            return;
                          }
                        } else {
                          _searchTapCount = 0;
                        }

                        setState(() => _currentIndex = idx);
                      },
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 150),
                            child: Icon(
                              isSelected ? item.activeIcon : item.icon,
                              key: ValueKey(isSelected),
                              color: isSelected
                                  ? accent
                                  : (isDark ? Colors.white54 : Colors.black38),
                              size: 22,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            item.label,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: isSelected
                                  ? accent
                                  : (isDark ? Colors.white54 : Colors.black38),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomNav(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA),
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) {
            final navigatorState =
                NavigationHelper.mobileNavigatorKey.currentState;
            navigatorState?.popUntil((route) => route.isFirst);

            if (index == 2) {
              final now = DateTime.now();
              if (now.difference(_lastSearchTap).inSeconds > 3) {
                _searchTapCount = 0;
              }
              _searchTapCount++;
              _lastSearchTap = now;
              if (_searchTapCount >= 11) {
                _searchTapCount = 0;
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const FantasyScreen()),
                );
                return;
              }
            } else {
              _searchTapCount = 0;
            }

            setState(() => _currentIndex = index);
          },
          items: [
            BottomNavigationBarItem(
              icon: const Icon(Icons.home_outlined),
              activeIcon: const Icon(Icons.home_rounded),
              label: l10n.home,
            ),
            BottomNavigationBarItem(
              icon: const Icon(Icons.grid_view_outlined),
              activeIcon: const Icon(Icons.grid_view_rounded),
              label: l10n.library,
            ),
            BottomNavigationBarItem(
              icon: const Icon(Icons.search_outlined),
              activeIcon: const Icon(Icons.search_rounded),
              label: l10n.search,
            ),
            BottomNavigationBarItem(
              icon: const Icon(Icons.graphic_eq_rounded),
              activeIcon: const Icon(Icons.graphic_eq_rounded),
              label: l10n.mixtapes,
            ),
            if (AudiobookshelfService().enabled)
              const BottomNavigationBarItem(
                icon: Icon(Icons.menu_book_outlined),
                activeIcon: Icon(Icons.menu_book_rounded),
                label: 'Книги',
              ),
            BottomNavigationBarItem(
              icon: const Icon(Icons.settings_outlined),
              activeIcon: const Icon(Icons.settings_rounded),
              label: l10n.settings,
            ),
          ],
        ),
      ),
    );
  }
}

class _VersionBadge extends StatelessWidget {
  final String label;
  final Color color;
  final bool bold;

  const _VersionBadge({
    required this.label,
    required this.color,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}
