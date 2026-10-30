import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../widgets/app_gradient_background.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/podcast_provider.dart';
import '../providers/player_provider.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';
import '../utils/navigation_helper.dart';
import '../widgets/podcast_card.dart';
import 'podcast_detail_screen.dart';

class PodcastsScreen extends StatefulWidget {
  const PodcastsScreen({super.key});

  @override
  State<PodcastsScreen> createState() => _PodcastsScreenState();
}

class _PodcastsScreenState extends State<PodcastsScreen> {
  final _feedController = TextEditingController();
  final _searchController = TextEditingController();
  bool _adding = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PodcastProvider>().loadSubscriptions();
    });
  }

  @override
  void dispose() {
    _feedController.dispose();
    _searchController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      final q = v.trim();
      if (q.isEmpty) {
        context.read<PodcastProvider>().clearSearch();
      } else {
        context.read<PodcastProvider>().search(q);
      }
    });
  }

  Future<void> _addFeed() async {
    final url = _feedController.text.trim();
    if (url.isEmpty) return;
    setState(() => _adding = true);
    final provider = context.read<PodcastProvider>();
    final ok = await provider.addFeed(url);
    if (!mounted) return;
    setState(() => _adding = false);
    if (ok) {
      _feedController.clear();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Подкаст добавлен')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(provider.error ?? 'Ошибка парсинга RSS')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final intensity = context.select<ThemeService, double>((t) => t.gradientIntensity);
    final accent = context.select<ThemeService, Color>((t) => t.accentColor.color);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 220,
            backgroundColor: isDark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82),
            surfaceTintColor: Colors.transparent,
            flexibleSpace: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        accent.withValues(alpha: (isDark ? 0.45 : 0.25) * intensity),
                        accent.withValues(alpha: (isDark ? 0.20 : 0.10) * intensity),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.55, 1.0],
                    ),
                  ),
                  child: FlexibleSpaceBar(
                    titlePadding: const EdgeInsets.only(left: 16, bottom: 16),
                    title: Text('Подкасты', style: theme.appBarTheme.titleTextStyle?.copyWith(letterSpacing: -0.3, shadows: [Shadow(color: Colors.black.withValues(alpha: isDark ? 0.55 : 0.18), blurRadius: 12)])),
                    background: Stack(
                      fit: StackFit.expand,
                      children: [
                        Opacity(
                          opacity: 0.18 * intensity,
                          child: CachedNetworkImage(
                            imageUrl: 'https://images.unsplash.com/photo-1478737270239-2f02b77fc618?w=800',
                            fit: BoxFit.cover,
                            errorWidget: (c,u,e) => const SizedBox(),
                          ),
                        ),
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [accent.withValues(alpha: 0.35*intensity), Colors.transparent],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Add RSS field
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark ? AppTheme.darkCard : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.rss_feed_rounded, color: accent, size: 20),
                          const SizedBox(width: 8),
                          Text('Добавить подкаст по RSS', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                        ]),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _feedController,
                                decoration: InputDecoration(
                                  hintText: 'https://example.com/feed.xml',
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                  filled: true,
                                  fillColor: isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7),
                                ),
                                keyboardType: TextInputType.url,
                                onSubmitted: (_) => _addFeed(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: _adding ? null : _addFeed,
                              style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                              child: _adding ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Добавить'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text('Вставь любую ссылку: RSS (mave/podster) или HTML-страницу (castbox.fm, podster.fm). Автоопределим RSS.', style: theme.textTheme.bodySmall?.copyWith(color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText, fontSize: 11)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Podster + iTunes search
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark ? AppTheme.darkCard : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.search_rounded, color: accent, size: 20),
                          const SizedBox(width: 8),
                          Text('Поиск подкастов', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                          const Spacer(),
                          Text('Podster + podcast.ru + iTunes', style: theme.textTheme.bodySmall?.copyWith(color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText, fontSize: 10)),
                        ]),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            hintText: 'Например: чай с психологом',
                            isDense: true,
                            prefixIcon: const Icon(Icons.search, size: 20),
                            suffixIcon: _searchController.text.isNotEmpty ? IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () { _searchController.clear(); context.read<PodcastProvider>().clearSearch(); setState(() {}); }) : null,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                            filled: true,
                            fillColor: isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7),
                          ),
                          onChanged: (v) { setState(() {}); _onSearchChanged(v); },
                          onSubmitted: (v) => _onSearchChanged(v),
                        ),
                        Consumer<PodcastProvider>(
                          builder: (context, pod, _) {
                            if (pod.isSearching) {
                              return const Padding(padding: EdgeInsets.all(12), child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))));
                            }
                            if (pod.searchResults.isEmpty) return const SizedBox.shrink();
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 12),
                                Text('Результаты (${pod.searchResults.length})', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700)),
                                const SizedBox(height: 8),
                                ...pod.searchResults.take(8).map((r) {
                                  final subscribed = pod.isSubscribed(r.feedUrl);
                                  return ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: r.artworkUrl.isNotEmpty ? CachedNetworkImage(imageUrl: r.artworkUrl, width: 44, height: 44, fit: BoxFit.cover, errorWidget: (c,u,e)=> Container(width:44,height:44,color: Colors.purple.shade100, child: const Icon(Icons.podcasts_rounded))) : Container(width:44,height:44,color: Colors.purple.shade100, child: const Icon(Icons.podcasts_rounded)),
                                    ),
                                    title: Text(r.trackName, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 13)),
                                    subtitle: Text(r.artistName.isEmpty ? r.feedUrl : r.artistName, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(fontSize: 11)),
                                    trailing: subscribed
                                        ? Icon(Icons.check_circle, color: accent, size: 20)
                                        : IconButton(icon: Icon(Icons.add_circle_outline, color: accent), onPressed: () async {
                                            final ok = await pod.addFeed(r.feedUrl);
                                            if (!context.mounted) return;
                                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Подкаст добавлен' : pod.error ?? 'Ошибка')));
                                          }),
                                    onTap: () {
                                      final stub = r.toPodcastStub();
                                      NavigationHelper.push(context, PodcastDetailScreen(podcast: stub));
                                    },
                                  );
                                }),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Consumer<PodcastProvider>(
                    builder: (context, pod, _) {
                      if (pod.isLoading && pod.allPodcasts.isEmpty) {
                        return const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()));
                      }
                      if (pod.allPodcasts.isEmpty) {
                        return Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(color: isDark ? AppTheme.darkCard : Colors.white, borderRadius: BorderRadius.circular(12)),
                          child: Column(children: [
                            Icon(Icons.podcasts_rounded, size: 48, color: accent.withValues(alpha: 0.7)),
                            const SizedBox(height: 12),
                            Text('Пока нет подписок', style: theme.textTheme.titleMedium),
                            const SizedBox(height: 6),
                            Text('Добавь RSS выше или найди подкаст через поиск.\nПо умолчанию показаны открытые подборки.', textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.lightSecondaryText)),
                          ]),
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(pod.subscriptions.isNotEmpty ? 'Мои подкасты' : 'Рекомендуем (открытые RSS)', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 12),
                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 180,
                              mainAxisSpacing: 16,
                              crossAxisSpacing: 12,
                              childAspectRatio: 0.68,
                            ),
                            itemCount: pod.allPodcasts.length,
                            itemBuilder: (context, i) {
                              final p = pod.allPodcasts[i];
                              return PodcastCard(
                                podcast: p,
                                size: 160,
                                onTap: () => NavigationHelper.push(context, PodcastDetailScreen(podcast: p)),
                                onPlayPressed: () async {
                                  final eps = await pod.loadEpisodes(p);
                                  if (eps.isEmpty) {
                                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Эпизоды не найдены или нужна настройка CORS')));
                                    return;
                                  }
                                  if (!context.mounted) return;
                                  final player = context.read<PlayerProvider>();
                                  final songs = eps.map((e) => e.toSong(p)).toList();
                                  await player.playSong(songs.first, playlist: songs, startIndex: 0);
                                },
                              );
                            },
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 120),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
