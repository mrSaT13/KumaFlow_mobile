import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../widgets/app_gradient_background.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/podcast.dart';
import '../providers/podcast_provider.dart';
import '../providers/player_provider.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';
import '../widgets/episode_tile.dart';

class PodcastDetailScreen extends StatefulWidget {
  final Podcast podcast;
  const PodcastDetailScreen({super.key, required this.podcast});

  @override
  State<PodcastDetailScreen> createState() => _PodcastDetailScreenState();
}

class _PodcastDetailScreenState extends State<PodcastDetailScreen> {
  List<PodcastEpisode> _episodes = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final eps = await context.read<PodcastProvider>().loadEpisodes(widget.podcast);
      if (!mounted) return;
      setState(() { _episodes = eps; _loading = false; });
      if (eps.isEmpty) setState(() => _error = 'Эпизоды не найдены');
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  Future<void> _playAll() async {
    if (_episodes.isEmpty) return;
    final player = context.read<PlayerProvider>();
    final songs = _episodes.map((e) => e.toSong(widget.podcast)).toList();
    await player.playSong(songs.first, playlist: songs, startIndex: 0);
  }

  Future<void> _playEpisode(int index) async {
    final player = context.read<PlayerProvider>();
    final songs = _episodes.map((e) => e.toSong(widget.podcast)).toList();
    await player.playSong(songs[index], playlist: songs, startIndex: index);
  }

  @override
  Widget build(BuildContext context) {
    final intensity = context.select<ThemeService, double>((t) => t.gradientIntensity);
    final accent = context.select<ThemeService, Color>((t) => t.accentColor.color);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final p = widget.podcast;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 360,
            backgroundColor: isDark ? const Color(0xFF121212).withValues(alpha: 0.8) : Colors.white.withValues(alpha: 0.85),
            leading: Padding(
              padding: const EdgeInsets.all(8),
              child: CircleAvatar(
                backgroundColor: Colors.black.withValues(alpha: 0.35),
                child: IconButton(icon: const Icon(Icons.arrow_back_rounded, color: Colors.white), onPressed: () => Navigator.pop(context)),
              ),
            ),
            actions: [
              Consumer<PodcastProvider>(
                builder: (context, pod, _) {
                  final subscribed = pod.isPodcastSubscribed(p);
                  return PopupMenuButton<String>(
                    icon: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.35), shape: BoxShape.circle),
                      child: const Icon(Icons.more_vert_rounded, color: Colors.white, size: 20),
                    ),
                    onSelected: (v) async {
                      final provider = context.read<PodcastProvider>();
                      if (v == 'remove') {
                        // find effective id by feedUrl to handle stub vs subscribed id mismatch
                        final target = pod.subscriptions.where((e) => e.feedUrl == p.feedUrl).firstOrNull ?? pod.subscriptions.where((e) => e.id == p.id).firstOrNull;
                        final idToRemove = target?.id ?? p.id;
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Удалить подписку?'),
                            content: Text('Удалить "${p.title}" из подписок?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
                              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
                            ],
                          ),
                        );
                        if (confirmed != true) return;
                        await provider.removePodcast(idToRemove);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Подписка удалена')));
                        Navigator.pop(context);
                      } else if (v == 'subscribe') {
                        final ok = await pod.addFeed(p.feedUrl);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Подписка добавлена' : pod.error ?? 'Ошибка')));
                        if (mounted) setState(() {});
                      } else if (v == 'refresh') {
                        _load();
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'refresh', child: Text('Обновить')),
                      if (subscribed) const PopupMenuItem(value: 'remove', child: Text('Удалить подписку')) else const PopupMenuItem(value: 'subscribe', child: Text('Подписаться')),
                    ],
                  );
                },
              ),
              const SizedBox(width: 8),
            ],
            flexibleSpace: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: FlexibleSpaceBar(
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (p.imageUrl != null && p.imageUrl!.isNotEmpty)
                        CachedNetworkImage(imageUrl: p.imageUrl!, fit: BoxFit.cover, errorWidget: (c,u,e) => Container(color: Colors.grey.shade900)),
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              accent.withValues(alpha: 0.35 * intensity),
                              accent.withValues(alpha: 0.18 * intensity),
                              (isDark ? Colors.black : Colors.white).withValues(alpha: 0.92),
                            ],
                            stops: const [0.0, 0.45, 1.0],
                          ),
                        ),
                      ),
                      // hero content
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 16,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: SizedBox(
                                width: 140,
                                height: 140,
                                child: p.imageUrl != null && p.imageUrl!.isNotEmpty
                                    ? CachedNetworkImage(imageUrl: p.imageUrl!, fit: BoxFit.cover, placeholder: (c,u)=>Container(color: Colors.grey.shade900), errorWidget: (c,u,e)=>Container(color: Colors.grey.shade900, child: const Icon(Icons.podcasts_rounded, color: Colors.white54, size: 40)))
                                    : Container(color: Colors.grey.shade900, child: const Icon(Icons.podcasts_rounded, color: Colors.white54, size: 40)),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(6)),
                                    child: const Text('ПОДКАСТ', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(p.title, style: theme.textTheme.headlineSmall?.copyWith(color: isDark ? Colors.white : Colors.black, fontWeight: FontWeight.w900, height: 1.1, shadows: [Shadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 8)]), maxLines: 3, overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: 4),
                                  Text(p.author, style: theme.textTheme.bodyMedium?.copyWith(color: isDark ? Colors.white70 : Colors.black87, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: 4),
                                  Text('${_episodes.isEmpty ? p.episodeCount : _episodes.length} эпизодов', style: theme.textTheme.bodySmall?.copyWith(color: isDark ? Colors.white70 : Colors.black54)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (p.description.isNotEmpty) ...[
                    Text(p.description, style: theme.textTheme.bodyMedium?.copyWith(height: 1.5, color: isDark ? Colors.white70 : Colors.black87), maxLines: 6, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 16),
                  ],
                  Consumer<PodcastProvider>(
                    builder: (context, pod, _) {
                      final subscribed = pod.isPodcastSubscribed(p);
                      return Row(
                        children: [
                          FilledButton.icon(
                            onPressed: _episodes.isEmpty ? null : _playAll,
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('Слушать'),
                            style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
                          ),
                          const SizedBox(width: 10),
                          if (subscribed)
                            OutlinedButton.icon(
                              onPressed: () async {
                                final target = pod.subscriptions.where((e) => e.feedUrl == p.feedUrl).firstOrNull;
                                final idToRemove = target?.id ?? p.id;
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('Отписаться?'),
                                    content: Text('Отписаться от "${p.title}"?'),
                                    actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Отписаться'))],
                                  ),
                                );
                                if (confirmed == true) {
                                  await pod.removePodcast(idToRemove);
                                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Подписка удалена')));
                                  setState(() {});
                                }
                              },
                              icon: const Icon(Icons.check_rounded, size: 18),
                              label: const Text('Вы подписаны'),
                              style: OutlinedButton.styleFrom(foregroundColor: accent, side: BorderSide(color: accent), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
                            )
                          else
                            FilledButton.icon(
                              onPressed: () async {
                                final ok = await pod.addFeed(p.feedUrl);
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Подписка добавлена' : pod.error ?? 'Ошибка')));
                                setState(() {});
                              },
                              icon: const Icon(Icons.add_rounded, size: 18),
                              label: const Text('Подписаться'),
                              style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
                            ),
                          const SizedBox(width: 8),
                          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh_rounded, size: 20), style: IconButton.styleFrom(side: BorderSide(color: isDark ? Colors.white24 : Colors.black12))),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Divider(color: isDark ? Colors.white10 : Colors.black12),
                ],
              ),
            ),
          ),
          if (_loading)
            const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())))
          else if (_error != null && _episodes.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(children: [
                  Icon(Icons.error_outline_rounded, size: 48, color: accent.withValues(alpha: 0.7)),
                  const SizedBox(height: 12),
                  Text(_error!, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.lightSecondaryText)),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _load, style: FilledButton.styleFrom(backgroundColor: accent), child: const Text('Повторить')),
                ]),
              ),
            )
          else
            SliverList.builder(
              itemCount: _episodes.length,
              itemBuilder: (context, i) {
                final ep = _episodes[i];
                return EpisodeTile(
                  episode: ep,
                  podcast: p,
                  index: i,
                  playlist: _episodes,
                  onPlay: () => _playEpisode(i),
                );
              },
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ],
      ),
    );
  }
}
