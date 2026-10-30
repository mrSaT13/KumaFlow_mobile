import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../widgets/app_gradient_background.dart';
import '../services/yandex_music_service.dart';
import '../services/subsonic_service.dart';
import '../services/theme_service.dart';
import '../providers/yandex_music_provider.dart';

/// Вкладка Фото артиста (из ArtistScreen -> 3 точки -> Фото артиста).
/// Теперь: грид превью с категориями (обложки/фото) + тап -> полноэкранный свайп.
/// Работает без токена (public covers), с токеном — больше фото.
class ArtistImagesScreen extends StatefulWidget {
  final String artistId;
  final String artistName;
  final int initialIndex;

  const ArtistImagesScreen({
    super.key,
    required this.artistId,
    required this.artistName,
    this.initialIndex = 0,
  });

  @override
  State<ArtistImagesScreen> createState() => _ArtistImagesScreenState();
}

class _ArtistImagesScreenState extends State<ArtistImagesScreen> {
  List<YandexImageResult> _images = [];
  bool _isLoading = true;
  String? _error;
  String _filter = 'all'; // all | cover | artist

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  Future<void> _loadImages() async {
    final yandexProvider = Provider.of<YandexMusicProvider>(context, listen: false);
    final subsonic = Provider.of<SubsonicService>(context, listen: false);

    // Always try to get hover cover from Navidrome/Subsonic — даже без Яндекса
    String? hoverUrl;
    try {
      final artist = await subsonic.getArtist(widget.artistId);
      if (artist.coverArt != null && artist.coverArt!.isNotEmpty) {
        hoverUrl = subsonic.getCoverArtUrl(artist.coverArt!, size: 800);
      }
    } catch (_) {
      try {
        final res = await subsonic.search(widget.artistName, artistCount: 1);
        if (res.artists.isNotEmpty && res.artists.first.coverArt != null) {
          hoverUrl = subsonic.getCoverArtUrl(res.artists.first.coverArt!, size: 800);
        }
      } catch (_) {}
    }

    if (!yandexProvider.isEnabled) {
      if (!mounted) return;
      if (hoverUrl != null) {
        setState(() {
          _images = [YandexImageResult(url: hoverUrl!, type: 'artist')];
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = 'Интеграция Яндекс Музыки отключена';
          _isLoading = false;
        });
      }
      return;
    }

    final service = YandexMusicService(oauthToken: yandexProvider.oauthToken);
    try {
      final images = await service.getArtistImages(widget.artistId, artistName: widget.artistName);
      final merged = List<YandexImageResult>.from(images);
      // Преpend hover-картинку (из SliverAppBar) автоматически в галерею
      if (hoverUrl != null && !merged.any((e) => e.url == hoverUrl)) {
        merged.insert(0, YandexImageResult(url: hoverUrl, type: 'artist'));
      }

      if (mounted) {
        setState(() {
          _images = merged;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        if (hoverUrl != null) {
          setState(() {
            _images = [YandexImageResult(url: hoverUrl!, type: 'artist')];
            _isLoading = false;
          });
        } else {
          setState(() {
            _error = e.toString();
            _isLoading = false;
          });
        }
      }
    }
  }

  List<YandexImageResult> get _filtered {
    if (_filter == 'all') return _images;
    return _images.where((e) => e.type == _filter).toList();
  }

  void _openFullscreen(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _FullscreenGallery(
          images: _filtered,
          initialIndex: index,
          artistName: widget.artistName,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(backgroundColor: Colors.transparent, 
      appBar: AppBar(title: Text('${widget.artistName} — Фото'),
        actions: [
          if (_images.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text('${_filtered.length}/${_images.length}', style: TextStyle(fontSize: 13, color: isDark ? Colors.white70 : Colors.black54)),
              ),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.grey)))
              : _images.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.photo_library_outlined, size: 56, color: Colors.grey),
                          SizedBox(height: 12),
                          Text('Нет фото', style: TextStyle(color: Colors.grey)),
                          SizedBox(height: 4),
                          Text('Фото подтягиваются из Яндекс Музыки без токена', style: TextStyle(color: Colors.grey, fontSize: 12)),
                        ],
                      ),
                    )
                  : CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                            child: Wrap(
                              spacing: 8,
                              children: [
                                _chip('Все', 'all'),
                                _chip('Обложки', 'cover'),
                                _chip('Артист', 'artist'),
                              ],
                            ),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.all(8),
                          sliver: SliverGrid(
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                              childAspectRatio: 1,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (ctx, i) {
                                final img = _filtered[i];
                                return GestureDetector(
                                  onTap: () => _openFullscreen(i),
                                  child: Hero(
                                    tag: 'artist_img_$i',
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          CachedNetworkImage(
                                            imageUrl: img.url,
                                            fit: BoxFit.cover,
                                            placeholder: (_, __) => Container(color: Colors.grey[900]),
                                            errorWidget: (_, __, ___) => Container(color: Colors.grey[800], child: const Icon(Icons.broken_image_rounded, color: Colors.white24)),
                                          ),
                                          Positioned(
                                            bottom: 6,
                                            left: 6,
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(6)),
                                              child: Text(img.type == 'cover' ? 'Обложка' : 'Фото', style: const TextStyle(color: Colors.white, fontSize: 10)),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                              childCount: _filtered.length,
                            ),
                          ),
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
      selectedColor: Theme.of(context).colorScheme.primary,
      onSelected: (_) => setState(() => _filter = value),
    );
  }
}

class _FullscreenGallery extends StatefulWidget {
  final List<YandexImageResult> images;
  final int initialIndex;
  final String artistName;
  const _FullscreenGallery({required this.images, required this.initialIndex, required this.artistName});

  @override
  State<_FullscreenGallery> createState() => _FullscreenGalleryState();
}

class _FullscreenGalleryState extends State<_FullscreenGallery> {
  late PageController _pc;
  late int _idx;

  @override
  void initState() {
    super.initState();
    _idx = widget.initialIndex;
    _pc = PageController(initialPage: _idx);
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text('${widget.artistName} ${_idx + 1}/${widget.images.length}', style: const TextStyle(color: Colors.white, fontSize: 14)),
      ),
      body: PageView.builder(
        controller: _pc,
        itemCount: widget.images.length,
        onPageChanged: (i) => setState(() => _idx = i),
        itemBuilder: (ctx, i) {
          final img = widget.images[i];
          return InteractiveViewer(
            minScale: 0.5,
            maxScale: 4,
            child: Center(
              child: Hero(
                tag: 'artist_img_$i',
                child: CachedNetworkImage(
                  imageUrl: img.url,
                  fit: BoxFit.contain,
                  placeholder: (_, __) => const CircularProgressIndicator(color: Colors.white),
                  errorWidget: (_, __, ___) => const Icon(Icons.error, color: Colors.white54, size: 48),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
