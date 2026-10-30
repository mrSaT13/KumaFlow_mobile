// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// Part of the PlayerProvider library: extension calls notifyListeners()
// on its own instance — same library, no behavior change.
part of '../player_provider.dart';

/// Радио: старт/стоп станции, bridge в очередь, тексты песен.
extension PlayerRadio on PlayerProvider {
  Future<void> playRadioStation(RadioStation station, {bool queueBridge = true}) async {
    if (_isPlayingRadio && _currentRadioStation?.id == station.id) {
      await togglePlayPause();
      return;
    }

    _isLoading = true;
    notifyListeners();

    // Preserve existing queue for bridge (не теряем очередь при старте радио)
    final preservedQueue = List<Song>.from(_queue);
    final preservedIndex = _currentIndex;

    try {
      _currentSong = null;
      // Bridge: не очищаем очередь — оставляем для AutoDJ/догна
      if (preservedQueue.isEmpty) {
        _queue = [];
        _currentIndex = -1;
      } else {
        _queue = preservedQueue;
        _currentIndex = -1; // overlay: radio играет, но queue сохранён
      }
      _isPlayingRadio = true;
      _isRenderingRemotely = false; // radio always plays locally
      _currentRadioStation = station;
      // Шапка очереди: радио — это контекст (десктоп показывает станцию).
      _currentQueueName = 'Радио · ${station.name}';
      _currentQueueHint = null;
      _position = Duration.zero;
      _duration = Duration.zero;

      try {
        await _audioPlayer.setUrl(station.streamUrl);
      } catch (e) {
        if (!_hasPlayedOnce) {
          debugPrint(
            'First radio playback failed (Android 16 Media3 issue), retrying: $e',
          );
          await Future.delayed(const Duration(milliseconds: 100));
          await _audioPlayer.setUrl(station.streamUrl);
          _hasPlayedOnce = true;
        } else {
          rethrow;
        }
      }

      await _audioPlayer.setVolume(_volume);

      await _ensureAudioFocus();
      await _audioPlayer.play();

      _updateSystemServicesForRadio(station);

      // ── Radio → Recommendation bridge: подмешиваем 5 треков по жанру станции ──
      if (queueBridge && _recommendationService != null) {
        // Не блокируем UI — генерируем в microtask
        Future.microtask(() async {
          try {
            // Было: срез 80к кэша. Стало: свежий пул из БД.
            List<Song> pool = [];
            if (_libraryProvider != null) {
              pool = await _libraryProvider!.getPoolForMix(limit: 700);
            }
            if (pool.isEmpty) return;
            // Если очередь уже есть — не дублируем bridge
            if (_queue.length >= 3) return;
            final bridge = _recommendationService!.getRadioBridgeQueue(pool, station, limit: 8);
            if (bridge.isEmpty) return;
            // Фильтруем уже в очереди
            final existingIds = _queue.map((s) => s.id).toSet();
            final toAdd = bridge.where((s) => !existingIds.contains(s.id)).take(5).toList();
            if (toAdd.isEmpty) return;
            _queue.addAll(toAdd);
            // Не уведомляем лишний раз, но обновляем персист через debounce.
            _saveQueueState();
            notifyListeners();
            debugPrint('[Player] Radio bridge queued ${toAdd.length} tracks for "${station.name}"');
          } catch (e) {
            debugPrint('[Player] Radio bridge error: $e');
          }
        });
      }
    } catch (e) {
      debugPrint('Error playing radio station: $e');
      _isPlaying = false;
      _isPlayingRadio = false;
      _currentRadioStation = null;
      _currentQueueName = null;
      _currentQueueHint = null;
      // Восстанавливаем очередь при ошибке радио
      _queue = preservedQueue;
      _currentIndex = preservedIndex;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Совместимость: старый вызов без bridge
  Future<void> playRadioStationWithBridge(RadioStation station) => playRadioStation(station, queueBridge: true);

  void stopRadio() {
    if (_isPlayingRadio) {
      _audioPlayer.stop();
      _isPlayingRadio = false;
      _currentRadioStation = null;
      _currentQueueName = null;
      _currentQueueHint = null;
      _isPlaying = false;
      // Clear lyrics when stopping radio
      _lyricsService.stopSync();
      _lyricsService.loadLyrics(null);
      notifyListeners();
    }
  }

  /// Load and sync lyrics for the given song
  Future<void> _loadAndSyncLyrics(Song song) async {
    try {
      // Stop any previous sync
      _lyricsService.stopSync();

      // Fetch lyrics from Subsonic API — с таймаутом: без него переключение
      // трека ждало сеть десятки секунд (вклад в ANR).
      final lyricsResponse = await _subsonicService
          .getLyricsBySongId(song.id)
          .timeout(const Duration(seconds: 5), onTimeout: () => null);

      if (lyricsResponse != null) {
        // Extract lyrics content from response
        // Subsonic returns lyrics in various formats
        String? lyricsContent;

        if (lyricsResponse.containsKey('lyrics')) {
          // Standard Subsonic format
          lyricsContent = lyricsResponse['lyrics'] as String?;
        } else if (lyricsResponse.containsKey('structuredLyrics')) {
          // Jellyfin format - convert to LRC
          final structured =
              lyricsResponse['structuredLyrics'] as List<dynamic>?;
          if (structured != null && structured.isNotEmpty) {
            lyricsContent = _convertStructuredToLrc(structured);
          }
        }

        if (lyricsContent != null && lyricsContent.isNotEmpty) {
          // Load lyrics into the service
          await _lyricsService.loadLyrics(lyricsContent);

          // Start syncing with position stream
          _lyricsService.startSync(_audioPlayer.positionStream);

          debugPrint('[Lyrics] Loaded and started sync for "${song.title}"');
        } else {
          // No lyrics available - clear any existing
          await _lyricsService.loadLyrics(null);
          debugPrint('[Lyrics] No lyrics available for "${song.title}"');
        }
      } else {
        // No lyrics available - clear any existing
        await _lyricsService.loadLyrics(null);
        debugPrint('[Lyrics] No lyrics available for "${song.title}"');
      }
    } catch (e) {
      debugPrint('[Lyrics] Failed to load lyrics for "${song.title}": $e');
      // Don't block playback if lyrics fail
      await _lyricsService.loadLyrics(null);
    }
  }

  /// Convert Jellyfin structured lyrics to LRC format
  String _convertStructuredToLrc(List<dynamic> structured) {
    final buffer = StringBuffer();
    for (final line in structured) {
      if (line is Map<String, dynamic>) {
        final text = line['text'] as String? ?? '';
        final startTicks = line['startTicks'] as int? ?? 0;
        final startMs = startTicks ~/ 10000; // Convert to milliseconds
        final minutes = startMs ~/ 60000;
        final seconds = (startMs % 60000) ~/ 1000;
        final centiseconds = (startMs % 1000) ~/ 10;
        buffer.writeln(
            '[$minutes:${seconds.toString().padLeft(2, '0')}.${centiseconds.toString().padLeft(2, '0')}]$text');
      }
    }
    return buffer.toString();
  }

  void _updateSystemServicesForRadio(RadioStation station) {
    _windowsService.updatePlaybackState(
      song: null,
      isPlaying: true,
      position: Duration.zero,
      duration: Duration.zero,
      artworkUrl: null,
    );

    _androidSystemService.updatePlaybackState(
      songId: station.id,
      title: station.name,
      artist: 'Internet Radio',
      album: station.homePageUrl ?? '',
      artworkUrl: null,
      duration: Duration.zero,
      position: Duration.zero,
      isPlaying: true,
    );
  }
}
