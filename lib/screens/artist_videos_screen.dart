import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../services/theme_service.dart';
import '../widgets/app_gradient_background.dart';
import '../services/yandex_music_service.dart';
import '../services/yandex_music_public_api.dart';
import '../providers/yandex_music_provider.dart';
import '../theme/yandex_music_theme.dart';
import 'artist_video_player_screen.dart';

/// Вкладка Видео артиста (открывается из ArtistScreen -> 3 точки -> Видео).
/// Теперь с лентой клипов (горизонтальная карусель) + списком всех видео.
/// Работает без токена через public API, с токеном — больше результатов.
class ArtistVideosScreen extends StatefulWidget {
  final String artistId;
  final String artistName;

  const ArtistVideosScreen({
    super.key,
    required this.artistId,
    required this.artistName,
  });

  @override
  State<ArtistVideosScreen> createState() => _ArtistVideosScreenState();
}

class _ArtistVideosScreenState extends State<ArtistVideosScreen> {
  List<YandexVideoResult> _videos = [];
  List<Map<String, dynamic>> _clips = []; // publicApi searchVideos лента
  bool _isLoading = true;
  String? _error;
  String _filter = 'all'; // all | clip | concert

  @override
  void initState() {
    super.initState();
    _loadVideos();
  }

  Future<void> _loadVideos() async {
    final yandexProvider = Provider.of<YandexMusicProvider>(context, listen: false);
    if (!yandexProvider.isEnabled) {
      setState(() {
        _error = 'Интеграция Яндекс Музыки отключена';
        _isLoading = false;
      });
      return;
    }

    final service = YandexMusicService(oauthToken: yandexProvider.oauthToken);
    final publicApi = YandexMusicPublicApi();
    try {
      // Параллельно: brief-info видео (с резолвом ID) + публичные клипы через search
      final futures = await Future.wait([
        service.getArtistVideos(widget.artistId, artistName: widget.artistName),
        publicApi.getArtistVideosByName(widget.artistName, limit: 12),
      ]);
      final briefVideos = futures[0] as List<YandexVideoResult>;
      final searchClips = futures[1] as List<Map<String, dynamic>>;

      // Мерджим: brief-info + search по имени (пользователь просил искать именно по имени, а не по Navidrome UID)
      List<YandexVideoResult> allVideos = List.from(briefVideos);
      if (searchClips.isNotEmpty) {
        final existingTitles = allVideos.map((v) => v.title.toLowerCase()).toSet();
        final existingIds = allVideos.map((v) => v.providerVideoId).whereType<String>().toSet();
        for (final c in searchClips) {
          final title = c['title']?.toString() ?? c['name']?.toString() ?? widget.artistName;
          final pid = c['providerVideoId']?.toString() ?? c['id']?.toString();
          final thumb = c['cover']?.toString() ?? c['thumbnail']?.toString() ?? c['ogImage']?.toString() ?? c['coverUri']?.toString();
          if (title.isEmpty) continue;
          final lowTitle = title.toLowerCase();
          if (existingTitles.contains(lowTitle) || (pid != null && existingIds.contains(pid))) continue;
          allVideos.add(YandexVideoResult(
            title: title,
            thumbnailUrl: thumb,
            embedUrl: c['embedUrl']?.toString() ?? c['url']?.toString(),
            provider: c['provider']?.toString() ?? 'Yandex',
            providerVideoId: pid,
          ));
          if (pid != null) existingIds.add(pid);
          existingTitles.add(lowTitle);
        }
      }

      if (mounted) {
        setState(() {
          _videos = allVideos;
          _clips = searchClips;
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

  List<dynamic> get _filteredVideos {
    if (_filter == 'all') return _videos;
    return _videos.where((v) {
      final t = v.title.toLowerCase();
      if (_filter == 'clip') return t.contains('clip') || t.contains('клип') || t.contains('official');
      if (_filter == 'concert') return t.contains('live') || t.contains('концерт') || t.contains('concert');
      return true;
    }).toList();
  }

  void _playVideo(YandexVideoResult video) {
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArtistVideoPlayerScreen(video: video, artistName: widget.artistName),
      ),
    );
  }

  void _playClip(Map<String, dynamic> clip) {
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArtistVideoPlayerScreen.fromClip(clip: clip, artistName: widget.artistName),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(backgroundColor: Colors.transparent, 
      appBar: AppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),
        title: Text('${widget.artistName} — Видео'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.grey)))
              : CustomScrollView(
                  slivers: [
                    // Лента клипов (горизонтальная)
                    if (_clips.isNotEmpty) ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                          child: Row(
                            children: [
                              const Icon(Icons.movie_rounded, size: 20, color: Color(0xFFFFCC00)),
                              const SizedBox(width: 8),
                              Text('Клипы', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
                              const Spacer(),
                              Text('${_clips.length}', style: TextStyle(fontSize: 12, color: isDark ? Colors.white38 : Colors.black38)),
                            ],
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 160,
                          child: ListView.separated(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            scrollDirection: Axis.horizontal,
                            itemCount: _clips.length,
                            separatorBuilder: (_, __) => const SizedBox(width: 12),
                            itemBuilder: (ctx, i) {
                              final c = _clips[i];
                              final title = c['title']?.toString() ?? c['name']?.toString() ?? 'Clip';
                              String? thumb;
                              final rawCover = c['cover'];
                              if (rawCover is String && rawCover.isNotEmpty) thumb = rawCover;
                              else if (rawCover is Map) thumb = rawCover['uri']?.toString() ?? rawCover['url']?.toString();
                              thumb ??= c['thumbnail']?.toString() ?? c['ogImage']?.toString() ?? c['coverUri']?.toString() ?? c['preview']?.toString();
                              String? coverUrl;
                              if (thumb != null && thumb.isNotEmpty) {
                                // normalize via Yandex cover logic + youtube fallback
                                thumb = thumb.replaceAll('%%', '400x225');
                                if (!thumb.startsWith('http')) thumb = 'https://$thumb';
                                // если это yandex uri без https
                                if (thumb.contains('avatars.yandex.net') && thumb.contains('%%')) thumb = thumb.replaceAll('%%', '400x225');
                                coverUrl = thumb;
                              }
                              if ((coverUrl == null || coverUrl.isEmpty) && c['providerVideoId'] != null) {
                                final pid = c['providerVideoId'].toString();
                                if (RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(pid)) {
                                  coverUrl = 'https://img.youtube.com/vi/$pid/hqdefault.jpg';
                                }
                              }
                              // Попытка вытянуть youtube id из embedUrl если превью нет
                              if ((coverUrl == null || coverUrl.isEmpty) && c['embedUrl'] != null) {
                                final m = RegExp(r'(?:youtu\.be/|youtube\.com/(?:embed/|watch\?v=))([a-zA-Z0-9_-]{11})').firstMatch(c['embedUrl'].toString());
                                if (m != null) coverUrl = 'https://img.youtube.com/vi/${m.group(1)}/hqdefault.jpg';
                              }
                              return GestureDetector(
                                onTap: () => _playClip(c),
                                child: SizedBox(
                                  width: 260,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        if (coverUrl != null)
                                          CachedNetworkImage(
                                            imageUrl: coverUrl,
                                            fit: BoxFit.cover,
                                            placeholder: (_, __) => Container(color: Colors.grey[900], child: const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24)))),
                                            errorWidget: (_, __, ___) => Container(color: Colors.grey[900], child: const Icon(Icons.videocam_rounded, color: Colors.white24, size: 40)),
                                          )
                                        else
                                          Container(color: Colors.grey[900], child: const Icon(Icons.videocam_rounded, color: Colors.white24, size: 40)),
                                        Container(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withValues(alpha: 0.7)]))),
                                        Center(
                                          child: Container(
                                            width: 48,
                                            height: 48,
                                            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: 0.6)),
                                            child: const Icon(YandexMusicTheme.playIcon, color: Colors.white, size: 28),
                                          ),
                                        ),
                                        Positioned(
                                          bottom: 8,
                                          left: 8,
                                          right: 8,
                                          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 16)),
                    ],

                    // Фильтры
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            _chip('Все', 'all'),
                            _chip('Клипы', 'clip'),
                            _chip('Live', 'concert'),
                          ],
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 12)),

                    // Список всех видео
                    if (_filteredVideos.isEmpty)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Column(
                            children: [
                              Icon(Icons.videocam_off_rounded, size: 48, color: Colors.grey),
                              SizedBox(height: 12),
                              Text('Нет видео', style: TextStyle(color: Colors.grey)),
                              SizedBox(height: 4),
                              Text('Попробуй включить токен Яндекс Музыки', style: TextStyle(color: Colors.grey, fontSize: 12)),
                            ],
                          ),
                        ),
                      )
                    else
                      SliverList.builder(
                        itemCount: _filteredVideos.length,
                        itemBuilder: (ctx, i) {
                          final v = _filteredVideos[i] as YandexVideoResult;
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                            child: _VideoCard(video: v, onTap: () => _playVideo(v)),
                          );
                        },
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                ),
    );
  }

  Widget _chip(String label, String value) {
    final selected = _filter == value;
    return ChoiceChip(
      label: Text(label, style: TextStyle(fontSize: 13, color: selected ? Colors.white : null)),
      selected: selected,
      selectedColor: const Color(0xFFFFCC00),
      onSelected: (_) => setState(() => _filter = value),
    );
  }
}

class _VideoCard extends StatelessWidget {
  final YandexVideoResult video;
  final VoidCallback onTap;

  const _VideoCard({required this.video, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Builder(builder: (context) {
                    String? thumb = video.thumbnailUrl;
                    // Normalize Yandex %% placeholder and ensure https
                    if (thumb != null && thumb.isNotEmpty) {
                      thumb = thumb.replaceAll('%%', '400x225');
                      if (!thumb.startsWith('http')) thumb = 'https://$thumb';
                    }
                    if ((thumb == null || thumb.isEmpty) && video.providerVideoId != null && RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(video.providerVideoId!)) {
                      thumb = 'https://img.youtube.com/vi/${video.providerVideoId}/hqdefault.jpg';
                    }
                    // Fallback: extract from embedUrl youtube id
                    if ((thumb == null || thumb.isEmpty) && video.embedUrl != null) {
                      final m = RegExp(r'(?:youtu\.be/|youtube\.com/(?:embed/|watch\?v=))([a-zA-Z0-9_-]{11})').firstMatch(video.embedUrl!);
                      if (m != null) thumb = 'https://img.youtube.com/vi/${m.group(1)}/hqdefault.jpg';
                    }
                    if (thumb != null && thumb.isNotEmpty) {
                      return CachedNetworkImage(
                        imageUrl: thumb,
                        fit: BoxFit.cover,
                        memCacheWidth: 600,
                        maxWidthDiskCache: 600,
                        placeholder: (_, __) => Container(color: Colors.grey[800], child: const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24)))),
                        errorWidget: (_, __, ___) => Container(color: Colors.grey[800], child: const Icon(Icons.videocam_rounded, color: Colors.white38, size: 48)),
                      );
                    }
                    return Container(color: Colors.grey[800], child: const Icon(Icons.videocam_rounded, color: Colors.white38, size: 48));
                  }),
                  Center(
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: 0.6)),
                      child: const Icon(YandexMusicTheme.playIcon, color: Colors.white, size: 30),
                    ),
                  ),
                  if (video.provider != null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(4)),
                        child: Text(video.provider!, style: const TextStyle(color: Colors.white, fontSize: 10)),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(video.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500), maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}
