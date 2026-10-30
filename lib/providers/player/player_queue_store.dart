// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// Part of the PlayerProvider library: extension calls notifyListeners()
// on its own instance — same library, no behavior change.
part of '../player_provider.dart';

/// Персист очереди: debounce-save, immediate-save, restore, clear.
extension PlayerQueueStore on PlayerProvider {
  void _saveQueueState() {
    // Cold-start: reduce SharedPreferences fsync spam (was every 300ms → fsync flood causing 32-64ms blocks)
    _persistDebounceTimer?.cancel();
    final delay = _queue.length > 1000
        ? const Duration(milliseconds: 5000)
        : _queue.length > 500
            ? const Duration(milliseconds: 3000)
            : const Duration(milliseconds: 2000);
    _persistDebounceTimer = Timer(delay, () async {
      await _saveQueueStateImmediate();
    });
  }

  Future<void> _saveQueueStateImmediate() async {
    try {
      // П5: очередь как song_id + position, без jsonEncode(full Song).
      // Дубль библиотеки в queue.song_data ронял диск/RAM и давал рассинхрон starred/playCount.
      final ids = _queue.map((s) => s.id).toList();
      try {
        await _db.saveQueueIds(
          ids,
          _currentIndex,
          _currentSong?.id ?? '',
          _position.inMilliseconds,
        );
      } catch (_) {
        // Fallback на старый путь для старых БД.
        final queueData = _queue.map((s) => s.toJson()).toList();
        await _db.saveQueue(
          queueData,
          _currentIndex,
          _currentSong?.id ?? '',
          _position.inMilliseconds,
        );
      }
      debugPrint(
          'Queue state saved (ids): index $_currentIndex, position $_position, n=${ids.length}');
    } catch (e) {
      debugPrint('Error saving queue state: $e');
    }
  }

  Future<void> _restoreQueueState() async {
    try {
      // П5: сначала пробуем id-путь (song_id → hydrate из songs).
      try {
        final idData = await _db.loadQueueIds();
        if (idData != null) {
          final ids = (idData['ids'] as List).cast<String>();
          if (ids.isNotEmpty) {
            final hydrated = await _db.resolveQueueSongs(ids, light: false);
            if (hydrated.isNotEmpty) {
              final savedIndex = idData['index'] as int? ?? 0;
              final savedSongId = idData['songId'] as String? ?? '';
              final savedPositionMs = idData['position'] as int? ?? 0;
              var targetIndex = savedIndex.clamp(0, hydrated.length - 1);
              if (savedSongId.isNotEmpty) {
                final idIndex = hydrated.indexWhere((s) => s.id == savedSongId);
                if (idIndex != -1) targetIndex = idIndex;
              }
              // Локальные без файла отсеиваем как раньше, но без existsSync-шторма на 80к:
              // очередь короткая, тут можно на месте.
              final restoredSongs = hydrated.where((s) {
                if (s.isLocal && s.path != null) {
                  try {
                    return File(s.path!).existsSync();
                  } catch (_) {
                    return false;
                  }
                }
                return true;
              }).toList();
              if (restoredSongs.isNotEmpty) {
                targetIndex = targetIndex.clamp(0, restoredSongs.length - 1);
                _queue = restoredSongs;
                _currentIndex = targetIndex;
                _currentSong = restoredSongs[targetIndex];
                _position = Duration(milliseconds: savedPositionMs);
                final d = restoredSongs[targetIndex].duration;
                if (d != null && d > 0) _duration = Duration(seconds: d);
                notifyListeners();
                debugPrint('Restored queue by ids: ${restoredSongs.length} songs');
                return;
              }
            }
          }
        }
      } catch (_) {}
      final data = await _db.loadQueue();
      if (data == null) return;

      final songsList = data['songs'] as List<dynamic>;
      if (songsList.isEmpty) return;

      final allSongs = songsList.length > 500
          ? await compute(_deserializeQueueIsolate, songsList)
          : songsList.map((j) => Song.fromJson(j as Map<String, dynamic>)).toList();
      // existsSync по сотням файлов — стат-шторм на главном потоке
      // (видели 60%+ kernel в ANR). Большие очереди фильтруем в изоляте,
      // туда-сюда едет только JSON.
      List<Song> restoredSongs;
      if (allSongs.length > 200) {
        final filteredJson = await compute(
          _filterLocalSongsIsolate,
          allSongs.map((s) => s.toJson()).toList(),
        );
        restoredSongs =
            filteredJson.map((j) => Song.fromJson(j)).toList();
      } else {
        restoredSongs = allSongs.where((s) {
          if (s.isLocal && s.path != null) {
            try {
              return File(s.path!).existsSync();
            } catch (_) {
              return false;
            }
          }
          return true;
        }).toList();
      }

      if (restoredSongs.isEmpty) return;

      final savedIndex = data['index'] as int? ?? 0;
      final savedSongId = data['songId'] as String? ?? '';
      final savedPositionMs = data['position'] as int? ?? 0;

      var targetIndex = savedIndex.clamp(0, restoredSongs.length - 1);
      if (savedSongId.isNotEmpty) {
        final idIndex = restoredSongs.indexWhere((s) => s.id == savedSongId);
        if (idIndex != -1) targetIndex = idIndex;
      }

      _queue = restoredSongs;
      _currentIndex = targetIndex;
      _currentSong = restoredSongs[targetIndex];
      _position = Duration(milliseconds: savedPositionMs);
      final songDurationSecs = restoredSongs[targetIndex].duration;
      if (songDurationSecs != null && songDurationSecs > 0) {
        _duration = Duration(seconds: songDurationSecs);
      }
      notifyListeners();
      debugPrint(
          'Restored persistent queue: ${restoredSongs.length} songs, index $targetIndex, position $_position');
    } catch (e) {
      debugPrint('Error restoring queue state: $e');
    }
  }

  void _clearPersistedQueue() {
    _persistDebounceTimer?.cancel();
    _db.clearQueue().catchError((e) {
      debugPrint('Error clearing persisted queue: $e');
    });
  }
}
