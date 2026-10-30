import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/library_provider.dart';
import '../screens/playlist_screen.dart';
import 'album_artwork.dart';

/// «В каких плейлистах встречается артист».
/// Грузится в фоне после отрисовки страницы, строго последовательно
/// (по 1 плейлисту за раз, с таймаутом) — без OOM и без фризов UI.
class ArtistPlaylistsSection extends StatefulWidget {
  final String artistId;
  final String artistName;

  const ArtistPlaylistsSection({
    super.key,
    required this.artistId,
    required this.artistName,
  });

  @override
  State<ArtistPlaylistsSection> createState() => _ArtistPlaylistsSectionState();
}

class _ArtistPlaylistsSectionState extends State<ArtistPlaylistsSection> {
  bool _loading = true;
  List<Playlist> _playlists = [];

  /// In-memory кэш: ключ = artistId + отпечаток списка плейлистов.
  /// Без отпечатка устаревший кэш прятал новые совпадения («артист есть
  /// в плейлисте, а секция пустая»).
  static final Map<String, List<Playlist>> _cache = {};

  String _fingerprint(List<Playlist> all) {
    final ids = all.map((p) => p.id).join('|');
    return '${widget.artistId}|${all.length}|${ids.hashCode}';
  }

  @override
  void initState() {
    super.initState();
    // Фон, не блокируем страницу артиста.
    Future.microtask(_loadInBackground);
  }

  Future<Playlist?> _fetchWithRetry(
      LibraryProvider library, Playlist meta) async {
    // Было: один запрос с таймаутом 6с, при обрыве — плейлист молча
    // пропускался. Теперь: короткий таймаут + 1 повтор.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final pl = await library
            .getPlaylist(meta.id)
            .timeout(const Duration(seconds: 5));
        // getPlaylist при сетевой ошибке может вернуть кэшированную мету
        // без треков — это не ответ, ретраим.
        if (pl.songs == null || pl.songs!.isEmpty) {
          final cachedSongs = meta.songs;
          if (cachedSongs != null && cachedSongs.isNotEmpty) return meta;
          if (attempt == 0) continue;
          return pl;
        }
        return pl;
      } catch (_) {
        if (attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 400));
          continue;
        }
        return null;
      }
    }
    return null;
  }

  Future<void> _loadInBackground() async {
    try {
      final library = Provider.of<LibraryProvider>(context, listen: false);
      final all = library.playlists;
      if (all.isEmpty) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final key = _fingerprint(all);
      final cached = _cache[key];
      if (cached != null) {
        if (mounted) {
          setState(() {
            _playlists = cached;
            _loading = false;
          });
        }
        return;
      }
      final found = <Playlist>[];

      // Проход 1 — мгновенно, только по уже закэшированным трекам, без сети.
      // Результат показываем сразу, а не после опроса всех плейлистов.
      for (final meta in all) {
        final cachedSongs = meta.songs;
        if (cachedSongs != null &&
            cachedSongs.isNotEmpty &&
            cachedSongs.any(_isArtistTrack)) {
          found.add(meta);
        }
      }
      if (mounted) {
        setState(() {
          _playlists = List<Playlist>.from(found);
          // Спиннер убираем только если дальше нечего догружать.
          _loading = all.any((m) =>
              (m.songs == null || m.songs!.isEmpty) &&
              !found.any((f) => f.id == m.id));
        });
      }

      // Проход 2 — догружаем детали плейлистов без треков.
      // Было: строго по 1, первые 25, без ретраев. Теперь: смотрим ВСЕ
      // плейлисты, чанками по 4 параллельно, с ретраем.
      final missing =
          all.where((m) => !found.any((f) => f.id == m.id)).toList();
      const parallelism = 4;
      for (int i = 0; i < missing.length; i += parallelism) {
        if (!mounted) return;
        final chunk = missing.skip(i).take(parallelism).toList();
        final results = await Future.wait(
          chunk.map((meta) => _fetchWithRetry(library, meta)),
        );
        var added = false;
        for (int k = 0; k < chunk.length; k++) {
          final pl = results[k];
          if (pl == null) continue;
          final songs = pl.songs ?? const <Song>[];
          if (songs.any(_isArtistTrack)) {
            found.add(pl);
            added = true;
          }
        }
        if (added && mounted) {
          setState(() => _playlists = List<Playlist>.from(found));
        }
        // Небольшая пауза, чтобы не душить сервер/батарею.
        if (i + parallelism < missing.length) {
          await Future.delayed(const Duration(milliseconds: 120));
        }
        if (!mounted) return;
      }
      _cache[key] = found;
      if (mounted) {
        setState(() {
          _playlists = found;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _isArtistTrack(Song s) {
    if (s.artistId != null &&
        s.artistId!.isNotEmpty &&
        s.artistId == widget.artistId) {
      return true;
    }
    final a = s.artist?.toLowerCase() ?? '';
    if (a.isEmpty) return false;
    final nameLower = widget.artistName.toLowerCase();
    if (a == nameLower || a.contains(nameLower) || nameLower.contains(a)) {
      return true;
    }
    // Фиты: «Artist1 / Artist2», «Artist feat. X».
    for (final part in a.split(RegExp(r'[/,&;]+'))) {
      final p = part.trim();
      if (p.isNotEmpty && (p == nameLower || p.contains(nameLower))) {
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Плейлисты с артистом',
              style:
                  theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          const SizedBox(
            height: 92,
            child: Center(
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))),
          ),
          const SizedBox(height: 24),
        ],
      );
    }
    if (_playlists.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Плейлисты с артистом',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12)),
              child: Text('${_playlists.length}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _playlists.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final pl = _playlists[i];
              return InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PlaylistScreen(
                        playlistId: pl.id, playlistName: pl.name),
                  ),
                ),
                child: SizedBox(
                  width: 250,
                  child: Row(
                    children: [
                      AlbumArtwork(
                          coverArt: pl.coverArt, size: 72, borderRadius: 8),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(pl.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 4),
                            Text(
                              pl.songCount != null
                                  ? '${pl.songCount} тр.'
                                  : '',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey[600]),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded,
                          color: Colors.grey, size: 20),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
