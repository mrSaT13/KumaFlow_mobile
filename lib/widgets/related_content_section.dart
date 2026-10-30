import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/yandex_music_provider.dart';
import '../services/yandex_music_service.dart';
import '../theme/app_theme.dart';
import '../screens/album_screen.dart';
import '../screens/artist_screen.dart';

/// Section showing related albums from Yandex Music.
///
/// Displays albums that are similar to the current artist/album,
/// fetched from Yandex Music API and matched with local library.
class RelatedAlbumsSection extends StatefulWidget {
  final String artistName;
  final List<Album> localAlbums;
  final double hPad;

  const RelatedAlbumsSection({
    super.key,
    required this.artistName,
    required this.localAlbums,
    this.hPad = 16,
  });

  @override
  State<RelatedAlbumsSection> createState() => _RelatedAlbumsSectionState();
}

class _RelatedAlbumsSectionState extends State<RelatedAlbumsSection> {
  List<RelatedAlbumMatch> _matches = [];
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRelatedAlbums();
  }

  Future<void> _loadRelatedAlbums() async {
    if (widget.artistName.isEmpty) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final provider = Provider.of<YandexMusicProvider>(context, listen: false);
      final matches = await provider.getRelatedAlbums(
        artistName: widget.artistName,
        localAlbums: widget.localAlbums,
        limit: 10,
      );

      if (mounted) {
        setState(() {
          _matches = matches;
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

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return _buildLoading();
    }

    if (_error != null) {
      return const SizedBox.shrink();
    }

    if (_matches.isEmpty) {
      return const SizedBox.shrink();
    }

    return _buildContent();
  }

  Widget _buildLoading() {
    return SizedBox(
      height: 220,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppTheme.appleMusicRed.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Поиск похожих альбомов...',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(widget.hPad, 4, widget.hPad, 8),
          child: Row(
            children: [
              Icon(
                Icons.explore_rounded,
                size: 20,
                color: AppTheme.appleMusicRed,
              ),
              const SizedBox(width: 8),
              Text(
                'Похожие альбомы',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black,
                  letterSpacing: -0.3,
                ),
              ),
              const Spacer(),
              Text(
                'из Yandex Music',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white38 : Colors.black38,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 220,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: widget.hPad),
            itemCount: _matches.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final match = _matches[index];
              return _RelatedAlbumCard(
                match: match,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AlbumScreen(
                        albumId: match.localAlbum.id,
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RelatedAlbumCard extends StatelessWidget {
  final RelatedAlbumMatch match;
  final VoidCallback onTap;

  const _RelatedAlbumCard({
    required this.match,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final yandexCover = match.yandexAlbum.getMediumCoverUrl();
    final localCover = match.localAlbum.coverArt;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 150,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _buildCover(yandexCover, localCover),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              match.localAlbum.name,
              style: TextStyle(
                color: isDark ? Colors.white : Colors.black,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              match.localAlbum.artist ?? '',
              style: TextStyle(
                color: isDark ? Colors.white60 : Colors.black54,
                fontSize: 11,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (match.confidence > 0.7) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.appleMusicRed.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Точное совпадение',
                  style: TextStyle(
                    fontSize: 9,
                    color: AppTheme.appleMusicRed,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCover(String? yandexUrl, String? localCoverArt) {
    // Prefer Yandex Music cover for better quality
    if (yandexUrl != null) {
      return CachedNetworkImage(
        imageUrl: yandexUrl,
        fit: BoxFit.cover,
        placeholder: (_, __) => Container(
          color: const Color(0xFF282828),
          child: const Center(
            child: Icon(
              Icons.album_rounded,
              color: Colors.white38,
              size: 48,
            ),
          ),
        ),
        errorWidget: (_, __, ___) {
          // Fallback to local cover
          if (localCoverArt != null) {
            return CachedNetworkImage(
              imageUrl: localCoverArt,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => _buildPlaceholder(),
            );
          }
          return _buildPlaceholder();
        },
      );
    }

    // Use local cover art
    if (localCoverArt != null) {
      return CachedNetworkImage(
        imageUrl: localCoverArt,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => _buildPlaceholder(),
      );
    }

    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      color: const Color(0xFF282828),
      child: const Center(
        child: Icon(
          Icons.album_rounded,
          color: Colors.white38,
          size: 48,
        ),
      ),
    );
  }
}

/// Section showing related artists from Yandex Music.
class RelatedArtistsSection extends StatefulWidget {
  final String artistName;
  final List<Artist> localArtists;
  final double hPad;

  const RelatedArtistsSection({
    super.key,
    required this.artistName,
    required this.localArtists,
    this.hPad = 16,
  });

  @override
  State<RelatedArtistsSection> createState() => _RelatedArtistsSectionState();
}

class _RelatedArtistsSectionState extends State<RelatedArtistsSection> {
  List<RelatedArtistMatch> _matches = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadRelatedArtists();
  }

  Future<void> _loadRelatedArtists() async {
    if (widget.artistName.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      final provider = Provider.of<YandexMusicProvider>(context, listen: false);
      final matches = await provider.getRelatedArtists(
        artistName: widget.artistName,
        localArtists: widget.localArtists,
        limit: 10,
      );

      if (mounted) {
        setState(() {
          _matches = matches;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _matches.isEmpty) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(widget.hPad, 4, widget.hPad, 8),
          child: Row(
            children: [
              Icon(
                Icons.people_rounded,
                size: 20,
                color: AppTheme.appleMusicRed,
              ),
              const SizedBox(width: 8),
              Text(
                'Похожие исполнители',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black,
                  letterSpacing: -0.3,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 140,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: widget.hPad),
            itemCount: _matches.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final match = _matches[index];
              return _RelatedArtistCard(
                match: match,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ArtistScreen(
                        artistId: match.localArtist.id,
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RelatedArtistCard extends StatelessWidget {
  final RelatedArtistMatch match;
  final VoidCallback onTap;

  const _RelatedArtistCard({
    required this.match,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final yandexCover = match.yandexArtist.getMediumCoverUrl();
    final localCover = match.localArtist.coverArt;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 100,
        child: Column(
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipOval(
                child: _buildAvatar(yandexCover, localCover),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              match.localArtist.name,
              style: TextStyle(
                color: isDark ? Colors.white : Colors.black,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar(String? yandexUrl, String? localCoverArt) {
    if (yandexUrl != null) {
      return CachedNetworkImage(
        imageUrl: yandexUrl,
        fit: BoxFit.cover,
        placeholder: (_, __) => _buildPlaceholder(),
        errorWidget: (_, __, ___) {
          if (localCoverArt != null) {
            return CachedNetworkImage(
              imageUrl: localCoverArt,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => _buildPlaceholder(),
            );
          }
          return _buildPlaceholder();
        },
      );
    }

    if (localCoverArt != null) {
      return CachedNetworkImage(
        imageUrl: localCoverArt,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => _buildPlaceholder(),
      );
    }

    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      color: const Color(0xFF282828),
      child: const Center(
        child: Icon(
          Icons.person,
          color: Colors.white38,
          size: 40,
        ),
      ),
    );
  }
}
