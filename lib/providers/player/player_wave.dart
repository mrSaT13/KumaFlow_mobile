// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// Part of the PlayerProvider library: extension calls notifyListeners()
// on its own instance — same library, no behavior change.
part of '../player_provider.dart';

/// Волна и оценки: генерация плейлистов, лайки/дизлайки, баны, звёзды.
extension PlayerWave on PlayerProvider {
  Future<List<Song>> generateMyWavePlaylist({int limit = 50}) async {
    final likedSongIds = _mlStore.profile.likedSongs;
    final ratings = _mlStore.ratings;

    final playlist = await _mlWaveService.generateMyWavePlaylist(
      likedSongIds: likedSongIds,
      ratings: ratings,
      limit: limit,
    );

    return playlist.songs.cast<Song>().toList();
  }

  /// Generate a "Song Alchemy" playlist with custom vibe parameters
  Future<List<Song>> generateSongAlchemy({
    required double energy,
    required double danceability,
    required double valence,
    required double acousticness,
    int limit = 50,
  }) async {
    final playlist = await _mlWaveService.generateSongAlchemy(
      energy: energy,
      danceability: danceability,
      valence: valence,
      acousticness: acousticness,
      limit: limit,
    );

    return playlist.songs.cast<Song>().toList();
  }

  /// Get similar tracks for the current song using vibe analysis
  Future<List<Song>> getSimilarTracks({int limit = 20}) async {
    if (_currentSong == null) return [];
    return await _mlWaveService.getSimilarTracks(_currentSong!, limit);
  }

  /// Get explainable AI recommendations for the current song
  List<String> getCurrentSongExplanations() {
    if (_currentSong == null) return [];

    final explanations = _explainableAI.explainRecommendation(
      track: _currentSong,
      profile: _mlStore.profile,
      ratings: _mlStore.ratings,
    );

    return explanations.map((e) => e.text).toList();
  }

  Future<void> toggleFavorite() async {
    if (_currentSong == null) return;

    final isStarred = _currentSong!.starred == true;

    final newSong = _currentSong!.copyWith(starred: !isStarred);
    _currentSong = newSong;
    _audioHandler.setCurrentSongStarred(!isStarred);
    // Track in ML service
    _mlService.rateSong(newSong.id, !isStarred, song: newSong);
    _brainRate(newSong.id, !isStarred);

    // Track in advanced ML engine
    _behaviorTracker.logLike(newSong.id, genre: newSong.genre);
    _mlStore.rateSong(newSong.id, !isStarred, {
      'title': newSong.title,
      'artist': newSong.artist ?? '',
    });

    // Record MAB reward for favorite action
    final mabContext = _multiArmedBandit.getCurrentContext();
    if (newSong.artistId != null) {
      _multiArmedBandit.recordReward(
        newSong.artistId!,
        _multiArmedBandit.calculateReward(!isStarred ? 'like' : 'dislike'),
        mabContext,
        'artist',
        newSong.artist,
      );
    }
    if (newSong.genre != null) {
      _multiArmedBandit.recordReward(
        newSong.genre!,
        _multiArmedBandit.calculateReward(!isStarred ? 'like' : 'dislike'),
        mabContext,
        'genre',
        newSong.genre,
      );
    }

    notifyListeners();

    try {
      if (isStarred) {
        await _subsonicService.unstar(id: newSong.id);
      } else {
        await _subsonicService.star(id: newSong.id);
      }
      _libraryProvider?.loadStarred();
    } catch (e) {
      debugPrint('Error toggling favorite: $e');
      _currentSong = _currentSong!.copyWith(starred: isStarred);
      _audioHandler.setCurrentSongStarred(isStarred);
      notifyListeners();
    }
  }

  Future<void> toggleFavoriteForSong(Song song) async {
    final isStarred = song.starred == true;
    try {
      if (isStarred) {
        await _subsonicService.unstar(id: song.id);
      } else {
        await _subsonicService.star(id: song.id);
      }
      _libraryProvider?.loadStarred();
      // Track in ML service
      _mlService.rateSong(song.id, !isStarred, song: song);
      _brainRate(song.id, !isStarred);

      // Track in advanced ML engine
      _behaviorTracker.logLike(song.id, genre: song.genre);
      _mlStore.rateSong(song.id, !isStarred, {
        'title': song.title,
        'artist': song.artist ?? '',
      });

      if (_currentSong?.queueKey == song.queueKey) {
        _currentSong = _currentSong!.copyWith(starred: !isStarred);
        notifyListeners();
        // Push the new like state to the home-screen widget.
        _updateAllServices();
      }
    } catch (e) {
      debugPrint('Error toggling favorite for song: $e');
    }
  }

  /// Record a user-initiated dislike (`false` rating). Updates the advanced
  /// ML engine (used by mixer / Smart Auto-DJ / My Wave) and the legacy
  /// `MLService` so both stores see the negative signal.
  ///
  /// Правило пользователя: 1 дизлайк = бан трека, 3 дизлайка треков одного
  /// артиста = бан артиста. Сам метод трек НЕ переключает — переключение
  /// делает [dislikeAndSkip] атомарно, чтобы UI (картинка/прогресс/очередь)
  /// не рассинхронизировался со звуком.
  /// Возвращает true если по итогам забанен артист.
  Future<bool> dislikeSong(Song song) async {
    // Advanced ML engine — primary source of truth for recommendations.
    _mlStore.rateSong(song.id, false, {
      'title': song.title,
      'artist': song.artist ?? '',
    });
    _behaviorTracker.logDislike(song.id, genre: song.genre);

    // Legacy ML service so the older `isDisliked` lookup path stays in sync.
    _mlService.rateSong(song.id, false, song: song);
    _brainRate(song.id, false);

    // Record MAB reward so disliked artists/genres get down-weighted.
    final mabContext = _multiArmedBandit.getCurrentContext();
    if (song.artistId != null) {
      _multiArmedBandit.recordReward(
        song.artistId!,
        _multiArmedBandit.calculateReward('dislike'),
        mabContext,
        'artist',
        song.artist,
      );
    }
    if (song.genre != null) {
      _multiArmedBandit.recordReward(
        song.genre!,
        _multiArmedBandit.calculateReward('dislike'),
        mabContext,
        'genre',
        song.genre,
      );
    }

    _moodDriftDetector.resetProfile();

    // 1 дизлайк = убираем ЭТОТ трек из очереди (все вхождения кроме текущего).
    final currentKey = _currentSong?.queueKey ?? _currentSong?.id;
    final dislikedId = song.id;
    final removedBefore = _countQueueMatchesBeforeCurrent(
      test: (s) => s.id == dislikedId,
    );
    _queue.removeWhere((s) {
      if ((s.queueKey ?? s.id) == currentKey && s.id == dislikedId) return false;
      return s.id == dislikedId;
    });
    if (removedBefore > 0) {
      _currentIndex = (_currentIndex - removedBefore).clamp(0, _queue.isEmpty ? 0 : _queue.length - 1);
    }
    if (_currentIndex >= _queue.length && _queue.isNotEmpty) {
      _currentIndex = _queue.length - 1;
    }

    // Счётчик дизлайков артиста: 3 дизлайка треков = бан артиста.
    bool artistBanned = false;
    final banId = song.artistId ?? song.artist ?? song.id;
    final banName = song.artist ?? 'Unknown';
    if (banName != 'Unknown' || song.artistId != null) {
      final count = _mlStore.registerArtistDislike(banId);
      if (count >= 3) {
        _mlStore.banArtist(banId, banName);
        _mlService.banArtist(banId, banName);
        artistBanned = true;
        // Удаляем все треки забаненного артиста (кроме текущего).
        final bannedLower = banName.toLowerCase();
        final removedBeforeArtist = _countQueueMatchesBeforeCurrent(
          test: (s) {
            if ((s.queueKey ?? s.id) == currentKey) return false;
            if (s.artistId != null && s.artistId == banId) return true;
            if (s.artist != null && s.artist!.toLowerCase() == bannedLower) return true;
            return false;
          },
        );
        _queue.removeWhere((s) {
          if ((s.queueKey ?? s.id) == currentKey) return false;
          if (s.artistId != null && s.artistId == banId) return true;
          if (s.artist != null && s.artist!.toLowerCase() == bannedLower) return true;
          return false;
        });
        if (removedBeforeArtist > 0) {
          _currentIndex = (_currentIndex - removedBeforeArtist).clamp(0, _queue.isEmpty ? 0 : _queue.length - 1);
        }
        if (_currentIndex >= _queue.length && _queue.isNotEmpty) {
          _currentIndex = _queue.length - 1;
        }
      }
    }

    _saveQueueState();
    notifyListeners();

    // Update the RecommendationService soft-affinity scores.
    _recommendationService?.trackDislike(song);
    return artistBanned;
  }

  int _countQueueMatchesBeforeCurrent({required bool Function(Song s) test}) {
    if (_currentIndex <= 0 || _queue.isEmpty) return 0;
    var n = 0;
    final end = _currentIndex.clamp(0, _queue.length);
    for (var i = 0; i < end; i++) {
      if (test(_queue[i])) n++;
    }
    return n;
  }

  /// Атомарный дизлайк+скип: сначала фиксируем ML/очередь, потом переключаем
  /// трек одним await-блоком. Повторные тапы пока идёт переключение игнорятся.
  /// Возвращает true если забанен артист (3+ дизлайка).
  Future<bool> dislikeAndSkip(Song song) async {
    if (_dislikeSkipBusy) return false;
    _dislikeSkipBusy = true;
    try {
      final artistBanned = await dislikeSong(song);
      // Оптимистичный UI: сразу показываем следующий трек, не ждём
      // resolve URL + setAudioSource (иначе очередь/картинка отстают).
      final nextIndex = _currentIndex + 1;
      final hasNext = nextIndex >= 0 && nextIndex < _queue.length;
      if (hasNext && !_shuffleEnabled && _concatenatingSource == null) {
        _currentIndex = nextIndex;
        _currentSong = _queue[_currentIndex];
      }
      // Сбрасываем позицию/артворк синхронно, чтобы прогресс-бар и картинка
      // не показывали старый трек пока грузится следующий.
      _position = Duration.zero;
      _resolvedArtworkUrl = null;
      notifyListeners();
      await skipNext();
      return artistBanned;
    } finally {
      _dislikeSkipBusy = false;
    }
  }

  /// Called when banned artists change externally (e.g. from artist screen).
  /// Cleans queue from newly banned artists.
  void cleanQueueFromBannedArtists(Set<String> bannedIds, Set<String> bannedNames) {
    final lowerNames = bannedNames.map((n) => n.toLowerCase()).toSet();
    final beforeLen = _queue.length;
    _queue.removeWhere((s) {
      if (s.id == _currentSong?.id) return false;
      if (s.artistId != null && bannedIds.contains(s.artistId)) return true;
      if (s.artist != null && lowerNames.contains(s.artist!.toLowerCase())) return true;
      return false;
    });
    if (_queue.length != beforeLen) {
      if (_currentIndex >= _queue.length) _currentIndex = (_queue.length - 1).clamp(0, _queue.length);
      _saveQueueState();
      notifyListeners();
    }
  }

  Future<void> setRating(String songId, int rating) async {
    if (_currentSong?.id != songId) return;

    final previousRating = _currentSong?.userRating;
    // Оптимистичный UI — звезды заполняются мгновенно, без ожидания сети (фикс лага 5 сек из логов)
    _currentSong = _currentSong?.copyWith(userRating: rating);
    notifyListeners();
    // Синхронизация с сервером в фоне, не блокируем UI
    unawaited(_subsonicService.setRating(songId, rating).catchError((e) {
      debugPrint('[Player] setRating bg error: $e');
      // Откат только если песня не сменилась
      if (_currentSong?.id == songId) {
        _currentSong = _currentSong?.copyWith(userRating: previousRating);
        notifyListeners();
      }
    }));
  }
}
