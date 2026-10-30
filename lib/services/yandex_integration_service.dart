import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import 'yandex_music_service.dart';
import 'subsonic_service.dart';

/// Service for integrating Yandex Music playlists with local Subsonic server.
///
/// Fetches playlists from Yandex Music API, searches for matching tracks
/// on the local Subsonic server, and creates local playlists.
class YandexIntegrationService {
  final YandexMusicService _yandexService;
  final SubsonicService _subsonicService;

  static const String _kCacheKey = 'yandex_playlists_cache';
  static const String _kLastSyncKey = 'yandex_playlists_last_sync';

  List<YandexPlaylistResult> _cachedPlaylists = [];
  bool _isLoading = false;
  String? _lastError;

  YandexIntegrationService({
    required YandexMusicService yandexService,
    required SubsonicService subsonicService,
  })  : _yandexService = yandexService,
        _subsonicService = subsonicService;

  bool get isLoading => _isLoading;
  String? get lastError => _lastError;
  List<YandexPlaylistResult> get playlists => _cachedPlaylists;

  // ──────────────────────────────────────────────────────────────────────────
  // Playlists
  // ──────────────────────────────────────────────────────────────────────────

  /// Fetch user playlists from Yandex Music.
  Future<List<YandexPlaylistResult>> fetchPlaylists() async {
    if (!_yandexService.hasToken) {
      _lastError = 'No Yandex Music token';
      return [];
    }

    _isLoading = true;
    _lastError = null;

    try {
      _cachedPlaylists = await _yandexService.getUserPlaylists();
      _isLoading = false;
      return _cachedPlaylists;
    } catch (e) {
      _lastError = e.toString();
      _isLoading = false;
      return [];
    }
  }

  /// Get tracks from a Yandex Music playlist and search for them on Subsonic.
  Future<List<Song>> getPlaylistTracks({
    required String playlistUid,
    required String playlistKind,
    int limit = 100,
  }) async {
    _isLoading = true;
    _lastError = null;

    try {
      // Get tracks from Yandex Music
      final yandexTracks = await _yandexService.getPlaylistTracks(
        playlistUid: playlistUid,
        playlistKind: playlistKind,
      );

      if (yandexTracks.isEmpty) {
        _isLoading = false;
        return [];
      }

      // Search for each track on Subsonic server — дедуп по id через Set
      final matchedSongs = <Song>[];
      final seenIds = <String>{};
      for (final track in yandexTracks.take(limit)) {
        try {
          // Try multiple search strategies
          List<Song> candidates = [];

          // Strategy 1: Search by title + artist
          var result = await _subsonicService.search(
            '${track.title} ${track.artistName ?? ''}',
            songCount: 5,
          );
          candidates.addAll(result.songs);

          // Strategy 2: Search by title only (if no results)
          if (candidates.isEmpty && track.title.isNotEmpty) {
            result = await _subsonicService.search(
              track.title,
              songCount: 5,
            );
            candidates.addAll(result.songs);
          }

          // Strategy 3: Search by artist name only (as fallback)
          if (candidates.isEmpty && track.artistName != null && track.artistName!.isNotEmpty) {
            result = await _subsonicService.search(
              track.artistName!,
              songCount: 10,
            );
            // Filter by title similarity
            candidates.addAll(result.songs.where((s) =>
                s.title.toLowerCase().contains(track.title.toLowerCase()) ||
                track.title.toLowerCase().contains(s.title.toLowerCase())));
          }

          if (candidates.isNotEmpty) {
            // Find best match by title similarity
            final bestMatch = _findBestMatch(track, candidates);
            if (bestMatch != null && seenIds.add(bestMatch.id)) {
              matchedSongs.add(bestMatch);
            }
          }
        } catch (e) {
          debugPrint('[YandexIntegration] Search error for ${track.title}: $e');
        }
      }

      _isLoading = false;
      return matchedSongs;
    } catch (e) {
      _lastError = e.toString();
      _isLoading = false;
      return [];
    }
  }

  /// Get "Моя волна" (My Wave) from Yandex Music and match with local library.
  /// Итоговый дедуп по id на случай дублей в самом плейлисте Яндекса.
  Future<List<Song>> getMyWaveTracks({int limit = 50}) async {
    if (!_yandexService.hasToken) return [];

    _isLoading = true;
    _lastError = null;

    try {
      final wavePlaylist = await _yandexService.getMyWavePlaylist();
      if (wavePlaylist == null) {
        _isLoading = false;
        return [];
      }

      final tracks = await getPlaylistTracks(
        playlistUid: wavePlaylist.uid,
        playlistKind: wavePlaylist.kind,
        limit: limit,
      );

      // Финальный дедуп (на случай если getPlaylistTracks вернул дубли)
      final deduped = <Song>[];
      final seen = <String>{};
      for (final s in tracks) {
        if (seen.add(s.id)) deduped.add(s);
      }

      _isLoading = false;
      return deduped;
    } catch (e) {
      _lastError = e.toString();
      _isLoading = false;
      return [];
    }
  }

  /// Get radio tracks by artist from Yandex Music and match with local library.
  Future<List<Song>> getRadioByArtist({
    required String artistId,
    required String artistName,
    int limit = 30,
  }) async {
    if (!_yandexService.hasToken) return [];

    _isLoading = true;
    _lastError = null;

    try {
      final radioTracks = await _yandexService.getRadioByArtist(
        artistId: artistId,
        count: limit,
      );

      if (radioTracks.isEmpty) {
        _isLoading = false;
        return [];
      }

      // Search for each track on Subsonic server — дедуп по id
      final matchedSongs = <Song>[];
      final seenIds = <String>{};
      for (final track in radioTracks) {
        try {
          final result = await _subsonicService.search(
            '${track.title} ${track.artistName ?? artistName}',
            songCount: 5,
          );

          if (result.songs.isNotEmpty) {
            final bestMatch = _findBestMatch(track, result.songs);
            if (bestMatch != null && seenIds.add(bestMatch.id)) {
              matchedSongs.add(bestMatch);
            }
          }
        } catch (e) {
          debugPrint('[YandexIntegration] Search error for ${track.title}: $e');
        }
      }

      _isLoading = false;
      return matchedSongs;
    } catch (e) {
      _lastError = e.toString();
      _isLoading = false;
      return [];
    }
  }

  /// Create a local playlist from Yandex Music playlist tracks.
  Future<bool> createLocalPlaylist({
    required String name,
    required List<Song> songs,
  }) async {
    try {
      // Create playlist on Subsonic server
      await _subsonicService.createPlaylist(
        name: name,
        songIds: songs.map((s) => s.id).toList(),
      );

      return true;
    } catch (e) {
      debugPrint('[YandexIntegration] Create playlist error: $e');
      return false;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Helpers
  // ──────────────────────────────────────────────────────────────────────────

  /// Find the best matching song from search results.
  Song? _findBestMatch(YandexTrackResult yandexTrack, List<Song> candidates) {
    if (candidates.isEmpty) return null;

    final yandexTitle = yandexTrack.title.toLowerCase().trim();
    final yandexArtist = (yandexTrack.artistName ?? '').toLowerCase().trim();

    Song? bestMatch;
    double bestScore = 0;

    for (final candidate in candidates) {
      double score = 0;
      final candidateTitle = candidate.title.toLowerCase().trim();
      final candidateArtist = (candidate.artist ?? '').toLowerCase().trim();

      // Title similarity (exact match or contains)
      if (candidateTitle == yandexTitle) {
        score += 0.6;
      } else if (candidateTitle.contains(yandexTitle) || yandexTitle.contains(candidateTitle)) {
        score += 0.4;
      } else {
        // Check for partial word match
        final yandexWords = yandexTitle.split(' ');
        final candidateWords = candidateTitle.split(' ');
        final commonWords = yandexWords.where((w) => candidateWords.any((cw) => cw.contains(w) || w.contains(cw))).length;
        if (commonWords > 0) {
          score += 0.2 * (commonWords / yandexWords.length);
        }
      }

      // Artist similarity
      if (yandexArtist.isNotEmpty && candidateArtist.isNotEmpty) {
        if (candidateArtist == yandexArtist) {
          score += 0.3;
        } else if (candidateArtist.contains(yandexArtist) || yandexArtist.contains(candidateArtist)) {
          score += 0.2;
        } else {
          // Check for partial artist name match
          final artistWords = yandexArtist.split(' ');
          final candidateArtistWords = candidateArtist.split(' ');
          final commonArtistWords = artistWords.where((w) => candidateArtistWords.any((cw) => cw.contains(w) || w.contains(cw))).length;
          if (commonArtistWords > 0) {
            score += 0.1 * (commonArtistWords / artistWords.length);
          }
        }
      }

      // Duration similarity (if available)
      if (yandexTrack.durationMs != null && candidate.duration != null) {
        final yandexDuration = yandexTrack.durationMs! ~/ 1000;
        final candidateDuration = candidate.duration!;
        final durationDiff = (yandexDuration - candidateDuration).abs();
        if (durationDiff < 5) {
          score += 0.1;
        } else if (durationDiff < 15) {
          score += 0.05;
        }
      }

      if (score > bestScore) {
        bestScore = score;
        bestMatch = candidate;
      }
    }

    // Lower threshold to be more permissive - return best match if any reasonable match exists
    return bestScore >= 0.2 ? bestMatch : null;
  }
}
