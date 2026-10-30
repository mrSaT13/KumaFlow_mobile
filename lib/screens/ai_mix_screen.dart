import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../services/ai_service.dart';
import '../services/ai_mix_service.dart';
import '../services/subsonic_service.dart';
import '../services/offline_service.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_gradient_background.dart';
import '../widgets/song_tile.dart';
import 'playlist_screen.dart';

class AiMixScreen extends StatefulWidget {
  const AiMixScreen({super.key});

  @override
  State<AiMixScreen> createState() => _AiMixScreenState();
}

class _AiMixScreenState extends State<AiMixScreen> {
  final _promptCtrl = TextEditingController();
  final _commentCtrl = TextEditingController();
  double _count = 30;
  bool _generating = false;
  AiMixResult? _result;
  String? _error;
  final _aiMix = AiMixService();

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  @override
  void dispose() {
    _promptCtrl.dispose();
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final q = _promptCtrl.text.trim();
    if (q.isEmpty) {
      setState(() => _error = 'Введи запрос, например "грусть" или "вечеринка"');
      return;
    }
    final lib = Provider.of<LibraryProvider>(context, listen: false);
    // Было: срез 80к кэша. Стало: свежий пул из БД.
    final pool = await lib.getPoolForMix(limit: 700);
    if (pool.isEmpty) {
      setState(() => _error = 'Библиотека пуста — сначала синхронизируй сервер');
      return;
    }
    if (OfflineService().isOfflineMode) {
      setState(() => _error = 'Офлайн режим — AI микс требует онлайн библиотеку');
      return;
    }
    setState(() {
      _generating = true;
      _error = null;
      _result = null;
    });
    try {
      final res = await _aiMix.generateFromPrompt(
        userQuery: q,
        library: pool,
        desiredCount: _count.round(),
      ).timeout(const Duration(seconds: 50), onTimeout: () => throw TimeoutException('ИИ отвечает слишком долго — проверь токен/модель'));
      if (!mounted) return;
      setState(() {
        _result = res;
        _commentCtrl.text = res.comment;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _createPlaylist() async {
    final res = _result;
    if (res == null) return;
    final sub = Provider.of<SubsonicService>(context, listen: false);
    final lib = Provider.of<LibraryProvider>(context, listen: false);
    final name = res.name.trim().isEmpty ? 'AI Mix' : res.name.trim();
    final comment = _commentCtrl.text.trim().isEmpty ? res.comment : _commentCtrl.text.trim();
    final toCreate = AiMixResult(name: name, comment: comment, songs: res.songs, songIds: res.songIds, rawResponse: res.rawResponse, fromFallback: res.fromFallback);
    try {
      final messenger = ScaffoldMessenger.of(context);
      // show loading
      showDialog(context: context, barrierDismissible: false, builder: (_) => Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary)));
      final playlistId = await _aiMix.createServerPlaylist(subsonic: sub, result: toCreate);
      if (!mounted) return;
      Navigator.of(context).pop(); // close loading
      await lib.loadPlaylists();
      messenger.showSnackBar(SnackBar(content: Text('Плейлист "$name" создан • ${res.songs.length} треков'), duration: const Duration(seconds: 2)));
      if (playlistId != null && mounted) {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaylistScreen(playlistId: playlistId)));
      }
    } catch (e) {
      if (!mounted) return;
      try { Navigator.of(context).pop(); } catch (_) {}
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось создать: $e'), backgroundColor: Colors.red));
    }
  }

  void _playAll({bool shuffle = false}) {
    final res = _result;
    if (res == null || res.songs.isEmpty) return;
    final songs = shuffle ? (List.of(res.songs)..shuffle()) : res.songs;
    Provider.of<PlayerProvider>(context, listen: false).playSong(songs.first, playlist: songs, startIndex: 0);
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.select<ThemeService, Color>((t) => t.accentColor.color);
    final ai = AiService();
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppGradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              _buildAppBar(accent),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                  children: [
                    _buildAiStatusCard(accent),
                    const SizedBox(height: 16),
                    _buildPromptCard(accent),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: Colors.red.withOpacity(0.12), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.red.withOpacity(0.3))),
                        child: Row(children: [const Icon(Icons.error_outline, color: Colors.red, size: 20), const SizedBox(width: 8), Expanded(child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)))]),
                      ),
                    ],
                    if (_generating) ...[
                      const SizedBox(height: 24),
                      Center(child: Column(children: [CircularProgressIndicator(color: accent), const SizedBox(height: 12), Text('ИИ подбирает треки...', style: TextStyle(color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText, fontSize: 13))])),
                    ],
                    if (_result != null && !_generating) ...[
                      const SizedBox(height: 16),
                      _buildResultCard(accent),
                    ],
                    const SizedBox(height: 16),
                    _buildDailyCard(accent),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar(Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(icon: const Icon(CupertinoIcons.back), onPressed: () => Navigator.of(context).pop()),
          const SizedBox(width: 4),
          Icon(Icons.auto_awesome_rounded, color: accent, size: 24),
          const SizedBox(width: 8),
          const Expanded(child: Text('ИИ Микс', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
          IconButton(tooltip: 'Настройки ИИ', icon: Icon(CupertinoIcons.settings, color: _isDark ? Colors.white70 : Colors.black54), onPressed: () => Navigator.of(context).pushNamed('/settings_ai')),
        ],
      ),
    );
  }

  Widget _buildAiStatusCard(Color accent) {
    return FutureBuilder(
      future: AiService().initialize(),
      builder: (ctx, _) {
        final configured = AiService().isConfigured;
        final provider = AiService().provider;
        final model = AiService().model;
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _isDark ? AppTheme.darkDivider : AppTheme.lightDivider),
          ),
          child: Row(
            children: [
              Container(width: 42, height: 42, decoration: BoxDecoration(color: configured ? accent.withOpacity(0.15) : Colors.grey.withOpacity(0.15), borderRadius: BorderRadius.circular(10)), child: Icon(configured ? Icons.check_circle_rounded : Icons.warning_rounded, color: configured ? accent : Colors.orange)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(configured ? 'ИИ подключён' : 'ИИ не настроен', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(height: 2),
                Text(configured ? '${provider.label} • $model' : 'Укажи токен Ollama Cloud в Настройках → ИИ', style: TextStyle(fontSize: 12, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
              ])),
              if (!configured)
                FilledButton.tonal(onPressed: () => Navigator.of(context).pushNamed('/settings_ai'), child: const Text('Настроить')),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPromptCard(Color accent) {
    final examples = ['грусть', 'вечеринка', 'для бега', 'романтический вечер', 'фокус и работа', '90s рок', 'медитация', 'энергия утра'];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: _isDark ? AppTheme.darkSurface : AppTheme.lightSurface, borderRadius: BorderRadius.circular(14), border: Border.all(color: _isDark ? AppTheme.darkDivider : AppTheme.lightDivider)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Что хочешь послушать?', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
        const SizedBox(height: 10),
        TextField(
          controller: _promptCtrl,
          maxLines: 3,
          minLines: 1,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _generate(),
          decoration: InputDecoration(
            hintText: 'Например: "грустный меланхоличный плейлист для дождливого вечера, 30 треков"',
            hintStyle: TextStyle(fontSize: 13, color: _isDark ? Colors.white38 : Colors.black38),
            filled: true,
            fillColor: _isDark ? const Color(0xFF2C2C2E) : const Color(0xFFF2F2F7),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: accent, width: 1.4)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            suffixIcon: IconButton(icon: Icon(Icons.auto_awesome_rounded, color: accent), onPressed: _generating ? null : _generate),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: examples.map((ex) => ActionChip(label: Text(ex, style: const TextStyle(fontSize: 12)), onPressed: () { _promptCtrl.text = ex; _generate(); }, backgroundColor: _isDark ? const Color(0xFF2C2C2E) : const Color(0xFFF2F2F7), side: BorderSide(color: accent.withOpacity(0.2)))).toList()),
        const SizedBox(height: 16),
        Row(children: [const Icon(CupertinoIcons.music_note_list, size: 18, color: Colors.grey), const SizedBox(width: 8), const Text('Треков:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), const Spacer(), Text('${_count.round()}', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: accent))]),
        Slider(value: _count, min: 10, max: 60, divisions: 10, label: _count.round().toString(), activeColor: accent, onChanged: (v) => setState(() => _count = v)),
        const SizedBox(height: 8),
        SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _generating ? null : _generate, icon: _generating ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.auto_awesome_rounded), label: Text(_generating ? 'Подбираем...' : 'Сгенерировать'), style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))))),
        if (_result != null && _result!.fromFallback)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text('⚠️ ИИ недоступен — показан локальный подбор', style: TextStyle(fontSize: 11, color: Colors.orange.shade700))),
      ]),
    );
  }

  Widget _buildResultCard(Color accent) {
    final res = _result!;
    return Container(
      decoration: BoxDecoration(color: _isDark ? AppTheme.darkSurface : AppTheme.lightSurface, borderRadius: BorderRadius.circular(14), border: Border.all(color: _isDark ? AppTheme.darkDivider : AppTheme.lightDivider)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(res.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            TextField(controller: _commentCtrl, maxLines: 3, minLines: 1, style: TextStyle(fontSize: 13, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText), decoration: InputDecoration(hintText: 'Комментарий для плейлиста', isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), filled: true, fillColor: _isDark ? const Color(0xFF2C2C2E) : const Color(0xFFF2F2F7), border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none))),
            const SizedBox(height: 10),
            Text('${res.songs.length} треков • комментарий сохранится в плейлисте', style: TextStyle(fontSize: 11, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(children: [
            Expanded(child: FilledButton.icon(onPressed: _createPlaylist, icon: const Icon(Icons.playlist_add_rounded, size: 18), label: const Text('Создать плейлист'), style: FilledButton.styleFrom(backgroundColor: accent))),
            const SizedBox(width: 8),
            IconButton.filledTonal(onPressed: () => _playAll(shuffle: false), icon: const Icon(Icons.play_arrow_rounded), tooltip: 'Играть'),
            const SizedBox(width: 4),
            IconButton.filledTonal(onPressed: () => _playAll(shuffle: true), icon: const Icon(Icons.shuffle_rounded), tooltip: 'Перемешать'),
          ]),
        ),
        const Divider(height: 1),
        ...List.generate(res.songs.length, (i) => RepaintBoundary(child: SongTile(song: res.songs[i], playlist: res.songs, index: i, showAlbum: true))),
        const SizedBox(height: 8),
      ]),
    );
  }

  Widget _buildDailyCard(Color accent) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: accent.withOpacity(_isDark ? 0.12 : 0.08), borderRadius: BorderRadius.circular(14), border: Border.all(color: accent.withOpacity(0.25))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(Icons.calendar_today_rounded, size: 18, color: accent), const SizedBox(width: 8), const Text('Ежедневный ИИ-микс', style: TextStyle(fontWeight: FontWeight.w700)), const Spacer(), FutureBuilder(future: AiMixService().shouldGenerateDaily(), builder: (ctx, snap) { final due = snap.data == true; return Text(due ? 'готов к генерации' : 'уже создан сегодня', style: TextStyle(fontSize: 11, color: due ? accent : Colors.grey)); })]),
        const SizedBox(height: 6),
        Text('Раз в день приложение само собирает персональный микс на основе твоих вкусов (при открытой главной). Последний можно открыть ниже или сохранить отдельным плейлистом.', style: TextStyle(fontSize: 12, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText, height: 1.3)),
        const SizedBox(height: 10),
        SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () async {
          final lib = Provider.of<LibraryProvider>(context, listen: false);
          final pool = await lib.getPoolForMix(limit: 700);
          if (pool.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Библиотека пуста'))); return; }
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Генерируем ежедневный микс...')));
          try {
            final res = await AiMixService().generateDailyAutoMix(library: pool, force: true);
            if (res != null && mounted) {
              setState(() { _result = res; _commentCtrl.text = res.comment; });
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ежедневный "${res.name}" готов • ${res.songs.length} треков')));
            }
          } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e'))); }
        }, icon: const Icon(Icons.auto_awesome_rounded, size: 16), label: const Text('Сгенерировать ежедневный сейчас'))),
        FutureBuilder(future: AiMixService().getLastDailyInfo(), builder: (ctx, snap) {
          final info = snap.data;
          if (info == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              Expanded(child: Text('Последний: ${info['name']} • ${info['date']}', style: TextStyle(fontSize: 11, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText))),
              TextButton.icon(
                onPressed: () async {
                  final lib = Provider.of<LibraryProvider>(context, listen: false);
                  final ids = (info['ids'] as List?)?.map((e) => e.toString()).toList() ?? const [];
                  // Было: поиск id в 80к кэше. Стало: точечная гидрация из БД.
                  List<Song> songs;
                  try {
                    songs = await lib.getSongsByIds(ids);
                  } catch (_) {
                    final pool = lib.cachedAllSongs.isNotEmpty ? lib.cachedAllSongs : lib.randomSongs;
                    final byId = {for (final s in pool) s.id: s};
                    songs = ids.map((id) => byId[id]).whereType<Song>().toList();
                  }
                  if (songs.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Треки последнего микса уже не в библиотеке')));
                    return;
                  }
                  setState(() {
                    _result = AiMixResult(name: info['name'] as String? ?? 'Ежедневный микс', comment: 'Автомикс за ${info['date']}', songs: songs, songIds: songs.map((s) => s.id).toList());
                    _commentCtrl.text = _result!.comment;
                  });
                },
                icon: const Icon(Icons.open_in_new_rounded, size: 14),
                label: const Text('Открыть', style: TextStyle(fontSize: 12)),
              ),
            ]),
          );
        }),
      ]),
    );
  }
}
