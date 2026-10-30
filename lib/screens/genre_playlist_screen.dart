import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../widgets/app_gradient_background.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/subsonic_service.dart';
import '../services/theme_service.dart';

/// Screen displaying tracks from a specific genre.
///
/// Fetches 50-100 tracks from Yandex Music radio and displays them
/// in a scrollable list. Each time the screen is opened, different
/// tracks are shown (randomized by the radio endpoint).
class GenrePlaylistScreen extends StatefulWidget {
  final String genreId;
  final String genreName;
  final Color genreColor;

  const GenrePlaylistScreen({
    super.key,
    required this.genreId,
    required this.genreName,
    required this.genreColor,
  });

  @override
  State<GenrePlaylistScreen> createState() => _GenrePlaylistScreenState();
}

class _GenrePlaylistScreenState extends State<GenrePlaylistScreen> {
  List<Song> _matchedSongs = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTracks();
  }

  Future<void> _loadTracks() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final subsonic = Provider.of<SubsonicService>(context, listen: false);

      // Load tracks directly from Subsonic server by genre name
      final serverSongs = await subsonic.getSongsByGenre(
        widget.genreName,
        count: 75,
      );

      if (mounted) {
        setState(() {
          _matchedSongs = serverSongs;
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

  String _formatDuration(int? milliseconds) {
    if (milliseconds == null) return '';
    final duration = Duration(milliseconds: milliseconds);
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _playTrack(int index) {
    if (_matchedSongs.isEmpty || index >= _matchedSongs.length) return;
    HapticFeedback.mediumImpact();
    context.read<PlayerProvider>().playSong(
      _matchedSongs[index],
      playlist: _matchedSongs,
      startIndex: index,
    );
  }

  void _playAll() {
    if (_matchedSongs.isEmpty) return;
    context.read<PlayerProvider>().playSong(
      _matchedSongs.first,
      playlist: _matchedSongs,
      startIndex: 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(backgroundColor: Colors.transparent, 
      body: Stack(
        children: [
          // Gradient background
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    widget.genreColor.withValues(alpha: 0.15),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.4],
                ),
              ),
            ),
          ),
          // Content
          CustomScrollView(
            slivers: [
              // App Bar
              SliverAppBar(
                pinned: true,
                expandedHeight: 200,
                leading: IconButton(
                  icon: Icon(
                    Icons.arrow_back,
                    color: isDark ? Colors.white : Colors.black,
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
                flexibleSpace: FlexibleSpaceBar(
                  title: Text(
                    widget.genreName,
                    style: TextStyle(
                      color: isDark ? Colors.white : Colors.black,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Gradient overlay
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              widget.genreColor.withValues(alpha: 0.4),
                              widget.genreColor.withValues(alpha: 0.1),
                            ],
                          ),
                        ),
                      ),
                      // Wave pattern
                      CustomPaint(
                        painter: _WavePatternPainter(
                          color: Colors.white.withValues(alpha: 0.1),
                        ),
                      ),
                      // Track count
                      Positioned(
                        bottom: 60,
                        left: 16,
                        child: Text(
                          _isLoading
                              ? 'Загрузка...'
                              : '${_matchedSongs.length} треков',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  // Play all button
                  if (_matchedSongs.isNotEmpty)
                    IconButton(
                      icon: Icon(
                        Icons.play_circle_filled,
                        color: widget.genreColor,
                        size: 32,
                      ),
                      onPressed: _playAll,
                    ),
                  // Refresh button
                  IconButton(
                    icon: Icon(
                      Icons.refresh,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                    onPressed: _loadTracks,
                  ),
                ],
              ),
              // Track list
              if (_isLoading)
                const SliverFillRemaining(
                  child: Center(
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_error != null)
                SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 64,
                          color: Colors.red,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Ошибка загрузки',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _error!,
                          style: TextStyle(
                            color: isDark ? Colors.white54 : Colors.black54,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _loadTracks,
                          child: const Text('Повторить'),
                        ),
                      ],
                    ),
                  ),
                )
              else if (_matchedSongs.isEmpty)
                SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.music_off,
                          size: 64,
                          color: Colors.grey,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Треки не найдены',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final song = _matchedSongs[index];
                      return _buildTrackTile(song, index, isDark);
                    },
                    childCount: _matchedSongs.length,
                  ),
                ),
              // Bottom padding
              const SliverToBoxAdapter(
                child: SizedBox(height: 100),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTrackTile(Song song, int index, bool isDark) {
    final title = song.title;
    final artist = song.artist ?? 'Unknown';
    final duration = song.duration != null
        ? _formatDuration(song.duration! * 1000)
        : '';

    String? coverUrl;
    if (song.coverArt != null) {
      final subsonic = Provider.of<SubsonicService>(context, listen: false);
      coverUrl = subsonic.getCoverArtUrl(song.coverArt!, size: 300);
    }

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Track number
          SizedBox(
            width: 32,
            child: Text(
              '${index + 1}',
              style: TextStyle(
                color: isDark ? Colors.white54 : Colors.black54,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 8),
          // Cover art
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              width: 48,
              height: 48,
              child: coverUrl != null
                  ? CachedNetworkImage(
                      imageUrl: coverUrl,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                        color: widget.genreColor.withValues(alpha: 0.2),
                        child: Icon(
                          Icons.music_note,
                          color: widget.genreColor,
                        ),
                      ),
                      errorWidget: (_, __, ___) => Container(
                        color: widget.genreColor.withValues(alpha: 0.2),
                        child: Icon(
                          Icons.music_note,
                          color: widget.genreColor,
                        ),
                      ),
                    )
                  : Container(
                      color: widget.genreColor.withValues(alpha: 0.2),
                      child: Icon(
                        Icons.music_note,
                        color: widget.genreColor,
                      ),
                    ),
            ),
          ),
        ],
      ),
      title: Text(
        title,
        style: TextStyle(
          color: isDark ? Colors.white : Colors.black,
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        artist,
        style: TextStyle(
          color: isDark ? Colors.white54 : Colors.black54,
          fontSize: 12,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (duration.isNotEmpty)
            Text(
              duration,
              style: TextStyle(
                color: isDark ? Colors.white54 : Colors.black54,
                fontSize: 12,
              ),
            ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(
              Icons.play_circle_outline,
              color: widget.genreColor,
            ),
            onPressed: () => _playTrack(index),
          ),
        ],
      ),
      onTap: () => _playTrack(index),
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
    final waveHeight = size.height * 0.05;
    final waveWidth = size.width * 0.15;

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
