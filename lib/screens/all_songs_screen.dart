import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/theme_service.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../models/models.dart';
import '../widgets/widgets.dart';
import '../widgets/app_gradient_background.dart';
import '../theme/app_theme.dart';

enum SongSortOption {
  titleAsc,
  titleDesc,
  artistAsc,
  artistDesc,
  albumAsc,
  albumDesc,
  recentlyAdded,
}

class AllSongsScreen extends StatefulWidget {
  const AllSongsScreen({super.key});

  @override
  State<AllSongsScreen> createState() => _AllSongsScreenState();
}

class _AllSongsScreenState extends State<AllSongsScreen> {
  // П1: пагинация из SQL вместо 80к в RAM. В памяти только окно ~200-1000.
  static const int _pageSize = 200;
  List<Song> _songs = [];
  // Для совместимости остального build-кода: _sortedSongs = то же окно.
  List<Song> _sortedSongs = [];
  int _total = 0;
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  final ScrollController _scrollController = ScrollController();
  SongSortOption _currentSort = SongSortOption.titleAsc;

  String get _dbSort {
    switch (_currentSort) {
      case SongSortOption.titleAsc:
        return 'titleAsc';
      case SongSortOption.titleDesc:
        return 'titleDesc';
      case SongSortOption.artistAsc:
        return 'artistAsc';
      case SongSortOption.artistDesc:
        return 'artistDesc';
      case SongSortOption.albumAsc:
        return 'albumAsc';
      case SongSortOption.albumDesc:
        return 'albumDesc';
      case SongSortOption.recentlyAdded:
        return 'recent';
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFirstPage());
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _isLoadingMore || _isLoading) return;
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    // Догружаем за 800px до конца.
    if (pos.pixels >= pos.maxScrollExtent - 800) {
      _loadMore();
    }
  }

  Future<void> _loadFirstPage() async {
    final libraryProvider = Provider.of<LibraryProvider>(context, listen: false);
    try {
      final total = await libraryProvider.getSongsTotal();
      final page = await libraryProvider.getSongsPage(limit: _pageSize, offset: 0, sort: _dbSort);
      if (!mounted) return;
      setState(() {
        _total = total;
        _songs = page;
        _sortedSongs = page;
        _hasMore = page.length >= _pageSize && _songs.length < total;
        _isLoading = false;
      });
    } catch (_) {
      // Fallback на старый путь при ошибке БД.
      try {
        await libraryProvider.ensureLibraryLoaded();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _songs = libraryProvider.cachedAllSongs.take(1000).toList();
        _sortedSongs = _songs;
        _total = libraryProvider.cachedAllSongs.length;
        _hasMore = false;
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final libraryProvider = Provider.of<LibraryProvider>(context, listen: false);
      final page = await libraryProvider.getSongsPage(limit: _pageSize, offset: _songs.length, sort: _dbSort);
      if (!mounted) return;
      setState(() {
        _songs.addAll(page);
        _sortedSongs = _songs;
        _hasMore = page.length >= _pageSize && _songs.length < _total;
        _isLoadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  Future<void> _reloadForSort() async {
    setState(() {
      _isLoading = true;
      _songs = [];
      _sortedSongs = [];
      _hasMore = true;
    });
    await _loadFirstPage();
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  // Сортировка идет в SQL (ORDER BY), List.sort 80к удален (П1).

  void _showSortOptions() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppTheme.darkCard : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Sort By',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
            const SizedBox(height: 8),
            _buildSortOption('Title (A-Z)', SongSortOption.titleAsc, isDark),
            _buildSortOption('Title (Z-A)', SongSortOption.titleDesc, isDark),
            _buildSortOption('Artist (A-Z)', SongSortOption.artistAsc, isDark),
            _buildSortOption('Artist (Z-A)', SongSortOption.artistDesc, isDark),
            _buildSortOption('Album (A-Z)', SongSortOption.albumAsc, isDark),
            _buildSortOption('Album (Z-A)', SongSortOption.albumDesc, isDark),
            _buildSortOption(
              'Recently Added',
              SongSortOption.recentlyAdded,
              isDark,
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildSortOption(String title, SongSortOption option, bool isDark) {
    final isSelected = _currentSort == option;
    return ListTile(
      title: Text(
        title,
        style: TextStyle(
          color: isSelected
              ? AppTheme.appleMusicRed
              : (isDark ? Colors.white : Colors.black),
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      trailing:
          isSelected ? Icon(Icons.check, color: AppTheme.appleMusicRed) : null,
      onTap: () {
        Navigator.pop(context);
        setState(() => _currentSort = option);
        _reloadForSort();
      },
    );
  }

  void _playAll({bool shuffle = false}) {
    // П1: играем загруженное окно (до 1000), а не 80к копией.
    if (_sortedSongs.isEmpty) return;
    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
    List<Song> playlist = List.from(_sortedSongs);
    if (shuffle) {
      playlist.shuffle();
    }
    playerProvider.playSong(playlist.first, playlist: playlist, startIndex: 0);
  }

  String _getSortLabel() {
    switch (_currentSort) {
      case SongSortOption.titleAsc:
        return 'Title (A-Z)';
      case SongSortOption.titleDesc:
        return 'Title (Z-A)';
      case SongSortOption.artistAsc:
        return 'Artist (A-Z)';
      case SongSortOption.artistDesc:
        return 'Artist (Z-A)';
      case SongSortOption.albumAsc:
        return 'Album (A-Z)';
      case SongSortOption.albumDesc:
        return 'Album (Z-A)';
      case SongSortOption.recentlyAdded:
        return 'Recently Added';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),
        title: Text(AppLocalizations.of(context)!.allSongs),
        
        actions: [
          if (_sortedSongs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.sort_rounded),
              onPressed: _showSortOptions,
              tooltip: AppLocalizations.of(context)!.sort,
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _songs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.music_note_outlined,
                        size: 64,
                        color: Colors.grey[600],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No songs found',
                        style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  // П1: общий счетчик из SQL, рядом — размер окна в RAM.
                                  '$_total songs${_songs.length < _total ? ' (${_songs.length} loaded)' : ''}',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color:
                                        isDark ? Colors.white : Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                GestureDetector(
                                  onTap: _showSortOptions,
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.sort_rounded,
                                        size: 14,
                                        color: AppTheme.appleMusicRed,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        _getSortLabel(),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: AppTheme.appleMusicRed,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => _playAll(shuffle: true),
                            icon: Icon(
                              Icons.shuffle_rounded,
                              color: isDark ? Colors.white70 : Colors.black54,
                              size: 28,
                            ),
                            tooltip: 'Shuffle play',
                          ),
                          const SizedBox(width: 8),
                          Consumer<PlayerProvider>(
                            builder: (context, playerProvider, _) {
                              // Было O(n*m) any-in-any на каждый build — вешало UI на 80к.
                              final windowIds = _sortedSongs.map((s) => s.id).toSet();
                              final isCurrentPlaylist =
                                  playerProvider.queue.isNotEmpty &&
                                      playerProvider.queue.any(
                                        (song) => windowIds.contains(song.id),
                                      );
                              final isPlaying =
                                  isCurrentPlaylist && playerProvider.isPlaying;

                              return GestureDetector(
                                onTap: () {
                                  if (isCurrentPlaylist &&
                                      playerProvider.currentSong != null) {
                                    if (playerProvider.isPlaying) {
                                      playerProvider.pause();
                                    } else {
                                      playerProvider.play();
                                    }
                                  } else {
                                    _playAll();
                                  }
                                },
                                child: Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: AppTheme.appleMusicRed,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color:
                                            AppTheme.appleMusicRed.withValues(
                                          alpha: 0.4,
                                        ),
                                        blurRadius: 12,
                                        offset: const Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  child: Icon(
                                    isPlaying
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    color: Colors.white,
                                    size: 28,
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.only(bottom: 100),
                        itemCount: _sortedSongs.length + (_hasMore ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index >= _sortedSongs.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }
                          return SongTile(
                            song: _sortedSongs[index],
                            playlist: _sortedSongs,
                            index: index,
                            showAlbum: true,
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
