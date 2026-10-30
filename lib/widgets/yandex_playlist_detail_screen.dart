import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/models.dart';
import '../providers/player_provider.dart';
import '../services/yandex_integration_service.dart';
import '../services/yandex_music_service.dart';
import '../theme/app_theme.dart';

/// Detail screen showing Yandex Music playlist tracks before playing.
class YandexPlaylistDetailScreen extends StatefulWidget {
  final YandexPlaylistResult playlist;
  final YandexIntegrationService integrationService;

  const YandexPlaylistDetailScreen({
    super.key,
    required this.playlist,
    required this.integrationService,
  });

  @override
  State<YandexPlaylistDetailScreen> createState() => _YandexPlaylistDetailScreenState();
}

class _YandexPlaylistDetailScreenState extends State<YandexPlaylistDetailScreen>
    with SingleTickerProviderStateMixin {
  List<Song> _tracks = [];
  bool _isLoading = true;
  String? _error;
  int _matchedCount = 0;
  int _totalCount = 0;

  late AnimationController _progressController;
  late Animation<double> _progressAnimation;

  @override
  void initState() {
    super.initState();
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _progressAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _progressController, curve: Curves.easeInOut),
    );
    _loadTracks();
  }

  @override
  void dispose() {
    _progressController.dispose();
    super.dispose();
  }

  Future<void> _loadTracks() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final tracks = await widget.integrationService.getPlaylistTracks(
        playlistUid: widget.playlist.uid,
        playlistKind: widget.playlist.kind,
        limit: 100,
      );

      if (mounted) {
        setState(() {
          _tracks = tracks;
          _matchedCount = tracks.length;
          _totalCount = widget.playlist.trackCount;
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // App Bar with playlist info
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            backgroundColor: isDark ? AppTheme.darkBackground : Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              background: _buildHeader(isDark),
              title: Text(
                widget.playlist.title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
            ),
            actions: [
              if (_tracks.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.play_arrow_rounded),
                  onPressed: _playAll,
                  tooltip: 'Play all',
                ),
            ],
          ),

          // Status bar
          SliverToBoxAdapter(
            child: _buildStatusBar(isDark),
          ),

          // Loading animation
          if (_isLoading)
            const SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _LoadingAnimation(),
                    SizedBox(height: 16),
                    Text(
                      'Searching for tracks on your server...',
                      style: TextStyle(fontSize: 14),
                    ),
                  ],
                ),
              ),
            )
          // Error state
          else if (_error != null)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Colors.red[300],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Error loading tracks',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _loadTracks,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          // Empty state
          else if (_tracks.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.music_off,
                      size: 48,
                      color: Colors.grey[400],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No tracks found on server',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Try searching for these tracks on your Subsonic server',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            )
          // Track list
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  return _buildTrackTile(_tracks[index], index);
                },
                childCount: _tracks.length,
              ),
            ),
        ],
      ),
      // Play button at bottom
      bottomNavigationBar: _tracks.isNotEmpty
          ? _buildPlayButton(isDark)
          : null,
    );
  }

  Widget _buildHeader(bool isDark) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Cover image or gradient
        if (widget.playlist.coverUrl != null)
          CachedNetworkImage(
            imageUrl: widget.playlist.coverUrl!,
            fit: BoxFit.cover,
            placeholder: (context, url) => _buildHeaderPlaceholder(isDark),
            errorWidget: (context, url, error) => _buildHeaderPlaceholder(isDark),
          )
        else
          _buildHeaderGradient(isDark),

        // Gradient overlay
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                isDark ? AppTheme.darkBackground : Colors.white,
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeaderPlaceholder(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.appleMusicRed.withValues(alpha: 0.3),
            const Color(0xFF16293D).withValues(alpha: 0.3),
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.queue_music,
          color: Colors.white.withValues(alpha: 0.5),
          size: 64,
        ),
      ),
    );
  }

  Widget _buildHeaderGradient(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [const Color(0xFF282828), const Color(0xFF1A1A1A)]
              : [const Color(0xFFF5F5F5), const Color(0xFFE0E0E0)],
        ),
      ),
    );
  }

  Widget _buildStatusBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(
            _matchedCount > 0 ? Icons.check_circle : Icons.info_outline,
            size: 16,
            color: _matchedCount > 0 ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 8),
          Text(
            '$_matchedCount of $_totalCount tracks found on server',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.white70 : Colors.black54,
            ),
          ),
          const Spacer(),
          if (_matchedCount > 0)
            TextButton(
              onPressed: _playAll,
              child: const Text('Play all'),
            ),
        ],
      ),
    );
  }

  Widget _buildTrackTile(Song song, int index) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: isDark ? AppTheme.darkSurface : Colors.grey[200],
        ),
        child: Center(
          child: Text(
            '${index + 1}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
          ),
        ),
      ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          color: isDark ? Colors.white : Colors.black,
        ),
      ),
      subtitle: Text(
        song.artist ?? 'Unknown Artist',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: isDark ? Colors.white54 : Colors.black54,
        ),
      ),
      trailing: Text(
        song.formattedDuration,
        style: TextStyle(
          fontSize: 12,
          color: isDark ? Colors.white38 : Colors.black38,
        ),
      ),
      onTap: () {
        HapticFeedback.lightImpact();
        context.read<PlayerProvider>().playSong(
          song,
          playlist: _tracks,
          startIndex: index,
        );
      },
    );
  }

  Widget _buildPlayButton(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkBackground : Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton.icon(
            onPressed: _playAll,
            icon: const Icon(Icons.play_arrow_rounded, size: 28),
            label: Text(
              'Play all ($_matchedCount tracks)',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.appleMusicRed,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _playAll() {
    if (_tracks.isEmpty) return;
    HapticFeedback.mediumImpact();
    context.read<PlayerProvider>().playSong(
      _tracks.first,
      playlist: _tracks,
      startIndex: 0,
    );
  }
}

/// Animated loading widget with pulsing circles.
class _LoadingAnimation extends StatefulWidget {
  const _LoadingAnimation();

  @override
  State<_LoadingAnimation> createState() => _LoadingAnimationState();
}

class _LoadingAnimationState extends State<_LoadingAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (index) {
            final delay = index * 0.2;
            final value = (_controller.value + delay) % 1.0;
            final scale = 0.5 + (value < 0.5 ? value * 2 : (1 - value) * 2) * 0.5;
            final opacity = 0.3 + scale * 0.7;

            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color.lerp(
                  AppTheme.appleMusicRed,
                  const Color(0xFF16293D),
                  scale,
                )!.withValues(alpha: opacity),
              ),
              transform: Matrix4.identity()..scale(scale),
            );
          }),
        );
      },
    );
  }
}
