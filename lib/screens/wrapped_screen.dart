import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../widgets/app_gradient_background.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/models.dart';
import '../providers/library_provider.dart';
import '../services/subsonic_service.dart';
import '../services/theme_service.dart';

class WrappedEntry {
  final String artist;
  final String? artistId;
  final int playCount;
  final String? coverArt;
  final List<String> topTracks;

  const WrappedEntry({
    required this.artist,
    this.artistId,
    required this.playCount,
    this.coverArt,
    this.topTracks = const [],
  });
}

class WrappedTrack {
  final Song song;
  final int playCount;

  const WrappedTrack(this.song, this.playCount);
}

class WrappedYearStats {
  final int year;
  final List<WrappedEntry> topArtists;
  final List<WrappedTrack> topTracks;
  final List<MapEntry<String, int>> topGenres;
  final int totalListeningSeconds;
  final int uniqueTrackCount;
  final int totalPlayCount;
  final String mostActiveDay;
  final String mostActiveMonth;

  const WrappedYearStats({
    required this.year,
    required this.topArtists,
    required this.topTracks,
    required this.topGenres,
    required this.totalListeningSeconds,
    required this.uniqueTrackCount,
    required this.totalPlayCount,
    required this.mostActiveDay,
    required this.mostActiveMonth,
  });

  String get formattedListeningTime {
    final hours = totalListeningSeconds ~/ 3600;
    final minutes = (totalListeningSeconds % 3600) ~/ 60;
    if (hours > 0) return '$hours h $minutes min';
    return '$minutes min';
  }

  String get formattedListeningTimeDays {
    final days = totalListeningSeconds ~/ 86400;
    final hours = (totalListeningSeconds % 86400) ~/ 3600;
    if (days > 0) return '$days d $hours h';
    return '$hours h';
  }
}

class WrappedScreen extends StatefulWidget {
  const WrappedScreen({super.key});

  @override
  State<WrappedScreen> createState() => _WrappedScreenState();
}

class _WrappedScreenState extends State<WrappedScreen> {
  bool _isLoading = true;
  WrappedYearStats? _stats;
  int _currentPage = 0;
  final PageController _pageController = PageController();
  Color _dominantColor = const Color(0xFF1DB954);
  final Map<String, Color> _artistColors = {};
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadStats() async {
    setState(() => _isLoading = true);
    try {
      final library = context.read<LibraryProvider>();
      final allSongs = library.randomSongs;
      final subsonic = context.read<SubsonicService>();

      if (allSongs.isEmpty) {
        setState(() {
          _isLoading = false;
          _stats = _emptyStats(DateTime.now().year);
        });
        return;
      }

      final stats = _computeStats(allSongs, subsonic);
      _stats = stats;

      if (stats.topArtists.isNotEmpty) {
        await _extractDominantColors(stats.topArtists, subsonic);
      }
    } catch (e) {
      debugPrint('[Wrapped] Error loading stats: $e');
      _stats = _emptyStats(DateTime.now().year);
    }
    if (mounted) setState(() => _isLoading = false);
  }

  WrappedYearStats _emptyStats(int year) {
    return WrappedYearStats(
      year: year,
      topArtists: const [],
      topTracks: const [],
      topGenres: const [],
      totalListeningSeconds: 0,
      uniqueTrackCount: 0,
      totalPlayCount: 0,
      mostActiveDay: 'N/A',
      mostActiveMonth: 'N/A',
    );
  }

  WrappedYearStats _computeStats(List<Song> songs, SubsonicService subsonic) {
    final now = DateTime.now();
    final year = now.year;
    final yearSongs = songs;

    // Top artists
    final artistCounts = <String, int>{};
    final artistTracks = <String, List<String>>{};
    final artistIds = <String, String?>{};
    final artistCovers = <String, String?>{};

    for (final song in yearSongs) {
      final artist = song.artist ?? 'Unknown';
      artistCounts[artist] = (artistCounts[artist] ?? 0) + 1;
      artistIds[artist] = song.artistId;
      artistCovers[artist] = song.coverArt;
      artistTracks.putIfAbsent(artist, () => []).add(song.title);
    }

    final sortedArtists = artistCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final topArtists = sortedArtists.take(5).map((e) {
      final tracks = artistTracks[e.key] ?? [];
      return WrappedEntry(
        artist: e.key,
        artistId: artistIds[e.key],
        playCount: e.value,
        coverArt: artistCovers[e.key],
        topTracks: tracks.take(3).toList(),
      );
    }).toList();

    // Top tracks
    final trackCounts = <String, MapEntry<Song, int>>{};
    for (final song in yearSongs) {
      final key = song.id;
      if (trackCounts.containsKey(key)) {
        final prev = trackCounts[key]!;
        trackCounts[key] = MapEntry(prev.key, prev.value + 1);
      } else {
        trackCounts[key] = MapEntry(song, 1);
      }
    }

    final sortedTracks = trackCounts.values.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final topTracks =
        sortedTracks.take(10).map((e) => WrappedTrack(e.key, e.value)).toList();

    // Top genres
    final genreCounts = <String, int>{};
    for (final song in yearSongs) {
      final genre = song.genre ?? 'Other';
      genreCounts[genre] = (genreCounts[genre] ?? 0) + 1;
    }
    final sortedGenres = genreCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topGenres = sortedGenres.take(5).toList();

    // Total listening time
    int totalSeconds = 0;
    for (final song in yearSongs) {
      totalSeconds += song.duration ?? 240;
    }
    final totalListening = totalSeconds;

    // Unique tracks
    final uniqueIds = <String>{};
    for (final song in yearSongs) {
      uniqueIds.add(song.id);
    }

    // Most active day/month (simulated from created dates)
    final dayCounts = <int, int>{};
    final monthCounts = <int, int>{};
    final weekdayNames = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday'
    ];
    final monthNames = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];

    for (final song in yearSongs) {
      if (song.created != null) {
        final dt = song.created!;
        final weekday = dt.weekday - 1;
        dayCounts[weekday] = (dayCounts[weekday] ?? 0) + 1;
        final month = dt.month - 1;
        monthCounts[month] = (monthCounts[month] ?? 0) + 1;
      }
    }

    String mostActiveDay = 'N/A';
    String mostActiveMonth = 'N/A';

    if (dayCounts.isNotEmpty) {
      final topDay = dayCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      mostActiveDay = weekdayNames[topDay.first.key];
    }

    if (monthCounts.isNotEmpty) {
      final topMonth = monthCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      mostActiveMonth = monthNames[topMonth.first.key];
    }

    return WrappedYearStats(
      year: year,
      topArtists: topArtists,
      topTracks: topTracks,
      topGenres: topGenres,
      totalListeningSeconds: totalListening,
      uniqueTrackCount: uniqueIds.length,
      totalPlayCount: yearSongs.length,
      mostActiveDay: mostActiveDay,
      mostActiveMonth: mostActiveMonth,
    );
  }

  Future<void> _extractDominantColors(
    List<WrappedEntry> artists,
    SubsonicService subsonic,
  ) async {
    for (final artist in artists) {
      if (artist.coverArt != null) {
        final url = subsonic.getCoverArtUrl(artist.coverArt, size: 100);
        if (url.isNotEmpty) {
          try {
            final palette = await _extractColorFromNetwork(url);
            if (palette != null && mounted) {
              setState(() => _artistColors[artist.artist] = palette);
            }
          } catch (_) {}
        }
      }
    }
    if (mounted && _artistColors.isNotEmpty) {
      final firstColor = _artistColors.values.first;
      setState(() => _dominantColor = firstColor);
    }
  }

  Future<Color?> _extractColorFromNetwork(String url) async {
    try {
      final provider = CachedNetworkImageProvider(url);
      final imageStream = provider.resolve(const ImageConfiguration());
      final completer = <Color?>[null];

      imageStream.addListener(ImageStreamListener((info, _) {
        completer[0] = const Color(0xFF1DB954);
      }));

      await Future.delayed(const Duration(seconds: 2));
      return completer[0];
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(seconds: 2),
                builder: (context, value, child) {
                  return Opacity(
                    opacity: value,
                    child: Transform.scale(
                      scale: 0.8 + value * 0.2,
                      child: child,
                    ),
                  );
                },
                child: const Icon(Icons.equalizer_rounded,
                    size: 80, color: Color(0xFF1DB954)),
              ),
              const SizedBox(height: 24),
              Text(
                'KumaFlow',
                style: TextStyle(
                  color: Colors.white.withAlpha(200),
                  fontSize: 16,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: 200,
                child: LinearProgressIndicator(
                  backgroundColor: Colors.white12,
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(Color(0xFF1DB954)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: _stats == null || (_stats!.totalPlayCount == 0)
          ? _buildEmptyState()
          : _buildWrappedBody(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.music_off_rounded,
              size: 64, color: Colors.white.withAlpha(60)),
          const SizedBox(height: 16),
          Text(
            'No listening data yet',
            style: TextStyle(
              color: Colors.white.withAlpha(180),
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Start listening to see your Wrapped!',
            style: TextStyle(
              color: Colors.white.withAlpha(100),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 24),
          TextButton.icon(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_rounded),
            label: const Text('Go back'),
            style: TextButton.styleFrom(foregroundColor: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _buildWrappedBody() {
    final pages = <Widget Function()>[
      () => _buildIntroPage(),
      () => _buildTopArtistsPage(),
      () => _buildTopTracksPage(),
      () => _buildGenresPage(),
      () => _buildStatsPage(),
      () => _buildSummaryPage(),
    ];

    return Stack(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 800),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                _dominantColor.withAlpha(40),
                Colors.black,
                _dominantColor.withAlpha(20),
              ],
            ),
          ),
        ),
        Column(
          children: [
            SafeArea(
              bottom: false,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.white70),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Text(
                      '${_stats!.year} Wrapped',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: pages.length,
                onPageChanged: (index) {
                  setState(() {
                    _currentPage = index;
                    if (_currentPage < pages.length &&
                        _stats!.topArtists.isNotEmpty) {
                      final artistIndex = min(_currentPage, _stats!.topArtists.length - 1);
                      final color = _artistColors[_stats!.topArtists[artistIndex].artist];
                      if (color != null) _dominantColor = color;
                    }
                  });
                },
                itemBuilder: (context, index) => pages[index](),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32)
                  .copyWith(bottom: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  pages.length,
                  (i) => AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _currentPage ? 24 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _currentPage
                          ? Colors.white
                          : Colors.white.withAlpha(60),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // Page 0: Intro
  Widget _buildIntroPage() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 1200),
              builder: (context, value, child) {
                return Opacity(
                  opacity: value,
                  child: Transform.translate(
                    offset: Offset(0, 30 * (1 - value)),
                    child: child,
                  ),
                );
              },
              child: Text(
                '${_stats!.year}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 72,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
            ),
            const SizedBox(height: 16),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 1200),
              builder: (context, value, child) {
                return Opacity(
                  opacity: value,
                  child: Transform.translate(
                    offset: Offset(0, 20 * (1 - value)),
                    child: child,
                  ),
                );
              },
              child: Text(
                'Your KumaFlow Wrapped',
                style: TextStyle(
                  color: Colors.white.withAlpha(200),
                  fontSize: 20,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 2,
                ),
              ),
            ),
            const SizedBox(height: 48),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 1200),
              builder: (context, value, child) {
                return Opacity(
                  opacity: value,
                  child: child,
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: _dominantColor.withAlpha(30),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: _dominantColor.withAlpha(80),
                  ),
                ),
                child: Text(
                  '${_stats!.totalPlayCount} songs played',
                  style: TextStyle(
                    color: _dominantColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 48),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 1200),
              builder: (context, value, child) {
                return Opacity(
                  opacity: value.clamp(0.0, 1.0),
                  child: child,
                );
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.arrow_upward_rounded,
                      color: Colors.white.withAlpha(80), size: 16),
                  const SizedBox(width: 8),
                  Text(
                    'Swipe up to explore',
                    style: TextStyle(
                      color: Colors.white.withAlpha(80),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Page 1: Top Artists
  Widget _buildTopArtistsPage() {
    final artists = _stats!.topArtists;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          const Text(
            'TOP ARTISTS',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Your most played artists of ${_stats!.year}',
            style: TextStyle(
              color: Colors.white.withAlpha(140),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: ListView.builder(
              itemCount: artists.length,
              itemBuilder: (context, index) {
                final artist = artists[index];
                final color = _artistColors[artist.artist] ?? _dominantColor;
                return TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: Duration(milliseconds: 600 + index * 150),
                  builder: (context, value, child) {
                    return Opacity(
                      opacity: value,
                      child: Transform.translate(
                        offset: Offset(0, 30 * (1 - value)),
                        child: child,
                      ),
                    );
                  },
                  child: _buildArtistCard(artist, index + 1, color),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArtistCard(WrappedEntry artist, int rank, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: rank == 1 ? color.withAlpha(100) : Colors.white.withAlpha(15),
        ),
      ),
      child: Row(
        children: [
          Text(
            '$rank',
            style: TextStyle(
              color: rank == 1 ? color : Colors.white.withAlpha(120),
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 56,
              height: 56,
              child: artist.coverArt != null
                  ? Builder(builder: (context) {
                      final url = context
                          .read<SubsonicService>()
                          .getCoverArtUrl(artist.coverArt, size: 120);
                      return url.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: url,
                              fit: BoxFit.cover,
                              placeholder: (_, __) => Container(
                                color: Colors.white.withAlpha(15),
                                child: Icon(Icons.person,
                                    color: Colors.white.withAlpha(40)),
                              ),
                              errorWidget: (_, __, ___) => Container(
                                color: Colors.white.withAlpha(15),
                                child: Icon(Icons.person,
                                    color: Colors.white.withAlpha(40)),
                              ),
                            )
                          : Container(
                              color: Colors.white.withAlpha(15),
                              child: Icon(Icons.person,
                                  color: Colors.white.withAlpha(40)),
                            );
                    })
                  : Container(
                      color: Colors.white.withAlpha(15),
                      child: Icon(Icons.person,
                          color: Colors.white.withAlpha(40)),
                    ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  artist.artist,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '${artist.playCount} plays',
                  style: TextStyle(
                    color: Colors.white.withAlpha(140),
                    fontSize: 13,
                  ),
                ),
                if (artist.topTracks.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${artist.topTracks.first}',
                    style: TextStyle(
                      color: color.withAlpha(180),
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (rank == 1)
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: color.withAlpha(30),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '★',
                style: TextStyle(color: color, fontSize: 14),
              ),
            ),
        ],
      ),
    );
  }

  // Page 2: Top Tracks
  Widget _buildTopTracksPage() {
    final tracks = _stats!.topTracks;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          const Text(
            'TOP TRACKS',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Your most played tracks of ${_stats!.year}',
            style: TextStyle(
              color: Colors.white.withAlpha(140),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: ListView.builder(
              itemCount: tracks.length,
              itemBuilder: (context, index) {
                final track = tracks[index];
                return TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: Duration(milliseconds: 500 + index * 100),
                  builder: (context, value, child) {
                    return Opacity(
                      opacity: value,
                      child: Transform.translate(
                        offset: Offset(0, 20 * (1 - value)),
                        child: child,
                      ),
                    );
                  },
                  child: _buildTrackItem(track, index + 1),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackItem(WrappedTrack track, int rank) {
    final isTop3 = rank <= 3;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isTop3 ? _dominantColor.withAlpha(15) : Colors.white.withAlpha(5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Text(
              '$rank',
              style: TextStyle(
                color: isTop3
                    ? _dominantColor
                    : Colors.white.withAlpha(100),
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 44,
              height: 44,
              child: track.song.coverArt != null
                  ? Builder(builder: (context) {
                      final url = context
                          .read<SubsonicService>()
                          .getCoverArtUrl(track.song.coverArt, size: 96);
                      return url.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: url,
                              fit: BoxFit.cover,
                              placeholder: (_, __) => _miniPlaceholder(),
                              errorWidget: (_, __, ___) => _miniPlaceholder(),
                            )
                          : _miniPlaceholder();
                    })
                  : _miniPlaceholder(),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.song.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  track.song.artist ?? 'Unknown',
                  style: TextStyle(
                    color: Colors.white.withAlpha(120),
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Text(
            '${track.playCount}×',
            style: TextStyle(
              color: Colors.white.withAlpha(120),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniPlaceholder() {
    return Container(
      color: Colors.white.withAlpha(10),
      child: Icon(Icons.music_note,
          size: 18, color: Colors.white.withAlpha(30)),
    );
  }

  // Page 3: Genres
  Widget _buildGenresPage() {
    final genres = _stats!.topGenres;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          const Text(
            'TOP GENRES',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'What you listened to most',
            style: TextStyle(
              color: Colors.white.withAlpha(140),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 32),
          Expanded(
            child: genres.isEmpty
                ? Center(
                    child: Text(
                      'No genre data available',
                      style: TextStyle(
                          color: Colors.white.withAlpha(100), fontSize: 14),
                    ),
                  )
                : Column(
                    children: [
                      for (int i = 0; i < genres.length; i++)
                        _buildGenreBar(genres[i], i, genres.first.value.toString()),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildGenreBar(
      MapEntry<String, int> genre, int index, String topGenre) {
    final maxCount = _stats!.topGenres.first.value;
    final fraction = maxCount > 0 ? genre.value / maxCount : 0.0;
    final colors = [
      _dominantColor,
      const Color(0xFFE91E63),
      const Color(0xFF9C27B0),
      const Color(0xFF2196F3),
      const Color(0xFFFF9800),
    ];
    final color = colors[index % colors.length];

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: fraction),
      duration: Duration(milliseconds: 800 + index * 200),
      builder: (context, value, child) {
        return Opacity(
          opacity: (value > 0 ? 1 : 0).toDouble(),
          child: child,
        );
      },
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  genre.key,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${genre.value} plays',
                  style: TextStyle(
                    color: Colors.white.withAlpha(140),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: Duration(milliseconds: 1000 + index * 200),
                builder: (context, animVal, child) {
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      return Stack(
                        children: [
                          Container(
                            width: constraints.maxWidth,
                            height: 10,
                            color: Colors.white.withAlpha(15),
                          ),
                          Container(
                            width: constraints.maxWidth * fraction * animVal,
                            height: 10,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  color.withAlpha(180),
                                  color,
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Page 4: Stats
  Widget _buildStatsPage() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          const Text(
            'YOUR STATS',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'The full picture of your ${_stats!.year}',
            style: TextStyle(
              color: Colors.white.withAlpha(140),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 32),
          Expanded(
            child: GridView.count(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.2,
              children: [
                _buildStatCard(
                  icon: Icons.access_time_rounded,
                  label: 'Listening Time',
                  value: _stats!.formattedListeningTime,
                  color: const Color(0xFFE91E63),
                ),
                _buildStatCard(
                  icon: Icons.queue_music_rounded,
                  label: 'Songs Played',
                  value: '${_stats!.totalPlayCount}',
                  color: const Color(0xFF9C27B0),
                ),
                _buildStatCard(
                  icon: Icons.fiber_new_rounded,
                  label: 'Unique Tracks',
                  value: '${_stats!.uniqueTrackCount}',
                  color: const Color(0xFF2196F3),
                ),
                _buildStatCard(
                  icon: Icons.person_rounded,
                  label: 'Top Artists',
                  value: '${_stats!.topArtists.length}',
                  color: const Color(0xFFFF9800),
                ),
                _buildStatCard(
                  icon: Icons.calendar_today_rounded,
                  label: 'Most Active Day',
                  value: _stats!.mostActiveDay,
                  color: _dominantColor,
                ),
                _buildStatCard(
                  icon: Icons.date_range_rounded,
                  label: 'Most Active Month',
                  value: _stats!.mostActiveMonth,
                  color: const Color(0xFF00BCD4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withAlpha(15),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withAlpha(40)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withAlpha(120),
              fontSize: 11,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // Page 5: Summary
  Widget _buildSummaryPage() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 1200),
              builder: (context, value, child) {
                return Opacity(
                  opacity: value,
                  child: Transform.scale(
                    scale: 0.8 + value * 0.2,
                    child: child,
                  ),
                );
              },
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      _dominantColor,
                      _dominantColor.withAlpha(150),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: _dominantColor.withAlpha(60),
                      blurRadius: 40,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.equalizer_rounded,
                  size: 56,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              'Your year in music',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${_stats!.year}',
              style: TextStyle(
                color: _dominantColor,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 32),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(8),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  _summaryStat(
                    '${_stats!.totalPlayCount}',
                    'songs played',
                  ),
                  const SizedBox(height: 12),
                  _summaryStat(
                    _stats!.formattedListeningTime,
                    'listening time',
                  ),
                  const SizedBox(height: 12),
                  _summaryStat(
                    '${_stats!.uniqueTrackCount}',
                    'unique tracks',
                  ),
                  if (_stats!.topArtists.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Divider(color: Colors.white.withAlpha(20)),
                    const SizedBox(height: 16),
                    Text(
                      'Your #1 artist',
                      style: TextStyle(
                        color: Colors.white.withAlpha(100),
                        fontSize: 12,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _stats!.topArtists.first.artist,
                      style: TextStyle(
                        color: _dominantColor,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_stats!.topArtists.first.playCount} plays',
                      style: TextStyle(
                        color: Colors.white.withAlpha(140),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 32),
            Text(
              'Made with KumaFlow',
              style: TextStyle(
                color: Colors.white.withAlpha(60),
                fontSize: 12,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryStat(String value, String label) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withAlpha(120),
            fontSize: 14,
          ),
        ),
      ],
    );
  }
}
