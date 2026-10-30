import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../widgets/app_gradient_background.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import '../models/models.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../services/subsonic_service.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';
import '../utils/screen_helper.dart';
import '../widgets/song_tile.dart';

/// Страница всех треков артиста.
/// Открывается по тапу "Ещё" у ТОП треков на ArtistScreen.
/// Показывает полный список с градиентом по жанру и кнопками Слушать/Перемешать.
class ArtistAllTracksScreen extends StatefulWidget {
  final String artistId;
  final String artistName;
  final String? coverArt;
  final List<Song> initialTracks;

  const ArtistAllTracksScreen({
    super.key,
    required this.artistId,
    required this.artistName,
    this.coverArt,
    this.initialTracks = const [],
  });

  @override
  State<ArtistAllTracksScreen> createState() => _ArtistAllTracksScreenState();
}

class _ArtistAllTracksScreenState extends State<ArtistAllTracksScreen> {
  List<Song> _tracks = [];
  bool _isLoading = true;

  // жанровый градиент — как у Плейлиста дня / GenreMix
  static const Map<String, List<Color>> _genreColors = {
    'Rock': [Color(0xFFDC2626), Color(0xFFEA580C)],
    'Metal': [Color(0xFF374151), Color(0xFF111827)],
    'Pop': [Color(0xFFEC4899), Color(0xFF8B5CF6)],
    'Hip-Hop': [Color(0xFFF59E0B), Color(0xFFDC2626)],
    'Electronic': [Color(0xFF3B82F6), Color(0xFF8B5CF6)],
    'Jazz': [Color(0xFFB45309), Color(0xFFD97706)],
    'Classical': [Color(0xFF4338CA), Color(0xFF6D28D9)],
    'R&B': [Color(0xFF7C3AED), Color(0xFFDB2777)],
    'Latin': [Color(0xFFDC2626), Color(0xFFF59E0B)],
    'Indie': [Color(0xFF10B981), Color(0xFF059669)],
    'Folk': [Color(0xFF15803D), Color(0xFF059669)],
    'Rap': [Color(0xFFDC2626), Color(0xFFEA580C)],
    'Punk': [Color(0xFFEF4444), Color(0xFFDC2626)],
    'Reggae': [Color(0xFF22C55E), Color(0xFFEAB308)],
    'Blues': [Color(0xFF2563EB), Color(0xFF1D4ED8)],
    'Country': [Color(0xFFD97706), Color(0xFF92400E)],
    'Soundtrack': [Color(0xFF7C3AED), Color(0xFF4F46E5)],
    'Alternative': [Color(0xFF6366F1), Color(0xFF8B5CF6)],
    'K-Pop': [Color(0xFFF472B6), Color(0xFFA855F7)],
    'Dance': [Color(0xFF06B6D4), Color(0xFF3B82F6)],
    'House': [Color(0xFF8B5CF6), Color(0xFFA855F7)],
    'Techno': [Color(0xFF6B7280), Color(0xFF4B5563)],
    'Ambient': [Color(0xFF38BDF8), Color(0xFF22D3EE)],
    'Lo-fi': [Color(0xFFC084FC), Color(0xFFF472B6)],
  };

  List<Color> _colorsForGenre(String genre) {
    if (_genreColors.containsKey(genre)) return _genreColors[genre]!;
    final norm = genre.trim().toLowerCase();
    for (final e in _genreColors.entries) {
      if (e.key.toLowerCase() == norm) return e.value;
    }
    for (final e in _genreColors.entries) {
      final k = e.key.toLowerCase();
      if (norm.contains(k) || k.contains(norm)) return e.value;
    }
    final hue = (norm.hashCode % 360).abs().toDouble();
    final c1 = HSLColor.fromAHSL(1.0, hue, 0.78, 0.52).toColor();
    final c2 = HSLColor.fromAHSL(1.0, (hue + 28) % 360, 0.82, 0.48).toColor();
    return [c1, c2];
  }

  // Градиент как у всех — по выбранному цвету пользователя (ThemeService.accentColor), а не по жанру
  List<Color> _buildGradient(BuildContext context) {
    try {
      final accent = Provider.of<ThemeService>(context, listen: false).accentColor.color;
      final second = HSLColor.fromColor(accent).withLightness((HSLColor.fromColor(accent).lightness - 0.12).clamp(0.0, 1.0)).toColor();
      return [accent, second];
    } catch (_) {}
    // фолбек — жанровый градиент
    if (_tracks.isEmpty) return [const Color(0xFF7C3AED), const Color(0xFF4F46E5)];
    final counts = <String, int>{};
    for (final s in _tracks) {
      final g = (s.genre ?? '').trim();
      if (g.isEmpty) continue;
      counts[g] = (counts[g] ?? 0) + 1;
    }
    if (counts.isEmpty) return [const Color(0xFF7C3AED), const Color(0xFF4F46E5)];
    final sorted = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    if (sorted.length == 1) return _colorsForGenre(sorted.first.key);
    final c1 = _colorsForGenre(sorted[0].key)[0];
    final c2 = _colorsForGenre(sorted[1].key)[0];
    if (c1 == c2) return _colorsForGenre(sorted[0].key);
    return [c1, c2];
  }

  @override
  void initState() {
    super.initState();
    _tracks = List<Song>.from(widget.initialTracks);
    _loadAllTracks();
  }

  Future<void> _loadAllTracks() async {
    final libraryProvider = Provider.of<LibraryProvider>(context, listen: false);
    final subsonic = libraryProvider.subsonicService;

    try {
      // 1) БД: все песни артиста по индексу artistId (было: скан 80к кэша)
      List<Song> cached;
      try {
        cached = await libraryProvider.getSongsByArtistId(widget.artistId, limit: 1000);
        if (cached.isEmpty) {
          cached = (await libraryProvider.getSongsPage(limit: 1000, offset: 0, sort: 'titleAsc'))
              .where((s) => (s.artist ?? '').toLowerCase() == widget.artistName.toLowerCase())
              .toList();
        }
      } catch (_) {
        cached = libraryProvider.cachedAllSongs.where((s) {
          if (s.artistId != null && s.artistId == widget.artistId) return true;
          if ((s.artist ?? '').toLowerCase() == widget.artistName.toLowerCase()) return true;
          return false;
        }).toList();
      }

      final seen = _tracks.map((e) => e.id).toSet();
      final merged = List<Song>.from(_tracks);
      for (final s in cached) {
        if (seen.add(s.id)) merged.add(s);
      }

      // 2) Если локальный режим — достаточно кэша
      if (libraryProvider.isLocalOnlyMode) {
        if (mounted) setState(() { _tracks = merged; _isLoading = false; });
        return;
      }

      // 3) Сетевой добираем: альбомы артиста → треки альбомов (параллельно по 5)
      List<Album> albums = [];
      try {
        albums = await subsonic.getArtistAlbums(widget.artistId).timeout(const Duration(seconds: 6), onTimeout: () => <Album>[]);
      } catch (_) {
        albums = [];
      }

      if (albums.isNotEmpty) {
        // дополняем кэш по альбомам
        for (var i = 0; i < albums.length; i += 5) {
          final chunk = albums.sublist(i, (i + 5).clamp(0, albums.length));
          try {
            final results = await Future.wait(chunk.map((a) => subsonic.getAlbumSongs(a.id).timeout(const Duration(seconds: 6), onTimeout: () => <Song>[])));
            for (final list in results) {
              for (final s in list) {
                if (seen.add(s.id)) merged.add(s);
              }
            }
          } catch (_) {}
          if (merged.length >= 80) break;
        }
      }

      // 4) Фолбек: если всё ещё мало — добираем по topSongs с сервера
      if (merged.length < 15) {
        try {
          final top = await subsonic.getArtistTopSongs(widget.artistId).timeout(const Duration(seconds: 6), onTimeout: () => <Song>[]);
          for (final s in top) {
            if (seen.add(s.id)) merged.add(s);
          }
        } catch (_) {}
      }

      if (mounted) setState(() { _tracks = merged; _isLoading = false; });
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _playAll({bool shuffle = false}) {
    if (_tracks.isEmpty) return;
    final player = Provider.of<PlayerProvider>(context, listen: false);
    var list = List<Song>.from(_tracks);
    if (shuffle) list.shuffle();
    player.playSong(list.first, playlist: list, startIndex: 0);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final gradient = _buildGradient(context);

    if (_isLoading && _tracks.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(backgroundColor: isDark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82)),
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Shimmer.fromColors(
                  baseColor: isDark ? AppTheme.darkCard : const Color(0xFFE0E0E0),
                  highlightColor: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5),
                  child: Column(children: [
                    Container(width: 160, height: 160, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12))),
                    const SizedBox(height: 16),
                    Container(width: 180, height: 18, color: Colors.white),
                  ]),
                ),
              ),
            ),
            SliverList(delegate: SliverChildBuilderDelegate((_, __) => const _TrackShimmer(), childCount: 10)),
          ],
        ),
      );
    }

    return Scaffold(
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: ScreenHelper.isSmallScreen(context) ? 320 : 380,
            backgroundColor: Colors.black,
            leading: Padding(
              padding: const EdgeInsets.all(8),
              child: CircleAvatar(
                backgroundColor: Colors.black.withValues(alpha: 0.4),
                child: IconButton(icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 20), onPressed: () => Navigator.pop(context)),
              ),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  // Градиент по жанру
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: gradient, begin: Alignment.topLeft, end: Alignment.bottomRight),
                    ),
                  ),
                  // Скрим для читаемости
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black.withValues(alpha: 0.08), Colors.black.withValues(alpha: 0.65)]),
                    ),
                  ),
                  // Артист обложка по центру — увеличенный круг + кольцо-градиент по жанру
                  Center(
                    child: Padding(
                      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 30, bottom: 70),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Builder(builder: (ctx) {
                            // кольцо по доминирующему жанру
                            String? domGenre;
                            if (_tracks.isNotEmpty) {
                              final counts = <String, int>{};
                              for (final s in _tracks) {
                                final g = (s.genre ?? '').trim();
                                if (g.isEmpty) continue;
                                counts[g] = (counts[g] ?? 0) + 1;
                              }
                              if (counts.isNotEmpty) {
                                final sorted = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
                                domGenre = sorted.first.key;
                              }
                            }
                            final ringColors = domGenre != null ? _colorsForGenre(domGenre) : gradient;
                            final isSmall = ScreenHelper.isSmallScreen(context);
                            final innerSize = isSmall ? 164.0 : 188.0;
                            final outerSize = innerSize + 8; // кольцо 4px
                            return Container(
                              width: outerSize,
                              height: outerSize,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(colors: ringColors, begin: Alignment.topLeft, end: Alignment.bottomRight),
                                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 8))],
                              ),
                              padding: const EdgeInsets.all(4),
                              child: Container(
                                decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black),
                                clipBehavior: Clip.antiAlias,
                                child: widget.coverArt != null && widget.coverArt!.isNotEmpty
                                    ? CachedNetworkImage(
                                        imageUrl: Provider.of<SubsonicService>(context, listen: false).getCoverArtUrl(widget.coverArt!, size: 400),
                                        fit: BoxFit.cover,
                                        placeholder: (_, __) => Container(color: Colors.grey[900]),
                                        errorWidget: (_, __, ___) => Container(color: Colors.grey[800], child: const Icon(Icons.person_rounded, color: Colors.white24, size: 48)),
                                      )
                                    : Container(color: Colors.grey[800], child: const Icon(Icons.person_rounded, color: Colors.white24, size: 48)),
                              ),
                            );
                          }),
                          const SizedBox(height: 14),
                          Text(widget.artistName, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, shadows: [Shadow(color: Colors.black54, blurRadius: 8)]), maxLines: 1, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 4),
                          Text('${_tracks.length} треков', style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 13, shadows: const [Shadow(color: Colors.black54, blurRadius: 4)])),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Row(children: [
                Expanded(child: _PlayButton(icon: CupertinoIcons.play_fill, label: 'Слушать', color: gradient[0], onTap: () => _playAll())),
                const SizedBox(width: 12),
                Expanded(child: _PlayButton(icon: CupertinoIcons.shuffle, label: 'Перемешать', color: gradient.length > 1 ? gradient[1] : gradient[0], onTap: () => _playAll(shuffle: true))),
              ]),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          if (_tracks.isEmpty)
            SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(32), child: Center(child: Text('Нет треков', style: TextStyle(color: Colors.grey[600])))))
          else
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final song = _tracks[index];
                return SongTile(song: song, playlist: _tracks, index: index, showAlbum: true, showArtist: false);
              }, childCount: _tracks.length),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _PlayButton({required this.icon, required this.label, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: color.withValues(alpha: isDark ? 0.18 : 0.12),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 13),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Icon(icon, color: Colors.white, size: 16),
            ),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }
}

class _TrackShimmer extends StatelessWidget {
  const _TrackShimmer();
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Shimmer.fromColors(
        baseColor: isDark ? AppTheme.darkCard : const Color(0xFFE0E0E0),
        highlightColor: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5),
        child: Row(children: [
          Container(width: 40, height: 40, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(4))),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Container(height: 12, color: Colors.white), const SizedBox(height: 6), Container(width: 120, height: 10, color: Colors.white)])),
        ]),
      ),
    );
  }
}
