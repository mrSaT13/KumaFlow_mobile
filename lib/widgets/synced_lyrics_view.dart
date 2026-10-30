import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/lyrics.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/local_music_service.dart';
import '../services/storage_service.dart';
import '../services/subsonic_service.dart';
import '../services/lrclib_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Controller — shared between SyncedLyricsView and CompactLyricsView
// ─────────────────────────────────────────────────────────────────────────────

class AppleMusicLyricsController extends ChangeNotifier {
  List<LyricLine> _lines = [];
  int _activeIndex = -1;
  int _selectedIndex = -1;
  Duration _currentPosition = Duration.zero;
  int? _lastIndex;

  final ValueNotifier<double> progressNotifier = ValueNotifier<double>(0.0);
  final ValueNotifier<Duration> positionNotifier =
      ValueNotifier<Duration>(Duration.zero);

  bool get isUserScrolling => _selectedIndex != -1;
  List<LyricLine> get lines => _lines;
  int get activeIndex => _activeIndex;
  int get selectedIndex => _selectedIndex;
  Duration get currentPosition => _currentPosition;

  void loadLines(List<LyricLine> lines) {
    _lines = lines;
    _activeIndex = -1;
    _selectedIndex = -1;
    _lastIndex = null;
    _currentPosition = Duration.zero;
    progressNotifier.value = 0.0;
    positionNotifier.value = Duration.zero;
    notifyListeners();
  }

  void setPosition(Duration position) {
    _currentPosition = position;
    positionNotifier.value = position;
    final newIndex = _computeActiveIndex(position);
    final indexChanged = newIndex != _activeIndex;
    if (indexChanged) _activeIndex = newIndex;
    if (_selectedIndex != -1 && newIndex == _selectedIndex) _selectedIndex = -1;
    progressNotifier.value = _computeLineProgress();
    if (indexChanged) notifyListeners();
  }

  double _computeLineProgress() {
    if (_activeIndex < 0 || _activeIndex >= _lines.length) return 0.0;
    final start = _lines[_activeIndex].timestamp.inMilliseconds;
    int end;
    if (_activeIndex + 1 < _lines.length) {
      end = _lines[_activeIndex + 1].timestamp.inMilliseconds;
    } else {
      end = start + 5000;
    }
    if (end <= start) return 1.0;
    final progress =
        (_currentPosition.inMilliseconds - start) / (end - start);
    return progress.clamp(0.0, 1.0);
  }

  double getLineProgress() => progressNotifier.value;

  void selectLine(int index) {
    _selectedIndex = index;
    notifyListeners();
  }

  void clearSelection() {
    _selectedIndex = -1;
    notifyListeners();
  }

  int _computeActiveIndex(Duration position) {
    if (_lines.isEmpty) return -1;
    // Fast path: still on same line — как в десктопе через react-lrc, без линейного скана
    if (_lastIndex != null &&
        _lastIndex! >= 0 &&
        _lastIndex! < _lines.length) {
      final cur = _lines[_lastIndex!];
      final nextTs = _lastIndex! < _lines.length - 1
          ? _lines[_lastIndex! + 1].timestamp
          : null;
      if (position >= cur.timestamp &&
          (nextTs == null || position < nextTs)) {
        return _lastIndex!;
      }
    }
    // Binary search - O(log n) over sorted lyric timestamps
    int left = 0;
    int right = _lines.length - 1;
    int result = -1;
    while (left <= right) {
      final mid = (left + right) ~/ 2;
      if (_lines[mid].timestamp <= position) {
        result = mid;
        left = mid + 1;
      } else {
        right = mid - 1;
      }
    }
    _lastIndex = result;
    return result;
  }

  @override
  void dispose() {
    progressNotifier.dispose();
    positionNotifier.dispose();
    super.dispose();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main SyncedLyricsView — Apple Music-style synced lyrics
// ─────────────────────────────────────────────────────────────────────────────

class SyncedLyricsView extends StatefulWidget {
  final Song song;
  final String? imageUrl;
  final VoidCallback? onClose;
  // В горизонтальной панели kumaflow плеера текст инлайн:
  // свои слайдер+кнопки не нужны (иначе два прогресса и два плей).
  final bool showControls;

  const SyncedLyricsView({
    super.key,
    required this.song,
    this.imageUrl,
    this.onClose,
    this.showControls = true,
  });

  @override
  State<SyncedLyricsView> createState() => _SyncedLyricsViewState();
}

class _SyncedLyricsViewState extends State<SyncedLyricsView>
    with TickerProviderStateMixin {
  SyncedLyrics? _lyrics;
  bool _isLoading = true;
  String? _error;
  late AnimationController _fadeController;
  StreamSubscription<Duration>? _positionSubscription;

  late Song _song;
  final AppleMusicLyricsController _lyricsController =
      AppleMusicLyricsController();

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _song = widget.song;
    _loadLyrics();
    _setupPositionListener();

    _lyricsController.addListener(_onLyricsChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<PlayerProvider>(
        context,
        listen: false,
      ).addListener(_onPlayerStateChanged);
    });
  }

  @override
  void didUpdateWidget(SyncedLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id) {
      _song = widget.song;
      _loadLyrics();
    }
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _fadeController.dispose();
    _lyricsController.removeListener(_onLyricsChanged);
    try {
      Provider.of<PlayerProvider>(context, listen: false)
          .removeListener(_onPlayerStateChanged);
    } catch (_) {}
    super.dispose();
  }

  void _onLyricsChanged() {
    if (mounted) setState(() {});
  }

  void _onPlayerStateChanged() {
    if (!mounted) return;
    final player = Provider.of<PlayerProvider>(context, listen: false);
    final currentSong = player.currentSong;
    if (currentSong != null && currentSong.id != _song.id) {
      _song = currentSong;
      _loadLyrics();
    }
  }

  // ── Lyrics cache — как в KumaFlow-desktop (src/service/lyrics.ts → idb-keyval)
  // Ключ такой же как queryKey ['get-lyrics', artist, title, duration] в desktop
  static final Map<String, SyncedLyrics?> _memoryCache = {};
  static final Map<String, DateTime> _cacheTime = {};
  static const _cacheExpiry = Duration(hours: 24);
  static const _negativeCacheExpiry = Duration(minutes: 5); // для "нет текста" не блокируем на сутки как раньше
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

  // ── Lyrics loading — с кэшем как на десктопе (мгновенно) ───────────────

  Future<void> _loadLyrics() async {
    final key = _cacheKey(_song);
    // 0. Кэш — мгновенный возврат как в desktop (idb-keyval)
    if (_isCacheValid(key)) {
      final cached = _memoryCache[key];
      if (cached != null && cached.isNotEmpty) {
        _lyrics = cached;
        _lyricsController.loadLines(cached.lines);
        _fadeController.forward(from: 0);
        if (mounted) setState(() => _isLoading = false);
        return;
      }
      if (cached == null) {
        // Закэширован "нет текста" — показываем сразу без сети
        if (mounted) {
          setState(() => _isLoading = false);
          _fadeController.forward(from: 0);
        }
        return;
      }
    }
    // Дедупликация запросов — как TanStack Query в desktop
    if (_inFlight.containsKey(key)) {
      try {
        final deduped = await _inFlight[key]!;
        if (!mounted) return;
        if (deduped != null && deduped.isNotEmpty) {
          _lyrics = deduped;
          _lyricsController.loadLines(deduped.lines);
          _fadeController.forward(from: 0);
        }
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _lyrics = null;
    });

    final completer = _fetchLyricsWithCache(key);
    _inFlight[key] = completer;
    try {
      final parsed = await completer;
      if (!mounted) return;
      if (parsed != null && parsed.isNotEmpty) {
        _lyrics = parsed;
        _lyricsController.loadLines(parsed.lines);
        _fadeController.forward(from: 0);
      }
    } catch (e) {
      _error = e.toString();
      _fadeController.forward(from: 0);
    } finally {
      _inFlight.remove(key);
      if (mounted) {
        setState(() => _isLoading = false);
        if (_error != null || _lyrics == null) _fadeController.forward(from: 0);
      }
    }
  }

  Future<SyncedLyrics?> _fetchLyricsWithCache(String cacheKey) async {
    try {
      final subsonic = Provider.of<SubsonicService>(context, listen: false);
      final storage = StorageService();
      final preferSynced = await storage.getPreferSyncedLyrics().timeout(const Duration(milliseconds: 800), onTimeout: () => true);
      final lrcEnabled = await storage.getLrcLibFallback().timeout(const Duration(milliseconds: 800), onTimeout: () => true);
      final songLyricsEnabled = subsonic.songLyricsEnabled;

      // 0) Локальные теги .lrc/USLT — music_assistant/helpers/tags.py + filesystem_local
      if (_song.isLocal) {
        try {
          final localText = await LocalMusicService().getLocalLyrics(_song.id).timeout(const Duration(seconds: 1));
          if (localText != null && localText.trim().isNotEmpty) {
            final parsed = SyncedLyrics.fromLrc(localText);
            final result = parsed.isNotEmpty ? parsed : SyncedLyrics.fromPlainText(localText);
            if (result.isNotEmpty) {
              _memoryCache[cacheKey] = result;
              _cacheTime[cacheKey] = DateTime.now();
              return result;
            }
          }
        } catch (_) {}
      }
      // Если сервер не поддерживает songLyrics — сразу пропускаем шаг 1 как в aonsoku/utils/servers.ts

      // Цепочка как в десктопе src/service/lyrics.ts:54-132 (без Yandex - подписка)
      // 1. Subsonic structured — synced приоритет, plain сохраняем как fallback
      SyncedLyrics? fallbackPlain;
      if (songLyricsEnabled) {
        try {
          final subsonicData = await subsonic
              .getLyricsBySongId(_song.id)
              .timeout(const Duration(seconds: 5));
        if (subsonicData != null) {
          final list = subsonicData['structuredLyrics'] as List?;
          if (list != null && list.isNotEmpty) {
            for (final entry in list) {
              final synced = entry['synced'] == true;
              final lines = entry['line'] as List?;
              if (lines == null || lines.isEmpty) continue;
              if (synced) {
                final parsed = _parseStructuredLyrics(lines);
                if (parsed.isNotEmpty) {
                  _memoryCache[cacheKey] = parsed;
                  _cacheTime[cacheKey] = DateTime.now();
                  return parsed;
                }
              }
            }
            // plain из structuredLyrics[0] — как osUnsyncedLyricsFound в десктопе
            final first = list.first as Map<String, dynamic>?;
            if (first != null) {
              final lines = first['line'] as List?;
              if (lines != null && lines.isNotEmpty) {
                // пробуем plain value из первой записи
              }
            }
          }
          fallbackPlain = _tryPlainFromSubsonic(subsonicData);
        }
      } catch (_) {}
      } // songLyricsEnabled

      // 2. LRCLIB synced/ plain — с album и isLms split, как в desktop + feishin
      SyncedLyrics? lrcResult;
      if (lrcEnabled && preferSynced) {
        try {
          lrcResult = await _fetchFromLrcLib().timeout(const Duration(seconds: 5));
          if (lrcResult != null && lrcResult.isNotEmpty) {
            _memoryCache[cacheKey] = lrcResult;
            _cacheTime[cacheKey] = DateTime.now();
            return lrcResult;
          }
        } catch (_) {}
      }

      // 3. Fallback plain из getLyricsBySongId (если был)
      if (fallbackPlain != null && fallbackPlain.isNotEmpty) {
        _memoryCache[cacheKey] = fallbackPlain;
        _cacheTime[cacheKey] = DateTime.now();
        return fallbackPlain;
      }

      // 4. getLyrics?artist=&title= — старый Navidrome без OpenSubsonic extension
      try {
        final plainData = await subsonic
            .getLyrics(artist: _song.artist, title: _song.title, id: _song.id)
            .timeout(const Duration(seconds: 5));
        if (plainData != null) {
          final value = plainData['value']?.toString();
          if (value != null && value.isNotEmpty) {
            SyncedLyrics parsed;
            if (value.contains('[') && value.contains(':')) {
              parsed = SyncedLyrics.fromLrc(value);
            } else {
              parsed = SyncedLyrics.fromPlainText(value);
            }
            if (parsed.isNotEmpty) {
              _memoryCache[cacheKey] = parsed;
              _cacheTime[cacheKey] = DateTime.now();
              return parsed;
            }
          }
        }
      } catch (_) {}

      // 5. Ничего не найдено — кэшируем null на 24ч как в десктопе {value:''} чтобы не спамить
      _memoryCache[cacheKey] = null;
      _cacheTime[cacheKey] = DateTime.now();
      return null;
    } catch (_) {
      return null;
    }
  }

  SyncedLyrics? _tryPlainFromSubsonic(Map<String, dynamic> data) {
    final plain = data['value'] as String?;
    if (plain != null && plain.isNotEmpty) {
      return SyncedLyrics.fromPlainText(plain);
    }
    return null;
  }

  SyncedLyrics _parseStructuredLyrics(List<dynamic> lines) {
    final result = <LyricLine>[];
    for (final entry in lines) {
      final startMs = entry['start'] as int? ?? 0;
      final text = entry['value'] as String? ?? '';
      if (text.isEmpty) continue;
      result.add(LyricLine(
        timestamp: Duration(milliseconds: startMs),
        text: text,
      ));
    }
    result.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return SyncedLyrics(lines: result);
  }

  Future<SyncedLyrics?> _fetchFromLrcLib() async {
    try {
      final lrcLib = LrcLibService();
      final result = await lrcLib.searchLyrics(
        artist: _song.artist ?? '',
        title: _song.title,
        album: _song.album,
        durationSeconds: _song.duration,
      );
      if (result == null) return null;

      final structured = result['structuredLyrics'] as List?;
      if (structured != null && structured.isNotEmpty) {
        final entry = structured.first as Map<String, dynamic>;
        final lineList = entry['line'] as List?;
        if (lineList != null && lineList.isNotEmpty) {
          return _parseStructuredLyrics(lineList);
        }
      }

      final plain = result['value'] as String?;
      if (plain != null && plain.isNotEmpty) {
        return SyncedLyrics.fromPlainText(plain);
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  // ── Position listener ───────────────────────────────────────────────────

  void _setupPositionListener() {
    _positionSubscription?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final player = Provider.of<PlayerProvider>(context, listen: false);
      _positionSubscription =
          player.positionStream?.listen((position) {
        _lyricsController.setPosition(position);
      });
    });
  }

  // ── Build — 1:1 как на скрине HOT! ──────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeController,
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return const _LyricsSkeletonLoader();

    if (_error != null) {
      return _LyricsScaffold(
        imageUrl: widget.imageUrl,
        song: _song,
        onClose: widget.onClose,
        showControls: widget.showControls,
        child: Center(
          child: Text(
            'Failed to load lyrics',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
          ),
        ),
      );
    }

    if (_lyrics == null || _lyrics!.isEmpty) {
      return _LyricsScaffold(
        imageUrl: widget.imageUrl,
        song: _song,
        onClose: widget.onClose,
        showControls: widget.showControls,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lyrics_outlined,
                size: 48,
                color: Colors.white.withValues(alpha: 0.2),
              ),
              const SizedBox(height: 12),
              Text(
                'No lyrics available',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return _LyricsScaffold(
      imageUrl: widget.imageUrl,
      song: _song,
      onClose: widget.onClose,
      showControls: widget.showControls,
      child: AMLLLyricsWidget(
        controller: _lyricsController,
        onSeek: (duration) {
          Provider.of<PlayerProvider>(context, listen: false).seek(duration);
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AMLLLyricsWidget — the actual scrollable lyrics list
// ─────────────────────────────────────────────────────────────────────────────

class AMLLLyricsWidget extends StatefulWidget {
  final AppleMusicLyricsController controller;
  final ValueChanged<Duration>? onSeek;

  const AMLLLyricsWidget({
    super.key,
    required this.controller,
    this.onSeek,
  });

  @override
  State<AMLLLyricsWidget> createState() => _AMLLLyricsWidgetState();
}

class _AMLLLyricsWidgetState extends State<AMLLLyricsWidget> {
  final ScrollController _scrollController = ScrollController();
  bool _userIsScrolling = false;
  Timer? _scrollDebounce;

  static const double _itemHeight = 56.0;
  static const double _viewportPadding = 120.0;
  double _bottomPadding(BuildContext ctx) {
    final bottomInset = MediaQuery.of(ctx).padding.bottom;
    // header 60 + controls ~110 + safeArea => ensure last line can center above controls, not under nav bar
    return _viewportPadding + bottomInset + 88;
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerUpdate);
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollDebounce?.cancel();
    widget.controller.removeListener(_onControllerUpdate);
    _scrollController.dispose();
    super.dispose();
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    if (!_userIsScrolling && widget.controller.activeIndex >= 0) {
      _scrollToLine(widget.controller.activeIndex);
    }
    setState(() {});
  }

  void _onScroll() {
    // Detect user-initiated scroll
    if (_scrollController.hasClients) {
      // A small threshold to avoid false positives from auto-scroll
    }
  }

  void _scrollToLine(int index) {
    if (!_scrollController.hasClients) return;
    final targetOffset =
        index * _itemHeight - _viewportPadding;
    _scrollController.animateTo(
      targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  void _handleLineTap(int index) {
    if (index < 0 || index >= widget.controller.lines.length) return;
    final line = widget.controller.lines[index];
    widget.controller.selectLine(index);
    widget.onSeek?.call(line.timestamp);

    // Reset user scrolling flag after a delay
    _scrollDebounce?.cancel();
    _scrollDebounce = Timer(const Duration(seconds: 2), () {
      widget.controller.clearSelection();
    });
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.controller.lines;
    final activeIdx = widget.controller.activeIndex;
    final selectedIdx = widget.controller.selectedIndex;

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null) {
          _userIsScrolling = true;
        } else if (notification is ScrollEndNotification) {
          _userIsScrolling = false;
        }
        return false;
      },
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(height: _viewportPadding),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final line = lines[index];
                final isActive = index == activeIdx;
                final isSelected = index == selectedIdx;

                return GestureDetector(
                  onTap: () => _handleLineTap(index),
                  behavior: HitTestBehavior.opaque,
                  child: _LyricLineWidget(
                    line: line,
                    isActive: isActive,
                    isSelected: isSelected,
                    progress: isActive
                        ? widget.controller.getLineProgress()
                        : 0.0,
                    position: widget.controller.currentPosition,
                  ),
                );
              },
              childCount: lines.length,
            ),
          ),

          // Bottom padding — dynamic to keep focused line inside player (not under controls/nav bar)
          SliverToBoxAdapter(
            child: SizedBox(height: _bottomPadding(context)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Single lyric line widget — Apple Music gradient style
// ─────────────────────────────────────────────────────────────────────────────

class _LyricLineWidget extends StatelessWidget {
  final LyricLine line;
  final bool isActive;
  final bool isSelected;
  final double progress;
  final Duration position;

  const _LyricLineWidget({
    required this.line,
    required this.isActive,
    required this.isSelected,
    required this.progress,
    required this.position,
  });

  @override
  Widget build(BuildContext context) {
    // Как на скрине HOT! — активная белая 1.0, неактивная 0.35, без градиента
    final opacity = isActive ? 1.0 : (isSelected ? 0.85 : 0.35);
    final fontWeight = isActive ? FontWeight.w700 : FontWeight.w500;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
      constraints: const BoxConstraints(minHeight: 56),
      child: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 280),
        style: TextStyle(
          fontSize: isActive ? 22 : 18,
          fontWeight: fontWeight,
          color: Colors.white.withValues(alpha: opacity),
          height: 1.45,
          letterSpacing: -0.2,
          shadows: isActive
              ? [
                  Shadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 8,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Text(
          line.text,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          softWrap: true,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Skeleton loader — shimmer-style loading placeholder
// ─────────────────────────────────────────────────────────────────────────────

class _LyricsSkeletonLoader extends StatefulWidget {
  const _LyricsSkeletonLoader();

  @override
  State<_LyricsSkeletonLoader> createState() => _LyricsSkeletonLoaderState();
}

class _LyricsSkeletonLoaderState extends State<_LyricsSkeletonLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shimmerController,
      builder: (_, __) {
        return CustomPaint(
          painter: _ShimmerPainter(progress: _shimmerController.value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: List.generate(8, (i) {
                final widths = [0.65, 0.8, 0.5, 0.75, 0.6, 0.85, 0.45, 0.7];
                final w = widths[i % widths.length];
                final topPad = i == 0 ? 0.0 : 16.0 + (i % 3) * 4.0;
                return Padding(
                  padding: EdgeInsets.only(top: topPad),
                  child: Container(
                    height: 20,
                    width: MediaQuery.of(context).size.width * w,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                );
              }),
            ),
          ),
        );
      },
    );
  }
}

class _ShimmerPainter extends CustomPainter {
  final double progress;

  _ShimmerPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final shimmerX = size.width * progress * 2 - size.width * 0.3;
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Colors.transparent,
          Colors.white.withValues(alpha: 0.06),
          Colors.transparent,
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromLTWH(shimmerX, 0, size.width * 0.6, size.height));

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(_ShimmerPainter old) => old.progress != progress;
}

// ─────────────────────────────────────────────────────────────────────────────
// Gradient background overlay for dark theme (оставлен для совместимости)
// ─────────────────────────────────────────────────────────────────────────────

class LyricsGradientBackground extends StatelessWidget {
  final Widget child;
  final Color? accentColor;

  const LyricsGradientBackground({
    super.key,
    required this.child,
    this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = accentColor ?? const Color(0xFF1A1A2E);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.8),
            const Color(0xFF0D0D1A),
            const Color(0xFF000000),
          ],
          stops: const [0.0, 0.5, 1.0],
        ),
      ),
      child: child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _LyricsScaffold — 1:1 как на скрине HOT!/ Token (скрин 2)
// Blur обложки + тёмный оверлей + header + lyrics + bottom seek+controls
// ─────────────────────────────────────────────────────────────────────────────

class _LyricsScaffold extends StatelessWidget {
  final String? imageUrl;
  final Song song;
  final VoidCallback? onClose;
  final Widget child;
  final bool showControls;

  const _LyricsScaffold({
    required this.imageUrl,
    required this.song,
    required this.onClose,
    required this.child,
    this.showControls = true,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (imageUrl != null && imageUrl!.isNotEmpty)
            CachedNetworkImage(
              imageUrl: imageUrl!,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => Container(color: const Color(0xFF0A0A0F)),
            )
          else
            Container(color: const Color(0xFF0A0A0F)),
          ClipRect(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(color: Colors.black.withValues(alpha: 0.58)),
            ),
          ),
        // Content
        SafeArea(
          child: Column(
            children: [
              _LyricsHeader(song: song, onClose: onClose),
              Expanded(child: child),
              if (showControls) const _LyricsBottomControls(),
              if (showControls) const SizedBox(height: 8),
            ],
          ),
        ),
        ],
      ),
    );
  }
}

class _LyricsHeader extends StatelessWidget {
  final Song song;
  final VoidCallback? onClose;

  const _LyricsHeader({required this.song, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 8),
      child: Row(
        children: [
          InkWell(
            onTap: onClose,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 22),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 1),
                Text(
                  song.artist ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12, fontWeight: FontWeight.w400),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LyricsBottomControls extends StatelessWidget {
  const _LyricsBottomControls();

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        final pos = player.position;
        final dur = player.duration ?? Duration.zero;
        final totalMs = dur.inMilliseconds == 0 ? 1 : dur.inMilliseconds;
        final value = (pos.inMilliseconds / totalMs).clamp(0.0, 1.0);

        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2.5,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white.withValues(alpha: 0.25),
                  thumbColor: Colors.white,
                ),
                child: Slider(
                  value: value.toDouble(),
                  onChanged: (v) {
                    final seekMs = (v * dur.inMilliseconds).round();
                    player.seek(Duration(milliseconds: seekMs));
                  },
                ),
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 28),
                    onPressed: player.hasPrevious ? () => player.skipPrevious() : null,
                  ),
                  GestureDetector(
                    onTap: player.togglePlayPause,
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                      child: Icon(player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.black, size: 34),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 28),
                    onPressed: player.hasNext ? () => player.skipNext() : null,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
