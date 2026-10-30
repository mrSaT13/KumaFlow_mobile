import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../services/offline_service.dart';
import '../services/subsonic_service.dart';
import '../services/theme_service.dart';
import '../services/yandex_music_service.dart';
import '../services/yandex_integration_service.dart';
import '../services/ml_service.dart';
import '../theme/app_theme.dart';
import '../widgets/widgets.dart';
import '../widgets/app_gradient_background.dart';
import '../widgets/related_content_section.dart';
import '../widgets/artist_playlists_section.dart';
import '../services/kumaflow_brain/kumaflow_brain_bridge.dart';
import '../services/kumaflow_brain/kumaflow_brain_playback.dart';
import '../widgets/artist_subscribe_bell.dart';
import '../services/wave_identity.dart';
import 'album_screen.dart';
import 'artist_images_screen.dart';import 'artist_videos_screen.dart';
import 'realises_album_screen.dart';
import 'artist_all_tracks_screen.dart';
import '../services/yandex_music_public_api.dart';

class ArtistScreen extends StatefulWidget {
  final String artistId;

  const ArtistScreen({super.key, required this.artistId});

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  Artist? _artist;
  List<Song> _topSongs = [];
  List<Album> _albums = [];
  bool _isLoading = true;
  /// Загрузка провалилась (сеть/сервер): показываем ретри + ждём онлайн.
  bool _loadFailed = false;
  /// Данные из кэша (офлайн): шапка честна — «показываем сохранённое».
  bool _fromCache = false;

  // Yandex: новый релиз / последние альбомы
  List<Map<String, dynamic>> _yandexNewReleases = [];
  bool _yandexReleasesLoading = true;

  // Collapsible sections for Lara Fabian design
  bool _showAllTopTracks = false;
  bool _albumsExpanded = true;
  bool _epsExpanded = false;
  bool _singlesExpanded = false;

  @override
  void initState() {
    super.initState();
    _loadArtistDetails();
    // Бесшовный офлайн->онлайн: открыли из офлайн-трека без сети —
    // при появлении сети догружаем серверное сами, рестарт не нужен.
    try {
      OfflineService().addOnlineListener(_handleOnlineRestored);
    } catch (_) {}
  }

  @override
  void dispose() {
    try {
      OfflineService().removeOnlineListener(_handleOnlineRestored);
    } catch (_) {}
    super.dispose();
  }

  void _handleOnlineRestored() {
    if (!mounted) return;
    // Перезагружаем только если было пусто/упало или показывали кэш.
    if (_loadFailed || _fromCache || _artist == null) {
      _loadArtistDetails();
    }
  }

  Future<void> _retryLoad() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _loadFailed = false;
    });
    await _loadArtistDetails();
  }

  Future<void> _loadArtistDetails() async {
    final libraryProvider = Provider.of<LibraryProvider>(
      context,
      listen: false,
    );
    final subsonicService = libraryProvider.subsonicService;

    try {
      Artist? artist;
      List<Song> topSongs = [];
      List<Album> albums = [];

      if (libraryProvider.isLocalOnlyMode) {
        artist = libraryProvider.artists.firstWhere(
          (a) => a.id == widget.artistId,
          orElse: () => Artist(id: widget.artistId, name: 'Unknown Artist'),
        );
        albums = await libraryProvider.getArtistAlbums(widget.artistId);
        // Было: скан 80к cachedAllSongs. Стало: SQL по индексу artistId.
        try {
          topSongs = await libraryProvider.getSongsByArtistId(widget.artistId, limit: 200);
        } catch (_) {
          topSongs = libraryProvider.cachedAllSongs
              .where((s) => s.artistId == widget.artistId)
              .take(200)
              .toList();
        }
        if (mounted) {
          setState(() {
            _artist = artist;
            _topSongs = topSongs;
            _albums = albums;
            _isLoading = false;
          });
        }
        return;
      }

      // Server mode - parallel fetch (was sequentially 3x await)
      Future<Artist?> fetchArtist() async {
        try {
          return await subsonicService.getArtist(widget.artistId);
        } catch (e) {
          debugPrint('[ArtistScreen] getArtist error: $e');
          try {
            final searchResult = await subsonicService.search(widget.artistId, artistCount: 1);
            if (searchResult.artists.isNotEmpty) return searchResult.artists.first;
          } catch (_) {}
          return Artist(id: widget.artistId, name: 'Unknown Artist');
        }
      }

      Future<List<Song>> fetchTop() async {
        try {
          return await subsonicService.getArtistTopSongs(widget.artistId);
        } catch (e) {
          debugPrint('[ArtistScreen] getArtistTopSongs error: $e');
          return [];
        }
      }

      Future<List<Album>> fetchAlbums() async {
        try {
          return await subsonicService.getArtistAlbums(widget.artistId);
        } catch (e) {
          debugPrint('[ArtistScreen] getArtistAlbums error: $e');
          return [];
        }
      }

      final results = await Future.wait([fetchArtist(), fetchTop(), fetchAlbums()]);
      artist = results[0] as Artist?;
      topSongs = results[1] as List<Song>;
      albums = results[2] as List<Album>;

      // Всё пусто (сеть легла): добиваем из локального кэша, чтобы из
      // офлайн-трека было что показать + честный флаг для автодогрузки.
      var fromCache = false;
      final unknown =
          artist == null || (artist.name.trim().isEmpty || artist.name == 'Unknown Artist');
      if ((unknown || topSongs.isEmpty) && mounted) {
        try {
          final cached = await libraryProvider.getSongsByArtistId(
              widget.artistId,
              limit: 200);
          if (cached.isNotEmpty && topSongs.isEmpty) {
            topSongs = cached;
            fromCache = true;
          }
        } catch (_) {}
      }
      final failed = (artist == null ||
              artist.name == 'Unknown Artist') &&
          topSongs.isEmpty &&
          albums.isEmpty;

      if (mounted) {
        setState(() {
          _artist = artist;
          _topSongs = topSongs;
          _albums = albums;
          _isLoading = false;
          _loadFailed = failed;
          _fromCache = fromCache && !failed;
        });
        if (fromCache && !failed) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                    'Офлайн — показано сохранённое. Обновим при появлении сети.'),
                duration: Duration(seconds: 3),
              ),
            );
          });
        }
      }

      // Lazy enrichment: fill topSongs from cache / limited album fetch without blocking UI
      if (albums.isNotEmpty && mounted) {
        // fire and forget
        _enrichTopSongsInBackground(albums, topSongs);
      }

      // Yandex: новые релизы артиста (не блокируем UI)
      if (artist != null && mounted) {
        _loadYandexNewReleases(artist.name, artist.id);
      }
    } catch (e) {
      debugPrint('[ArtistScreen] _loadArtistDetails error: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadFailed = true;
        });
      }
    }
  }

  Future<void> _enrichTopSongsInBackground(List<Album> albums, List<Song> initialTop) async {
    try {
      final libraryProvider = Provider.of<LibraryProvider>(context, listen: false);
      final subsonicService = libraryProvider.subsonicService;
      // Prefer DB songs to avoid network (SQL по индексу, не скан 80к)
      final initialIds = initialTop.map((e) => e.id).toSet();
      List<Song> cachedExtra;
      try {
        cachedExtra = (await libraryProvider.getSongsByArtistId(widget.artistId, limit: 200))
            .where((s) => initialIds.add(s.id))
            .toList();
      } catch (_) {
        cachedExtra = libraryProvider.cachedAllSongs
            .where((s) => s.artistId == widget.artistId && initialIds.add(s.id))
            .take(200)
            .toList();
      }
      if (cachedExtra.isNotEmpty) {
        // If cache already gives enough tracks, use it and skip network
        if (cachedExtra.length >= 8 && mounted) {
          setState(() => _topSongs = [...initialTop, ...cachedExtra.take(10)]);
          return;
        }
        if (mounted && cachedExtra.length >= 3) {
          setState(() => _topSongs = [...initialTop, ...cachedExtra.take(10)]);
          // still optionally fetch more, but not critical
          if (initialTop.length + cachedExtra.length >= 8) return;
        }
      }
      // Network fallback: only first 6 albums, chunked, with timeout
      final limited = albums.take(6).toList();
      final seen = initialTop.map((s) => s.id).toSet()..addAll(cachedExtra.map((s) => s.id));
      final extra = <Song>[];
      // include cachedExtra already
      extra.addAll(cachedExtra.where((s) => seen.add(s.id)));
      for (var i = 0; i < limited.length; i += 5) {
        final chunk = limited.sublist(i, (i + 5).clamp(0, limited.length));
        try {
          final results = await Future.wait(
            chunk.map((a) => subsonicService.getAlbumSongs(a.id).timeout(const Duration(seconds: 6), onTimeout: () => <Song>[])),
          );
          for (final songs in results) {
            for (final s in songs) {
              if (seen.add(s.id)) extra.add(s);
            }
          }
        } catch (_) {}
        if (extra.length >= 10) break;
      }
      if (extra.isNotEmpty && mounted) {
        // merge without duplicates, keep original order
        final merged = [...initialTop];
        for (final s in extra) {
          if (!merged.any((e) => e.id == s.id)) merged.add(s);
        }
        setState(() => _topSongs = merged);
      }
    } catch (e) {
      debugPrint('[ArtistScreen] enrichTopSongs error: $e');
    }
  }

  Future<void> _loadYandexNewReleases(String artistName, String artistId) async {
    try {
      final yandexProvider = Provider.of<YandexMusicProvider>(context, listen: false);
      if (!yandexProvider.isEnabled) {
        if (mounted) setState(() => _yandexReleasesLoading = false);
        return;
      }
      final pub = YandexMusicPublicApi();
      // 1) Пытаемся резолвить Yandex ID через поиск
      String? yandexId;
      try {
        final search = await pub.searchArtists(artistName, limit: 1);
        if (search.isNotEmpty) yandexId = search.first['id']?.toString();
      } catch (_) {}
      yandexId ??= artistId;
      if (yandexId == null || yandexId.isEmpty) {
        if (mounted) setState(() => _yandexReleasesLoading = false);
        return;
      }
      // 2) Берём последние альбомы артиста (сортировка по году)
      final albums = await pub.getArtistAlbums(yandexId, limit: 6);
      // Сортируем по year desc, свежий первый
      albums.sort((a, b) {
        final ya = (a['year'] as int?) ?? 0;
        final yb = (b['year'] as int?) ?? 0;
        return yb.compareTo(ya);
      });
      if (mounted) {
        setState(() {
          _yandexNewReleases = albums.take(3).toList();
          _yandexReleasesLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[ArtistScreen] yandex new releases error: $e');
      if (mounted) setState(() => _yandexReleasesLoading = false);
    }
  }

  Future<void> _addArtistToQueue() async {
    if (_albums.isEmpty) return;

    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
    final libraryProvider = Provider.of<LibraryProvider>(
      context,
      listen: false,
    );
    final subsonicService = libraryProvider.subsonicService;

    final messenger = ScaffoldMessenger.of(context);
    final loc = AppLocalizations.of(context);

    try {
      final songsToQueue = <Song>[];
      if (libraryProvider.isLocalOnlyMode) {
        // Было: скан 80к на каждый альбом. Стало: SQL по индексу albumId.
        for (final album in _albums) {
          try {
            songsToQueue.addAll(await libraryProvider.getSongsByAlbumId(album.id, limit: 500));
          } catch (_) {
            songsToQueue.addAll(libraryProvider.cachedAllSongs.where((s) => s.albumId == album.id).take(500));
          }
        }
      } else {
        // Try DB first (один запрос по artistId + группировка), then network in parallel chunks
        final cachedByAlbum = <String, List<Song>>{};
        try {
          final artistSongs = await libraryProvider.getSongsByArtistId(widget.artistId, limit: 1000);
          for (final s in artistSongs) {
            if (s.albumId != null) (cachedByAlbum[s.albumId!] ??= []).add(s);
          }
        } catch (_) {
          for (final s in libraryProvider.cachedAllSongs) {
            if (s.albumId != null && s.artistId == widget.artistId) (cachedByAlbum[s.albumId!] ??= []).add(s);
          }
        }
        final needFetch = <Album>[];
        for (final album in _albums) {
          final cached = cachedByAlbum[album.id];
          if (cached != null && cached.isNotEmpty) {
            songsToQueue.addAll(cached);
          } else {
            needFetch.add(album);
          }
        }
        // Fetch remaining in parallel chunks of 5
        for (var i = 0; i < needFetch.length; i += 5) {
          final chunk = needFetch.sublist(i, (i + 5).clamp(0, needFetch.length));
          final results = await Future.wait(chunk.map((a) => subsonicService.getAlbumSongs(a.id).timeout(const Duration(seconds: 6), onTimeout: () => <Song>[])));
          for (final list in results) songsToQueue.addAll(list);
        }
      }

      if (songsToQueue.isNotEmpty) {
        playerProvider.addAllToQueue(songsToQueue);
      }

      if (!mounted) return;

      final addedToQueueMessage =
          loc?.addedArtistToQueue ?? 'Added artist to Queue';
      messenger.showSnackBar(
        SnackBar(
          content: Text(addedToQueueMessage),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      final addedToQueueErrorMessage =
          loc?.addedArtistToQueueError ?? 'Failed adding artist to Queue';
      messenger.showSnackBar(
        SnackBar(
          content: Text(addedToQueueErrorMessage),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _playTopSongs({bool shuffle = false}) {
    if (_topSongs.isEmpty) return;

    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);

    var songs = List<Song>.from(_topSongs);
    if (shuffle) {
      songs.shuffle();
    }

    playerProvider.playSong(songs.first, playlist: songs, startIndex: 0);
  }

  Future<void> _playYandexRadio() async {
    if (_artist == null) return;

    HapticFeedback.mediumImpact();

    final yandexProvider = Provider.of<YandexMusicProvider>(context, listen: false);

    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const _RadioLoadingDialog(),
    );

    try {
      final subsonicService = Provider.of<SubsonicService>(context, listen: false);
      List<Song> tracks = [];

      // 1) Base radio: Navidrome / Subsonic (always).
      // Guarantees radio works offline / without Yandex token.
      tracks = await _buildServerSideRadio(limit: 30);

      // 2) Yandex enrichment: if token enabled, append similar tracks from Yandex.
      // Spec: radio via Navidrome + additionally if Yam token is on, add Yandex similar tracks.
      if (yandexProvider.isEnabled && yandexProvider.hasToken) {
        try {
          final integrationService = YandexIntegrationService(
            yandexService: YandexMusicService(oauthToken: yandexProvider.oauthToken),
            subsonicService: subsonicService,
          );
          final yandexTracks = await integrationService.getRadioByArtist(
            artistId: _artist!.id,
            artistName: _artist!.name,
            limit: 15,
          );
          // Append only new tracks, dedup by id
          final existingIds = tracks.map((e) => e.id).toSet();
          for (final t in yandexTracks) {
            if (existingIds.add(t.id)) tracks.add(t);
          }
          debugPrint('[ArtistScreen] Yandex enrichment added \ tracks, total ');
        } catch (e) {
          debugPrint('[ArtistScreen] Yandex enrichment failed: ');
        }
      }

      // 3) ML-augmented top-up if still too short (<12 tracks): fill with scored local tracks
      if (tracks.length < 12) {
        final mlTracks = await _buildMlRadioTopup(
          existing: tracks,
          limit: 30 - tracks.length,
        );
        final existingIds = tracks.map((e) => e.id).toSet();
        for (final t in mlTracks) {
          if (existingIds.add(t.id)) tracks.add(t);
        }
      }

      // Shuffle to avoid infinite loop on same artist's own songs and ensure variety
      tracks.shuffle();

      if (!mounted) return;
      Navigator.pop(context); // Close loading dialog

      if (tracks.isNotEmpty) {
        // Feed tracks to ML engine
        final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
        for (final track in tracks) {
          playerProvider.mlStore.incrementPlayCount(track.id, null);
          playerProvider.behaviorTracker.logPlay(track.id);
        }

        // Play the radio
        playerProvider.playSong(tracks.first, playlist: tracks, startIndex: 0);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Радио \: \ треков'),
            duration: const Duration(seconds: 2),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Не нашлось треков для радио '),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка радио: '),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// M5: Brain-радио по артисту: POST /api/wave/seed -> резолв через
  /// KumaFlowBrainWaveResolver -> сразу в плеер. Мост выкл/сеть — снэк, тихо.
  Future<void> _playBrainRadio() async {
    if (_artist == null) return;
    HapticFeedback.mediumImpact();
    final bridge =
        Provider.of<KumaFlowBrainBridge>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    if (!bridge.isActive) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('KumaFlow Brain не подключён (Настройки → ML → KumaFlow Brain)'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const _RadioLoadingDialog(),
    );
    try {
      final subsonic = Provider.of<SubsonicService>(context, listen: false);
      final player = Provider.of<PlayerProvider>(context, listen: false);
      final artistName = _artist!.name;
      final tracks = await KumaFlowBrainPlayback.startArtistRadio(
        bridge: bridge,
        subsonic: subsonic,
        artistName: artistName,
      );
      if (!mounted) return;
      Navigator.pop(context); // Close loading dialog
      if (tracks.isEmpty) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Brain-радио: ничего не нашлось в библиотеке ($artistName)'),
            duration: const Duration(seconds: 3),
          ),
        );
        return;
      }
      final seedName =
          seedLabel(WaveSeed(kind: 'artist', label: artistName));
      await saveWaveSeed(WaveSeed(kind: 'artist', label: artistName));
      await saveWaveContext(
          tracks.map((s) => s.id).toList(), seedName, 'brain');
      await player.playSong(
        tracks.first,
        playlist: tracks,
        startIndex: 0,
        playlistName: seedName,
        isWave: true,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text('🧠 $seedName: ${tracks.length} треков'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close loading dialog
        messenger.showSnackBar(
          SnackBar(
            content: Text('Brain-радио: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  /// Build a radio station from local Subsonic library using Navidrome APIs.
  /// Combines: artist top songs + Navidrome getSimilarSongs + same-genre pool.
  Future<List<Song>> _buildServerSideRadio({required int limit}) async {
    final libraryProvider = Provider.of<LibraryProvider>(context, listen: false);
    final subsonicService = libraryProvider.subsonicService;
    final pool = <Song>[];
    final seen = <String>{};

    void addUnique(Iterable<Song> songs) {
      for (final s in songs) {
        if (seen.add(s.id)) pool.add(s);
      }
    }

    // 1) Artist's own top tracks (up to 10)
    addUnique(_topSongs.take(10));

    // 2) More tracks by the same artist from albums (deduped) - optimized: cache first + parallel
    if (libraryProvider.isLocalOnlyMode) {
      for (final album in _albums) {
        try {
          final albumSongs = await libraryProvider.getSongsByAlbumId(album.id, limit: 500);
          addUnique(albumSongs.where((s) => s.artistId == _artist!.id));
          if (pool.length >= limit) break;
        } catch (_) {}
      }
    } else {
      // Use DB songs if available (один запрос, группировка по альбомам)
      final cachedByAlbum = <String, List<Song>>{};
      try {
        final artistSongs = await libraryProvider.getSongsByArtistId(_artist!.id, limit: 1000);
        for (final s in artistSongs) {
          if (s.albumId != null) (cachedByAlbum[s.albumId!] ??= []).add(s);
        }
      } catch (_) {
        for (final s in libraryProvider.cachedAllSongs) {
          if (s.albumId != null) (cachedByAlbum[s.albumId!] ??= []).add(s);
        }
      }
      final albumsToFetch = <Album>[];
      for (final album in _albums.take(6)) {
        final cached = cachedByAlbum[album.id];
        if (cached != null && cached.isNotEmpty) {
          addUnique(cached.where((s) => s.artistId == _artist!.id));
          if (pool.length >= limit) break;
        } else {
          albumsToFetch.add(album);
        }
      }
      if (pool.length < limit && albumsToFetch.isNotEmpty) {
        try {
          final results = await Future.wait(albumsToFetch.map((a) => subsonicService.getAlbumSongs(a.id).timeout(const Duration(seconds: 6), onTimeout: () => <Song>[])));
          for (final list in results) {
            addUnique(list.where((s) => s.artistId == _artist!.id));
            if (pool.length >= limit) break;
          }
        } catch (_) {}
      }
    }

    // 2b) Navidrome similar songs parallel
    try {
      final seeds = _topSongs.take(2).toList();
      if (seeds.isNotEmpty) {
        final simResults = await Future.wait(seeds.map((seed) => subsonicService.getSimilarSongs(seed.id, count: 10).timeout(const Duration(seconds: 6), onTimeout: () => <Song>[])));
        for (final similar in simResults) {
          addUnique(similar);
          if (pool.length >= limit) break;
        }
      }
    } catch (_) {}

    // 3) Same-genre tracks from the local library (fixed bug: s.artistId != artistId)
    String? seedGenre;
    if (_topSongs.isNotEmpty) {
      seedGenre = _topSongs.first.genre;
    }
    // fallback to artist's album genre if topSongs has no genre
    seedGenre ??= _albums.isNotEmpty ? _albums.first.genre : null;
    if (seedGenre != null && seedGenre.isNotEmpty) {
      // Было: скан 80к + shuffle всего. Стало: SQL RANDOM-сэмпл по жанру.
      List<Song> genrePool;
      try {
        genrePool = await libraryProvider.getGenreSample(seedGenre, excludeArtistId: _artist!.id, limit: limit);
      } catch (_) {
        genrePool = libraryProvider.cachedAllSongs
            .where((s) => s.artistId != _artist!.id && s.genre == seedGenre)
            .take(500)
            .toList()
          ..shuffle();
      }
      addUnique(genrePool.take(limit));
    }

    // 4) Tracks by similar artists via genre clustering (fallback)
    final similarArtists = <String>{};
    if (seedGenre != null) {
      try {
        final sample = await libraryProvider.getGenreSample(seedGenre, excludeArtistId: _artist!.id, limit: 60);
        for (final s in sample) {
          if (s.artistId != null) {
            similarArtists.add(s.artistId!);
            if (similarArtists.length >= 3) break;
          }
        }
      } catch (_) {
        for (final s in libraryProvider.cachedAllSongs) {
          if (s.artistId != null &&
              s.artistId != _artist!.id &&
              s.genre == seedGenre) {
            similarArtists.add(s.artistId!);
            if (similarArtists.length >= 3) break;
          }
        }
      }
    }
    for (final id in similarArtists) {
      try {
        final top = await subsonicService.getArtistTopSongs(id);
        addUnique(top.take(5));
        if (pool.length >= limit) break;
      } catch (_) {}
    }

    // Ensure we return shuffled but limited list for variety
    pool.shuffle();
    return pool.take(limit).toList();
  }

  /// Top-up the radio with ML-scored tracks from the local library.
  Future<List<Song>> _buildMlRadioTopup({
    required List<Song> existing,
    required int limit,
  }) async {
    final libraryProvider = Provider.of<LibraryProvider>(context, listen: false);
    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
    // Было: весь 80к список в RAM + O(n*m) existing.any. Стало: стратифицированный пул 600.
    List<Song> pool;
    try {
      final exclude = existing.map((e) => e.id).toList();
      pool = await playerProvider.recommendationService?.getSongsForMixHybrid(
            excludeArtistId: _artist!.id,
            limit: 600,
            excludeIds: exclude.length > 300 ? exclude.sublist(0, 300) : exclude,
          ) ??
          [];
      if (pool.isEmpty) throw StateError('empty');
    } catch (_) {
      final seen = existing.map((e) => e.id).toSet();
      pool = libraryProvider.cachedAllSongs
          .where((s) => s.artistId != _artist!.id && seen.add(s.id))
          .take(600)
          .toList();
    }
    if (pool.isEmpty) return [];

    final mlService = MLService();
    final bannedArtists = mlService.profile.bannedArtists.toSet();

    final scored = <MapEntry<Song, double>>[];
    for (final s in pool) {
      if (s.artistId != null && bannedArtists.contains(s.artistId)) continue;
      final score = playerProvider.recommendationService?.calculateSongScore(s) ?? 0.5;
      scored.add(MapEntry(s, score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(limit).map((e) => e.key).toList();
  }

  void _openArtistImages() {
    if (_artist == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArtistImagesScreen(
          artistId: _artist!.id,
          artistName: _artist!.name,
        ),
      ),
    );
  }

  void _openArtistCoverFullscreen() {
    if (_artist?.coverArt == null) return;
    final subsonicService = Provider.of<SubsonicService>(context, listen: false);
    final coverUrl = subsonicService.getCoverArtUrl(_artist!.coverArt!, size: 0);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _FullscreenImageViewer(imageUrl: coverUrl),
      ),
    );
  }

  void _openArtistVideos() {
    if (_artist == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArtistVideosScreen(
          artistId: _artist!.id,
          artistName: _artist!.name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (_isLoading) {
      return Scaffold(backgroundColor: Colors.transparent, 
        appBar: AppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_artist == null) {
      return Scaffold(
        appBar: AppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(CupertinoIcons.wifi_slash,
                    size: 40, color: Colors.white38),
                const SizedBox(height: 12),
                Text(AppLocalizations.of(context)!.artistDataNotFound,
                    textAlign: TextAlign.center),
                const SizedBox(height: 6),
                const Text(
                  'Нет сети — откроется само при появлении соединения.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _retryLoad,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Повторить'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final albums = _albums.where((a) => (a.songCount ?? 0) >= 7).toList();
    final eps = _albums.where((a) {
      final count = a.songCount ?? 0;
      return count >= 3 && count <= 6;
    }).toList();
    final singles = _albums.where((a) => (a.songCount ?? 0) <= 2).toList();

    Album? recentRelease;
    if (_albums.isNotEmpty) {
      final withYear = _albums.where((a) => a.year != null).toList()
        ..sort((a, b) => b.year!.compareTo(a.year!));
      recentRelease = withYear.isNotEmpty ? withYear.first : _albums.first;
    }

    return Scaffold(
      floatingActionButton: _loadFailed
          ? FloatingActionButton.extended(
              onPressed: _retryLoad,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Повторить'),
            )
          : null,
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 420,
            backgroundColor: Colors.black,
            leading: Padding(
              padding: const EdgeInsets.all(8),
              child: CircleAvatar(
                backgroundColor: Colors.black.withValues(alpha: 0.4),
                child: IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: GestureDetector(
                onTap: _openArtistCoverFullscreen,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_artist!.coverArt != null)
                      CachedNetworkImage(
                        imageUrl: Provider.of<SubsonicService>(context, listen: false).getCoverArtUrl(_artist!.coverArt!, size: 800),
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Container(color: const Color(0xFF1A1A1A)),
                        errorWidget: (_, __, ___) {
                          final accent = Theme.of(context).colorScheme.primary;
                          return Container(
                            color: accent.withValues(alpha: 0.15),
                            child: Center(child: Icon(CupertinoIcons.mic_fill, size: 64, color: accent)),
                          );
                        },
                      )
                    else
                      Builder(builder: (ctx) {
                        final accent = Theme.of(context).colorScheme.primary;
                        return Container(
                          color: accent.withValues(alpha: 0.15),
                          child: Center(child: Icon(CupertinoIcons.mic_fill, size: 64, color: accent)),
                        );
                      }),
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.black.withValues(alpha: 0.15), Colors.black.withValues(alpha: 0.78)],
                          stops: const [0.42, 1.0],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 88,
                      child: Text(
                        _artist!.name,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w700, letterSpacing: 0.2, shadows: [Shadow(color: Colors.black54, blurRadius: 8)]),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 18,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Builder(builder: (ctx) {
                            final mlService = Provider.of<MLService>(context);
                            final isBanned = mlService.isArtistBanned(_artist!.id, _artist!.name);
                            return GestureDetector(
                              onTap: () {
                                showModalBottomSheet(
                                  context: context,
                                  backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                                  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
                                  builder: (sheetCtx) => SafeArea(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const SizedBox(height: 12),
                                        Container(width: 36, height: 4, decoration: BoxDecoration(color: Colors.grey[600], borderRadius: BorderRadius.circular(2))),
                                        const SizedBox(height: 12),
                                        ListTile(leading: const Icon(Icons.photo_library_rounded), title: const Text('Фото артиста'), onTap: () { Navigator.pop(sheetCtx); _openArtistImages(); }),
                                        ListTile(leading: const Icon(Icons.videocam_rounded), title: const Text('Видео'), onTap: () { Navigator.pop(sheetCtx); _openArtistVideos(); }),
                                        ListTile(leading: const Icon(Icons.radio_button_checked_rounded), title: const Text('Радио по артисту'), onTap: () { Navigator.pop(sheetCtx); _playYandexRadio(); }),
                                        // M5: долгое нажатие/меню артиста -> POST /api/wave/seed.
                                        ListTile(leading: const Icon(Icons.psychology_rounded), title: const Text('🧠 Brain-радио'), onTap: () { Navigator.pop(sheetCtx); _playBrainRadio(); }),
                                        ListTile(leading: const Icon(Icons.queue_music_rounded), title: const Text('Добавить в очередь'), onTap: () { Navigator.pop(sheetCtx); _addArtistToQueue(); }),
                                        ListTile(
                                          leading: Icon(isBanned ? Icons.block_rounded : Icons.heart_broken_rounded, color: isBanned ? Colors.red : null),
                                          title: Text(isBanned ? 'Включить в рекомендации' : 'Исключить из рекомендаций'),
                                          onTap: () {
                                            Navigator.pop(sheetCtx);
                                            if (isBanned) {
                                              mlService.unbanArtist(_artist!.id);
                                            } else {
                                              mlService.banArtist(_artist!.id, _artist!.name);
                                            }
                                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isBanned ? 'Включен в рекомендации: ${_artist!.name}' : 'Исключен: ${_artist!.name}'), duration: const Duration(seconds: 2)));
                                          },
                                        ),
                                        const SizedBox(height: 12),
                                      ],
                                    ),
                                  ),
                                );
                              },
                              child: Container(width: 44, height: 44, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), shape: BoxShape.circle, border: Border.all(color: Colors.white.withValues(alpha: 0.15))), child: const Icon(Icons.more_horiz_rounded, color: Colors.white, size: 20)),
                            );
                          }),
                          const SizedBox(width: 16),
                          GestureDetector(
                            onTap: () => _playTopSongs(shuffle: true),
                            child: Container(width: 44, height: 44, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), shape: BoxShape.circle, border: Border.all(color: Colors.white.withValues(alpha: 0.15))), child: const Icon(Icons.shuffle_rounded, color: Colors.white, size: 20)),
                          ),
                          const SizedBox(width: 12),
                          Builder(builder: (ctx) {
                            final accent = Theme.of(ctx).colorScheme.primary;
                            return GestureDetector(
                              onTap: () => _playTopSongs(),
                              child: Container(width: 56, height: 56, decoration: BoxDecoration(color: accent, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 10, offset: const Offset(0, 4))]), child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 36)),
                            );
                          }),
                           const SizedBox(width: 12),
                           Builder(builder: (context) {
                             final mlService = Provider.of<MLService>(context);
                             final isLiked = mlService.isArtistLiked(_artist!.id);
                             return GestureDetector(
                               onTap: () {
                                 mlService.likeArtist(_artist!.id, liked: !isLiked);
                                 // Подписка уходит мозгу best-effort (дальше — внешний сервис).
                                 try {
                                   final bridge = Provider.of<KumaFlowBrainBridge>(context, listen: false);
                                   if (isLiked) {
                                     bridge.unsubscribeArtistRemote(_artist!.id, _artist!.name);
                                   } else {
                                     bridge.subscribeArtistRemote(_artist!.id, _artist!.name);
                                   }
                                 } catch (_) {}
                                 ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isLiked ? 'Лайк снят: ${_artist!.name}' : 'Лайк: ${_artist!.name}'), duration: Duration(seconds: 2)));
                               },
                               child: Container(width: 44, height: 44, decoration: BoxDecoration(color: isLiked ? const Color(0xFFFF3B30) : Colors.white.withValues(alpha: 0.18), shape: BoxShape.circle, border: Border.all(color: Colors.white.withValues(alpha: 0.15))), child: Icon(isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: Colors.white, size: 20)),
                             );
                           }),
                           const SizedBox(width: 12),
                           ArtistSubscribeBell(
                             artistId: _artist!.id,
                             artistName: _artist!.name,
                             circle: true,
                           ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (recentRelease != null) ...[
                    Text('Недавний релиз', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumScreen(albumId: recentRelease!.id))),
                      child: Row(
                        children: [
                          ClipRRect(borderRadius: BorderRadius.circular(6), child: AlbumArtwork(coverArt: recentRelease.coverArt, size: 64, borderRadius: 6)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Builder(builder: (ctx) {
                                  final accent = Theme.of(ctx).colorScheme.primary;
                                  return Text('Альбом', style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w600));
                                }),
                                const SizedBox(height: 2),
                                Text(recentRelease.name, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 2),
                                Text(recentRelease.year != null ? recentRelease.year.toString() : '', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded, color: Colors.grey),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                  // Yandex: Новый релиз / последние альбомы артиста (из Яндекс Музыки)
                  if (_yandexReleasesLoading) ...[
                    Row(children: [SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 8), Text('Загрузка релизов...', style: TextStyle(color: Colors.grey[600], fontSize: 12))]),
                    const SizedBox(height: 24),
                  ] else if (_yandexNewReleases.isNotEmpty) ...[
                    Row(
                      children: [
                        Text('Новые релизы', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(width: 6),
                        Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: AppTheme.appleMusicRed.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)), child: const Text('Yandex', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.appleMusicRed))),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 184,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _yandexNewReleases.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 12),
                        itemBuilder: (context, i) {
                          final raw = _yandexNewReleases[i];
                          final albumId = raw['id']?.toString() ?? '';
                          final title = raw['title'] as String? ?? 'Альбом';
                          final year = raw['year']?.toString();
                          final coverUri = raw['coverUri'] as String? ?? raw['ogImage'] as String? ?? '';
                          final coverUrl = YandexMusicService.getCoverUrl(coverUri, size: '400x400') ?? coverUri;
                          final trackCount = raw['trackCount']?.toString() ?? '';
                          return GestureDetector(
                            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RealisesAlbumScreen(albumId: albumId, initialTitle: title, initialCoverUri: coverUri, initialArtistName: _artist?.name))),
                            child: SizedBox(
                              width: 140,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: coverUrl.isNotEmpty
                                        ? CachedNetworkImage(imageUrl: coverUrl, width: 140, height: 140, fit: BoxFit.cover, placeholder: (_, __) => Container(color: Colors.grey[900]), errorWidget: (_, __, ___) => Container(color: Colors.grey[850], child: const Icon(Icons.album_rounded, color: Colors.white24)))
                                        : Container(width: 140, height: 140, decoration: BoxDecoration(color: Colors.grey[850], borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.album_rounded, color: Colors.white24)),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 2),
                                  Text([if (year != null) year, if (trackCount.isNotEmpty) '$trackCount тр.'].join(' • '), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                  if (_topSongs.isNotEmpty) ...[
                    Row(
                      children: [
                        Text('ТОП треков', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        const Spacer(),
                        if (_topSongs.length >= 5)
                          Builder(builder: (ctx) {
                            final accent = Theme.of(ctx).colorScheme.primary;
                            return TextButton(
                              onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ArtistAllTracksScreen(
                                    artistId: _artist!.id,
                                    artistName: _artist!.name,
                                    coverArt: _artist!.coverArt,
                                    initialTracks: _topSongs,
                                  ),
                                ),
                              ),
                              child: Text('Ещё', style: TextStyle(color: accent, fontSize: 13)),
                            );
                          }),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _topSongs.take(5).length,
                      itemBuilder: (context, index) {
                        final song = _topSongs[index];
                        return SongTile(song: song, playlist: _topSongs, index: index, showAlbum: true);
                      },
                    ),
                    const SizedBox(height: 24),
                  ],
                  if (albums.isNotEmpty) ...[
                    _CollapsibleHeader(title: 'Альбомы', count: albums.length, expanded: _albumsExpanded, onToggle: () => setState(() => _albumsExpanded = !_albumsExpanded)),
                    const SizedBox(height: 8),
                    if (_albumsExpanded)
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, childAspectRatio: 0.82, crossAxisSpacing: 12, mainAxisSpacing: 12),
                        itemCount: albums.length,
                        itemBuilder: (context, i) => AlbumCard(album: albums[i], size: double.infinity, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumScreen(albumId: albums[i].id)))),
                      )
                    else
                      SizedBox(
                        height: 170,
                        child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: albums.take(6).length, separatorBuilder: (_, __) => const SizedBox(width: 12), itemBuilder: (c, i) => SizedBox(width: 140, child: AlbumCard(album: albums[i], size: 140, onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => AlbumScreen(albumId: albums[i].id)))))),
                      ),
                    const SizedBox(height: 24),
                  ],
                  if (eps.isNotEmpty) ...[
                    _CollapsibleHeader(title: 'EP и мини-альбомы', count: eps.length, expanded: _epsExpanded, onToggle: () => setState(() => _epsExpanded = !_epsExpanded)),
                    const SizedBox(height: 8),
                    if (_epsExpanded)
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, childAspectRatio: 0.82, crossAxisSpacing: 12, mainAxisSpacing: 12),
                        itemCount: eps.length,
                        itemBuilder: (context, i) => AlbumCard(album: eps[i], size: double.infinity, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumScreen(albumId: eps[i].id)))),
                      )
                    else
                      SizedBox(
                        height: 170,
                        child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: eps.take(6).length, separatorBuilder: (_, __) => const SizedBox(width: 12), itemBuilder: (c, i) => SizedBox(width: 140, child: AlbumCard(album: eps[i], size: 140, onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => AlbumScreen(albumId: eps[i].id)))))),
                      ),
                    const SizedBox(height: 24),
                  ],
                  if (singles.isNotEmpty) ...[
                    _CollapsibleHeader(title: 'Синглы', count: singles.length, expanded: _singlesExpanded, onToggle: () => setState(() => _singlesExpanded = !_singlesExpanded)),
                    const SizedBox(height: 8),
                    if (_singlesExpanded)
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, childAspectRatio: 0.82, crossAxisSpacing: 12, mainAxisSpacing: 12),
                        itemCount: singles.length,
                        itemBuilder: (context, i) => AlbumCard(album: singles[i], size: double.infinity, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumScreen(albumId: singles[i].id)))),
                      )
                    else
                      SizedBox(
                        height: 170,
                        child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: singles.take(6).length, separatorBuilder: (_, __) => const SizedBox(width: 12), itemBuilder: (c, i) => SizedBox(width: 140, child: AlbumCard(album: singles[i], size: 140, onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => AlbumScreen(albumId: singles[i].id)))))),
                      ),
                    const SizedBox(height: 24),
                  ],
                  if (_artist != null)
                    ArtistPlaylistsSection(
                        artistId: _artist!.id, artistName: _artist!.name),
                  if (_artist != null && _albums.isNotEmpty) RelatedAlbumsSection(artistName: _artist!.name, localAlbums: _albums),
                  if (_artist != null) RelatedArtistsSection(artistName: _artist!.name, localArtists: Provider.of<LibraryProvider>(context, listen: false).artists),
                  const SizedBox(height: 100),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CollapsibleHeader extends StatelessWidget {
  final String title;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;
  const _CollapsibleHeader({required this.title, required this.count, required this.expanded, required this.onToggle});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(8),
      child: Row(
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)), child: Text('$count', style: const TextStyle(fontSize: 12, color: Colors.grey))),
          const Spacer(),
          Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: Colors.grey),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _PlayButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

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
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: accent, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: accent,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Loading dialog for Yandex Radio.
class _RadioLoadingDialog extends StatefulWidget {
  const _RadioLoadingDialog();

  @override
  State<_RadioLoadingDialog> createState() => _RadioLoadingDialogState();
}

class _RadioLoadingDialogState extends State<_RadioLoadingDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final accent2 = Color.lerp(accent, Colors.orange, 0.3) ?? accent;
    return Dialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Animated radio waves - uses accent
            SizedBox(
              width: 80,
              height: 80,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      // Outer ring
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: accent.withValues(
                              alpha: 0.3 + (_controller.value * 0.3),
                            ),
                            width: 2,
                          ),
                        ),
                      ),
                      // Middle ring
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: accent2.withValues(
                              alpha: 0.4 + (_controller.value * 0.4),
                            ),
                            width: 2,
                          ),
                        ),
                      ),
                      // Inner ring
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: accent.withValues(
                              alpha: 0.5 + (_controller.value * 0.5),
                            ),
                            width: 2,
                          ),
                        ),
                      ),
                      // Center dot
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: [accent, accent2],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Loading Radio',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Fetching tracks from Yandex Music...',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),
            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                backgroundColor: const Color(0xFF2A2A2A),
                valueColor: AlwaysStoppedAnimation<Color>(
                  Color.lerp(
                    accent,
                    accent2,
                    _controller.value,
                  )!,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FullscreenImageViewer extends StatelessWidget {
  final String imageUrl;
  const _FullscreenImageViewer({required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5.0,
          child: CachedNetworkImage(
            imageUrl: imageUrl,
            fit: BoxFit.contain,
            placeholder: (_, __) => const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
            errorWidget: (_, __, ___) => const Center(
              child: Icon(Icons.error, color: Colors.white54, size: 48),
            ),
          ),
        ),
      ),
    );
  }
}
