// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
// Part of the PlayerProvider library: extension calls notifyListeners()
// on its own instance — same library, no behavior change.
part of '../player_provider.dart';

/// Audiobookshelf: контекст книги, главы, sync прогресса.
extension PlayerAudiobookshelf on PlayerProvider {
  void setAbsBookContext({required String itemId, required List<Map<String, dynamic>> chapters, required double totalDuration}) {
    _absBookId = itemId;
    _absChaptersRaw = chapters;
    try {
      _absChaptersTyped = chapters.map((e) => BookChapter.fromJson(e)).toList();
    } catch (_) {
      _absChaptersTyped = [];
    }
    _absTotalDuration = totalDuration;
    _absLastSyncAbsTime = 0;
    _absUnsyncedMs = 0;
    _absPlayingSinceMs = DateTime.now().millisecondsSinceEpoch;
  }

  void clearAbsBookContext() {
    _absSyncTimer?.cancel();
    _absBookId = null;
    _absChaptersRaw = [];
    _absChaptersTyped = [];
    _absTotalDuration = 0;
  }

  void _startAbsSyncTimer() {
    _absSyncTimer?.cancel();
    // Immediate sync
    _syncAbsProgress();
    // Dynamic interval: не будим CPU каждую секунду (было 1с, стало 5с)
    _absSyncTimer = Timer.periodic(const Duration(seconds: 5), (t) async {
      if (!_isPlaying || _absBookId == null) return;
      final absTime = _getCurrentAbsTime();
      final nearStart = absTime < 90;
      final nearEnd = (_absTotalDuration - absTime) < 90;
      final intervalMs = (nearStart || nearEnd) ? 5000 : 15000;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _absLastSyncAbsTime * 1000 < intervalMs) return;
      await _syncAbsProgress();
    });
  }

  void _stopAbsSyncTimer({bool flush = true}) {
    _absSyncTimer?.cancel();
    if (flush) _flushAbsSync(force: true);
  }

  double _getCurrentAbsTime() {
    double pos = _position.inSeconds.toDouble();
    if (_absChaptersTyped.isNotEmpty) {
      final idx = _currentIndex >= 0 && _currentIndex < _absChaptersTyped.length ? _currentIndex : 0;
      final chapStart = _absChaptersTyped[idx].start;
      return chapStart + pos;
    } else if (_absChaptersRaw.isNotEmpty) {
      final idx = _currentIndex >= 0 && _currentIndex < _absChaptersRaw.length ? _currentIndex : 0;
      final chapStart = (_absChaptersRaw[idx]['start'] as num?)?.toDouble() ?? 0;
      return chapStart + pos;
    }
    return pos;
  }

  Future<void> _syncAbsProgress() async {
    if (_absBookId == null || _absTotalDuration <= 0) return;
    if (_absIsSyncing) { _absSyncPending = true; return; }
    _absIsSyncing = true;
    try {
      final absTime = _getCurrentAbsTime();
      final now = DateTime.now().millisecondsSinceEpoch;
      // accumulate timeListened
      if (_absPlayingSinceMs != null && _isPlaying) {
        _absUnsyncedMs += now - _absPlayingSinceMs!;
      }
      _absPlayingSinceMs = _isPlaying ? now : null;
      final timeListened = (_absUnsyncedMs / 1000).clamp(0, 60).toDouble();
      if (absTime <= 0) { _absIsSyncing = false; return; }
      final svc = AudiobookshelfService();
      await svc.syncProgress(_absBookId!, absTime, _absTotalDuration, timeListened: timeListened > 0 ? timeListened : 15);
      _absLastSyncAbsTime = (now ~/ 1000).toDouble();
      _absUnsyncedMs = 0;
      // Notify listeners so detail screen live progress updates without re-fetch
      notifyListeners();
    } catch (_) {} finally {
      _absIsSyncing = false;
      if (_absSyncPending) { _absSyncPending = false; _syncAbsProgress(); }
    }
  }

  Future<void> _flushAbsSync({bool force = false}) async {
    if (_absBookId == null) return;
    await _syncAbsProgress();
  }

  // Expose for UI: total book progress
  double get absBookProgress {
    if (_absTotalDuration <= 0) return 0;
    final t = _getCurrentAbsTime();
    return (t / _absTotalDuration).clamp(0, 1);
  }
  double get absCurrentTime => _getCurrentAbsTime();
  double get absTotalDuration => _absTotalDuration;
  String? get absBookId => _absBookId;
}
