import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'dart:math' as math;
import '../models/genre.dart';
import '../providers/library_provider.dart';
import '../theme/app_theme.dart';

/// Genre carousel widget that displays genres as gradient cards.
///
/// Fetches genres from Subsonic server via LibraryProvider and displays them
/// in a horizontal scrollable carousel with gradient backgrounds.
class GenreCarousel extends StatefulWidget {
  final double hPad;
  final bool isDesktop;
  final Function(String genreId, String genreName, Color color)? onGenreTap;

  const GenreCarousel({
    super.key,
    this.hPad = 16.0,
    this.isDesktop = false,
    this.onGenreTap,
  });

  @override
  State<GenreCarousel> createState() => _GenreCarouselState();
}

class _GenreCarouselState extends State<GenreCarousel> {
  List<Genre> _genres = [];
  bool _isLoading = true;
  String? _error;
  // genre (lowercase) -> up to 2 cover art URLs, Navic-style card collage
  Map<String, List<String>> _coverUrls = {};

  // Genre color mapping (keyed by English genre name from Subsonic)
  static const Map<String, Color> _genreColors = {
    'rock': Color(0xFF3779BC),
    'pop': Color(0xFFFF6665),
    'metal': Color(0xFF9D65A9),
    'alternative': Color(0xFFC44F69),
    'indie': Color(0xFF3779BC),
    'electronic': Color(0xFF6C65A9),
    'dance': Color(0xFFE4BA0F),
    'hip-hop': Color(0xFF59CD9C),
    'hip hop': Color(0xFF59CD9C),
    'rap': Color(0xFF59CD9C),
    'jazz': Color(0xFFE3208F),
    'blues': Color(0xFFA5C94B),
    'reggae': Color(0xFFFF9344),
    'ska': Color(0xFFC44F69),
    'punk': Color(0xFFC44F69),
    'folk': Color(0xFFFD9060),
    'country': Color(0xFFFF9344),
    'classical': Color(0xFF6FC3E0),
    'r&b': Color(0xFFA5C94B),
    'soul': Color(0xFFA5C94B),
    'soundtrack': Color(0xFFFF6665),
    'relax': Color(0xFF6FC3E0),
    'ambient': Color(0xFF6FC3E0),
  };

  @override
  void initState() {
    super.initState();
    _loadGenres();
  }

  Future<void> _loadGenres() async {
    try {
      final libraryProvider = Provider.of<LibraryProvider>(context, listen: false);
      await libraryProvider.loadGenres();

      if (mounted) {
        var all = libraryProvider.richGenres;
        // избранные жанры вместо рандомных — приоритет жанрам из лайкнутых/частых треков
        final starredGenres = libraryProvider.starred?.songs.map((s) => s.genre?.toLowerCase()).whereType<String>().toSet() ?? {};
        // Было: скан 80к cachedAllSongs. Стало: GROUP BY в SQL.
        final freq = <String,int>{};
        try {
          final stats = await libraryProvider.getGenreStats();
          for (final row in stats) {
            final g = (row['genre'] as String?)?.toLowerCase();
            if (g != null && g.isNotEmpty) freq[g] = (row['cnt'] as int?) ?? 0;
          }
        } catch (_) {
          for (final s in libraryProvider.cachedAllSongs.take(5000)) {
            final g = s.genre?.toLowerCase();
            if (g != null && g.isNotEmpty) freq[g] = (freq[g]??0)+1;
          }
        }
        all.sort((a,b){
          final aFav = starredGenres.contains(a.value.toLowerCase()) ? 0 : 1;
          final bFav = starredGenres.contains(b.value.toLowerCase()) ? 0 : 1;
          if (aFav != bFav) return aFav.compareTo(bFav);
          final aCnt = freq[a.value.toLowerCase()] ?? a.songCount;
          final bCnt = freq[b.value.toLowerCase()] ?? b.songCount;
          return bCnt.compareTo(aCnt);
        });
        // показываем избранные/топ, остальные после — но не рандом
        // Covers for cards: 1 обложка на жанр из GROUP BY (вместо скана 80к)
        final coverMap = <String, List<String>>{};
        try {
          final stats = await libraryProvider.getGenreStats();
          for (final row in stats) {
            final g = (row['genre'] as String?)?.toLowerCase();
            final ca = row['cover'] as String?;
            if (g == null || g.isEmpty || ca == null || ca.isEmpty) continue;
            coverMap.putIfAbsent(g, () => [ca]);
          }
          if (coverMap.isEmpty) throw StateError('empty');
        } catch (_) {
          try {
            for (final s in libraryProvider.cachedAllSongs.take(5000)) {
              final g = s.genre?.toLowerCase();
              final ca = s.coverArt;
              if (g == null || g.isEmpty || ca == null || ca.isEmpty) continue;
              final list = coverMap.putIfAbsent(g, () => []);
              if (list.length < 2 && !list.contains(ca)) list.add(ca);
            }
          } catch (_) {}
        }
        try {
          final svc = libraryProvider.subsonicService;
          _coverUrls = {
            for (final e in coverMap.entries)
              e.key: e.value.map((id) => svc.getCoverArtUrl(id, size: 200)).toList(),
          };
        } catch (_) {}
        setState(() {
          _genres = all;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Color _getGenreColor(String genreName) {
    final lower = genreName.toLowerCase();

    // Try exact match first
    if (_genreColors.containsKey(lower)) {
      return _genreColors[lower]!;
    }

    // Try partial match
    for (final entry in _genreColors.entries) {
      if (lower.contains(entry.key) || entry.key.contains(lower)) {
        return entry.value;
      }
    }

    // Default color based on hash
    final hash = genreName.hashCode;
    final colors = _genreColors.values.toList();
    return colors[hash.abs() % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_isLoading) {
      return _buildLoading(isDark);
    }

    if (_error != null || _genres.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: widget.hPad),
          child: Text(
            'Жанры',
            style: TextStyle(
              fontSize: widget.isDesktop ? 22 : 20,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : Colors.black,
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: widget.isDesktop ? 120 : 100,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: widget.hPad),
            itemCount: _genres.length,
            itemBuilder: (context, index) {
              final genre = _genres[index];
              return _buildGenreCard(genre, isDark);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildGenreCard(Genre genre, bool isDark) {
    final genreName = genre.value;
    final color = _getGenreColor(genreName);
    final covers = _coverUrls[genreName.toLowerCase()] ?? const <String>[];

    return GestureDetector(
      onTap: () => widget.onGenreTap?.call(genreName, genreName, color),
      child: Container(
        width: widget.isDesktop ? 140 : 120,
        margin: const EdgeInsets.only(right: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              color,
              color.withValues(alpha: 0.7),
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.3),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: [
              // Wave pattern overlay
              Positioned.fill(
                child: CustomPaint(
                  painter: _WavePatternPainter(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
              ),
              // Navic-style rotated covers peeking from the right edge
              if (covers.isNotEmpty)
                Positioned(
                  right: -18,
                  top: 8,
                  child: SizedBox(
                    width: 76,
                    height: 84,
                    child: Stack(
                      children: [
                        if (covers.length > 1)
                          Positioned(
                            right: 0,
                            top: 6,
                            child: Transform.rotate(
                              angle: 0.42,
                              child: _coverThumb(covers[1], 56),
                            ),
                          ),
                        Positioned(
                          right: covers.length > 1 ? 22 : 8,
                          top: 0,
                          child: Transform.rotate(
                            angle: 0.18,
                            child: _coverThumb(covers[0], 60),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              // Genre name + track count
              Positioned(
                bottom: 12,
                left: 12,
                right: covers.isNotEmpty ? 66 : 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      genreName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        shadows: [
                          Shadow(
                            color: Colors.black26,
                            blurRadius: 4,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (genre.songCount > 0)
                      Text(
                        '${genre.songCount} треков',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 11,
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

  Widget _coverThumb(String url, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => Container(color: Colors.white24),
        ),
      ),
    );
  }

  Widget _buildLoading(bool isDark) {
    return SizedBox(
      height: widget.isDesktop ? 120 : 100,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: widget.hPad),
        itemCount: 6,
        itemBuilder: (context, index) {
          return Container(
            width: widget.isDesktop ? 140 : 120,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: isDark ? AppTheme.darkCard : Colors.grey[200],
            ),
          );
        },
      ),
    );
  }
}

/// Custom painter for wave pattern overlay.
class _WavePatternPainter extends CustomPainter {
  final Color color;

  _WavePatternPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final path = Path();
    final waveHeight = size.height * 0.1;
    final waveWidth = size.width * 0.2;

    for (double y = 0; y < size.height; y += waveHeight * 2) {
      path.moveTo(0, y);
      for (double x = 0; x < size.width; x += waveWidth) {
        path.quadraticBezierTo(
          x + waveWidth / 2,
          y - waveHeight,
          x + waveWidth,
          y,
        );
      }
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
