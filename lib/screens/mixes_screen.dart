import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../services/theme_service.dart';
import '../models/song.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../services/recommendation_service.dart';
import '../services/ai_service.dart';
import '../services/ai_mix_service.dart';
import '../services/mix_cache_service.dart';
import '../services/ml_playlist_service.dart';
import '../services/subsonic_service.dart';
import '../theme/app_theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/instant_mix_dialog.dart';
import '../services/auto_dj_service.dart';
import '../services/player_ui_settings_service.dart';
import '../services/playlist_orchestrator.dart';
import '../services/wave_identity.dart';
import '../widgets/favorite_playlists_section.dart';
import '../widgets/collab_mix_section.dart';
import 'mix_detail_screen.dart';
import 'ai_mix_screen.dart';

/// Локализация отображаемого названия микса под язык программы.
/// Ключи в map стабильно английские (сервис + кэш), переводим только UI.
String localizedMixTitle(BuildContext context, String key) {
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
  // "$artist Mix" / "$genre Mix" — динамические, суффикс локализуем.
  if (key.endsWith(' Mix') && key.length > 4) {
    return l10n.artistMixWithName(key.substring(0, key.length - 4));
  }
  if (key.endsWith(' Vibes') && key.length > 6) {
    return l10n.timeVibesWithName(key.substring(0, key.length - 6));
  }
  return key;
}

/// Dedicated ML mixes tab: shows all generated mixes as sections with a
/// "play all" button per mix roster.
class MixesScreen extends StatefulWidget {
  const MixesScreen({super.key});

  @override
  State<MixesScreen> createState() => _MixesScreenState();
}

class _MixesScreenState extends State<MixesScreen> {
  Map<String, List<Song>> _cachedMixes = const {};
  String _lastKey = '';
  final Map<String, bool> _expanded = {};
  List<Song>? _madeForYouSongs;
  bool _madeForYouLoading = false;
  bool _madeForYouExpanded = false;
  List<Song>? _dailyMixSongs;
  bool _dailyMixLoading = false;
  bool _dailyMixExpanded = false;
  AiMixResult? _aiDailyMix;
  bool _aiDailyLoading = false;
  bool _aiDailyExpanded = false;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  String _computeCacheKey(List<Song> filtered, RecommendationService rec) {
    // Cheap hash instead of join('|') on 10k ids
    int h = filtered.length.hashCode ^ rec.bannedArtistsKey.hashCode ^ (AiService().isConfigured ? 1 : 0);
    for (final s in filtered.take(20)) {
      h = h * 31 + s.id.hashCode;
    }
    return '${filtered.length}_$h';
  }

  Future<void> _loadMadeForYou(List<Song> pool, {bool force = false}) async {
    if (_madeForYouLoading) return;
    final repo = MixCacheService();
    final key = 'm4u_${pool.length}_${pool.take(5).map((s) => s.id).join(',').hashCode}';
    if (!force) {
      final cached = await repo.loadMadeForYou(key, pool);
      if (cached != null && mounted) {
        setState(() => _madeForYouSongs = cached);
        return;
      }
    }
    if (!mounted) return;
    setState(() => _madeForYouLoading = true);
    try {
      // Prefer server random, fallback to pool shuffle
      List<Song> songs = [];
      try {
        final sub = Provider.of<SubsonicService>(context, listen: false);
        songs = await sub.getRandomSongs(size: 30);
      } catch (_) {}
      if (songs.isEmpty) {
        songs = List<Song>.from(pool)..shuffle();
        songs = songs.take(30).toList();
      }
      await repo.saveMadeForYou(key, songs);
      if (mounted) setState(() => _madeForYouSongs = songs);
    } finally {
      if (mounted) setState(() => _madeForYouLoading = false);
    }
  }

  /// Ежедневный ИИ-микс в Миксах: сначала показываем последний сохранённый
  /// (getLastDailyInfo + резолв id в треки пула), если сутки прошли —
  /// генерируем новый фоном. Ручной refresh — force-перегенерация.
  Future<void> _loadAiDailyMix(List<Song> pool, {bool force = false}) async {
    if (_aiDailyLoading || pool.isEmpty || !mounted) return;
    // setState только после async-паузы — метод дёргается из build.
    await Future.delayed(Duration.zero);
    if (!mounted || _aiDailyLoading) return;
    setState(() => _aiDailyLoading = true);
    try {
      final svc = AiMixService();
      AiMixResult? res =
          await svc.generateDailyAutoMix(library: pool, force: force);
      res ??= await _resolveLastAiDaily(pool);
      if (mounted && res != null && res.songs.isNotEmpty) {
        setState(() => _aiDailyMix = res);
      }
    } catch (e) {
      debugPrint('[Mixes] AiDaily error: $e');
    } finally {
      if (mounted) setState(() => _aiDailyLoading = false);
    }
  }

  Future<AiMixResult?> _resolveLastAiDaily(List<Song> pool) async {
    try {
      final info = await AiMixService().getLastDailyInfo();
      if (info == null) return null;
      final byId = {for (final s in pool) s.id: s};
      final ids =
          (info['ids'] as List?)?.map((e) => e.toString()).toList() ??
              const [];
      final songs = ids.map((id) => byId[id]).whereType<Song>().toList();
      if (songs.isEmpty) return null;
      return AiMixResult(
        name: (info['name'] as String?) ?? 'Ежедневный ИИ-микс',
        comment: 'Автомикс за ${info['date']}',
        songs: songs,
        songIds: songs.map((s) => s.id).toList(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadDailyMix(List<Song> pool, RecommendationService rec) async {
    if (_dailyMixLoading) return;
    if (pool.isEmpty) return;
    setState(() => _dailyMixLoading = true);
    try {
      final svc = MlPlaylistService();
      // ensure rec wired
      svc.setServices(subsonicService: Provider.of<SubsonicService>(context, listen: false), recommendationService: rec);
      final res = await svc.generateDailyMix(pool: pool, limit: 25);
      if (mounted && res != null) setState(() => _dailyMixSongs = res.songs);
    } catch (e) {
      debugPrint('[Mixes] DailyMix error: $e');
    } finally {
      if (mounted) setState(() => _dailyMixLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final intensity = context.select<ThemeService, double>((t) => t.gradientIntensity);
    final l10n = AppLocalizations.of(context)!;
    final accentColor =
        context.select<ThemeService, Color>((t) => t.accentColor.color);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(
          l10n.mixtapes,
          style: TextStyle(
            letterSpacing: -0.3,
            shadows: [
              Shadow(
                color: Colors.black
                    .withValues(alpha: _isDark ? 0.55 : 0.18),
                blurRadius: 12,
                offset: const Offset(0, 1),
              ),
            ],
          ),
        ),
        centerTitle: false,
        backgroundColor: _isDark
            ? const Color(0xFF121212).withValues(alpha: 0.72)
            : Colors.white.withValues(alpha: 0.82),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        actions: [
          IconButton(
            tooltip: 'ИИ Микс',
            icon: const Icon(Icons.auto_awesome_rounded),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AiMixScreen())),
          ),
        ],
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    accentColor.withValues(alpha: (_isDark ? 0.40 : 0.20) * intensity),
                    accentColor.withValues(alpha: (_isDark ? 0.16 : 0.08) * intensity),
                    (_isDark ? Colors.black : Colors.white)
                        .withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
                border: Border(
                  bottom: BorderSide(
                    color: _isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.07),
                    width: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      body: Consumer2<LibraryProvider, RecommendationService>(
        builder: (context, libraryProvider, recService, _) {
          // В офлайне — только играемое (скачанное/локальное).
          final allSongs = libraryProvider.isOfflineNow
              ? libraryProvider.playablePool()
              : (libraryProvider.cachedAllSongs.isNotEmpty
                  ? libraryProvider.cachedAllSongs
                  : libraryProvider.randomSongs);

          if (libraryProvider.isLoading && !libraryProvider.isInitialized) {
            return const Center(child: CircularProgressIndicator());
          }

          if (allSongs.isEmpty) {
            return Center(
              child: Text(
                l10n.libraryEmpty,
                style: TextStyle(
                  color: _isDark
                      ? AppTheme.darkSecondaryText
                      : AppTheme.lightSecondaryText,
                ),
              ),
            );
          }

          // Regenerate mixes when the song pool OR the banned-artist set
          // changes — ban/unban otherwise keeps stale mixes on screen.
          var filteredSongs = libraryProvider.mergeLocalLibrary
              ? allSongs
              : allSongs.where((s) => !s.isLocal).toList();
          if (filteredSongs.isEmpty && allSongs.isNotEmpty) filteredSongs = allSongs;
          final key = _computeCacheKey(filteredSongs, recService);
          if (key != _lastKey) {
            _lastKey = key;
            final _capKey = key;
            final _capSongs = List<Song>.from(filteredSongs);
            // Try cache first (TTL 12h), then generate
            MixCacheService().loadAllMixes(_capKey, _capSongs).then((cached) {
              if (cached != null && _capKey == _lastKey && mounted) {
                setState(() => _cachedMixes = cached);
                if (_madeForYouSongs == null && !_madeForYouLoading) _loadMadeForYou(_capSongs);
                if (_aiDailyMix == null && !_aiDailyLoading) _loadAiDailyMix(_capSongs);
                // Daily — лениво, только по тапу на refresh в Daily секции, не авто
                return;
              }
              Future.microtask(() async {
                // Тяжёлый скоринг — в отдельном изоляте, UI не висит.
                final mixes = await recService.generateMixesIsolated(_capSongs);
                if (_capKey == _lastKey && mounted) {
                  setState(() => _cachedMixes = mixes);
                  MixCacheService().saveAllMixes(_capKey, mixes);
                  if (_madeForYouSongs == null && !_madeForYouLoading) _loadMadeForYou(_capSongs);
                  if (_aiDailyMix == null && !_aiDailyLoading) _loadAiDailyMix(_capSongs);
                  // Daily и AI rename — отложено чтобы не ANR, только по требованию
                  // AI rename after mixes ready, sequential with delay to avoid 429/ANR
                  if (AiService().isConfigured && mixes.isNotEmpty) {
                    final ai = AiService();
                    final snapshot = Map<String, List<Song>>.from(mixes);
                    final renamed = <String, List<Song>>{};
                    final localeCode = Localizations.localeOf(context).languageCode;
                    for (final e in snapshot.entries) {
                      try {
                        final aiName = await ai.generateMixName(e.value, hint: e.key, locale: localeCode);
                        renamed[aiName.isEmpty ? e.key : aiName] = e.value;
                      } catch (_) {
                        renamed[e.key] = e.value;
                      }
                      await Future.delayed(const Duration(milliseconds: 400));
                    }
                    if (mounted && _capKey == _lastKey) {
                      setState(() => _cachedMixes = renamed);
                      MixCacheService().saveAllMixes(_capKey, renamed);
                    }
                  }
                }
              });
            });
            if (_cachedMixes.isEmpty) {
              // keep placeholder until async completes
            }
            if (_madeForYouSongs == null && !_madeForYouLoading) {
              _loadMadeForYou(filteredSongs);
            }
            if (_aiDailyMix == null && !_aiDailyLoading) {
              _loadAiDailyMix(filteredSongs);
            }
            // DailyMix — не грузим сразу чтобы не ANR, загрузится после основных миксов
          }
          final mixes = _cachedMixes;

          if (mixes.isEmpty) {
            return Center(
              child: Text(
                'Рекомендации отключены или нет данных',
                style: TextStyle(
                  color: _isDark
                      ? AppTheme.darkSecondaryText
                      : AppTheme.lightSecondaryText,
                ),
              ),
            );
          }

          final orderedKeys = mixes.keys.toList();

          return RefreshIndicator(
            onRefresh: () async {
              setState(() {
                _lastKey = '';
                _dailyMixSongs = null;
                _aiDailyMix = null;
              });
            },
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(child: _buildSeedWaveSection(context, filteredSongs)),
                const SliverToBoxAdapter(child: FavoritePlaylistsSection()),
                const SliverToBoxAdapter(child: CollabMixSection()),
                // «Скачанное»: все файлы доступные в офлайне одним плейлистом.
                // Виден всегда когда есть что играть без сети.
                SliverToBoxAdapter(child: Builder(
                  builder: (ctx) {
                    final off = libraryProvider.offlineSongs;
                    if (off.isEmpty) return const SizedBox.shrink();
                    return _buildMixSection(context, AppLocalizations.of(context)!.downloadedMix, off);
                  },
                )),
                SliverToBoxAdapter(child: _buildMadeForYouSection(context)),
                SliverToBoxAdapter(child: _buildDailyMixSection(context)),
                SliverToBoxAdapter(child: _buildAiDailyMixSection(context)),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: MediaQuery.of(context).orientation == Orientation.landscape ? 4 : 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (ctx, idx) {
                        final name = orderedKeys[idx];
                        final songs = mixes[name] ?? const <Song>[];
                        return _buildMixCard(ctx, localizedMixTitle(ctx, name), songs, rawKey: name);
                      },
                      childCount: orderedKeys.length,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildMixSection(
      BuildContext context, String name, List<Song> songs) {
    final playerProvider = context.read<PlayerProvider>().playSong;
    final expanded = _expanded[name] ?? (songs.length <= 5);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              _mixIcon(name),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${songs.length} треков',
                      style: TextStyle(
                        fontSize: 12,
                        color: _isDark
                            ? AppTheme.darkSecondaryText
                            : AppTheme.lightSecondaryText,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Волна',
                icon: const Icon(Icons.waves_rounded, size: 22),
                color: Theme.of(context).colorScheme.primary,
                onPressed: () {
                  if (songs.isEmpty) return;
                  final lib = Provider.of<LibraryProvider>(context, listen: false);
                  final pool = lib.playablePool();
                  final lower = name.toLowerCase();
                  final firstGenre = songs.first.genre;
                  if (firstGenre != null && lower.contains(firstGenre.toLowerCase())) {
                    _playSeedWave(context, pool, seedGenre: firstGenre);
                  } else if (songs.first.artist != null) {
                    // Try to detect artist mix: name is "<Artist> Mix"
                    final artist = name.replaceAll(' Mix', '').trim();
                    final seedArtist = artist.isNotEmpty ? artist : songs.first.artist!;
                    _playSeedWave(context, pool, seedArtist: seedArtist);
                  } else {
                    _showInstantMixForSong(context, songs.first);
                  }
                },
              ),
              IconButton(
                tooltip: 'Играть',
                icon: const Icon(Icons.play_circle_fill_rounded),
                color: AppTheme.loginAccent,
                onPressed: () {
                  if (songs.isEmpty) return;
                  playerProvider(
                    songs.first,
                    playlist: songs,
                    startIndex: 0,
                  );
                },
              ),
              if (songs.length > 5)
                IconButton(
                  icon: Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                  onPressed: () {
                    setState(() => _expanded[name] = !expanded);
                  },
                ),
            ],
          ),
        ),
        if (!expanded) ...[
          // Compact preview: 3 rows via Column to avoid nested viewport crash (Null check at RenderViewport)
          Column(
            children: List.generate(
              songs.length.clamp(0, 3),
              (i) => RepaintBoundary(
                child: SongTile(song: songs[i], playlist: songs, index: i, showAlbum: true),
              ),
            ),
          ),
          Center(
            child: TextButton(
              onPressed: () => setState(() => _expanded[name] = true),
              child: Text(
                'Показать все (${songs.length})',
                style: const TextStyle(color: AppTheme.loginAccent),
              ),
            ),
          ),
        ] else ...[
          // Full list via Column (no nested scrollable viewport) — prevents RenderViewportBase._paintContents null crash
          Column(
            children: List.generate(
              songs.length,
              (i) => RepaintBoundary(
                child: SongTile(song: songs[i], playlist: songs, index: i, showAlbum: true),
              ),
            ),
          ),
        ],
        Divider(
          height: 1,
          indent: 16,
          endIndent: 16,
          color: _isDark ? AppTheme.darkDivider : AppTheme.lightDivider,
        ),
      ],
    );
  }

  Widget _buildMadeForYouSection(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              Container(width: 42, height: 42, decoration: BoxDecoration(color: accent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)), child: Icon(Icons.person_outline_rounded, color: accent, size: 24)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(AppLocalizations.of(context)!.madeForYou, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)), Text(AppLocalizations.of(context)!.localeName.startsWith('ru') ? 'Персональная подборка • 30 треков' : 'Personal selection • 30 tracks', style: const TextStyle(fontSize: 12, color: Colors.grey))])),
              IconButton(tooltip: AppLocalizations.of(context)!.refresh, icon: const Icon(Icons.refresh_rounded), onPressed: () async {
                final lib = Provider.of<LibraryProvider>(context, listen: false);
                // Было: срез 80к кэша. Стало: свежий пул из БД.
                final pool = await lib.getPoolForMix(limit: 700);
                _loadMadeForYou(pool, force: true);
              }),
              IconButton(icon: Icon(_madeForYouExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded), onPressed: () => setState(() => _madeForYouExpanded = !_madeForYouExpanded)),
            ],
          ),
        ),
        if (_madeForYouLoading)
          const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
        else if (_madeForYouSongs == null || _madeForYouSongs!.isEmpty)
          Padding(padding: const EdgeInsets.all(16), child: Text('Нет данных — сделайте pull to refresh', style: TextStyle(color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)))
        else ...[
          Column(
            children: List.generate(
              _madeForYouExpanded ? _madeForYouSongs!.length : (_madeForYouSongs!.length.clamp(0, 3)),
              (i) => RepaintBoundary(child: SongTile(song: _madeForYouSongs![i], playlist: _madeForYouSongs!, index: i, showAlbum: true)),
            ),
          ),
          if (!_madeForYouExpanded && _madeForYouSongs!.length > 3)
            Center(child: TextButton(onPressed: () => setState(() => _madeForYouExpanded = true), child: Text('Показать все (${_madeForYouSongs!.length})', style: TextStyle(color: accent)))),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: FilledButton.icon(onPressed: () {
            if (_madeForYouSongs == null || _madeForYouSongs!.isEmpty) return;
            Provider.of<PlayerProvider>(context, listen: false).playSong(_madeForYouSongs!.first, playlist: _madeForYouSongs!, startIndex: 0);
          }, icon: const Icon(Icons.play_arrow_rounded), label: const Text('Слушать всё'))),
        ],
        Divider(height: 1, indent: 16, endIndent: 16, color: _isDark ? AppTheme.darkDivider : AppTheme.lightDivider),
      ],
    );
  }

  Widget _buildDailyMixSection(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              Container(width: 42, height: 42, decoration: BoxDecoration(color: Colors.deepPurple.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.history_rounded, color: Colors.deepPurple, size: 24)),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(AppLocalizations.of(context)!.localeName.startsWith('ru') ? 'Ежедневный микс' : 'Daily Mix', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)), Text(AppLocalizations.of(context)!.localeName.startsWith('ru') ? 'Забытые любимые + новинки' : 'Forgotten favorites + new releases', style: const TextStyle(fontSize: 12, color: Colors.grey))])),
              if (_dailyMixLoading)
                const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
              else
                IconButton(tooltip: AppLocalizations.of(context)!.refresh, icon: const Icon(Icons.refresh_rounded), onPressed: () async {
                  final lib = Provider.of<LibraryProvider>(context, listen: false);
                  final pool = await lib.getPoolForMix(limit: 700);
                  final rec = Provider.of<RecommendationService>(context, listen: false);
                  MixCacheService().invalidateDaily().then((_) => _loadDailyMix(pool, rec));
                }),
              IconButton(icon: Icon(_dailyMixExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded), onPressed: () => setState(() => _dailyMixExpanded = !_dailyMixExpanded)),
            ],
          ),
        ),
        if (_dailyMixLoading)
          const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
        else if (_dailyMixSongs == null || _dailyMixSongs!.isEmpty)
          Padding(padding: const EdgeInsets.all(16), child: Text(AppLocalizations.of(context)!.localeName.startsWith('ru') ? 'Ежедневный микс генерируется... потяни вниз' : 'Daily Mix is generating... pull down', style: TextStyle(color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)))
        else ...[
          Column(
            children: List.generate(
              _dailyMixExpanded ? _dailyMixSongs!.length : (_dailyMixSongs!.length.clamp(0, 3)),
              (i) => RepaintBoundary(child: SongTile(song: _dailyMixSongs![i], playlist: _dailyMixSongs!, index: i, showAlbum: true)),
            ),
          ),
          if (!_dailyMixExpanded && _dailyMixSongs!.length > 3)
            Center(child: TextButton(onPressed: () => setState(() => _dailyMixExpanded = true), child: Text('Показать все (${_dailyMixSongs!.length})', style: TextStyle(color: accent)))),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: FilledButton.icon(onPressed: () {
            if (_dailyMixSongs == null || _dailyMixSongs!.isEmpty) return;
            Provider.of<PlayerProvider>(context, listen: false).playSong(_dailyMixSongs!.first, playlist: _dailyMixSongs!, startIndex: 0);
          }, icon: const Icon(Icons.play_arrow_rounded), label: Text(AppLocalizations.of(context)!.localeName.startsWith('ru') ? 'Слушать Ежедневный микс' : 'Listen Daily Mix'))),
        ],
        Divider(height: 1, indent: 16, endIndent: 16, color: _isDark ? AppTheme.darkDivider : AppTheme.lightDivider),
      ],
    );
  }

  Widget _buildAiDailyMixSection(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final isRu =
        AppLocalizations.of(context)!.localeName.startsWith('ru');
    final songs = _aiDailyMix?.songs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10)),
                  child: Icon(Icons.auto_awesome_rounded,
                      color: accent, size: 24)),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(
                        _aiDailyMix?.name ??
                            (isRu
                                ? 'Ежедневный ИИ-микс'
                                : 'Daily AI Mix'),
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    FutureBuilder<bool>(
                      future: AiMixService().shouldGenerateDaily(),
                      builder: (ctx, snap) {
                        final due = snap.data == true;
                        return Text(
                            _aiDailyLoading
                                ? (isRu ? 'Генерируем…' : 'Generating…')
                                : (due
                                    ? (isRu
                                        ? 'Готов к генерации'
                                        : 'Ready to generate')
                                    : (isRu
                                        ? 'Уже создан сегодня'
                                        : 'Already made today')),
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey));
                      },
                    ),
                  ])),
              if (_aiDailyLoading)
                const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else
                IconButton(
                    tooltip: AppLocalizations.of(context)!.refresh,
                    icon: const Icon(Icons.refresh_rounded),
                    onPressed: () async {
                      final lib = Provider.of<LibraryProvider>(context,
                          listen: false);
                      final pool = await lib.getPoolForMix(limit: 700);
                      _loadAiDailyMix(pool, force: true);
                    }),
              IconButton(
                  icon: Icon(_aiDailyExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded),
                  onPressed: () =>
                      setState(() => _aiDailyExpanded = !_aiDailyExpanded)),
            ],
          ),
        ),
        if (_aiDailyLoading && songs == null)
          const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2)))
        else if (songs == null || songs.isEmpty)
          Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                  isRu
                      ? 'ИИ-микс ещё не собран — нажми refresh'
                      : 'AI mix not ready yet — hit refresh',
                  style: TextStyle(
                      color: _isDark
                          ? AppTheme.darkSecondaryText
                          : AppTheme.lightSecondaryText)))
        else ...[
          if ((_aiDailyMix?.comment ?? '').isNotEmpty)
            Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(_aiDailyMix!.comment,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: _isDark
                            ? AppTheme.darkSecondaryText
                            : AppTheme.lightSecondaryText))),
          Column(
            children: List.generate(
              _aiDailyExpanded
                  ? songs.length
                  : (songs.length.clamp(0, 3)),
              (i) => RepaintBoundary(
                  child: SongTile(
                      song: songs[i],
                      playlist: songs,
                      index: i,
                      showAlbum: true)),
            ),
          ),
          if (!_aiDailyExpanded && songs.length > 3)
            Center(
                child: TextButton(
                    onPressed: () =>
                        setState(() => _aiDailyExpanded = true),
                    child: Text('Показать все (${songs.length})',
                        style: TextStyle(color: accent)))),
          Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                Expanded(
                    child: FilledButton.icon(
                        onPressed: () {
                          Provider.of<PlayerProvider>(context,
                                  listen: false)
                              .playSong(songs.first,
                                  playlist: songs, startIndex: 0);
                        },
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(isRu ? 'Слушать' : 'Play'))),
                const SizedBox(width: 12),
                Expanded(
                    child: OutlinedButton.icon(
                        onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const AiMixScreen())),
                        icon: const Icon(Icons.open_in_new_rounded,
                            size: 16),
                        label: Text(isRu ? 'В ИИ-миксы' : 'Open AI'))),
              ])),
        ],
        Divider(
            height: 1,
            indent: 16,
            endIndent: 16,
            color: _isDark ? AppTheme.darkDivider : AppTheme.lightDivider),
      ],
    );
  }

  Widget _buildSeedWaveSection(BuildContext context, List<Song> pool) {
    final accent = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: accent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
                child: Icon(Icons.waves_rounded, color: accent, size: 24),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Моя волна по...', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                    Text('Выбери артиста или жанр', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => _showArtistPicker(context, pool),
                  icon: const Icon(Icons.person_rounded, size: 18),
                  label: const Text('По артисту'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => _showGenrePicker(context, pool),
                  icon: const Icon(Icons.category_rounded, size: 18),
                  label: const Text('По жанру'),
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, indent: 16, endIndent: 16, color: _isDark ? AppTheme.darkDivider : AppTheme.lightDivider),
      ],
    );
  }

  void _showArtistPicker(BuildContext context, List<Song> pool) {
    final rec = Provider.of<RecommendationService>(context, listen: false);
    final topArtists = rec.getTopFavoriteArtists(limit: 30);
    // Build full artist set from entire pool (fix: previously capped at 50, Баста at 70k not visible)
    final allPoolArtists = <String>{};
    final poolLower = <String>{};
    for (final s in pool) {
      if (s.artist != null && s.artist!.trim().isNotEmpty) {
        final low = s.artist!.toLowerCase();
        if (poolLower.add(low)) allPoolArtists.add(s.artist!.trim());
      }
    }
    List<String> artists = List<String>.from(topArtists);
    final seenLower = artists.map((e) => e.toLowerCase()).toSet();
    for (final a in allPoolArtists) {
      if (!seenLower.contains(a.toLowerCase())) {
        artists.add(a);
        seenLower.add(a.toLowerCase());
      }
    }
    if (topArtists.length < 10) {
      artists.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }
    final controller = TextEditingController();
    List<String> filtered = artists.take(200).toList();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setS) {
          return DraggableScrollableSheet(
            initialChildSize: 0.7,
            minChildSize: 0.5,
            maxChildSize: 0.9,
            expand: false,
            builder: (_, scroll) => Column(
              children: [
                const SizedBox(height: 12),
                Container(width: 36, height: 4, decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(2))),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: TextField(
                    controller: controller,
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Поиск артиста', border: OutlineInputBorder(), isDense: true),
                    onChanged: (q) {
                      final low = q.toLowerCase();
                      setS(() {
                        filtered = q.isEmpty ? artists.take(200).toList() : artists.where((a) => a.toLowerCase().contains(low)).take(200).toList();
                      });
                    },
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: scroll,
                    itemCount: filtered.length,
                    itemBuilder: (_, i) {
                      final a = filtered[i];
                      return ListTile(
                        leading: const Icon(Icons.person_rounded),
                        title: Text(a, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          _playSeedWave(context, pool, seedArtist: a);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        });
      },
    ).whenComplete(() => controller.dispose());
  }

  void _showGenrePicker(BuildContext context, List<Song> pool) {
    final rec = Provider.of<RecommendationService>(context, listen: false);
    var genres = List<String>.from(rec.getRecommendedGenres(limit: 30));
    // Always merge with pool genres so list not stuck at 1 when affinity is narrow
    final seenLower = genres.map((e) => e.toLowerCase()).toSet();
    for (final s in pool) {
      if (s.genre != null && !seenLower.contains(s.genre!.toLowerCase())) {
        genres.add(s.genre!);
        seenLower.add(s.genre!.toLowerCase());
      }
      if (genres.length >= 30) break;
    }
    // If server has richGenres, prioritize those over pool singletons (fallback to libraryProvider)
    try {
      final lib = Provider.of<LibraryProvider>(context, listen: false);
      for (final g in lib.richGenres.map((e) => e.value)) {
        if (!seenLower.contains(g.toLowerCase())) {
          genres.add(g);
          seenLower.add(g.toLowerCase());
        }
        if (genres.length >= 30) break;
      }
    } catch (_) {}
    genres.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(width: 36, height: 4, decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(2))),
            const Padding(padding: EdgeInsets.all(16), child: Text('Выбери жанр', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: genres.length,
                itemBuilder: (_, i) {
                  final g = genres[i];
                  return ListTile(
                    leading: const Icon(Icons.category_rounded),
                    title: Text(g),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _playSeedWave(context, pool, seedGenre: g);
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _playSeedWave(BuildContext context, List<Song> pool, {String? seedArtist, String? seedGenre}) async {
    final rec = Provider.of<RecommendationService>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final player = Provider.of<PlayerProvider>(context, listen: false);
    // Показываем модальный индикатор — барьер не закрывается тапом
    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black38,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: CircularProgressIndicator(
            color: Theme.of(context).colorScheme.primary,
            strokeWidth: 3,
          ),
        ),
      ),
    );
    // Даём кадр отрисоваться перед тяжёлым getPersonalizedFeed (убирает ANR/краш вьюпорта)
    await Future.delayed(const Duration(milliseconds: 120));
    if (!context.mounted) {
      return;
    }
    List<Song> wave = const [];
    try {
      wave = await Future(() => rec.getPersonalizedFeed(pool, limit: 50, seedArtist: seedArtist, seedGenre: seedGenre))
          .timeout(const Duration(seconds: 10), onTimeout: () => <Song>[]);
      if (!context.mounted) return;
      if (wave.isEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(seedArtist != null ? 'Нет треков для артиста "$seedArtist"' : 'Нет треков для жанра "$seedGenre"')));
        return;
      }
      // Сид как на десктопе: «В стиле: …», иначе шапка — «Моя коллекция».
      final seedName = seedArtist != null && seedArtist.isNotEmpty
          ? seedLabel(WaveSeed(kind: 'artist', label: seedArtist))
          : 'Волна · $seedGenre';
      await saveWaveSeed(seedArtist != null && seedArtist.isNotEmpty
          ? WaveSeed(kind: 'artist', label: seedArtist)
          : null);
      await saveWaveContext(
          wave.map((s) => s.id).toList(), seedName, 'local');
      player.playSong(wave.first,
          playlist: wave,
          startIndex: 0,
          playlistName: seedName,
          isWave: true);
      messenger.showSnackBar(SnackBar(content: Text('$seedName: ${wave.length} треков'), duration: const Duration(seconds: 2)));
    } catch (e, st) {
      debugPrint('[Mixes] _playSeedWave error: $e $st');
      if (context.mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Ошибка волны: $e')));
      }
    } finally {
      // Гарантированно закрываем диалог — даже если уже заиграно, иначе крутилка остаётся (баг из логов)
      if (context.mounted) {
        try {
          Navigator.of(context, rootNavigator: true).pop();
        } catch (_) {
          try { if (Navigator.of(context).canPop()) Navigator.of(context).pop(); } catch (_) {}
        }
      }
    }
  }

  void _showInstantMixForSong(BuildContext context, Song seed) {
    final autoDj = Provider.of<AutoDjService?>(context, listen: false);
    if (autoDj == null) return;
    final lib = Provider.of<LibraryProvider>(context, listen: false);
    final pool = lib.cachedAllSongs.isNotEmpty ? lib.cachedAllSongs : lib.randomSongs;
    InstantMixDialog.show(context: context, seedSong: seed, autoDjService: autoDj, availableSongs: pool, onConfirm: (mix) {
      if (mix.isEmpty) return;
      List<Song> ordered = mix;
      try {
        ordered = PlaylistOrchestrator.orchestrate(mix, startWith: 'mixed', endWith: 'mixed');
      } catch (_) {}
      Provider.of<PlayerProvider>(context, listen: false).playSong(ordered.first, playlist: ordered, startIndex: 0);
    });
  }

  Widget _buildMixCard(BuildContext context, String name, List<Song> songs, {String? rawKey}) {
    final shape = PlayerUiSettingsService().getArtworkShape();
    final radiusVal = PlayerUiSettingsService().getAlbumArtCornerRadius();
    final borderRadius = shape == 'circle' ? 9999.0 : shape == 'square' ? 0.0 : radiusVal.clamp(0.0, 24.0);
    // single generation cache — already via _lastKey, no rebuild each build
    final iconData = _mixIcon(rawKey ?? name);
    // Extract icon/color from _mixIcon container
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MixDetailScreen(mixName: name, songs: songs))),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.primary.withValues(alpha: 0.85),
              Theme.of(context).colorScheme.primary.withValues(alpha: 0.55),
            ],
          ),
          boxShadow: [
            BoxShadow(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25), blurRadius: 8, offset: const Offset(0, 4)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Stack(
            children: [
              Positioned.fill(child: CustomPaint(painter: _CardWavePainter(color: Colors.white.withValues(alpha: 0.08)))),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    iconData,
                    const Spacer(),
                    Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14, shadows: [Shadow(color: Colors.black26, blurRadius: 4)])),
                    const SizedBox(height: 4),
                    Text('${songs.length} треков', style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 11)),
                  ],
                ),
              ),
              Positioned(
                bottom: 8,
                right: 8,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  child: const Icon(Icons.play_arrow_rounded, color: Colors.black, size: 20),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mixIcon(String name) {
    IconData icon;
    Color color = AppTheme.loginAccent;
    final lower = name.toLowerCase();
    if (lower.contains('mood') || lower.contains('happy') || lower.contains('sad') || lower.contains('melancholic') || lower.contains('aggressive') || lower.contains('energetic') || lower.contains('calm')) {
      icon = Icons.mood_rounded;
    } else if (lower.contains('tempo')) {
      icon = Icons.speed_rounded;
    } else if (lower.contains('era')) {
      icon = Icons.history_rounded;
    } else if (lower.contains('deep cut')) {
      icon = Icons.spa_rounded;
    } else if (lower.contains('fusion')) {
      icon = Icons.merge_rounded;
    } else if (lower.contains('quick')) {
      icon = Icons.flash_on_rounded;
      color = AppTheme.spotifyGreen;
    } else if (lower.contains('discover')) {
      icon = Icons.explore_rounded;
      color = AppTheme.spotifyGreen;
    } else if (lower.contains('vibes') || lower.contains('time of day')) {
      icon = Icons.nightlight_round;
    } else if (lower.contains('workout')) {
      icon = Icons.fitness_center_rounded;
      color = Colors.redAccent;
    } else if (lower.contains('running')) {
      icon = Icons.directions_run_rounded;
      color = Colors.orange;
    } else if (lower.contains('cycling')) {
      icon = Icons.directions_bike_rounded;
      color = Colors.teal;
    } else if (lower.contains('meditation')) {
      icon = Icons.self_improvement_rounded;
      color = Colors.purple;
    } else if (lower.contains('sleep')) {
      icon = Icons.bedtime_rounded;
      color = Colors.indigo;
    } else if (lower.contains('focus')) {
      icon = Icons.center_focus_strong_rounded;
      color = Colors.blueGrey;
    } else if (lower.contains('creativity')) {
      icon = Icons.brush_rounded;
      color = Colors.amber;
    } else if (lower.contains('cooking')) {
      icon = Icons.restaurant_rounded;
      color = Colors.deepOrange;
    } else if (lower.contains('reading')) {
      icon = Icons.menu_book_rounded;
      color = Colors.brown;
    } else if (lower.contains('gaming')) {
      icon = Icons.videogame_asset_rounded;
      color = Colors.green;
    } else if (lower.contains('acoustic')) {
      icon = Icons.music_note_rounded;
      color = Colors.brown;
    } else if (lower.contains('daily')) {
      icon = Icons.history_rounded;
      color = Colors.deepPurple;
    } else {
      icon = Icons.album_rounded;
    }

    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: color, size: 24),
    );
  }
}

class _CardWavePainter extends CustomPainter {
  final Color color;
  _CardWavePainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.2;
    final path = Path();
    final h = size.height * 0.08;
    final w = size.width * 0.18;
    for (double y = 0; y < size.height; y += h * 2) {
      path.moveTo(0, y);
      for (double x = 0; x < size.width; x += w) {
        path.quadraticBezierTo(x + w/2, y - h, x + w, y);
      }
    }
    canvas.drawPath(path, paint);
  }
  @override
  bool shouldRepaint(covariant CustomPainter o) => false;
}
