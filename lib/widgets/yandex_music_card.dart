import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme/yandex_music_theme.dart';

/// Yandex Music-style card with hover animation and gradient overlay.
class YandexMusicCard extends StatefulWidget {
  final String? imageUrl;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final double width;
  final double height;
  final bool isCircle;
  final bool showPlayButton;
  final Widget? child;

  const YandexMusicCard({
    super.key,
    this.imageUrl,
    required this.title,
    this.subtitle,
    this.onTap,
    this.width = 160,
    this.height = 200,
    this.isCircle = false,
    this.showPlayButton = false,
    this.child,
  });

  @override
  State<YandexMusicCard> createState() => _YandexMusicCardState();
}

class _YandexMusicCardState extends State<YandexMusicCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _hoverController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _elevationAnimation;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    _hoverController = AnimationController(
      vsync: this,
      duration: YandexMusicTheme.microDuration,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.03).animate(
      CurvedAnimation(parent: _hoverController, curve: YandexMusicTheme.defaultCurve),
    );
    _elevationAnimation = Tween<double>(begin: 0, end: 8).animate(
      CurvedAnimation(parent: _hoverController, curve: YandexMusicTheme.defaultCurve),
    );
  }

  @override
  void dispose() {
    _hoverController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) {
        setState(() => _isHovered = true);
        _hoverController.forward();
      },
      onExit: (_) {
        setState(() => _isHovered = false);
        _hoverController.reverse();
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _hoverController,
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAnimation.value,
              child: Container(
                width: widget.width,
                height: widget.height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.isCircle ? widget.width / 2 : 12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: 0.2 + (_elevationAnimation.value * 0.03),
                      ),
                      blurRadius: 8 + _elevationAnimation.value,
                      offset: Offset(0, 2 + _elevationAnimation.value / 2),
                    ),
                  ],
                ),
                child: child,
              ),
            );
          },
          child: _buildCardContent(),
        ),
      ),
    );
  }

  Widget _buildCardContent() {
    if (widget.isCircle) {
      return _buildCircleCard();
    }
    return _buildRectCard();
  }

  Widget _buildCircleCard() {
    return ClipOval(
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildImage(),
          _buildGradientOverlay(),
          if (widget.showPlayButton && _isHovered) _buildPlayButton(),
          if (widget.child != null) widget.child!,
        ],
      ),
    );
  }

  Widget _buildRectCard() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildImage(),
          _buildGradientOverlay(),
          _buildTextOverlay(),
          if (widget.showPlayButton && _isHovered) _buildPlayButton(),
          if (widget.child != null) widget.child!,
        ],
      ),
    );
  }

  Widget _buildImage() {
    if (widget.imageUrl != null) {
      return CachedNetworkImage(
        imageUrl: widget.imageUrl!,
        fit: BoxFit.cover,
        placeholder: (_, __) => _buildPlaceholder(),
        errorWidget: (_, __, ___) => _buildPlaceholder(),
      );
    }
    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      color: YandexMusicTheme.darkElevated,
      child: const Center(
        child: Icon(
          Icons.music_note_rounded,
          size: 48,
          color: YandexMusicTheme.textTertiary,
        ),
      ),
    );
  }

  Widget _buildGradientOverlay() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        height: widget.height * 0.5,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black.withValues(alpha: 0.8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextOverlay() {
    return Positioned(
      bottom: 12,
      left: 12,
      right: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            style: YandexMusicTheme.bodyLarge.copyWith(
              color: YandexMusicTheme.textPrimary,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (widget.subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              widget.subtitle!,
              style: YandexMusicTheme.bodySmall.copyWith(
                color: YandexMusicTheme.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPlayButton() {
    return Positioned(
      bottom: 12,
      right: 12,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: YandexMusicTheme.yandexYellow,
          boxShadow: [
            BoxShadow(
              color: YandexMusicTheme.yandexYellow.withValues(alpha: 0.4),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: const Icon(
          YandexMusicTheme.playIcon,
          color: Colors.white,
          size: 24,
        ),
      ),
    );
  }
}

/// Yandex Music-style horizontal scroll section.
class YandexMusicHorizontalSection extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final double itemWidth;
  final double itemHeight;
  final EdgeInsets padding;

  const YandexMusicHorizontalSection({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
    this.itemWidth = 160,
    this.itemHeight = 200,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: YandexMusicTheme.headingMedium,
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: YandexMusicTheme.bodyMedium,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: itemHeight + 40, // Extra space for text
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: padding,
            itemCount: children.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) => children[index],
          ),
        ),
      ],
    );
  }
}

/// Yandex Music-style artist card with circular image.
class YandexMusicArtistCard extends StatelessWidget {
  final String? imageUrl;
  final String name;
  final VoidCallback? onTap;
  final double size;

  const YandexMusicArtistCard({
    super.key,
    this.imageUrl,
    required this.name,
    this.onTap,
    this.size = 120,
  });

  @override
  Widget build(BuildContext context) {
    return YandexMusicCard(
      imageUrl: imageUrl,
      title: name,
      onTap: onTap,
      width: size,
      height: size,
      isCircle: true,
      showPlayButton: true,
    );
  }
}

/// Yandex Music-style album card.
class YandexMusicAlbumCard extends StatelessWidget {
  final String? imageUrl;
  final String title;
  final String? artist;
  final VoidCallback? onTap;
  final double size;

  const YandexMusicAlbumCard({
    super.key,
    this.imageUrl,
    required this.title,
    this.artist,
    this.onTap,
    this.size = 160,
  });

  @override
  Widget build(BuildContext context) {
    return YandexMusicCard(
      imageUrl: imageUrl,
      title: title,
      subtitle: artist,
      onTap: onTap,
      width: size,
      height: size,
      showPlayButton: true,
    );
  }
}

/// Yandex Music-style playlist card.
class YandexMusicPlaylistCard extends StatelessWidget {
  final String? imageUrl;
  final String title;
  final String? description;
  final VoidCallback? onTap;
  final double size;

  const YandexMusicPlaylistCard({
    super.key,
    this.imageUrl,
    required this.title,
    this.description,
    this.onTap,
    this.size = 160,
  });

  @override
  Widget build(BuildContext context) {
    return YandexMusicCard(
      imageUrl: imageUrl,
      title: title,
      subtitle: description,
      onTap: onTap,
      width: size,
      height: size,
      showPlayButton: true,
    );
  }
}
