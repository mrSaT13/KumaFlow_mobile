import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/library_provider.dart';
import '../services/offline_service.dart';
import '../theme/app_theme.dart';

/// Экран «Загрузки»: видимость приватного кеша (system file manager его не видит).
/// Треки / книги / подкасты + путь кеша + экспорт в общую Музыку + очистка.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  final _off = OfflineService();
  bool _loading = true;
  Map<String, int> _breakdown = const {};
  String _cachePath = '';
  List<Song> _songs = const [];
  final Set<String> _exporting = {};
  String? _error;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _off.initialize();
      if (!mounted) return;
      final bd = await _off.getDownloadBreakdown();
      if (!mounted) return;
      final path = await _off.getCachePath();
      List<Song> songs = const [];
      try {
        if (!mounted) return;
        final lib = Provider.of<LibraryProvider>(context, listen: false);
        songs = await lib.getOfflineSongs().timeout(
          const Duration(seconds: 10),
          onTimeout: () => <Song>[],
        );
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _breakdown = bd;
        _cachePath = path;
        _songs = songs.take(200).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  String _fmtBytes(int b) {
    if (b <= 0) return '0 B';
    const u = ['B', 'KB', 'MB', 'GB'];
    var v = b.toDouble();
    var i = 0;
    while (v >= 1024 && i < u.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${u[i]}';
  }

  Future<void> _export(Song s) async {
    if (_exporting.contains(s.id)) return;
    setState(() => _exporting.add(s.id));
    try {
      final res = await _off.exportTrackFile(
        trackId: s.id,
        artist: s.artist ?? '',
        title: s.title,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res != null
              ? 'Экспортировано в Музыка/KumaFlow: ${OfflineService.exportFileName(s.artist ?? '', s.title, s.suffix ?? 'mp3')}'
              : 'Не удалось экспортировать'),
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting.remove(s.id));
    }
  }

  Future<void> _clearKind(String kind, String label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Удалить $label?'),
        content: const Text('Файлы удалятся с устройства. Плейлисты и оценки останутся.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Отмена')),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child:
                  const Text('Удалить', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    if (kind == 'all') {
      await _off.deleteAllDownloads();
    } else {
      await _off.clearDownloadKind(kind);
    }
    if (!mounted) return;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Загрузки')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Ошибка: $_error'),
                      const SizedBox(height: 12),
                      FilledButton(
                          onPressed: _load,
                          child: const Text('Повторить')),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _summaryCard(),
                      const SizedBox(height: 12),
                      _pathCard(),
                      const SizedBox(height: 12),
                      _kindTile(
                        icon: CupertinoIcons.music_note,
                        title: 'Треки',
                        count: _breakdown['tracks'] ?? 0,
                        kind: null,
                      ),
                      _kindTile(
                        icon: CupertinoIcons.book_fill,
                        title: 'Аудиокниги',
                        count: _breakdown['books'] ?? 0,
                        kind: 'books',
                        label: 'книги',
                      ),
                      _kindTile(
                        icon: CupertinoIcons.mic_fill,
                        title: 'Подкасты',
                        count: _breakdown['podcasts'] ?? 0,
                        kind: 'podcasts',
                        label: 'подкасты',
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const Text('Скачанные треки',
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600)),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: () => _clearKind('all', 'все загрузки'),
                            icon: const Icon(CupertinoIcons.trash,
                                size: 16, color: Colors.red),
                            label: const Text('Очистить всё',
                                style: TextStyle(color: Colors.red)),
                          ),
                        ],
                      ),
                      if (_songs.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                              child: Text('Пока пусто — скачай трек из плеера')),
                        )
                      else
                        ..._songs.map((s) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(
                                  CupertinoIcons.music_note_2,
                                  size: 22),
                              title: Text(s.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: Text(s.artist ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              trailing: _exporting.contains(s.id)
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : IconButton(
                                      icon: const Icon(
                                          CupertinoIcons.share_up,
                                          size: 20),
                                      tooltip:
                                          'Экспорт в Музыка/KumaFlow',
                                      onPressed: () => _export(s),
                                    ),
                            )),
                    ],
                  ),
                ),
    );
  }

  Widget _summaryCard() {
    final total = _breakdown['files'] ?? 0;
    final bytes = _breakdown['bytes'] ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(CupertinoIcons.arrow_down_circle_fill, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$total файлов · ${_fmtBytes(bytes)}',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    'Приватный кеш: файловый менеджер его не видит — это нормально. Для переноса используй экспорт.',
                    style: TextStyle(
                        fontSize: 12,
                        color: _isDark
                            ? AppTheme.darkSecondaryText
                            : AppTheme.lightSecondaryText),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pathCard() {
    return Card(
      child: ListTile(
        leading: const Icon(CupertinoIcons.folder_fill, size: 22),
        title: const Text('Путь кеша', style: TextStyle(fontSize: 13)),
        subtitle: Text(_cachePath.isEmpty ? '—' : _cachePath,
            style: const TextStyle(fontSize: 11),
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
      ),
    );
  }

  Widget _kindTile({
    required IconData icon,
    required String title,
    required int count,
    required String? kind,
    String? label,
  }) {
    return Card(
      child: ListTile(
        leading: Icon(icon, size: 22),
        title: Text(title),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$count',
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            if (kind != null) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(CupertinoIcons.trash,
                    size: 18, color: Colors.red),
                tooltip: 'Удалить ${label ?? kind}',
                onPressed: () => _clearKind(kind, label ?? kind),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
