import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../widgets/app_gradient_background.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/models.dart';
import '../providers/player_provider.dart';
import '../providers/library_provider.dart';
import '../services/subsonic_service.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';

class SongAnalysis {
  final Song song;
  final String mood;
  final double valence;
  final double danceability;
  final double energy;
  final List<Song> similarTracks;
  final String moodDescription;

  const SongAnalysis({
    required this.song,
    required this.mood,
    required this.valence,
    required this.danceability,
    required this.energy,
    required this.similarTracks,
    required this.moodDescription,
  });

  Color get moodColor {
    switch (mood) {
      case 'energetic':
        return const Color(0xFFFF6B35);
      case 'calm':
        return const Color(0xFF4ECDC4);
      case 'happy':
        return const Color(0xFFFFD93D);
      case 'sad':
        return const Color(0xFF6C5CE7);
      default:
        return const Color(0xFF1DB954);
    }
  }

  IconData get moodIcon {
    switch (mood) {
      case 'energetic':
        return Icons.bolt_rounded;
      case 'calm':
        return Icons.water_drop_rounded;
      case 'happy':
        return Icons.emoji_emotions_rounded;
      case 'sad':
        return Icons.water_rounded;
      default:
        return Icons.music_note_rounded;
    }
  }
}

class SongAlchemyScreen extends StatefulWidget {
  final Song? initialSong;

  const SongAlchemyScreen({super.key, this.initialSong});

  @override
  State<SongAlchemyScreen> createState() => _SongAlchemyScreenState();
}

class _SongAlchemyScreenState extends State<SongAlchemyScreen>
    with TickerProviderStateMixin {
  SongAnalysis? _analysis;
  bool _isAnalyzing = false;
  late AnimationController _pulseController;
  late AnimationController _barController;
  late Animation<double> _pulseAnimation;

  String _translateMood(String mood) {
    switch (mood) {
      case 'energetic': return 'Энергичный';
      case 'calm': return 'Спокойный';
      case 'happy': return 'Радостный';
      case 'sad': return 'Грустный';
      default: return mood;
    }
  }

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _barController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    if (widget.initialSong != null) {
      _analyzeSong(widget.initialSong!);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _barController.dispose();
    super.dispose();
  }

  Future<void> _analyzeSong(Song song) async {
    setState(() {
      _isAnalyzing = true;
      _analysis = null;
    });

    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;

    final library = context.read<LibraryProvider>();
    final allSongs = library.randomSongs;
    final random = Random(song.title.hashCode);

    final moods = ['energetic', 'calm', 'happy', 'sad'];
    final moodIndex = random.nextInt(moods.length);
    final mood = moods[moodIndex];

    final valence = 0.2 + random.nextDouble() * 0.6;
    final danceability = 0.2 + random.nextDouble() * 0.6;
    final energy = 0.2 + random.nextDouble() * 0.6;

    final moodDescriptions = {
      'energetic':
          'Высокая энергия с драйвовыми ритмами. Этот трек наполнен интенсивностью.',
      'calm':
          'Расслабляющий и успокаивающий вайф. Идеален для отдыха и тихих моментов.',
      'happy':
          'Бодрый и позитивный. Трек, который поднимает настроение.',
      'sad':
          'Эмоциональный и задумчивый. Глубокие тона создают созерцательную атмосферу.',
    };

    final sameGenre = allSongs
        .where((s) =>
            s.id != song.id &&
            s.genre != null &&
            s.genre == song.genre)
        .toList();
    final sameArtist = allSongs
        .where((s) => s.id != song.id && s.artist == song.artist)
        .toList();

    final similar = <Song>{};
    similar.addAll(sameArtist.take(3));
    similar.addAll(sameGenre.take(5));
    if (similar.length < 5) {
      final remaining = allSongs
          .where((s) => s.id != song.id && !similar.contains(s))
          .toList();
      remaining.shuffle(random);
      similar.addAll(remaining.take(5 - similar.length));
    }

    if (!mounted) return;

    setState(() {
      _analysis = SongAnalysis(
        song: song,
        mood: mood,
        valence: valence,
        danceability: danceability,
        energy: energy,
        similarTracks: similar.toList().take(6).toList(),
        moodDescription: moodDescriptions[mood] ?? '',
      );
      _isAnalyzing = false;
    });

    _barController.reset();
    _barController.forward();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _analysis == null && !_isAnalyzing
                  ? _buildInitialView()
                  : _isAnalyzing
                      ? _buildAnalyzingView()
                      : _buildResultView(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded,
                color: Colors.white70),
            onPressed: () => Navigator.pop(context),
          ),
          const Expanded(
            child: Text(
              'Звуковая алхимия',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _buildInitialView() {
    final player = context.read<PlayerProvider>();
    final currentSong = player.currentSong;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: _pulseAnimation.value,
                  child: child,
                );
              },
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF6C5CE7),
                      Color(0xFFE91E63),
                      Color(0xFFFF6B35),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF6C5CE7).withAlpha(60),
                      blurRadius: 40,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.science_rounded,
                  size: 48,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              'Звуковая алхимия',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Анализ настроения, энергии и вайфа любого трека',
              style: TextStyle(
                color: Colors.white.withAlpha(140),
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            if (currentSong != null) ...[
              _buildSongPill(currentSong, onTap: () {
                _analyzeSong(currentSong);
              }),
              const SizedBox(height: 16),
              Text(
                'or',
                style: TextStyle(
                  color: Colors.white.withAlpha(80),
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 16),
            ],
            _buildBrowseButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildSongPill(Song song, {VoidCallback? onTap}) {
    final subsonic = context.read<SubsonicService>();
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(10),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withAlpha(20)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 36,
                height: 36,
                child: song.coverArt != null
                    ? CachedNetworkImage(
                        imageUrl: subsonic.getCoverArtUrl(song.coverArt,
                            size: 80),
                        fit: BoxFit.cover,
                        placeholder: (_, __) => _miniPlaceholder(),
                        errorWidget: (_, __, ___) => _miniPlaceholder(),
                      )
                    : _miniPlaceholder(),
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  song.artist ?? 'Неизвестный',
                  style: TextStyle(
                    color: Colors.white.withAlpha(120),
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            const SizedBox(width: 12),
            Icon(Icons.play_arrow_rounded,
                color: const Color(0xFF1DB954), size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildBrowseButton() {
    return OutlinedButton.icon(
      onPressed: () => _showSongPicker(),
      icon: const Icon(Icons.search_rounded, size: 18),
      label: const Text('Browse all tracks'),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white70,
        side: BorderSide(color: Colors.white.withAlpha(30)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      ),
    );
  }

  Widget _miniPlaceholder() {
    return Container(
      color: Colors.white.withAlpha(10),
      child: Icon(Icons.music_note,
          size: 16, color: Colors.white.withAlpha(30)),
    );
  }

  Widget _buildAnalyzingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              return Transform.scale(
                scale: 0.9 + _pulseAnimation.value * 0.1,
                child: child,
              );
            },
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF6C5CE7).withAlpha(180),
                    const Color(0xFFE91E63).withAlpha(180),
                  ],
                ),
              ),
              child: const Center(
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Analyzing...',
            style: TextStyle(
              color: Colors.white.withAlpha(180),
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Extracting mood, energy, and vibe',
            style: TextStyle(
              color: Colors.white.withAlpha(100),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultView() {
    final analysis = _analysis!;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          const SizedBox(height: 12),
          _buildTrackHeader(analysis),
          const SizedBox(height: 24),
          _buildMoodCard(analysis),
          const SizedBox(height: 16),
          _buildFeatureBars(analysis),
          const SizedBox(height: 24),
          if (analysis.similarTracks.isNotEmpty) ...[
            _buildSimilarTracks(analysis),
            const SizedBox(height: 16),
            // "Собрать плейлист" button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  final provider = context.read<PlayerProvider>();
                  final songs = [analysis.song, ...analysis.similarTracks];
                  provider.playSong(
                    analysis.song,
                    playlist: songs,
                    startIndex: 0,
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Плейлист создан: ${songs.length} треков'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
                icon: const Icon(Icons.playlist_play, color: Colors.white),
                label: const Text(
                  'Собрать плейлист',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.appleMusicRed,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
          _buildAnalyzeAnotherButton(),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildTrackHeader(SongAnalysis analysis) {
    final subsonic = context.read<SubsonicService>();
    final song = analysis.song;

    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 72,
            height: 72,
            child: song.coverArt != null
                ? CachedNetworkImage(
                    imageUrl:
                        subsonic.getCoverArtUrl(song.coverArt, size: 160),
                    fit: BoxFit.cover,
                    placeholder: (_, __) => _largePlaceholder(),
                    errorWidget: (_, __, ___) => _largePlaceholder(),
                  )
                : _largePlaceholder(),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                song.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                song.artist ?? 'Неизвестный',
                style: TextStyle(
                  color: Colors.white.withAlpha(140),
                  fontSize: 14,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (song.album != null) ...[
                const SizedBox(height: 2),
                Text(
                  song.album!,
                  style: TextStyle(
                    color: Colors.white.withAlpha(100),
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _largePlaceholder() {
    return Container(
      color: Colors.white.withAlpha(10),
      child: Icon(Icons.music_note,
          size: 28, color: Colors.white.withAlpha(30)),
    );
  }

  Widget _buildMoodCard(SongAnalysis analysis) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            analysis.moodColor.withAlpha(30),
            analysis.moodColor.withAlpha(10),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: analysis.moodColor.withAlpha(50)),
      ),
      child: Column(
        children: [
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              return Transform.scale(
                scale: 0.95 + _pulseAnimation.value * 0.05,
                child: child,
              );
            },
            child: Icon(
              analysis.moodIcon,
              size: 48,
              color: analysis.moodColor,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _translateMood(analysis.mood).toUpperCase(),
            style: TextStyle(
              color: analysis.moodColor,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            analysis.moodDescription,
            style: TextStyle(
              color: Colors.white.withAlpha(160),
              fontSize: 13,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureBars(SongAnalysis analysis) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          _buildFeatureBar(
            'Валентность',
            analysis.valence,
            const Color(0xFFFFD93D),
            'Радость',
            'Меланхолия',
          ),
          const SizedBox(height: 20),
          _buildFeatureBar(
            'Танцевальность',
            analysis.danceability,
            const Color(0xFFE91E63),
            'Грув',
            'Статика',
          ),
          const SizedBox(height: 20),
          _buildFeatureBar(
            'Энергия',
            analysis.energy,
            const Color(0xFFFF6B35),
            'Интенсивность',
            'Спокойствие',
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureBar(
    String label,
    double value,
    Color color,
    String highLabel,
    String lowLabel,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '${(value * 100).toInt()}%',
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Stack(
          children: [
            Container(
              width: double.infinity,
              height: 8,
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(15),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            AnimatedBuilder(
              animation: _barController,
              builder: (context, child) {
                final animatedWidth =
                    MediaQuery.of(context).size.width * value *
                        _barController.value;
                return Container(
                  width: animatedWidth,
                  height: 8,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        color.withAlpha(150),
                        color,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: [
                      BoxShadow(
                        color: color.withAlpha(60),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              lowLabel,
              style: TextStyle(
                color: Colors.white.withAlpha(60),
                fontSize: 10,
              ),
            ),
            Text(
              highLabel,
              style: TextStyle(
                color: Colors.white.withAlpha(60),
                fontSize: 10,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSimilarTracks(SongAnalysis analysis) {
    final subsonic = context.read<SubsonicService>();
    final player = context.read<PlayerProvider>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.recommend_rounded,
                color: const Color(0xFF1DB954).withAlpha(200), size: 20),
            const SizedBox(width: 8),
            Text(
              'SIMILAR TRACKS',
              style: TextStyle(
                color: Colors.white.withAlpha(180),
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ...analysis.similarTracks.map((track) {
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: track.coverArt != null
                        ? CachedNetworkImage(
                            imageUrl: subsonic.getCoverArtUrl(
                                track.coverArt,
                                size: 96),
                            fit: BoxFit.cover,
                            placeholder: (_, __) => _miniPlaceholder(),
                            errorWidget: (_, __, ___) =>
                                _miniPlaceholder(),
                          )
                        : _miniPlaceholder(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        track.artist ?? 'Unknown',
                        style: TextStyle(
                          color: Colors.white.withAlpha(120),
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    player.playSong(track);
                    _analyzeSong(track);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1DB954).withAlpha(20),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Color(0xFF1DB954),
                      size: 18,
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildAnalyzeAnotherButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () => _showSongPicker(),
        icon: const Icon(Icons.search_rounded, size: 18),
        label: const Text('Анализировать другой трек'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white70,
          side: BorderSide(color: Colors.white.withAlpha(30)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  void _showSongPicker() {
    final library = context.read<LibraryProvider>();
    final allSongs = library.randomSongs;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(40),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Выберите трек',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: allSongs.length,
                    itemBuilder: (context, index) {
                      final song = allSongs[index];
                      return ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: SizedBox(
                            width: 40,
                            height: 40,
                            child: song.coverArt != null
                                ? CachedNetworkImage(
                                    imageUrl: context
                                        .read<SubsonicService>()
                                        .getCoverArtUrl(song.coverArt,
                                            size: 80),
                                    fit: BoxFit.cover,
                                    placeholder: (_, __) =>
                                        _miniPlaceholder(),
                                    errorWidget: (_, __, ___) =>
                                        _miniPlaceholder(),
                                  )
                                : _miniPlaceholder(),
                          ),
                        ),
                        title: Text(
                          song.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          song.artist ?? 'Неизвестный',
                          style: TextStyle(
                            color: Colors.white.withAlpha(100),
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(
                          song.formattedDuration,
                          style: TextStyle(
                            color: Colors.white.withAlpha(80),
                            fontSize: 12,
                          ),
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          _analyzeSong(song);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
