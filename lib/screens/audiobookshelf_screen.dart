import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../services/audiobookshelf_service.dart';
import '../services/theme_service.dart';
import '../services/offline_service.dart';
import '../theme/app_theme.dart';
import '../utils/audiobook_helper.dart';
import '../utils/navigation_helper.dart';
import '../models/book.dart';
import 'audiobook_detail_screen.dart';
import 'settings_screen.dart';

class AudiobookshelfScreen extends StatefulWidget {
  const AudiobookshelfScreen({super.key});
  @override
  State<AudiobookshelfScreen> createState() => _AudiobookshelfScreenState();
}

class _AudiobookshelfScreenState extends State<AudiobookshelfScreen> {
  final _svc = AudiobookshelfService();
  final _searchCtrl = TextEditingController();
  bool _loading = false;
  List<Map<String, dynamic>> _allBooks = [];
  List<Map<String, dynamic>> _filtered = [];
   String _filter = 'all'; // all, progress, finished, notstarted
  String _query = '';

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.toLowerCase());
      _applyFilter();
    });
  }

  Future<void> _load() async {
    await _svc.initialize();
    final off = OfflineService();
    await off.init();
    if (off.isOfflineMode) {
      // Офлайн — показываем только скачанные книги, не лезем в сеть
      final downloaded = await off.getDownloadedBooks();
      if (mounted) {
        setState(() {
          _allBooks = downloaded;
          _applyFilter();
        });
      }
      return;
    }
    if (_svc.isConfigured) _fetch();
  }

  Future<void> _fetch() async {
    final off = OfflineService();
    await off.init();
    if (off.isOfflineMode) {
      final downloaded = await off.getDownloadedBooks();
      if (mounted) {
        setState(() {
          _allBooks = downloaded;
          _applyFilter();
        });
      }
      return;
    }
    setState(() => _loading = true);
    try {
      final libs = await _svc.fetchLibraries();
      if (libs.isNotEmpty) {
        // Fetch larger set to include completed books beyond first 50 (home uses same)
        final books = await _svc.fetchBooks(libraryId: libs.first['id'] as String? ?? '', limit: 300);
        if (mounted) {
          setState(() {
            _allBooks = books;
            _applyFilter();
          });
        }
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ABS error: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Unified progress helpers — handles all ABS variants (userMediaProgress, mediaProgress, progress map/num, currentTime)
  double _extractProgress(Map<String, dynamic> b) {
    var p = (b['userMediaProgress']?['progress'] as num?)?.toDouble();
    if (p != null) return p.clamp(0, 1).toDouble();
    p = (b['mediaProgress']?['progress'] as num?)?.toDouble();
    if (p != null) return p.clamp(0, 1).toDouble();
    final progMap = b['progress'] is Map ? b['progress'] as Map<String, dynamic> : null;
    if (progMap != null) {
      p = (progMap['progress'] as num?)?.toDouble();
      if (p != null) return p.clamp(0, 1).toDouble();
    }
    p = (b['progress'] as num?)?.toDouble();
    if (p != null) {
      if (p > 1) {
        final dur = (b['media']?['duration'] as num?)?.toDouble() ?? (b['duration'] as num?)?.toDouble() ?? 0;
        if (dur > 0) return (p / dur).clamp(0, 1).toDouble();
      }
      return p.clamp(0, 1).toDouble();
    }
    p = (b['userMediaProgress']?['progress'] as num?)?.toDouble() ?? (b['mediaProgress']?['progress'] as num?)?.toDouble();
    if (p != null) return p.clamp(0, 1).toDouble();
    final ct = (b['userMediaProgress']?['currentTime'] as num?)?.toDouble() ??
        (b['mediaProgress']?['currentTime'] as num?)?.toDouble() ??
        (progMap?['currentTime'] as num?)?.toDouble();
    final dur = (b['media']?['duration'] as num?)?.toDouble() ?? (b['duration'] as num?)?.toDouble() ?? 0;
    if (ct != null && dur > 0) return (ct / dur).clamp(0, 1).toDouble();
    return 0;
  }

  bool _extractFinished(Map<String, dynamic> b, double prog) {
    final f = b['userMediaProgress']?['isFinished'] as bool?;
    if (f != null) return f;
    final f2 = b['mediaProgress']?['isFinished'] as bool?;
    if (f2 != null) return f2;
    final progMap = b['progress'] is Map ? b['progress'] as Map<String, dynamic> : null;
    if (progMap != null && progMap['isFinished'] is bool) return progMap['isFinished'] as bool;
    if (prog >= 0.99) return true;
    final ct = (b['userMediaProgress']?['currentTime'] as num?)?.toDouble() ??
        (b['mediaProgress']?['currentTime'] as num?)?.toDouble() ??
        (progMap?['currentTime'] as num?)?.toDouble() ?? 0;
    final dur = (b['media']?['duration'] as num?)?.toDouble() ?? (b['duration'] as num?)?.toDouble() ?? 0;
    if (dur > 0 && ct >= dur - 1.0) return true;
    return false;
  }

  int _extractLastUpdate(Map<String, dynamic> b) {
    var v = (b['userMediaProgress']?['lastUpdate'] as num?)?.toInt();
    if (v != null && v != 0) return v;
    v = (b['mediaProgress']?['lastUpdate'] as num?)?.toInt();
    if (v != null && v != 0) return v;
    final progMap = b['progress'] is Map ? b['progress'] as Map<String, dynamic> : null;
    v = (progMap?['lastUpdate'] as num?)?.toInt();
    if (v != null && v != 0) return v;
    v = (b['userMediaProgress']?['updatedAt'] as num?)?.toInt();
    if (v != null && v != 0) return v;
    return 0;
  }

  void _applyFilter() {
    var list = List<Map<String, dynamic>>.from(_allBooks);
    if (_query.isNotEmpty) {
      list = list.where((b) {
        final title = (b['media']?['metadata']?['title'] ?? '').toString().toLowerCase();
        final author = (b['media']?['metadata']?['authorName'] ?? b['media']?['metadata']?['author'] ?? '').toString().toLowerCase();
        return title.contains(_query) || author.contains(_query);
      }).toList();
    }
    if (_filter == 'progress') {
      list = list.where((b) {
        final prog = _extractProgress(b);
        final fin = _extractFinished(b, prog);
        return prog > 0.01 && !fin;
      }).toList();
    } else if (_filter == 'finished') {
      list = list.where((b) {
        final prog = _extractProgress(b);
        return _extractFinished(b, prog);
      }).toList();
    } else if (_filter == 'notstarted') {
      list = list.where((b) => _extractProgress(b) <= 0.01).toList();
    }
    // Sort: started most recent first
    list.sort((a, b) {
      if (_filter == 'all' || _filter == 'progress') {
        final la = _extractLastUpdate(a);
        final lb = _extractLastUpdate(b);
        if (la != 0 || lb != 0) return lb.compareTo(la);
      }
      return 0;
    });
    _filtered = list;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final intensity = context.select<ThemeService, double>((t) => t.gradientIntensity);
    final accentColor =
        context.select<ThemeService, Color>((t) => t.accentColor.color);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Audiobookshelf'),
        backgroundColor: _isDark
            ? const Color(0xFF121212).withValues(alpha: 0.72)
            : Colors.white.withValues(alpha: 0.82),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    accentColor.withValues(alpha: (_isDark ? 0.40 : 0.20) * intensity),
                    accentColor.withValues(alpha: (_isDark ? 0.16 : 0.08) * intensity),
                    (_isDark ? Colors.black : Colors.white)
                        .withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
                border: Border(
                  bottom: BorderSide(
                    color: _isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.07),
                    width: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _fetch,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!_svc.isConfigured)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        const Icon(Icons.settings_rounded, size: 32, color: Colors.grey),
                        const SizedBox(height: 8),
                        const Text('Настрой Audiobookshelf в Настройки → Сервер → Audiobookshelf', textAlign: TextAlign.center),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: () {
                            // Correct redirect: open Settings on Server tab (index 2)
                            try {
                              NavigationHelper.push(context, const SettingsScreen(initialTab: 2));
                            } catch (_) {
                              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen(initialTab: 2)));
                            }
                          },
                          icon: const Icon(Icons.settings),
                          label: const Text('Открыть настройки'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // Search + filter
            TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Поиск по книгам...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Builder(builder: (ctx) {
              // Compute counts for chips — uses same robust helpers as _applyFilter
              int cntAll = _allBooks.length;
              int cntProgress = _allBooks.where((b) {
                final prog = _extractProgress(b);
                final fin = _extractFinished(b, prog);
                return prog > 0.01 && !fin;
              }).length;
              int cntFinished = _allBooks.where((b) {
                final prog = _extractProgress(b);
                return _extractFinished(b, prog);
              }).length;
              int cntNot = _allBooks.where((b) => _extractProgress(b) <= 0.01).length;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _filterChip('Все ($cntAll)', 'all'),
                    const SizedBox(width: 8),
                    _filterChip('В процессе ($cntProgress)', 'progress'),
                    const SizedBox(width: 8),
                    _filterChip('Завершённые ($cntFinished)', 'finished'),
                    const SizedBox(width: 8),
                    _filterChip('Не начатые ($cntNot)', 'notstarted'),
                  ],
                ),
              );
            }),
            const SizedBox(height: 16),
            if (_loading) const Center(child: CircularProgressIndicator()),
            if (!_loading && _filtered.isEmpty && _allBooks.isNotEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Ничего не найдено'))),
            for (final b in _filtered) _buildBookTile(b),
            if (!_svc.isConfigured && !_loading)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Text('Укажи URL и токен Audiobookshelf. Книги, обложки, описания, прогресс и таймер сна будут как в музыкальном плеере.', style: TextStyle(color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(String label, String value) {
    final selected = _filter == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (v) {
        if (v) setState(() { _filter = value; _applyFilter(); });
      },
    );
  }

  Widget _buildBookTile(Map<String, dynamic> b) {
    final id = b['id'] as String? ?? '';
    final title = b['media']?['metadata']?['title'] ?? 'Unknown';
    final author = b['media']?['metadata']?['authorName'] ?? b['media']?['metadata']?['author'] ?? '';
    final desc = b['media']?['metadata']?['description'] ?? '';
    final dur = (b['media']?['duration'] as num?)?.toDouble() ?? 0;
    MediaProgress? mp;
    try {
      final emb = b['userMediaProgress'] as Map<String, dynamic>?;
      if (emb != null) mp = MediaProgress.fromJson(emb, totalDuration: dur);
    } catch (_) {}
    final progress = mp?.progress ?? (b['userMediaProgress']?['progress'] as num?)?.toDouble() ?? 0;
    final isFinished = mp?.isFinished ?? progress >= 0.99;
    final cur = mp?.currentTime ?? 0;
    final coverUrl = _svc.getCoverUrl(id, width: 200);
    final headers = _svc.authHeaders;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AudiobookDetailScreen(itemId: id, initialData: b))),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: coverUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: coverUrl,
                        httpHeaders: headers,
                        width: 80,
                        height: 110,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(width: 80, height: 110, color: Colors.grey[800], child: const Icon(Icons.menu_book, color: Colors.white54)),
                      )
                    : Container(width: 80, height: 110, color: Colors.grey[800], child: const Icon(Icons.menu_book, color: Colors.white54)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 4),
                    Text(author, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: _isDark ? Colors.white70 : Colors.black54)),
                    if (desc.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(desc, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: _isDark ? Colors.white54 : Colors.black45)),
                    ],
                    if (progress > 0) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: progress.clamp(0, 1), backgroundColor: Colors.grey[300], valueColor: AlwaysStoppedAnimation(isFinished ? Colors.green : Theme.of(context).colorScheme.primary)),
                      const SizedBox(height: 2),
                      Text(isFinished ? 'Завершено' : '${(progress * 100).toStringAsFixed(0)}% • ${_fmt(cur)}', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                    ],
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, children: [
                      FilledButton.icon(
                        onPressed: () async {
                          try { await AudiobookHelper.playBook(context, id, b, startTime: isFinished ? 0 : cur); } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e'))); }
                        },
                        icon: Icon(isFinished ? Icons.replay_rounded : Icons.play_arrow_rounded, size: 14),
                        label: Text(isFinished ? 'Заново' : (cur > 30 ? 'Продолжить' : 'Слушать'), style: const TextStyle(fontSize: 11)),
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 28), padding: const EdgeInsets.symmetric(horizontal: 10), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      ),
                      PopupMenuButton<String>(
                        onSelected: (v) async {
                          if (v == 'download') {
                            final detail = await _svc.fetchBookDetail(id) ?? b;
                            final files = _svc.getAudioFiles(detail);
                            final off = OfflineService(); await off.init();
                            final n = await off.downloadBook(itemId: id, audioFiles: files, baseUrl: _svc.getUrl(), token: _svc.getToken());
                            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(n>0 ? 'Скачано $n файлов' : 'Ошибка')));
                          }
                          if (v == 'delete') {
                            final off = OfflineService(); await off.init(); await off.deleteBook(id);
                            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Кэш удалён')));
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'download', child: Text('Скачать')),
                          PopupMenuItem(value: 'delete', child: Text('Удалить кэш')),
                        ],
                        child: const Padding(padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), child: Icon(Icons.more_horiz, size: 16)),
                      ),
                    ]),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmt(double secs) {
    final d = Duration(seconds: secs.round());
    final h = d.inHours; final m = d.inMinutes.remainder(60).toString().padLeft(2,'0'); final s = d.inSeconds.remainder(60).toString().padLeft(2,'0');
    if (h>0) return '$h:$m:$s';
    return '$m:$s';
  }
}
