import 'dart:io';
import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/theme_service.dart';
import '../widgets/app_gradient_background.dart';
import '../l10n/app_localizations.dart';
import '../models/genre.dart';
import '../providers/library_provider.dart';
import '../theme/app_theme.dart';
import '../utils/navigation_helper.dart';
import 'genre_screen.dart';

class GenresScreen extends StatefulWidget {
  const GenresScreen({super.key});

  @override
  State<GenresScreen> createState() => _GenresScreenState();
}

class _GenresScreenState extends State<GenresScreen> {
  List<Genre>? _genres;
  bool _isLoading = true;
  String? _error;
  // До двух обложек на жанр (URL), берутся из треков этого жанра.
  Map<String, List<String>> _genreCovers = {};

  @override
  void initState() {
    super.initState();
    _loadGenres();
  }

  Future<void> _loadGenres() async {
    try {
      final libraryProvider = Provider.of<LibraryProvider>(
        context,
        listen: false,
      );
      await libraryProvider.loadGenres();
      // Было: проход по 80к кэша. Стало: одна обложка на жанр из GROUP BY.
      final covers = <String, List<String>>{};
      try {
        final stats = await libraryProvider.getGenreStats();
        for (final row in stats) {
          final g = row['genre'] as String?;
          final ca = row['cover'] as String?;
          if (g == null || g.isEmpty || ca == null || ca.isEmpty) continue;
          try {
            final url = libraryProvider.getCoverArtUrl(ca);
            if (url.isEmpty) continue;
            covers.putIfAbsent(g, () => [url]);
          } catch (_) {}
        }
        if (covers.isEmpty) throw StateError('empty');
      } catch (_) {
        try {
          int filled = 0;
          final totalGenres = libraryProvider.richGenres.length;
          for (final s in libraryProvider.cachedAllSongs.take(5000)) {
            final g = s.genre;
            if (g == null || g.isEmpty) continue;
            final list = covers.putIfAbsent(g, () => <String>[]);
            if (list.length >= 2) continue;
            final ca = s.coverArt;
            if (ca == null || ca.isEmpty) continue;
            try {
              final url = libraryProvider.getCoverArtUrl(ca);
              if (url.isEmpty || list.contains(url)) continue;
              list.add(url);
              if (list.length == 2) filled++;
              if (totalGenres > 0 && filled >= totalGenres) break;
            } catch (_) {}
          }
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _genres = libraryProvider.richGenres;
          _genreCovers = covers;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(backgroundColor: Colors.transparent, 
      body: CustomScrollView(
        slivers: [
          SliverAppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),
            pinned: true,
            expandedHeight: 140,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(l10n.genres, style: theme.appBarTheme.titleTextStyle),
              titlePadding: const EdgeInsets.only(left: 52, bottom: 16),
            ),
          ),
          if (_isLoading)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(
                    12,
                    (_) => Container(
                      width: 100,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppTheme.lightDivider,
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                ),
              ),
            )
          else if (_error != null)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 64,
                      color: AppTheme.lightSecondaryText,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.errorLoadingGenres,
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _isLoading = true;
                          _error = null;
                        });
                        _loadGenres();
                      },
                      child: Text(l10n.retry),
                    ),
                  ],
                ),
              ),
            )
          else if (_genres == null || _genres!.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.library_music,
                      size: 64,
                      color: AppTheme.lightSecondaryText,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.noGenresFound,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ],
                ),
              ),
            )
          else
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _genres!
                      .map(
                        (genre) => _GenreChip(
                          genre: genre,
                          coverUrls:
                              _genreCovers[genre.value] ?? const <String>[],
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
      ),
    );
  }
}

class _GenreChip extends StatelessWidget {
  final Genre genre;
  final List<String> coverUrls;

  const _GenreChip({required this.genre, this.coverUrls = const <String>[]});

  Color _getGenreColor(String value) {
    final colors = [
      Colors.red,
      Colors.pink,
      Colors.purple,
      Colors.deepPurple,
      Colors.indigo,
      Colors.blue,
      Colors.lightBlue,
      Colors.cyan,
      Colors.teal,
      Colors.green,
      Colors.lightGreen,
      Colors.lime,
      Colors.amber,
      Colors.orange,
      Colors.deepOrange,
    ];
    final index = value.hashCode.abs() % colors.length;
    return colors[index];
  }

  Widget _cover(String url, double size) {
    final isFile = url.startsWith('/') ||
        (url.length > 2 && url[1] == ':') ||
        url.startsWith('file://');
    final radius = BorderRadius.circular(6);
    if (isFile) {
      final path =
          url.startsWith('file://') ? Uri.parse(url).toFilePath() : url;
      return ClipRRect(
        borderRadius: radius,
        child: Image.file(
          File(path),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      );
    }
    return ClipRRect(
      borderRadius: radius,
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => const SizedBox.shrink(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = _getGenreColor(genre.value);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;

    // Нет обложек — выглядит как раньше (компактный чип).
    if (coverUrls.isEmpty) {
      return Tooltip(
        message: l10n.genreTooltip(genre.songCount, genre.albumCount),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              NavigationHelper.push(context, GenreScreen(genre: genre.value));
            },
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: isDark ? 0.2 : 0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: color.withValues(alpha: 0.5),
                  width: 1,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    genre.value,
                    style: TextStyle(
                      color: isDark ? color.withValues(alpha: 0.9) : color,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  if (genre.songCount > 0)
                    Text(
                      l10n.songsCount(genre.songCount),
                      style: TextStyle(
                        color: (isDark ? color.withValues(alpha: 0.9) : color)
                            .withValues(alpha: 0.7),
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // Есть обложки — карточка по образцу Navic: текст ужался влево,
    // справа до двух повёрнутых обложек из треков этого жанра.
    final shown = coverUrls.take(2).toList();
    return Tooltip(
      message: l10n.genreTooltip(genre.songCount, genre.albumCount),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            NavigationHelper.push(context, GenreScreen(genre: genre.value));
          },
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: 170,
            padding: const EdgeInsets.only(
              left: 14,
              top: 10,
              bottom: 10,
              right: 6,
            ),
            decoration: BoxDecoration(
              color: color.withValues(alpha: isDark ? 0.22 : 0.16),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: color.withValues(alpha: 0.5),
                width: 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        genre.value,
                        style: TextStyle(
                          color: isDark ? color.withValues(alpha: 0.95) : color,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (genre.songCount > 0)
                        Text(
                          l10n.songsCount(genre.songCount),
                          style: TextStyle(
                            color:
                                (isDark
                                        ? color.withValues(alpha: 0.9)
                                        : color)
                                    .withValues(alpha: 0.7),
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: shown.length > 1 ? 66 : 44,
                  height: 48,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      if (shown.length > 1)
                        Positioned(
                          right: 0,
                          top: 4,
                          child: Transform.rotate(
                            angle: 0.18,
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(6),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.3),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: _cover(shown[1], 40),
                            ),
                          ),
                        ),
                      Positioned(
                        right: shown.length > 1 ? 22 : 0,
                        top: 4,
                        child: Transform.rotate(
                          angle: -0.12,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.3),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: _cover(shown[0], 40),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
