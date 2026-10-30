import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/theme_service.dart';
import '../widgets/app_gradient_background.dart';
import '../providers/library_provider.dart';
import '../services/ml_service.dart';
import '../services/kumaflow_brain/kumaflow_brain_bridge.dart';
import 'settings_screen.dart';
import '../services/yandex_enrichment_service.dart';
import '../services/offline_service.dart';
import '../services/brain_mood_enrichment_service.dart';
import '../widgets/album_artwork.dart';
import '../theme/app_theme.dart';
import 'cold_start_onboarding_screen.dart';

class SettingsMlTab extends StatefulWidget {
  const SettingsMlTab({super.key});

  @override
  State<SettingsMlTab> createState() => _SettingsMlTabState();
}

class _SettingsMlTabState extends State<SettingsMlTab> {
  bool _enrichLoading = false;

  @override
  Widget build(BuildContext context) {
    final mlService = Provider.of<MLService>(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Подключение мозга живёт во вкладке «Интеграции» — здесь ссылка.
        _SectionCard(
          isDark: isDark,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.psychology_rounded,
                color: Color(0xFFAF52DE)),
            title: const Text('KumaFlow Brain: подключение'),
            subtitle: const Text('URL, токен, волна — во вкладке «Интеграции»',
                style: TextStyle(fontSize: 11)),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const SettingsScreen(initialTab: 6),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // ML Profile Overview
        _SectionCard(
          isDark: isDark,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.auto_awesome,
                    color: AppTheme.appleMusicRed,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'ML Профиль',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _StatRow(
                label: 'Всего оценок',
                value: mlService.ratings.length.toString(),
                isDark: isDark,
              ),
              _StatRow(
                label: 'Лайков',
                value: mlService.profile.likedSongs.length.toString(),
                isDark: isDark,
              ),
              _StatRow(
                label: 'Дизлайков',
                value: mlService.profile.dislikedSongs.length.toString(),
                isDark: isDark,
              ),
              _StatRow(
                label: 'Забаненных артистов',
                value: mlService.profile.bannedArtists.length.toString(),
                isDark: isDark,
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Yandex Enrichment metrics
        _YandexEnrichmentCard(
          isDark: isDark,
          enrichLoading: _enrichLoading,
          onEnrich: () async {
            setState(() => _enrichLoading = true);
            final lib = Provider.of<LibraryProvider>(context, listen: false);
            final svc = YandexEnrichmentService();
            final count = await svc.enrichBatch(lib.cachedAllSongs, limit: 40);
            if (mounted) {
              setState(() => _enrichLoading = false);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Обогащено: $count треков (без токена)')));
            }
          },
          onClear: () async {
            await YandexEnrichmentService().clear();
            if (mounted) {
              setState(() {});
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Кэш ЯМ очищен')));
            }
          },
        ),

        const SizedBox(height: 16),

        // Офлайн-волна из скачанного + настроения с мозга
        _OfflineWaveCard(isDark: isDark),

        const SizedBox(height: 16),

        // Top Artists
        if (mlService.profile.preferredArtists.isNotEmpty) ...[
          _SectionCard(
            isDark: isDark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Топ артисты',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                ...mlService.getTopArtists(limit: 10).map((artist) {
                  final weight = mlService.profile.preferredArtists[artist] ?? 0;
                  final name = mlService.displayNameForArtist(artist);
                  // Обложка: первый трек этого артиста из кэша библиотеки.
                  String? coverId;
                  try {
                    final lib = Provider.of<LibraryProvider>(context, listen: false);
                    for (final s in lib.cachedAllSongs) {
                      if (s.artistId == artist || s.artist == artist) {
                        if (s.coverArt != null && s.coverArt!.isNotEmpty) {
                          coverId = s.coverArt;
                          break;
                        }
                      }
                    }
                    // Имя тоже можно добрать из библиотеки для старых id-ключей.
                    if ((mlService.profile.preferredArtistNames[artist] == null ||
                            mlService.profile.preferredArtistNames[artist]!.isEmpty)) {
                      for (final s in lib.cachedAllSongs) {
                        if (s.artistId == artist && (s.artist?.isNotEmpty ?? false)) {
                          mlService.rememberArtistName(artist, s.artist);
                          break;
                        }
                      }
                    }
                  } catch (_) {}
                  final display = mlService.displayNameForArtist(artist);
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: coverId != null
                        ? ClipOval(
                            child: SizedBox(
                              width: 40,
                              height: 40,
                              child: AlbumArtwork(
                                coverArt: coverId,
                                size: 40,
                              ),
                            ),
                          )
                        : CircleAvatar(
                            backgroundColor: AppTheme.appleMusicRed.withValues(alpha: 0.2),
                            child: Text(
                              display.isNotEmpty ? display[0].toUpperCase() : '?',
                              style: const TextStyle(color: AppTheme.appleMusicRed),
                            ),
                          ),
                    title: Text(name),
                    subtitle: name != artist
                        ? Text(artist,
                            style: TextStyle(
                              fontSize: 10,
                              color: isDark ? Colors.white38 : Colors.black38,
                            ))
                        : null,
                    trailing: Text(
                      weight.toStringAsFixed(1),
                      style: TextStyle(
                        color: isDark ? Colors.white54 : Colors.black54,
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        // Top Genres
        if (mlService.profile.preferredGenres.isNotEmpty) ...[
          _SectionCard(
            isDark: isDark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Топ жанры',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                ...mlService.getTopGenres(limit: 10).map((genre) {
                  final weight = mlService.profile.preferredGenres[genre] ?? 0;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.library_music_rounded,
                      color: AppTheme.appleMusicRed,
                    ),
                    title: Text(genre),
                    trailing: Text(
                      weight.toStringAsFixed(1),
                      style: TextStyle(
                        color: isDark ? Colors.white54 : Colors.black54,
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        // Disliked Songs
        if (mlService.profile.dislikedSongs.isNotEmpty) ...[
          _SectionCard(
            isDark: isDark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Дизлайкнутые треки',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${mlService.profile.dislikedSongs.length}',
                      style: TextStyle(
                        color: AppTheme.appleMusicRed,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Эти треки исключены из рекомендаций',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        // Reset ML Profile
        _SectionCard(
          isDark: isDark,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Управление',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.auto_awesome,
                  color: AppTheme.loginAccent,
                ),
                title: const Text('Обучить / дообучить вкус'),
                subtitle: const Text(
                  'Выбрать жанры и артистов для улучшения рекомендаций',
                  style: TextStyle(fontSize: 12),
                ),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const ColdStartOnboardingScreen(),
                    ),
                  );
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.refresh_rounded,
                  color: AppTheme.appleMusicRed,
                ),
                title: const Text('Сбросить ML профиль'),
                subtitle: const Text(
                  'Удалить все оценки и начать заново',
                  style: TextStyle(fontSize: 12),
                ),
                onTap: () => _showResetDialog(context, mlService),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.info_outline,
                  color: isDark ? Colors.white70 : Colors.black54,
                ),
                title: const Text('О ML системе'),
                subtitle: const Text(
                  'Как работает обучение',
                  style: TextStyle(fontSize: 12),
                ),
                onTap: () => _showInfoDialog(context),
              ),
            ],
          ),
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  void _showResetDialog(BuildContext context, MLService mlService) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Сбросить ML профиль?'),
        content: const Text(
          'Все ваши оценки, лайки, дизлайки и предпочтения будут удалены. '
          'Это действие необратимо.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () async {
              // Reset the profile
              Navigator.pop(ctx);
              await mlService.resetEverything();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('ML профиль сброшен')),
                );
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Сбросить'),
          ),
        ],
      ),
    );
  }

  void _showInfoDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Как работает ML'),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'KumaFlow изучает ваши предпочтения:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              Text('• Лайки увеличивают вес артистов и жанров'),
              Text('• Дизлайки уменьшают вес артистов и жанров'),
              Text('• 3+ скипа подряд = авто-дизлайк'),
              Text('• Повторные прослушивания дают +50 к весу'),
              Text('• Чем дольше слушаете, тем выше вес'),
              SizedBox(height: 12),
              Text(
                'На основе этого KumaFlow генерирует:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              Text('• Миксы по жанрам и артистам'),
              Text('• Плейлист дня'),
              Text('• Похожие треки'),
              Text('• Радио артистов'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Понятно'),
          ),
        ],
      ),
    );
  }
}

class _YandexEnrichmentCard extends StatelessWidget {
  final bool isDark;
  final bool enrichLoading;
  final Future<void> Function() onEnrich;
  final Future<void> Function() onClear;
  const _YandexEnrichmentCard({required this.isDark, required this.enrichLoading, required this.onEnrich, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final svc = YandexEnrichmentService();
    final lib = Provider.of<LibraryProvider>(context, listen: false);
    // Было: статистика по 80к кэшу в RAM. Стало: COUNT(*) из SQL.
    final statsFuture = lib.getLibraryStats();
    final cachedCount = svc.cachedCount;
    final songEntries = svc.songEntries;
    final artistEntries = svc.artistEntries;
    final hist = svc.genreHistogram();
    final topHist = (hist.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(5).toList();

    return _SectionCard(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_sync_rounded, color: AppTheme.appleMusicRed, size: 22),
              const SizedBox(width: 10),
              const Text('Yandex обогащение', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const Spacer(),
              if (enrichLoading) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 6),
          Text('Без токена — публичные жанры/похожие из ЯМ для локальных файлов', style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black54)),
          const SizedBox(height: 12),
          _StatRow(label: 'Кэш: треков', value: '$songEntries', isDark: isDark),
          _StatRow(label: 'Кэш: артистов', value: '$artistEntries', isDark: isDark),
          _StatRow(label: 'Всего в кэше', value: '$cachedCount', isDark: isDark),
          FutureBuilder<Map<String, int>>(
            future: statsFuture,
            builder: (ctx, snap) {
              final total = snap.data?['total'] ?? 0;
              final withGenre = snap.data?['withGenre'] ?? 0;
              final coverage = total > 0 ? (withGenre / total * 100).toStringAsFixed(1) : '0';
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _StatRow(label: 'Треков в библиотеке', value: '$total', isDark: isDark),
                  _StatRow(label: 'Покрытие жанрами', value: '$withGenre/$total ($coverage%)', isDark: isDark),
                ],
              );
            },
          ),
          if (topHist.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Топ из ЯМ:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? Colors.white70 : Colors.black54)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: topHist.map((e) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: const Color(0xFFFFCC00).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                    child: Text('${e.key} ${e.value}', style: const TextStyle(fontSize: 11)),
                  )).toList(),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: enrichLoading ? null : onEnrich,
                  icon: const Icon(Icons.auto_fix_high_rounded, size: 16),
                  label: Text(enrichLoading ? '...' : 'Обогатить 40 треков'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: onClear,
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: 'Очистить кэш ЯМ',
              ),
            ],
          ),
          Text('Триггер: авто при импорте библиотеки + при открытии Главной (фон)', style: TextStyle(fontSize: 10, color: isDark ? Colors.white38 : Colors.black38)),
        ],
      ),
    );
  }
}

/// Офлайн-волна из скачанного + настроения с мозга.
///
/// Тумблер: тап «Скачанное» — ML-волна (generateLocalMyWave, знает лайки
/// и дозагруженные настроения) или старый голый шаффл.
/// Кнопка: дотянуть настроения скачанных с мозга (source='brain').
/// Всё умно: прогон ≤150 треков, сеть пачками по 5 с паузами,
/// память O(пачка), UI не блокируется (прогресс по пачкам).
class _OfflineWaveCard extends StatefulWidget {
  final bool isDark;
  const _OfflineWaveCard({required this.isDark});

  @override
  State<_OfflineWaveCard> createState() => _OfflineWaveCardState();
}

class _OfflineWaveCardState extends State<_OfflineWaveCard> {
  bool _enriching = false;
  int _done = 0;
  int _total = 0;
  String? _status;
  int _enrichedTotal = 0;
  DateTime? _lastRun;

  @override
  void initState() {
    super.initState();
    _refreshMeta();
  }

  Future<void> _refreshMeta() async {
    try {
      final svc = BrainMoodEnrichmentService();
      // Честный счётчик — сколько песен реально имеют mood в БД.
      final c = await svc.moodsInDb();
      final last = await svc.lastRun();
      if (!mounted) return;
      setState(() {
        _enrichedTotal = c;
        _lastRun = last;
      });
    } catch (_) {}
  }

  Future<void> _runEnrich() async {
    if (_enriching) return;
    final bridge =
        Provider.of<KumaFlowBrainBridge>(context, listen: false);
    final client = bridge.client;
    if (client == null || bridge.isOfflineNow) {
      setState(() => _status = 'Мозг недоступен (выкл/нет URL/офлайн).');
      return;
    }
    // Раньше гнали только скачанные (69) — из 1700 библиотеки это вводило
    // в заблуждение. Теперь гоним всю библиотеку (скачанные в приоритете).
    Set<String> ids;
    try {
      final lib = Provider.of<LibraryProvider>(context, listen: false);
      final all = lib.cachedAllSongs.map((s) => s.id).where((id) => !id.startsWith('local_')).toSet();
      final down = OfflineService().getDownloadedSongIds().where((id) => !id.startsWith('local_')).toSet();
      ids = {...down, ...all};
    } catch (_) {
      ids = OfflineService().getDownloadedSongIds();
    }
    ids.removeWhere((id) => id.startsWith('local_'));
    if (ids.isEmpty) {
      setState(() => _status = 'Треков для обогащения нет.');
      return;
    }
    setState(() {
      _enriching = true;
      _done = 0;
      _total = 0;
      _status = 'Тянем настроения: ${ids.length} треков…';
    });
    try {
      final r = await BrainMoodEnrichmentService().enrichDownloadedDetailed(
        client: client,
        downloadedIds: ids,
        maxTracks: 500,
        onProgress: (d, t) {
          if (!mounted) return;
          setState(() {
            _done = d;
            _total = t;
          });
        },
      );
      if (!mounted) return;
      final dbCount = await BrainMoodEnrichmentService().moodsInDb();
      setState(() => _status = (r.moods > 0 || r.enriched > 0)
          ? 'Готово: настроений ${r.moods} (всего в БД $dbCount), фич ${r.enriched} из ${r.total}. Повтори для остатка.'
          : 'Нового нет — остаток либо уже с настроениями, либо без данных на мозге (кулдаун 7 дней). В БД настроений: $dbCount.');
      await _refreshMeta();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _enriching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final sub = TextStyle(
        fontSize: 11, color: isDark ? Colors.white54 : Colors.black54);
    return _SectionCard(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.waves_rounded,
                  color: Color(0xFF007AFF), size: 22),
              SizedBox(width: 10),
              Text('Офлайн-волна и настроения',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 4),
          Consumer<MLService>(
            builder: (ctx, ml, _) => SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('ML-волна из скачанного',
                  style: TextStyle(fontSize: 14)),
              subtitle: Text(
                  ml.downloadedMlWave
                      ? 'Тап «Скачанное» — умная волна (лайки + настроения)'
                      : 'Тап «Скачанное» — простой шаффл как раньше',
                  style: sub),
              value: ml.downloadedMlWave,
              onChanged: (v) => ml.setDownloadedMlWave(v),
            ),
          ),
          Text(
              'В офлайне плеер и так берёт только скачанное; тумблер решает КАК: ML-подбор или шаффл.',
              style: sub),
          const SizedBox(height: 12),
          _StatRow(
              label: 'Настроений с мозга',
              value: '$_enrichedTotal',
              isDark: isDark),
          if (_lastRun != null)
            _StatRow(
                label: 'Последняя подтяжка',
                value:
                    '${_lastRun!.day}.${_lastRun!.month} ${_lastRun!.hour}:${_lastRun!.minute.toString().padLeft(2, '0')}',
                isDark: isDark),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _enriching ? null : _runEnrich,
              icon: const Icon(Icons.mood_rounded, size: 16),
              label: Text(_enriching
                  ? 'Тянем… $_done/$_total'
                  : 'Подтянуть настроения с мозга'),
            ),
          ),
          if (_enriching)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(
                  value: _total > 0 ? _done / _total : null),
            ),
          if (_status != null) ...[
            const SizedBox(height: 6),
            Text(_status!,
                style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white70 : Colors.black87)),
          ],
          Text('Умно: ≤500/прогон, пачки по 5, паузы 200мс — без ANR/OOM. Пустые без данных пропускаем на 7 дней.',
              style: TextStyle(
                  fontSize: 10,
                  color: isDark ? Colors.white38 : Colors.black38)),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final Widget child;
  final bool isDark;

  const _SectionCard({required this.child, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isDark;

  const _StatRow({
    required this.label,
    required this.value,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: isDark ? Colors.white70 : Colors.black54,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}


