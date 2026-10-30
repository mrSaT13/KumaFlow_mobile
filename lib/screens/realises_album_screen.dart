import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../services/theme_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import '../models/models.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../services/yandex_music_service.dart';
import '../services/yandex_music_public_api.dart';
import '../providers/yandex_music_provider.dart';
import '../theme/app_theme.dart';
import '../utils/screen_helper.dart';
import '../widgets/app_gradient_background.dart';
import '../widgets/song_tile.dart';

/// Экран релиза/альбома из Яндекс Музыки с треками.
/// Аналог client.albums_with_tracks('id'): GET /albums/{id}/with-tracks
/// Работает без токена (public), с токеном — больше полей.
/// Показывает обложку, метаданные, volumes → треки, матчит локальные песни для воспроизведения.
class RealisesAlbumScreen extends StatefulWidget {
  final String albumId;
  final String? initialTitle;
  final String? initialCoverUri;
  final String? initialArtistName;

  const RealisesAlbumScreen({
    super.key,
    required this.albumId,
    this.initialTitle,
    this.initialCoverUri,
    this.initialArtistName,
  });

  @override
  State<RealisesAlbumScreen> createState() => _RealisesAlbumScreenState();
}

class _RealisesAlbumScreenState extends State<RealisesAlbumScreen> {
  Map<String, dynamic>? _albumData;
  List<Map<String, dynamic>> _volumesFlat = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAlbum();
  }

  Future<void> _loadAlbum() async {
    final yandexProvider = Provider.of<YandexMusicProvider>(context, listen: false);
    // Используем public API если нет токена, иначе authenticated service (больше полей)
    try {
      Map<String, dynamic>? result;
      if (yandexProvider.isEnabled && yandexProvider.hasToken) {
        final svc = YandexMusicService(oauthToken: yandexProvider.oauthToken);
        final pub = YandexMusicPublicApi();
        result = await pub.getAlbumInfo(widget.albumId);
        // fallback к authenticated если public пуст
        if (result == null) {
          final info = await svc.getAlbumInfo(widget.albumId);
          if (info != null) {
            result = {
              'id': info.id,
              'title': info.title,
              'coverUri': info.coverUri,
              'year': info.year,
              'genre': info.genres?.isNotEmpty == true ? info.genres!.first : null,
              'artists': info.artistName != null ? [{'name': info.artistName, 'id': info.artistId}] : [],
              'trackCount': info.trackCount,
            };
          }
        }
      } else {
        final pub = YandexMusicPublicApi();
        result = await pub.getAlbumInfo(widget.albumId);
      }

      if (result == null) {
        if (mounted) setState(() { _error = 'Альбом не найден'; _isLoading = false; });
        return;
      }

      // result может быть как весь альбом с volumes, так и обёртка с ключом 'album'
      Map<String, dynamic> album = result;
      List volumes = [];
      if (result.containsKey('album') && result['album'] is Map) {
        album = (result['album'] as Map).cast<String, dynamic>();
        volumes = (result['volumes'] as List? ?? result['volumes'] as List? ?? []) ;
        // иногда volumes в корне рядом с album
        if (volumes.isEmpty && result.containsKey('volumes')) volumes = result['volumes'] as List;
      } else {
        volumes = (result['volumes'] as List? ?? []) ;
      }

      // volumes — List<List<Map>> — сплющиваем
      final flat = <Map<String, dynamic>>[];
      for (final vol in volumes) {
        if (vol is List) {
          for (final t in vol) {
            if (t is Map) flat.add((t as Map).cast<String, dynamic>());
          }
        } else if (vol is Map) {
          flat.add((vol).cast<String, dynamic>());
        }
      }

      // fallback: если volumes пустой, но есть trackCount - оставим пустой список (покажем метаданные)
      if (mounted) {
        setState(() {
          _albumData = album;
          _volumesFlat = flat;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  String _getCoverUri() {
    if (_albumData?['coverUri'] != null) return _albumData!['coverUri'] as String;
    if (_albumData?['ogImage'] != null) return _albumData!['ogImage'] as String;
    return widget.initialCoverUri ?? '';
  }

  String _getTitle() => (_albumData?['title'] as String?) ?? widget.initialTitle ?? 'Альбом';
  String _getArtist() {
    final artists = _albumData?['artists'] as List?;
    if (artists != null && artists.isNotEmpty) {
      final first = artists.first as Map;
      return first['name']?.toString() ?? widget.initialArtistName ?? '';
    }
    return (_albumData?['artistName'] as String?) ?? widget.initialArtistName ?? '';
  }

  void _playAll({bool shuffle = false}) {
    if (_volumesFlat.isEmpty) return;
    _playTracks(_volumesFlat, startIndex: 0, shuffle: shuffle);
  }

  Future<void> _playTracks(List<Map<String, dynamic>> yandexTracks, {int startIndex = 0, bool shuffle = false}) async {
    final libraryProvider = Provider.of<LibraryProvider>(context, listen: false);
    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);

    // Пытаемся сматчить каждый Yandex трек с локальной библиотекой по title+artist.
    // Было: карта 80к + скан на каждый трек. Стало: точечный SQL-поиск на трек.
    final playlist = <Song>[];
    final unmatched = <Map<String, dynamic>>[];

    for (final yt in yandexTracks) {
      final title = (yt['title'] as String? ?? '').trim();
      final artists = yt['artists'] as List?;
      final artistName = artists != null && artists.isNotEmpty ? (artists.first['name'] as String? ?? '') : _getArtist();
      final key = '${title.toLowerCase()}|${artistName.toLowerCase()}';
      Song? local;
      try {
        final byTitle = (await libraryProvider.searchDbAsync(title, limit: 10)).songs;
        for (final s in byTitle) {
          if ('${s.title.toLowerCase().trim()}|${(s.artist ?? '').toLowerCase().trim()}' == key) {
            local = s;
            break;
          }
        }
        local ??= byTitle.isNotEmpty ? byTitle.first : null;
        if (local == null) {
          final byBoth = (await libraryProvider.searchDbAsync('$title $artistName', limit: 5)).songs;
          if (byBoth.isNotEmpty) local = byBoth.first;
        }
      } catch (_) {
        local = null;
      }
      if (local != null) {
        playlist.add(local);
      } else {
        unmatched.add(yt);
      }
    }

    List<Song> toPlay = playlist;
    if (shuffle) {
      toPlay = List<Song>.from(playlist)..shuffle();
    }

    if (toPlay.isNotEmpty) {
      final start = startIndex.clamp(0, toPlay.length - 1);
      playerProvider.playSong(toPlay[start], playlist: toPlay, startIndex: start);
      if (unmatched.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Найдено локально ${toPlay.length}/${yandexTracks.length} треков'), duration: const Duration(seconds: 2)),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Треки альбома не найдены в локальной библиотеке'), duration: Duration(seconds: 2)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_isLoading) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(backgroundColor: isDark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82)),
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Shimmer.fromColors(
                      baseColor: isDark ? AppTheme.darkCard : const Color(0xFFE0E0E0),
                      highlightColor: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5),
                      child: Container(width: 200, height: 200, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12))),
                    ),
                    const SizedBox(height: 16),
                    Shimmer.fromColors(
                      baseColor: isDark ? AppTheme.darkCard : const Color(0xFFE0E0E0),
                      highlightColor: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5),
                      child: Container(width: 180, height: 20, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(4))),
                    ),
                  ],
                ),
              ),
            ),
            SliverList(delegate: SliverChildBuilderDelegate((_, __) => const _TrackShimmer(), childCount: 8)),
          ],
        ),
      );
    }

    if (_error != null || _albumData == null) {
      return Scaffold(
        appBar: AppBar(backgroundColor: isDark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82)),
        body: Center(child: Text(_error ?? 'Ошибка загрузки')),
      );
    }

    final coverUri = _getCoverUri();
    final coverUrl = YandexMusicService.getCoverUrl(coverUri, size: '600x600') ?? coverUri;
    final title = _getTitle();
    final artist = _getArtist();
    final year = _albumData?['year']?.toString();
    final genre = (_albumData?['genre'] as String?) ?? (_albumData?['genres'] is List && (_albumData!['genres'] as List).isNotEmpty ? (_albumData!['genres'] as List).first.toString() : null);
    final trackCount = _volumesFlat.isNotEmpty ? _volumesFlat.length : (_albumData?['trackCount'] as int? ?? 0);

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
                  if (coverUrl.isNotEmpty)
                    CachedNetworkImage(
                      imageUrl: coverUrl,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: const Color(0xFF1A1A1A)),
                      errorWidget: (_, __, ___) => Container(color: Colors.grey[900], child: const Icon(Icons.album_rounded, size: 64, color: Colors.white24)),
                    )
                  else
                    Container(color: Colors.grey[900], child: const Icon(Icons.album_rounded, size: 64, color: Colors.white24)),
                  Container(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black.withValues(alpha: 0.1), Colors.black.withValues(alpha: 0.75)]))),
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 20,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: coverUrl.isNotEmpty
                              ? CachedNetworkImage(imageUrl: coverUrl, width: 110, height: 110, fit: BoxFit.cover)
                              : Container(width: 110, height: 110, color: Colors.grey[800], child: const Icon(Icons.album_rounded, color: Colors.white24)),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800, shadows: [Shadow(color: Colors.black54, blurRadius: 6)]), maxLines: 2, overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 4),
                              Text(artist, style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 13, shadows: const [Shadow(color: Colors.black54, blurRadius: 4)]), maxLines: 1, overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 4),
                              Text([if (year != null) year, if (genre != null) genre, '$trackCount треков'].join(' • '), style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 11)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Row(
                children: [
                  Expanded(child: _PlayButton(icon: CupertinoIcons.play_fill, label: 'Слушать', onTap: () => _playAll())),
                  const SizedBox(width: 12),
                  Expanded(child: _PlayButton(icon: CupertinoIcons.shuffle, label: 'Перемешать', onTap: () => _playAll(shuffle: true))),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
          if (_volumesFlat.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Треки недоступны', style: TextStyle(color: Colors.grey[600]), textAlign: TextAlign.center),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final yt = _volumesFlat[index];
                final trackTitle = yt['title'] as String? ?? 'Трек';
                final durationMs = (yt['durationMs'] as num?)?.toInt();
                final artists = yt['artists'] as List?;
                final artistName = artists != null && artists.isNotEmpty ? (artists.first['name'] as String? ?? artist) : artist;
                final duration = durationMs != null ? Duration(milliseconds: durationMs) : null;
                final durationStr = duration != null ? '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}' : '';
                final libraryProvider = Provider.of<LibraryProvider>(context, listen: false);
                // проверяем наличие в локальной библиотеке для индикатора
                final existsLocally = libraryProvider.cachedAllSongs.any((s) => s.title.toLowerCase() == trackTitle.toLowerCase() && (s.artist ?? '').toLowerCase() == artistName.toLowerCase());

                return ListTile(
                  leading: Text('${index + 1}', style: TextStyle(color: Colors.grey[500], fontSize: 14, fontWeight: FontWeight.w600)),
                  title: Text(trackTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  subtitle: Text(artistName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (durationStr.isNotEmpty) Text(durationStr, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                      const SizedBox(width: 8),
                      Icon(existsLocally ? Icons.check_circle_rounded : Icons.cloud_off_rounded, size: 14, color: existsLocally ? Colors.green : Colors.grey[400]),
                    ],
                  ),
                  onTap: () => _playTracks(_volumesFlat, startIndex: index),
                );
              }, childCount: _volumesFlat.length),
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
  final VoidCallback onTap;
  const _PlayButton({required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = Theme.of(context).colorScheme.primary;
    return Material(
      color: accent.withValues(alpha: isDark ? 0.15 : 0.1),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, color: accent, size: 18), const SizedBox(width: 8), Text(label, style: TextStyle(color: accent, fontSize: 14, fontWeight: FontWeight.w600))]),
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
          Container(width: 20, height: 14, color: Colors.white),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Container(height: 14, color: Colors.white), const SizedBox(height: 6), Container(width: 120, height: 10, color: Colors.white)])),
          Container(width: 40, height: 12, color: Colors.white),
        ]),
      ),
    );
  }
}
