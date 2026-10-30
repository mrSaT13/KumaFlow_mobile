import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../widgets/app_gradient_background.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/player_provider.dart';
import '../services/services.dart';
import '../services/subsonic_service.dart';
import '../services/offline_service.dart';
import '../services/safe_image_cache_manager.dart';
import '../services/theme_service.dart';
import '../services/ml_service.dart';
import '../services/recommendation_service.dart';
import '../services/library_database_service.dart';
import '../services/local_music_service.dart';
import '../theme/app_theme.dart';

/// Screen shown when server is unavailable or user manually goes offline.
/// Plays cached/downloaded songs locally. ML and recommendations work on local files.
class OfflineModeScreen extends StatefulWidget {
  final bool enteredManually;

  const OfflineModeScreen({super.key, this.enteredManually = false});

  @override
  State<OfflineModeScreen> createState() => _OfflineModeScreenState();
}

class _OfflineModeScreenState extends State<OfflineModeScreen> {
  Timer? _pingTimer;
  bool _isPinging = false;
  List<Song> _allOfflineSongs = [];
  List<Song> _cachedSongs = [];
  List<Song> _downloadedSongs = [];
  List<Song> _localSongs = [];
  List<Song> _myWaveLocal = [];
  List<Song> _recommendedLocal = [];
  bool _isLoading = true;
  bool _hasStartedPlaying = false;

  @override
  void initState() {
    super.initState();
    _loadOfflineContent();
    _startPeriodicPing();
    if (widget.enteredManually) {
      _autoStartPlayback();
    }
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadOfflineContent() async {
    setState(() => _isLoading = true);

    try {
      final libraryProvider = Provider.of<LibraryProvider>(context, listen: false);

      // Только реально доступные офлайн: файл скачан, локальный файл существует, либо isLocal с файлом
      final off = OfflineService();
      await off.initialize();
      final downloadedIds = off.getDownloadedSongIds().toSet();
      bool rowHasFile(String id, String? path, int isLocal) {
        if (downloadedIds.contains(id)) return true;
        if (off.getLocalPath(id) != null) return true;
        if (isLocal == 1 && path != null) {
          if (path.startsWith('http://') || path.startsWith('https://')) return false;
          try {
            return File(path).existsSync();
          } catch (_) {
            return false;
          }
        }
        return false;
      }

      bool hasFile(Song s) {
        if (downloadedIds.contains(s.id)) return true;
        if (off.getLocalPath(s.id) != null) return true;
        if (s.isLocal == true && s.path != null) {
          final p = s.path!;
          if (p.startsWith('http://') || p.startsWith('https://')) return false;
          try {
            return File(p).existsSync();
          } catch (_) {
            return false;
          }
        }
        return false;
      }

      bool isLocalPath(Song s) => s.path != null &&
          !(s.path!.startsWith('http://') || s.path!.startsWith('https://'));

      final db = LibraryDatabaseService();
      final providerSongs = libraryProvider.cachedAllSongs;
      List<Song> allSongs;
      List<Song> cachedPreview = const [];

      if (providerSongs.isEmpty) {
        // Было: getAllSongs — 80к полных объектов + jsonDecode в RAM.
        // Стало: чанковый скан легких строк, гидрируем только совпавшие.
        // _cachedSongs для витрины — первые 200 (экран показывает 10).
        final matchIds = <String>[];
        final cachedIds = <String>[];
        try {
          const chunk = 2000;
          final total = await db.getSongCount();
          for (var offset = 0; offset < total; offset += chunk) {
            final rows = await db.getSongsForOfflineScan(limit: chunk, offset: offset);
            for (final r in rows) {
              final id = r['id'] as String;
              if (rowHasFile(id, r['path'] as String?, (r['isLocal'] as int?) ?? 0)) {
                matchIds.add(id);
              } else if (cachedIds.length < 200) {
                cachedIds.add(id);
              }
            }
          }
          allSongs = await db.getSongsByIds(matchIds, light: false);
          cachedPreview = await db.getSongsByIds(cachedIds, light: true);
        } catch (_) {
          allSongs = providerSongs;
        }
      } else {
        allSongs = providerSongs;
        // Рабочий набор случаен: скачанные треки могут в него не попасть —
        // догружаем их точно по id из БД.
        try {
          final missing = downloadedIds.where((id) => !allSongs.any((s) => s.id == id)).toList();
          if (missing.isNotEmpty) {
            final resolved = await db.getSongsByIds(missing, light: false);
            if (resolved.isNotEmpty) allSongs = [...allSongs, ...resolved];
          }
        } catch (_) {}
      }

      // Also include local device music (dedup O(1) через Set)
      try {
        final localMusic = Provider.of<LocalMusicService>(context, listen: false);
        if (localMusic.songs.isNotEmpty) {
          final seen = allSongs.map((m) => m.id).toSet();
          final merged = List<Song>.from(allSongs);
          for (final s in localMusic.songs) {
            if (seen.add(s.id)) merged.add(s);
          }
          allSongs = merged;
        }
      } catch (_) {}

      _downloadedSongs = allSongs.where(hasFile).toList();
      _localSongs = allSongs.where(isLocalPath).toList();
      // Витрина кэшированных показывает 10 — держим максимум 200 вместо 80к.
      if (providerSongs.isEmpty) {
        _cachedSongs = cachedPreview;
      } else {
        _cachedSongs = allSongs.where((s) => !hasFile(s)).take(200).toList();
      }
      // Моя волна в офлайне — ТОЛЬКО из скачанного/локального, без fallback на всё.
      // Иначе ML/оркестратор/BPM гоняют нес-качанные треки, а играть нечего.
      _allOfflineSongs = List<Song>.from(_downloadedSongs);

      await _generateLocalRecommendations();
    } catch (e) {
      debugPrint('[OfflineMode] Error loading offline content: $e');
    }

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  /// ML and recommendations work locally on offline files
  Future<void> _generateLocalRecommendations() async {
    if (_allOfflineSongs.isEmpty) return;

    try {
      final mlService = Provider.of<MLService>(context, listen: false);
      final recommendationService = Provider.of<RecommendationService>(context, listen: false);

      _myWaveLocal = mlService.generateLocalMyWave(
        songs: _allOfflineSongs,
        count: 30,
      );

      _recommendedLocal = recommendationService.getLocalRecommendations(
        songs: _allOfflineSongs,
        count: 20,
      );
    } catch (e) {
      debugPrint('[OfflineMode] Error generating local recommendations: $e');
      _myWaveLocal = List.from(_allOfflineSongs);
      _myWaveLocal.shuffle();
      _myWaveLocal = _myWaveLocal.take(30).toList();
      _recommendedLocal = List.from(_allOfflineSongs);
      _recommendedLocal.shuffle();
      _recommendedLocal = _recommendedLocal.take(20).toList();
    }
  }

  Future<void> _autoStartPlayback() async {
    if (_hasStartedPlaying) return;
    _hasStartedPlaying = true;

    if (_myWaveLocal.isNotEmpty) {
      final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
      playerProvider.playSong(
        _myWaveLocal.first,
        playlist: _myWaveLocal,
        startIndex: 0,
      );
    }
  }

  void _startPeriodicPing() {
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _pingServer();
    });
  }

  Future<void> _pingServer() async {
    if (_isPinging) return;

    setState(() => _isPinging = true);

    try {
      final subsonicService = Provider.of<SubsonicService>(context, listen: false);
      final isOnline = await subsonicService.ping();

      if (isOnline && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Сервер снова доступен!'),
            backgroundColor: Colors.green,
          ),
        );

        await Future.delayed(const Duration(seconds: 2));

        if (mounted) {
          Navigator.of(context).pop();
        }
      }
    } catch (_) {}

    if (mounted) {
      setState(() => _isPinging = false);
    }
  }

  void _playMyWave() {
    if (_myWaveLocal.isEmpty) return;
    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
    playerProvider.playSong(
      _myWaveLocal.first,
      playlist: _myWaveLocal,
      startIndex: 0,
    );
    Navigator.pop(context);
  }

  void _playShuffleAll() {
    if (_allOfflineSongs.isEmpty) return;
    final shuffled = List<Song>.from(_allOfflineSongs)..shuffle();
    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
    playerProvider.playSong(
      shuffled.first,
      playlist: shuffled,
      startIndex: 0,
    );
    Navigator.pop(context);
  }

  void _playPlaylist(List<Song> songs) {
    if (songs.isEmpty) return;
    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
    playerProvider.playSong(
      songs.first,
      playlist: songs,
      startIndex: 0,
    );
    Navigator.pop(context);
  }

  Future<void> _generateInstantMix() async {
    if (_allOfflineSongs.isEmpty) return;
    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
    // Reuse the provider's wired AutoDjService (fresh instances have no
    // services set and return empty mixes).
    final autoDj = playerProvider.autoDjService;
    final libraryProvider = Provider.of<LibraryProvider>(context, listen: false);

    final currentSong = playerProvider.currentSong ??
        _allOfflineSongs.first;

    final mix = await autoDj.getInstantMix(
      seedSong: currentSong,
      count: 25,
      availableSongs: _allOfflineSongs,
    );

    if (mix.isNotEmpty && mounted) {
      playerProvider.playSong(
        mix.first,
        playlist: mix,
        startIndex: 0,
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final totalSongs = _allOfflineSongs.length;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF121212) : Colors.grey[100],
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.cloud_off_rounded,
                            color: Colors.orange,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Офлайн режим',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? Colors.white : Colors.black,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '$totalSongs треков доступно локально',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: isDark ? Colors.white54 : Colors.black54,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.05)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _isPinging ? Icons.sync : Icons.sync_disabled,
                            color: _isPinging ? Colors.blue : Colors.orange,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _isPinging
                                  ? 'Проверка соединения...'
                                  : 'Сервер недоступен. Повтор каждые 30 сек.',
                              style: TextStyle(
                                fontSize: 13,
                                color: isDark ? Colors.white70 : Colors.black54,
                              ),
                            ),
                          ),
                          if (_isPinging)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_isLoading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_allOfflineSongs.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.library_music_outlined,
                        size: 80,
                        color: isDark ? Colors.white24 : Colors.black26,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Нет доступных треков',
                        style: TextStyle(
                          fontSize: 18,
                          color: isDark ? Colors.white54 : Colors.black54,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          'Скачайте треки для прослушивания без сети',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark ? Colors.white38 : Colors.black38,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'БЫСТРОЕ ВОСПРОИЗВЕДЕНИЕ',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white54 : Colors.black54,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      _OfflinePlayCard(
                        title: 'Моя волна (локальная)',
                        subtitle: '${_myWaveLocal.length} треков',
                        icon: Icons.waves_rounded,
                        color: AppTheme.appleMusicRed,
                        onTap: _playMyWave,
                        enabled: _myWaveLocal.isNotEmpty,
                      ),
                      const SizedBox(height: 8),
                      _OfflinePlayCard(
                        title: 'Перемешать всё',
                        subtitle: '$totalSongs треков',
                        icon: Icons.shuffle_rounded,
                        color: Colors.blue,
                        onTap: _playShuffleAll,
                        enabled: totalSongs > 0,
                      ),
                      const SizedBox(height: 8),
                      _OfflinePlayCard(
                        title: 'Instant Mix',
                        subtitle: 'На основе текущего трека',
                        icon: Icons.auto_awesome,
                        color: Colors.purple,
                        onTap: _generateInstantMix,
                        enabled: _allOfflineSongs.isNotEmpty,
                      ),
                    ],
                  ),
                ),
              ),
              if (_myWaveLocal.isNotEmpty) ...[
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child:                       Text(
                      'МОЯ ВОЛНА',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white54 : Colors.black54,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final song = _myWaveLocal[index];
                      return _OfflineSongTile(
                        song: song,
                        onTap: () {
                          final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
                          playerProvider.playSong(
                            song,
                            playlist: _myWaveLocal,
                            startIndex: index,
                          );
                        },
                      );
                    },
                    childCount: _myWaveLocal.take(15).length,
                  ),
                ),
              ],
              if (_recommendedLocal.isNotEmpty) ...[
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child:                       Text(
                      'РЕКОМЕНДАЦИИ (ЛОКАЛЬНЫЕ)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white54 : Colors.black54,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final song = _recommendedLocal[index];
                      return _OfflineSongTile(
                        song: song,
                        onTap: () {
                          final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
                          playerProvider.playSong(
                            song,
                            playlist: _recommendedLocal,
                            startIndex: index,
                          );
                        },
                      );
                    },
                    childCount: _recommendedLocal.take(15).length,
                  ),
                ),
              ],
              if (_cachedSongs.isNotEmpty) ...[
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child:                       Text(
                      'КЭШИРОВАННЫЕ (${_cachedSongs.length})',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white54 : Colors.black54,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final song = _cachedSongs[index];
                      return _OfflineSongTile(
                        song: song,
                        onTap: () {
                          final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
                          playerProvider.playSong(
                            song,
                            playlist: _cachedSongs,
                            startIndex: index,
                          );
                        },
                      );
                    },
                    childCount: _cachedSongs.take(10).length,
                  ),
                ),
              ],
              if (_downloadedSongs.isNotEmpty) ...[
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child:                       Text(
                      'СКАЧАННЫЕ (${_downloadedSongs.length})',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white54 : Colors.black54,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final song = _downloadedSongs[index];
                      return _OfflineSongTile(
                        song: song,
                        onTap: () {
                          final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
                          playerProvider.playSong(
                            song,
                            playlist: _downloadedSongs,
                            startIndex: index,
                          );
                        },
                      );
                    },
                    childCount: _downloadedSongs.take(10).length,
                  ),
                ),
              ],
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: OutlinedButton.icon(
                    onPressed: _isPinging ? null : _pingServer,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Повторить подключение'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      side: BorderSide(
                        color: isDark ? Colors.white24 : Colors.black26,
                      ),
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          ],
        ),
      ),
    );
  }
}

class _OfflinePlayCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool enabled;

  const _OfflinePlayCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: enabled
          ? color.withValues(alpha: 0.1)
          : (isDark ? Colors.white.withValues(alpha: 0.03) : Colors.grey[200]),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(
                icon,
                color: enabled ? color : Colors.grey,
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: enabled
                            ? (isDark ? Colors.white : Colors.black)
                            : Colors.grey,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: enabled
                            ? (isDark ? Colors.white54 : Colors.black54)
                            : Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.play_arrow_rounded,
                color: enabled ? color : Colors.grey,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfflineSongTile extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;

  const _OfflineSongTile({
    required this.song,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subsonicService = Provider.of<SubsonicService>(context, listen: false);

    final localCover = OfflineService().getLocalCoverForSong(
      albumId: song.albumId,
      coverArt: song.coverArt,
      trackId: song.id,
    );
    return ListTile(
      onTap: onTap,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 48,
          height: 48,
          child: localCover != null
              ? Image.file(
                  File(localCover),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: Colors.grey[800],
                    child: const Icon(Icons.music_note, color: Colors.white30, size: 20),
                  ),
                )
              : song.coverArt != null
                  ? CachedNetworkImage(
                      imageUrl: subsonicService.getCoverArtUrl(song.coverArt!, size: 100),
                      cacheManager: SafeImageCacheManager.instance,
                      cacheKey: 'main_${song.coverArt}_200',
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        color: Colors.grey[800],
                        child: const Icon(Icons.music_note, color: Colors.white30, size: 20),
                      ),
                    )
                  : Container(
                      color: Colors.grey[800],
                      child: const Icon(Icons.music_note, color: Colors.white30, size: 20),
                    ),
        ),
      ),
      title: Text(
        song.title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: isDark ? Colors.white : Colors.black,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        song.artist ?? 'Unknown Artist',
        style: TextStyle(
          fontSize: 12,
          color: isDark ? Colors.white54 : Colors.black54,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Icon(
        song.isLocal ? Icons.phone_android : Icons.cloud_done,
        size: 16,
        color: isDark ? Colors.white38 : Colors.black38,
      ),
    );
  }
}


