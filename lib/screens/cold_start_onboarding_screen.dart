import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../widgets/app_gradient_background.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/artist.dart';
import '../models/genre.dart';
import '../models/song.dart';
import '../providers/library_provider.dart';
import '../services/subsonic_service.dart';
import '../services/theme_service.dart';
import '../services/ml_service.dart';
import '../services/bpm_analyzer_service.dart';
import '../theme/app_theme.dart';

/// Multi-step ML cold-start onboarding: pick genres → pick artists (with
/// similar-artist suggestions) → load favorites → train ML profile.
/// Redesign: circular genre/artist grids, accent button, gradient, server search.
class ColdStartOnboardingScreen extends StatefulWidget {
  const ColdStartOnboardingScreen({super.key});

  @override
  State<ColdStartOnboardingScreen> createState() =>
      _ColdStartOnboardingScreenState();
}

class _ColdStartOnboardingScreenState extends State<ColdStartOnboardingScreen>
    with SingleTickerProviderStateMixin {
  final _pageController = PageController();
  int _page = 0;

  final TextEditingController _genreSearch = TextEditingController();
  final TextEditingController _artistSearch = TextEditingController();

  final _selectedGenres = <String>[];
  final _selectedArtists = <String, double>{}; // artistId -> weight
  Set<String> _genreCandidates = {};

  bool _loading = false;
  bool _training = false;
  bool _finishing = false;
  String? _error;

  List<Artist> _allArtists = [];
  List<Song> _genreSongs = [];
  List<Song> _likedSongsCache = [];
  // Server-side artist search results (global search, merged into the grid).
  List<Artist> _serverArtists = [];
  bool _searchingArtists = false;
  Timer? _artistSearchTimer;

  // expand similar artists under tapped artist
  String? _expandedArtistId;
  final Map<String, List<Artist>> _similarCache = {};
  final Map<String, String?> _artistFallbackCover = {};

  late SubsonicService _subsonic;
  late MLService _ml;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => context.select<ThemeService, Color>((t) => t.accentColor.color);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
    _genreSearch.addListener(() => setState(() {}));
    _artistSearch.addListener(_onArtistQueryChanged);
  }

  /// Local filter updates instantly; server (global) search is debounced.
  void _onArtistQueryChanged() {
    if (mounted) setState(() {});
    _artistSearchTimer?.cancel();
    final q = _artistSearch.text.trim();
    if (q.length < 2) {
      if (mounted && _serverArtists.isNotEmpty) {
        setState(() => _serverArtists = []);
      }
      return;
    }
    _artistSearchTimer =
        Timer(const Duration(milliseconds: 450), () => _searchArtistsServer(q));
  }

  /// Global artist search on the server (Navidrome search3 / Jellyfin),
  /// merged with the local list so anyone can be found.
  Future<void> _searchArtistsServer(String q) async {
    if (!mounted || _artistSearch.text.trim() != q) return;
    setState(() => _searchingArtists = true);
    try {
      final libraryProvider =
          Provider.of<LibraryProvider>(context, listen: false);
      final res = await libraryProvider.searchArtistsGlobal(q);
      if (!mounted || _artistSearch.text.trim() != q) return;
      setState(() {
        _serverArtists = res;
        _searchingArtists = false;
      });
    } catch (_) {
      if (mounted) setState(() => _searchingArtists = false);
    }
  }

  Future<void> _loadData() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    _subsonic = Provider.of<SubsonicService>(context, listen: false);
    _ml = Provider.of<MLService>(context, listen: false);

    final libraryProvider =
        Provider.of<LibraryProvider>(context, listen: false);
    if (!libraryProvider.isInitialized) {
      libraryProvider.initialize().catchError((e) {
        debugPrint('Library init failed during cold start: $e');
      });
    }

    List<Genre> genres = [];
    List<Artist> artists = [];
    List<Song> likedSongs = [];
    var artistsFailed = false;
    var genresFailed = false;
    try {
      final genresFuture = _subsonic.getGenres();
      final artistsFuture = _subsonic.getArtists();
      final starredFuture = _subsonic.getStarred();
      try {
        genres = await genresFuture;
      } catch (e) {
        genresFailed = true;
        debugPrint('Cold start getGenres failed: $e');
      }
      try {
        artists = await artistsFuture;
      } catch (e) {
        artistsFailed = true;
        debugPrint('Cold start getArtists failed: $e');
      }
      try {
        likedSongs = (await starredFuture).songs;
      } catch (e) {
        debugPrint('Cold start getStarred failed: $e');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }

    // Fallback: reuse artists already cached by a previous library sync
    // instead of showing an empty step.
    if (artists.isEmpty) {
      try {
        final cached = libraryProvider.artists;
        if (cached.isNotEmpty) {
          artists = cached;
          artistsFailed = false;
        }
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _genreCandidates = genres.map((g) => g.value).toSet();
      _allArtists = artists;
      _likedSongsCache = likedSongs;
      for (final s in likedSongs) {
        final aid = s.artistId;
        if (aid != null && aid.isNotEmpty) {
          _selectedArtists[aid] = 1.0;
        }
      }
      if (artists.isEmpty && artistsFailed) {
        _error = 'Не удалось загрузить артистов с сервера. '
            'Проверь соединение и нажми «Повторить».';
      } else if (genres.isEmpty && genresFailed) {
        _error = 'Не удалось загрузить жанры с сервера. '
            'Проверь соединение и нажми «Повторить».';
      } else {
        _error = null;
      }
      _loading = false;
    });
    // preload fallback covers for artists without coverArt
    _preloadFallbackCovers();
  }

  void _preloadFallbackCovers() {
    // Map artistId -> coverArt from likedSongs or genreSongs later
    for (final a in _allArtists) {
      if (a.coverArt == null) {
        final match = _likedSongsCache.firstWhere(
          (s) => s.artistId == a.id && s.coverArt != null,
          orElse: () => Song(id: '', title: '', artist: '', artistId: '', coverArt: null, duration: 0),
        );
        if (match.coverArt != null) {
          _artistFallbackCover[a.id] = match.coverArt;
        }
      }
    }
  }

  List<String> get _filteredGenres {
    final q = _genreSearch.text.trim().toLowerCase();
    final list = _genreCandidates.toList()..sort();
    if (q.isEmpty) return list;
    // серверный поиск: фильтруем на клиенте, но также показываем индикатор
    return list.where((g) => g.toLowerCase().contains(q)).toList();
  }

  List<Artist> get _genreArtists {
    final q = _artistSearch.text.trim().toLowerCase();
    var artists = _allArtists;
    if (_selectedGenres.isNotEmpty && _genreSongs.isNotEmpty) {
      final ids = _genreSongs
          .where((s) => _selectedGenres.contains(s.genre))
          .map((s) => s.artistId ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      if (ids.isNotEmpty) {
        final filtered = artists.where((a) => ids.contains(a.id)).toList();
        // also include liked artists even if not in genre
        final likedIds = _selectedArtists.keys.toSet();
        final extra = artists.where((a) => likedIds.contains(a.id) && !ids.contains(a.id)).toList();
        artists = [...filtered, ...extra];
        // if filtered empty, fallback to all
        if (filtered.isEmpty) artists = _allArtists;
      }
    }
    if (q.isNotEmpty) {
      artists = artists.where((a) => a.name.toLowerCase().contains(q)).toList();
    }
    // Merge global server hits missing from the local getArtists() list.
    if (q.isNotEmpty && _serverArtists.isNotEmpty) {
      final ids = artists.map((a) => a.id).toSet();
      final extra =
          _serverArtists.where((a) => !ids.contains(a.id)).toList();
      if (extra.isNotEmpty) {
        artists = [...artists, ...extra];
      }
    }
    // sort: selected first, then alphabetically
    artists.sort((a, b) {
      final sa = _selectedArtists.containsKey(a.id) ? 0 : 1;
      final sb = _selectedArtists.containsKey(b.id) ? 0 : 1;
      if (sa != sb) return sa.compareTo(sb);
      return a.name.compareTo(b.name);
    });
    return artists;
  }

  Future<void> _onGenresNext() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait(
        _selectedGenres.map((genre) async {
          try {
            return await _subsonic.getSongsByGenre(genre, count: 60);
          } catch (e) {
            debugPrint('Genre "$genre" fetch failed: $e');
            return <Song>[];
          }
        }),
      );
      if (mounted) {
        setState(() {
          _genreSongs = results.expand((l) => l).toList();
          // update fallback covers
          for (final s in _genreSongs) {
            final aid = s.artistId;
            if (aid != null && s.coverArt != null && !_artistFallbackCover.containsKey(aid)) {
              final artist = _allArtists.firstWhere((a) => a.id == aid, orElse: () => Artist(id: '', name: ''));
              if (artist.coverArt == null) _artistFallbackCover[aid] = s.coverArt;
            }
          }
        });
      }
      if (!mounted) return;
      _animateToPage(1);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _onArtistNext() async {
    setState(() => _training = true);
    try {
      final starredSearch = await _subsonic.getStarred();
      final likedIds = starredSearch.songs.map((s) => s.id).toList();

      // Names for bandit arms (id -> display name).
      final artistNames = <String, String>{};
      for (final a in _allArtists) {
        if (_selectedArtists.containsKey(a.id)) {
          artistNames[a.id] = a.name;
        }
      }

      await _ml.seedTaste(
        genres: _selectedGenres.toSet(),
        artistWeights: _selectedArtists,
        likedSongs: likedIds,
        artistNames: artistNames,
      );

      final bpm = BpmAnalyzerService();
      bpm.cacheAllBPM(_genreSongs).catchError((e) {
        debugPrint('BPM pre-analysis failed: $e');
      });

      if (mounted) _animateToPage(2);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _training = false);
    }
  }

  void _animateToPage(int page) {
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _artistSearchTimer?.cancel();
    _pageController.dispose();
    _genreSearch.dispose();
    _artistSearch.dispose();
    super.dispose();
  }

  // ── Genre visual mapping ──────────────────────────────────────────
  ({Color color, IconData icon}) _genreVisual(String genre) {
    final lower = genre.toLowerCase();
    // explicit mapping for known Russian/English genres
    if (lower.contains('поп') || lower == 'pop') {
      return (color: const Color(0xFFFF3B30), icon: Icons.album_rounded);
    }
    if (lower.contains('рок-н-ролл') || lower.contains('rock-n-roll')) {
      return (color: const Color(0xFF007AFF), icon: Icons.music_note_rounded);
    }
    if (lower.contains('хард-рок') || lower.contains('hard-rock') || lower.contains('хард рок')) {
      return (color: const Color(0xFF0A84FF), icon: CupertinoIcons.guitars);
    }
    if ((lower.contains('рок') && !lower.contains('рэп')) || lower.contains('rock')) {
      // progressive, folk etc fallback to blue
      if (lower.contains('прогрес')) return (color: const Color(0xFF007AFF), icon: Icons.queue_music_rounded);
      if (lower.contains('фолк')) return (color: const Color(0xFF5AC8FA), icon: Icons.music_note_rounded);
      return (color: const Color(0xFF007AFF), icon: CupertinoIcons.guitars);
    }
    if (lower.contains('рэп') || lower.contains('rap') || lower.contains('хип') || lower.contains('hip')) {
      return (color: const Color(0xFF34C759), icon: Icons.mic_rounded);
    }
    if (lower.contains('метал') || lower.contains('metal')) {
      return (color: const Color(0xFF8E8E93), icon: Icons.bolt_rounded);
    }
    if (lower.contains('электрон') || lower.contains('electronic')) {
      return (color: const Color(0xFFAF52DE), icon: Icons.bolt_rounded);
    }
    if (lower.contains('танцевальн') || lower.contains('dance')) {
      return (color: const Color(0xFF5856D6), icon: Icons.campaign_rounded);
    }
    if (lower.contains('альтернатив') || lower.contains('alternative')) {
      return (color: const Color(0xFFFF2D55), icon: Icons.star_rounded);
    }
    if (lower.contains('панк') || lower.contains('punk')) {
      return (color: const Color(0xFFFF9500), icon: Icons.warning_rounded);
    }
    if (lower.contains('хардкор') || lower.contains('hardcore')) {
      return (color: const Color(0xFFFF3B30), icon: Icons.local_fire_department_rounded);
    }
    if (lower.contains('фолк') || lower.contains('folk')) {
      return (color: const Color(0xFF5AC8FA), icon: Icons.music_note_rounded);
    }
    // fallback hash to palette
    final palette = [
      (color: const Color(0xFFFF3B30), icon: Icons.album_rounded),
      (color: const Color(0xFF007AFF), icon: Icons.queue_music_rounded),
      (color: const Color(0xFF34C759), icon: Icons.mic_rounded),
      (color: const Color(0xFF5856D6), icon: Icons.campaign_rounded),
      (color: const Color(0xFFAF52DE), icon: Icons.bolt_rounded),
      (color: const Color(0xFFFF9500), icon: Icons.local_fire_department_rounded),
      (color: const Color(0xFFFF2D55), icon: Icons.star_rounded),
      (color: const Color(0xFF5AC8FA), icon: Icons.music_note_rounded),
    ];
    final idx = genre.hashCode.abs() % palette.length;
    return palette[idx];
  }

  String? _artistImageUrl(Artist artist) {
    if (artist.coverArt != null) return _subsonic.getCoverArtUrl(artist.coverArt, size: 300);
    final fallback = _artistFallbackCover[artist.id];
    if (fallback != null) return _subsonic.getCoverArtUrl(fallback, size: 300);
    // try find in genreSongs
    final match = _genreSongs.firstWhere(
      (s) => s.artistId == artist.id && s.coverArt != null,
      orElse: () => Song(id: '', title: '', artist: '', artistId: '', coverArt: null, duration: 0),
    );
    if (match.coverArt != null) return _subsonic.getCoverArtUrl(match.coverArt, size: 300);
    if (artist.artistImageUrl != null) return artist.artistImageUrl;
    return null;
  }

  Future<List<Artist>> _fetchSimilarArtists(Artist artist) async {
    if (_similarCache.containsKey(artist.id)) return _similarCache[artist.id]!;
    List<Artist> similar = [];
    // try genre-based similar first (fast, local)
    final mySongs = _genreSongs.where((s) => s.artistId == artist.id).toList();
    final myGenres = mySongs.map((s) => s.genre).whereType<String>().toSet();
    if (myGenres.isNotEmpty) {
      similar = _allArtists
          .where((a) => a.id != artist.id && !_selectedArtists.containsKey(a.id))
          .where((a) {
        final aGenres = _genreSongs.where((s) => s.artistId == a.id).map((s) => s.genre);
        return aGenres.any(myGenres.contains);
      }).take(6).toList();
    }
    // supplement with server search via similar songs if still few
    if (similar.length < 3 && mySongs.isNotEmpty) {
      try {
        final topSongId = mySongs.first.id;
        if (topSongId.isNotEmpty) {
          final simSongs = await _subsonic.getSimilarSongs(topSongId, count: 20).timeout(const Duration(seconds: 6), onTimeout: () => <Song>[]);
          final simArtistIds = simSongs.map((s) => s.artistId).whereType<String>().toSet();
          final extra = _allArtists.where((a) => simArtistIds.contains(a.id) && a.id != artist.id && !similar.any((s) => s.id == a.id)).take(3 - similar.length).toList();
          similar = [...similar, ...extra];
        }
      } catch (_) {}
    }
    // fallback: random if still empty
    if (similar.isEmpty) {
      similar = (_allArtists.where((a) => a.id != artist.id).toList()..shuffle()).take(3).toList();
    }
    _similarCache[artist.id] = similar.take(3).toList();
    return _similarCache[artist.id]!;
  }

  void _toggleArtist(Artist artist) async {
    final wasSelected = _selectedArtists.containsKey(artist.id);
    setState(() {
      if (wasSelected) {
        _selectedArtists.remove(artist.id);
        if (_expandedArtistId == artist.id) _expandedArtistId = null;
      } else {
        _selectedArtists[artist.id] = 1.0;
        _expandedArtistId = artist.id;
      }
    });
    if (!wasSelected) {
      final sim = await _fetchSimilarArtists(artist);
      if (mounted) setState(() => _similarCache[artist.id] = sim);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accent;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppGradientBackground(
        child: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  _buildTopBar(accent),
                  Expanded(
                    child: _loading && _genreCandidates.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 42,
                                  height: 42,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    color: accent,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  'Загружаем жанры…',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: _isDark ? Colors.white : Colors.black87,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : PageView(
                            controller: _pageController,
                            physics: const NeverScrollableScrollPhysics(),
                            onPageChanged: (i) => setState(() => _page = i),
                            children: [
                              _buildGenreStep(),
                              _buildArtistStep(),
                              _buildDoneStep(accent),
                            ],
                          ),
                  ),
                  _buildBottomBar(accent),
                ],
              ),
              if (_loading && _page == 0 && _genreCandidates.isNotEmpty)
                Positioned.fill(
                  child: ClipRect(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: ColoredBox(
                        color: (_isDark ? AppTheme.darkBackground : Colors.white).withValues(alpha: 0.88),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 42,
                                height: 42,
                                child: CircularProgressIndicator(strokeWidth: 3, color: accent),
                              ),
                              const SizedBox(height: 20),
                              Text(
                                'Загружаем песни твоих жанров…',
                                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _isDark ? Colors.white : Colors.black87),
                              ),
                              const SizedBox(height: 6),
                              Text('Это может занять несколько секунд',
                                  style: TextStyle(fontSize: 13, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(Color accent) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Настрой свой вкус', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(_pageTitle(),
                    style: TextStyle(fontSize: 13, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
              ],
            ),
          ),
          _stepDots(accent),
        ],
      ),
    );
  }

  String _pageTitle() {
    switch (_page) {
      case 0:
        return 'Шаг 1 из 3 — Жанры';
      case 1:
        return 'Шаг 2 из 3 — Артисты';
      default:
        return 'Шаг 3 из 3 — Готово';
    }
  }

  Widget _stepDots(Color accent) {
    return Row(
      children: List.generate(3, (i) {
        final active = i == _page;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.only(left: 6),
          width: active ? 22 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: active ? accent : (_isDark ? AppTheme.darkDivider : AppTheme.lightDivider),
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }

  // ─── Step 0: Genres – circular grid ───────────────────────────────
  Widget _buildGenreStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _searchField(_genreSearch, hint: 'Поиск жанра… (с сервера)', onChanged: (_) => setState(() {})),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: Text(
            'Выбрано: ${_selectedGenres.length} · Коснись кружков с любимыми жанрами',
            style: TextStyle(fontSize: 12, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText),
          ),
        ),
        Expanded(
          child: _filteredGenres.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _error ?? 'Жанры не найдены',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: _isDark
                                  ? AppTheme.darkSecondaryText
                                  : AppTheme.lightSecondaryText),
                        ),
                        if (_genreCandidates.isEmpty) ...[
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _loading ? null : _loadData,
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Повторить'),
                          ),
                        ],
                      ],
                    ),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.82,
                  ),
                  itemCount: _filteredGenres.length,
                  itemBuilder: (context, index) {
                    final genre = _filteredGenres[index];
                    return _genreCircle(genre, _selectedGenres.contains(genre));
                  },
                ),
        ),
      ],
    );
  }

  Widget _genreCircle(String genre, bool selected) {
    final visual = _genreVisual(genre);
    final accent = _accent;
    return GestureDetector(
      onTap: () {
        setState(() {
          if (selected) {
            _selectedGenres.remove(genre);
          } else {
            _selectedGenres.add(genre);
          }
        });
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: visual.color,
                  border: Border.all(
                    color: selected ? Colors.white : Colors.transparent,
                    width: selected ? 3 : 0,
                  ),
                  boxShadow: selected
                      ? [BoxShadow(color: visual.color.withValues(alpha: 0.45), blurRadius: 14, spreadRadius: 1)]
                      : [BoxShadow(color: Colors.black.withValues(alpha: _isDark ? 0.35 : 0.12), blurRadius: 10, offset: const Offset(0, 4))],
                ),
                child: Icon(visual.icon, size: 36, color: Colors.white),
              ),
              if (selected)
                Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.18),
                  ),
                  child: const Icon(Icons.check_rounded, color: Colors.white, size: 32),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 34,
            child: Text(
              genre,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                height: 1.1,
                color: selected ? accent : (_isDark ? Colors.white : Colors.black87),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Step 1: Artists – circular grid with expand similar ──────────
  Widget _buildArtistStep() {
    final artists = _genreArtists;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _searchField(_artistSearch, hint: 'Поиск артиста…', onChanged: (_) => setState(() {})),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: Text(
            'Выбрано артистов: ${_selectedArtists.length} · Нажми на кружок чтобы лайкнуть ♥${_searchingArtists ? ' · Ищем на сервере…' : ''}',
            style: TextStyle(fontSize: 12, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText),
          ),
        ),
        Expanded(
          child: artists.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _allArtists.isEmpty
                              ? (_error ?? 'Артисты не найдены')
                              : 'Артисты не найдены',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: _isDark
                                  ? AppTheme.darkSecondaryText
                                  : AppTheme.lightSecondaryText),
                        ),
                        // No data at all (not just a query miss) — offer retry.
                        if (_allArtists.isEmpty) ...[
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _loading ? null : _loadData,
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Повторить'),
                          ),
                        ],
                      ],
                    ),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 100),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.78,
                  ),
                  itemCount: artists.length,
                  itemBuilder: (context, index) {
                    final artist = artists[index];
                    return _artistCircle(artist);
                  },
                ),
        ),
      ],
    );
  }

  Widget _artistCircle(Artist artist) {
    final selected = _selectedArtists.containsKey(artist.id);
    final isExpanded = _expandedArtistId == artist.id && selected;
    final imageUrl = _artistImageUrl(artist);
    final accent = _accent;
    final similar = _similarCache[artist.id] ?? [];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => _toggleArtist(artist),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFFFE066),
                  border: Border.all(color: selected ? accent : Colors.transparent, width: selected ? 3 : 0),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: _isDark ? 0.35 : 0.15), blurRadius: 10, offset: const Offset(0, 4)),
                    if (selected) BoxShadow(color: accent.withValues(alpha: 0.35), blurRadius: 12, spreadRadius: 1),
                  ],
                ),
                child: ClipOval(
                  child: imageUrl != null
                      ? CachedNetworkImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => Container(color: const Color(0xFFFFE066), child: const Icon(Icons.person_rounded, color: Colors.white70, size: 36)),
                          errorWidget: (_, __, ___) => Container(color: const Color(0xFFFFE066), child: const Icon(CupertinoIcons.heart_fill, color: Color(0xFFFF3B30), size: 30)),
                        )
                      : Container(color: const Color(0xFFFFE066), child: const Icon(CupertinoIcons.heart_fill, color: Color(0xFFFF3B30), size: 30)),
                ),
              ),
              // heart badge when not selected shows placeholder heart, when selected shows filled heart on top
              if (!selected || imageUrl == null)
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFFFFE066).withValues(alpha: imageUrl != null ? 0.0 : 1.0)),
                  child: Center(
                    child: Icon(CupertinoIcons.heart_fill, color: const Color(0xFFFF3B30).withValues(alpha: 0.95), size: 28),
                  ),
                ),
              // selected indicator
              if (selected)
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: accent, border: Border.all(color: _isDark ? const Color(0xFF121212) : Colors.white, width: 2)),
                    child: const Icon(Icons.check_rounded, size: 16, color: Colors.white),
                  ),
                ),
              // small heart when image present and not yet liked
              if (!selected && imageUrl != null)
                Positioned(
                  bottom: 2,
                  right: 2,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white, boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 4)]),
                    child: const Icon(CupertinoIcons.heart, size: 14, color: Color(0xFFFF3B30)),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 30,
          child: Text(
            artist.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, height: 1.1, color: selected ? accent : (_isDark ? Colors.white : Colors.black87)),
          ),
        ),
        // similar artists expansion
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          child: isExpanded && similar.isNotEmpty
              ? Container(
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  decoration: BoxDecoration(
                    color: (_isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.04)),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: accent.withValues(alpha: 0.18)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: similar.map((s) {
                      final simUrl = _artistImageUrl(s);
                      final simSelected = _selectedArtists.containsKey(s.id);
                      return Expanded(
                        child: GestureDetector(
                          onTap: () => _toggleArtist(s),
                          child: Column(
                            children: [
                              Container(
                                width: 42,
                                height: 42,
                                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: simSelected ? accent : Colors.white24, width: simSelected ? 2 : 1)),
                                child: ClipOval(
                                  child: simUrl != null
                                      ? CachedNetworkImage(imageUrl: simUrl, fit: BoxFit.cover, errorWidget: (_, __, ___) => Container(color: accent.withValues(alpha: 0.2), child: Text(s.name[0], textAlign: TextAlign.center, style: TextStyle(color: accent, fontSize: 14))))
                                      : Container(color: accent.withValues(alpha: 0.2), child: Center(child: Text(s.name.isNotEmpty ? s.name[0] : '?', style: TextStyle(color: accent)))),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(s.name.split(' ').first, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: TextStyle(fontSize: 8, fontWeight: FontWeight.w600, color: simSelected ? accent : (_isDark ? Colors.white70 : Colors.black54))),
                              if (!simSelected) const Icon(Icons.add_circle, size: 10, color: Color(0xFFFF3B30)),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  // ─── Step 2: Done ────────────────────────────────────────────────
  Widget _buildDoneStep(Color accent) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(shape: BoxShape.circle, color: accent.withValues(alpha: 0.15), border: Border.all(color: accent, width: 3)),
              child: Icon(Icons.auto_awesome_rounded, size: 44, color: accent),
            ),
            const SizedBox(height: 24),
            const Text('Профиль обучен!', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text(
              'Мы запомнили твои жанры и артистов. '
              'Миксы станут персональными с каждым прослушиванием.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, height: 1.4, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _finishing ? null : _finishOnboarding,
              icon: _finishing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.play_arrow_rounded),
              label: Text(_finishing ? 'Загружаем…' : 'Начать слушать'),
              style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.white, minimumSize: const Size(220, 52)),
            ),
          ],
        ),
      ),
    );
  }

  void _finishOnboarding() async {
    setState(() => _finishing = true);
    try {
      await _ml.markColdStartDone();
    } finally {
      if (mounted) setState(() => _finishing = false);
    }
  }

  Widget _searchField(TextEditingController controller, {required String hint, required ValueChanged<String> onChanged}) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: TextStyle(fontSize: 15, color: _isDark ? Colors.white : Colors.black87),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: _isDark ? Colors.white38 : Colors.black38, fontSize: 14),
        isDense: true,
        prefixIcon: Icon(Icons.search_rounded, size: 20, color: _isDark ? Colors.white54 : Colors.black45),
        filled: true,
        fillColor: _isDark ? AppTheme.darkCard : Colors.white,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _isDark ? Colors.white12 : Colors.black12)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _accent, width: 1.4)),
      ),
    );
  }

  Widget _buildBottomBar(Color accent) {
    final canNext = _page == 0 ? _selectedGenres.isNotEmpty : _page == 1 ? _selectedArtists.isNotEmpty : true;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      decoration: BoxDecoration(
        color: (_isDark ? AppTheme.darkBackground : Colors.white).withValues(alpha: 0.92),
        border: Border(top: BorderSide(color: _isDark ? AppTheme.darkDivider : AppTheme.lightDivider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _page > 0
                ? TextButton(onPressed: () => _animateToPage(_page - 1), child: const Text('Назад'))
                : const SizedBox.shrink(),
          ),
          if (_page < 2)
            FilledButton.icon(
              onPressed: (canNext && !_loading && !_training)
                  ? () {
                      if (_page == 0) {
                        _onGenresNext();
                      } else if (_page == 1) {
                        _onArtistNext();
                      }
                    }
                  : null,
              icon: (_loading || _training)
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(_page == 0 ? Icons.arrow_forward_rounded : Icons.auto_awesome_rounded),
              label: Text(_page == 0 ? 'Далее' : 'Обучить'),
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
                disabledBackgroundColor: accent.withValues(alpha: 0.35),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
        ],
      ),
    );
  }
}
