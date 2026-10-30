import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../services/theme_service.dart';
import '../widgets/app_gradient_background.dart';
import '../services/audiobookshelf_service.dart';
import '../services/auto_dj_service.dart';
import '../services/offline_service.dart';
import '../providers/player_provider.dart';
import '../models/song.dart';
import '../models/book.dart';
import '../theme/app_theme.dart';

class AudiobookDetailScreen extends StatefulWidget {
  final String itemId;
  final Map<String, dynamic> initialData;
  const AudiobookDetailScreen({super.key, required this.itemId, required this.initialData});

  @override
  State<AudiobookDetailScreen> createState() => _AudiobookDetailScreenState();
}

class _AudiobookDetailScreenState extends State<AudiobookDetailScreen> with WidgetsBindingObserver {
  final _svc = AudiobookshelfService();
  final _offline = OfflineService();
  Map<String, dynamic>? _detail;
  List<BookChapter> _chapters = [];
  List<Map<String, dynamic>> _audioFiles = [];
  MediaProgress? _progress;
  double _totalDuration = 0;
  double _progressNorm = 0;
  bool _loading = true;
  bool _isDownloading = false;
  bool _isCached = false;
  double _dlProgress = 0;
  String _dlFileLabel = '';
  Timer? _refreshTimer;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _startRefreshTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshProgress();
    }
  }

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    // Refresh progress every 5 sec while screen is visible, plus live player sync
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      // If player is playing this book, UI will update via Provider watch, no need to fetch
      final pp = context.read<PlayerProvider>();
      if (pp.absBookId == widget.itemId && pp.isPlaying) return;
      _refreshProgress();
    });
  }

  Future<void> _refreshProgress() async {
    try {
      final totalDur = _totalDuration > 0 ? _totalDuration : _svc.extractTotalDuration(_detail ?? widget.initialData);
      MediaProgress? prog;
      try {
        prog = await _svc.fetchMediaProgress(widget.itemId, totalDuration: totalDur);
      } catch (_) {}
      prog ??= _svc.extractMediaProgress(_detail ?? widget.initialData, totalDuration: totalDur);
      if (prog != null && mounted) {
        final norm = (prog.progress ?? 0).clamp(0.0, 1.0);
        if ((norm - _progressNorm).abs() > 0.001 || prog.currentTime != _progress?.currentTime) {
          setState(() {
            _progress = prog;
            _progressNorm = norm;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _load() async {
    final detail = await _svc.fetchBookDetail(widget.itemId);
    final d = detail ?? widget.initialData;
    final chapters = _svc.extractBookChapters(d);
    final audioFiles = _svc.getAudioFiles(d);
    final totalDur = _svc.extractTotalDuration(d);
    // Fetch progress typed
    MediaProgress? prog;
    try {
      final raw = await _svc.fetchMediaProgress(widget.itemId, totalDuration: totalDur);
      if (raw != null) prog = raw;
    } catch (_) {}
    // Fallback embedded
    prog ??= _svc.extractMediaProgress(d, totalDuration: totalDur);
    // If still null but we have raw json, try fetchProgressRaw
    if (prog == null) {
      try {
        final raw = await _svc.fetchProgressRaw(widget.itemId);
        if (raw != null) prog = MediaProgress.fromJson(raw, totalDuration: totalDur);
      } catch (_) {}
    }
    double norm = prog?.progress ?? 0;
    // isFinished check
    await _checkCache(d, audioFiles);

    if (mounted) {
      setState(() {
        _detail = d;
        _chapters = chapters;
        _audioFiles = audioFiles;
        _totalDuration = totalDur;
        _progress = prog;
        _progressNorm = norm.clamp(0, 1);
        _loading = false;
      });
    }
  }

  Future<void> _checkCache(Map<String, dynamic> d, List<Map<String, dynamic>> files) async {
    await _offline.init();
    final fids = files.map((e) => e['ino']?.toString() ?? '').where((e) => e.isNotEmpty).toList();
    final cached = fids.isNotEmpty ? _offline.isBookDownloaded(widget.itemId, fids) : _offline.isBookCached(widget.itemId);
    if (mounted) setState(() => _isCached = cached);
  }

  String _getTitle() => _detail?['media']?['metadata']?['title'] ?? widget.initialData['media']?['metadata']?['title'] ?? _detail?['title'] ?? 'Unknown';
  String _getAuthor() {
    final authors = _detail?['media']?['metadata']?['authors'] as List?;
    if (authors != null && authors.isNotEmpty) return authors.map((a) => a['name'] ?? '').join(', ');
    return _detail?['media']?['metadata']?['authorName'] ?? _detail?['media']?['metadata']?['author'] ?? widget.initialData['media']?['metadata']?['authorName'] ?? '';
  }

  String _getNarrator() {
    final narr = _detail?['media']?['metadata']?['narrators'] as List?;
    if (narr != null && narr.isNotEmpty) return narr.join(', ');
    return _detail?['media']?['metadata']?['narratorName'] ?? '';
  }

  String _getDesc() => _detail?['media']?['metadata']?['description'] ?? _detail?['media']?['metadata']?['descriptionPlain'] ?? '';
  String _getPublisher() => _detail?['media']?['metadata']?['publisher'] ?? '';
  String _getSeries() {
    final series = _detail?['media']?['metadata']?['series'] as List?;
    if (series == null || series.isEmpty) return '';
    return series.map((s) => '${s['name']}${s['sequence'] != null ? ' #${s['sequence']}' : ''}').join(', ');
  }

  String _formatDuration(double secs) {
    final d = Duration(seconds: secs.round());
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h > 0) return '${h}ч ${m}м';
    return '${m} мин';
  }

  String _formatTime(double secs) {
    final d = Duration(seconds: secs.round());
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '${h}:$m:$s';
    return '$m:$s';
  }

  Future<void> _downloadBook() async {
    if (_isDownloading) return;
    setState(() {
      _isDownloading = true;
      _dlProgress = 0;
      _dlFileLabel = '';
    });
    try {
      final base = _svc.getUrl();
      final token = _svc.getToken();
      final meta = _detail ?? widget.initialData;
      final total = _audioFiles.isEmpty ? 1 : _audioFiles.length;
      final perFile = <String, double>{};
      final count = await _offline.downloadBook(itemId: widget.itemId, audioFiles: _audioFiles, baseUrl: base, token: token, bookMeta: meta, onFileProgress: (fid, p) {
        perFile[fid] = p;
        double sum = 0;
        for (final v in perFile.values) {
          sum += v.clamp(0.0, 1.0);
        }
        final agg = total > 0 ? (sum / total).clamp(0.0, 1.0) : 0.0;
        if (mounted) {
          setState(() {
            _dlProgress = agg;
            _dlFileLabel = fid;
          });
        }
      });
      // Кэшируем обложку для офлайна (в URL уже есть token)
      try {
        final coverUrl = _svc.getCoverUrl(widget.itemId, width: 600);
        if (coverUrl.isNotEmpty && _offline.getBookCoverPath(widget.itemId) == null) {
          final client = HttpClient();
          final req = await client.getUrl(Uri.parse(coverUrl));
          req.headers.set('Authorization', 'Bearer ${token}');
          final resp = await req.close();
          if (resp.statusCode == 200) {
            final bytes = <int>[];
            await resp.forEach(bytes.addAll);
            await _offline.saveBookCover(widget.itemId, bytes);
          }
          client.close();
        }
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(count > 0 ? 'Скачано файлов: $count' : 'Ошибка скачивания')));
        setState(() => _isCached = count > 0);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isDownloading = false;
        });
      }
    }
  }

  Future<void> _deleteBook() async {
    await _offline.deleteBook(widget.itemId);
    if (mounted) {
      setState(() => _isCached = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Кэш удалён')));
    }
  }

  void _playFrom(double startTime) {
    // Use typed chapters
    final chapters = _chapters.isEmpty
        ? [BookChapter(id: '0', title: _getTitle(), start: 0, end: _totalDuration, duration: _totalDuration)]
        : _chapters;
    final audioFiles = _audioFiles;
    final player = context.read<PlayerProvider>();

    // Determine file mapping Lissen-style
    // Set ABS sync context for provider (for progress sync)
    final chapterMaps = chapters.map((c) => c.toJson()).toList();
    player.setAbsBookContext(itemId: widget.itemId, chapters: chapterMaps, totalDuration: _totalDuration);

    // Build playlist with proper file mapping
    final playlist = <Song>[];
    final isSingleFile = audioFiles.length == 1 && chapters.length > 1;
    final isMultiFileOneToOne = audioFiles.length > 1 && chapters.length == audioFiles.length;

    for (int i = 0; i < chapters.length; i++) {
      final c = chapters[i];
      String chapFileId = '';
      double? chapStart;
      double? chapEnd;

      if (isMultiFileOneToOne) {
        chapFileId = audioFiles[i]['ino']?.toString() ?? '';
        chapStart = null;
        chapEnd = null;
      } else if (isSingleFile) {
        chapFileId = audioFiles.first['ino']?.toString() ?? '';
        chapStart = c.start;
        chapEnd = c.end;
      } else if (audioFiles.length > 1) {
        // Resolve via file start/end offsets
        // Find file that contains chapter start
        bool mapped = false;
        double acc = 0;
        for (final f in audioFiles) {
          final fid = f['ino']?.toString() ?? '';
          final dur = (f['duration'] as num?)?.toDouble() ?? 0;
          final fStart = acc;
          final fEnd = acc + dur;
          if (c.start >= fStart && c.start < fEnd) {
            chapFileId = fid;
            // If chapter fully inside file, clip
            if (c.end <= fEnd) {
              chapStart = c.start - fStart;
              chapEnd = c.end - fStart;
            } else {
              // Chapter spans multiple files — use from start to file end (first clip)
              // For simplicity, play from chapter start to file end; next chapters cover rest
              chapStart = c.start - fStart;
              chapEnd = dur;
            }
            mapped = true;
            break;
          }
          acc = fEnd;
        }
        if (!mapped) {
          chapFileId = audioFiles.first['ino']?.toString() ?? '';
          chapStart = c.start;
          chapEnd = c.end;
        }
      } else {
        // No files — use play endpoint
        chapFileId = '';
        chapStart = null;
        chapEnd = null;
      }

      // Prefer offline cache if downloaded - try ino then single file fallback
      String? offlinePath;
      if (chapFileId.isNotEmpty) {
        offlinePath = _offline.getBookFilePath(widget.itemId, chapFileId);
        // Single-file book downloaded as 'single' - try that fallback
        offlinePath ??= _offline.getBookFilePath(widget.itemId, "single");
      }
      if (offlinePath == null && chapFileId.isEmpty) {
        offlinePath = _offline.getBookFilePath(widget.itemId, "single");
      }
      if (offlinePath == null) {
        // scan any file for this book
        final any = _offline.getLocalPath("abs_${widget.itemId}_ch_0");
        if (any == null) {
          try {
            final dir = _offline.getBookFilePath(widget.itemId, chapFileId.isNotEmpty ? chapFileId : "0");
            offlinePath = offlinePath ?? dir;
          } catch(_){}
        } else {
          offlinePath = any;
        }
      }
      final streamUrl = offlinePath != null ? Uri.file(offlinePath).toString() : (chapFileId.isNotEmpty ? _svc.getStreamUrl(widget.itemId, fileId: chapFileId) : _svc.getStreamUrl(widget.itemId));
      // Check offline cache for this file — if cached, use offline path hint via abs cache lookup
      // Player will resolve offline automatically, keep network url as fallback
      playlist.add(Song(
        id: 'abs_${widget.itemId}_ch_$i',
        title: 'Глава ${i + 1}: ${c.title}',
        album: _getTitle(),
        artist: _getAuthor(),
        genre: 'Audiobook',
        duration: c.duration.round(),
        coverArt: 'abs:${widget.itemId}',
        path: streamUrl,
        isLocal: false,
        absStart: chapStart,
        absEnd: chapEnd,
      ));
    }

    // Calculate start index/offset using Lissen calculateChapterIndexAndPosition
    final pos = calculateChapterIndexAndPosition(chapters, startTime);
    int startIdx = pos.index >= 0 ? pos.index : 0;
    // Handle near-end epsilon: if startTime near totalDuration-1, reset to 0
    if (_totalDuration > 0 && startTime >= _totalDuration - 1.0) {
      startIdx = 0;
    }
    double offsetInChapter = pos.position;
    // Clamp offset to chapter duration
    if (startIdx < chapters.length) {
      offsetInChapter = offsetInChapter.clamp(0, chapters[startIdx].duration).toDouble();
    }

    // If playlist empty fallback
    if (playlist.isEmpty) return;
    if (startIdx >= playlist.length) startIdx = 0;

    final initialPos = offsetInChapter > 0.5
        ? Duration(milliseconds: (offsetInChapter * 1000).round())
        : null;

    // Use provider's initialPosition support (reliable via setAudioSource initialPosition)
    player.playSong(playlist[startIdx], playlist: playlist, startIndex: startIdx, initialPosition: initialPos);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coverUrl = _svc.getCoverUrl(widget.itemId, width: 600);
    final headers = _svc.authHeaders;
    final localCover = _offline.getBookCoverPath(widget.itemId);
    // Live progress from PlayerProvider when this book is playing
    final pp = context.watch<PlayerProvider>();
    final isLive = pp.absBookId == widget.itemId && _totalDuration > 0 && pp.absTotalDuration > 0;
    final liveCur = isLive ? pp.absCurrentTime : (_progress?.currentTime ?? 0);
    final liveNorm = isLive ? pp.absBookProgress : _progressNorm;
    final cur = liveCur;
    final displayNorm = liveNorm;
    final isFinished = isLive ? (liveNorm >= 0.99) : (_progress?.isFinished ?? false);
    final timeRemaining = _totalDuration > cur ? _totalDuration - cur : 0;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),
        title: Text(_getTitle(), maxLines: 1, overflow: TextOverflow.ellipsis),
        
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'download') _downloadBook();
              if (v == 'delete') _deleteBook();
            },
            itemBuilder: (_) => [
              if (!_isCached)
                PopupMenuItem(value: 'download', enabled: !_isDownloading, child: Row(children: [Icon(_isDownloading ? Icons.downloading : Icons.download, size: 18), const SizedBox(width: 8), Text(_isDownloading ? 'Скачивание...' : 'Скачать для офлайн')])),
              if (_isCached) const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline, size: 18), SizedBox(width: 8), Text('Удалить кэш')])),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: localCover != null
                            ? Image.file(
                                File(localCover),
                                width: 200,
                                height: 280,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(width: 200, height: 280, color: Colors.grey[800], child: const Icon(Icons.menu_book, size: 48, color: Colors.white54)),
                              )
                            : coverUrl.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: coverUrl,
                                httpHeaders: headers,
                                width: 200,
                                height: 280,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) => Container(width: 200, height: 280, color: Colors.grey[800], child: const Icon(Icons.menu_book, size: 48, color: Colors.white54)),
                              )
                            : Container(width: 200, height: 280, color: Colors.grey[800], child: const Icon(Icons.menu_book, size: 48, color: Colors.white54)),
                      ),
                      if (_isCached)
                        Positioned(top: 8, right: 8, child: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(8)), child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.offline_pin, size: 12, color: Colors.white), SizedBox(width: 4), Text('офлайн', style: TextStyle(fontSize: 10, color: Colors.white))]))),
                      if (isFinished)
                        Positioned(bottom: 8, left: 8, right: 8, child: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)), child: const Text('Завершено', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.white)))),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(_getTitle(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(_getAuthor(), style: TextStyle(fontSize: 16, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText), textAlign: TextAlign.center),
                if (_getNarrator().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('Читает: ${_getNarrator()}', style: TextStyle(fontSize: 14, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText), textAlign: TextAlign.center),
                ],
                if (_getSeries().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(_getSeries(), style: TextStyle(fontSize: 13, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText), textAlign: TextAlign.center),
                ],
                const SizedBox(height: 8),
                Text(_formatDuration(_totalDuration), style: TextStyle(fontSize: 14, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText), textAlign: TextAlign.center),
                if (displayNorm > 0 || isLive) ...[
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(value: displayNorm.clamp(0, 1), backgroundColor: Colors.grey[300], valueColor: AlwaysStoppedAnimation(isFinished ? Colors.green : Theme.of(context).colorScheme.primary), minHeight: 8),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${(displayNorm * 100).toStringAsFixed(0)}% • ${_formatTime(cur)}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      Text(isFinished ? 'Завершено' : 'Осталось ${_formatTime(timeRemaining.toDouble())}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                  if (isLive) ...[
                    const SizedBox(height: 4),
                    Text('Синхронизация: ${pp.isPlaying ? 'идёт' : 'пауза'} • сервер обновится каждые 5-15 сек', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                  ],
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => _playFrom(cur),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(cur > 30 && !isFinished ? 'Продолжить с ${_formatTime(cur)}' : isFinished ? 'Слушать заново' : 'Слушать'),
                ),
                if (_isDownloading) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: _dlProgress > 0 ? _dlProgress : null),
                  const SizedBox(height: 4),
                  Text(
                    _dlProgress > 0
                        ? 'Скачивание... ${(_dlProgress * 100).toInt()}%${_dlFileLabel.isNotEmpty ? ' • $_dlFileLabel' : ''}'
                        : 'Скачивание...',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          final player = context.read<PlayerProvider>();
                          player.setSleepTimer(const Duration(minutes: 30));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Таймер сна 30 мин установлен')));
                        },
                        icon: const Icon(Icons.bedtime_rounded),
                        label: const Text('Таймер 30м'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          final player = context.read<PlayerProvider>();
                          player.setSleepTimer(const Duration(minutes: 60));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Таймер сна 60 мин')));
                        },
                        icon: const Icon(Icons.bedtime_rounded),
                        label: const Text('60м'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // AutoDJ toggle for audiobooks — OFF by default
                Builder(builder: (ctx) {
                  final autoDj = AutoDjService();
                  return ListenableBuilder(
                    listenable: autoDj,
                    builder: (context, _) {
                      final enabled = autoDj.audiobookEnabled;
                      return Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).cardColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
                        ),
                        child: SwitchListTile(
                          title: const Text('Автодиджей после книги', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          subtitle: Text(enabled ? 'После последней главы добавится музыка' : 'Книга закончится — плеер остановится', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                          value: enabled,
                          onChanged: (v) async {
                            await autoDj.setAudiobookEnabled(v);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(v ? 'Автодиджей для книг включён' : 'Автодиджей для книг выключен')));
                            }
                          },
                          secondary: Icon(enabled ? Icons.queue_music_rounded : Icons.stop_circle_outlined, color: enabled ? Theme.of(context).colorScheme.primary : Colors.grey),
                        ),
                      );
                    },
                  );
                }),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    await _refreshProgress();
                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Прогресс обновлён')));
                  },
                  icon: const Icon(Icons.sync_rounded, size: 18),
                  label: const Text('Обновить прогресс'),
                ),
                if (_getPublisher().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Издатель: ${_getPublisher()}', style: TextStyle(fontSize: 12, color: Colors.grey)),
                ],
                if (_getDesc().isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Описание', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _isDark ? Colors.white : Colors.black)),
                  const SizedBox(height: 8),
                  Text(_getDesc(), style: TextStyle(fontSize: 14, color: _isDark ? Colors.white70 : Colors.black87)),
                ],
                const SizedBox(height: 24),
                Row(
                  children: [
                    const Icon(Icons.list_rounded, size: 20),
                    const SizedBox(width: 8),
                    Text('Главы (${_chapters.length})', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text(_formatDuration(_totalDuration), style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
                const SizedBox(height: 8),
                if (_chapters.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Глав нет — книга как один файл. Нажми Слушать.', style: TextStyle(color: Colors.grey[600]), textAlign: TextAlign.center),
                  )
                else
                  ..._chapters.asMap().entries.map((e) {
                    final idx = e.key;
                    final c = e.value;
                    final isCurrent = cur >= c.start && cur < c.end;
                    return Card(
                      color: isCurrent ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15) : null,
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isCurrent ? Theme.of(context).colorScheme.primary : Colors.grey[300],
                          child: Text('${idx + 1}', style: TextStyle(color: isCurrent ? Colors.white : Colors.black54, fontSize: 12)),
                        ),
                        title: Text(c.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal, fontSize: 14)),
                        subtitle: Text('${_formatTime(c.start)} • ${_formatTime(c.duration)}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                        trailing: const Icon(Icons.play_circle_outline),
                        onTap: () => _playFrom(c.start),
                      ),
                    );
                  }),
                const SizedBox(height: 80),
              ],
            ),
    );
  }
}



