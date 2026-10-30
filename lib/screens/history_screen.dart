import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/theme_service.dart';
import '../l10n/app_localizations.dart';
import '../models/song.dart';
import '../services/recommendation_service.dart';
import '../providers/library_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/widgets.dart';
import '../widgets/app_gradient_background.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Song> _recentSongs = [];
  bool _isLoading = true;
  LibraryProvider? _libraryProvider;
  RecommendationService? _recommendationService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Check if still mounted before accessing context
      if (!mounted) return;

      // Listen for library / profile updates in case data arrives later.
      _libraryProvider = Provider.of<LibraryProvider>(
        context,
        listen: false,
      );
      _recommendationService = Provider.of<RecommendationService>(
        context,
        listen: false,
      );

      // Check again after provider lookup (widget may have been disposed)
      if (!mounted) return;

      _libraryProvider!.addListener(_onProvidersChanged);
      _recommendationService!.addListener(_onProvidersChanged);
      _loadHistory();
    });
  }

  @override
  void dispose() {
    _libraryProvider?.removeListener(_onProvidersChanged);
    _recommendationService?.removeListener(_onProvidersChanged);
    super.dispose();
  }

  void _onProvidersChanged() {
    if (mounted) _loadHistory();
  }

  Future<void> _loadHistory() async {
    final recommendationService = _recommendationService;
    final libraryProvider = _libraryProvider;
    if (recommendationService == null || libraryProvider == null) return;

    // If library is still loading, keep showing the spinner.
    if (libraryProvider.cachedAllSongs.isEmpty) {
      if (!libraryProvider.isLoading && libraryProvider.isInitialized) {
        // Library finished loading and is genuinely empty.
        if (mounted) {
          setState(() {
            _recentSongs = [];
            _isLoading = false;
          });
        }
      }
      return;
    }

    // Load history even if recommendations are disabled
    // The profiles are still tracked even when recommendations are off

    final profiles = recommendationService.profiles;
    // Было: songMap из 80к кэша. Стало: сыгранные из БД (истории нужно 100).
    List<Song> playedPool;
    try {
      playedPool = await libraryProvider.getPlayedSongs(limit: 500);
    } catch (_) {
      playedPool = libraryProvider.cachedAllSongs;
    }
    final allSongs = playedPool.isNotEmpty ? playedPool : libraryProvider.cachedAllSongs;

    final songMap = {for (var s in allSongs) s.id: s};

    final playedSongs = profiles.entries
        .where((e) => e.value.playCount > 0 && songMap.containsKey(e.key))
        .map((e) => MapEntry(songMap[e.key]!, e.value.lastPlayed))
        .toList();

    playedSongs.sort((a, b) => b.value.compareTo(a.value));

    if (mounted) {
      setState(() {
        _recentSongs = playedSongs.map((e) => e.key).take(100).toList();
        _isLoading = false;
      });
    }
  }

  List<MapEntry<String, List<Song>>> _groupByDate(List<Song> songs) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final profiles = _recommendationService?.profiles ?? {};
    final buckets = <String, List<Song>>{
      'Сегодня': [],
      'Вчера': [],
      'На этой неделе': [],
      'В этом месяце': [],
      'Ранее': [],
    };
    for (final s in songs) {
      final p = profiles[s.id];
      final lp = p?.lastPlayed;
      if (lp == null) {
        buckets['Ранее']!.add(s);
        continue;
      }
      final d = DateTime(lp.year, lp.month, lp.day);
      final diff = today.difference(d).inDays;
      if (diff == 0) buckets['Сегодня']!.add(s);
      else if (diff == 1) buckets['Вчера']!.add(s);
      else if (diff < 7) buckets['На этой неделе']!.add(s);
      else if (diff < 30) buckets['В этом месяце']!.add(s);
      else buckets['Ранее']!.add(s);
    }
    return buckets.entries.where((e) => e.value.isNotEmpty).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(backgroundColor: Colors.transparent, 
      appBar: AppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),title: Text(AppLocalizations.of(context)!.listeningHistory)),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _recentSongs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.history_rounded,
                        size: 64,
                        color: isDark
                            ? AppTheme.darkSecondaryText
                            : AppTheme.lightSecondaryText,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No Listening History',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          color: isDark
                              ? AppTheme.darkSecondaryText
                              : AppTheme.lightSecondaryText,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Songs you play will appear here',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: isDark
                              ? AppTheme.darkSecondaryText
                              : AppTheme.lightSecondaryText,
                        ),
                      ),
                    ],
                  ),
                )
              : Builder(builder: (context) {
                  final grouped = _groupByDate(_recentSongs);
                  return ListView.builder(
                    itemCount: grouped.length,
                    itemBuilder: (context, sectionIndex) {
                      final section = grouped[sectionIndex];
                      final header = section.key;
                      final songs = section.value;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                            child: Row(
                              children: [
                                Text(header, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: isDark ? Colors.white70 : Colors.black54)),
                                const SizedBox(width: 8),
                                Container(width: 24, height: 1, color: isDark ? Colors.white24 : Colors.black12),
                                const SizedBox(width: 8),
                                Text('${songs.length}', style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.black38)),
                              ],
                            ),
                          ),
                          ...List.generate(songs.length, (i) {
                            final globalIndex = _recentSongs.indexOf(songs[i]);
                            return SongTile(song: songs[i], playlist: _recentSongs, index: globalIndex, showAlbum: true);
                          }),
                        ],
                      );
                    },
                  );
                }),
    );
  }
}
