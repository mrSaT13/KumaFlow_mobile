import 'package:flutter/material.dart';
import 'app_theme.dart';

/// Yandex Music-inspired theme and design system.
///
/// Provides colors, gradients, animations, and styles that match
/// the Yandex Music app aesthetic.
class YandexMusicTheme {
  // ──────────────────────────────────────────────────────────────────────────
  // Colors
  // ──────────────────────────────────────────────────────────────────────────

  /// Wave accent — follows the shared Polar theme (see AppTheme).
  static const Color yandexYellow = AppTheme.appleMusicRed;

  /// Dark background
  static const Color darkBackground = Color(0xFF121212);

  /// Card background (dark mode)
  static const Color darkCard = Color(0xFF1E1E1E);

  /// Elevated card background
  static const Color darkElevated = Color(0xFF282828);

  /// Surface color
  static const Color darkSurface = Color(0xFF2C2C2C);

  /// Text colors
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xFFB3B3B3);
  static const Color textTertiary = Color(0xFF727272);

  /// Accent colors for different states
  static const Color accentRed = Color(0xFFE53935);
  static const Color accentGreen = Color(0xFF1DB954);
  static const Color accentBlue = Color(0xFF1E88E5);
  static const Color accentPurple = Color(0xFF9C27B0);

  // ──────────────────────────────────────────────────────────────────────────
  // Gradients
  // ──────────────────────────────────────────────────────────────────────────

  /// Default gradient for player background
  static LinearGradient defaultGradient = const LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFF2C2C2C),
      Color(0xFF121212),
    ],
  );

  /// Create gradient from album art colors
  static LinearGradient createGradientFromColors({
    required Color dominantColor,
    required Color accentColor,
    Alignment begin = Alignment.topCenter,
    Alignment end = Alignment.bottomCenter,
  }) {
    return LinearGradient(
      begin: begin,
      end: end,
      colors: [
        dominantColor.withValues(alpha: 0.8),
        _darkenColor(dominantColor, 0.4),
        Color.lerp(dominantColor, accentColor, 0.3)!.withValues(alpha: 0.6),
        const Color(0xFF121212),
      ],
      stops: const [0.0, 0.3, 0.6, 1.0],
    );
  }

  /// Create radial gradient for hover effects
  static RadialGradient createHoverGradient(Color centerColor) {
    return RadialGradient(
      center: Alignment.center,
      radius: 0.8,
      colors: [
        centerColor.withValues(alpha: 0.3),
        centerColor.withValues(alpha: 0.0),
      ],
    );
  }

  /// Shimmer gradient for loading states
  static LinearGradient shimmerGradient = LinearGradient(
    begin: const Alignment(-1.0, -0.3),
    end: const Alignment(1.0, 0.3),
    colors: [
      Colors.grey[900]!,
      Colors.grey[800]!,
      Colors.grey[900]!,
    ],
  );

  // ──────────────────────────────────────────────────────────────────────────
  // Box Decorations
  // ──────────────────────────────────────────────────────────────────────────

  /// Card decoration with subtle shadow
  static BoxDecoration cardDecoration({
    Color? color,
    double borderRadius = 12,
  }) {
    return BoxDecoration(
      color: color ?? darkCard,
      borderRadius: BorderRadius.circular(borderRadius),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.3),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  /// Hover card decoration
  static BoxDecoration hoverCardDecoration({
    Color? color,
    double borderRadius = 12,
  }) {
    return BoxDecoration(
      color: color ?? darkElevated,
      borderRadius: BorderRadius.circular(borderRadius),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.4),
          blurRadius: 16,
          offset: const Offset(0, 4),
        ),
      ],
    );
  }

  /// Player card decoration with gradient
  static BoxDecoration playerCardDecoration({
    Color dominantColor = const Color(0xFF282828),
  }) {
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          dominantColor.withValues(alpha: 0.6),
          _darkenColor(dominantColor, 0.3),
          const Color(0xFF121212),
        ],
      ),
      borderRadius: BorderRadius.circular(16),
      boxShadow: [
        BoxShadow(
          color: dominantColor.withValues(alpha: 0.4),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
      ],
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Animations
  // ──────────────────────────────────────────────────────────────────────────

  /// Standard duration for micro-interactions
  static const Duration microDuration = Duration(milliseconds: 150);

  /// Standard duration for page transitions
  static const Duration pageTransitionDuration = Duration(milliseconds: 300);

  /// Standard duration for large animations
  static const Duration largeDuration = Duration(milliseconds: 500);

  /// Curve for smooth animations
  static const Curve defaultCurve = Curves.easeInOut;

  /// Curve for bouncy animations
  static const Curve bounceCurve = Curves.elasticOut;

  /// Curve for sharp animations
  static const Curve sharpCurve = Curves.easeOut;

  // ──────────────────────────────────────────────────────────────────────────
  // Text Styles
  // ──────────────────────────────────────────────────────────────────────────

  static const TextStyle headingLarge = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.bold,
    color: textPrimary,
    letterSpacing: -0.5,
  );

  static const TextStyle headingMedium = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.bold,
    color: textPrimary,
    letterSpacing: -0.3,
  );

  static const TextStyle headingSmall = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );

  static const TextStyle bodyLarge = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.normal,
    color: textPrimary,
  );

  static const TextStyle bodyMedium = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.normal,
    color: textSecondary,
  );

  static const TextStyle bodySmall = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.normal,
    color: textTertiary,
  );

  static const TextStyle labelLarge = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: textPrimary,
    letterSpacing: 0.5,
  );

  static const TextStyle labelMedium = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: textSecondary,
    letterSpacing: 0.3,
  );

  // ──────────────────────────────────────────────────────────────────────────
  // Icon Styles
  // ──────────────────────────────────────────────────────────────────────────

  /// Yandex Music-style icons
  static const IconData homeIcon = Icons.home_rounded;
  static const IconData searchIcon = Icons.search_rounded;
  static const IconData libraryIcon = Icons.library_music_rounded;
  static const IconData profileIcon = Icons.person_rounded;

  /// Player control icons
  static const IconData playIcon = Icons.play_arrow_rounded;
  static const IconData pauseIcon = Icons.pause_rounded;
  static const IconData skipNextIcon = Icons.skip_next_rounded;
  static const IconData skipPreviousIcon = Icons.skip_previous_rounded;
  static const IconData shuffleIcon = Icons.shuffle_rounded;
  static const IconData shuffleActiveIcon = Icons.shuffle_on_rounded;
  static const IconData repeatIcon = Icons.repeat_rounded;
  static const IconData repeatActiveIcon = Icons.repeat_on_rounded;
  static const IconData repeatOneIcon = Icons.repeat_one_rounded;
  static const IconData favoriteIcon = Icons.favorite_border_rounded;
  static const IconData favoriteActiveIcon = Icons.favorite_rounded;
  static const IconData shareIcon = Icons.share_rounded;
  static const IconData moreIcon = Icons.more_horiz_rounded;

  /// Navigation icons
  static const IconData backIcon = Icons.arrow_back_ios_new_rounded;
  static const IconData forwardIcon = Icons.arrow_forward_ios_rounded;
  static const IconData closeIcon = Icons.close_rounded;

  /// Action icons
  static const IconData downloadIcon = Icons.download_rounded;
  static const IconData downloadDoneIcon = Icons.download_done_rounded;
  static const IconData addToQueueIcon = Icons.queue_music_rounded;
  static const IconData addToPlaylistIcon = Icons.playlist_add_rounded;

  // ──────────────────────────────────────────────────────────────────────────
  // Helper Methods
  // ──────────────────────────────────────────────────────────────────────────

  /// Darken a color by a factor (0-1)
  static Color _darkenColor(Color color, double factor) {
    final hsl = HSLColor.fromColor(color);
    final darkened = hsl.withLightness((hsl.lightness * (1 - factor)).clamp(0.0, 1.0));
    return darkened.toColor();
  }

  /// Lighten a color by a factor (0-1)
  static Color lightenColor(Color color, double factor) {
    final hsl = HSLColor.fromColor(color);
    final lightened = hsl.withLightness((hsl.lightness + (1 - hsl.lightness) * factor).clamp(0.0, 1.0));
    return lightened.toColor();
  }

  /// Get contrasting text color for a background
  static Color getContrastingTextColor(Color backgroundColor) {
    final luminance = backgroundColor.computeLuminance();
    return luminance > 0.5 ? Colors.black : Colors.white;
  }

  /// Create color with opacity (Flutter 3.x compatible)
  static Color withAlpha(Color color, double opacity) {
    return color.withValues(alpha: opacity);
  }
}
