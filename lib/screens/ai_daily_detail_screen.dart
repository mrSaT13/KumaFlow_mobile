import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../services/ai_mix_service.dart';
import '../services/subsonic_service.dart';
import '../widgets/song_tile.dart';
import 'playlist_screen.dart';

/// Детали ежедневного ИИ-микса: проваливание с главной.
/// Временный микс живёт только здесь: регенерация стирает предыдущий
/// несохранённый и показывает новый. Сохранённый («Сохранить как плейлист»)
/// уходит на сервер и дальше живёт в Плейлистах сам по себе.
class AiDailyDetailScreen extends StatefulWidget {
  const AiDailyDetailScreen({super.key});

  @override
  State<AiDailyDetailScreen> createState() => _AiDailyDetailScreenState();
}

class _AiDailyDetailScreenState extends State<AiDailyDetailScreen> {
  bool _loading = true;
  bool _busy = false;
  String? _name;
  String? _comment;
  String? _date;
  String? _savedId;
  List<Song> _songs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final lib = Provider.of<LibraryProvider>(context, listen: false);
      final svc = AiMixService();
      final info = await svc.getLastDailyInfo();
      final saved = await svc.getDailySavedPlaylistId();
      List<Song> songs = const [];
      if (info != null) {
        final ids = ((info['ids'] as List?) ?? const []).map((e) => '$e').toList();
        try {
          songs = await lib.getSongsByIds(ids);
        } catch (_) {}
        if (songs.isEmpty) {
          final pool = lib.cachedAllSongs.isNotEmpty
              ? lib.cachedAllSongs
              : lib.randomSongs;
          final byId = {for (final s in pool) s.id: s};
          songs = [for (final id in ids) if (byId[id] != null) byId[id]!];
        }
      }
      if (!mounted) return;
      setState(() {
        _name = info?['name']?.toString();
        // Комментарий генерации в last-инфо не хранится — покажем дату.
        _comment = null;
        _date = info?['date']?.toString();
        _savedId = saved;
        _songs = songs;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final lib = Provider.of<LibraryProvider>(context, listen: false);
      final pool = lib.cachedAllSongs.isNotEmpty
          ? lib.cachedAllSongs
          : lib.randomSongs;
      if (pool.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Библиотека пуста — не из чего собрать')),
          );
        }
        return;
      }
      final res = await AiMixService()
          .generateDailyAutoMix(library: pool, force: true);
      if (res == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не собралось — попробуй ещё раз')),
          );
        }
        return;
      }
      await AiMixService().markDailyDone(res.name, res.songIds);
      if (!mounted) return;
      // Новый временный стирает предыдущий несохранённый полностью.
      setState(() {
        _name = res.name;
        _comment = res.comment;
        _date = DateTime.now().toIso8601String().substring(0, 10);
        _songs = res.songs;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не обновилось: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy || _songs.isEmpty) return;
    setState(() => _busy = true);
    try {
      final sub = Provider.of<SubsonicService>(context, listen: false);
      final lib = Provider.of<LibraryProvider>(context, listen: false);
      final name = (_name?.trim().isNotEmpty ?? false) ? _name!.trim() : 'ИИ-микс дня';
      final res = AiMixResult(
        name: name,
        comment: (_comment ?? '').trim(),
        songs: _songs,
        songIds: _songs.map((s) => s.id).toList(),
        rawResponse: '',
        fromFallback: false,
      );
      final id = await AiMixService().createServerPlaylist(
        subsonic: sub,
        result: res,
      );
      await AiMixService().setDailySavedPlaylistId(id);
      await lib.loadPlaylists();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Плейлист «$name» сохранён • ${_songs.length} треков')),
      );
      final saved = await AiMixService().getDailySavedPlaylistId();
      if (mounted) setState(() => _savedId = saved);
      if (id != null && mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => PlaylistScreen(playlistId: id)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не сохранилось: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _playAll({bool shuffle = false}) {
    if (_songs.isEmpty) return;
    final songs = shuffle ? (List.of(_songs)..shuffle()) : _songs;
    final qName = (_name?.trim().isNotEmpty ?? false) ? _name!.trim() : 'ИИ-микс дня';
    Provider.of<PlayerProvider>(context, listen: false).playSong(
      songs.first,
      playlist: songs,
      startIndex: 0,
      playlistName: qName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = (_name?.trim().isNotEmpty ?? false) ? _name!.trim() : 'ИИ-микс дня';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
            tooltip: 'Обновить (старый несохранённый сотрётся)',
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _songs.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Микс ещё не собран'),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _busy ? null : _refresh,
                          icon: const Icon(Icons.auto_awesome_rounded),
                          label: const Text('Собрать'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 180),
                  itemCount: _songs.length + 1,
                  itemBuilder: (ctx, i) {
                    if (i == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${_songs.length} треков${_date != null ? ' · $_date' : ''}',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: isDark ? Colors.white60 : Colors.black54,
                                    ),
                                  ),
                                ),
                                if (_savedId != null)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.green.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text(
                                      'сохранён в плейлистах',
                                      style: TextStyle(
                                          fontSize: 11, color: Colors.green),
                                    ),
                                  )
                                else
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.orange.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text(
                                      'временный',
                                      style: TextStyle(
                                          fontSize: 11, color: Colors.orange),
                                    ),
                                  ),
                              ],
                            ),
                            if (_comment != null && _comment!.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                _comment!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isDark ? Colors.white70 : Colors.black87,
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    }
                    final s = _songs[i - 1];
                    return SongTile(
                      song: s,
                      playlist: _songs,
                      index: i - 1,
                      showAlbum: true,
                    );
                  },
                ),
      floatingActionButton: _songs.isEmpty
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'ai_daily_save',
                  onPressed: _busy ? null : _save,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: const Text('Сохранить как плейлист'),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.extended(
                  heroTag: 'ai_daily_play',
                  onPressed: () => _playAll(),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Слушать'),
                ),
              ],
            ),
    );
  }
}
