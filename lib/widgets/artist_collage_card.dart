import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/library_provider.dart';
import '../services/subsonic_service.dart';
import '../services/playlist_orchestrator.dart';
import '../theme/app_theme.dart';

/// Artist Collage Card - карточка артиста с коллажем из 4-6 обложек альбомов
/// Порт с десктопной версии (artist-collage-card.tsx)
class ArtistCollageCard extends StatefulWidget {
  final String artistName;
  final String? artistId;
  final VoidCallback? onTap;

  const ArtistCollageCard({
    super.key,
    required this.artistName,
    this.artistId,
    this.onTap,
  });

  @override
  State<ArtistCollageCard> createState() => _ArtistCollageCardState();
}

class _ArtistCollageCardState extends State<ArtistCollageCard> {
  List<String> _albumCovers = [];
  bool _isLoading = true;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _loadAlbumCovers();
  }

  Future<void> _loadAlbumCovers() async {
    try {
      final subsonicService = Provider.of<SubsonicService>(context, listen: false);
      
      // Search for artist's albums
      final results = await subsonicService.search(
        widget.artistName,
        artistCount: 0,
        albumCount: 6,
        songCount: 0,
      );

      final covers = <String>[];
      for (final album in results.albums) {
        if (album.coverArt != null) {
          covers.add(subsonicService.getCoverArtUrl(album.coverArt!, size: 300));
        }
      }

      if (mounted) {
        setState(() {
          _albumCovers = covers;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _playArtistRadio() async {
    if (_isPlaying) return;
    setState(() => _isPlaying = true);

    try {
      final subsonicService = Provider.of<SubsonicService>(context, listen: false);
      final provider = context.read<PlayerProvider>();

      // Search for artist's songs
      final artistResults = await subsonicService.search(
        widget.artistName,
        artistCount: 0,
        albumCount: 0,
        songCount: 25,
      );

      final allSongs = <Song>[];
      allSongs.addAll(artistResults.songs);

      // Try to find similar songs by genre
      if (artistResults.songs.isNotEmpty) {
        final firstSong = artistResults.songs.first;
        if (firstSong.genre != null) {
          try {
            final genreResults = await subsonicService.search(
              firstSong.genre!,
              artistCount: 0,
              albumCount: 0,
              songCount: 15,
            );
            // Add songs from similar genre, excluding current artist
            for (final song in genreResults.songs) {
              if (song.artist != widget.artistName && !allSongs.any((s) => s.id == song.id)) {
                allSongs.add(song);
              }
            }
          } catch (_) {}
        }
      }

      if (allSongs.isNotEmpty) {
        // Use orchestrator for smooth transitions
        final shuffled = PlaylistOrchestrator.orchestrate(
          allSongs,
          startWith: 'energetic',
          endWith: 'mixed',
        );
        provider.playSong(
          shuffled.first,
          playlist: shuffled,
          startIndex: 0,
        );
      }
    } catch (e) {
      debugPrint('Error playing artist radio: $e');
    } finally {
      if (mounted) setState(() => _isPlaying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF282828),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: widget.onTap ?? _playArtistRadio,
      child: Column(
        children: [
          // Circular artist image — enlarged per request (было 100 → стало 120)
          SizedBox(
            width: 120,
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Circular image
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF282828),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _albumCovers.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: _albumCovers.first,
                          fit: BoxFit.cover,
                          fadeInDuration: Duration.zero,
                          fadeOutDuration: Duration.zero,
                          errorWidget: (_, __, ___) => _buildPlaceholderCircle(),
                        )
                      : _buildPlaceholderCircle(),
                ),
                // Transparent play button overlay
                if (!_isPlaying)
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.3),
                    ),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white.withValues(alpha: 0.9),
                      size: 42,
                    ),
                  )
                else
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.5),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(28),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Artist name
          SizedBox(
            width: 120,
            child: Text(
              widget.artistName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholderCircle() {
    return Container(
      color: const Color(0xFF282828),
      child: Center(
        child: Text(
          widget.artistName.isNotEmpty ? widget.artistName[0].toUpperCase() : '?',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 38,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
