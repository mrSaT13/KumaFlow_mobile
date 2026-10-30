import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/subsonic_service.dart';
import '../services/yandex_music_api.dart';
import '../theme/app_theme.dart';

/// KION-style similar tracks bottom sheet.
/// Shows similar tracks from Yandex Music API.
class KionSimilarTracksSheet extends StatefulWidget {
  final Song currentSong;

  const KionSimilarTracksSheet({super.key, required this.currentSong});

  @override
  State<KionSimilarTracksSheet> createState() => _KionSimilarTracksSheetState();
}

class _KionSimilarTracksSheetState extends State<KionSimilarTracksSheet> {
  List<Map<String, dynamic>> _similarTracks = [];
  bool _isLoading = true;
  String? _error;
  String? _searchedTrackName;

  @override
  void initState() {
    super.initState();
    _loadSimilarContent();
  }

  Future<void> _loadSimilarContent() async {
    if (!mounted) return;
    setState(() { _isLoading = true; _error = null; });

    try {
      final yandexApi = Provider.of<YandexMusicApi>(context, listen: false);
      final song = widget.currentSong;

      // Search for the track on Yandex Music by name + artist
      final searchQuery = '${song.title} ${song.artist ?? ''}';
      final searchResults = await yandexApi.searchTracks(searchQuery, limit: 5);

      if (searchResults.isEmpty) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _error = 'Трек не найден в Яндекс Музыке';
          });
        }
        return;
      }

      // Find the best match
      Map<String, dynamic>? bestMatch;
      for (final track in searchResults) {
        final trackTitle = (track['title'] as String?)?.toLowerCase() ?? '';
        if (trackTitle.contains(song.title.toLowerCase()) ||
            song.title.toLowerCase().contains(trackTitle)) {
          bestMatch = track;
          break;
        }
      }
      bestMatch ??= searchResults.first;

      // Get similar tracks using Yandex track ID
      final trackId = bestMatch['id']?.toString() ?? '';
      if (trackId.isEmpty) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _error = 'Не удалось получить ID трека';
          });
        }
        return;
      }

      _searchedTrackName = bestMatch['title'] as String?;
      final similar = await yandexApi.getSimilarTracks(trackId, limit: 15);

      if (mounted) {
        setState(() {
          _similarTracks = similar;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Ошибка загрузки: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: AppTheme.darkSurface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 5,
                decoration: BoxDecoration(
                  color: AppTheme.darkDivider,
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
              const SizedBox(height: 16),
              // Header with current track info
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    Text(
                      'Похожие на',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.currentSong.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                    if (widget.currentSong.artist != null)
                      Text(
                        widget.currentSong.artist!,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _buildContent(scrollController),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildContent(ScrollController scrollController) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: Colors.white.withValues(alpha: 0.5), size: 48),
            const SizedBox(height: 16),
            Text(
              _error!,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadSimilarContent,
              child: const Text('Повторить'),
            ),
          ],
        ),
      );
    }

    if (_similarTracks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.music_off, color: Colors.white.withValues(alpha: 0.3), size: 48),
            const SizedBox(height: 16),
            Text(
              'Похожие треки не найдены',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      itemCount: _similarTracks.length,
      itemBuilder: (context, index) {
        final track = _similarTracks[index];
        return _SimilarTrackItem(
          track: track,
          onTap: () => _playTrack(track),
        );
      },
    );
  }

  void _playTrack(Map<String, dynamic> track) {
    // For now, show what was found
    final title = track['title'] as String? ?? 'Трек';
    final artist = _extractArtistName(track) ?? 'Артист';
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$title — $artist'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String? _extractArtistName(Map<String, dynamic> track) {
    final artists = track['artists'] as List?;
    if (artists != null && artists.isNotEmpty) {
      return (artists.first as Map<String, dynamic>?)?['name'] as String?;
    }
    return null;
  }
}

/// Single similar track item.
class _SimilarTrackItem extends StatelessWidget {
  final Map<String, dynamic> track;
  final VoidCallback onTap;

  const _SimilarTrackItem({
    required this.track,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final title = track['title'] as String? ?? 'Неизвестно';
    final artists = track['artists'] as List?;
    String artistName = 'Неизвестный артист';
    if (artists != null && artists.isNotEmpty) {
      final firstArtist = artists.first as Map<String, dynamic>?;
      artistName = firstArtist?['name'] as String? ?? 'Неизвестный артист';
    }

    // Extract cover URL from track
    String? coverUrl;
    final albums = track['albums'] as List?;
    if (albums != null && albums.isNotEmpty) {
      final firstAlbum = albums.first as Map<String, dynamic>?;
      final coverUri = firstAlbum?['coverUri'] as String?;
      if (coverUri != null) {
        coverUrl = 'https://avatars.yandex.net/$coverUri?size=100';
      }
    }

    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: coverUrl != null
            ? CachedNetworkImage(
                imageUrl: coverUrl,
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(
                  width: 44,
                  height: 44,
                  color: AppTheme.darkElevated,
                  child: const Icon(Icons.music_note, size: 20),
                ),
                errorWidget: (_, __, ___) => Container(
                  width: 44,
                  height: 44,
                  color: AppTheme.darkElevated,
                  child: const Icon(Icons.music_note, size: 20),
                ),
              )
            : Container(
                width: 44,
                height: 44,
                color: AppTheme.darkElevated,
                child: const Icon(Icons.music_note, size: 20),
              ),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
      subtitle: Text(
        artistName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: AppTheme.darkSecondaryText,
          fontSize: 12,
        ),
      ),
      trailing: IconButton(
        icon: const Icon(
          Icons.play_circle_outline,
          color: Colors.white70,
          size: 24,
        ),
        onPressed: onTap,
      ),
      onTap: onTap,
    );
  }
}
