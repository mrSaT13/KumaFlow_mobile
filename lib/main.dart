import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'package:window_manager/window_manager.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:safe_device/safe_device.dart';

import 'l10n/app_localizations.dart';
import 'models/server_config.dart';
import 'services/services.dart';
import 'services/audio_handler.dart';
import 'services/transcoding_service.dart';
import 'services/local_music_service.dart';
import 'services/ml_service.dart';
import 'services/equalizer_service.dart';
import 'services/favorite_playlists_service.dart';
import 'services/offline_service.dart';
import 'services/remote_control/remote_client.dart';
import 'services/remote_control/remote_discovery.dart';
import 'services/sync_notification_service.dart';
import 'services/brain_new_arrivals_service.dart';
import 'services/brain_arrivals_bg.dart';
import 'widgets/privacy_policy_dialog.dart';
import 'providers/providers.dart';
import 'providers/podcast_provider.dart';
import 'screens/screens.dart';

import 'package:dynamic_color/dynamic_color.dart';
import 'theme/theme.dart';
import 'utils/image_cache.dart';
import 'services/yandex_music_api.dart';
import 'services/unified_music_auth.dart';
import 'services/artist_image_service.dart';
import 'services/image_cache_service.dart';
import 'services/safe_image_cache_manager.dart';
import 'services/yandex_music_public_api.dart';
import 'screens/splash_screen.dart';

/// Этап замера сети для экрана долгого подключения: мс или «—» при провале.
String _fmtStage(int? ms) {
  if (ms == null || ms < 0) return '—';
  if (ms >= 1000) return '${(ms / 1000).toStringAsFixed(1)}с';
  return '${ms}мс';
}

// Global instance for analytics (to be shown after auth)

/// Shows the privacy policy dialog on first launch
Future<void> _showPrivacyPolicyIfNeeded() async {
  if (await PrivacyPolicyDialog.shouldShow()) {
    // Small delay to ensure UI is fully loaded
    await Future.delayed(const Duration(milliseconds: 300));
    if (navigatorKey.currentContext != null) {
      final result = await showDialog<bool>(
        context: navigatorKey.currentContext!,
        builder: (context) => const PrivacyPolicyDialog(),
        barrierDismissible: false,
      );

      // If user declined, mark as accepted anyway to not show again
      // but we could handle this differently if needed
      if (result == false) {
        await PrivacyPolicyDialog.markAccepted();
      }
    }
  }
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Checks if the app is running on an emulator/simulator
Future<bool> _isRunningOnEmulator() async {
  if (kDebugMode) return false;
  if (kIsWeb) return false;
  if (!Platform.isAndroid && !Platform.isIOS) return false;

  return !(await SafeDevice.isRealDevice);
}

/// Widget shown when app is running on emulator
class _EmulatorWarningScreen extends StatelessWidget {
  const _EmulatorWarningScreen();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) {
          final l10n = AppLocalizations.of(context)!;
          return Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.block_rounded,
                      size: 80,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 32),
                    Text(
                      l10n.emulatorDetected,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.emulatorNotAllowed,
                      style: const TextStyle(
                        fontSize: 16,
                        color: Colors.grey,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 48),
                    FilledButton.icon(
                      onPressed: () {
                        SystemNavigator.pop();
                      },
                      icon: const Icon(Icons.exit_to_app),
                      label: Text(l10n.exitApp),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(200, 50),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Boot-хелперы для диагностики ANR: каждый тяжёлый init логирует старт/финиш
/// с миллисекундами, heartbeat каждые 5с показывает жив ли event loop.
/// Разрыв меток в logcat = окно блокировки главного потока.
/// ID запуска движка: два main() в одном процессе видны в логах по разным
/// ID (факт 13.10.2026: два полных инита при одном PID, мьютекс-сокет
/// обоих пропустил). Heartbeat с разными ID = два живых движка = война за БД.
final int engineId = DateTime.now().millisecondsSinceEpoch % 100000;
final DateTime _bootT0 = DateTime.now();
void _bootLog(String msg) => debugPrint(
    '[Boot#$engineId] +${DateTime.now().difference(_bootT0).inSeconds}s $msg');

/// Мьютекс первичного инстанса: ServerSocket на loopback держим весь срок
/// жизни процесса + ПРОВЕРКА КОННЕКТОМ (13.10.2026: голый bind обоих
/// пропустил — SO_REUSEADDR/двойной движок, два полных инита, война за БД).
/// Вторичный движок уходит тихо, тяжёлое дважды не стартует.
ServerSocket? _primarySocket;
const _mutexPort = 45931;

/// Жив ли первичный прямо сейчас: коннект к мьютекс-порту.
/// Успех = кто-то держит порт = мы вторичные.
Future<bool> _isPrimaryAlive() async {
  try {
    final s = await Socket.connect(
      InternetAddress.loopbackIPv4,
      _mutexPort,
      timeout: const Duration(milliseconds: 400),
    );
    try {
      s.destroy();
    } catch (_) {}
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> _claimPrimaryInstance() async {
  if (await _isPrimaryAlive()) {
    // Вторичный: даём первичному 2с (гонка сворачивания) и проверяем снова.
    await Future.delayed(const Duration(seconds: 2));
    if (await _isPrimaryAlive()) return false;
  }
  try {
    _primarySocket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4, _mutexPort);
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _timedInit(String name, Future<void> Function() fn) async {
  final sw = Stopwatch()..start();
  _bootLog('init start: $name');
  try {
    await fn();
    _bootLog('init done: $name in ${sw.elapsedMilliseconds}ms');
  } catch (e) {
    _bootLog('init error: $name after ${sw.elapsedMilliseconds}ms: $e');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _bootLog('main enter');
  // Второй движок в том же процессе тоже выполняет main() (дабл-тап по
  // иконке, 13.10.2026: два main enter с разницей 3мс, все иниты дважды,
  // война за БД → ANR + database locked 10с). Первый забрал порт —
  // остальные тихо уходят, тяжёлое не стартует дважды.
  if (!await _claimPrimaryInstance()) {
    _bootLog('secondary engine — skip heavy init');
    return;
  }
  // Heartbeat первые 3 мин: пока event loop жив — тики идут каждые 5с.
  var beats = 0;
  Timer.periodic(const Duration(seconds: 5), (t) {
    beats++;
    _bootLog('alive');
    if (beats >= 36) t.cancel();
  });

  JustAudioMediaKit.ensureInitialized(linux: true, windows: false);

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions();
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  ImageCacheConfig.configure();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ),
  );

  final storageService = StorageService();
  final subsonicService = SubsonicService();
  final offlineService = OfflineService();
  final libraryProvider = LibraryProvider(subsonicService);
  final recommendationService = RecommendationService();
  final localMusicService = LocalMusicService();
  final mlService = MLService();
  final castService = CastService();
  final localeService = LocaleService();
  final upnpService = UpnpService();
  final jukeboxService = JukeboxService();
  final themeService = ThemeService();
  final nowPlayingThemeService = NowPlayingThemeService();
  // KumaFlow Brain: по умолчанию ВЫКЛ, чисто локально.
  final brainSettings = KumaFlowBrainSettings();
  _timedInit('brain', () => brainSettings.load());
  final brainBridge = KumaFlowBrainBridge(brainSettings);
  brainBridge.onAutoAction = (msg) {
    try {
      final ctx = navigatorKey.currentContext;
      if (ctx != null) {
        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      debugPrint('[Brain] auto-action snackbar failed: $e');
    }
  };

  _timedInit('bpm', () => BpmAnalyzerService().initialize());
  // Remote control (десктоп в LAN): discovery фоном, клиент по требованию.
  final remoteDiscovery = RemoteDiscovery();
  final remoteClient = RemoteClient();
  _timedInit('remote', () => remoteDiscovery.init());
  _timedInit('bpmCrossfade', () => BpmCrossfadeService().initialize());
  // Критично для «Моей волны» — ждём до runApp, иначе пустая волна.
  // Некритичное (bpm/remote/brain) остаётся фоном.
  await Future.wait([
    _timedInit('offline', () => offlineService.initialize()),
    _timedInit('recommendations', () => recommendationService.initialize()),
    _timedInit('localMusic', () => localMusicService.initialize()),
  ]);
  // AI / Audiobookshelf services
  // ignore: avoid_dynamic_call
  try {
    (AiService() as dynamic).initialize();
  } catch (e) {
    debugPrint('[Init] AiService failed: $e');
  }
  try {
    (AudiobookshelfService() as dynamic).initialize();
  } catch (e) {
    debugPrint('[Init] Audiobookshelf failed: $e');
  }
  _timedInit('ml', () => mlService.initialize());

  // Local HTTP server so DLNA/UPnP renderers can fetch files stored on the
  // device (a renderer cannot open file:// URIs from the phone).
  LocalFileServer.instance.start();

  // Sync banned artists from MLService -> RecommendationService
  mlService.onBannedArtistsChanged = (ids, names) {
    recommendationService.updateBannedArtists(ids, names: names);
  };
  // Immediate sync after load - _loadData emits via microtask, but ensure current bans are pushed even if no new ban occurs
  Future.microtask(() {
    final ids = mlService.profile.bannedArtists.toSet();
    final names = mlService.profile.bannedArtistNames.values.toSet();
    if (ids.isNotEmpty || names.isNotEmpty) {
      recommendationService.updateBannedArtists(ids, names: names.isEmpty ? ids : names);
    }
  });
  localeService.loadSavedLocale().catchError((e) {
    debugPrint('Failed to load saved locale: $e');
  });
  await _timedInit('theme', () => themeService.initialize());
  _timedInit('jukebox', () => jukeboxService.initialize());
  _timedInit('nowPlayingTheme', () => nowPlayingThemeService.initialize());

  // Initialize equalizer service
  final equalizerService = EqualizerService();
  _timedInit('equalizer', () => equalizerService.initialize());

  // Initialize favorite playlists service
  _timedInit('favPlaylists', () => FavoritePlaylistsService().initialize());

  // Analytics removed per user request

  // Player UI settings - ne blokiruet start
  _timedInit('playerUi', () => PlayerUiSettingsService().initialize());

  // Initialise the audio service BEFORE runApp so the background audio engine
  // is ready and fully decoupled from the Flutter widget lifecycle on iOS.
  _bootLog('init start: audioService');
  final audioSw = Stopwatch()..start();
  final audioHandler = await initAudioService();
  _bootLog('init done: audioService in ${audioSw.elapsedMilliseconds}ms');

  // Create TranscodingService instance to share across providers
  final transcodingService = TranscodingService();

  // New services for Yandex Music integration - ne blokiruyut start (Substreamer Phase 2)
  final yandexMusicPublicApi = YandexMusicPublicApi();
  final yandexMusicApi = YandexMusicApi();
  yandexMusicApi.init().catchError((e) => debugPrint('yandex init error: $e'));
  final unifiedMusicAuth = UnifiedMusicAuth();
  final artistImageService = ArtistImageService(
    yandexApi: yandexMusicPublicApi,
    subsonic: subsonicService,
  );
  final imageCacheService = ImageCacheService();
  _timedInit('imageCache', () => imageCacheService.initialize());
  _bootLog('runApp');
  WidgetsBinding.instance.addPostFrameCallback((_) => _bootLog('first frame'));

  final Widget appWithProviders = MultiProvider(
    providers: [
      Provider<StorageService>.value(value: storageService),
      Provider<SubsonicService>.value(value: subsonicService),
      ChangeNotifierProvider<RecommendationService>.value(
        value: recommendationService,
      ),
      ChangeNotifierProvider<TranscodingService>.value(
        value: transcodingService,
      ),
      ChangeNotifierProvider<LocalMusicService>.value(value: localMusicService),
      ChangeNotifierProvider(
        create: (_) => AuthProvider(subsonicService, storageService),
      ),
      ChangeNotifierProvider<CastService>.value(value: castService),
      ChangeNotifierProvider<LocaleService>.value(value: localeService),
      ChangeNotifierProvider<ThemeService>.value(value: themeService),
      ChangeNotifierProvider<NowPlayingThemeService>.value(
        value: nowPlayingThemeService,
      ),
      ChangeNotifierProvider<UpnpService>.value(value: upnpService),
      ChangeNotifierProvider<JukeboxService>.value(value: jukeboxService),
      Provider<YandexMusicApi>.value(value: yandexMusicApi),
      Provider<UnifiedMusicAuth>.value(value: unifiedMusicAuth),
      Provider<ArtistImageService>.value(value: artistImageService),
      Provider<ImageCacheService>.value(value: imageCacheService),
      Provider<YandexMusicPublicApi>.value(value: yandexMusicPublicApi),
      ChangeNotifierProvider(
        create: (_) => PlayerProvider(
          subsonicService,
          storageService,
          castService,
          upnpService,
          audioHandler,
          jukeboxService,
          transcodingService,
        ),
      ),
      ChangeNotifierProvider<EqualizerService>.value(value: equalizerService),
      ChangeNotifierProvider<MLService>.value(value: mlService),
      ChangeNotifierProvider<LibraryProvider>.value(value: libraryProvider),
      ChangeNotifierProvider(create: (_) => YandexMusicProvider()),
      ChangeNotifierProvider(create: (_) => PodcastProvider()),
      ChangeNotifierProvider<OfflineService>.value(value: offlineService),
      ChangeNotifierProvider<KumaFlowBrainSettings>.value(value: brainSettings),
      ChangeNotifierProvider<KumaFlowBrainBridge>.value(value: brainBridge),
      ChangeNotifierProvider<BrainNewArrivalsService>.value(
          value: BrainNewArrivalsService.instance),
      ChangeNotifierProvider<RemoteDiscovery>.value(value: remoteDiscovery),
      ChangeNotifierProvider<RemoteClient>.value(value: remoteClient),
    ],
    child: const KumaFlowApp(),
  );

  // Привязка моста к плееру (best-effort, плеер работает и без KumaFlow Brain).
  // ignore: discarded_futures
  Future.microtask(() {
    try {
      // PlayerProvider создаётся в MultiProvider выше; находим через контекст.
      final ctx = navigatorKey.currentContext;
      if (ctx != null) {
        // ignore: use_build_context_synchronously
        Provider.of<PlayerProvider>(ctx, listen: false).attachBrain(brainBridge);
      }
    } catch (e) {
      debugPrint('[Init] attachBrain failed: $e');
    }
  });

  // Sweep corrupt cached images LAZILY: сразу на старте он гонялся с UI
  // за файлы (артисты не грузились на холодном старте). Ждём 30с после
  // старта, чтобы первые обложки успели прочитаться из кеша.
  // ignore: discarded_futures
  Future.delayed(const Duration(seconds: 30), () {
    try {
      SafeImageCacheManager.instance.purgeCorruptFiles();
    } catch (e) {
      debugPrint('purge delayed error: $e');
    }
  });

  // Android progress notifications for library sync + downloads
  // ignore: discarded_futures
  SyncNotificationService.instance
      .attach(libraryProvider, offlineService)
      .catchError((e) {
    debugPrint('Failed to attach sync notifications: $e');
  });

  // Новинки от отслеживаемых артистов (мозг -> системный пуш)
  // ignore: discarded_futures
  BrainNewArrivalsService.instance
      .attach(brainBridge, onTracks: (tracks) async {
    final done = <String>{};
    for (final t in tracks) {
      final id = t['id'] ?? '';
      if (id.isEmpty) continue;
      try {
        final ok = await offlineService.downloadTrack(
          trackId: id,
          title: (t['title'] ?? '').isEmpty ? 'Трек' : t['title']!,
          artist: (t['artist'] ?? '').isEmpty ? 'Unknown' : t['artist']!,
          subsonicService: subsonicService,
        );
        if (ok) done.add(id);
      } catch (_) {}
    }
    return done;
  }).catchError((e) {
    debugPrint('Failed to attach arrival notifications: $e');
  });

  // Фоновая проверка новинок (лёгкий опрос, без скачивания).
  // ignore: discarded_futures
  scheduleBrainArrivals().catchError((e) {
    debugPrint('Failed to schedule arrival checks: $e');
  });

  runApp(appWithProviders);
}

class KumaFlowApp extends StatelessWidget {
  const KumaFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    final localeService = Provider.of<LocaleService>(context);
    final themeService = Provider.of<ThemeService>(context);

    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        final accent = themeService.accentColor.color;

        final ThemeData light;
        final ThemeData dark;

        if (lightDynamic != null && darkDynamic != null) {
          // Override dynamic color scheme with user-selected accent color
          final harmonisedLight = lightDynamic.harmonized().copyWith(
                primary: accent,
                secondary: accent.withAlpha(200),
              );
          final harmonisedDark = darkDynamic.harmonized().copyWith(
                primary: accent,
                secondary: accent.withAlpha(200),
              );
          light = AppTheme.lightThemeFromScheme(harmonisedLight);
          dark = AppTheme.darkThemeFromScheme(harmonisedDark);
        } else {
          light = AppTheme.lightThemeWith(accent);
          dark = AppTheme.darkThemeWith(accent);
        }

        return MaterialApp(
          title: 'KumaFlow',
          debugShowCheckedModeBanner: false,
          theme: light,
          darkTheme: dark,
          themeMode: themeService.themeMode,
          navigatorKey: navigatorKey,
          locale: localeService.currentLocale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const AuthWrapper(),
        );
      },
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool? _wizardDone;
  bool _minSplashElapsed = false;
  bool _maxSplashTimeout = false;
  // MainScreen уже показывали в этой сессии: re-auth поверх живого экрана
  // (возврат сети, ручная проверка) не должен мигать сплэшем — обновление
  // идёт фоном. Флаг сбрасывается при уходе на login/unreachable.
  bool _showedMain = false;
  bool _lastMainOffline = false;

  @override
  void initState() {
    super.initState();
    _checkWizard();
    // Brain -> Player привязка (идемпотентно, best-effort).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final brain = Provider.of<KumaFlowBrainBridge>(context, listen: false);
        Provider.of<PlayerProvider>(context, listen: false).attachBrain(brain);
      } catch (e) {
        debugPrint('[AuthWrapper] attachBrain failed: $e');
      }
    });
    // Splash min 2s / max 15s
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _minSplashElapsed = true);
    });
    Future.delayed(const Duration(seconds: 15), () {
      if (mounted) setState(() => _maxSplashTimeout = true);
    });
  }

  Future<void> _checkWizard() async {
    final done = await OnboardingWizardScreen.isDone();
    if (mounted) setState(() => _wizardDone = done);
  }

  void _onWizardDone() {
    setState(() => _wizardDone = true);
  }

  @override
  Widget build(BuildContext context) {
    // Стартовый гейт ОДНИМ виджетом: раньше корневой SplashScreen сменялся
    // _AuthenticatingSplash, который создавал SplashScreen заново в другой
    // позиции дерева — intro-анимация и стадии рестартовали, выглядело как
    // «двойной сплэшскрин». Теперь _StartupGate живёт на том же слоте все
    // предстартовые состояния, SplashScreen внутри него не пересоздаётся.
    if (!_minSplashElapsed) {
      return const _StartupGate();
    }
    // Max 15s timeout - esli vse esche gruzimsya, pokazivaem oshibku
    if (_maxSplashTimeout && _wizardDone == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.hourglass_empty_rounded, size: 48, color: Colors.white54),
              const SizedBox(height: 16),
              const Text('Загрузка занимает слишком долго', style: TextStyle(color: Colors.white)),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => setState(() => _maxSplashTimeout = false), child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }
    // Show wizard on first launch before anything else
    if (_wizardDone == null) {
      return const _StartupGate();
    }
    if (_wizardDone == false) {
      return OnboardingWizardScreen(onDone: _onWizardDone);
    }

    final authProvider = Provider.of<AuthProvider>(context);
    final mlService = Provider.of<MLService>(context);

    switch (authProvider.state) {
      case AuthState.unknown:
        // Ловушки «не удалось/долго» удалены (дублировали unreachable):
        // пока идёт проверка — сплэш, при провале — один экран unreachable.
        return const _StartupGate();
      case AuthState.authenticated:
        // Show privacy policy first if needed
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          await _showPrivacyPolicyIfNeeded();
        });
        // Cold-start ML onboarding on first login
        if (!mlService.coldStartDone) {
          _showedMain = false;
          return const ColdStartOnboardingScreen();
        }
        _showedMain = true;
        _lastMainOffline = false;
        return const MainScreen();
      case AuthState.offlineMode:
        _showedMain = true;
        _lastMainOffline = true;
        return const MainScreen(isOfflineMode: true);
      case AuthState.serverUnreachable:
        _showedMain = false;
        return _ServerUnreachableScreen(
          hasOfflineContent: authProvider.hasOfflineContent,
          onEnterOfflineMode: () => authProvider.enterOfflineMode(),
          onDisconnect: () => authProvider.disconnect(),
        );
      case AuthState.authenticating:
        // Re-auth поверх живого MainScreen (возврат сети, ручная проверка) —
        // остаёмся на нём, обновление фоновое. Сплэш только на холодном старте.
        if (_showedMain) {
          return _lastMainOffline
              ? const MainScreen(isOfflineMode: true)
              : const MainScreen();
        }
        // Проверка висит до ~17с при мёртвом сервере (пинг 5с+12с, факт
        // 15.10.2026: connectionTimeout на залипшем IP). Через 5с проверки
        // показываем выход поверх сплэша — ждать конец пинга не надо.
        // Провал пинга — экран unreachable как раньше. Сам сплэш при этом
        // НЕ пересоздаётся (единый _StartupGate — иначе двойной сплэш).
        return const _StartupGate(allowEscape: true);
      case AuthState.unauthenticated:
      case AuthState.error:
        _showedMain = false;
        return const LoginScreen();
    }
  }
}

/// Единый стартовый гейт: SplashScreen создаётся ОДИН раз и живёт на том же
/// слоте дерева все предстартовые состояния (min-splash, wizard-unknown,
/// auth-unknown/authenticating). Кнопки «Офлайн/Повторить» при долгой
/// проверке — оверлеем поверх, а не заменой экрана: замена пересоздавала
/// SplashScreen с рестартом intro и стадий («двойной сплэшскрин», факт
/// 15.10.2026: AuthWrapper → _AuthenticatingSplash → новый SplashScreen).
class _StartupGate extends StatefulWidget {
  final bool allowEscape;
  const _StartupGate({this.allowEscape = false});

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  bool _escape = false;
  Timer? _escapeTimer;

  @override
  void initState() {
    super.initState();
    _armEscape();
  }

  @override
  void didUpdateWidget(_StartupGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.allowEscape && !oldWidget.allowEscape) _armEscape();
  }

  void _armEscape() {
    if (!widget.allowEscape || _escape || _escapeTimer != null) return;
    _escapeTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && widget.allowEscape) setState(() => _escape = true);
    });
  }

  @override
  void dispose() {
    _escapeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_escape) return const SplashScreen();
    final auth = Provider.of<AuthProvider>(context, listen: false);
    // Только кнопки: статус уже показывает сам сплэш (стадии), второй текст
    // поверх давал наложение строк (факт 15.10.2026: «Версия v3.7.45+2075»
    // поверх «соединение с»). Кнопки внизу, версию не перекрывают.
    return Stack(
      children: [
        const SplashScreen(),
        Positioned(
          left: 0,
          right: 0,
          bottom: 40,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.tonal(
                  onPressed: () => auth.enterOfflineMode(),
                  child: const Text('Открыть офлайн'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => auth.retryConnection(),
                  child: const Text('Повторить проверку'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Диагностика сети на экране unreachable: честная классификация ошибки
/// (сертификат отдельно от сети, идея yuzic addressProbe) + замеры
/// DNS/TCP/TLS. Без гейтов — видно всегда, а не только при err != null.
class _NetDiagnostics extends StatelessWidget {
  const _NetDiagnostics();

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final err = auth.lastError ?? '';
    final isCert =
        err.isNotEmpty && SubsonicService.classifyConnectionError(err) == 'cert';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (err.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              isCert
                  ? 'Похоже на отказ сертификата: проверь дату LE на Keenetic или включи «Доверять самоподписанным» в настройках сервера.'
                  : err,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ),
        FutureBuilder<Map<String, int>>(
          future: Provider.of<SubsonicService>(context, listen: false)
              .probeStages(),
          builder: (ctx, snap) {
            final m = snap.data;
            final txt = m == null
                ? 'Замер сети…'
                : 'Сеть: DNS ${_fmtStage(m['dns'])} · '
                    'TCP ${_fmtStage(m['tcp'])} · '
                    'TLS ${_fmtStage(m['tls'])}';
            return Text(txt,
                style:
                    const TextStyle(color: Colors.white38, fontSize: 11),
                textAlign: TextAlign.center);
          },
        ),
      ],
    );
  }
}

class _ServerUnreachableScreen extends StatelessWidget {
  final bool hasOfflineContent;
  final VoidCallback onEnterOfflineMode;
  final VoidCallback onDisconnect;

  const _ServerUnreachableScreen({
    required this.hasOfflineContent,
    required this.onEnterOfflineMode,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 72, color: Colors.grey),
              const SizedBox(height: 24),
              Text(
                AppLocalizations.of(context)!.serverUnreachableTitle,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                AppLocalizations.of(context)!.serverUnreachableSubtitle,
                style: const TextStyle(color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              // Диагностика сети — всегда видна (раньше пряталась за err-gate
              // на удалённом экране-дубликате и её никто не видел).
              _NetDiagnostics(),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => authProvider.retryConnection(),
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(AppLocalizations.of(context)!.retry),
                ),
              ),
              const SizedBox(height: 12),
              _buildSwitchProfileButton(context),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onEnterOfflineMode,
                  icon: const Icon(Icons.offline_pin_rounded),
                  label: Text(AppLocalizations.of(context)!.openOfflineMode),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onDisconnect,
                  icon: const Icon(Icons.logout_rounded),
                  label: Text(AppLocalizations.of(context)!.disconnect),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSwitchProfileButton(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final l10n = AppLocalizations.of(context)!;

    return FutureBuilder<List<ServerConfig>>(
      future: authProvider.getSavedProfiles(),
      builder: (context, snapshot) {
        final profiles = snapshot.data ?? [];
        if (profiles.isEmpty) return const SizedBox.shrink();

        final currentConfig = authProvider.config;
        final otherProfiles = profiles
            .where(
              (p) =>
                  p.serverUrl != currentConfig?.serverUrl ||
                  p.username != currentConfig?.username,
            )
            .toList();

        if (otherProfiles.isEmpty) return const SizedBox.shrink();

        return SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => _showSwitchProfileDialog(context, otherProfiles),
            icon: const Icon(Icons.swap_horiz_rounded),
            label: Text(l10n.switchServer),
          ),
        );
      },
    );
  }

  void _showSwitchProfileDialog(
      BuildContext context, List<ServerConfig> profiles) {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final l10n = AppLocalizations.of(context)!;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Theme.of(ctx).brightness == Brightness.dark
              ? AppTheme.darkSurface
              : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 5,
                decoration: BoxDecoration(
                  color: Theme.of(ctx).brightness == Brightness.dark
                      ? AppTheme.darkDivider
                      : AppTheme.lightDivider,
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.switchServer,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              ...profiles.map((profile) {
                final label = profile.name?.isNotEmpty == true
                    ? profile.name!
                    : '${profile.username}@${Uri.tryParse(profile.serverUrl)?.host ?? profile.serverUrl}';
                return ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(label),
                  subtitle: Text(profile.serverUrl,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await authProvider.switchProfile(profile);
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

