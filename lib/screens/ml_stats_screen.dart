import 'dart:math' as math;
import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/library_provider.dart';
import '../services/subsonic_service.dart';
import '../theme/app_theme.dart';
import '../services/ml_service.dart';
import '../services/local_analytics_service.dart';
import '../services/kumaflow_brain/kumaflow_brain_bridge.dart';
import '../services/kumaflow_brain/kumaflow_brain_client.dart';
import '../services/kumaflow_brain/kumaflow_brain_settings.dart';

/// ML listening statistics screen with charts, heatmap, and achievement tracking.
///
/// Источники данных (приоритет):
/// 1. KumaFlow Brain (wrapped/profile) — если мост активен;
/// 2. Локально: LocalAnalyticsService (реальные прослушивания) + MLService
///    (рейтинги/профиль). Работает и при выключенном мозге.
class MLStatsScreen extends StatefulWidget {
  const MLStatsScreen({super.key});

  @override
  State<MLStatsScreen> createState() => _MLStatsScreenState();
}

class _MLStatsScreenState extends State<MLStatsScreen> {
  late final MLStatsProvider _provider;

  @override
  void initState() {
    super.initState();
    _provider = MLStatsProvider();
    _provider.loadStats().then((_) {
      if (!mounted) return;
      // Best-effort: догрузить статистику мозга поверх локальной.
      try {
        final bridge =
            Provider.of<KumaFlowBrainBridge>(context, listen: false);
        final settings =
            Provider.of<KumaFlowBrainSettings>(context, listen: false);
        final client = bridge.client;
        if (client != null && settings.userId.isNotEmpty) {
          _provider.loadBrainStats(client, settings.userId);
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _provider.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return ChangeNotifierProvider.value(
      value: _provider,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),
          title: const Text('Статистика прослушиваний'),
          
        ),
        body: Consumer<MLStatsProvider>(
          builder: (context, provider, _) {
            if (provider.isLoading) {
              return const Center(child: CircularProgressIndicator());
            }

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildOverviewCards(provider, isDark),
                const SizedBox(height: 20),
                _buildTopGenresChart(provider, isDark),
                const SizedBox(height: 20),
                _buildTopArtists(provider, isDark),
                const SizedBox(height: 20),
                _buildActivityHeatmap(provider, isDark),
                const SizedBox(height: 20),
                _buildAchievements(provider, isDark),
                const SizedBox(height: 40),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildOverviewCards(MLStatsProvider provider, bool isDark) {
    return Row(
      children: [
        Expanded(
          child: _StatCard(
            icon: Icons.headphones_rounded,
            label: 'Треков',
            value: provider.totalTracks.toString(),
            isDark: isDark,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatCard(
            icon: Icons.timer_rounded,
            label: 'Время',
            value: provider.formattedTotalTime,
            isDark: isDark,
          ),
        ),
      ],
    );
  }

  Widget _buildTopGenresChart(MLStatsProvider provider, bool isDark) {
    return Builder(builder: (context) {
      final accent = Theme.of(context).colorScheme.primary;
      return _SectionCard(
        title: 'Топ жанры',
        isDark: isDark,
        child: provider.genreDistribution.isEmpty
            ? SizedBox(
                height: 120,
                child: Center(
                  child: Text(
                    provider.isLoading
                        ? 'Загрузка…'
                        : 'Нет данных о жанрах — послушай что-нибудь',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark
                          ? AppTheme.darkSecondaryText
                          : AppTheme.lightSecondaryText,
                    ),
                  ),
                ),
              )
            : SizedBox(
                height: 180,
                child: CustomPaint(
                  size: const Size(double.infinity, 180),
                  painter: _PieChartPainter(
                    data: provider.genreDistribution,
                    colors: [
                      accent,
                      accent.withValues(alpha: 0.85),
                      accent.withValues(alpha: 0.70),
                      accent.withValues(alpha: 0.55),
                      accent.withValues(alpha: 0.40),
                    ],
                    isDark: isDark,
                  ),
                ),
              ),
        footer: provider.genreDistribution.isEmpty
            ? null
            : _buildLegend(provider.genreDistribution, isDark),
      );
    });
  }

  Widget _buildLegend(List<_GenreStat> data, bool isDark) {
    return Builder(builder: (context) {
      final accent = Theme.of(context).colorScheme.primary;
      final colors = [
        accent,
        accent.withValues(alpha: 0.85),
        accent.withValues(alpha: 0.70),
        accent.withValues(alpha: 0.55),
        accent.withValues(alpha: 0.40),
      ];
      return Wrap(
        spacing: 12,
        runSpacing: 6,
        children: data.take(5).map((item) {
          final color = colors[data.indexOf(item) % colors.length];

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '${item.name} (${item.percentage.toStringAsFixed(0)}%)',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText,
              ),
            ),
          ],
        );
      }).toList(),
      );
    });
  }

  Widget _buildTopArtists(MLStatsProvider provider, bool isDark) {
    return Builder(builder: (context) {
      final accent = Theme.of(context).colorScheme.primary;
      if (provider.topArtists.isEmpty) {
        return _SectionCard(
          title: 'Топ артисты',
          isDark: isDark,
          child: SizedBox(
            height: 64,
            child: Center(
              child: Text(
                provider.isLoading
                    ? 'Загрузка…'
                    : 'Нет данных об артистах — послушай что-нибудь',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark
                      ? AppTheme.darkSecondaryText
                      : AppTheme.lightSecondaryText,
                ),
              ),
            ),
          ),
        );
      }
      return _SectionCard(
        title: 'Топ артисты',
        isDark: isDark,
        child: Column(
          children: provider.topArtists.take(5).toList().asMap().entries.map((entry) {
            final rank = entry.key + 1;
            final artist = entry.value;
            final maxCount = provider.topArtists.first.playCount;

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    child: Text(
                      '$rank',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: rank <= 3 ? accent : (isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _ArtistAvatar(artist: artist, isDark: isDark),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          artist.name,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: isDark ? Colors.white : Colors.black,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: artist.playCount / maxCount,
                            backgroundColor: isDark ? AppTheme.darkDivider : AppTheme.lightDivider,
                            valueColor: AlwaysStoppedAnimation(accent),
                            minHeight: 3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${artist.playCount}',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      );
    });
  }

  Widget _buildActivityHeatmap(MLStatsProvider provider, bool isDark) {
    return Builder(builder: (context) {
      final accent = Theme.of(context).colorScheme.primary;
      return _SectionCard(
        title: 'Активность (последние 12 недель)',
        isDark: isDark,
        child: SizedBox(
          height: 112,
          child: CustomPaint(
            size: const Size(double.infinity, 112),
            painter: _HeatmapPainter(
              data: provider.weeklyActivity,
              isDark: isDark,
              accent: accent,
            ),
          ),
        ),
      );
    });
  }

  Widget _buildAchievements(MLStatsProvider provider, bool isDark) {
    return Builder(builder: (context) {
      final accent = Theme.of(context).colorScheme.primary;
      return _SectionCard(
        title: 'Достижения',
        isDark: isDark,
        child: Column(
          children: provider.achievements.map((achievement) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: achievement.unlocked
                          ? accent.withAlpha(30)
                          : (isDark ? AppTheme.darkElevated : AppTheme.lightDivider),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      achievement.icon,
                      size: 20,
                      color: achievement.unlocked
                          ? accent
                          : (isDark ? AppTheme.darkTertiaryText : AppTheme.lightSecondaryText),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          achievement.name,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: achievement.unlocked
                                ? (isDark ? Colors.white : Colors.black)
                                : (isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          achievement.description,
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? AppTheme.darkTertiaryText : AppTheme.lightSecondaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (achievement.unlocked)
                    Icon(Icons.check_circle, size: 18, color: accent)
                  else
                    SizedBox(
                      width: 48,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: achievement.progress,
                          backgroundColor: isDark ? AppTheme.darkDivider : AppTheme.lightDivider,
                          valueColor: AlwaysStoppedAnimation(accent),
                          minHeight: 3,
                        ),
                      ),
                    ),
                ],
              ),
            );
          }).toList(),
        ),
      );
    });
  }
}

// -- Data Models --

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool isDark;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: accent),
          const SizedBox(height: 10),
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : Colors.black,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? footer;
  final bool isDark;

  const _SectionCard({
    required this.title,
    required this.child,
    this.footer,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : Colors.black,
            ),
          ),
          const SizedBox(height: 12),
          child,
          if (footer != null) ...[
            const SizedBox(height: 12),
            footer!,
          ],
        ],
      ),
    );
  }
}

class _GenreStat {
  final String name;
  final double percentage;

  const _GenreStat(this.name, this.percentage);
}

class _ArtistStat {
  final String name;
  final int playCount;
  /// Subsonic coverArt id для картинки артиста (обложка любого его трека).
  /// Может быть null — тогда аватарка резолвится в UI через библиотеку.
  final String? coverArtId;

  const _ArtistStat(this.name, this.playCount, {this.coverArtId});
}

/// Аватарка артиста: пробует обложку трека (Subsonic), иначе иконка.
/// coverArtId идёт из провайдера; если его нет — ищем первый трек артиста
/// в локальной библиотеке и берём его coverArt.
class _ArtistAvatar extends StatelessWidget {
  final _ArtistStat artist;
  final bool isDark;

  const _ArtistAvatar({required this.artist, required this.isDark});

  @override
  Widget build(BuildContext context) {
    String? coverId = artist.coverArtId;
    if (coverId == null || coverId.isEmpty) {
      try {
        final lib = Provider.of<LibraryProvider>(context, listen: false);
        final all = lib.cachedAllSongs.isNotEmpty
            ? lib.cachedAllSongs
            : lib.randomSongs;
        final lower = artist.name.toLowerCase();
        for (final s in all) {
          if ((s.artist ?? '').toLowerCase() == lower &&
              s.coverArt != null &&
              s.coverArt!.isNotEmpty) {
            coverId = s.coverArt;
            break;
          }
        }
      } catch (_) {}
    }
    String url = '';
    if (coverId != null && coverId.isNotEmpty) {
      try {
        final sub =
            Provider.of<SubsonicService>(context, listen: false);
        url = sub.getCoverArtUrl(coverId, size: 96);
      } catch (_) {}
    }
    if (url.isEmpty) {
      return CircleAvatar(
        radius: 16,
        backgroundColor:
            isDark ? AppTheme.darkElevated : AppTheme.lightDivider,
        child: Icon(Icons.person,
            size: 18,
            color: isDark
                ? AppTheme.darkSecondaryText
                : AppTheme.lightSecondaryText),
      );
    }
    return CircleAvatar(
      radius: 16,
      backgroundColor:
          isDark ? AppTheme.darkElevated : AppTheme.lightDivider,
      backgroundImage: CachedNetworkImageProvider(url),
      onBackgroundImageError: (_, __) {},
      child: null,
    );
  }
}

class _Achievement {
  final String name;
  final String description;
  final IconData icon;
  final bool unlocked;
  final double progress;

  const _Achievement({
    required this.name,
    required this.description,
    required this.icon,
    required this.unlocked,
    this.progress = 0,
  });
}

// -- Provider --

class MLStatsProvider extends ChangeNotifier {
  bool isLoading = true;
  int totalTracks = 0;
  int totalMinutes = 0;
  List<_GenreStat> genreDistribution = [];
  List<_ArtistStat> topArtists = [];
  List<List<double>> weeklyActivity = [];
  List<_Achievement> achievements = [];
  /// true, когда поверх локальной статистики успешно легли данные мозга.
  bool brainMerged = false;

  String get formattedTotalTime {
    final hours = totalMinutes ~/ 60;
    final mins = totalMinutes % 60;
    if (hours > 0) return '${hours}h ${mins}m';
    return '${mins}m';
  }

  /// Локальная статистика. Работает при выключенном мозге.
  /// ВАЖНО: раньше здесь создавался НОВЫЙ `RecommendationService()` —
  /// у него пустые profiles/affinity, отсюда «Время 0m» и «Топ жанры 0%».
  /// Теперь primary-источник — синглтоны с реальными данными:
  /// LocalAnalyticsService (история прослушиваний) + MLService (рейтинги).
  Future<void> loadStats() async {
    isLoading = true;
    brainMerged = false;
    notifyListeners();

    try {
      final mlService = MLService();
      try {
        await mlService.initialize();
      } catch (_) {}
      final analytics = LocalAnalyticsService();
      try {
        await analytics.initialize();
      } catch (_) {}

      final mlRatings = mlService.ratings;
      final history = analytics.listeningHistory;
      final stats = analytics.getStats(
        from: DateTime.now().subtract(const Duration(days: 365)),
        to: DateTime.now(),
      );

      // --- Треки / время: аналитика первична, ML — фолбэк ---
      totalTracks = math.max(mlRatings.length, stats.totalListens);
      if (totalTracks == 0) totalTracks = history.length;
      totalMinutes = stats.totalDurationMs ~/ 60000;
      if (totalMinutes == 0) {
        // Фолбэк: суммарный playCount из ML-рейтингов × средняя длина 4 мин.
        int plays = 0;
        for (final r in mlRatings.values) {
          plays += r.playCount;
        }
        if (plays > 0) {
          totalMinutes = (plays * 4).clamp(0, 1 << 30).toInt();
        }
      }

      // --- Жанры: счёты из аналитики + жанры ML-рейтингов + веса профиля ---
      final genreCounts = <String, double>{};
      for (final g in stats.topGenres) {
        if (g.name.trim().isEmpty) continue;
        genreCounts[g.name] = (genreCounts[g.name] ?? 0) + g.count.toDouble();
      }
      for (final r in mlRatings.values) {
        final g = (r.genre ?? '').trim();
        if (g.isEmpty) continue;
        genreCounts[g] = (genreCounts[g] ?? 0) + r.playCount.toDouble();
      }
      try {
        mlService.profile.preferredGenres.forEach((k, v) {
          if (k.trim().isEmpty || v <= 0) return;
          genreCounts[k] = (genreCounts[k] ?? 0) + v;
        });
      } catch (_) {}
      final genreTotal =
          genreCounts.values.fold(0.0, (sum, v) => sum + v);
      genreDistribution = genreTotal > 0
          ? (genreCounts.entries
                  .map((e) => _GenreStat(e.key, e.value / genreTotal * 100))
                  .toList()
                ..sort((a, b) => b.percentage.compareTo(a.percentage)))
              .take(5)
              .toList()
          : [];

      // --- Артисты: аналитика (listenCount) + ML-рейтинги (playCount) ---
      final artistScores = <String, int>{};
      final artistNames = <String, String>{};
      for (final a in analytics.getTopArtists(limit: 1000)) {
        final key = a.artistName.trim().isNotEmpty
            ? a.artistName.trim()
            : a.artistId;
        artistScores[key] = (artistScores[key] ?? 0) + a.listenCount;
        artistNames[key] = a.artistName;
      }
      for (final r in mlRatings.values) {
        final name = (r.artist ?? '').trim();
        if (name.isEmpty) continue;
        artistScores[name] = (artistScores[name] ?? 0) + r.playCount;
        artistNames[name] = name;
      }

      topArtists = (artistScores.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value)))
          .take(10)
          .map((e) => _ArtistStat(artistNames[e.key] ?? e.key, e.value))
          .toList();

      // --- Активность: реальная теплокарта 12 недель × 7 дней ---
      weeklyActivity = _buildWeeklyActivity(history);

      _rebuildAchievements(
        artistCount: artistScores.length,
        nightPlays: history
            .where((e) => e.timestamp.hour < 5)
            .length,
      );
    } catch (e) {
      totalTracks = 0;
      totalMinutes = 0;
      genreDistribution = [];
      topArtists = [];
      weeklyActivity = [];
      achievements = [];
    }

    isLoading = false;
    notifyListeners();
  }

  /// Best-effort слой мозга поверх локальной статистики.
  /// Парсит wrapped/profile дефенсивно (не знаем точную схему сервера) —
  /// при любой несовместимости локальные данные остаются как были.
  Future<void> loadBrainStats(
      KumaFlowBrainClient client, String userId) async {
    try {
      Map<String, dynamic>? wrapped;
      Map<String, dynamic>? profile;
      try {
        wrapped = await client
            .getWrapped(userId)
            .timeout(const Duration(seconds: 10));
      } catch (_) {}
      try {
        profile = await client
            .getProfile(userId)
            .timeout(const Duration(seconds: 10));
      } catch (_) {}
      if (wrapped == null && profile == null) return;

      var changed = false;

      // --- Жанры мозга ---
      final brainGenres = _parseBrainGenres(wrapped, profile);
      if (brainGenres.isNotEmpty) {
        final total =
            brainGenres.values.fold(0.0, (s, v) => s + v);
        if (total > 0) {
          genreDistribution = (brainGenres.entries
                  .map((e) => _GenreStat(e.key, e.value / total * 100))
                  .toList()
                ..sort((a, b) => b.percentage.compareTo(a.percentage)))
              .take(5)
              .toList();
          changed = true;
        }
      }

      // --- Артисты мозга ---
      final brainArtists = _parseBrainArtists(wrapped, profile);
      if (brainArtists.isNotEmpty) {
        // Мержим с локальными: мозг знает серверную историю целиком.
        final merged = <String, _ArtistStat>{};
        for (final a in topArtists) {
          merged[a.name.toLowerCase()] = a;
        }
        for (final e in brainArtists.entries) {
          final key = e.key.toLowerCase();
          final local = merged[key];
          if (local == null) {
            merged[key] = _ArtistStat(e.key, e.value);
          } else if (e.value > local.playCount) {
            merged[key] =
                _ArtistStat(local.name, e.value, coverArtId: local.coverArtId);
          }
        }
        final sorted = merged.values.toList()
          ..sort((a, b) => b.playCount.compareTo(a.playCount));
        topArtists = sorted.take(10).toList();
        changed = true;
      }

      // --- Время/треки мозга ---
      final brainTotals = _parseBrainTotals(wrapped, profile);
      final bTracks = brainTotals['tracks'] ?? 0;
      final bMinutes = brainTotals['minutes'] ?? 0;
      if (bTracks > totalTracks) {
        totalTracks = bTracks;
        changed = true;
      }
      if (bMinutes > totalMinutes) {
        totalMinutes = bMinutes;
        changed = true;
      }

      if (changed) {
        brainMerged = true;
        _rebuildAchievements(
          artistCount: topArtists.length,
          nightPlays: 0,
        );
        notifyListeners();
      }
    } catch (_) {
      // Тихий best-effort: локальная статистика уже показана.
    }
  }

  // ---------- helpers ----------

  void _rebuildAchievements({required int artistCount, required int nightPlays}) {
    achievements = [
      _Achievement(
        name: 'Первое прослушивание',
        description: 'Прослушайте свой первый трек',
        icon: Icons.headphones,
        unlocked: totalTracks > 0,
      ),
      _Achievement(
        name: 'Исследователь жанров',
        description: 'Прослушайте 5 разных жанров',
        icon: Icons.explore,
        unlocked: genreDistribution.length >= 5,
        progress: (genreDistribution.length / 5).clamp(0.0, 1.0),
      ),
      _Achievement(
        name: 'Ночная сова',
        description: 'Слушайте после полуночи 10 раз',
        icon: Icons.nightlight_round,
        unlocked: nightPlays >= 10,
        progress: (nightPlays / 10).clamp(0.0, 1.0),
      ),
      _Achievement(
        name: 'Клуб 100',
        description: 'Прослушайте 100 разных артистов',
        icon: Icons.stars,
        unlocked: artistCount >= 100,
        progress: (artistCount / 100).clamp(0.0, 1.0),
      ),
      _Achievement(
        name: 'Меломан',
        description: 'Прослушайте 1000 треков',
        icon: Icons.library_music,
        unlocked: totalTracks >= 1000,
        progress: (totalTracks / 1000).clamp(0.0, 1.0),
      ),
    ];
  }

  /// 12 колонок (недели) × 7 строк (дни нед). Интенсивность 0..1
  /// нормирована на макс. дневное число прослушиваний.
  List<List<double>> _buildWeeklyActivity(List<ListeningEvent> history) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // buckets[week][weekday]: week 0 = 11 недель назад, week 11 = текущая.
    final buckets =
        List.generate(12, (_) => List.filled(7, 0));
    for (final e in history) {
      final d = DateTime(
          e.timestamp.year, e.timestamp.month, e.timestamp.day);
      final diff = today.difference(d).inDays;
      if (diff < 0 || diff >= 84) continue;
      final week = 11 - (diff ~/ 7);
      final weekday = (e.timestamp.weekday - 1).clamp(0, 6);
      buckets[week][weekday]++;
    }
    int maxCount = 0;
    for (final w in buckets) {
      for (final c in w) {
        if (c > maxCount) maxCount = c;
      }
    }
    if (maxCount == 0) {
      return List.generate(12, (_) => List.filled(7, 0.0));
    }
    return buckets
        .map((w) => w.map((c) => c / maxCount).toList())
        .toList();
  }

  Map<String, double> _parseBrainGenres(
      Map<String, dynamic>? wrapped, Map<String, dynamic>? profile) {
    const keys = [
      'top_genres',
      'topGenres',
      'genres',
      'genre_distribution',
      'genreDistribution',
      'favorite_genres',
      'favourite_genres',
    ];
    for (final src in [wrapped, profile]) {
      if (src == null) continue;
      // Вложенные контейнеры вида {stats: {...}} / {data: {...}}.
      final candidates = <Map<String, dynamic>>[src];
      for (final nk in ['stats', 'data', 'profile', 'taste']) {
        final nested = src[nk];
        if (nested is Map) {
          candidates.add(Map<String, dynamic>.from(nested));
        }
      }
      for (final c in candidates) {
        for (final k in keys) {
          final v = c[k];
          final parsed = _parseNameCountList(v);
          if (parsed.isNotEmpty) return parsed;
        }
      }
    }
    return {};
  }

  Map<String, int> _parseBrainArtists(
      Map<String, dynamic>? wrapped, Map<String, dynamic>? profile) {
    const keys = [
      'top_artists',
      'topArtists',
      'artists',
      'artist_distribution',
      'favorite_artists',
    ];
    for (final src in [wrapped, profile]) {
      if (src == null) continue;
      final candidates = <Map<String, dynamic>>[src];
      for (final nk in ['stats', 'data', 'profile', 'taste']) {
        final nested = src[nk];
        if (nested is Map) {
          candidates.add(Map<String, dynamic>.from(nested));
        }
      }
      for (final c in candidates) {
        for (final k in keys) {
          final v = c[k];
          final parsed = _parseNameCountList(v);
          if (parsed.isNotEmpty) {
            return parsed.map((key, value) => MapEntry(key, value.toInt()));
          }
        }
      }
    }
    return {};
  }

  /// Принимает и список [{name,count}|{genre,plays}|...], и карту {name: count}.
  Map<String, double> _parseNameCountList(dynamic v) {
    final out = <String, double>{};
    if (v is Map) {
      v.forEach((k, val) {
        final name = k.toString().trim();
        final n = val is num
            ? val.toDouble()
            : double.tryParse(val.toString()) ?? 0;
        if (name.isNotEmpty && n > 0) out[name] = n;
      });
      return out;
    }
    if (v is! List) return out;
    for (final item in v) {
      if (item is Map) {
        final m = Map<String, dynamic>.from(item);
        final name = (m['name'] ??
                m['genre'] ??
                m['artist'] ??
                m['artist_name'] ??
                m['title'] ??
                '')
            .toString()
            .trim();
        final raw = m['count'] ??
            m['plays'] ??
            m['play_count'] ??
            m['plays_count'] ??
            m['value'] ??
            m['weight'] ??
            m['score'] ??
            0;
        final n = raw is num
            ? raw.toDouble()
            : double.tryParse(raw.toString()) ?? 0;
        if (name.isNotEmpty && n > 0) out[name] = n;
      } else if (item is String && item.trim().isNotEmpty) {
        out[item.trim()] = (out[item.trim()] ?? 0) + 1;
      }
    }
    return out;
  }

  Map<String, int> _parseBrainTotals(
      Map<String, dynamic>? wrapped, Map<String, dynamic>? profile) {
    int tracks = 0;
    int minutes = 0;
    final all = <Map<String, dynamic>>[];
    for (final src in [wrapped, profile]) {
      if (src == null) continue;
      all.add(src);
      for (final nk in ['stats', 'data', 'profile']) {
        final nested = src[nk];
        if (nested is Map) all.add(Map<String, dynamic>.from(nested));
      }
    }
    int asInt(dynamic v) =>
        v is num ? v.toInt() : int.tryParse(v.toString()) ?? 0;
    for (final m in all) {
      for (final k in [
        'total_tracks',
        'totalTracks',
        'total_plays',
        'totalPlays',
        'plays',
        'track_count'
      ]) {
        if (m[k] != null) tracks = math.max(tracks, asInt(m[k]));
      }
      for (final k in [
        'total_minutes',
        'totalMinutes',
        'minutes',
        'listening_minutes'
      ]) {
        if (m[k] != null) minutes = math.max(minutes, asInt(m[k]));
      }
      for (final k in [
        'total_seconds',
        'totalSeconds',
        'listening_seconds',
        'total_duration_sec'
      ]) {
        if (m[k] != null) minutes = math.max(minutes, asInt(m[k]) ~/ 60);
      }
      for (final k in [
        'total_duration_ms',
        'totalDurationMs',
        'listening_ms'
      ]) {
        if (m[k] != null) minutes = math.max(minutes, asInt(m[k]) ~/ 60000);
      }
    }
    return {'tracks': tracks, 'minutes': minutes};
  }
}

// -- Custom Painters --

class _PieChartPainter extends CustomPainter {
  final List<_GenreStat> data;
  final List<Color> colors;
  final bool isDark;

  _PieChartPainter({
    required this.data,
    required this.colors,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 10;
    double startAngle = -math.pi / 2;

    for (int i = 0; i < data.length; i++) {
      final sweepAngle = (data[i].percentage / 100) * 2 * math.pi;
      final paint = Paint()
        ..color = colors[i % colors.length]
        ..style = PaintingStyle.fill;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        true,
        paint,
      );

      startAngle += sweepAngle;
    }

    // Inner circle for donut effect
    final innerPaint = Paint()
      ..color = isDark ? AppTheme.darkCard : AppTheme.lightCard
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius * 0.55, innerPaint);

    // Center text
    final totalPercent = data.fold(0.0, (sum, d) => sum + d.percentage);
    final textPainter = TextPainter(
      text: TextSpan(
        text: '${totalPercent.toInt()}%',
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: isDark ? Colors.white : Colors.black,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      center - Offset(textPainter.width / 2, textPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(_PieChartPainter oldDelegate) => false;
}

class _HeatmapPainter extends CustomPainter {
  final List<List<double>> data;
  final bool isDark;
  final Color accent;

  _HeatmapPainter({required this.data, required this.isDark, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    const daysInWeek = 7;
    const weeks = 12;
    final cellWidth = (size.width - 30) / weeks;
    final cellHeight = (size.height - 20) / daysInWeek;
    final gap = 2.0;

    final dayLabels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final labelStyle = TextStyle(
      fontSize: 9,
      color: isDark ? AppTheme.darkTertiaryText : AppTheme.lightSecondaryText,
    );

    for (int day = 0; day < daysInWeek; day++) {
      final tp = TextPainter(
        text: TextSpan(text: dayLabels[day], style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(0, day * cellHeight + (cellHeight - tp.height) / 2 + 10),
      );
    }

    for (int week = 0; week < data.length && week < weeks; week++) {
      for (int day = 0; day < data[week].length && day < daysInWeek; day++) {
        final intensity = data[week][day];
        final color = _heatmapColor(intensity, isDark);

        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(
            18 + week * (cellWidth),
            day * (cellHeight) + 10,
            cellWidth - gap,
            cellHeight - gap,
          ),
          const Radius.circular(3),
        );

        final paint = Paint()..color = color;
        canvas.drawRRect(rect, paint);
      }
    }
  }

  Color _heatmapColor(double intensity, bool isDark) {
    if (intensity < 0.2) {
      return isDark ? const Color(0xFF1A1A1A) : const Color(0xFFE8E8E8);
    } else if (intensity < 0.4) {
      return accent.withAlpha(60);
    } else if (intensity < 0.6) {
      return accent.withAlpha(100);
    } else if (intensity < 0.8) {
      return accent.withAlpha(160);
    }
    return accent;
  }

  @override
  bool shouldRepaint(_HeatmapPainter oldDelegate) => false;
}
