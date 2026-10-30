import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/kumaflow_brain/kumaflow_brain_bridge.dart';
import '../services/ml/audio_features_cache.dart';
import '../services/player_ui_settings_service.dart';
import '../services/wave_identity.dart';
import 'my_wave_dancing_blobs.dart';
import 'my_wave_fluid_v3.dart';
import 'vibe_wave_background.dart';
import '../services/ml_service.dart';
import 'wave/wave_mood.dart' show waveGenreColor;

/// KumaFlow "My Wave" hero card with dynamic background.
/// Large card with cover art, play button, and current track info.
class KumaFlowMyWaveHero extends StatefulWidget {
  final List<Song> songs;
  final VoidCallback onPlay;
  final VoidCallback? onShuffle;
  final VoidCallback? onCustomize;
  final String? currentTrackTitle;
  final String? currentTrackArtist;
  final String? coverUrl;
  final bool isTv;
  /// Версия фильтров волны: home увеличивает после закрытия шторки
  /// «Настроить», hero перезагружает пилюли из prefs.
  final int filtersVersion;
  /// Генерация волны в полёте: вместо play рисуем спиннер (как на ПК).
  final bool isGenerating;

  const KumaFlowMyWaveHero({
    super.key,
    required this.songs,
    required this.onPlay,
    this.onShuffle,
    this.onCustomize,
    this.currentTrackTitle,
    this.currentTrackArtist,
    this.coverUrl,
    this.isTv = false,
    this.filtersVersion = 0,
    this.isGenerating = false,
  });

  @override
  State<KumaFlowMyWaveHero> createState() => _KumaFlowMyWaveHeroState();
}

class _KumaFlowMyWaveHeroState extends State<KumaFlowMyWaveHero> with SingleTickerProviderStateMixin {
  Color _dominantColor = const Color(0xFF1A0A2E);
  Color _accentColor = const Color(0xFF0D1B3E);
  late AnimationController _gradientController;
  // Кэш палитры по coverUrl, чтобы не дергать PaletteGenerator повторно (OOM)
  static final Map<String, List<Color>> _paletteCache = {};
  bool _isExtracting = false;

  // Жанровый цвет — общий `waveGenreColor` (словарь 1в1 с ПК/каруселью).
  Color _getGenreColor(String genreName) => waveGenreColor(genreName);

  List<Color> _getGenreGradientColors() {
    final genres = widget.songs.map((s) => s.genre).whereType<String>().where((g) => g.isNotEmpty).toList();
    if (genres.isEmpty) return [_dominantColor, _accentColor];
    final freq = <String, int>{};
    for (final g in genres) {
      final lower = g.toLowerCase();
      freq[lower] = (freq[lower] ?? 0) + 1;
    }
    final sorted = freq.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final top = sorted.take(3).map((e) => _getGenreColor(e.key)).toList();
    if (top.length == 1) return [top[0], Color.lerp(top[0], Colors.black, 0.25)!];
    if (top.length == 2) return [top[0], top[1]];
    return top;
  }

  // Активные фильтры волны (как пилюли на десктопе): читаем те же ключи,
  // что пишет шторка «Настроить». Плюс метка источника.
  List<String> _filters = const [];
  bool _brainSource = false;

  // Handoff «Продолжить» с другого устройства (как в Я.Музыке):
  // трек + позиция + устройство. Только когда мост активен и сервер
  // отдал свежий resume. Стиль — та же пилюля, вид карточки не ломаем.
  KumaFlowBrainResume? _resume;
  bool _resumeLoading = false;

  // Пульс hero в такт: только кэш (БД/память, без вычисления — без лагов).
  double _beatBpm = 120;
  double _beatEnergy = 0.5;
  double _beatDance = 0.5;
  String? _beatSongId;

  void _ensureBeat(String? songId) {
    if (songId == _beatSongId) return;
    _beatSongId = songId;
    if (songId == null || songId.isEmpty) {
      if (mounted) {
        setState(() {
          _beatBpm = 120;
          _beatEnergy = 0.5;
          _beatDance = 0.5;
        });
      }
      return;
    }
    AudioFeaturesCache().getCached(songId).then((f) {
      if (!mounted || _beatSongId != songId) return;
      setState(() {
        _beatBpm = (f?.bpm ?? 120).clamp(60.0, 200.0);
        _beatEnergy = (f?.energy ?? 0.5).clamp(0.0, 1.0);
        _beatDance = (f?.danceability ?? 0.5).clamp(0.0, 1.0);
      });
    });
  }

  /// Фон волны по выбранному виду (как Hero на ПК):
  /// v1 — статичный градиент (для слабых), v2 — танцующие блобы / светлый
  /// флюид, v3 — шейдер vibe с десктопа (для мощных, с фолбэком на v2).
  Widget _waveBg(List<Color> genreGrad, bool isDark) {
    return ValueListenableBuilder<String>(
      valueListenable:
          PlayerUiSettingsService().homeMyWaveVariantNotifier,
      builder: (ctx, variant, _) {
        if (variant == 'v1') return const SizedBox.expand();
        if (variant == 'v3') {
          return Consumer2<PlayerProvider, MLService>(
            builder: (ctx, p, ml, _) {
              final cur = p.currentSong;
              final like =
                  cur == null ? null : ml.ratings[cur.id]?.like;
              return VibeWaveBackground(
                accent: _dominantColor,
                genre: cur?.genre,
                energy: _beatEnergy,
                bpm: _beatBpm,
                isPlaying: p.isPlaying,
                dark: isDark,
                like: like,
                fallback: isDark
                    ? _blobs(genreGrad)
                    : MyWaveFluidV3(
                        beat: p.isPlaying ? 0.5 : 0.0,
                        isPlaying: p.isPlaying,
                      ),
              );
            },
          );
        }
        // v2
        if (isDark) return _blobs(genreGrad);
        return Consumer<PlayerProvider>(
          builder: (ctx, p, _) {
            return MyWaveFluidV3(
              beat: p.isPlaying ? 0.5 : 0.0,
              isPlaying: p.isPlaying,
            );
          },
        );
      },
    );
  }

  Widget _blobs(List<Color> genreGrad) {
    return Consumer<PlayerProvider>(
      builder: (ctx, p, _) {
        final cur = p.currentSong;
        if (cur?.id != _beatSongId) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _ensureBeat(cur?.id);
          });
        }
        return MyWaveDancingBlobs(
          genreColors: genreGrad,
          bpm: _beatBpm,
          energy: _beatEnergy,
          danceability: _beatDance,
          isPlaying: p.isPlaying,
        );
      },
    );
  }

  Future<void> _loadResume() async {
    KumaFlowBrainResume? info;
    try {
      final bridge =
          Provider.of<KumaFlowBrainBridge>(context, listen: false);
      if (bridge.isActive) {
        info = await bridge
            .fetchResumeInfo()
            .timeout(const Duration(seconds: 7));
      }
    } catch (_) {
      info = null;
    }
    if (!mounted) return;
    setState(() {
      _resume = info;
      _resumeLoading = false;
    });
  }

  Future<void> _continueFromServer() async {
    try {
      final player = Provider.of<PlayerProvider>(context, listen: false);
      final ok = await player.applyServerResume();
      if (!mounted) return;
      if (ok) {
        _loadResume();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Не получилось продолжить — сервер молчит')));
      }
    } catch (_) {}
  }

  Future<void> _loadFilters() async {
    final bridge = () {
      try {
        return Provider.of<KumaFlowBrainBridge>(context, listen: false);
      } catch (_) {
        return null;
      }
    }();
    try {
      final p = await SharedPreferences.getInstance();
      if (!mounted) return;
      bool brain = false;
      try {
        brain = bridge?.isActive ?? false;
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _filters = [
          p.getString('mywave_activity') ?? '',
          p.getString('mywave_character') ?? '',
          p.getString('mywave_mood') ?? '',
          p.getString('mywave_lang') ?? '',
        ].where((e) => e.isNotEmpty).toList();
        _brainSource = brain;
      });
    } catch (_) {}
  }

  Future<void> _clearFilters() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('mywave_activity', '');
      await p.setString('mywave_character', '');
      await p.setString('mywave_mood', '');
      await p.setString('mywave_lang', '');
    } catch (_) {}
    _loadFilters();
  }

  /// Комбинированная пилюля фильтров + источник (как на десктопе).
  /// Тап по тексту — открыть «Настроить», крестик — сбросить фильтры.
  /// Тап-зоны — соседи, а не вложенные: иначе тап по крестику открывал
  /// ещё и шторку, и казалось что сброс «не сработал».
  Widget _buildFilterPills() {
    final label = [
      ..._filters,
      if (_brainSource) 'KumaFlow Brain',
    ].join(' • ');
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.tune_rounded, color: Colors.white, size: 14),
              const SizedBox(width: 6),
              Flexible(
                child: GestureDetector(
                  onTap: widget.onCustomize,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _clearFilters,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close_rounded, color: Colors.white, size: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Баннер «Продолжить» — та же пилюля, что фильтры, но с акцентом:
  /// тап грузит очередь+позицию с сервера и играет. Прячется сам, когда
  /// этот трек уже играет. Рефреш-иконка — перепроверить вручную.
  Widget _buildResumeBanner() {
    final r = _resume;
    if (r == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Center(
        child: Consumer<PlayerProvider>(
          builder: (ctx, player, _) {
            final cur = player.currentSong?.id;
            if (cur != null && cur == r.playableId) {
              return const SizedBox.shrink();
            }
            // Свой слот не предлагаем продолжать (мост уже отфильтровал
            // по ownDeviceId, это второй рубеж — на случай гонки UUID).
            try {
              final own = Provider.of<KumaFlowBrainBridge>(context,
                      listen: false)
                  .ownDeviceId;
              if (own != null &&
                  own.isNotEmpty &&
                  r.deviceId.isNotEmpty &&
                  r.deviceId == own) {
                return const SizedBox.shrink();
              }
            } catch (_) {}
            final title = r.title.isNotEmpty ? r.title : 'трек';
            // Имя из веба (/api/me/devices display_name), иначе метка.
            final from = r.fromLabel.isNotEmpty ? ' с ${r.fromLabel}' : '';
            final age =
                r.ageLabel.isNotEmpty ? ' • ${r.ageLabel}' : '';
            return Container(
              constraints: const BoxConstraints(maxWidth: 320),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.35)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.play_circle_fill_rounded,
                      color: Colors.white, size: 18),
                  const SizedBox(width: 6),
                  Flexible(
                    child: GestureDetector(
                      onTap: _continueFromServer,
                      child: Text(
                        'Продолжить$from: $title — ${r.positionLabel}$age',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (_resumeLoading) return;
                      setState(() => _resumeLoading = true);
                      _loadResume();
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: _resumeLoading
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.refresh_rounded,
                              color: Colors.white, size: 14),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _gradientController = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat(reverse: true);
    _extractColors();
    _loadFilters();
    _loadResume();
  }

  @override
  void dispose() {
    _gradientController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(KumaFlowMyWaveHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverUrl != widget.coverUrl) {
      _extractColors();
    }
    if (oldWidget.filtersVersion != widget.filtersVersion) {
      _loadFilters();
      _loadResume();
    }
  }

  Future<void> _extractColors() async {
    if (widget.coverUrl == null || widget.coverUrl!.isEmpty) return;
    if (_isExtracting) return;
    if (_paletteCache.containsKey(widget.coverUrl)) {
      final cached = _paletteCache[widget.coverUrl]!;
      if (mounted) {
        setState(() {
          _dominantColor = cached[0];
          _accentColor = cached[1];
        });
      }
      return;
    }
    _isExtracting = true;
    try {
      final provider = ResizeImage(
        NetworkImage(widget.coverUrl!),
        width: 80,
        height: 80,
      );
      final paletteGenerator = await PaletteGenerator.fromImageProvider(
        provider,
        maximumColorCount: 8,
        size: const Size(80, 80),
      );
      final dom = paletteGenerator.dominantColor?.color ?? const Color(0xFF1A0A2E);
      final vib = paletteGenerator.vibrantColor?.color ?? const Color(0xFF0D1B3E);
      _paletteCache[widget.coverUrl!] = [dom, vib];
      if (_paletteCache.length > 50) {
        _paletteCache.remove(_paletteCache.keys.first);
      }
      if (mounted) {
        setState(() {
          _dominantColor = dom;
          _accentColor = vib;
        });
      }
    } catch (_) {
    } finally {
      _isExtracting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isNoCover = widget.coverUrl == null || widget.coverUrl!.isEmpty;
    final isLandscape = !widget.isTv && MediaQuery.of(context).orientation == Orientation.landscape;
    final isTv = widget.isTv;
    // ТВ: высота больше для 10ft UI, телефон-горизонталь — компакт
    final double cardHeight = isTv ? 360 : (isLandscape ? 170 : 280);
    final double cardRadius = isTv ? 24 : 16;
    final double playSize = isTv ? 88 : 72;
    final double playIconSize = isTv ? 48 : 40;
    return ValueListenableBuilder<bool>(
      valueListenable: PlayerUiSettingsService().homeMyWaveAnimatedNotifier,
      builder: (ctx, animated, __) {
        return AnimatedBuilder(
          animation: _gradientController,
          builder: (ctx2, _) {
            final anim = _gradientController.value;
            final genreGrad = _getGenreGradientColors();
            final begin = isNoCover ? Alignment(-1 + anim * 0.6, -1) : Alignment.topLeft;
            final end = isNoCover ? Alignment(1, 1 - anim * 0.6) : Alignment.bottomRight;
            // V3 светлая: подложка почти белая, флюид рисует _waveBg.
            final gradColors = !isDark
                ? [
                    const Color(0xFFF5F0FF),
                    const Color(0xFFE9D5FF),
                    const Color(0xFFFDF4FF),
                  ]
                : isNoCover
                    ? [
                        Color.lerp(genreGrad.first, genreGrad.last, anim)!,
                        Color.lerp(genreGrad.length > 1 ? genreGrad[1] : _accentColor, const Color(0xFF7C3AED), 0.5 + anim * 0.3)!,
                        Color.lerp(genreGrad.first.withValues(alpha: 0.8), genreGrad.last, 1 - anim)!,
                      ]
                    : (genreGrad.length >= 2 ? genreGrad : [_dominantColor, _accentColor, _dominantColor.withValues(alpha: 0.8)]);

            Widget buildCard() {
              return Container(
                margin: EdgeInsets.fromLTRB(16, animated ? 0 : 8, 16, 0),
                height: cardHeight,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(cardRadius),
                  gradient: LinearGradient(begin: begin, end: end, colors: gradColors),
                  boxShadow: [
                    BoxShadow(color: _dominantColor.withValues(alpha: 0.4), blurRadius: isTv ? 28 : 20, offset: const Offset(0, 8)),
                  ],
                ),
                child: Stack(
                  children: [
                    if (widget.coverUrl != null && !animated)
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(cardRadius),
                            child: ClipRect(
                              child: BackdropFilter(
                                filter: ImageFilter.blur(sigmaX: isTv ? 20 : 16, sigmaY: isTv ? 20 : 16),
                                child: CachedNetworkImage(
                                  imageUrl: widget.coverUrl!,
                                  fit: BoxFit.cover,
                                  color: Colors.black.withValues(alpha: 0.3),
                                  colorBlendMode: BlendMode.darken,
                                  memCacheWidth: isTv ? 600 : 400,
                                  maxWidthDiskCache: isTv ? 600 : 400,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (animated)
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(cardRadius),
                                child: _waveBg(genreGrad, isDark),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.songs.isNotEmpty)
                            ValueListenableBuilder<bool>(
                              valueListenable: PlayerUiSettingsService()
                                  .homeMyWaveShowCountNotifier,
                              builder: (_, showCount, __) {
                                if (!showCount) {
                                  return const SizedBox.shrink();
                                }
                                return Align(
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    '${widget.songs.length} треков',
                                    style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
                                  ),
                                );
                              },
                            ),
                          const Spacer(),
                          if (widget.currentTrackTitle == null)
                            Center(
                              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: const [
                                Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
                                SizedBox(width: 4),
                                Text('Моя волна', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                              ]),
                            ),
                          if (widget.currentTrackTitle == null) const SizedBox(height: 12),
                          if (widget.currentTrackTitle != null) ...[
                            Row(
                              children: [
                                if (widget.coverUrl != null)
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: CachedNetworkImage(
                                      imageUrl: widget.coverUrl!,
                                      width: 48,
                                      height: 48,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        widget.currentTrackTitle!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      if (widget.currentTrackArtist != null)
                                        Text(
                                          widget.currentTrackArtist!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: Colors.white.withValues(alpha: 0.7),
                                            fontSize: 14,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const Icon(
                                  Icons.favorite_border,
                                  color: Colors.white70,
                                  size: 24,
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                          ],
                          Center(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (widget.onShuffle != null)
                                  ValueListenableBuilder<bool>(
                                    valueListenable: PlayerUiSettingsService().homeShowMyWaveShuffleNotifier,
                                    builder: (_, showShuffle, __) {
                                      if (!showShuffle) return const SizedBox.shrink();
                                      return Row(children: [
                                        GestureDetector(
                                          onTap: widget.onShuffle,
                                          child: Container(
                                            width: 40,
                                            height: 40,
                                            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(20)),
                                            child: const Icon(Icons.shuffle_rounded, color: Colors.white, size: 20),
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                      ]);
                                    },
                                  ),
                                Consumer<PlayerProvider>(
                                  builder: (ctx, player, _) {
                                    final curId = player.currentSong?.id;
                                    final isThisWavePlaying = isWavePlayingNow(
                                      isPlaying: player.isPlaying,
                                      currentSongId: curId,
                                      heroIds: [for (final s in widget.songs) s.id],
                                      queueName: player.currentQueueName,
                                    );
                                    return GestureDetector(
                                      onTap: isThisWavePlaying ? player.pause : widget.onPlay,
                                      child: Container(
                                        width: playSize,
                                        height: playSize,
                                        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2))]),
                                        child: AnimatedSwitcher(
                                          duration: const Duration(milliseconds: 250),
                                          transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                                          child: widget.isGenerating
                                              ? SizedBox(key: const ValueKey('gen'), width: playIconSize * 0.6, height: playIconSize * 0.6, child: const CircularProgressIndicator(strokeWidth: 3, color: Colors.black))
                                              : Icon(isThisWavePlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, key: ValueKey(isThisWavePlaying), color: Colors.black, size: playIconSize),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                                if (widget.onCustomize != null) ...[
                                  const SizedBox(width: 16),
                                  GestureDetector(
                                    onTap: widget.onCustomize,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(20)),
                                      child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.tune_rounded, color: Colors.white, size: 16), SizedBox(width: 6), Text('Настроить', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500))]),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          // Пилюли активных фильтров как на десктопе.
                          // В горизонтали и на ТВ места нет — только портрет.
                          if (_filters.isNotEmpty && !isLandscape && !isTv)
                            _buildFilterPills(),
                          // Продолжить с другого устройства (resume с сервера).
                          if (!isLandscape && !isTv) _buildResumeBanner(),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }

            if (animated) {
              final double cardH = cardHeight;
              final double spill = isTv ? 60 : 40;
              final double radius = isTv ? 28 : 24;
              return RepaintBoundary(
                child: SizedBox(
                  height: cardH + spill,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        bottom: 0,
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: isTv ? 12 : 8),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(radius),
                            child: Opacity(
                              opacity: isTv ? 0.62 : 0.52,
                              child: RepaintBoundary(
                            child: _waveBg(genreGrad, isDark),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        top: isTv ? 30 : 20,
                        child: buildCard(),
                      ),
                    ],
                  ),
                ),
              );
            }
            return RepaintBoundary(child: buildCard());
          },
        );
      },
    );
  }
}
