import '../../models/ml/ml_types.dart';

class BehaviorTracker {
  final List<PlayEvent> _events = [];
  static const int maxEvents = 2000;
  final Map<String, String> _trackGenres = {};

  void logEvent(PlayEvent event) {
    _events.add(event);
    if (_events.length > maxEvents) {
      _events.removeAt(0);
    }
  }

  /// Remember the genre associated with a track so [getTopGenres] can report
  /// real genres rather than fall back to time-of-day context.
  void noteGenre(String trackId, String? genre) {
    if (trackId.isEmpty) return;
    if (genre == null || genre.isEmpty) {
      _trackGenres.remove(trackId);
      return;
    }
    _trackGenres[trackId] = genre;
  }

  void logPlay(String trackId, {String sessionId = '', String? genre}) {
    if (genre != null) _trackGenres[trackId] = genre;
    logEvent(PlayEvent(
      trackId: trackId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      action: 'play',
      sessionId: sessionId,
      timeContext: _getTimeContext(),
      dayOfWeek: DateTime.now().weekday,
    ));
  }

  void logSkip(String trackId, int position, {String sessionId = ''}) {
    final action = position < 30 ? 'skip_early' : 'skip_late';
    logEvent(PlayEvent(
      trackId: trackId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      action: action,
      position: position,
      sessionId: sessionId,
      timeContext: _getTimeContext(),
      dayOfWeek: DateTime.now().weekday,
    ));
  }

  void logComplete(String trackId, {String sessionId = '', String? genre}) {
    if (genre != null) _trackGenres[trackId] = genre;
    logEvent(PlayEvent(
      trackId: trackId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      action: 'complete',
      sessionId: sessionId,
      timeContext: _getTimeContext(),
      dayOfWeek: DateTime.now().weekday,
    ));
  }

  void logLike(String trackId, {String sessionId = '', String? genre}) {
    if (genre != null) _trackGenres[trackId] = genre;
    logEvent(PlayEvent(
      trackId: trackId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      action: 'like',
      sessionId: sessionId,
      timeContext: _getTimeContext(),
      dayOfWeek: DateTime.now().weekday,
    ));
  }

  void logDislike(String trackId, {String sessionId = '', String? genre}) {
    if (genre != null) _trackGenres[trackId] = genre;
    logEvent(PlayEvent(
      trackId: trackId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      action: 'dislike',
      sessionId: sessionId,
      timeContext: _getTimeContext(),
      dayOfWeek: DateTime.now().weekday,
    ));
  }

  void logReplay(String trackId, {String sessionId = '', String? genre}) {
    if (genre != null) _trackGenres[trackId] = genre;
    logEvent(PlayEvent(
      trackId: trackId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      action: 'replay',
      sessionId: sessionId,
      timeContext: _getTimeContext(),
      dayOfWeek: DateTime.now().weekday,
    ));
  }

  /// User seeked significantly backwards — re-listening, strong interest.
  void logSeekBack(String trackId, int position, {String sessionId = '', String? genre}) {
    if (genre != null) _trackGenres[trackId] = genre;
    logEvent(PlayEvent(
      trackId: trackId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      action: 'seek_back',
      position: position,
      sessionId: sessionId,
      timeContext: _getTimeContext(),
      dayOfWeek: DateTime.now().weekday,
    ));
  }

  /// Track was left behind at 5–80% without an explicit skip
  /// (direct song pick, queue jump). Soft negative signal.
  void logAbandon(String trackId, int position, {String sessionId = '', String? genre}) {
    if (genre != null) _trackGenres[trackId] = genre;
    logEvent(PlayEvent(
      trackId: trackId,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      action: 'abandon',
      position: position,
      sessionId: sessionId,
      timeContext: _getTimeContext(),
      dayOfWeek: DateTime.now().weekday,
    ));
  }

  Map<String, dynamic> getRecentFeedback({int limit = 20}) {
    final recent = _events.reversed.take(limit).toList();
    final skippedArtistIds = <String>{};
    final skippedGenres = <String>{};
    final lovedArtistIds = <String>{};
    final lovedGenres = <String>{};
    final skippedTrackIds = <String>{};
    final abandonedTrackIds = <String>{};

    for (final event in recent) {
      if (event.action == 'skip_early' || event.action == 'skip_late') {
        skippedTrackIds.add(event.trackId);
      }
      if (event.action == 'abandon') {
        abandonedTrackIds.add(event.trackId);
      }
      if (event.action == 'like' ||
          event.action == 'complete' ||
          event.action == 'replay' ||
          event.action == 'seek_back') {
        lovedArtistIds.add(event.trackId);
      }
    }

    return {
      'skippedArtistIds': skippedArtistIds,
      'skippedGenres': skippedGenres,
      'lovedArtistIds': lovedArtistIds,
      'lovedGenres': lovedGenres,
      'skippedTrackIds': skippedTrackIds,
      'abandonedTrackIds': abandonedTrackIds,
    };
  }

  List<String> getTopGenres({int limit = 10}) {
    final genreCounts = <String, int>{};
    for (final event in _events) {
      if (event.action != 'play' && event.action != 'complete' &&
          event.action != 'like' && event.action != 'replay' &&
          event.action != 'seek_back') {
        continue;
      }
      final genre = _trackGenres[event.trackId]?.toLowerCase();
      if (genre == null || genre.isEmpty) continue;
      genreCounts[genre] = (genreCounts[genre] ?? 0) + 1;
    }
    final sorted = genreCounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(limit).map((e) => e.key).toList();
  }

  List<PlayEvent> getRecentEvents({int limit = 20}) {
    return _events.reversed.take(limit).toList();
  }

  void cleanup({int maxAgeDays = 30}) {
    final cutoff = DateTime.now().subtract(Duration(days: maxAgeDays)).millisecondsSinceEpoch;
    _events.removeWhere((e) => e.timestamp < cutoff);
  }

  String _getTimeContext() {
    final hour = DateTime.now().hour;
    if (hour >= 6 && hour < 12) return 'morning';
    if (hour >= 12 && hour < 17) return 'day';
    if (hour >= 17 && hour < 22) return 'evening';
    return 'night';
  }

  List<PlayEvent> get events => List.unmodifiable(_events);
}
