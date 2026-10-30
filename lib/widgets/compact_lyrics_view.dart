import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/lyrics.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/local_music_service.dart';
import '../services/subsonic_service.dart';
import '../services/offline_service.dart';
import '../services/lrclib_service.dart';
import 'synced_lyrics_view.dart'
    show AppleMusicLyricsController, AMLLLyricsWidget;
import '../l10n/app_localizations.dart';

class CompactLyricsView extends StatefulWidget {
  final Song song;
  final VoidCallback? onClose;

  const CompactLyricsView({super.key, required this.song, this.onClose});

  @override
  State<CompactLyricsView> createState() => _CompactLyricsViewState();
}

class _CompactLyricsViewState extends State<CompactLyricsView> {
  final AppleMusicLyricsController _lyricsController =
      AppleMusicLyricsController();
  StreamSubscription? _positionSubscription;

  bool _isLoading = true;
  String? _error;
  SyncedLyrics? _lyrics;
  bool _showReturnButton = false;

  Duration _lastUpdate = Duration.zero;
  late Song _song;

  // Кэш как в KumaFlow-desktop (src/service/lyrics.ts) и как в SyncedLyricsView
  static final Map<String, SyncedLyrics?> _memoryCache = {};
  static final Map<String, DateTime> _cacheTime = {};
  static const _cacheExpiry = Duration(hours: 24);
  static const _negativeCacheExpiry = Duration(minutes: 5);
  static final Map<String, Future<SyncedLyrics?>> _inFlight = {};
  static void clearCache() {
    _memoryCache.clear();
    _cacheTime.clear();
    _inFlight.clear();
  }

  static String _cacheKey(Song s) {
    final artist = (s.artist ?? '').toLowerCase().trim();
    final title = s.title.toLowerCase().trim();
    final dur = s.duration ?? 0;
    return 'lyrics:$artist::$title::$dur';
  }

  bool _isCacheValid(String k) {
    if (!_memoryCache.containsKey(k) || !_cacheTime.containsKey(k)) return false;
    final isNegative = _memoryCache[k] == null;
    final expiry = isNegative ? _negativeCacheExpiry : _cacheExpiry;
    return DateTime.now().difference(_cacheTime[k]!) < expiry;
  }

  @override
  void initState() {
    super.initState();
    _song = widget.song;
    _loadLyrics();
    _setupPositionListener();
    _lyricsController.addListener(_onControllerChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<PlayerProvider>(
        context,
        listen: false,
      ).addListener(_onPlayerStateChanged);
    });
  }

  @override
  void dispose() {
    try {
      Provider.of<PlayerProvider>(
        context,
        listen: false,
      ).removeListener(_onPlayerStateChanged);
    } catch (_) {}
    _positionSubscription?.cancel();
    _lyricsController.removeListener(_onControllerChanged);
    _lyricsController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final showReturn = _lyricsController.isUserScrolling;
    if (showReturn != _showReturnButton) {
      setState(() {
        _showReturnButton = showReturn;
      });
    }
  }

  void _onPlayerStateChanged() {
    if (!mounted) return;
    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
    final currentSong = playerProvider.currentSong;
    if (currentSong != null && currentSong.id != _song.id) {
      setState(() => _song = currentSong);
      _loadLyrics();
    }
  }

  @override
  void didUpdateWidget(CompactLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id && widget.song.id != _song.id) {
      setState(() => _song = widget.song);
      _loadLyrics();
    }
  }

  void _setupPositionListener() {
    _positionSubscription?.cancel();
    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
    _positionSubscription = playerProvider.positionStream.listen((position) {
      if (!mounted) return;
      final diff = (position - _lastUpdate).abs();
      final wentBackwards = position < _lastUpdate;
      if (diff.inMilliseconds >= 16 || wentBackwards) {
        _lastUpdate = position;
        _lyricsController.setPosition(position);
      }
    });
  }

  Future<void> _loadLyrics() async {
    final key = _cacheKey(_song);
    if (_isCacheValid(key)) {
      final cachedLyrics = _memoryCache[key];
      if (cachedLyrics != null && cachedLyrics.isNotEmpty) {
        _applyLyrics(cachedLyrics);
        return;
      }
      if (cachedLyrics == null) {
        // закэширован "нет текста"
        if (mounted) {
          setState(() {
            _error = AppLocalizations.of(context)!.noLyricsAvailable;
            _isLoading = false;
          });
        }
        return;
      }
    }
    if (_inFlight.containsKey(key)) {
      try {
        final deduped = await _inFlight[key]!;
        if (!mounted) return;
        if (deduped != null && deduped.isNotEmpty) {
          _applyLyrics(deduped);
        } else {
          setState(() {
            _error = AppLocalizations.of(context)!.noLyricsAvailable;
            _isLoading = false;
          });
        }
      } catch (_) {
        if (mounted) setState(() => _isLoading = false);
      }
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final fut = _fetchLyricsCompact(key);
    _inFlight[key] = fut;
    try {
      final result = await fut;
      if (!mounted) return;
      if (result != null && result.isNotEmpty) {
        _applyLyrics(result);
      } else {
        // кэшируем "не найдено" уже внутри _fetch
        setState(() {
          _error = AppLocalizations.of(context)!.noLyricsAvailable;
          _isLoading = false;
        });
      }
    } catch (e) {
      _inFlight.remove(key);
      if (mounted) {
        setState(() {
          _error = AppLocalizations.of(context)!.failedToLoadLyrics;
          _isLoading = false;
        });
      }
      return;
    } finally {
      _inFlight.remove(key);
    }
    return;
  }

  Future<SyncedLyrics?> _fetchLyricsCompact(String cacheKey) async {
    SyncedLyrics? result;
    try {
      final subsonicService =
          Provider.of<SubsonicService>(context, listen: false);
      final offlineService = OfflineService();
      final cached = await offlineService.getLocalLyrics(_song.id);
      // Локальный sidecar .lrc / USLT — music_assistant
      if (_song.isLocal) {
        try {
          final localText = await LocalMusicService().getLocalLyrics(_song.id).timeout(const Duration(seconds: 1));
          if (localText != null && localText.trim().isNotEmpty) {
            final parsed = SyncedLyrics.fromLrc(localText);
            result = parsed.isNotEmpty ? parsed : SyncedLyrics.fromPlainText(localText);
            if (result.isNotEmpty) {
              _memoryCache[cacheKey] = result;
              _cacheTime[cacheKey] = DateTime.now();
              return result;
            }
          }
        } catch (_) {}
      }
      Map<String, dynamic>? syncedData;
      try {
        syncedData = cached?['lyricsList'] as Map<String, dynamic>? ??
            await subsonicService
                .getLyricsBySongId(_song.id)
                .timeout(const Duration(seconds: 5));
      } catch (_) {
        syncedData = null;
      }

      if (syncedData != null) {
        final structuredLyrics = syncedData['structuredLyrics'];
        if (structuredLyrics is List && structuredLyrics.isNotEmpty) {
          final syncedEntry =
              structuredLyrics.cast<Map<String, dynamic>>().firstWhere(
                    (l) => l['synced'] == true,
                    orElse: () => <String, dynamic>{},
                  );
          final lines = syncedEntry['line'] as List?;
          if (lines != null && lines.isNotEmpty) {
            final parsedLines = lines
                .map<LyricLine>((line) {
                  final start = line['start'] as int? ?? 0;
                  return LyricLine(
                    timestamp: Duration(milliseconds: start),
                    text: line['value']?.toString() ?? '',
                  );
                })
                .where((l) => l.text.isNotEmpty)
                .toList();
            if (parsedLines.isNotEmpty) {
              result = SyncedLyrics(lines: parsedLines);
              _memoryCache[cacheKey] = result;
              _cacheTime[cacheKey] = DateTime.now();
              return result;
            }
          }
        }
      }

      // LRCLIB synced fallback — как в desktop (preferSynced): synced из LRCLIB важнее plain с сервера
      String? lrcPlainFallback;
      try {
        final lrcLib = LrcLibService();
        final lrcResult = await lrcLib
            .searchLyrics(
              artist: _song.artist ?? '',
              title: _song.title,
              album: _song.album,
              durationSeconds: _song.duration,
            )
            .timeout(const Duration(seconds: 5));
        if (lrcResult != null) {
          final structured = lrcResult['structuredLyrics'] as List?;
          if (structured != null && structured.isNotEmpty) {
            final entry = structured.first as Map<String, dynamic>;
            final lines = entry['line'] as List?;
            if (lines != null && lines.isNotEmpty) {
              final parsedLines = lines
                  .map<LyricLine>((line) {
                    final start = line['start'] as int? ?? 0;
                    return LyricLine(
                      timestamp: Duration(milliseconds: start),
                      text: line['value']?.toString() ?? '',
                    );
                  })
                  .where((l) => l.text.isNotEmpty)
                  .toList();
              if (parsedLines.isNotEmpty) {
                result = SyncedLyrics(lines: parsedLines);
                _memoryCache[cacheKey] = result;
                _cacheTime[cacheKey] = DateTime.now();
                return result;
              }
            }
          }
          final plainLrc = lrcResult['value']?.toString();
          if (plainLrc != null && plainLrc.isNotEmpty) {
            lrcPlainFallback = plainLrc;
          }
        }
      } catch (e) {
        debugPrint('[CompactLyrics] LRCLIB fallback error: $e');
      }

      // Серверный plain (getLyrics) — фолбэк после LRCLIB synced
      try {
        final plainData = cached?['lyrics'] as Map<String, dynamic>? ??
            await subsonicService
                .getLyrics(
                  artist: _song.artist,
                  title: _song.title,
                  id: _song.id,
                )
                .timeout(const Duration(seconds: 5));
        if (plainData != null) {
          final value = plainData['value']?.toString();
          if (value != null && value.isNotEmpty) {
            if (value.contains('[') && value.contains(':')) {
              result = SyncedLyrics.fromLrc(value);
            } else {
              result = SyncedLyrics.fromPlainText(value);
            }
            _memoryCache[cacheKey] = result;
            _cacheTime[cacheKey] = DateTime.now();
            return result;
          }
        }
      } catch (_) {}

      // LRCLIB plain как последний фолбэк
      if (lrcPlainFallback != null && lrcPlainFallback.isNotEmpty) {
        if (lrcPlainFallback.contains('[') && lrcPlainFallback.contains(':')) {
          result = SyncedLyrics.fromLrc(lrcPlainFallback);
        } else {
          result = SyncedLyrics.fromPlainText(lrcPlainFallback);
        }
        _memoryCache[cacheKey] = result;
        _cacheTime[cacheKey] = DateTime.now();
        return result;
      }

      // Не найдено — кэшируем null как в desktop (value: '')
      _memoryCache[cacheKey] = null;
      _cacheTime[cacheKey] = DateTime.now();
      return null;
    } catch (_) {
      _memoryCache[cacheKey] = null;
      _cacheTime[cacheKey] = DateTime.now();
      return result;
    }
  }

  void _applyLyrics(SyncedLyrics lyrics) {
    if (!mounted) return;
    setState(() {
      _lyrics = lyrics;
      _isLoading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _lyricsController.loadLines(lyrics.lines);
      final pos = Provider.of<PlayerProvider>(context, listen: false).position;
      _lyricsController.setPosition(pos);
    });
  }

  void _onLineTap(int index) {
    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
    playerProvider.seek(_lyricsController.lines[index].timestamp);
    _lyricsController.selectLine(index);
    setState(() => _showReturnButton = true);
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) _lyricsController.clearSelection();
    });
  }

  void _returnToSyncedPosition() {
    _lyricsController.clearSelection();
    setState(() => _showReturnButton = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    }

    if (_error != null || _lyrics == null || _lyrics!.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.music_off_rounded, size: 48, color: Colors.white38),
            const SizedBox(height: 16),
            Text(
              _error ?? AppLocalizations.of(context)!.noLyrics,
              style: const TextStyle(color: Colors.white54, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        AMLLLyricsWidget(
          controller: _lyricsController,
        ),
        if (_showReturnButton)
          Positioned(
            bottom: 16,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: _returnToSyncedPosition,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.keyboard_arrow_down,
                        color: Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        AppLocalizations.of(context)!.backToCurrent,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
