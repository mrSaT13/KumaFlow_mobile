import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/yandex_music_public_api.dart';
import '../theme/app_theme.dart';

/// KION/Yandex-style landing section with horizontal scrollable cards.
/// Displays new releases, charts, editorial playlists, etc.
class KionLandingSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Map<String, dynamic>> items;
  final ValueChanged<Map<String, dynamic>>? onTap;
  final double hPad;

  const KionLandingSection({
    super.key,
    required this.title,
    required this.icon,
    required this.items,
    this.onTap,
    this.hPad = 16.0,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(hPad, 16, hPad, 12),
          child: Row(
            children: [
              Icon(icon, color: AppTheme.appleMusicRed, size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 180,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: hPad),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return _LandingCard(
                item: item,
                onTap: onTap != null ? () => onTap!(item) : null,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Single landing card (album/playlist/artist).
class _LandingCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final VoidCallback? onTap;

  const _LandingCard({required this.item, this.onTap});

  @override
  Widget build(BuildContext context) {
    final yandexApi = YandexMusicPublicApi();
    final title = item['title'] as String? ??
        item['name'] as String? ??
        'Неизвестно';
    final subtitle = item['subtitle'] as String? ??
        item['description'] as String? ??
        '';

    // Try to extract cover URL
    String? coverUrl;
    if (item.containsKey('cover')) {
      coverUrl = yandexApi.extractCoverUrl(item['cover']);
    } else if (item.containsKey('coverUri')) {
      coverUrl = yandexApi.getCoverUrl(item['coverUri'] as String);
    } else if (item.containsKey('images')) {
      final images = item['images'] as List?;
      if (images != null && images.isNotEmpty) {
        final firstImage = images.first as Map<String, dynamic>?;
        coverUrl = yandexApi.extractCoverUrl(firstImage);
      }
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 160,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: coverUrl != null
                  ? CachedNetworkImage(
                      imageUrl: coverUrl,
                      width: 160,
                      height: 160,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                        width: 160,
                        height: 160,
                        color: AppTheme.darkElevated,
                        child: const Icon(Icons.album, size: 40),
                      ),
                      errorWidget: (_, __, ___) => Container(
                        width: 160,
                        height: 160,
                        color: AppTheme.darkElevated,
                        child: const Icon(Icons.album, size: 40),
                      ),
                    )
                  : Container(
                      width: 160,
                      height: 160,
                      color: AppTheme.darkElevated,
                      child: const Icon(Icons.album, size: 40),
                    ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 11,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Quick access grid with album covers.
class KionQuickAccessGrid extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final ValueChanged<Map<String, dynamic>>? onTap;
  final double hPad;
  final bool isDesktop;

  const KionQuickAccessGrid({
    super.key,
    required this.items,
    this.onTap,
    this.hPad = 16.0,
    this.isDesktop = false,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    final crossAxisCount = isDesktop ? 4 : 2;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          childAspectRatio: 3,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return _QuickAccessItem(
            item: item,
            onTap: onTap != null ? () => onTap!(item) : null,
          );
        },
      ),
    );
  }
}

/// Single quick access item.
class _QuickAccessItem extends StatelessWidget {
  final Map<String, dynamic> item;
  final VoidCallback? onTap;

  const _QuickAccessItem({required this.item, this.onTap});

  @override
  Widget build(BuildContext context) {
    final yandexApi = YandexMusicPublicApi();
    final title = item['title'] as String? ?? item['name'] as String? ?? '';
    final subtitle = item['subtitle'] as String? ?? '';

    String? coverUrl;
    if (item.containsKey('cover')) {
      coverUrl = yandexApi.extractCoverUrl(item['cover']);
    } else if (item.containsKey('coverUri')) {
      coverUrl = yandexApi.getCoverUrl(item['coverUri'] as String);
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.darkCard,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(8),
                bottomLeft: Radius.circular(8),
              ),
              child: coverUrl != null
                  ? CachedNetworkImage(
                      imageUrl: coverUrl,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                        width: 56,
                        height: 56,
                        color: AppTheme.darkElevated,
                      ),
                      errorWidget: (_, __, ___) => Container(
                        width: 56,
                        height: 56,
                        color: AppTheme.darkElevated,
                        child: const Icon(Icons.music_note, size: 20),
                      ),
                    )
                  : Container(
                      width: 56,
                      height: 56,
                      color: AppTheme.darkElevated,
                      child: const Icon(Icons.music_note, size: 20),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 11,
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
}
