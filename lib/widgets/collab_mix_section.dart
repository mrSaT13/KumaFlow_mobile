import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../screens/settings_screen.dart';
import '../services/collab/collab_account.dart';
import '../services/collab/collab_mix_service.dart';
import '../services/subsonic_service.dart';

/// Карточка коллаб-микса в Миксах на главной:
/// Play + shuffle + автообновление + сохранить (на сервер / снимок).
class CollabMixSection extends StatefulWidget {
  final double hPad;
  const CollabMixSection({super.key, this.hPad = 16});

  @override
  State<CollabMixSection> createState() => _CollabMixSectionState();
}

class _CollabMixSectionState extends State<CollabMixSection> {
  final _mix = CollabMixService();
  final _store = CollabAccountStore();
  bool _settingsOpen = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_boot);
  }

  Future<void> _boot() async {
    if (!mounted) return;
    await _mix.loadSettings();
    await _store.load();
    if (!mounted) return;
    // Скрываемся если друзей нет ИЛИ все выключены в настройках.
    if (_store.enabledAccounts.isEmpty) {
      setState(() {});
      return;
    }
    final hadCache = await _mix.loadCached();
    if (!mounted) return;
    // Автообновление: если кэша нет или протух — пересобрать в фоне.
    if (!hadCache) {
      await _generate(force: false);
    }
    if (mounted) setState(() {});
  }

  Future<void> _generate({bool force = true}) async {
    if (!mounted) return;
    late List<Song> pool;
    try {
      final lib = Provider.of<LibraryProvider>(context, listen: false);
      // Было: весь 80к кэш. Стало: свежий стратифицированный пул из БД.
      pool = await lib.getPoolForMix(limit: 700);
    } catch (_) {
      return;
    }
    if (pool.isEmpty) return;
    try {
      final resolver =
          Provider.of<PlayerProvider>(context, listen: false).multiServerResolver;
      await _mix.generate(ownPool: pool, resolver: resolver, force: force);
    } catch (_) {
      await _mix.generate(ownPool: pool, force: force);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_mix, _store]),
      builder: (context, _) {
        if (_store.enabledAccounts.isEmpty) return const SizedBox.shrink();
        final accent = Theme.of(context).colorScheme.primary;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.hPad),
              child: Row(
                children: [
                  Icon(Icons.group_rounded, color: accent, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _mix.hasMix ? _mix.name : 'Коллаб-микс',
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w800),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          _mix.hasMix
                              ? _mix.description
                              : 'Общий микс с друзьями',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey[600]),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (_mix.generating)
                    const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    IconButton(
                      icon: const Icon(Icons.refresh_rounded, size: 20),
                      tooltip: 'Пересобрать микс',
                      color: accent,
                      onPressed: () => _generate(force: true),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.hPad),
              child: _HeroCard(
                mix: _mix,
                onPlay: _play,
                onShuffle: _shufflePlay,
                onSaveServer: _saveToServer,
                onSnapshot: _snapshot,
                onToggleSettings: () =>
                    setState(() => _settingsOpen = !_settingsOpen),
                settingsOpen: _settingsOpen,
              ),
            ),
            if (_settingsOpen)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: widget.hPad),
                child: _SettingsCard(
                  mix: _mix,
                  onChanged: () => _generate(force: true),
                ),
              ),
            if (_mix.error != null && !_mix.hasMix)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: widget.hPad),
                child: Text(_mix.error!,
                    style: const TextStyle(fontSize: 12, color: Colors.red)),
              ),
          ],
        );
      },
    );
  }

  void _play() {
    final songs = _mix.songs;
    if (songs.isEmpty) return;
    context.read<PlayerProvider>().playSong(songs.first, playlist: songs);
  }

  void _shufflePlay() {
    final songs = List<Song>.from(_mix.songs)..shuffle();
    if (songs.isEmpty) return;
    context.read<PlayerProvider>().playSong(songs.first, playlist: songs);
  }

  Future<void> _saveToServer() async {
    try {
      final sub = Provider.of<SubsonicService>(context, listen: false);
      final (saved, skipped) = await _mix.saveToServer(sub);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(skipped > 0
            ? 'На сервер: $saved тр. (+$skipped с серверов друзей — только в приложении)'
            : 'Сохранено на сервер: $saved тр.'),
      ));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Не сохранилось: $e')));
    }
  }

  Future<void> _snapshot() async {
    try {
      await _mix.saveSnapshot();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Снимок сохранён локально')));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Не сохранилось: $e')));
    }
  }
}

class _HeroCard extends StatelessWidget {
  final CollabMixService mix;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;
  final VoidCallback onSaveServer;
  final VoidCallback onSnapshot;
  final VoidCallback onToggleSettings;
  final bool settingsOpen;

  const _HeroCard({
    required this.mix,
    required this.onPlay,
    required this.onShuffle,
    required this.onSaveServer,
    required this.onSnapshot,
    required this.onToggleSettings,
    required this.settingsOpen,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final songs = mix.songs;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          colors: isDark
              ? const [Color(0xFF1B2A1D), Color(0xFF121212)]
              : const [Color(0xFFE8F5E9), Colors.white],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
            color: accent.withValues(alpha: 0.35), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                _CoverCollage(songs: songs.take(4).toList()),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${songs.length} треков',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey[600])),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: mix.contributors
                            .map((c) => Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: accent.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(c,
                                      style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: accent)),
                                ))
                            .toList(),
                      ),
                      if (mix.friendTracksCount > 0) ...[
                        const SizedBox(height: 4),
                        Text('с серверов друзей: ${mix.friendTracksCount}',
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey[600])),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: songs.isEmpty ? null : onPlay,
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    label: const Text('Слушать'),
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: songs.isEmpty ? null : onShuffle,
                  icon: const Icon(Icons.shuffle_rounded, size: 20),
                  tooltip: 'Перемешать',
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert_rounded),
                  tooltip: 'Сохранить',
                  onSelected: (v) {
                    if (v == 'server') onSaveServer();
                    if (v == 'snapshot') onSnapshot();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: 'server',
                        child: Text('Сохранить на сервер')),
                    PopupMenuItem(
                        value: 'snapshot',
                        child: Text('Снимок локально')),
                  ],
                ),
                IconButton(
                  onPressed: onToggleSettings,
                  icon: Icon(
                    settingsOpen
                        ? Icons.expand_less_rounded
                        : Icons.tune_rounded,
                    size: 20,
                  ),
                  tooltip: 'Баланс микса',
                  color: accent,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CoverCollage extends StatelessWidget {
  final List<Song> songs;
  const _CoverCollage({required this.songs});

  @override
  Widget build(BuildContext context) {
    if (songs.isEmpty) {
      return Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
            color: Colors.grey[800],
            borderRadius: BorderRadius.circular(12)),
        child: const Icon(Icons.group_rounded,
            color: Colors.white54, size: 36),
      );
    }
    String coverFor(Song s) {
      try {
        return Provider.of<PlayerProvider>(context, listen: false)
            .multiServerResolver
            .resolveCoverUrl(s, size: 200);
      } catch (_) {
        return '';
      }
    }

    if (songs.length == 1) {
      final url = coverFor(songs.first);
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: url.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: url,
                width: 96,
                height: 96,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) =>
                    Container(width: 96, height: 96, color: Colors.grey[800]))
            : Container(width: 96, height: 96, color: Colors.grey[800]),
      );
    }
    return SizedBox(
      width: 96,
      height: 96,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2, crossAxisSpacing: 1, mainAxisSpacing: 1),
          itemCount: songs.length.clamp(2, 4),
          itemBuilder: (_, i) {
            final url = coverFor(songs[i]);
            return url.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: url,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) =>
                        Container(color: Colors.grey[800]))
                : Container(color: Colors.grey[800]);
          },
        ),
      ),
    );
  }
}

class _SettingsCard extends StatefulWidget {
  final CollabMixService mix;
  final VoidCallback onChanged;
  const _SettingsCard({required this.mix, required this.onChanged});

  @override
  State<_SettingsCard> createState() => _SettingsCardState();
}

class _SettingsCardState extends State<_SettingsCard> {
  late double _selfWeight;
  late int _limit;

  @override
  void initState() {
    super.initState();
    _selfWeight = widget.mix.settings.selfWeight;
    _limit = widget.mix.settings.limit;
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF1E1E1E)
            : const Color(0xFFF5F5F5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Я', style: TextStyle(fontSize: 12)),
              Expanded(
                child: Slider(
                  value: _selfWeight,
                  min: 0,
                  max: 1,
                  divisions: 10,
                  activeColor: accent,
                  label: _selfWeight < 0.35
                      ? 'Больше друзей'
                      : _selfWeight > 0.65
                          ? 'Больше моё'
                          : 'Поровну',
                  onChanged: (v) => setState(() => _selfWeight = v),
                  onChangeEnd: (v) async {
                    await widget.mix.setSettings(
                        widget.mix.settings.copyWith(selfWeight: v));
                    widget.onChanged();
                  },
                ),
              ),
              const Text('Друзья', style: TextStyle(fontSize: 12)),
            ],
          ),
          Row(
            children: [
              const Text('Треков:', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 8),
              for (final n in [15, 30, 50])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text('$n'),
                    selected: _limit == n,
                    onSelected: (_) async {
                      setState(() => _limit = n);
                      await widget.mix.setSettings(
                          widget.mix.settings.copyWith(limit: n));
                      widget.onChanged();
                    },
                  ),
                ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const SettingsScreen(initialTab: 2)),
                ),
                icon: const Icon(Icons.person_add_rounded, size: 16),
                label: const Text('Друзья',
                    style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
