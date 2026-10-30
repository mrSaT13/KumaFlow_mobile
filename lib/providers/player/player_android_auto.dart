part of '../player_provider.dart';

/// Android Auto: инициализация колбэков, browse/search/play, обложки,
/// публикация состояния воспроизведения.
extension PlayerAndroidAuto on PlayerProvider {
  void _initializeAndroidAuto() {
    _androidAutoService.initialize();

    _androidAutoService.onPlay = play;
    _androidAutoService.onPause = pause;
    _androidAutoService.onStop = stop;
    _androidAutoService.onSkipNext = skipNext;
    _androidAutoService.onSkipPrevious = skipPrevious;
    _androidAutoService.onSeekTo = seek;
    _androidAutoService.onPlayFromMediaId = _playFromMediaId;
    _androidAutoService.onSetVolume = _onRemoteVolumeChange;

    _androidAutoService.onGetAlbumSongs = _getAlbumSongsForAndroidAuto;
    _androidAutoService.onGetArtistAlbums = _getArtistAlbumsForAndroidAuto;
    _androidAutoService.onGetPlaylistSongs = _getPlaylistSongsForAndroidAuto;
    _androidAutoService.onSearch = _searchForAndroidAuto;
    _androidAutoService.onPlayFromSearch = _playFromSearchForAndroidAuto;
    _androidAutoService.onRequestLibraryData = _onRequestLibraryData;
  }

  void _onRequestLibraryData() {
    debugPrint(
        'PlayerProvider: Android Auto requested library data, delegating to LibraryProvider');
    // The LibraryProvider handles this in its constructor, but we add this
    // as a fallback to ensure the request is handled
    if (_libraryProvider != null) {
      // Trigger a re-push of library data via the LibraryProvider
      // This is handled by the callback registered in LibraryProvider's constructor
    }
  }

  Future<List<Map<String, String>>> _getAlbumSongsForAndroidAuto(
    String albumId,
  ) async {
    if (_offlineService.isOfflineMode && _libraryProvider != null) {
      await _offlineService.initialize();
      final downloadedIds = _offlineService.getDownloadedSongIds().toSet();
      // Было: фильтр 80к кэша. Стало: песни альбома из БД + фильтр скачанных.
      List<Song> albumSongs;
      try {
        albumSongs = await _libraryProvider!.getSongsByAlbumId(albumId, limit: 500);
      } catch (_) {
        albumSongs = _libraryProvider!.cachedAllSongs
            .where((s) => s.albumId == albumId)
            .toList();
      }
      final offlineSongs = albumSongs
          .where((s) => downloadedIds.contains(s.id))
          .toList();
      if (offlineSongs.isNotEmpty) {
        return offlineSongs
            .map(
              (song) {
                final local = _offlineService.getLocalCoverForSong(
                  albumId: song.albumId,
                  coverArt: song.coverArt,
                  trackId: song.id,
                );
                return {
                  'id': song.id,
                  'title': song.title,
                  'artist': song.artist ?? '',
                  'album': song.album ?? '',
                  'artworkUrl': local != null
                      ? Uri.file(local).toString()
                      : _resolveCoverUrl(song.coverArt, size: 300),
                  'duration': (song.duration ?? 0).toString(),
                };
              },
            )
            .toList();
      }
    }
    try {
      final songs = await _subsonicService.getAlbumSongs(albumId);
      return songs
          .map(
            (song) => {
              'id': song.id,
              'title': song.title,
              'artist': song.artist ?? '',
              'album': song.album ?? '',
                'artworkUrl': _resolveCoverUrl(song.coverArt, size: 300),
              'duration': (song.duration ?? 0).toString(),
            },
          )
          .toList();
    } catch (e) {
      debugPrint('Error getting album songs for Android Auto: $e');
      return [];
    }
  }

  Future<List<Map<String, String>>> _getArtistAlbumsForAndroidAuto(
    String artistId,
  ) async {
    if (_offlineService.isOfflineMode && _libraryProvider != null) {
      await _offlineService.initialize();
      final downloadedIds = _offlineService.getDownloadedSongIds().toSet();
      // Было: фильтр 80к кэша. Стало: песни артиста из БД + фильтр скачанных.
      List<Song> artistSongs;
      try {
        artistSongs = await _libraryProvider!.getSongsByArtistId(artistId, limit: 1000);
      } catch (_) {
        artistSongs = _libraryProvider!.cachedAllSongs
            .where((s) => s.artistId == artistId)
            .toList();
      }
      final albumIdsWithDownloads = artistSongs
          .where((s) => downloadedIds.contains(s.id))
          .map((s) => s.albumId)
          .whereType<String>()
          .toSet();
      final offlineAlbums = _libraryProvider!.cachedAllAlbums
          .where((a) => albumIdsWithDownloads.contains(a.id))
          .toList();
      if (offlineAlbums.isNotEmpty) {
        return offlineAlbums
            .map(
              (album) => {
                'id': album.id,
                'name': album.name,
                'artist': album.artist ?? '',
                'artworkUrl': _resolveCoverUrl(album.coverArt, size: 300),
              },
            )
            .toList();
      }
    }
    try {
      final albums = await _subsonicService.getArtistAlbums(artistId);
      return albums
          .map(
            (album) => {
              'id': album.id,
              'name': album.name,
              'artist': album.artist ?? '',
              'artworkUrl': _resolveCoverUrl(album.coverArt,
                size: 300,
              ),
            },
          )
          .toList();
    } catch (e) {
      debugPrint('Error getting artist albums for Android Auto: $e');
      return [];
    }
  }

  Future<List<Map<String, String>>> _getPlaylistSongsForAndroidAuto(
    String playlistId,
  ) async {
    if (_offlineService.isOfflineMode && _libraryProvider != null) {
      await _offlineService.initialize();
      final downloadedIds = _offlineService.getDownloadedSongIds().toSet();
      final cachedPlaylist = _libraryProvider!.playlists
          .where((p) => p.id == playlistId)
          .firstOrNull;
      if (cachedPlaylist?.songs != null && cachedPlaylist!.songs!.isNotEmpty) {
        final offlineSongs = cachedPlaylist.songs!
            .where((s) => downloadedIds.contains(s.id))
            .toList();
        if (offlineSongs.isNotEmpty) {
          return offlineSongs
              .map(
                (song) {
                  final local = _offlineService.getLocalCoverForSong(
                    albumId: song.albumId,
                    coverArt: song.coverArt,
                    trackId: song.id,
                  );
                  return {
                    'id': song.id,
                    'title': song.title,
                    'artist': song.artist ?? '',
                    'album': song.album ?? '',
                    'artworkUrl': local != null
                        ? Uri.file(local).toString()
                        : _resolveCoverUrl(song.coverArt, size: 300),
                    'duration': (song.duration ?? 0).toString(),
                  };
                },
              )
              .toList();
        }
      }
    }
    try {
      final playlist = await _subsonicService.getPlaylist(playlistId);
      final songs = playlist.songs ?? [];
      return songs
          .map(
            (song) => {
              'id': song.id,
              'title': song.title,
              'artist': song.artist ?? '',
              'album': song.album ?? '',
                'artworkUrl': _resolveCoverUrl(song.coverArt, size: 300),
              'duration': (song.duration ?? 0).toString(),
            },
          )
          .toList();
    } catch (e) {
      debugPrint('Error getting playlist songs for Android Auto: $e');
      return [];
    }
  }

  Future<List<Map<String, String>>> _searchForAndroidAuto(
    String query,
  ) async {
    debugPrint(
        'PlayerProvider: _searchForAndroidAuto called with query="$query"');
    debugPrint(
        'PlayerProvider: isOfflineMode=${_offlineService.isOfflineMode}, libraryProvider=$_libraryProvider');

    if (_offlineService.isOfflineMode && _libraryProvider != null) {
      await _offlineService.initialize();
      final downloadedIds = _offlineService.getDownloadedSongIds().toSet();
      // Было: скан 80к кэша. Стало: SQL-поиск + фильтр скачанных.
      List<Song> offlineResults;
      try {
        final hits = await _libraryProvider!.searchDbAsync(query, limit: 100);
        offlineResults = hits.songs.where((s) => downloadedIds.contains(s.id)).take(20).toList();
      } catch (_) {
        final lowerQuery = query.toLowerCase();
        offlineResults = _libraryProvider!.cachedAllSongs
            .where(
              (s) =>
                  downloadedIds.contains(s.id) &&
                  (s.title.toLowerCase().contains(lowerQuery) ||
                      (s.artist?.toLowerCase().contains(lowerQuery) ?? false) ||
                      (s.album?.toLowerCase().contains(lowerQuery) ?? false)),
            )
            .take(20)
            .toList();
      }
      return offlineResults
          .map(
            (song) {
              final local = _offlineService.getLocalCoverForSong(
                albumId: song.albumId,
                coverArt: song.coverArt,
                trackId: song.id,
              );
              return {
                'id': song.id,
                'title': song.title,
                'artist': song.artist ?? '',
                'album': song.album ?? '',
                'artworkUrl': local != null
                    ? Uri.file(local).toString()
                    : _resolveCoverUrl(song.coverArt, size: 300),
                'duration': (song.duration ?? 0).toString(),
              };
            },
          )
          .toList();
    }
    try {
      debugPrint(
          'PlayerProvider: Calling subsonicService.search with query="$query"');
      final results = await _subsonicService.search(
        query,
        songCount: 20,
        albumCount: 0,
        artistCount: 0,
      );
      debugPrint(
          'PlayerProvider: Search returned ${results.songs.length} songs');
      return results.songs
          .map(
            (song) => {
              'id': song.id,
              'title': song.title,
              'artist': song.artist ?? '',
              'album': song.album ?? '',
                'artworkUrl': _resolveCoverUrl(song.coverArt, size: 300),
              'duration': (song.duration ?? 0).toString(),
            },
          )
          .toList();
    } catch (e, stackTrace) {
      debugPrint('PlayerProvider: Android Auto search error: $e');
      debugPrint('PlayerProvider: Stack trace: $stackTrace');
      return [];
    }
  }

  Future<void> _playFromSearchForAndroidAuto(String query) async {
    debugPrint('Android Auto: playFromSearch called with query: "$query"');
    try {
      if (query.trim().isEmpty) {
        if (_currentSong != null) {
          await play();
        } else if (_libraryProvider != null &&
            _libraryProvider!.randomSongs.isNotEmpty) {
          final songs = _libraryProvider!.randomSongs;
          await playSong(songs.first, playlist: songs, startIndex: 0);
        }
        return;
      }

      final results = await _subsonicService.search(
        query,
        songCount: 20,
        albumCount: 0,
        artistCount: 0,
      );
      if (results.songs.isNotEmpty) {
        await playSong(
          results.songs.first,
          playlist: results.songs,
          startIndex: 0,
        );
      } else {
        debugPrint('Android Auto: no search results for "$query"');
      }
    } catch (e) {
      debugPrint('Android Auto: playFromSearch error: $e');
    }
  }

  Future<void> _playFromMediaId(String mediaId) async {
    debugPrint('Android Auto: playFromMediaId called with: $mediaId');

    final queueIndex = _queue.indexWhere((song) => song.id == mediaId);
    if (queueIndex != -1) {
      await skipToIndex(queueIndex);
      return;
    }

    if (_libraryProvider != null) {
      final randomSongs = _libraryProvider!.randomSongs;
      final songIndex = randomSongs.indexWhere((song) => song.id == mediaId);
      if (songIndex != -1) {
        await playSong(
          randomSongs[songIndex],
          playlist: randomSongs,
          startIndex: songIndex,
        );
        return;
      }
    }

    try {
      final searchResults = await _subsonicService.search(
        mediaId,
        songCount: 5,
      );
      if (searchResults.songs.isNotEmpty) {
        final song = searchResults.songs.firstWhere(
          (s) => s.id == mediaId,
          orElse: () => searchResults.songs.first,
        );
        await playSong(song);
        return;
      }

      debugPrint('Android Auto: Could not find song with id: $mediaId');
    } catch (e) {
      debugPrint('Android Auto: Error fetching song: $e');
    }
  }

  String? _resolveArtworkUrl() {
    if (_currentSong == null) return null;
    if (_currentSong!.coverArt == null) return null;
    if (_isHttpCover(_currentSong!.coverArt)) return _currentSong!.coverArt;
    if (_currentSong!.isLocal) {
      return Uri.file(_currentSong!.coverArt!).toString();
    }

    return _resolvedArtworkUrl;
  }

  Future<void> _refreshArtworkUrl() async {
    final song = _currentSong;
    if (song == null || song.coverArt == null) {
      _resolvedArtworkUrl = null;
      return;
    }
    if (_isHttpCover(song.coverArt)) {
      _resolvedArtworkUrl = song.coverArt;
      if (_currentSong?.queueKey == song.queueKey) {
        _updateAllServices();
        _updateAndroidAuto();
      }
      return;
    }
    if (song.isLocal) {
      _resolvedArtworkUrl = Uri.file(song.coverArt!).toString();
      return;
    }

    await _offlineService.initialize();

    final localPath = _offlineService.getLocalCoverForSong(
      albumId: song.albumId,
      coverArt: song.coverArt,
      trackId: song.id,
    );
    if (localPath != null) {
      _resolvedArtworkUrl = Uri.file(localPath).toString();
      if (_currentSong?.queueKey == song.queueKey) _updateAllServices();
      return;
    }

    final coverArtId = song.coverArt!;
    final serverSuffix = song.sourceServerId ?? 'main';

    // Search for cached artwork from highest to lowest quality for iOS Now Playing.
    // AlbumArtwork пишет ключи main_<cover>_<size>, ищем с префиксом тоже.
    for (final sz in [1200, 800, 600, 400, 300, 200]) {
      for (final key in [
        '${serverSuffix}_${coverArtId}_natural_$sz',
        '${serverSuffix}_${coverArtId}_$sz',
        'main_${coverArtId}_natural_$sz',
        'main_${coverArtId}_$sz',
        '${coverArtId}_natural_$sz',
        '${coverArtId}_$sz'
      ]) {
        try {
          final fileInfo = await SafeImageCacheManager.instance.getFileFromCache(key);
          if (fileInfo != null && fileInfo.file.existsSync()) {
            if (_currentSong?.queueKey == song.queueKey) {
              _resolvedArtworkUrl = Uri.file(fileInfo.file.path).toString();
              _updateAllServices();
            }
            return;
          }
          // Fallback to the legacy default manager for any pre-fix caches.
          final legacyInfo = await DefaultCacheManager().getFileFromCache(key);
          if (legacyInfo != null && legacyInfo.file.existsSync()) {
            if (_currentSong?.queueKey == song.queueKey) {
              _resolvedArtworkUrl = Uri.file(legacyInfo.file.path).toString();
              _updateAllServices();
            }
            return;
          }
        } catch (_) {}
      }
    }
    // Request high quality for iOS Now Playing bar / Control Center (1200px)
    final serverUrl = _resolveCoverUrl(coverArtId, size: 1200, song: song);

    if (!_offlineService.isOfflineMode) {
      _resolvedArtworkUrl = serverUrl;
      if (_currentSong?.queueKey == song.queueKey) _updateAllServices();
    }
  }

  void _updateAndroidAuto() {
    if (_currentSong == null) return;

    final artworkUrl = _resolveArtworkUrl();

    final effectiveDuration = _duration.inMilliseconds > 0
        ? _duration
        : Duration(seconds: _currentSong!.duration ?? 0);

    _androidAutoService.updatePlaybackState(
      songId: _currentSong!.id,
      title: _currentSong!.title,
      artist: _currentSong!.artist ?? '',
      album: _currentSong!.album ?? '',
      artworkUrl: artworkUrl,
      duration: effectiveDuration,
      position: _position,
      isPlaying: _isPlaying,
    );

    // Update the audio_service handler so lock screen / Control Center / iOS
    // Now Playing info stays accurate regardless of the UI lifecycle.
    _audioHandler.updateNowPlaying(
      id: _currentSong!.id,
      title: _currentSong!.title,
      artist: _currentSong!.artist,
      album: _currentSong!.album,
      artworkUrl: artworkUrl,
      duration: effectiveDuration,
    );
    _audioHandler.setCurrentSongStarred(_currentSong!.starred == true);

    _updateDiscordRpc();
    _updateAllServices();
  }
}
