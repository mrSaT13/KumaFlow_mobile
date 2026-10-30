import 'dart:io';
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/audiobookshelf_service.dart';
import '../services/kumaflow_brain/kumaflow_brain_bridge.dart';
import '../services/player_ui_settings_service.dart';
import '../services/subsonic_service.dart';
import '../services/ml_service.dart';
import '../services/wave_energy_service.dart';
import '../services/wave_identity.dart';
import '../widgets/album_artwork.dart' show isLocalFilePath;
import '../screens/ml_stats_screen.dart';
import 'vibe_wave_background.dart';
import 'wave/kuma_wave_background.dart';
import 'wave/wave_mood.dart';

/// KumaHeroV2 — hero «Моя волна» 1в1 как на ПК (yandex-раскладка
/// `KumaWaveHero`): сплошная карточка #F1F2F6 / #141A26 по теме,
/// мягкое живое пятно по центру, заголовок-кнопка «⏸ Моя волна»,
/// под ним один ряд пилюль «Настроить» + статистика + контекст ×.
/// Никакого гигантского круга Play — играет сам заголовок, как на ПК.
/// Включается тумблером «Моя волна V2» (Настройки → Оформление → Главная),
// Third independent of KION-тумблера.
class KumaHeroV2 extends StatefulWidget {
  final List<Song> songs;
  final VoidCallback onPlay;
  final VoidCallback? onShuffle;
  final VoidCallback? onCustomize;
  final String? currentTrackTitle;
  final String? currentTrackArtist;
  final String? coverUrl;
  final bool isTv;
  final int filtersVersion;
  /// Генерация волны в полёте: вместо play рисуем спиннер (как на ПК).
  final bool isGenerating;
  /// Сырой coverArt ИГРАЮЩЕГО трека (не URL пула): трио идёт от него.
  final String? currentCoverArt;
  /// Жанр ИГРАЮЩЕГО трека: второй в цепочке ПК после акцента обложки.
  final String? currentGenre;

  const KumaHeroV2({
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
    this.currentCoverArt,
    this.currentGenre,
  });

  @override
  State<KumaHeroV2> createState() => _KumaHeroV2State();
}

class _KumaHeroV2State extends State<KumaHeroV2> {
  List<String> _filters = const [];
  KumaFlowBrainResume? _resume;
  bool _resumeLoading = false;

  // Доминанта обложки (как accent на ПК) → трио капли. Кэш по источнику.
  Color? _coverBase;
  static final Map<String, Color> _baseCache = {};
  bool _extractingBase = false;

  /// Эффективный источник обложки: сырой арт играющего трека важнее
  /// URL пула (как currentSongColor на ПК, а не первая песня подборки).
  String _artSource() {
    final raw = (widget.currentCoverArt ?? '').trim();
    if (raw.isNotEmpty) return 'raw:$raw';
    return 'url:${(widget.coverUrl ?? '').trim()}';
  }

  /// Провайдер для палитры по любому типу арта: сеть, файл, ABS с токеном,
  /// subsonic-id. Старый код умел только голый NetworkImage — офлайн
  /// и книжный сервер всегда падали в дефолтное трио.
  ImageProvider? _artProvider() {
    final raw = (widget.currentCoverArt ?? '').trim();
    if (raw.isNotEmpty) {
      if (raw.startsWith('http')) {
        return ResizeImage(NetworkImage(raw),
            width: 48, height: 48);
      }
      if (raw.startsWith('abs:')) {
        try {
          final u = AudiobookshelfService()
              .getCoverUrl(raw.substring(4), width: 96);
          final headers = AudiobookshelfService().authHeaders;
          return ResizeImage(
              NetworkImage(u, headers: headers.isEmpty ? null : headers),
              width: 48,
              height: 48);
        } catch (_) {}
      }
      if (isLocalFilePath(raw)) {
        try {
          return ResizeImage(FileImage(File(raw)),
              width: 48, height: 48);
        } catch (_) {}
      }
      try {
        final svc =
            Provider.of<SubsonicService>(context, listen: false);
        final u = svc.getCoverArtUrl(raw, size: 200);
        if (u.isNotEmpty && u.startsWith('http')) {
          return ResizeImage(NetworkImage(u), width: 48, height: 48);
        }
      } catch (_) {}
    }
    final u = (widget.coverUrl ?? '').trim();
    if (u.startsWith('http')) {
      return ResizeImage(NetworkImage(u), width: 48, height: 48);
    }
    return null;
  }

  /// Настроение капли: КАК НА ПК — жанр ТЕКУЩЕГО трека
  /// (`genre={currentSong?.genre}`), а не топ-жанр всего пула.
  /// Иначе у кого в библиотеке доминирует rusrap — вечные кольца bounce,
  /// что бы ни играло. Пула — только фолбэк когда ничего не играет.
  WaveMood _poolMood() {
    final freq = <String, int>{};
    for (final s in widget.songs) {
      final g = s.genre;
      if (g == null || g.isEmpty) continue;
      final lower = g.toLowerCase();
      freq[lower] = (freq[lower] ?? 0) + 1;
    }
    if (freq.isEmpty) return WaveMood.none;
    final top = freq.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return waveMoodForGenre(top.first.key);
  }

  Future<void> _extractBase() async {
    final src = _artSource();
    final provider = _artProvider();
    if (provider == null) {
      if (mounted && _coverBase != null) setState(() => _coverBase = null);
      return;
    }
    final hit = _baseCache[src];
    if (hit != null) {
      if (mounted && _coverBase != hit) setState(() => _coverBase = hit);
      return;
    }
    if (_extractingBase) return;
    _extractingBase = true;
    try {
      // 48px хватает для доминанты; большой арт только тормозил и жрал
      // память. Таймаут 6с: на мёртвом сервере не висим (цвета останутся
      // дефолтными до следующей обложки).
      final palette = await PaletteGenerator.fromImageProvider(
        provider,
        maximumColorCount: 8,
        size: const Size(48, 48),
      ).timeout(const Duration(seconds: 6));
      final base =
          palette.vibrantColor?.color ?? palette.dominantColor?.color;
      if (base != null) {
        _baseCache[src] = base;
        if (_baseCache.length > 50) {
          _baseCache.remove(_baseCache.keys.first);
        }
        if (mounted) setState(() => _coverBase = base);
      }
    } catch (_) {
    } finally {
      _extractingBase = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _loadFilters();
    _loadResume();
    _extractBase();
  }

  @override
  void didUpdateWidget(KumaHeroV2 oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filtersVersion != widget.filtersVersion) {
      _loadFilters();
      _loadResume();
    }
    // Трек сменился — мгновенно падаем на жанровое трио (перетекёт
    // морфингом), точную доминанту дотянет палитра и тоже перетечёт.
    if (oldWidget.currentCoverArt != widget.currentCoverArt ||
        oldWidget.coverUrl != widget.coverUrl) {
      if (mounted && _coverBase != null) setState(() => _coverBase = null);
      _extractBase();
    }
  }

  Future<void> _loadFilters() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _filters = [
          p.getString('mywave_activity') ?? '',
          p.getString('mywave_character') ?? '',
          p.getString('mywave_mood') ?? '',
          p.getString('mywave_lang') ?? '',
        ].where((e) => e.isNotEmpty).toList();
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

  void _openStats() {
    try {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const MLStatsScreen()),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Сплошная карточка 1в1 как на ПК, пятно — мягкое и полупрозрачное,
    // чтобы карточка читалась сплошной, а не градиентом во весь фон.
    final cardBg = isDark ? const Color(0xFF141A26) : const Color(0xFFF1F2F6);
    final titleColor = isDark ? Colors.white : const Color(0xFF111111);
    final pillBg = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : const Color(0xFFDCE7F8).withValues(alpha: 0.9);
    final pillFg = isDark ? Colors.white : const Color(0xFF1A2B4A);
    final hintBg = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.07);
    // Трио капли — цепочка как на ПК: акцент ИГРАЮЩЕГО трека → жанр
    // трека → топ-жанр пула → дефолт. Смены перетекают морфингом 700мс.
    final curGenre = (widget.currentGenre ?? '').trim();
    final genreTrio = curGenre.isNotEmpty
        ? buildWaveTrio(waveGenreColor(curGenre), isDark)
        : null;
    final trio =
        buildWaveTrio(_coverBase, isDark) ?? genreTrio ?? defaultWaveTrio;
    final poolMood = _poolMood();
    final isLandscape =
        !widget.isTv && MediaQuery.of(context).orientation == Orientation.landscape;
    final double cardHeight = widget.isTv ? 360 : (isLandscape ? 180 : 320);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      height: cardHeight,
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.12),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            // Фон 1в1 ПК: ореол + blob-капля + эффект настроения.
            // Цвета из обложки, настроение — жанр текущего трека (как ПК),
            // фолбэк — топ-жанр пула. Игра пульсирует.
            // Темп пульса — BPM текущего трека (WaveEnergyService).
            Positioned.fill(
              child: Consumer<PlayerProvider>(
                builder: (ctx, player, _) {
                  final curId = player.currentSong?.id;
                  final wavePlaying = isWavePlayingNow(
                    isPlaying: player.isPlaying,
                    currentSongId: curId,
                    heroIds: [for (final s in widget.songs) s.id],
                    queueName: player.currentQueueName,
                  );
                  try {
                    WaveEnergyService().setTrack(
                      player.currentSong,
                      playing: player.isPlaying,
                    );
                  } catch (_) {}
                  final curGenre = player.currentSong?.genre;
                  final curMood = (curGenre != null && curGenre.isNotEmpty)
                      ? waveMoodForGenre(curGenre)
                      : WaveMood.none;
                  final mood =
                      curMood != WaveMood.none ? curMood : poolMood;
                  return ValueListenableBuilder<int>(
                    valueListenable: PlayerUiSettingsService()
                        .waveFxVersionNotifier,
                    builder: (_, __, ___) => ValueListenableBuilder<String>(
                      valueListenable: PlayerUiSettingsService()
                          .homeMyWaveVariantNotifier,
                      builder: (_, variant, ___) {
                        // V1 — статичный фон (для слабых): тикер стоит.
                        if (variant == 'v1') {
                          return KumaWaveBackground(
                            alive: false,
                            playing: false,
                            dark: isDark,
                            trio: trio,
                            mood: WaveMood.none,
                          );
                        }
                        if (variant == 'v3') {
                          return Consumer<MLService>(
                            builder: (_, ml, ___) {
                              final like = curId == null
                                  ? null
                                  : ml.ratings[curId]?.like;
                              final w = WaveEnergyService();
                              final bg = KumaWaveBackground(
                                alive: true,
                                playing: wavePlaying,
                                dark: isDark,
                                trio: trio,
                                mood: mood,
                                enabledFx: PlayerUiSettingsService()
                                    .getWaveFxEnabled(),
                              );
                              return VibeWaveBackground(
                                accent: trio.isNotEmpty ? trio[0] : null,
                                genre: (curGenre?.isNotEmpty == true)
                                    ? curGenre
                                    : null,
                                energy: w.anchorEnergy,
                                bpm: w.bpm,
                                isPlaying: player.isPlaying,
                                dark: isDark,
                                like: like,
                                fallback: bg,
                              );
                            },
                          );
                        }
                        // V2 — текущие блобы как на ПК.
                        return KumaWaveBackground(
                          alive: true,
                          playing: wavePlaying,
                          dark: isDark,
                          trio: trio,
                          mood: mood,
                          enabledFx: PlayerUiSettingsService()
                              .getWaveFxEnabled(),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
              child: Column(
                children: [
                  if (widget.songs.isNotEmpty)
                    ValueListenableBuilder<bool>(
                      valueListenable: PlayerUiSettingsService()
                          .homeMyWaveShowCountNotifier,
                      builder: (_, showCount, ___) {
                        if (!showCount) return const SizedBox.shrink();
                        return Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            '${widget.songs.length} треков',
                            style: TextStyle(
                              color: titleColor.withValues(alpha: 0.55),
                              fontSize: 13,
                            ),
                          ),
                        );
                      },
                    ),
                  // Центр как на ПК: заголовок-кнопка «⏸ Моя волна».
                  Expanded(
                    child: Center(
                      child: Consumer<PlayerProvider>(
                        builder: (ctx, player, _) {
                          final curId = player.currentSong?.id;
                          final isWavePlaying = isWavePlayingNow(
                            isPlaying: player.isPlaying,
                            currentSongId: curId,
                            heroIds: [for (final s in widget.songs) s.id],
                            queueName: player.currentQueueName,
                          );
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              if (isWavePlaying) {
                                player.pause();
                              } else {
                                widget.onPlay();
                              }
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (widget.isGenerating)
                                    SizedBox(
                                      width: 30,
                                      height: 30,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 3,
                                        color: titleColor,
                                      ),
                                    )
                                  else
                                    Icon(
                                      isWavePlaying
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      color: titleColor,
                                      size: 34,
                                    ),
                                  const SizedBox(width: 10),
                                  Flexible(
                                    child: Text(
                                      'Моя волна',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: titleColor,
                                        fontSize: 32,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: -0.5,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  // Один ряд пилюль как на ПК: Настроить + статистика + контекст ×.
                  // Цвет текста задаём снаружи (Flexible выше не красит сам).
                  DefaultTextStyle(
                    style: TextStyle(color: titleColor),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (widget.onShuffle != null)
                          ValueListenableBuilder<bool>(
                            valueListenable: PlayerUiSettingsService()
                                .homeShowMyWaveShuffleNotifier,
                            builder: (_, showShuffle, __) {
                              if (!showShuffle) {
                                return const SizedBox.shrink();
                              }
                              return GestureDetector(
                                onTap: widget.onShuffle,
                                child: Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: pillBg,
                                    borderRadius: BorderRadius.circular(19),
                                  ),
                                  child: Icon(
                                    Icons.shuffle_rounded,
                                    color: pillFg,
                                    size: 18,
                                  ),
                                ),
                              );
                            },
                          ),
                        if (widget.onCustomize != null)
                          GestureDetector(
                            onTap: widget.onCustomize,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 9),
                              decoration: BoxDecoration(
                                color: pillBg,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.tune_rounded,
                                      color: pillFg, size: 16),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Настроить',
                                    style: TextStyle(
                                      color: pillFg,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        GestureDetector(
                          onTap: _openStats,
                          child: Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: pillBg,
                              borderRadius: BorderRadius.circular(19),
                            ),
                            child: Icon(
                              Icons.bar_chart_rounded,
                              color: pillFg,
                              size: 18,
                            ),
                          ),
                        ),
                        if (_filters.isNotEmpty)
                          Container(
                            constraints:
                                const BoxConstraints(maxWidth: 220),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 9),
                            decoration: BoxDecoration(
                              color: hintBg,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: GestureDetector(
                                    onTap: widget.onCustomize,
                                    child: Text(
                                      _filters.join(' • '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: pillFg,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _clearFilters,
                                  child: Padding(
                                    padding: const EdgeInsets.all(4),
                                    child: Icon(
                                      Icons.close_rounded,
                                      color:
                                          pillFg.withValues(alpha: 0.6),
                                      size: 15,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Продолжить с другого устройства.
                  if (!isLandscape && !widget.isTv) _buildResume(pillFg),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResume(Color pillFg) {
    final r = _resume;
    if (r == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Center(
        child: Consumer<PlayerProvider>(
          builder: (ctx, player, _) {
            final cur = player.currentSong?.id;
            if (cur != null && cur == r.playableId) {
              return const SizedBox.shrink();
            }
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
            final isDark =
                Theme.of(context).brightness == Brightness.dark;
            final title = r.title.isNotEmpty ? r.title : 'трек';
            final from = r.fromLabel.isNotEmpty ? ' с ${r.fromLabel}' : '';
            return Container(
              constraints: const BoxConstraints(maxWidth: 320),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.35)
                    : Colors.white.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: pillFg.withValues(alpha: 0.25)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.play_circle_fill_rounded,
                      color: pillFg, size: 18),
                  const SizedBox(width: 6),
                  Flexible(
                    child: GestureDetector(
                      onTap: _continueFromServer,
                      child: Text(
                        'Продолжить$from: $title — ${r.positionLabel}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: pillFg,
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
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: pillFg))
                          : Icon(Icons.refresh_rounded,
                              color: pillFg, size: 14),
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
}
