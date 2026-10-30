import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import '../providers/player_provider.dart';
import '../providers/yandex_music_provider.dart';
import '../services/subsonic_service.dart';
import '../services/yandex_integration_service.dart';
import '../services/yandex_music_service.dart';
import '../theme/app_theme.dart';
import '../utils/navigation_helper.dart';
import 'yandex_playlist_detail_screen.dart';

/// Section displaying Yandex Music playlists on the home screen.
class YandexPlaylistsSection extends StatefulWidget {
  final double hPad;
  final bool isDesktop;

  const YandexPlaylistsSection({
    super.key,
    this.hPad = 16.0,
    this.isDesktop = false,
  });

  @override
  State<YandexPlaylistsSection> createState() => _YandexPlaylistsSectionState();
}

class _YandexPlaylistsSectionState extends State<YandexPlaylistsSection>
    with SingleTickerProviderStateMixin {
  late YandexIntegrationService _integrationService;
  List<YandexPlaylistResult> _playlists = [];
  bool _isLoading = false;
  bool _hasError = false;
  String? _loadingPlaylistId;

  // Cache keys
  static const String _cacheKey = 'yandex_playlists_cache_v1';
  static const String _cacheTimestampKey = 'yandex_playlists_cache_ts';
  static const Duration _cacheExpiry = Duration(hours: 6);

  @override
  void initState() {
    super.initState();
    _initService();
    _loadPlaylists();
  }

  void _initService() {
    final yandexProvider = Provider.of<YandexMusicProvider>(context, listen: false);
    debugPrint('[YandexPlaylists] Initializing service. hasToken: ${yandexProvider.hasToken}, isEnabled: ${yandexProvider.isEnabled}');

    if (yandexProvider.hasToken) {
      final subsonicService = Provider.of<SubsonicService>(context, listen: false);
      _integrationService = YandexIntegrationService(
        yandexService: YandexMusicService(oauthToken: yandexProvider.oauthToken),
        subsonicService: subsonicService,
      );
      debugPrint('[YandexPlaylists] Service initialized with token');
    } else {
      debugPrint('[YandexPlaylists] No token available, service not initialized');
    }
  }

  Future<void> _loadPlaylists() async {
    final yandexProvider = Provider.of<YandexMusicProvider>(context, listen: false);
    debugPrint('[YandexPlaylists] Loading playlists. isEnabled: ${yandexProvider.isEnabled}, hasToken: ${yandexProvider.hasToken}');

    if (!yandexProvider.isEnabled || !yandexProvider.hasToken) {
      debugPrint('[YandexPlaylists] Skipping load - Yandex Music disabled or no token');
      return;
    }

    // Initialize service if not already done
    if (_integrationService == null) {
      _initService();
      if (_integrationService == null) {
        debugPrint('[YandexPlaylists] Failed to initialize service');
        return;
      }
    }

    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      // Try to load from cache first
      final cachedPlaylists = await _loadFromCache();
      if (cachedPlaylists != null && cachedPlaylists.isNotEmpty) {
        if (mounted) {
          setState(() {
            _playlists = cachedPlaylists;
            _isLoading = false;
          });
        }
        // Still refresh in background
        _refreshPlaylists();
        return;
      }

      // No cache, fetch from API
      await _refreshPlaylists();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  Future<void> _refreshPlaylists() async {
    try {
      debugPrint('[YandexPlaylists] Refreshing playlists from API...');
      final playlists = await _integrationService.fetchPlaylists();
      debugPrint('[YandexPlaylists] Fetched ${playlists.length} playlists');

      if (mounted) {
        setState(() {
          _playlists = playlists.where((p) => p.trackCount > 0).toList();
          _isLoading = false;
          _hasError = false;
        });
        debugPrint('[YandexPlaylists] Showing ${_playlists.length} playlists with tracks');
        await _saveToCache(_playlists);
      }
    } catch (e) {
      debugPrint('[YandexPlaylists] Error refreshing playlists: $e');
      if (mounted && _playlists.isEmpty) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  Future<List<YandexPlaylistResult>?> _loadFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = prefs.getInt(_cacheTimestampKey);
      if (timestamp == null) return null;

      final cacheTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
      if (DateTime.now().difference(cacheTime) > _cacheExpiry) {
        return null; // Cache expired
      }

      final json = prefs.getString(_cacheKey);
      if (json == null) return null;

      final list = jsonDecode(json) as List;
      return list.map((e) => YandexPlaylistResult.fromJson(e)).toList();
    } catch (e) {
      return null;
    }
  }

  Future<void> _saveToCache(List<YandexPlaylistResult> playlists) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = playlists.map((p) => {
        'uid': p.uid,
        'kind': p.kind,
        'title': p.title,
        'description': p.description,
        'trackCount': p.trackCount,
        'coverUrl': p.coverUrl,
        'isOwn': p.isOwn,
      }).toList();
      await prefs.setString(_cacheKey, jsonEncode(json));
      await prefs.setInt(_cacheTimestampKey, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      // Ignore cache errors
    }
  }

  @override
  Widget build(BuildContext context) {
    final yandexProvider = Provider.of<YandexMusicProvider>(context);

    // Don't show if Yandex Music is disabled or no token
    if (!yandexProvider.isEnabled || !yandexProvider.hasToken) {
      debugPrint('[YandexPlaylists] Not showing - isEnabled: ${yandexProvider.isEnabled}, hasToken: ${yandexProvider.hasToken}');
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle(),
        if (_isLoading && _playlists.isEmpty)
          _buildLoadingSkeleton()
        else if (_hasError && _playlists.isEmpty)
          _buildErrorState()
        else
          SizedBox(
            height: widget.isDesktop ? 180 : 160,
            child: RefreshIndicator(
              onRefresh: () async {
                HapticFeedback.lightImpact();
                await _refreshPlaylists();
              },
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: widget.hPad),
                itemCount: _playlists.length,
                itemBuilder: (context, index) {
                  return _buildPlaylistCard(_playlists[index]);
                },
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSectionTitle() {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.hPad, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppTheme.appleMusicRed, Color(0xFF16293D)],
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(
              Icons.music_note,
              color: Colors.white,
              size: 14,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Yandex Music',
            style: TextStyle(
              fontSize: widget.isDesktop ? 20 : 18,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white
                  : Colors.black,
            ),
          ),
          const Spacer(),
          if (_playlists.isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                HapticFeedback.lightImpact();
                await _refreshPlaylists();
              },
              icon: Icon(
                Icons.refresh,
                size: 16,
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white54
                    : Colors.black54,
              ),
              label: Text(
                'Refresh',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white54
                      : Colors.black54,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLoadingSkeleton() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: widget.isDesktop ? 180 : 160,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: widget.hPad),
        itemCount: 4,
        itemBuilder: (context, index) {
          return Container(
            width: widget.isDesktop ? 160 : 140,
            margin: const EdgeInsets.only(right: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Shimmer cover
                Container(
                  height: widget.isDesktop ? 120 : 100,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: LinearGradient(
                      begin: Alignment(-1.0 + (index * 0.5), 0),
                      end: Alignment(1.0 + (index * 0.5), 0),
                      colors: [
                        isDark ? const Color(0xFF282828) : Colors.grey[300]!,
                        isDark ? const Color(0xFF3A3A3A) : Colors.grey[200]!,
                        isDark ? const Color(0xFF282828) : Colors.grey[300]!,
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Shimmer text
                Container(
                  height: 12,
                  width: 80,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: isDark ? const Color(0xFF3A3A3A) : Colors.grey[300],
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  height: 10,
                  width: 50,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: isDark ? const Color(0xFF2A2A2A) : Colors.grey[200],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildErrorState() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.hPad),
      child: Container(
        height: 80,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: isDark ? AppTheme.darkSurface : Colors.grey[100],
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.cloud_off,
                color: isDark ? Colors.white24 : Colors.black26,
                size: 24,
              ),
              const SizedBox(height: 4),
              Text(
                'Failed to load playlists',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: _loadPlaylists,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaylistCard(YandexPlaylistResult playlist) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLoadingThis = _loadingPlaylistId == playlist.uid;

    return GestureDetector(
      onTap: () => _openPlaylist(playlist),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: widget.isDesktop ? 160 : 140,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cover art with loading overlay
            Stack(
              children: [
                Container(
                  height: widget.isDesktop ? 120 : 100,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: isDark ? AppTheme.darkSurface : Colors.grey[200],
                  ),
                  child: playlist.coverUrl != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: CachedNetworkImage(
                            imageUrl: playlist.coverUrl!,
                            fit: BoxFit.cover,
                            placeholder: (context, url) => _buildPlaceholder(isDark),
                            errorWidget: (context, url, error) => _buildPlaceholder(isDark),
                          ),
                        )
                      : _buildPlaceholder(isDark),
                ),
                // Loading overlay
                if (isLoadingThis)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: Colors.black.withValues(alpha: 0.6),
                      ),
                      child: const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(height: 8),
                            Text(
                              'Loading...',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // Title
            Text(
              playlist.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
            const SizedBox(height: 2),
            // Track count
            Text(
              '${playlist.trackCount} tracks',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white54 : Colors.black54,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholder(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            isDark ? const Color(0xFF282828) : const Color(0xFFF5F5F5),
            isDark ? const Color(0xFF1A1A1A) : const Color(0xFFE0E0E0),
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.queue_music,
          color: isDark ? Colors.white24 : Colors.black26,
          size: 32,
        ),
      ),
    );
  }

  Future<void> _openPlaylist(YandexPlaylistResult playlist) async {
    HapticFeedback.mediumImpact();

    // Navigate to detail screen
    NavigationHelper.push(
      context,
      YandexPlaylistDetailScreen(
        playlist: playlist,
        integrationService: _integrationService,
      ),
    );
  }
}
