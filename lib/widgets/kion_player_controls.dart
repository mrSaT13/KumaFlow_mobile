import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lottie/lottie.dart';
import '../theme/app_theme.dart';

/// KION-style animated like button with Lottie animation.
class KionLikeButton extends StatefulWidget {
  final bool isLiked;
  final VoidCallback onTap;
  final double size;

  const KionLikeButton({
    super.key,
    required this.isLiked,
    required this.onTap,
    this.size = 28,
  });

  @override
  State<KionLikeButton> createState() => _KionLikeButtonState();
}

class _KionLikeButtonState extends State<KionLikeButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _showAnimation = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(KionLikeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isLiked != widget.isLiked && widget.isLiked) {
      _playLikeAnimation();
    }
  }

  void _playLikeAnimation() {
    setState(() => _showAnimation = true);
    _controller.forward(from: 0).then((_) {
      if (mounted) {
        setState(() => _showAnimation = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      child: SizedBox(
        width: widget.size + 16,
        height: widget.size + 16,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_showAnimation)
              Lottie.asset(
                'assets/lottie/like_primary_animation.json',
                width: widget.size * 2,
                height: widget.size * 2,
                controller: _controller,
              ),
            Icon(
              widget.isLiked ? Icons.favorite : Icons.favorite_border,
              color: widget.isLiked
                  ? AppTheme.appleMusicRed
                  : Colors.white.withValues(alpha: 0.7),
              size: widget.size,
            ),
          ],
        ),
      ),
    );
  }
}

/// KION-style animated dislike button with broken heart icon.
class KionDislikeButton extends StatefulWidget {
  final VoidCallback onTap;
  final double size;

  const KionDislikeButton({
    super.key,
    required this.onTap,
    this.size = 24,
  });

  @override
  State<KionDislikeButton> createState() => _KionDislikeButtonState();
}

class _KionDislikeButtonState extends State<KionDislikeButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _showAnimation = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _playDislikeAnimation() {
    setState(() => _showAnimation = true);
    _controller.forward(from: 0).then((_) {
      if (mounted) {
        setState(() => _showAnimation = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        _playDislikeAnimation();
        widget.onTap();
      },
      child: SizedBox(
        width: widget.size + 16,
        height: widget.size + 16,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_showAnimation)
              Lottie.asset(
                'assets/lottie/dislike.json',
                width: widget.size * 2,
                height: widget.size * 2,
                controller: _controller,
              ),
            Icon(
              Icons.heart_broken_rounded,
              color: Colors.white.withValues(alpha: 0.7),
              size: widget.size,
            ),
          ],
        ),
      ),
    );
  }
}

/// KION-style animated play/pause button with Lottie.
class KionPlayPauseButton extends StatefulWidget {
  final bool isPlaying;
  final VoidCallback onTap;
  final double size;

  const KionPlayPauseButton({
    super.key,
    required this.isPlaying,
    required this.onTap,
    this.size = 64,
  });

  @override
  State<KionPlayPauseButton> createState() => _KionPlayPauseButtonState();
}

class _KionPlayPauseButtonState extends State<KionPlayPauseButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _showAnimation = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(KionPlayPauseButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      _playToggleAnimation();
    }
  }

  void _playToggleAnimation() {
    setState(() => _showAnimation = true);
    _controller.forward(from: 0).then((_) {
      if (mounted) {
        setState(() => _showAnimation = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_showAnimation)
              Lottie.asset(
                widget.isPlaying
                    ? 'assets/lottie/press_pause_anim_white.json'
                    : 'assets/lottie/press_play_anim_white.json',
                width: widget.size * 1.5,
                height: widget.size * 1.5,
                controller: _controller,
              ),
            Icon(
              widget.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: Colors.black,
              size: widget.size * 0.5,
            ),
          ],
        ),
      ),
    );
  }
}

/// KION-style animated shuffle button.
class KionShuffleButton extends StatefulWidget {
  final bool isEnabled;
  final VoidCallback onTap;
  final double size;

  const KionShuffleButton({
    super.key,
    required this.isEnabled,
    required this.onTap,
    this.size = 24,
  });

  @override
  State<KionShuffleButton> createState() => _KionShuffleButtonState();
}

class _KionShuffleButtonState extends State<KionShuffleButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(KionShuffleButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isEnabled != widget.isEnabled) {
      _controller.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      child: SizedBox(
        width: widget.size + 16,
        height: widget.size + 16,
        child: Lottie.asset(
          widget.isEnabled
              ? 'assets/lottie/shuffle.json'
              : 'assets/lottie/unshuffle.json',
          width: widget.size,
          height: widget.size,
          controller: _controller,
        ),
      ),
    );
  }
}

/// KION-style animated repeat button.
class KionRepeatButton extends StatefulWidget {
  final int repeatMode; // 0=off, 1=all, 2=one
  final VoidCallback onTap;
  final double size;

  const KionRepeatButton({
    super.key,
    required this.repeatMode,
    required this.onTap,
    this.size = 24,
  });

  @override
  State<KionRepeatButton> createState() => _KionRepeatButtonState();
}

class _KionRepeatButtonState extends State<KionRepeatButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(KionRepeatButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repeatMode != widget.repeatMode) {
      _controller.forward(from: 0);
    }
  }

  String _getAsset() {
    switch (widget.repeatMode) {
      case 1:
        return 'assets/lottie/repeat.json';
      case 2:
        return 'assets/lottie/repeat_track.json';
      default:
        return 'assets/lottie/repeat_disable.json';
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      child: SizedBox(
        width: widget.size + 16,
        height: widget.size + 16,
        child: Lottie.asset(
          _getAsset(),
          width: widget.size,
          height: widget.size,
          controller: _controller,
        ),
      ),
    );
  }
}

/// KION-style speed control button.
class KionSpeedButton extends StatelessWidget {
  final double speed;
  final VoidCallback onTap;
  final double size;

  const KionSpeedButton({
    super.key,
    required this.speed,
    required this.onTap,
    this.size = 22,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: speed != 1.0
              ? AppTheme.appleMusicRed.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          speed == 1.0 ? '1x' : '${speed}x',
          style: TextStyle(
            color: speed != 1.0
                ? AppTheme.appleMusicRed
                : Colors.white.withValues(alpha: 0.7),
            fontSize: size,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
