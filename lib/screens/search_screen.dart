import 'dart:io';
import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import '../services/theme_service.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../services/subsonic_service.dart';
import '../services/audiobookshelf_service.dart';
import 'audiobook_detail_screen.dart';
import '../theme/app_theme.dart';
import '../utils/navigation_helper.dart';
import '../widgets/widgets.dart';
import 'album_screen.dart';
import 'artist_screen.dart';
import 'genres_screen.dart';
import 'new_releases_screen.dart';
import 'top_rated_screen.dart';
import 'favorites_screen.dart';
import 'radio_screen.dart';
import 'podcasts_screen.dart';
import 'podcast_detail_screen.dart';
import '../l10n/app_localizations.dart';
import '../services/player_ui_settings_service.dart';
import '../providers/podcast_provider.dart';
import '../models/podcast.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  SearchResult? _searchResult;
  SearchResult? _autocompleteSuggestions;
  List<Map<String, dynamic>> _bookResults = [];
  bool _isSearching = false;
  bool _isLoadingSuggestions = false;
  bool _showSuggestions = false;
  String _query = '';
  Timer? _debounceTimer;
  bool _liveSearch = true;

  @override
  void initState() {
    super.initState();
    _liveSearch = PlayerUiSettingsService().getLiveSearch();
    PlayerUiSettingsService().liveSearchNotifier.addListener(_onLiveSearchChanged);
  }

  void _onLiveSearchChanged() {
    setState(() {
      _liveSearch = PlayerUiSettingsService().liveSearchNotifier.value;
    });
  }

  @override
  void dispose() {
    PlayerUiSettingsService().liveSearchNotifier.removeListener(_onLiveSearchChanged);
    _searchController.dispose();
    _focusNode.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadAutocomplete(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _autocompleteSuggestions = null;
        _showSuggestions = false;
      });
      return;
    }

    setState(() {
      _isLoadingSuggestions = true;
      _showSuggestions = true;
    });

    try {
      final libraryProvider = Provider.of<LibraryProvider>(
        context,
        listen: false,
      );
      final result = await libraryProvider.search(query);
      if (mounted && _searchController.text.trim() == query.trim()) {
        setState(() {
          _autocompleteSuggestions = result;
          _isLoadingSuggestions = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingSuggestions = false;
        });
      }
    }
  }

  void _onSearchChanged(String value) {
    _debounceTimer?.cancel();

    if (value.trim().isEmpty) {
      setState(() {
        _searchResult = null;
        _autocompleteSuggestions = null;
        _showSuggestions = false;
        _query = '';
        _bookResults = [];
        _isSearching = false;
        _isLoadingSuggestions = false;
      });
      // Очищаем подкаст-поиск, иначе после стирания остаются старые результаты и вместо категорий показывается "Подкасты"
      try {
        Provider.of<PodcastProvider>(context, listen: false).clearSearch();
      } catch (_) {}
      return;
    }

    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (_liveSearch) {
        _search(value);
      } else {
        _loadAutocomplete(value);
      }
    });
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _searchResult = null;
        _bookResults = [];
        _query = '';
        _showSuggestions = false;
      });
      Provider.of<PodcastProvider>(context, listen: false).clearSearch();
      return;
    }

    setState(() {
      _isSearching = true;
      _query = query;
      _showSuggestions = false;
    });

    try {
      final libraryProvider = Provider.of<LibraryProvider>(
        context,
        listen: false,
      );
      final podcastProvider = Provider.of<PodcastProvider>(context, listen: false);
      final absFuture = AudiobookshelfService().isConfigured
          ? AudiobookshelfService().searchBooks(query)
          : Future.value(<Map<String, dynamic>>[]);
      final results = await Future.wait([
        libraryProvider.search(query),
        absFuture,
        podcastProvider.search(query),
      ]);
      final result = results[0] as SearchResult;
      final books = results[1] as List<Map<String, dynamic>>;
      if (mounted && _query == query) {
        setState(() {
          _searchResult = result;
          _bookResults = books;
          _isSearching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final intensity = context.select<ThemeService, double>((t) => t.gradientIntensity);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accentColor =
        context.select<ThemeService, Color>((t) => t.accentColor.color);

    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                floating: true,
                expandedHeight: 120,
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
                        title: Text(
                          AppLocalizations.of(context)!.searchTitle,
                          style: theme.appBarTheme.titleTextStyle?.copyWith(
                            letterSpacing: -0.3,
                            shadows: [
                              Shadow(
                                color: Colors.black.withValues(
                                    alpha: isDark ? 0.55 : 0.18),
                                blurRadius: 12,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                        titlePadding:
                            const EdgeInsets.only(left: 16, bottom: 60),
                      ),
                    ),
                  ),
                ),
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(56),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: CupertinoSearchTextField(
                      controller: _searchController,
                      focusNode: _focusNode,
                      placeholder: AppLocalizations.of(
                        context,
                      )!.searchPlaceholder,
                      style: theme.textTheme.bodyLarge,
                      backgroundColor: isDark
                          ? AppTheme.darkCard
                          : AppTheme.lightBackground,
                      onChanged: _onSearchChanged,
                      onSubmitted: (value) {
                        setState(() => _showSuggestions = false);
                        _search(value);
                      },
                    ),
                  ),
                ),
              ),
              if (_isSearching)
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      const SizedBox(height: 24),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          AppLocalizations.of(context)!.albums,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 12),
                      HorizontalShimmerList(
                        count: 3,
                        child: const AlbumCardShimmer(size: 150),
                      ),
                      const SizedBox(height: 24),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          AppLocalizations.of(context)!.songs,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      ...List.generate(5, (_) => const SongTileShimmer()),
                    ],
                  ),
                )
              else if ((_searchResult != null && !_searchResult!.isEmpty) || _bookResults.isNotEmpty || context.select<PodcastProvider, bool>((p) => p.searchResults.isNotEmpty))
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      if (_searchResult != null && !_searchResult!.isEmpty) _buildSearchResults(),
                      _buildPodcastSearchResults(),
                      if (_bookResults.isNotEmpty) _buildBookResults(),
                    ],
                  ),
                )
              else if (_query.isNotEmpty && _searchResult?.isEmpty == true && _bookResults.isEmpty && context.select<PodcastProvider, bool>((p) => p.searchResults.isEmpty))
                SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          CupertinoIcons.search,
                          size: 64,
                          color: AppTheme.lightSecondaryText,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          AppLocalizations.of(context)!.noResults,
                          style: theme.textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          AppLocalizations.of(context)!.tryDifferentSearch,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: AppTheme.lightSecondaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                SliverToBoxAdapter(child: _buildBrowseCategories()),
            ],
          ),
          
          if (_showSuggestions && _searchController.text.isNotEmpty)
            Positioned(
              top: 120 + 56 + 8,
              left: 16,
              right: 16,
              child: _buildAutocompleteOverlay(isDark),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchResults() {
    final result = _searchResult!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (result.artists.isNotEmpty) ...[
          SectionHeader(title: AppLocalizations.of(context)!.artists),
          ...result.artists
              .take(5)
              .map(
                (artist) => ArtistTile(
                  artist: artist,
                  onTap: () => NavigationHelper.push(
                    context,
                    ArtistScreen(artistId: artist.id),
                  ),
                ),
              ),
          const SizedBox(height: 16),
        ],

        if (result.albums.isNotEmpty) ...[
          HorizontalScrollSection(
            title: AppLocalizations.of(context)!.albums,
            children: result.albums
                .take(10)
                .map(
                  (album) => AlbumCard(
                    album: album,
                    size: 150,
                    onTap: () => NavigationHelper.push(
                      context,
                      AlbumScreen(albumId: album.id),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 16),
        ],

        if (result.songs.isNotEmpty) ...[
          SectionHeader(title: AppLocalizations.of(context)!.songs),
          ...result.songs.asMap().entries.map(
            (entry) => SongTile(
              song: entry.value,
              playlist: result.songs,
              index: entry.key,
              showArtist: true,
              showAlbum: true,
            ),
          ),
        ],

        const SizedBox(height: 150),
      ],
    );
  }

  Widget _buildBookResults() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: 'Книги'),
        ..._bookResults.take(10).map((b) {
          final id = b['id'] as String? ?? '';
          final title = b['media']?['metadata']?['title'] ?? 'Unknown';
          final author = b['media']?['metadata']?['authorName'] ?? b['media']?['metadata']?['author'] ?? '';
          return ListTile(
            leading: const Icon(Icons.menu_book_rounded),
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(author, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AudiobookDetailScreen(itemId: id, initialData: b))),
          );
        }),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildPodcastSearchResults() {
    return Consumer<PodcastProvider>(
      builder: (context, pod, _) {
        if (pod.isSearching) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        if (pod.searchResults.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(title: 'Подкасты'),
            ...pod.searchResults.take(8).map((r) {
              return ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: r.artworkUrl.isNotEmpty
                      ? Image.network(r.artworkUrl, width: 44, height: 44, fit: BoxFit.cover, errorBuilder: (c,u,e)=>Container(width:44,height:44,color: Colors.purple.shade100, child: const Icon(Icons.podcasts_rounded, size: 20)))
                      : Container(width:44,height:44,color: Colors.purple.shade100, child: const Icon(Icons.podcasts_rounded, size: 20)),
                ),
                title: Text(r.trackName, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(r.artistName, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  icon: const Icon(Icons.add_rounded),
                  onPressed: () async {
                    final ok = await pod.addFeed(r.feedUrl);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Подкаст добавлен' : pod.error ?? 'Ошибка')));
                  },
                ),
                onTap: () async {
                  // temporary podcast stub -> detail with feedUrl
                  final Podcast stub = r.toPodcastStub();
                  NavigationHelper.push(context, PodcastDetailScreen(podcast: stub));
                },
              );
            }),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }

  Widget _buildBrowseCategories() {
    // Обложки для плиток: берём первые доступные картинки из провайдеров.
    // Если картинок нет (офлайн/пустая библиотека) — coverUrl null и
    // карточка выглядит как раньше (градиент + иконка).
    String? podcastsCover;
    String? newReleasesCover;
    String? topRatedCover;
    String? genresCover;
    String? favoritesCover;
    try {
      final lib = Provider.of<LibraryProvider>(context, listen: false);
      String? firstCover(Iterable<String?> ids) {
        for (final id in ids) {
          if (id != null && id.isNotEmpty) {
            try {
              final url = lib.getCoverArtUrl(id);
              if (url.isNotEmpty) return url;
            } catch (_) {}
          }
        }
        return null;
      }

      if (lib.newestAlbums.isNotEmpty) {
        newReleasesCover = firstCover(
          lib.newestAlbums.map((a) => a.coverArt),
        );
      }
      if (lib.frequentAlbums.isNotEmpty) {
        topRatedCover = firstCover(
          lib.frequentAlbums.map((a) => a.coverArt),
        );
      }
      // Для плитки "Жанры": любая первая обложка из треков.
      try {
        favoritesCover = firstCover([
          ...lib.starred?.songs.map((s) => s.coverArt) ?? const <String?>[],
          ...lib.starred?.albums.map((a) => a.coverArt) ?? const <String?>[],
        ]);
      } catch (_) {}
      try {
        genresCover = firstCover(
          lib.cachedAllSongs.map((s) => s.coverArt),
        );
      } catch (_) {}
      // Фолбэки, если частотные/новые альбомы ещё не загружены.
      newReleasesCover ??= firstCover(
        lib.cachedAllSongs.map((s) => s.coverArt),
      );
      topRatedCover ??= newReleasesCover;
      genresCover ??= newReleasesCover;
    } catch (_) {}
    try {
      final pod = Provider.of<PodcastProvider>(context, listen: false);
      for (final pc in [...pod.subscriptions, ...pod.featured]) {
        if (pc.imageUrl != null && pc.imageUrl!.isNotEmpty) {
          podcastsCover = pc.imageUrl;
          break;
        }
      }
    } catch (_) {}
    final categories = [
      _CategoryItem(
        'Подкасты',
        Icons.podcasts_rounded,
        [Colors.purple, Colors.deepPurple],
        () => NavigationHelper.push(context, const PodcastsScreen()),
        coverUrl: podcastsCover,
      ),
      _CategoryItem(
        AppLocalizations.of(context)!.categoryNewReleases,
        Icons.album_rounded,
        [Colors.orange, Colors.red],
        () => NavigationHelper.push(context, const NewReleasesScreen()),
        coverUrl: newReleasesCover,
      ),
      _CategoryItem(
        AppLocalizations.of(context)!.categoryTopRated,
        Icons.star_rounded,
        [Colors.amber, Colors.orange],
        () => NavigationHelper.push(context, const TopRatedScreen()),
        coverUrl: topRatedCover,
      ),
      _CategoryItem(
        AppLocalizations.of(context)!.categoryGenres,
        Icons.library_music_rounded,
        [Colors.green, Colors.teal],
        () => NavigationHelper.push(context, const GenresScreen()),
        coverUrl: genresCover,
      ),
      _CategoryItem(
        AppLocalizations.of(context)!.categoryFavorites,
        Icons.favorite_rounded,
        [Colors.red, Colors.pink],
        () => NavigationHelper.push(context, const FavoritesScreen()),
        coverUrl: favoritesCover,
      ),
      if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux)
        _CategoryItem(
          AppLocalizations.of(context)!.categoryRadio,
          Icons.radio_rounded,
          [Colors.blue, Colors.indigo],
          () => NavigationHelper.push(context, const RadioScreen()),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: AppLocalizations.of(context)!.browseCategories),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.6,
            ),
            itemCount: categories.length,
            itemBuilder: (context, index) {
              final category = categories[index];
              return _CategoryCard(category: category);
            },
          ),
        ),
        const SizedBox(height: 150),
      ],
    );
  }

  Widget _buildAutocompleteOverlay(bool isDark) {
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      color: isDark ? AppTheme.darkCard : Colors.white,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 400),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark ? const Color(0xFF38383A) : const Color(0xFFE5E5EA),
            width: 1,
          ),
        ),
        child: _isLoadingSuggestions
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            : _autocompleteSuggestions == null ||
                  _autocompleteSuggestions!.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    AppLocalizations.of(context)!.noSuggestions,
                    style: TextStyle(
                      color: AppTheme.lightSecondaryText,
                      fontSize: 14,
                    ),
                  ),
                ),
              )
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_autocompleteSuggestions!.artists.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Text(
                          AppLocalizations.of(context)!.artists,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.lightSecondaryText,
                          ),
                        ),
                      ),
                      ..._autocompleteSuggestions!.artists.map(
                        (artist) => ListTile(
                          dense: true,
                          leading: Icon(
                            CupertinoIcons.person,
                            size: 20,
                            color: AppTheme.appleMusicRed,
                          ),
                          title: Text(
                            artist.name,
                            style: const TextStyle(fontSize: 14),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            setState(() => _showSuggestions = false);
                            NavigationHelper.push(
                              context,
                              ArtistScreen(artistId: artist.id),
                            );
                          },
                        ),
                      ),
                    ],
                    if (_autocompleteSuggestions!.albums.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Text(
                          AppLocalizations.of(context)!.albums,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.lightSecondaryText,
                          ),
                        ),
                      ),
                      ..._autocompleteSuggestions!.albums.map(
                        (album) => ListTile(
                          dense: true,
                          leading: Icon(
                            CupertinoIcons.music_albums,
                            size: 20,
                            color: AppTheme.appleMusicRed,
                          ),
                          title: Text(
                            album.name,
                            style: const TextStyle(fontSize: 14),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: album.artist != null
                              ? Text(
                                  album.artist!,
                                  style: const TextStyle(fontSize: 12),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                )
                              : null,
                          onTap: () {
                            setState(() => _showSuggestions = false);
                            NavigationHelper.push(
                              context,
                              AlbumScreen(albumId: album.id),
                            );
                          },
                        ),
                      ),
                    ],
                    if (_autocompleteSuggestions!.songs.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Text(
                          AppLocalizations.of(context)!.songs,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.lightSecondaryText,
                          ),
                        ),
                      ),
                      ..._autocompleteSuggestions!.songs.map(
                        (song) => ListTile(
                          dense: true,
                          leading: Icon(
                            CupertinoIcons.music_note,
                            size: 20,
                            color: AppTheme.appleMusicRed,
                          ),
                          title: Text(
                            song.title,
                            style: const TextStyle(fontSize: 14),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: song.artist != null
                              ? Text(
                                  song.artist!,
                                  style: const TextStyle(fontSize: 12),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                )
                              : null,
                          onTap: () {
                            setState(() => _showSuggestions = false);
                            final playerProvider = Provider.of<PlayerProvider>(
                              context,
                              listen: false,
                            );
                            playerProvider.playSong(
                              song,
                              playlist: _autocompleteSuggestions!.songs,
                              startIndex: _autocompleteSuggestions!.songs
                                  .indexOf(song),
                            );
                          },
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                  ],
                ),
              ),
      ),
    );
  }
}

class _CategoryItem {
  final String title;
  final IconData icon;
  final List<Color> colors;
  final VoidCallback onTap;
  final String? coverUrl;

  _CategoryItem(this.title, this.icon, this.colors, this.onTap, {this.coverUrl});
}

class _CategoryCard extends StatelessWidget {
  final _CategoryItem category;

  const _CategoryCard({required this.category});

  Widget _buildCover(String url) {
    // Локальный файл (isLocal) грузим через File, остальное — сеть.
    final isFile = url.startsWith('/') ||
        (url.length > 2 && url[1] == ':') ||
        url.startsWith('file://');
    if (isFile) {
      final path = url.startsWith('file://')
          ? Uri.parse(url).toFilePath()
          : url;
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(path),
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: url,
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => const SizedBox.shrink(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasCover =
        category.coverUrl != null && category.coverUrl!.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: category.colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: category.onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(category.icon, color: Colors.white, size: 24),
                      const Spacer(),
                      Text(
                        category.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // Обложка справа как в Navic: чуть повёрнута, текст ужался влево.
                // Нет обложки — выглядит как раньше (только иконка + текст).
                if (hasCover) ...[
                  const SizedBox(width: 8),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      const SizedBox(height: 8),
                      Transform.rotate(
                        angle: 0.12,
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.35),
                                blurRadius: 8,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: _buildCover(category.coverUrl!),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
