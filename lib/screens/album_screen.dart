import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../services/ml_service.dart';
import '../services/subsonic_service.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';
import '../widgets/widgets.dart';
import '../widgets/app_gradient_background.dart';
import '../l10n/app_localizations.dart';
import '../utils/navigation_helper.dart';
import '../utils/screen_helper.dart';
import '../services/offline_service.dart';
import 'genre_screen.dart';

class AlbumScreen extends StatefulWidget {
  final String albumId;

  const AlbumScreen({super.key, required this.albumId});

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  Album? _album;
  List<Song> _songs = [];
  bool _isLoading = true;
  bool _isDownloading = false;

  @override
  void initState() {
    super.initState();
    _loadAlbum();
  }

  Future<void> _loadAlbum() async {
    final subsonicService = Provider.of<SubsonicService>(
      context,
      listen: false,
    );
    final libraryProvider = Provider.of<LibraryProvider>(
      context,
      listen: false,
    );

    try {
      Album? album;

      if (libraryProvider.isLocalOnlyMode) {
        album = libraryProvider.cachedAllAlbums.firstWhere(
          (a) => a.id == widget.albumId,
          orElse: () => Album(id: widget.albumId, name: 'Unknown Album'),
        );
      } else {
        album = await subsonicService.getAlbum(widget.albumId);
      }

      final songs = await libraryProvider.getAlbumSongs(widget.albumId);

      if (mounted) {
        setState(() {
          _album = album;
          _songs = songs;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _playAll({bool shuffle = false}) {
    if (_songs.isEmpty) return;

    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);

    List<Song> playlist = List.from(_songs);
    if (shuffle) {
      playlist.shuffle();
    }

    // Имя альбома — в шапку очереди (иначе «Моя коллекция»).
    final qName = _album?.name.trim().isNotEmpty == true
        ? _album!.name.trim()
        : 'Альбом';
    playerProvider.playSong(
      playlist.first,
      playlist: playlist,
      startIndex: 0,
      playlistName: qName,
    );
  }

  Future<void> _downloadAlbum() async {
    if (_songs.isEmpty) return;

    final subsonicService = Provider.of<SubsonicService>(
      context,
      listen: false,
    );
    final offlineService = OfflineService();
    await offlineService.initialize();

    if (!mounted) return;
    setState(() => _isDownloading = true);

    try {
      await offlineService.startBackgroundDownload(_songs, subsonicService);
      if (!mounted) return;
      setState(() => _isDownloading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Downloaded ${_songs.length} songs from ${_album!.name}',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      debugPrint('[Album] background download failed: $e');
      if (!mounted) return;
      setState(() => _isDownloading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Не удалось скачать: $e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Downloading ${_songs.length} songs in background…'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (_isLoading) {
      return Scaffold(backgroundColor: Colors.transparent, 
        appBar: AppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),),
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const AlbumArtworkShimmer(size: 250),
                    const SizedBox(height: 24),
                    Shimmer.fromColors(
                      baseColor:
                          isDark ? AppTheme.darkCard : const Color(0xFFE0E0E0),
                      highlightColor: isDark
                          ? const Color(0xFF2A2A2A)
                          : const Color(0xFFF5F5F5),
                      child: Container(
                        width: 200,
                        height: 24,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Shimmer.fromColors(
                      baseColor:
                          isDark ? AppTheme.darkCard : const Color(0xFFE0E0E0),
                      highlightColor: isDark
                          ? const Color(0xFF2A2A2A)
                          : const Color(0xFFF5F5F5),
                      child: Container(
                        width: 150,
                        height: 18,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => const SongTileShimmer(),
                childCount: 10,
              ),
            ),
          ],
        ),
      );
    }

    if (_album == null) {
      return Scaffold( 
        appBar: AppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),),
        body: Center(child: Text(AppLocalizations.of(context)!.albumNotFound)),
      );
    }

    final totalDuration = _songs.fold<int>(
      0,
      (sum, song) => sum + (song.duration ?? 0),
    );
    final hours = totalDuration ~/ 3600;
    final minutes = (totalDuration % 3600) ~/ 60;

    final isOffline = Provider.of<AuthProvider>(context, listen: false).state ==
        AuthState.offlineMode;

    return Scaffold( 
      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              SliverAppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),
                pinned: true,
                expandedHeight: ScreenHelper.isSmallScreen(context) ? 280 : 360,
                leading: IconButton(
                  icon: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.black.withValues(alpha: 0.5)
                          : Colors.white.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      CupertinoIcons.back,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
                flexibleSpace: FlexibleSpaceBar(
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      Padding(
                        padding: EdgeInsets.only(
                          top: MediaQuery.of(context).padding.top + 40,
                          left: ScreenHelper.isSmallScreen(context) ? 24 : 40,
                          right: ScreenHelper.isSmallScreen(context) ? 24 : 40,
                          bottom: ScreenHelper.isSmallScreen(context) ? 60 : 80,
                        ),
                        child: AlbumArtwork(
                          coverArt: _album!.coverArt,
                          size: ScreenHelper.isSmallScreen(context) ? 200 : 280,
                          borderRadius: 10,
                          preserveAspectRatio: true,
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  if (!isOffline)
                    IconButton(
                      tooltip: 'Download album',
                      onPressed: _isDownloading ? null : _downloadAlbum,
                      icon: _isDownloading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(CupertinoIcons.cloud_download),
                    ),
                ],
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        _album!.name,
                        style: theme.textTheme.headlineLarge?.copyWith(
                          fontSize:
                              ScreenHelper.isSmallScreen(context) ? 22 : null,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      MultiArtistWidget(
                        artists: _album!.artistParticipants,
                        artistFallback: _album!.artist ??
                            AppLocalizations.of(context)!.unknownArtist,
                        artistIdFallback: _album!.artistId,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: AppTheme.appleMusicRed,
                          fontSize:
                              ScreenHelper.isSmallScreen(context) ? 16 : null,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (_album!.genre != null)
                            _album!.genre!.toUpperCase(),
                          if (_album!.year != null) _album!.year.toString(),
                          if (hours > 0)
                            '$hours HR $minutes MIN'
                          else
                            '$minutes MIN',
                        ].join(' • '),
                        style: theme.textTheme.bodySmall,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: _PlayButton(
                              icon: CupertinoIcons.play_fill,
                              label: AppLocalizations.of(context)!.play,
                              onTap: () => _playAll(),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _PlayButton(
                              icon: CupertinoIcons.shuffle,
                              label: AppLocalizations.of(context)!.shuffle,
                              onTap: () => _playAll(shuffle: true),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final song = _songs[index];
                  return SongTile(
                    song: song,
                    playlist: _songs,
                    index: index,
                    showArtwork: false,
                    showTrackNumber: true,
                    showArtist: false,
                  );
                }, childCount: _songs.length),
              ),
              // «Альбомы в этом жанре» — тихо скрывается при пусто/ошибке.
              if (_album?.genre != null && _album!.genre!.isNotEmpty)
                SliverToBoxAdapter(
                  child: _GenreAlbumsSection(
                    genre: _album!.genre!,
                    currentAlbumId: _album!.id,
                    currentArtistId: _album!.artistId,
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 150)),
            ],
          ),
        ],
      ),
    );
  }
}

/// «Ещё в жанре»: альбомы того же жанра, но других артистов.
/// Серверный getAlbumList2 byGenre (быстрый, поддерживается Navidrome),
/// офлайн-фолбэк — фильтр cachedAllAlbums локально.
/// Ранжирование «по-умному»: топ-2 по суммарному playCount треков из
/// локальной библиотеки (вкус), остальное — шаффл (открытие).
/// Нет данных/ошибка/таймаут 5с — рендерит пустоту без тостов.
class _GenreAlbumsSection extends StatefulWidget {
  final String genre;
  final String currentAlbumId;
  final String? currentArtistId;

  const _GenreAlbumsSection({
    required this.genre,
    required this.currentAlbumId,
    this.currentArtistId,
  });

  @override
  State<_GenreAlbumsSection> createState() => _GenreAlbumsSectionState();
}

class _GenreAlbumsSectionState extends State<_GenreAlbumsSection> {
  List<Album> _albums = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_GenreAlbumsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.genre != widget.genre ||
        oldWidget.currentAlbumId != widget.currentAlbumId) {
      _loaded = false;
      _albums = [];
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final lib = Provider.of<LibraryProvider>(context, listen: false);
      List<Album> candidates = [];
      // 1) Сервер (5с макс).
      try {
        candidates = await lib
            .getAlbumsByGenre(widget.genre)
            .timeout(const Duration(seconds: 5));
      } on TimeoutException catch (_) {
        candidates = [];
      } catch (_) {
        candidates = [];
      }
      // 2) Офлайн/пусто — локальный фильтр.
      if (candidates.isEmpty && lib.cachedAllAlbums.isNotEmpty) {
        final g = widget.genre.toLowerCase();
        candidates = lib.cachedAllAlbums
            .where((a) => (a.genre ?? '').toLowerCase().contains(g))
            .toList();
      }
      // 3) Выкидываем текущий альбом и альбомы того же артиста.
      candidates = candidates.where((a) {
        if (a.id == widget.currentAlbumId) return false;
        if (widget.currentArtistId != null &&
            a.artistId != null &&
            a.artistId == widget.currentArtistId) {
          return false;
        }
        // Фолбэк по имени артиста, если id нет.
        if ((a.artistId == null || widget.currentArtistId == null) &&
            _albumArtistName != null &&
            a.artist != null &&
            a.artist!.toLowerCase() == _albumArtistName!.toLowerCase()) {
          return false;
        }
        return true;
      }).toList();
      if (candidates.isEmpty) {
        if (mounted) setState(() => _loaded = true);
        return;
      }
      // 4) «По-умному»: скоринг по playCount треков альбома из БД.
      // Было: суммирование по 80к кэша. Стало: GROUP BY в SQL.
      final byAlbum = <String, int>{};
      try {
        byAlbum.addAll(await lib.getAlbumPlayCounts());
        // Лёгкий ML-вес: лайкнутые треки альбома (по рабочему набору).
        final ml = MLService();
        for (final s in lib.cachedAllSongs) {
          if (ml.profile.likedSongs.contains(s.id) && s.albumId != null) {
            byAlbum[s.albumId!] = (byAlbum[s.albumId!] ?? 0) + 5;
          }
        }
      } catch (_) {}
      candidates.sort(
        (a, b) => (byAlbum[b.id] ?? 0).compareTo(byAlbum[a.id] ?? 0),
      );
      final top = candidates.take(2).toList();
      final rest = candidates.skip(top.length).toList()..shuffle();
      final ordered = [...top, ...rest].take(10).toList();
      if (mounted) {
        setState(() {
          _albums = ordered;
          _loaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  String? get _albumArtistName {
    try {
      final lib = Provider.of<LibraryProvider>(context, listen: false);
      final match = lib.cachedAllAlbums.where(
        (a) => a.id == widget.currentAlbumId,
      );
      if (match.isNotEmpty) return match.first.artist;
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _albums.isEmpty) return const SizedBox.shrink();
    final isDesktop =
        Theme.of(context).platform == TargetPlatform.macOS ||
        Theme.of(context).platform == TargetPlatform.windows ||
        Theme.of(context).platform == TargetPlatform.linux;
    final cardSize = isDesktop ? 180.0 : 150.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Ещё в жанре «${widget.genre}»',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: () => NavigationHelper.push(
                  context,
                  GenreScreen(genre: widget.genre),
                ),
                child: const Text('Все'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: cardSize + 52,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            scrollDirection: Axis.horizontal,
            itemCount: _albums.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (ctx, i) {
              final album = _albums[i];
              return AlbumCard(
                album: album,
                size: cardSize,
                onTap: () => NavigationHelper.push(
                  ctx,
                  AlbumScreen(albumId: album.id),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PlayButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _PlayButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = Theme.of(context).colorScheme.primary;

    return Material(
      color: accent.withValues(alpha: isDark ? 0.15 : 0.1),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: accent, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: accent,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
