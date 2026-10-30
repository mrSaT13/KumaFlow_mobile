import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../widgets/app_gradient_background.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import '../models/models.dart';
import '../providers/player_provider.dart' as pp;
import '../services/subsonic_service.dart';
import '../services/audiobookshelf_service.dart';
import '../services/theme_service.dart';
import '../services/storage_service.dart';
import '../theme/yandex_music_theme.dart';
import '../widgets/kion_queue_sheet.dart';
import '../widgets/album_artwork.dart' show isLocalFilePath;

/// Yandex Music-style player screen with working controls.
class YandexMusicPlayerScreen extends StatefulWidget {
  const YandexMusicPlayerScreen({super.key});

  @override
  State<YandexMusicPlayerScreen> createState() => _YandexMusicPlayerScreenState();
}

class _YandexMusicPlayerScreenState extends State<YandexMusicPlayerScreen> {
  Color _dominantColor = const Color(0xFF282828);
  Color _accentColor = const Color(0xFF121212);
  String? _lastCoverArt;
  bool _extracting = false;

  String _resolveImageUrl(Song? song) {
    if (song == null) return '';
    final ca = song.coverArt;
    if (ca == null || ca.isEmpty) return '';
    if (ca.startsWith('http://') || ca.startsWith('https://')) return ca;
    if (isLocalFilePath(ca)) return ca;
    if (ca.startsWith('abs:')) return AudiobookshelfService().getCoverUrl(ca.substring(4), width: 400);
    final svc = Provider.of<SubsonicService>(context, listen: false);
    return svc.getCoverArtUrl(ca, size: 400);
  }

  ImageProvider? _resolveImageProvider(String url) {
    if (url.isEmpty) return null;
    if (isLocalFilePath(url)) {
      final f = File(url);
      if (!f.existsSync()) return null;
      return FileImage(f);
    }
    if (url.startsWith('http')) return NetworkImage(url);
    return null;
  }

  Future<void> _extractColors(String imageUrl) async {
    if (imageUrl.isEmpty || _extracting) return;
    final provider = _resolveImageProvider(imageUrl);
    if (provider == null) return;
    _extracting = true;
    try {
      final paletteGenerator = await PaletteGenerator.fromImageProvider(
        provider,
        size: const Size(112, 112),
        maximumColorCount: 8,
      );
      if (mounted && _lastCoverArt == imageUrl) {
        setState(() {
          _dominantColor = paletteGenerator.dominantColor?.color ?? const Color(0xFF282828);
          _accentColor = paletteGenerator.vibrantColor?.color ?? const Color(0xFF121212);
        });
      }
    } catch (_) {}
    _extracting = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final song = Provider.of<pp.PlayerProvider>(context).currentSong;
    final url = _resolveImageUrl(song);
    if (url != _lastCoverArt) {
      _lastCoverArt = url;
      if (url.isNotEmpty) _extractColors(url);
    }
  }

  @override
  Widget build(BuildContext context) {
    final playerProvider = Provider.of<pp.PlayerProvider>(context);
    final currentSong = playerProvider.currentSong;
    final isPlaying = playerProvider.isPlaying;
    final subsonicService = Provider.of<SubsonicService>(context, listen: false);

    // Sync palette when song changes (outside build loop via post-frame)
    final curUrl = _resolveImageUrl(currentSong);
    if (curUrl != _lastCoverArt) {
      _lastCoverArt = curUrl;
      if (curUrl.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _extractColors(curUrl));
      }
    }

    return Scaffold(backgroundColor: Colors.transparent, 
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _dominantColor.withValues(alpha: 0.8),
              _darkenColor(_dominantColor, 0.3),
              const Color(0xFF121212),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Header
              _buildHeader(context, currentSong),
              // Album Art
              Expanded(
                child: _buildAlbumArt(context, currentSong, subsonicService),
              ),
              // Song Info
              _buildSongInfo(context, currentSong),
              const SizedBox(height: 16),
              // Progress Bar
              _buildProgressBar(context, playerProvider, currentSong),
              const SizedBox(height: 16),
              // Controls - MAIN FIX: Simple working buttons
              _buildControls(context, playerProvider, isPlaying),
              const SizedBox(height: 16),
              // Bottom Actions
              _buildBottomActions(context, playerProvider, currentSong),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, Song? currentSong) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 32),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Column(
            children: [
              Text(
                'NOW PLAYING',
                style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.6), letterSpacing: 1),
              ),
              const SizedBox(height: 2),
              Text(
                currentSong?.album ?? 'Queue',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.more_vert_rounded, color: Colors.white, size: 24),
            onPressed: () {},
          ),
        ],
      ),
    );
  }

  Widget _buildAlbumArt(BuildContext context, Song? currentSong, SubsonicService subsonicService) {
    return Center(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.85,
        height: MediaQuery.of(context).size.width * 0.85,
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 400),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: _dominantColor.withValues(alpha: 0.6),
              blurRadius: 40,
              offset: const Offset(0, 20),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: _buildArtworkImage(currentSong),
        ),
      ),
    );
  }

  Widget _buildArtworkImage(Song? song) {
    if (song == null || song.coverArt == null || song.coverArt!.isEmpty) return _buildPlaceholderArt();
    final ca = song.coverArt!;
    if (ca.startsWith('http://') || ca.startsWith('https://')) {
      return CachedNetworkImage(imageUrl: ca, fit: BoxFit.cover, errorWidget: (_, __, ___) => _buildPlaceholderArt());
    }
    if (isLocalFilePath(ca)) {
      final f = File(ca);
      if (!f.existsSync()) return _buildPlaceholderArt();
      return Image.file(f, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _buildPlaceholderArt());
    }
    if (ca.startsWith('abs:')) {
      final url = AudiobookshelfService().getCoverUrl(ca.substring(4), width: 500);
      final headers = AudiobookshelfService().authHeaders;
      return CachedNetworkImage(imageUrl: url, httpHeaders: headers, fit: BoxFit.cover, errorWidget: (_, __, ___) => _buildPlaceholderArt());
    }
    final svc = Provider.of<SubsonicService>(context, listen: false);
    final url = svc.getCoverArtUrl(ca, size: 500);
    return CachedNetworkImage(imageUrl: url, fit: BoxFit.cover, errorWidget: (_, __, ___) => _buildPlaceholderArt());
  }

  Widget _buildPlaceholderArt() {
    return Container(
      color: YandexMusicTheme.darkElevated,
      child: const Center(
        child: Icon(Icons.music_note_rounded, size: 80, color: YandexMusicTheme.textTertiary),
      ),
    );
  }

  Widget _buildSongInfo(BuildContext context, Song? currentSong) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Text(
            currentSong?.title ?? 'No track',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Text(
            currentSong?.artist ?? 'Unknown Artist',
            style: TextStyle(fontSize: 16, color: Colors.white.withValues(alpha: 0.7)),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar(BuildContext context, pp.PlayerProvider playerProvider, Song? currentSong) {
    final position = playerProvider.position;
    final duration = currentSong?.duration != null ? Duration(seconds: currentSong!.duration!) : Duration.zero;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: position.inSeconds.toDouble().clamp(0, duration.inSeconds.toDouble()),
              max: duration.inSeconds.toDouble() > 0 ? duration.inSeconds.toDouble() : 1,
              onChanged: (value) => playerProvider.seek(Duration(seconds: value.toInt())),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formatDuration(position), style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.6))),
                Text(_formatDuration(duration), style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.6))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// MAIN FIX: Simple working controls with proper GestureDetector
  Widget _buildControls(BuildContext context, pp.PlayerProvider playerProvider, bool isPlaying) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Dislike (broken heart)
          GestureDetector(
            onTap: () async {
              final song = playerProvider.currentSong;
              if (song == null) return;
              HapticFeedback.lightImpact();
              final storageService = Provider.of<StorageService>(context, listen: false);
              await storageService.saveDislike(song.id, true);
              final artistBanned = await playerProvider.dislikeAndSkip(song);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(artistBanned
                        ? 'Артист скрыт (3 дизлайка) — будет исключён'
                        : 'Пропущен — будет исключён из рекомендаций'),
                    duration: Duration(seconds: 1),
                  ),
                );
              }
            },
            child: Icon(
              Icons.heart_broken_rounded,
              color: Colors.white.withValues(alpha: 0.7),
              size: 28,
            ),
          ),

          // Previous
          GestureDetector(
            onTap: () => playerProvider.skipPrevious(),
            child: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 40),
          ),

          // Play/Pause
          GestureDetector(
            onTap: () => playerProvider.togglePlayPause(),
            child: Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
              ),
              child: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 36,
                color: Colors.black,
              ),
            ),
          ),

          // Next
          GestureDetector(
            onTap: () => playerProvider.skipNext(),
            child: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 40),
          ),

          // Like (heart)
          GestureDetector(
            onTap: () {
              if (playerProvider.currentSong != null) {
                HapticFeedback.lightImpact();
                playerProvider.toggleFavorite();
              }
            },
            child: Icon(
              playerProvider.currentSong?.starred == true
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              color: playerProvider.currentSong?.starred == true
                  ? YandexMusicTheme.accentRed
                  : Colors.white.withValues(alpha: 0.7),
              size: 28,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomActions(BuildContext context, pp.PlayerProvider playerProvider, Song? currentSong) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Shuffle
          GestureDetector(
            onTap: () => playerProvider.toggleShuffle(),
            child: Icon(
              playerProvider.shuffleEnabled ? Icons.shuffle_on_rounded : Icons.shuffle_rounded,
              color: playerProvider.shuffleEnabled ? YandexMusicTheme.accentRed : Colors.white.withValues(alpha: 0.7),
              size: 24,
            ),
          ),

          // Repeat
          GestureDetector(
            onTap: () => playerProvider.toggleRepeat(),
            child: Icon(
              playerProvider.repeatMode == pp.RepeatMode.one
                  ? Icons.repeat_one_rounded
                  : (playerProvider.repeatMode != pp.RepeatMode.off
                      ? Icons.repeat_on_rounded
                      : Icons.repeat_rounded),
              color: playerProvider.repeatMode != pp.RepeatMode.off
                  ? YandexMusicTheme.accentRed
                  : Colors.white.withValues(alpha: 0.7),
              size: 24,
            ),
          ),

          // Queue
          GestureDetector(
            onTap: () {
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => const KionQueueSheet(),
              );
            },
            child: Icon(Icons.queue_music_rounded, color: Colors.white.withValues(alpha: 0.7), size: 24),
          ),

          // Sleep timer
          GestureDetector(
            onTap: () {
              final player = context.read<pp.PlayerProvider>();
              showModalBottomSheet(
                context: context,
                backgroundColor: Colors.transparent,
                isScrollControlled: true,
                builder: (sheetCtx) {
                  bool endCurrentSong = player.sleepTimerEndCurrentSong;
                  bool fadeOut = player.sleepTimerFadeOut;
                  int fadeOutSeconds = player.sleepTimerFadeDurationSeconds;
                  return StatefulBuilder(
                    builder: (ctx, setSt) => Container(
                      decoration: const BoxDecoration(
                        color: Color(0xFF282828),
                        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(height: 8),
                            Container(
                              width: 36, height: 5,
                              decoration: BoxDecoration(
                                color: Colors.white24,
                                borderRadius: BorderRadius.circular(2.5),
                              ),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'Таймер сна',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                            const Divider(color: Colors.white12, height: 24),
                            ...[
                              ('15 мин', const Duration(minutes: 15)),
                              ('30 мин', const Duration(minutes: 30)),
                              ('45 мин', const Duration(minutes: 45)),
                              ('1 час', const Duration(hours: 1)),
                              ('2 часа', const Duration(hours: 2)),
                            ].map(
                              (opt) => ListTile(
                                title: Text(opt.$1, style: const TextStyle(color: Colors.white)),
                                onTap: () {
                                  Navigator.pop(sheetCtx);
                                  player.setSleepTimer(opt.$2);
                                },
                              ),
                            ),
                            if (player.hasSleepTimer)
                              ListTile(
                                leading: const Icon(Icons.timer_off_rounded, color: YandexMusicTheme.accentRed),
                                title: const Text('Отменить таймер', style: TextStyle(color: YandexMusicTheme.accentRed)),
                                onTap: () {
                                  Navigator.pop(sheetCtx);
                                  player.setSleepTimer(Duration.zero);
                                },
                              ),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
            child: Icon(
              Icons.timer_outlined,
              color: playerProvider.hasSleepTimer ? YandexMusicTheme.accentRed : Colors.white.withValues(alpha: 0.7),
              size: 24,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Color _darkenColor(Color color, double factor) {
    final hsl = HSLColor.fromColor(color);
    return hsl.withLightness((hsl.lightness * (1 - factor)).clamp(0.0, 1.0)).toColor();
  }
}
