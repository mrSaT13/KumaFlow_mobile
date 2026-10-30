// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// Part of the PlayerProvider library: extension calls notifyListeners()
// on its own instance — same library, no behavior change.
part of '../player_provider.dart';

/// Gapless-источники: построение AudioSource, окно concatenating,
/// preload следующих треков, смена индекса.
extension PlayerSources on PlayerProvider {
  int _queueToConcatIndex(int queueIndex) => queueIndex - _windowStart;

  bool _concatHasQueueIndex(int queueIndex) =>
      _concatenatingSource != null &&
      queueIndex >= _windowStart &&
      queueIndex < _windowStart + _concatenatingSource!.length;

  Future<AudioSource> _buildAudioSourceForSong(Song song) async {
    // Трек уже умирал в этой сессии — источник не строим, пропускаем.
    if (_deadStreamKeys.contains(song.queueKey)) {
      debugPrint('[Player] skip session-dead stream "${song.title}"');
      throw Exception('Stream marked dead this session');
    }
    // Podcast: сначала проверяем локальный кэш для офлайна
    if (_isPodcastSong(song)) {
      final cleanId = song.id.replaceFirst('podcast:', '');
      final podPath = _offlineService.getPodcastLocalPath(cleanId) ?? _offlineService.getPodcastLocalPath(song.id) ?? _offlineService.getLocalPath(cleanId) ?? _offlineService.getLocalPath(song.id);
      if (podPath != null) {
        return AudioSource.uri(Uri.file(podPath), tag: song.id);
      }
      // Также пробуем по id эпизода без префикса
      final altPath = _offlineService.getPodcastLocalPath(song.id);
      if (altPath != null) return AudioSource.uri(Uri.file(altPath), tag: song.id);
      if (song.path != null && (song.path!.startsWith('http://') || song.path!.startsWith('https://'))) {
        return AudioSource.uri(Uri.parse(song.path!), tag: song.id);
      }
    }
    // Use preloaded source if available (from BPM crossfade preload)
    if (_preloadedSources.containsKey(song.queueKey)) {
      return _preloadedSources.remove(song.queueKey)!;
    }
    if (_preloadedSources.containsKey(song.id)) {
      return _preloadedSources.remove(song.id)!;
    }
    if (song.isLocal == true && song.path != null) {
      // Prevent hang on missing file — fail fast so Future.wait can skip it
      try {
        final f = File(song.path!);
        if (!await f.exists().timeout(const Duration(seconds: 2), onTimeout: () => false)) {
          debugPrint('[Player] local file missing: ${song.path}');
          throw Exception('Local file not found: ${song.path}');
        }
      } catch (e) {
        if (e.toString().contains('Local file not found')) rethrow;
        debugPrint('[Player] exists check failed for ${song.path}: $e');
      }
      final localSource = AudioSource.uri(Uri.file(song.path!), tag: song.id);
      if (song.absStart != null && song.absEnd != null && song.absEnd! > song.absStart!) {
        return ClippingAudioSource(
          child: localSource,
          start: Duration(milliseconds: (song.absStart! * 1000).round()),
          end: Duration(milliseconds: (song.absEnd! * 1000).round()),
          tag: song.id,
        );
      }
      return localSource;
    }
    // Audiobookshelf: check offline cache first (supports clipping even offline)
    if (song.id.startsWith('abs_')) {
      final offlinePath = _offlineService.getLocalPath(song.id);
      if (offlinePath != null) {
        final baseSource = AudioSource.uri(Uri.file(offlinePath), tag: song.id);
        if (song.absStart != null && song.absEnd != null && song.absEnd! > song.absStart!) {
          return ClippingAudioSource(
            child: baseSource,
            start: Duration(milliseconds: (song.absStart! * 1000).round()),
            end: Duration(milliseconds: (song.absEnd! * 1000).round()),
            tag: song.id,
          );
        }
        return baseSource;
      }
      // Try book file cache: extract itemId/fileId from path
      if (song.path != null && song.path!.contains('/api/items/')) {
        final baseSource = AudioSource.uri(Uri.parse(song.path!), tag: song.id);
        if (song.absStart != null && song.absEnd != null && song.absEnd! > song.absStart!) {
          return ClippingAudioSource(
            child: baseSource,
            start: Duration(milliseconds: (song.absStart! * 1000).round()),
            end: Duration(milliseconds: (song.absEnd! * 1000).round()),
            tag: song.id,
          );
        }
        return baseSource;
      }
    }
    final offlinePath = _offlineService.getLocalPath(song.queueKey) ??
        _offlineService.getLocalPath(song.id);
    if (offlinePath != null) {
      return AudioSource.uri(Uri.file(offlinePath), tag: song.queueKey);
    }
    // Collab: stream URL с сервера-владельца трека (трек друга — его URL).
    final tActive =
        _transcodingService.enabled || _transcodingService.smartEnabled;
    final tBitRate =
        tActive ? _transcodingService.currentBitRate : null;
    final tFormat =
        tActive ? _transcodingService.format : null;
    // YouTube: прокси StreamAudioSource (сырой URL дает 403 в ExoPlayer,
    // трек обрывается на первых секундах).
    try {
      final ytSource = await _subsonicService
          .getYoutubeAudioSource(song)
          .timeout(const Duration(seconds: 8));
      if (ytSource != null) return ytSource;
    } catch (_) {}
    final url = await _multiServerResolver.resolveStreamUrl(song,
        maxBitRate: tBitRate, format: tFormat);
    // Cache remote streams locally so seeking works even when the server
    // transcodes and doesn't support HTTP range requests (issue #170).
    final cacheDir = await getTemporaryDirectory();
    final cacheFile = File(
      '${cacheDir.path}/${_streamCacheName(song)}',
    );
    // ignore: experimental_member_use
    return LockCachingAudioSource(
      Uri.parse(url),
      cacheFile: cacheFile,
      tag: song.queueKey,
    );
  }

  Future<void> _buildAndSetConcatenatingSource(
      {required int initialIndex, Duration? initialPosition}) async {
    // Снапшот + токен: очередь может мутировать (AutoDJ addAll, remove,
    // reorder, дизлайк-чистка) пока строятся AudioSource. Устаревший результат
    // отбрасываем вместо RangeError/OOB и неверного adjustedIndex.
    var buildQueue = List<Song>.from(_queue);
    if (buildQueue.isEmpty) throw Exception('Queue is empty');
    var safeInitial = initialIndex.clamp(0, buildQueue.length - 1);
    final currentKey = buildQueue[safeInitial].queueKey;
    final myToken = ++_sourceBuildToken;
    // Окно вместо всей очереди: concatenating[i] == queue[start + i].
    // На тысячах треков полная сборка = OOM + ANR, окно — максимум
    // _kGaplessWindowSize источников вокруг текущего.
    int windowStartFor(int totalLen, int initial) {
      if (totalLen <= PlayerProvider._kGaplessWindowSize) return 0;
      final maxStart = totalLen - PlayerProvider._kGaplessWindowSize;
      return (initial - PlayerProvider._kGaplessKeepBefore).clamp(0, maxStart);
    }
    // Build sources with per-track timeout and skip failed tracks to avoid hang on 1 bad file.
    // Bounded concurrency пачками по 8: Future.wait() по всей очереди из
    // сотен треков устраивал thundering herd (сотни stat/network/file
    // параллельно в UI-изоляте) — OOM, ANR и флуд «skip unplayable» в логе.
    // Пачки сохраняют порядок results и отдают кадры event loop между чанками.
    Future<AudioSource?> buildOne(Song s) => _buildAudioSourceForSong(s)
        .timeout(const Duration(seconds: 6), onTimeout: () {
          debugPrint('[Player] timeout building source for "${s.title}"');
          throw TimeoutException('Source build timeout for ${s.id}');
        })
        .then<AudioSource?>((v) => v)
        .catchError((e) {
          debugPrint('[Player] skip unplayable track "${s.title}": $e');
          return null;
        });

    Future<List<AudioSource?>?> buildWindow(List<Song> w) async {
      final results = List<AudioSource?>.filled(w.length, null);
      const chunkSize = 8;
      for (var i = 0; i < w.length; i += chunkSize) {
        // Пока строили чанк — стартовала более новая сборка: бросаем эту.
        if (myToken != _sourceBuildToken) {
          debugPrint('[Player] dropping stale concatenating build (token $myToken)');
          return null;
        }
        final end = (i + chunkSize).clamp(0, w.length);
        final chunk = await Future.wait(
          List.generate(end - i, (k) => buildOne(w[i + k])),
        );
        for (var k = 0; k < chunk.length; k++) {
          results[i + k] = chunk[k];
        }
      }
      return results;
    }

    var start = windowStartFor(buildQueue.length, safeInitial);
    var end = (start + PlayerProvider._kGaplessWindowSize).clamp(0, buildQueue.length);
    var window = buildQueue.sublist(start, end);
    var results = await buildWindow(window);
    // Пока строили — стартовала более новая сборка (скип/дизлайк/досборка):
    // этот результат устарел, отбрасываем.
    if (results == null) {
      debugPrint('[Player] dropping stale concatenating build (token $myToken)');
      return;
    }
    // Битые внутри окна — выкидываем из очереди (как раньше) и пересобираем
    // окно один раз, чтобы маппинг окно<->очередь остался плотным 1:1.
    if (results.any((r) => r == null)) {
      final deadKeys = <String>{};
      for (var i = 0; i < window.length; i++) {
        if (results[i] == null) deadKeys.add(window[i].queueKey);
      }
      _deadStreamKeys.addAll(deadKeys);
      buildQueue =
          buildQueue.where((s) => !deadKeys.contains(s.queueKey)).toList();
      if (buildQueue.isEmpty) {
        throw Exception('No playable sources in queue');
      }
      _queue = buildQueue;
      safeInitial = buildQueue
          .indexWhere((s) => s.queueKey == currentKey)
          .clamp(0, buildQueue.length - 1);
      start = windowStartFor(buildQueue.length, safeInitial);
      end = (start + PlayerProvider._kGaplessWindowSize).clamp(0, buildQueue.length);
      window = buildQueue.sublist(start, end);
      results = await buildWindow(window);
      if (results == null) {
        debugPrint('[Player] dropping stale concatenating build (token $myToken)');
        return;
      }
      if (results.any((r) => r == null)) {
        throw Exception('No playable sources in window');
      }
    }
    if (myToken != _sourceBuildToken) {
      debugPrint('[Player] dropping stale concatenating build (token $myToken)');
      return;
    }
    final children = results.whereType<AudioSource>().toList();
    if (children.isEmpty) {
      throw Exception('No playable sources in queue (${buildQueue.length} tracks)');
    }
    _windowStart = start;
    final adjustedIndex = safeInitial - start;
    debugPrint('[Player] concatenating window: $_windowStart..${start + children.length} '
        'of ${buildQueue.length} (initial=$adjustedIndex)');

    _concatenatingSource = ConcatenatingAudioSource(children: children);
    // Avoid deadlock if previous source still loading — stop first
    try {
      await _audioPlayer.stop().timeout(const Duration(seconds: 2));
    } catch (_) {}
    await _audioPlayer.setAudioSource(
      _concatenatingSource!,
      initialIndex: adjustedIndex,
      initialPosition: initialPosition,
      preload: true,
    ).timeout(const Duration(seconds: 12), onTimeout: () {
      throw TimeoutException('setAudioSource timeout');
    });
  }

  /// Достройка окна вперёд по мере дослушивания (gapless-автодвижение).
  /// append через .add() — без пересборки и заикания. Потолок
  /// _kGaplessMaxSources, дальше дальние прыжки идут через playSong.
  Future<void> _maybeExtendWindow() async {
    try {
      final src = _concatenatingSource;
      if (src == null || !_gaplessEnabled || _currentIndex < 0) return;
      final windowEnd = _windowStart + src.length;
      if (_currentIndex < windowEnd - 10) return;
      if (windowEnd >= _queue.length) return;
      if (src.length >= PlayerProvider._kGaplessMaxSources) return;
      final myToken = _sourceBuildToken;
      final addEnd = (windowEnd + 24).clamp(0, _queue.length);
      for (var qi = windowEnd; qi < addEnd; qi++) {
        if (myToken != _sourceBuildToken) return;
        if (_concatenatingSource != src) return;
        // Очередь могла мутировать — сверяем границу.
        if (_windowStart + src.length != qi) return;
        try {
          final source = await _buildAudioSourceForSong(_queue[qi])
              .timeout(const Duration(seconds: 6));
          if (myToken != _sourceBuildToken || _concatenatingSource != src) {
            return;
          }
          if (_windowStart + src.length != qi) return;
          src.add(source);
        } catch (e) {
          debugPrint('[Player] extend window skip: $e');
          _deadStreamKeys.add(_queue[qi].queueKey);
          return;
        }
      }
      debugPrint('[Player] window extended to ${_windowStart + src.length} of ${_queue.length}');
    } catch (e) {
      debugPrint('[Player] extend window error: $e');
    }
  }

  /// Preload the next 2 tracks in the queue for smooth BPM crossfade transitions.
  /// Called after a track starts playing. Resolves stream URLs and begins
  /// caching so the audio is ready when the crossfade point is reached.
  void _preloadNextTracks() {
    if (_queue.isEmpty || _currentIndex < 0) return;
    // Не сносим всё: оставляем источники следующих 2 треков (они ещё
    // пригодятся), удаляем только дальние/устаревшие.
    final keep = <String>{};
    const preloadCount = 2;
    for (int i = 1; i <= preloadCount; i++) {
      final nextIndex = _currentIndex + i;
      if (nextIndex >= _queue.length) break;
      keep.add(_queue[nextIndex].queueKey);
    }
    _preloadedSources.removeWhere((k, _) => !keep.contains(k));

    for (int i = 1; i <= preloadCount; i++) {
      final nextIndex = _currentIndex + i;
      if (nextIndex >= _queue.length) break;
      final song = _queue[nextIndex];
      if (_preloadedSources.containsKey(song.queueKey)) continue;

      _buildAudioSourceForSong(song).then((source) {
        _preloadedSources[song.queueKey] = source;
        debugPrint('[Player] ⚡ Preloaded track $i: "${song.title}"');
      }).catchError((e) {
        debugPrint('[Player] ⚡ Preload failed for "${song.title}": $e');
      });
    }
  }

  Future<void> _prepareCurrentSong() async {
    if (_currentSong == null) return;
    // When jukebox mode is active, the server handles playback.
    if (_jukeboxService.enabled) return;
    try {
      if (_gaplessEnabled && _queue.isNotEmpty) {
        await _buildAndSetConcatenatingSource(initialIndex: _currentIndex);
      } else {
        final String playUrl;
        if (_currentSong!.isLocal == true && _currentSong!.path != null) {
          playUrl = Uri.file(_currentSong!.path!).toString();
        } else {
          final offlinePath =
              _offlineService.getLocalPath(_currentSong!.queueKey) ??
                  _offlineService.getLocalPath(_currentSong!.id);
          if (offlinePath != null) {
            playUrl = 'file://$offlinePath';
          } else {
            playUrl =
                await _multiServerResolver.resolveStreamUrl(_currentSong!);
          }
        }
        if (_currentSong!.isLocal == true ||
            _offlineService.getLocalPath(_currentSong!.queueKey) != null ||
            _offlineService.getLocalPath(_currentSong!.id) != null) {
          await _audioPlayer.setUrl(playUrl);
        } else {
          final cacheDir = await getTemporaryDirectory();
          final cacheFile = File(
            '${cacheDir.path}/${_streamCacheName(_currentSong!)}',
          );
          // ignore: experimental_member_use
          await _audioPlayer.setAudioSource(
            // ignore: experimental_member_use
            LockCachingAudioSource(
              Uri.parse(playUrl),
              cacheFile: cacheFile,
              tag: _currentSong!.queueKey,
            ),
          );
        }
      }
      // Seek to the restored position after the source is loaded
      if (_position.inMilliseconds > 0) {
        await _audioPlayer.seek(_position);
      }
    } catch (e) {
      debugPrint('Error preparing current song after restore: $e');
    }
  }

  /// Handles a track that started via gapless queue auto-advance
  /// ([_onCurrentIndexChanged]) instead of [playSong]: sends now-playing
  /// scrobble to the server and logs ML play signals. Skipped when
  /// [playSong] just tracked the same queueKey (within 10s).
  void _trackGaplessNewSong() {
    final song = _currentSong;
    if (song == null || _isPodcastSong(song)) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastTrackPlayKey == song.queueKey && now - _lastTrackPlayMs < 10000) {
      return;
    }
    if (song.isLocal == true) {
      _stopNowPlayingTimer();
      return;
    }
    _trackPlay();
    if (_offlineService.isOfflineMode) {
      _offlineService.queueScrobble(song.id, submission: false);
    } else {
      _multiServerResolver.scrobble(song, submission: false).catchError((e) {
        _offlineService.queueScrobble(song.id, submission: false);
      });
      _offlineService
          .flushPendingScrobbles(_subsonicService)
          .catchError((e) {
        debugPrint('Scrobble flush failed: $e');
      });
    }
    _startNowPlayingTimer();
    // История — только по порогу через _maybeCommitHistory (см. playSong):
    // gapless-старт за 0 сек не считается прослушиванием.
  }

  Future<void> _onCurrentIndexChanged(int newIndex) async {
    if (newIndex < 0 || newIndex >= _queue.length) return;
    if (newIndex == _currentIndex) return;

    debugPrint(
        '[Player] ⏭ Track changed by index: $newIndex "${_queue[newIndex].title}"');

    // Sleep timer: end after current song
    if (_sleepTimerEndCurrentSong) {
      _doSleepTimerStop();
      return;
    }

    // Track completion of the previous song — skip podcasts
    if (!_isPodcastSong(_currentSong) && _currentSong != null) {
      // A track the user explicitly skipped (skipNext logged it) must NOT be
      // reported as fully played: no submission, no completion event.
      final wasSkipped = _currentSong!.id == _lastSkipLoggedId;
      _lastSkipLoggedId = null;
      if (!wasSkipped) {
        if (_currentSong!.isLocal != true) {
          _subsonicService
              .scrobble(_currentSong!.id, submission: true)
              .catchError(
            (e) {
              _offlineService.queueScrobble(_currentSong!.id, submission: true);
            },
          );
        }
        // Gapless-дослушивание: предыдущий трек играл до конца — порог пройден.
        _maybeCommitHistory(_currentSong!, _duration.inSeconds, _duration.inSeconds, force: true);
        // Аналитика «что я слушал уже» (включая подкасты — см. recordListen).
        unawaited(_recordAnalytics(_currentSong!, _duration.inMilliseconds, true));
      }
    }

    // AutoDJ: add songs near end of queue - respect audiobook toggle — skip for podcasts
    if (!_isPodcastSong(_currentSong) && _autoDjService.shouldAddSongsFor(newIndex, _queue.length, _currentSong)) {
      unawaited(_addAutoDjSongs());
    }

    _currentIndex = newIndex;
    _currentSong = _queue[_currentIndex];
    _position = Duration.zero;
    _resolvedArtworkUrl = null;
    notifyListeners();
    _saveQueueState();

    // Gapless auto-advance path: the new track never goes through playSong(),
    // so report now-playing + track ML signals here (deduped against a
    // playSong() that just handled the same queueKey).
    _trackGaplessNewSong();

    // Было: переход ждал сеть (обложка/текст) — при деградированном uplink
    // каждый автопереход висел. Обложка/текст догоняют фоном.
    final arrivedSong = _currentSong;
    unawaited(_refreshArtworkUrl().then((_) {
      if (_currentSong?.queueKey != arrivedSong?.queueKey) return;
      _updateAllServices();
      _updateAndroidAuto();
    }));
    if (arrivedSong != null) {
      unawaited(_loadAndSyncLyrics(arrivedSong).then((_) async {
        if (_currentSong?.queueKey != arrivedSong.queueKey) return;
        try {
          await _lyricsService.updateSongInfo(
            title: arrivedSong.title,
            artist: arrivedSong.artist ?? 'Unknown Artist',
            artworkUrl: _resolvedArtworkUrl ?? arrivedSong.coverArt,
          );
        } catch (_) {}
      }));
      await _applyReplayGain(arrivedSong);
    }

    _updateAllServices();
    _preloadNextTracks();
    _updateAndroidAuto();
    // Окно могло подъехать к концу — достраиваем вперёд фоном.
    unawaited(_maybeExtendWindow());
  }
}
