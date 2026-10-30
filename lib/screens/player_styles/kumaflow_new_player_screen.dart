import 'dart:io';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../main.dart' show navigatorKey;
import '../../models/artist_ref.dart';
import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../providers/auth_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../screens/artist_screen.dart';
import '../car_mode_screen.dart';
import '../equalizer_screen.dart';
import '../../widgets/cast_device_picker.dart';
import '../../services/audiobookshelf_service.dart';
import '../../services/kumaflow_brain/kumaflow_brain_bridge.dart';
import '../../services/kumaflow_brain/kumaflow_brain_playback.dart';
import '../../services/offline_service.dart';
import '../../services/safe_image_cache_manager.dart';
import '../../services/subsonic_service.dart';
import '../../services/wave_identity.dart';
import '../../theme/app_theme.dart';
import '../../utils/navigation_helper.dart';
import '../../widgets/album_artwork.dart'
    show AlbumArtwork, isLocalFilePath;
import '../../widgets/star_rating_widget.dart';
import '../../widgets/synced_lyrics_view.dart';

/// KumaFlowNew — порт десктопного fullscreen-плеера
/// (C:\kumaflow-release\src\app\components\fullscreen\):
/// - page.tsx: Drawer + backdrop-blur + правая панель 360-400px
/// - now-playing.tsx: CoverColumn (обложка + инфо + бейджи) + ContextPanel
///   ("Сейчас играет / Моя коллекция", текущий трек, "Далее в очереди")
/// - progress.tsx: тонкий slim-прогресс снизу
///
/// Мобильная адаптация:
/// - вертикаль: колонка (обложка → инфо → кнопки вынесены из оверлея:
///   дизлайк | назад | плей/пауза | дальше | лайк — как у дефолта)
/// - горизонталь/планшет (width>=700 или landscape): две колонки как на
///   десктопе — слева обложка+управление, справа ContextPanel инлайн
/// - свайп горизонтальный по обложке: prev/next
/// - свайп вниз: закрыть; свайп вверх: очередь снизу-вверх с анимацией
class KumaflowNewPlayerScreen extends StatefulWidget {
  const KumaflowNewPlayerScreen({super.key});

  @override
  State<KumaflowNewPlayerScreen> createState() =>
      _KumaflowNewPlayerScreenState();
}

class _KumaflowNewPlayerScreenState extends State<KumaflowNewPlayerScreen> {
  double _hDrag = 0;
  double _vDrag = 0;
  // Порог поднят: 70px срабатывал от дрожания пальца при тапе,
  // ложный skipNext -> 3 скипа = авто-дизлайк/бан артиста.
  static const double _swipeThreshold = 120;
  static const double _closeThreshold = 140;
  DateTime _lastCoverSwipeAt = DateTime.fromMillisecondsSinceEpoch(0);
  // Кэш разрешённых обложек артистов (имя -> http-URL картинки или null).
  final Map<String, Future<String?>> _artistArtCache = {};
  // Прекеш соседних обложек: переключение без спиннера.
  final Set<String> _precachedUrls = {};
  String _precacheKey = '';
  // Таб правой панели в горизонтальном режиме: очередь или текст
  // (как десктопные панели context/lyrics, переключаются без шторок).
  String _widePanel = 'queue';

  String _coverUrl(Song? s, SubsonicService svc, int size) {
    if (s?.coverArt == null) return '';
    final ca = s!.coverArt!;
    if (ca.startsWith('http')) return ca;
    if (isLocalFilePath(ca)) return ca;
    if (ca.startsWith('abs:')) {
      return AudiobookshelfService().getCoverUrl(ca.substring(4), width: size);
    }
    return svc.getCoverArtUrl(ca, size: size);
  }

  /// Греем кэш картинок текущей и соседних: следующий трек открывается сразу.
  /// Только http (локальные и так мгновенные), один пост-кадр на смену трека.
  void _precacheNeighbors(PlayerProvider p, SubsonicService svc) {
    final q = p.queue;
    final idx = q.isEmpty
        ? -1
        : p.currentIndex.clamp(0, q.length - 1).toInt();
    final ids = <String>[
      if (idx > 0) q[idx - 1].id,
      if (idx >= 0) q[idx].id,
      if (idx >= 0 && idx + 1 < q.length) q[idx + 1].id,
    ];
    final key = ids.join('|');
    if (key.isEmpty || key == _precacheKey) return;
    _precacheKey = key;
    final urls = <String>{};
    if (idx > 0) urls.add(_coverUrl(q[idx - 1], svc, 600));
    if (idx >= 0) urls.add(_coverUrl(q[idx], svc, 600));
    if (idx >= 0 && idx + 1 < q.length) {
      urls.add(_coverUrl(q[idx + 1], svc, 600));
    }
    final fresh =
        urls.where((u) => u.startsWith('http') && !_precachedUrls.contains(u));
    if (fresh.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = context;
      for (final u in fresh) {
        _precachedUrls.add(u);
        try {
          precacheImage(CachedNetworkImageProvider(u), ctx);
        } catch (_) {}
      }
      if (_precachedUrls.length > 60) _precachedUrls.clear();
    });
  }

  Widget _art(String url, {BoxFit fit = BoxFit.cover, int cacheSize = 600}) {
    if (url.isEmpty) return _placeholder();
    if (isLocalFilePath(url)) {
      return Image.file(File(url),
          fit: fit,
          cacheWidth: cacheSize,
          errorBuilder: (_, __, ___) => _placeholder());
    }
    // Офлайн-приоритет: скачанная cover_*.jpg вместо сетевого URL.
    try {
      final off = OfflineService().getLocalCoverForSong(trackId: url);
      if (off != null) {
        return Image.file(File(off),
            fit: fit,
            cacheWidth: cacheSize,
            errorBuilder: (_, __, ___) => _placeholder());
      }
    } catch (_) {}
    final headers = url.contains('audiobookshelf')
        ? AudiobookshelfService().authHeaders
        : <String, String>{};
    return CachedNetworkImage(
      key: ValueKey('knew_${url.hashCode}_$cacheSize'),
      imageUrl: url,
      httpHeaders: headers,
      cacheManager: SafeImageCacheManager.instance,
      cacheKey: 'knew_${url.hashCode}_$cacheSize',
      fit: fit,
      memCacheWidth: cacheSize,
      maxWidthDiskCache: cacheSize,
      maxHeightDiskCache: cacheSize,
      useOldImageOnUrlChange: true,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      progressIndicatorBuilder: (_, __, progress) => Stack(
        fit: StackFit.expand,
        children: [
          _placeholder(dimIcon: true),
          Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                value: progress.progress,
                strokeWidth: 2.5,
                color: Colors.white70,
              ),
            ),
          ),
        ],
      ),
      errorWidget: (_, __, ___) => _placeholder(),
    );
  }

  /// Плейсхолдер обложки: тёмный сине-серый градиент + нота,
  /// а не плоский серый квадрат.
  Widget _placeholder({bool dimIcon = false}) => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF334155), Color(0xFF1E293B)],
          ),
        ),
        child: Center(
          child: Icon(Icons.music_note_rounded,
              size: 72,
              color: Colors.white.withValues(
                  alpha: dimIcon ? 0.12 : 0.22)),
        ),
      );

  /// Фон экрана: блюр обложки + затемнение; без обложки —
  /// глубокий градиент с едва заметной нотой, а не чёрная плашка.
  Widget _backdrop(String url) {
    if (url.isEmpty) {
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1C2733), Color(0xFF0B0F14)],
          ),
        ),
        child: const Center(
          child: Icon(Icons.music_note_rounded,
              size: 200, color: Color(0x14FFFFFF)),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        _art(url),
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
          child: Container(color: Colors.black.withValues(alpha: 0.45)),
        ),
      ],
    );
  }

  String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  /// Единый путь дизлайка: dislikeAndSkip (ML + счётчик артиста + чистка
  /// очереди атомарно). Старый saveDislike+skipNext писал лишний skip
  /// и не чистил очередь — следующий skip дописывал счётчик к бану.
  Future<void> _dislike(PlayerProvider p, Song? s) async {
    if (s == null) return;
    try {
      final artistBanned = await p.dislikeAndSkip(s);
      if (artistBanned && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Артист забанен: ${s.artist ?? ''}'),
              duration: const Duration(seconds: 2)),
        );
      }
    } catch (_) {
      await p.skipNext();
    }
  }

  void _openQueue() {
    // Появление снизу-вверх с анимацией (дефолтная анимация шторки ~300мс)
    final song = context.read<PlayerProvider>().currentSong;
    final imgUrl = _coverUrl(
        song, Provider.of<SubsonicService>(context, listen: false), 800);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black54,
      builder: (_) => _QueueSheetKfn(
        onOpenLyrics: (s) => _openLyrics(s, imgUrl),
      ),
    );
  }

  void _openLyrics(Song song, String imgUrl) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        height: MediaQuery.of(context).size.height * 0.85,
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
                width: 36,
                height: 5,
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2.5))),
            const SizedBox(height: 8),
            Expanded(
              child: SyncedLyricsView(song: song, imageUrl: imgUrl),
            ),
          ],
        ),
      ),
    );
  }

  void _showAbout(Song s) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.title,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Артист: ${s.artist ?? '—'}'),
            Text('Альбом: ${s.album ?? '—'}'),
            if (s.genre != null) Text('Жанр: ${s.genre}'),
            if (s.year != null) Text('Год: ${s.year}'),
            if (s.suffix != null) Text('Формат: ${s.suffix!.toUpperCase()}'),
            if (s.bitRate != null) Text('Битрейт: ${s.bitRate} kbps'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Закрыть')),
        ],
      ),
    );
  }

  // ---------- Меню "•••": как дефолтный _showSongMenu ----------
  // Режим авто / Скачать / В плейлист / Оценка звёздами /
  // Волна по треку / Волна по артисту.
  void _openMoreMenu(Song song) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.darkSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: AppTheme.darkDivider,
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
                const SizedBox(height: 12),
                // Шапка: мини-обложка + название + закрыть
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8)),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: _art(_coverUrl(
                              song,
                              Provider.of<SubsonicService>(context,
                                  listen: false),
                              200)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(song.title,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            Text(song.artist ?? '',
                                style: const TextStyle(
                                    color: Colors.white60, fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white54),
                        onPressed: () => Navigator.pop(sheetCtx),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // Оценка звёздами (как StarRatingWidget в дефолте)
                _ratingRow(song),
                const Divider(color: AppTheme.darkDivider),
                // Режим авто — это CarMode (как в дефолтном меню)
                ListTile(
                  leading: const Icon(
                      Icons.directions_car_filled_rounded,
                      color: Colors.white),
                  title: const Text('Режим авто',
                      style: TextStyle(color: Colors.white)),
                  subtitle: const Text('Крупные кнопки для машины',
                      style:
                          TextStyle(color: Colors.white54, fontSize: 12)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CarModeScreen(),
                      ),
                    );
                  },
                ),
                // Скачать / прогресс / скачано — как в дефолте
                Builder(builder: (ctx2) {
                  final off = Provider.of<OfflineService>(ctx2);
                  final prog = off.downloadProgress[song.id];
                  final isDownloading = prog != null &&
                      !prog.isComplete &&
                      !prog.isError &&
                      prog.progress < 1.0;
                  if (isDownloading) {
                    final pct = (prog.progress * 100).toInt();
                    return ListTile(
                      leading: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                              value: prog.progress > 0 ? prog.progress : null,
                              strokeWidth: 2,
                              color: Colors.white)),
                      title: Text('Скачивание... $pct%',
                          style: const TextStyle(color: Colors.white)),
                      subtitle: LinearProgressIndicator(
                          value:
                              prog.progress > 0 ? prog.progress : null),
                    );
                  }
                  if (off.isSongDownloaded(song.id)) {
                    return ListTile(
                      leading: const Icon(Icons.download_done_rounded,
                          color: Colors.green),
                      title: const Text('Скачано',
                          style: TextStyle(color: Colors.white)),
                      onTap: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text('Удалить загрузку?'),
                            content:
                                const Text('Удалить скачанный файл?'),
                            actions: [
                              TextButton(
                                  onPressed: () =>
                                      Navigator.pop(c, false),
                                  child: const Text('Отмена')),
                              TextButton(
                                  onPressed: () => Navigator.pop(c, true),
                                  child: const Text('Удалить')),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          await off.deleteSong(song.id);
                          if (mounted) {
                            Navigator.pop(sheetCtx);
                          }
                        }
                      },
                    );
                  }
                  final isOffline =
                      Provider.of<AuthProvider>(context, listen: false)
                              .state ==
                          AuthState.offlineMode;
                  return ListTile(
                    leading: Icon(
                        isOffline
                            ? Icons.cloud_off_rounded
                            : Icons.download_rounded,
                        color: Colors.white),
                    title: const Text('Скачать',
                        style: TextStyle(color: Colors.white)),
                    onTap: () async {
                      Navigator.pop(sheetCtx);
                      final sub = Provider.of<SubsonicService>(context,
                          listen: false);
                      final ok = await off.downloadSong(song, sub);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text(ok
                                    ? 'Скачано: ${song.title}'
                                    : 'Ошибка загрузки')));
                      }
                    },
                  );
                }),
                ListTile(
                  leading: const Icon(Icons.playlist_add_rounded,
                      color: Colors.white),
                  title: const Text('Добавить в плейлист',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _openPlaylistPicker(song);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.cast_rounded,
                      color: Colors.white),
                  title: const Text('Трансляция',
                      style: TextStyle(color: Colors.white)),
                  subtitle: const Text('Chromecast / DLNA — на телевизор',
                      style:
                          TextStyle(color: Colors.white54, fontSize: 12)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    CastDevicePicker.show(context);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.waves_rounded,
                      color: Colors.white),
                  title: const Text('Волна по треку',
                      style: TextStyle(color: Colors.white)),
                  subtitle: const Text('Brain-радио от текущего трека',
                      style:
                          TextStyle(color: Colors.white54, fontSize: 12)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _playTrackWave(song);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.person_search_rounded,
                      color: Colors.white),
                  title: const Text('Волна по артисту',
                      style: TextStyle(color: Colors.white)),
                  subtitle: Text(
                      _artistNames(song).isEmpty
                          ? 'Топ треки артиста'
                          : _artistNames(song),
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _playArtistWave(song);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded,
                      color: Colors.white),
                  title: const Text('О треке',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _showAbout(song);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.equalizer_rounded,
                      color: Colors.white),
                  title: const Text('Эквалайзер',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => DraggableScrollableSheet(
                        initialChildSize: 0.7,
                        minChildSize: 0.4,
                        maxChildSize: 0.95,
                        builder: (_, scrollController) => ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(16)),
                          child: const EqualizerScreen(),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Строка оценки звёздами с живым обновлением.
  /// StatefulWidget, а не локальная переменная в builder: та сбрасывалась
  /// на song.userRating при каждом ребилде — тапы «не реагировали»
  /// (сервер оценку получал, UI стоял).
  Widget _ratingRow(Song song) => _RatingRow(song: song);

  /// Пикер плейлиста + создание нового (как в дефолте).
  Future<void> _openPlaylistPicker(Song song) async {
    final sub = Provider.of<SubsonicService>(context, listen: false);
    List<Playlist> playlists = [];
    try {
      playlists = await sub.getPlaylists();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
      return;
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.darkSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 5,
                decoration: BoxDecoration(
                  color: AppTheme.darkDivider,
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
              const SizedBox(height: 12),
              const Text('Добавить в плейлист',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFA243C),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.add_circle_rounded),
                    label: const Text('Новый плейлист'),
                    onPressed: () {
                      Navigator.pop(sheetCtx);
                      _showCreatePlaylistDialog(song);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: playlists.length,
                  itemBuilder: (_, i) {
                    final pl = playlists[i];
                    final coverUrl = pl.coverArt != null
                        ? sub.getCoverArtUrl(pl.coverArt!, size: 100)
                        : null;
                    return ListTile(
                      leading: coverUrl != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: CachedNetworkImage(
                                imageUrl: coverUrl,
                                width: 46,
                                height: 46,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) => Container(
                                    width: 46,
                                    height: 46,
                                    color: const Color(0xFF2A3542),
                                    child: const Icon(
                                        Icons.queue_music_rounded,
                                        color: Colors.white54)),
                              ),
                            )
                          : Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: const Color(0xFF2A3542),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Icon(
                                  Icons.queue_music_rounded,
                                  color: Colors.white54),
                            ),
                      title: Text(pl.name,
                          style:
                              const TextStyle(color: Colors.white)),
                      subtitle: pl.songCount != null
                          ? Text('${pl.songCount} треков',
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 12))
                          : null,
                      onTap: () async {
                        Navigator.pop(sheetCtx);
                        try {
                          await sub.updatePlaylist(
                            playlistId: pl.id,
                            songIdsToAdd: [song.id],
                          );
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text(
                                        'Добавлено в «${pl.name}»'),
                                    duration:
                                        const Duration(seconds: 1)));
                          }
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Ошибка: $e')));
                          }
                        }
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCreatePlaylistDialog(Song song) async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Новый плейлист'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration:
              const InputDecoration(hintText: 'Название плейлиста'),
          onSubmitted: (_) => Navigator.pop(c, nameCtrl.text.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Отмена')),
          TextButton(
              onPressed: () =>
                  Navigator.pop(c, nameCtrl.text.trim()),
              child: const Text('Создать')),
        ],
      ),
    );
    nameCtrl.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final sub =
          Provider.of<SubsonicService>(context, listen: false);
      await sub.createPlaylist(name: name, songIds: [song.id]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Плейлист «$name» создан'),
            duration: const Duration(seconds: 1)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    }
  }

  /// Волна по треку — brain POST /api/wave/seed {kind: track}
  /// (мозг создаёт автоплейлист «Волна по …», сид-трек первый).
  /// Мозг выкл/ошибка → локальный фолбэк Instant Mix.
  /// playSong сам публикует новую очередь (POST /api/wave/publish
  /// через _brainPublishNow), веб зеркалит уже новую очередь.
  Future<void> _playTrackWave(Song song) async {
    final provider = context.read<PlayerProvider>();
    final sub = Provider.of<SubsonicService>(context, listen: false);
    final bridge =
        Provider.of<KumaFlowBrainBridge>(context, listen: false);
    // Кэшируем до await (иначе use_build_context_synchronously).
    final cachedSongs =
        context.read<LibraryProvider>().cachedAllSongs;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            ),
            SizedBox(width: 12),
            Text('Генерируем волну по треку...'),
          ],
        ),
        duration: Duration(days: 1),
      ),
    );
    // 1) Brain-радио по треку
    if (bridge.isActive) {
      try {
        final tracks = await KumaFlowBrainPlayback.startTrackRadio(
          bridge: bridge,
          subsonic: sub,
          trackId: song.id,
        ).timeout(const Duration(seconds: 75));
        if (!mounted) return;
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        if (tracks.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Волна пуста: трек не нашёлся в библиотеке')),
          );
          return;
        }
        // Сид как на десктопе (applyWaveSeed): подпись + сид + контекст.
        final seedName = seedLabel(
            WaveSeed(kind: 'track', label: song.title));
        await saveWaveSeed(
            WaveSeed(kind: 'track', label: song.title));
        await saveWaveContext(
            tracks.map((s) => s.id).toList(), seedName, 'brain');
        await provider.playSong(tracks.first,
            playlist: tracks,
            startIndex: 0,
            playlistName: seedName,
            isWave: true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content:
                  Text('🧠 $seedName: ${tracks.length} треков'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        return;
      } catch (e) {
        debugPrint('[KumaFlowNew] brain track radio failed: $e');
      }
    }
    // 2) Локальный фолбэк — Instant Mix как в дефолтном меню
    final autoDj = provider.autoDjService;
    final tracks = await autoDj.getInstantMix(
      seedSong: song,
      count: 10,
      availableSongs: cachedSongs,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (tracks.length > 1) {
      final seedName =
          seedLabel(WaveSeed(kind: 'track', label: song.title));
      await saveWaveSeed(WaveSeed(kind: 'track', label: song.title));
      await saveWaveContext(
          tracks.map((s) => s.id).toList(), seedName, 'local');
      provider.playSong(tracks.first,
          playlist: tracks,
          startIndex: 0,
          playlistName: seedName,
          isWave: true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$seedName: ${tracks.length} треков'),
          duration: const Duration(seconds: 2),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось собрать волну')),
      );
    }
  }

  /// Волна по артисту — brain POST /api/wave/seed {kind: artist}
  /// (ядро: топ-треки артиста + локально-похожие + добор getSimilarSongs2).
  /// Мозг выкл/ошибка → локальный фолбэк: топ треки артиста вперемешку.
  Future<void> _playArtistWave(Song song) async {
    final artists = _effectiveArtists(song);
    final artistName =
        artists.isNotEmpty ? artists.first.name : (song.artist ?? '');
    if (artistName.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет имени артиста для волны')),
      );
      return;
    }
    final sub = Provider.of<SubsonicService>(context, listen: false);
    final bridge =
        Provider.of<KumaFlowBrainBridge>(context, listen: false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            ),
            SizedBox(width: 12),
            Text('Генерируем волну по артисту...'),
          ],
        ),
        duration: Duration(days: 1),
      ),
    );
    // 1) Brain-радио по артисту
    if (bridge.isActive) {
      try {
        final tracks = await KumaFlowBrainPlayback.startArtistRadio(
          bridge: bridge,
          subsonic: sub,
          artistName: artistName,
        ).timeout(const Duration(seconds: 75));
        if (!mounted) return;
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        if (tracks.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  'Brain-радио: ничего не нашлось в библиотеке ($artistName)'),
              duration: const Duration(seconds: 3),
            ),
          );
          return;
        }
        final seedName = seedLabel(
            WaveSeed(kind: 'artist', label: artistName));
        await saveWaveSeed(
            WaveSeed(kind: 'artist', label: artistName));
        await saveWaveContext(
            tracks.map((s) => s.id).toList(), seedName, 'brain');
        await context.read<PlayerProvider>().playSong(
              tracks.first,
              playlist: tracks,
              startIndex: 0,
              playlistName: seedName,
              isWave: true,
            );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  '🧠 $seedName: ${tracks.length} треков'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
        return;
      } catch (e) {
        debugPrint('[KumaFlowNew] brain artist radio failed: $e');
      }
    }
    // 2) Локальный фолбэк — топ треки артиста вперемешку
    final artistId = artists.isNotEmpty && artists.first.id.isNotEmpty
        ? artists.first.id
        : song.artistId;
    if (artistId == null || artistId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Нет id артиста для волны')),
        );
      }
      return;
    }
    try {
      final tracks = await sub.getArtistTopSongs(artistId, count: 25);
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (tracks.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Треки артиста не найдены')),
        );
        return;
      }
      tracks.shuffle();
      final seedName =
          seedLabel(WaveSeed(kind: 'artist', label: artistName));
      await saveWaveSeed(WaveSeed(kind: 'artist', label: artistName));
      await saveWaveContext(
          tracks.map((s) => s.id).toList(), seedName, 'local');
      context.read<PlayerProvider>().playSong(
            tracks.first,
            playlist: tracks,
            startIndex: 0,
            playlistName: seedName,
            isWave: true,
          );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$seedName: ${tracks.length} треков'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<PlayerProvider>();
    final song = p.currentSong;
    final svc = Provider.of<SubsonicService>(context, listen: false);
    // 600 = тот же размер что греет _precacheNeighbors (было 800 → мимо кэша).
    // Офлайн: локальная cover_*.jpg вместо сетевого URL.
    String url = _coverUrl(song, svc, 600);
    final urlSmall = _coverUrl(song, svc, 200);
    try {
      final local = OfflineService().getLocalCoverForSong(
        albumId: song?.albumId,
        coverArt: song?.coverArt,
        trackId: song?.id,
      );
      if (local != null) url = local;
    } catch (_) {}

    if (song == null) {
      return const Scaffold(
        body: Center(child: Text('Нет трека')),
      );
    }

    final size = MediaQuery.of(context).size;
    final isWide =
        size.width >= 700 || (size.width > size.height && size.width >= 600);

    // Прекеш текущей + соседних обложек: переключение без долгого спиннера.
    _precacheNeighbors(p, svc);
    // Прелоад аватарок артистов при смене трека: шторка «Артисты»
    // открывается мгновенно, резолв уже идёт/готов в фоне.
    _precacheArtistImages(song);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Backdrop: блюр обложки + затемнение (как backdrop.tsx)
          _backdrop(urlSmall.isEmpty ? url : urlSmall),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.05),
                  Colors.black.withValues(alpha: 0.35),
                ],
              ),
            ),
          ),
          SafeArea(
            child: GestureDetector(
              // Свайп вниз — закрыть (как дефолт _dragOffset)
              onVerticalDragUpdate: (d) =>
                  setState(() => _vDrag += d.delta.dy),
              onVerticalDragEnd: (d) {
                final v = d.primaryVelocity ?? 0;
                if (_vDrag > _closeThreshold || v > 700) {
                  Navigator.maybePop(context);
                } else if (_vDrag < -110 || v < -700) {
                  // Горизонталь: очередь — таб панели, без шторок.
                  if (isWide) {
                    setState(() => _widePanel = 'queue');
                  } else {
                    _openQueue();
                  }
                }
                setState(() => _vDrag = 0);
              },
              child: Column(
                children: [
                  _topBar(context, p, song, url, isWide: isWide),
                  Expanded(
                    child: isWide
                        ? _wideBody(context, p, song, svc, url)
                        // Вертикаль: транспорт+тулбар — фиксированный футер
                        // у низа экрана (13.10.2026: Spacer внутри скролла
                        // оставлял ~110dp пустоты под тулбаром — кнопки
                        // висели в середине, а не у нижнего края).
                        // Верх (обложка→прогресс) скроллится, кнопки стоят.
                        : Column(
                            children: [
                              Expanded(
                                  child: _narrowBody(
                                      context, p, song, svc, url)),
                              _mainControls(context, song),
                              const SizedBox(height: 14),
                              _subControls(context, p, song, url,
                                  isWide: false),
                              const SizedBox(height: 4),
                            ],
                          ),
                  ),
                  // Прогресс только внутри _narrowBody/_wideBody
                  // (раньше тут был второй _slimProgress -> два бара).
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- Верхняя строка ----------
  // Единственная кнопка очереди (вторая точка входа — свайп вверх).
  // Вертикаль: открывает шторку. Горизонталь: переключает таб панели.
  Widget _topBar(
      BuildContext context, PlayerProvider p, Song song, String url,
      {required bool isWide}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                color: Colors.white, size: 28),
            onPressed: () => Navigator.maybePop(context),
          ),
          const Spacer(),
          // Wide: заголовок живёт только в правой панели (иначе дубль
          // шапки как на скрине 4). Контекст — из очереди (десктоп
          // getActiveContext), а не хардкод «Моя коллекция».
          if (!isWide)
            Builder(builder: (_) {
              final ctx = getActiveQueueContext(
                queueName: p.currentQueueName,
                queueHint: p.currentQueueHint,
                isRadio: p.isPlayingRadio,
                radioName: p.currentRadioStation?.name,
              );
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(ctx.kicker,
                      style: const TextStyle(
                          color: Colors.white60, fontSize: 11)),
                  Text(ctx.title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold)),
                ],
              );
            }),
          if (!isWide) const Spacer(),
          IconButton(
            icon: const Icon(Icons.list_rounded, color: Colors.white70),
            tooltip: 'Очередь',
            onPressed: () {
              if (isWide) {
                setState(() => _widePanel = 'queue');
              } else {
                _openQueue();
              }
            },
          ),
        ],
      ),
    );
  }

  // ---------- Вертикальный layout (как референс) ----------
  // Карусель с пиками prev/next -> инфо -> бейджи+инфо+меню ->
  // прогресс -> транспорт -> тулбар внизу.
  Widget _narrowBody(BuildContext context, PlayerProvider p, Song song,
      SubsonicService svc, String url) {
    final w = MediaQuery.of(context).size.width;
    final h = MediaQuery.of(context).size.height;
    // Центр ~74% ширины: съедаем пустое место; боковушки режутся экраном.
    final coverW =
        (w * 0.74).clamp(0.0, h * 0.40).clamp(210.0, 400.0).toDouble();
    return LayoutBuilder(
      builder: (ctx, c) => SingleChildScrollView(
        physics: const ClampingScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: Column(
            children: [
              const SizedBox(height: 2),
              _coverCarousel(context, p, song, svc, coverW),
              const SizedBox(height: 12),
              // Заголовок: кружок артиста слева + название/артист.
              _mtsTitleRow(
                  context, p, song, coverW, _coverUrl(song, svc, 200)),
              const SizedBox(height: 6),
              _metaRow(context, song, coverW),
              const SizedBox(height: 2),
              // Прогресс сразу под метой как на жёлтом референсе.
              // Транспорт+тулбар переехали в фиксированный футер build()
              // (кнопки у низа экрана, не зависят от скролла/Spacer).
              _slimProgress(context, p),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- Пейджер как на референсе: центр + крупные боковушки ----------
  // Боковые карточки того же размера, обрезаны краем экрана (как рёбра
  // альбома на скрине). Тап/свайп по боковушке — те же skipPrevious/Next,
  // что кнопки и свайп по центру. Соседи догреты прекешем.
  Widget _coverCarousel(BuildContext context, PlayerProvider p, Song song,
      SubsonicService svc, double coverW) {
    final q = p.queue;
    final idx = q.isEmpty
        ? -1
        : p.currentIndex.clamp(0, q.length - 1).toInt();
    final prev = (idx > 0) ? q[idx - 1] : null;
    final next =
        (idx >= 0 && idx + 1 < q.length) ? q[idx + 1] : null;
    final w = MediaQuery.of(context).size.width;
    // Центр от левого края; боковушка выступает за край экрана и режется им.
    const gap = 16.0;
    final centerLeft = (w - coverW) / 2;
    final sideOff = centerLeft - gap - coverW;

    Widget sideCard(Song? s, bool isPrev) {
      if (s == null) return const SizedBox.shrink();
      final u = _coverUrl(s, svc, 600);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => isPrev ? p.skipPrevious() : p.skipNext(),
        onHorizontalDragUpdate: _handleCoverHDragUpdate,
        onHorizontalDragEnd: (d) => _handleCoverHDragEnd(d, p),
        child: Container(
          width: coverW,
          height: coverW,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.10), width: 1),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 20,
                  offset: const Offset(0, 10)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            // Боковушки приглушены: центр — фокус. Без fade-вспышек.
            child: Opacity(
              opacity: 0.6,
              child: Container(
                foregroundDecoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: u.startsWith('http')
                    ? CachedNetworkImage(
                        imageUrl: u,
                        fit: BoxFit.cover,
                        fadeInDuration: Duration.zero,
                        fadeOutDuration: Duration.zero,
                        errorWidget: (_, __, ___) =>
                            _placeholder(),
                      )
                    : _art(u),
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: w,
      height: coverW,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            left: sideOff,
            top: 0,
            child: sideCard(prev, true),
          ),
          Positioned(
            left: centerLeft,
            top: 0,
            child: _cover(context, p, song, coverW, isWide: false),
          ),
          Positioned(
            right: sideOff,
            top: 0,
            child: sideCard(next, false),
          ),
        ],
      ),
    );
  }

  void _handleCoverHDragUpdate(DragUpdateDetails d) {
    if (d.delta.dx.abs() < d.delta.dy.abs() * 1.5) return;
    setState(() => _hDrag += d.delta.dx);
  }

  void _handleCoverHDragEnd(DragEndDetails d, PlayerProvider p) {
    final v = d.primaryVelocity ?? 0;
    final traveled = _hDrag;
    setState(() {
      _hDrag = 0;
      _vDrag = 0;
    });
    final now = DateTime.now();
    if (traveled.abs() < _swipeThreshold) return;
    if (now.difference(_lastCoverSwipeAt).inMilliseconds < 500) return;
    _lastCoverSwipeAt = now;
    if (traveled > 0 || v > 1000) {
      p.skipPrevious();
    } else if (traveled < 0 || v < -1000) {
      p.skipNext();
    }
  }

  // ---------- Горизонтальный / планшет ----------
  // Слева компактно: обложка + транспорт + тулбар (всё видно без скролла).
  // Справа панель с табами очередь/текст (как десктоп, без шторок).
  // Снизу на всю ширину — прогресс как на референсе.
  Widget _wideBody(BuildContext context, PlayerProvider p, Song song,
      SubsonicService svc, String url) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final midH = c.maxHeight;
        final midW = c.maxWidth;
        // Левая колонка широкая фикс: контролы (~260px) влезают,
        // раньше было coverS+16 ~146px -> транспорт вылезал, текст
        // "How I'm Feelin — Belly, Shen..." обрезался в одну строку.
        final leftW = midW * 0.38 < 280
            ? 280.0
            : (midW * 0.38 > 340 ? 340.0 : midW * 0.38);
        final coverS = (leftW - 16).clamp(140.0, 300.0).toDouble();
        // При низком landscape (высота ~360) всё скроллится,
        // а не сжимается в кашу.
        final fitsHeight = midH >= 430;
        Widget leftCol = Column(
          mainAxisAlignment: fitsHeight
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _cover(context, p, song, coverS, isWide: true),
            const SizedBox(height: 8),
            // Полный инфо-блок как в вертикали/десктопе CoverColumn,
            // а не однострочный _infoLine с ellipsis.
            _infoBlock(context, song, url, coverS,
                titleSize: 16, hideAlbum: false),
            const SizedBox(height: 8),
            _mainControls(context, song, compact: true),
            _subControls(context, p, song, url, isWide: true),
          ],
        );
        return Column(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: leftW,
                    child: fitsHeight
                        ? leftCol
                        : SingleChildScrollView(
                            physics:
                                const ClampingScrollPhysics(),
                            child: leftCol,
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.only(right: 12, top: 4),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.30),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      child: _ContextPanelKfn(
                        panel: _widePanel,
                        onPanelChanged: (v) =>
                            setState(() => _widePanel = v),
                        song: song,
                        imgUrl: url,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _slimProgress(context, p),
          ],
        );
      },
    );
  }

  // ---------- Обложка со свайпами ----------
  // Кнопок на обложке нет: очередь — свайп вверх / иконка в шапке.
  Widget _cover(
      BuildContext context, PlayerProvider p, Song song, double width,
      {required bool isWide}) {
    return GestureDetector(
      // Горизонтальный свайп — prev/next (общий хендлер с боковушками).
      // Вертикали тут нет специально: она у внешнего детектора.
      onHorizontalDragUpdate: _handleCoverHDragUpdate,
      onHorizontalDragEnd: (d) => _handleCoverHDragEnd(d, p),
      child: Transform.translate(
        offset: Offset(_hDrag.clamp(-60.0, 60.0).toDouble(), 0),
        child: Container(
          width: width,
          height: width,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.10), width: 1),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 30,
                  offset: const Offset(0, 16)),
            ],
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  // 600 вместо 800: ресайз на сервере быстрее, на экране
                  // разницы нет, соседи догреты прекешем.
                  child: _art(_coverUrl(
                      song,
                      Provider.of<SubsonicService>(context, listen: false),
                      600)),
                ),
              ),
              // Индикатор свайпа
              if (_hDrag.abs() > 10)
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Center(
                      child: Icon(
                        _hDrag > 0
                            ? Icons.skip_previous_rounded
                            : Icons.skip_next_rounded,
                        color: Colors.white,
                        size: 56,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- Инфо-блок: кружок + название/артист + (i) ----------
  // Тап по артисту — как в дефолте (1 → сразу на страницу, >1 → шторка),
  // но картинки в шторке подгружаются асинхронно (поиск по имени),
  // даже если у артиста нет id/coverArt.
  Widget _infoBlock(
      BuildContext context, Song song, String url, double width,
      {double titleSize = 20,
      bool hideAlbum = false,
      bool showInfoButton = true}) {
    final artists = _effectiveArtists(song);
    final album = (song.album ?? '').trim();
    return SizedBox(
      width: width,
      child: Row(
        children: [
          // Кружок артиста: 1 -> фото, 2-4 -> сплит как на десктопе,
          // фолбэк — миниатюра обложки. Тап — как по имени.
          GestureDetector(
            onTap: () => _onArtistTap(context, song),
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.18),
                    width: 1.5),
              ),
              child: ClipOval(
                child: artists.isEmpty
                    ? _art(url)
                    : _artistAvatar(song, artists, url),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: titleSize,
                      fontWeight: FontWeight.bold,
                      height: 1.15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    // Альбом ужимается первым (до ~1/3), артист —
                    // приоритет: забирает всё оставшееся место.
                    if (album.isNotEmpty && !hideAlbum)
                      Flexible(
                        flex: 35,
                        fit: FlexFit.loose,
                        child: Text(
                          album,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (album.isNotEmpty && !hideAlbum)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6),
                        child: Text('•',
                            style: TextStyle(
                                color: Colors.white38, fontSize: 13)),
                      ),
                    Expanded(
                      flex: 65,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _onArtistTap(context, song),
                        child: Text(
                          _artistNames(song),
                          style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (showInfoButton)
            IconButton(
              icon: const Icon(Icons.info_outline_rounded,
                  color: Colors.white54, size: 20),
              tooltip: 'О треке',
              onPressed: () => _showAbout(song),
            ),
        ],
      ),
    );
  }

  // ---------- Заголовок: кружок артиста + название/артист ----------
  // 1 артист -> фото, 2-4 -> сплит-круг как на десктопе (_artistAvatar).
  // Без артистов — старый вид по центру. Тап по всему ряду — как раньше.
  Widget _mtsTitleRow(BuildContext context, PlayerProvider p, Song song,
      double width, String fallbackCover) {
    final artists = _effectiveArtists(song);
    final centered = artists.isEmpty;
    return SizedBox(
      width: width,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _onArtistTap(context, song),
        child: Row(
          children: [
            if (!centered) ...[
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.18),
                      width: 1.5),
                ),
                child: ClipOval(
                  child: _artistAvatar(song, artists, fallbackCover,
                      size: 52),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: centered
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        height: 1.15),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign:
                        centered ? TextAlign.center : TextAlign.start,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _artistNames(song),
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign:
                        centered ? TextAlign.center : TextAlign.start,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Мета-ряд: пилюли + (i) + (•••) как на жёлтом референсе ----------
  // Жанр / год / тип файла / настроение, справа инфо о треке и меню.
  Widget _metaRow(BuildContext context, Song song, double width) {
    return SizedBox(
      width: width,
      child: Row(
        children: [
          Expanded(child: _badges(song)),
          IconButton(
            icon: const Icon(Icons.info_outline_rounded,
                color: Colors.white54, size: 20),
            tooltip: 'О треке',
            onPressed: () => _showAbout(song),
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz_rounded,
                color: Colors.white54, size: 20),
            tooltip: 'Ещё',
            onPressed: () => _openMoreMenu(song),
          ),
        ],
      ),
    );
  }

  // ---------- Артисты: разбор как в MultiArtistWidget ----------

  static final _artistSplitRe = RegExp(
    r'\s*[/,;]\s*|\s+feat\.?\s+|\s+ft\.?\s+|\s+&\s+|\s+×\s+',
    caseSensitive: false,
  );

  static List<String> _splitArtistString(String raw) {
    final parts = raw
        .split(_artistSplitRe)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.length > 1 && parts.any((p) => p.length < 2)) {
      return [raw.trim()];
    }
    return parts.isEmpty ? [raw.trim()] : parts;
  }

  /// Эффективный список артистов: participants, иначе разбор строки.
  List<ArtistRef> _effectiveArtists(Song song) {
    final parts = song.artistParticipants;
    if (parts != null && parts.isNotEmpty) {
      final expanded = <ArtistRef>[];
      for (final a in parts) {
        if (_artistSplitRe.hasMatch(a.name)) {
          final sub = _splitArtistString(a.name);
          if (sub.length > 1) {
            for (final n in sub) {
              expanded.add(ArtistRef(id: '', name: n));
            }
            continue;
          }
        }
        expanded.add(a);
      }
      return expanded;
    }
    final name = song.artist;
    final id = song.artistId;
    if (name != null && name.trim().isNotEmpty) {
      final sub = _splitArtistString(name);
      if (sub.length > 1) {
        return sub
            .map((n) => ArtistRef(
                id: n == sub.first ? (id ?? '') : '', name: n))
            .toList();
      }
      return [ArtistRef(id: id ?? '', name: name)];
    }
    if (id != null && id.isNotEmpty) {
      return [ArtistRef(id: id, name: name ?? '')];
    }
    return [];
  }

  String _artistNames(Song song) {
    final list = _effectiveArtists(song);
    if (list.isEmpty) return '';
    return list.map((a) => a.name).join(', ');
  }

  void _onArtistTap(BuildContext context, Song song) {
    final list = _effectiveArtists(song);
    if (list.isEmpty) return;
    if (list.length == 1) {
      _navigateToArtist(context, list.first);
    } else {
      _openArtistsSheet(context, list);
    }
  }

  void _navigateToArtist(BuildContext context, ArtistRef artist) {
    if (artist.id.isNotEmpty) {
      NavigationHelper.push(
        navigatorKey.currentContext ?? context,
        ArtistScreen(artistId: artist.id),
      );
    } else if (artist.name.isNotEmpty) {
      _searchAndNavigate(context, artist.name);
    }
  }

  /// Поиск артиста по имени без id (вторые+ участники сплита).
  /// Раньше: голый await search без таймаута и без индикации — на мёртвой
  /// сети тап «умирал» на 30с+ и казалось что переход не работает.
  /// Теперь: мгновенный спиннер + дедлайн 8с + честная ошибка.
  Future<void> _searchAndNavigate(BuildContext context, String name) async {
    final subsonic = Provider.of<SubsonicService>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text('Ищем артиста «$name»…')),
          ],
        ),
        duration: const Duration(seconds: 8),
      ),
    );
    try {
      final result = await subsonic
          .search(
            name,
            artistCount: 5,
            albumCount: 0,
            songCount: 0,
          )
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      if (result.artists.isNotEmpty) {
        final matched = result.artists.firstWhere(
          (a) => a.name.toLowerCase() == name.toLowerCase(),
          orElse: () => result.artists.first,
        );
        if (!mounted) return;
        NavigationHelper.push(
          navigatorKey.currentContext ?? context,
          ArtistScreen(artistId: matched.id),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Артист не найден: $name'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Не удалось найти артиста: нет связи с сервером'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  /// Шторка выбора артиста: прелоад картинок по цепочке
  /// getArtist -> search artist -> search album -> трек из кэша,
  /// чтобы не было пустых `B/S` кружков как на скрине 2.
  void _openArtistsSheet(BuildContext context, List<ArtistRef> artists) {
    final song = context.read<PlayerProvider>().currentSong;
    final svc = Provider.of<SubsonicService>(context, listen: false);
    final fallbackCover = song != null ? _coverUrl(song, svc, 200) : '';
    for (final a in artists) {
      if ((a.effectiveCoverArt ?? '').isNotEmpty) continue;
      _cachedArtistFuture(a);
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.darkSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.darkDivider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Артисты',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.45,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: artists.length,
                  itemBuilder: (_, i) {
                    final a = artists[i];
                    return ListTile(
                      leading: SizedBox(
                        width: 52,
                        height: 52,
                        child: ClipOval(
                          child: _artistImage(a, 52,
                              fallbackCoverUrl: fallbackCover),
                        ),
                      ),
                      title: Text(a.name,
                          style: const TextStyle(color: Colors.white)),
                      onTap: () {
                        Navigator.pop(ctx);
                        _navigateToArtist(context, a);
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  /// Аватар: 1 артист -> фото, 2-4 -> сплит-круг как на десктопе
  /// artist-avatar.tsx (половины/четверти, каждая кликабельна).
  Widget _artistAvatar(Song song, List<ArtistRef> artists, String songCoverUrl,
      {double size = 46}) {
    if (artists.length <= 1) {
      return _artistImage(
          artists.first, size, fallbackCoverUrl: songCoverUrl);
    }
    final list = artists.take(4).toList();
    if (list.length == 2) {
      return Row(children: [
        Expanded(
            child: _artistSlice(list[0], songCoverUrl, size: size)),
        Expanded(
            child: _artistSlice(list[1], songCoverUrl, size: size)),
      ]);
    }
    if (list.length == 3) {
      return Row(children: [
        Expanded(
            child: _artistSlice(list[0], songCoverUrl, size: size)),
        Expanded(
          child: Column(children: [
            Expanded(
                child: _artistSlice(list[1], songCoverUrl, size: size)),
            Expanded(
                child: _artistSlice(list[2], songCoverUrl, size: size)),
          ]),
        ),
      ]);
    }
    return Column(children: [
      Expanded(
        child: Row(children: [
          Expanded(
              child: _artistSlice(list[0], songCoverUrl, size: size)),
          Expanded(
              child: _artistSlice(list[1], songCoverUrl, size: size)),
        ]),
      ),
      Expanded(
        child: Row(children: [
          Expanded(
              child: _artistSlice(list[2], songCoverUrl, size: size)),
          Expanded(
              child: _artistSlice(list[3], songCoverUrl, size: size)),
        ]),
      ),
    ]);
  }

  Widget _artistSlice(ArtistRef artist, String fallbackCoverUrl,
      {double size = 46}) {
    return GestureDetector(
      onTap: () => _navigateToArtist(context, artist),
      child: _artistImage(artist, size,
          fallbackCoverUrl: fallbackCoverUrl),
    );
  }

  /// Картинка артиста: coverArt/id сразу, иначе цепочка как на десктопе:
  /// getArtist(id).coverArt/artistImageUrl -> search artist -> search album
  /// -> обложка любого трека артиста из кэша -> градиент с инициалами.
  Widget _artistImage(ArtistRef artist, double size,
      {String? fallbackCoverUrl}) {
    final direct = artist.effectiveCoverArt;
    if (direct != null && direct.isNotEmpty) {
      return AlbumArtwork(
        coverArt: direct,
        size: size,
        borderRadius: size / 2,
        shadow: const BoxShadow(color: Colors.transparent),
      );
    }
    final fut = _cachedArtistFuture(artist);
    return FutureBuilder<String?>(
      future: fut,
      builder: (_, snap) {
        var imgUrl = snap.data;
        if ((imgUrl == null || imgUrl.isEmpty) &&
            snap.connectionState == ConnectionState.done &&
            fallbackCoverUrl != null &&
            fallbackCoverUrl.isNotEmpty) {
          imgUrl = fallbackCoverUrl;
        }
        if (imgUrl != null && imgUrl.isNotEmpty) {
          if (imgUrl.startsWith('http')) {
            return CachedNetworkImage(
              key: ValueKey('knew_artist_${imgUrl.hashCode}_${size.toInt()}'),
              imageUrl: imgUrl,
              cacheManager: SafeImageCacheManager.instance,
              cacheKey: 'knew_artist_${imgUrl.hashCode}_${size.toInt()}',
              width: size,
              height: size,
              fit: BoxFit.cover,
              // Без fade-вспышек + ужатый декод: кружки рисуются сразу.
              fadeInDuration: Duration.zero,
              fadeOutDuration: Duration.zero,
              memCacheWidth: (size * 2).toInt(),
              maxWidthDiskCache: (size * 2).toInt(),
              maxHeightDiskCache: (size * 2).toInt(),
              useOldImageOnUrlChange: true,
              placeholder: (_, __) =>
                  _artistInitials(artist.name, size),
              errorWidget: (_, __, ___) {
                if (fallbackCoverUrl != null &&
                    fallbackCoverUrl.isNotEmpty &&
                    fallbackCoverUrl != imgUrl) {
                  return _art(fallbackCoverUrl);
                }
                return _artistInitials(artist.name, size);
              },
            );
          }
          return AlbumArtwork(
            coverArt: imgUrl,
            size: size,
            borderRadius: size / 2,
            shadow: const BoxShadow(color: Colors.transparent),
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return _artistInitials(artist.name, size, loading: true);
        }
        if (fallbackCoverUrl != null && fallbackCoverUrl.isNotEmpty) {
          return _art(fallbackCoverUrl);
        }
        return _artistInitials(artist.name, size);
      },
    );
  }

  Widget _artistInitials(String name, double size,
      {bool loading = false}) {
    final initials = name.trim().isEmpty
        ? '?'
        : name
            .trim()
            .split(RegExp(r'\s+'))
            .take(2)
            .map((w) => w.isEmpty ? '' : w[0].toUpperCase())
            .join();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3B4C63), Color(0xFF1E293B)],
        ),
        shape: BoxShape.circle,
        border: Border.all(
            color: Colors.white.withValues(alpha: 0.14), width: 1),
      ),
      child: Center(
        child: loading
            ? SizedBox(
                width: size * 0.4,
                height: size * 0.4,
                child: const CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white70),
              )
            : Text(initials,
                style: TextStyle(
                    color: Colors.white70,
                    fontSize: size * 0.35,
                    fontWeight: FontWeight.bold)),
      ),
    );
  }

  /// Дедлайн одного сетевого шага резолва картинки артиста.
  /// Без него на мёртвой сети каждый шаг висел до 30с (Dio timeout).
  static const _artistStepTimeout = Duration(seconds: 5);

  /// Общий доступ к закешированному резолву картинки артиста.
  /// Общий дедлайн 10с (onTimeout -> null): на мёртвой сети кружки
  /// показывают фолбэк/инициалы, а не висят минутами. Пустой результат
  /// тоже кешируется — повторные открытия мгновенные.
  Future<String?> _cachedArtistFuture(ArtistRef a) {
    // Ключ был только имя → однофамильцы перезатирали друг друга.
    final key = a.id.isNotEmpty ? '${a.id}|${a.name}' : a.name;
    return _artistArtCache.putIfAbsent(
      key,
      () => _resolveArtistImage(a.id, a.name).timeout(
        const Duration(seconds: 10),
        onTimeout: () => null,
      ),
    );
  }

  /// Прелоад аватарок при смене трека: пока слушаешь — картинки уже
  /// резолвятся в фоне, шторка «Артисты» открывается мгновенно.
  /// Параллельно (Future.wait), ошибки глотаем — это фон.
  String _preloadedArtistSongId = '';
  void _precacheArtistImages(Song song) {
    if (song.id == _preloadedArtistSongId) return;
    _preloadedArtistSongId = song.id;
    final futs = <Future<void>>[];
    for (final a in _effectiveArtists(song).take(4)) {
      if ((a.effectiveCoverArt ?? '').isNotEmpty) continue;
      futs.add(
          _cachedArtistFuture(a).then((_) {}).catchError((_) {}));
    }
    if (futs.isEmpty) return;
    Future.wait<void>(futs).catchError((_) {});
  }

  /// Цепочка как на десктопе: getArtist(id) -> search artist
  /// -> search album по имени -> обложка трека артиста из кэша библиотеки.
  /// Каждый сетевой шаг ограничен 5с: на мёртвой сети весь резолв
  /// укладывается в общий дедлайн _cachedArtistFuture, а не 30с x N.
  Future<String?> _resolveArtistImage(String id, String name) async {
    try {
      final ctx = navigatorKey.currentContext;
      if (ctx == null || name.trim().isEmpty) return null;
      final subsonic = Provider.of<SubsonicService>(ctx, listen: false);
      // 1) Страница артиста по id
      if (id.isNotEmpty) {
        try {
          final page =
              await subsonic.getArtist(id).timeout(_artistStepTimeout);
          final direct = page.artistImageUrl;
          if (direct != null && direct.startsWith('http')) return direct;
          final ca = page.coverArt;
          if (ca != null && ca.isNotEmpty) {
            if (ca.startsWith('http')) return ca;
            return subsonic.getCoverArtUrl(ca, size: 200);
          }
        } catch (_) {}
      }
      // 2) Поиск артиста по имени
      try {
        final result = await subsonic
            .search(
              name,
              artistCount: 5,
              albumCount: 0,
              songCount: 0,
            )
            .timeout(_artistStepTimeout);
        if (result.artists.isNotEmpty) {
          final matched = result.artists.firstWhere(
            (a) => a.name.toLowerCase() == name.toLowerCase(),
            orElse: () => result.artists.first,
          );
          final direct = matched.artistImageUrl;
          if (direct != null && direct.startsWith('http')) return direct;
          final ca = matched.coverArt;
          if (ca != null && ca.isNotEmpty) {
            if (ca.startsWith('http')) return ca;
            return subsonic.getCoverArtUrl(ca, size: 200);
          }
        }
      } catch (_) {}
      // 3) Обложка альбома по имени (как десктоп search3 albumCount:1)
      try {
        final albums = await subsonic
            .search(
              name,
              artistCount: 0,
              albumCount: 1,
              songCount: 0,
            )
            .timeout(_artistStepTimeout);
        if (albums.albums.isNotEmpty) {
          final ca = albums.albums.first.coverArt;
          if (ca != null && ca.isNotEmpty) {
            if (ca.startsWith('http')) return ca;
            return subsonic.getCoverArtUrl(ca, size: 200);
          }
        }
      } catch (_) {}
      // 4) Любой трек артиста из кэша библиотеки -> его обложка
      try {
        final lib = Provider.of<LibraryProvider>(ctx, listen: false);
        final all = lib.cachedAllSongs;
        final low = name.toLowerCase();
        for (final s in all) {
          if ((s.artist ?? '').toLowerCase().contains(low) ||
              (s.artist ?? '').toLowerCase() == low) {
            final ca = s.coverArt;
            if (ca != null && ca.isNotEmpty) {
              if (ca.startsWith('http') || isLocalFilePath(ca)) {
                return ca;
              }
              if (ca.startsWith('abs:')) {
                return AudiobookshelfService()
                    .getCoverUrl(ca.substring(4), width: 200);
              }
              return subsonic.getCoverArtUrl(ca, size: 200);
            }
          }
        }
      } catch (_) {}
      return null;
    } catch (_) {
      return null;
    }
  }

  // ---------- Бейджи-пилюли как на скринах десктопа ----------
  // + настроение с мозга (read-only): song.mood сразу, иначе async
  // waveContinue/getTrack с кэшем. Мозг на сервере не трогаем.
  final Map<String, Future<String?>> _brainMoodCache = {};

  Widget _badges(Song song) {
    final items = <String>[];
    if (song.genre != null && song.genre!.isNotEmpty) {
      items.add(song.genre!);
    }
    if (song.year != null) items.add('${song.year}');
    final localMood = (song.mood ?? '').trim();
    if (localMood.isNotEmpty) items.add(localMood);
    if (song.suffix != null && song.suffix!.isNotEmpty) {
      items.add(song.suffix!.toUpperCase());
    }
    Widget chip(String t) => Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: const Color(0xFF16283A),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(t,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        );
    final syncChips = items.map(chip).toList();
    // Мозговое настроение — только если локального нет (без дублей).
    if (localMood.isNotEmpty) {
      if (syncChips.isEmpty) return const SizedBox.shrink();
      return Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: syncChips,
      );
    }
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        ...syncChips,
        FutureBuilder<String?>(
          future: _brainMoodCache.putIfAbsent(
              song.id, () => _brainMoodFor(song)),
          builder: (_, snap) {
            final m = snap.data?.trim() ?? '';
            if (m.isEmpty) return const SizedBox.shrink();
            return chip(m);
          },
        ),
      ],
    );
  }

  /// Настроение трека с мозга (только чтение):
  /// uuid -> getTrack.moods[0]; иначе waveContinue ищем свой playableId.
  Future<String?> _brainMoodFor(Song song) async {
    try {
      final ctx = navigatorKey.currentContext;
      if (ctx == null) return null;
      final bridge =
          Provider.of<KumaFlowBrainBridge>(ctx, listen: false);
      if (!bridge.isActive) return null;
      final c = bridge.client;
      if (c == null) return null;
      // Прямой uuid трека мозга.
      var isUuid = false;
      try {
        final v = song.id.trim();
        isUuid = v.length == 36 && '-'.allMatches(v).length == 4;
      } catch (_) {}
      if (isUuid) {
        try {
          final t = await c
              .getTrack(song.id)
              .timeout(const Duration(seconds: 5));
          final moods = t['moods'];
          if (moods is List && moods.isNotEmpty) {
            return moods.first.toString();
          }
        } catch (_) {}
      }
      // Через продолжение волны: ищем в ответе свой трек.
      try {
        final tracks = await bridge
            .waveContinue(
              queue: [song.id],
              currentTrackId: song.id,
              count: 5,
            )
            .timeout(const Duration(seconds: 6));
        for (final t in tracks) {
          if (t.playableId == song.id && t.moods.isNotEmpty) {
            return t.moods.first;
          }
        }
      } catch (_) {}
      return null;
    } catch (_) {
      return null;
    }
  }

  // ---------- Главные кнопки: дизлайк | назад | плей | дальше | лайк ----------
  // Иерархия: транспорт крупный белый, оценки меньше по краям.
  // compact — для горизонтального режима (всё видно без скролла).
  Widget _mainControls(BuildContext context, Song song,
      {bool compact = false}) {
    final p = context.watch<PlayerProvider>();
    final liked = song.starred == true;
    // compact ужаты чтобы влезть в левую колонку 280-340:
    // было play 56 + gaps 4 -> ширина ~260, вылезало за 146px колонку.
    final playSize = compact ? 52.0 : 88.0;
    final playIcon = compact ? 28.0 : 46.0;
    final navSize = compact ? 28.0 : 44.0;
    final sideSize = compact ? 20.0 : 30.0;
    final gap = compact ? 8.0 : 14.0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Дизлайк — зачёркнутое сердце как на жёлтом референсе
        // (раньше был палец thumb_down_outlined).
        _ctrlWidget(
          _crossedHeart(sideSize, Colors.white60),
          () => _dislike(p, song),
          tooltip: 'Дизлайк',
        ),
        SizedBox(width: gap),
        _ctrlBtn(Icons.skip_previous_rounded, navSize, Colors.white,
            () => p.skipPrevious(),
            tooltip: 'Назад'),
        SizedBox(width: gap),
        GestureDetector(
          onTap: () => p.togglePlayPause(),
          child: Container(
            width: playSize,
            height: playSize,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 16,
                    offset: const Offset(0, 6)),
              ],
            ),
            child: Icon(
              p.isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              color: Colors.black,
              size: playIcon,
            ),
          ),
        ),
        SizedBox(width: gap),
        _ctrlBtn(Icons.skip_next_rounded, navSize, Colors.white,
            () => p.skipNext(),
            tooltip: 'Дальше'),
        SizedBox(width: gap),
        _ctrlBtn(
            liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            sideSize,
            liked ? const Color(0xFFFF2D55) : Colors.white60, () {
          p.toggleFavorite();
        }, tooltip: 'Лайк'),
      ],
    );
  }

  Widget _ctrlBtn(
      IconData icon, double size, Color color, VoidCallback onTap,
      {String? tooltip}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Tooltip(
        message: tooltip ?? '',
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: color, size: size),
        ),
      ),
    );
  }

  Widget _ctrlWidget(Widget child, VoidCallback onTap, {String? tooltip}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Tooltip(
        message: tooltip ?? '',
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: child,
        ),
      ),
    );
  }

  /// Зачёркнутое сердце для дизлайка: контур + диагональная черта.
  /// Как на жёлтом референсе: слева перечёркнутое, справа обычное.
  Widget _crossedHeart(double size, Color color) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.favorite_border_rounded, size: size, color: color),
          Transform.rotate(
            angle: -0.785,
            child: Container(
              width: size * 1.25,
              height: 1.8,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- Нижний тулбар: shuffle | repeat | текст | таймер | share ----------
  // ••• переехало в мета-ряд (как на жёлтом). Таймер и поделиться —
  // как в дефолтном плеере.
  Widget _subControls(
      BuildContext context, PlayerProvider p, Song song, String url,
      {required bool isWide}) {
    const active = Color(0xFF4E8CA8);
    final iconSize = 22.0;
    Widget item(
        {required IconData icon,
        required String tooltip,
        required bool isActive,
        required VoidCallback onTap}) {
      return IconButton(
        icon:
            Icon(icon, size: iconSize, color: isActive ? active : Colors.white54),
        tooltip: tooltip,
        onPressed: onTap,
      );
    }

    final repeat = p.repeatMode;
    final timerOn = p.hasSleepTimer;
    final timerTip = timerOn && p.sleepTimerRemaining != null
        ? 'Таймер: ${_fmt(p.sleepTimerRemaining!)}'
        : 'Таймер сна';
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        item(
            icon: p.shuffleEnabled
                ? Icons.shuffle_on_rounded
                : Icons.shuffle_rounded,
            tooltip: 'Перемешать',
            isActive: p.shuffleEnabled,
            onTap: () => p.toggleShuffle()),
        item(
            icon: repeat == RepeatMode.one
                ? Icons.repeat_one_on_rounded
                : (repeat == RepeatMode.all
                    ? Icons.repeat_on_rounded
                    : Icons.repeat_rounded),
            tooltip: 'Повтор',
            isActive: repeat != RepeatMode.off,
            onTap: () => p.toggleRepeat()),
        item(
            icon: Icons.mic_rounded,
            tooltip: 'Текст песни',
            isActive: false,
            onTap: () {
              // Горизонталь: текст — таб правой панели, без шторок.
              if (isWide) {
                setState(() => _widePanel = 'lyrics');
              } else {
                _openLyrics(song, url);
              }
            }),
        item(
            icon: timerOn
                ? Icons.timer_rounded
                : Icons.timer_outlined,
            tooltip: timerTip,
            isActive: timerOn,
            onTap: () => _showSleepTimerDialog(context, p)),
        item(
            icon: Icons.share_outlined,
            tooltip: 'Поделиться',
            isActive: false,
            onTap: () => _shareSong(context, song)),
      ],
    );
  }

  /// Таймер сна как в дефолтном плеере (упрощённо: минуты + выкл).
  void _showSleepTimerDialog(BuildContext context, PlayerProvider p) {
    final opts = <String, Duration>{
      '15 минут': const Duration(minutes: 15),
      '30 минут': const Duration(minutes: 30),
      '45 минут': const Duration(minutes: 45),
      '1 час': const Duration(hours: 1),
      '2 часа': const Duration(hours: 2),
    };
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Таймер сна'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (p.hasSleepTimer)
              ListTile(
                leading: const Icon(Icons.timer_off_outlined),
                title: const Text('Выключить таймер'),
                onTap: () {
                  p.cancelSleepTimer();
                  Navigator.pop(ctx);
                },
              ),
            ...opts.entries.map((e) => ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: Text(e.key),
                  onTap: () {
                    p.setSleepTimer(e.value);
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text('Таймер: ${e.key}'),
                          duration: const Duration(seconds: 1)),
                    );
                  },
                )),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Закрыть')),
        ],
      ),
    );
  }

  /// Поделиться: текст + обложка альбома файлом (как дефолтный плеер
  /// через SongShareCard, но без RepaintBoundary — качаем coverArt по URL
  /// с auth-параметрами и шарим XFile; нет обложки — только текст).
  Future<void> _shareSong(BuildContext context, Song song) async {
    try {
      final artist = song.artist ?? '';
      final text = '${song.title}'
          '${artist.isNotEmpty ? " — $artist" : ""}'
          '${song.album != null && song.album!.isNotEmpty ? " (${song.album})" : ""}'
          '\n\nShared via KumaFlow';
      final sub = Provider.of<SubsonicService>(context, listen: false);
      final coverUrl = _coverUrl(song, sub, 800);
      if (coverUrl.isNotEmpty && coverUrl.startsWith('http')) {
        try {
          final client = HttpClient();
          try {
            final req = await client
                .getUrl(Uri.parse(coverUrl))
                .timeout(const Duration(seconds: 10));
            final resp = await req.close().timeout(const Duration(seconds: 10));
            if (resp.statusCode == 200) {
              final bytes = await resp
                  .fold<List<int>>(<int>[], (p, e) => p..addAll(e))
                  .timeout(const Duration(seconds: 10));
              if (bytes.length > 1000) {
                final dir = Directory.systemTemp;
                final f = File(
                    '${dir.path}/kumaflow-share-${song.id}.jpg');
                await f.writeAsBytes(bytes, flush: true);
                await SharePlus.instance.share(
                  ShareParams(
                    files: [XFile(f.path, mimeType: 'image/jpeg')],
                    text: text,
                    subject: '${song.title} - $artist',
                  ),
                );
                HapticFeedback.lightImpact();
                return;
              }
            }
          } finally {
            client.close(force: true);
          }
        } catch (e) {
          debugPrint('[KumaFlowNew] share cover failed, text only: $e');
        }
      }
      await SharePlus.instance.share(
        ShareParams(
          text: text,
          subject: '${song.title} - $artist',
        ),
      );
      HapticFeedback.lightImpact();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось поделиться: $e')),
        );
      }
    }
  }

  // ---------- Тонкий slim-прогресс снизу (как FullscreenProgress line) ----------
  Widget _slimProgress(BuildContext context, PlayerProvider p) {
    final dur = p.currentSong?.duration != null
        ? Duration(seconds: p.currentSong!.duration!)
        : Duration.zero;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: StreamBuilder<Duration>(
        stream: p.positionStream,
        initialData: p.position,
        builder: (_, snap) {
          final pos = snap.data ?? Duration.zero;
          final max = dur.inSeconds.toDouble() > 0
              ? dur.inSeconds.toDouble()
              : 1.0;
          final val =
              pos.inSeconds.toDouble().clamp(0.0, max).toDouble();
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Слайдер сверху, время под ним (как на референсе)
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  activeTrackColor: const Color(0xFF4E8CA8),
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: val,
                  max: max,
                  onChanged: (v) => p.seek(Duration(seconds: v.toInt())),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_fmt(pos),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12)),
                    Text(_fmt(dur),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Очередь в стиле десктопного ContextBody (now-playing.tsx:639-795):
/// - шапка: kicker "Сейчас играет" + title "Моя коллекция", кнопки
///   очередь / текст / закрыть
/// - уже сыгранные (до 3) приглушены с fade наверх
/// - текущий трек подсвечен
/// - "Далее в очереди" — следующие треки, тап = переход
/// Появление: showModalBottomSheet снизу-вверх с анимацией 320мс.
class _QueueSheetKfn extends StatefulWidget {
  /// Открыть текст песни: вызывается ПОСЛЕ закрытия очереди,
  /// чтобы шторки не складывались друг на друга.
  final void Function(Song song)? onOpenLyrics;
  const _QueueSheetKfn({this.onOpenLyrics});

  @override
  State<_QueueSheetKfn> createState() => _QueueSheetKfnState();
}

class _QueueSheetKfnState extends State<_QueueSheetKfn> {
  bool _jumpedFor = false;
  String _jumpSongId = '';
  ScrollController? _sheetCtrl;
  // Кэш похожих (на трек): треки с reason + имена артистов.
  final Map<String, Future<List<_SimTrack>>> _simTracksCache = {};
  final Map<String, Future<List<String>>> _simArtistsCache = {};

  @override
  void dispose() {
    super.dispose();
  }

  void _jumpToCurrent(int idx, String songId) {
    if (_jumpedFor && _jumpSongId == songId) return;
    _jumpedFor = true;
    _jumpSongId = songId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _sheetCtrl;
      if (c == null || !c.hasClients) return;
      try {
        c.jumpTo((idx * 64)
            .toDouble()
            .clamp(0.0, c.position.maxScrollExtent));
      } catch (_) {}
    });
  }

  String _fmtSec(int? sec) {
    if (sec == null || sec <= 0) return '';
    return '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.78,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (ctx, scrollCtrl) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(ctx).scaffoldBackgroundColor,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Consumer<PlayerProvider>(
            builder: (ctx, p, _) {
              final q = p.queue;
              final idx = q.isEmpty
                  ? 0
                  : p.currentIndex.clamp(0, q.length - 1).toInt();
              final prev = q.isEmpty
                  ? <Song>[]
                  : q.sublist(
                      (idx - 3).clamp(0, q.length).toInt(),
                      idx.clamp(0, q.length).toInt());
              // Далее — 5 следующих, не 8.
              final next = q.isEmpty
                  ? <Song>[]
                  : q.sublist((idx + 1).clamp(0, q.length).toInt(),
                      (idx + 6).clamp(0, q.length).toInt());
              final cur = q.isEmpty
                  ? p.currentSong
                  : q[idx.clamp(0, q.length - 1).toInt()];
              if (cur != null) _jumpToCurrent(idx, cur.id);
              _sheetCtrl = scrollCtrl;

              // Один ListView на контроллере шторки: свайп-вниз закрывает
              // (раньше NestedScrollView + второй контроллер глотали жест).
              return ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                children: [
                  _sheetHeader(ctx, p),
                  // Уже сыграли — приглушены, fade наверх
                  if (prev.isNotEmpty)
                    Opacity(
                      opacity: 0.55,
                      child: ShaderMask(
                        shaderCallback: (r) =>
                            const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black],
                          stops: [0.0, 0.45],
                        ).createShader(r),
                        blendMode: BlendMode.dstIn,
                        child: Column(
                          children: prev.asMap().entries.map((e) {
                            final i = idx - prev.length + e.key;
                            return _row(ctx, p, e.value, i,
                                dimmed: true);
                          }).toList(),
                        ),
                      ),
                    ),
                  // Текущий — подсвечен
                  if (cur != null)
                    _row(ctx, p, cur, idx, current: true),
                  // Далее в очереди — 5 шт
                  if (next.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(8, 12, 8, 6),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Далее в очереди',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.white70)),
                      ),
                    ),
                    ...next.asMap().entries.map((e) =>
                        _row(ctx, p, e.value, idx + 1 + e.key)),
                  ],
                  // Похожие с мозга + микс + похожие артисты (как в МТС:
                  // листаем ниже очереди, выход — свайп вниз или крестик).
                  if (cur != null) _similarTracks(ctx, p, cur),
                  if (cur != null) _mixCard(ctx, p, cur),
                  if (cur != null) _similarArtists(ctx, cur),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _sheetHeader(BuildContext ctx, PlayerProvider p) {
    // Контекст очереди как на десктопе (getActiveContext).
    final qctx = getActiveQueueContext(
      queueName: p.currentQueueName,
      queueHint: p.currentQueueHint,
      isRadio: p.isPlayingRadio,
      radioName: p.currentRadioStation?.name,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        Container(
            width: 36,
            height: 5,
            decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2.5))),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(qctx.kicker,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11)),
                    Text(qctx.title,
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.mic_rounded, color: Colors.white54),
                tooltip: 'Текст',
                onPressed: () {
                  // Сначала закрыть очередь, потом открыть текст —
                  // иначе шторки складываются (см. скрин с текстом).
                  final song = p.currentSong;
                  final cb = widget.onOpenLyrics;
                  Navigator.pop(ctx);
                  if (song != null && cb != null) {
                    Future.microtask(() => cb(song));
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white54),
                tooltip: 'Закрыть',
                onPressed: () => Navigator.pop(ctx),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext ctx, PlayerProvider p, Song s, int i,
      {bool current = false, bool dimmed = false}) {
    final svc = Provider.of<SubsonicService>(ctx, listen: false);
    String thumb = '';
    final ca = s.coverArt;
    if (ca != null) {
      if (ca.startsWith('http') || isLocalFilePath(ca)) {
        thumb = ca;
      } else if (ca.startsWith('abs:')) {
        thumb = AudiobookshelfService()
            .getCoverUrl(ca.substring(4), width: 100);
      } else {
        thumb = svc.getCoverArtUrl(ca, size: 100);
      }
    }
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => p.skipToIndex(i),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: current
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: current ? 48 : 44,
              height: current ? 48 : 44,
              decoration:
                  BoxDecoration(borderRadius: BorderRadius.circular(8)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: thumb.isEmpty
                    ? Container(
                        color: const Color(0xFF2A3542),
                        child: const Icon(Icons.music_note_rounded,
                            color: Colors.white24, size: 20))
                    : (isLocalFilePath(thumb)
                        ? Image.file(File(thumb),
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink())
                        : CachedNetworkImage(
                            imageUrl: thumb,
                            fit: BoxFit.cover,
                            fadeInDuration: Duration.zero,
                            fadeOutDuration: Duration.zero,
                            memCacheWidth: 112,
                            placeholder: (_, __) => Container(
                                color: const Color(0xFF2A3542),
                                child: const Icon(
                                    Icons.music_note_rounded,
                                    color: Colors.white24,
                                    size: 20)),
                            errorWidget: (_, __, ___) =>
                                const SizedBox.shrink())),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.title,
                      style: TextStyle(
                          fontWeight:
                              current ? FontWeight.w600 : FontWeight.w400,
                          fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(s.artist ?? '',
                      style: const TextStyle(
                          color: Colors.white60, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (dimmed)
              const SizedBox.shrink()
            else
              Text(_fmtSec(s.duration),
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  // ---------- Похожие треки с мозга (2 шт, только чтение) ----------
  // now-playing next[] (title/artist + reason) матчим к локальному кэшу;
  // недобор — subsonic.getSimilarSongs. Тап — играть одиночным.
  Widget _similarTracks(BuildContext ctx, PlayerProvider p, Song cur) {
    return FutureBuilder<List<_SimTrack>>(
      future: _simTracksCache.putIfAbsent(
          cur.id, () => _loadSimilarTracks(ctx, cur)),
      builder: (_, snap) {
        final list = snap.data ?? const <_SimTrack>[];
        if (list.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 12, 8, 6),
              child: Text('Похожие треки',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white70)),
            ),
            ...list.map((t) => _simRow(ctx, p, t)),
          ],
        );
      },
    );
  }

  Future<List<_SimTrack>> _loadSimilarTracks(
      BuildContext ctx, Song cur) async {
    final out = <_SimTrack>[];
    final seen = <String>{cur.id};
    // 1) Мозг: now-playing next (read-only).
    try {
      final bridge =
          Provider.of<KumaFlowBrainBridge>(ctx, listen: false);
      if (bridge.isActive && bridge.client != null) {
        final res = await bridge.client!
            .nowPlaying(bridge.settings.userId, n: 5)
            .timeout(const Duration(seconds: 6));
        final raw = res['next'];
        if (raw is List) {
          final lib =
              Provider.of<LibraryProvider>(ctx, listen: false);
          final all = lib.cachedAllSongs;
          for (final e in raw) {
            if (out.length >= 2) break;
            if (e is! Map) continue;
            final m = Map<String, dynamic>.from(e);
            final title = (m['title'] ?? '').toString().toLowerCase();
            final artist =
                (m['artist_name'] ?? '').toString().toLowerCase();
            final reason = (m['reason'] ?? '').toString();
            if (title.isEmpty) continue;
            for (final s in all) {
              if (!seen.add(s.id)) continue;
              if (s.title.toLowerCase() == title &&
                  (artist.isEmpty ||
                      (s.artist ?? '').toLowerCase() == artist)) {
                out.add(_SimTrack(s, reason));
                break;
              }
            }
          }
        }
      }
    } catch (_) {}
    // 2) Недобор — серверный similar (Last.fm, best-effort).
    if (out.length < 2) {
      try {
        final sub =
            Provider.of<SubsonicService>(ctx, listen: false);
        final sim = await sub
            .getSimilarSongs(cur.id, count: 10)
            .timeout(const Duration(seconds: 4), onTimeout: () => []);
        for (final s in sim) {
          if (out.length >= 2) break;
          if (!seen.add(s.id)) continue;
          out.add(_SimTrack(s, ''));
        }
      } catch (_) {}
    }
    // 3) Недобор — тот же жанр из локального кэша.
    if (out.length < 2) {
      try {
        final genre = (cur.genre ?? '').trim().toLowerCase();
        if (genre.isNotEmpty) {
          final lib =
              Provider.of<LibraryProvider>(ctx, listen: false);
          for (final s in lib.cachedAllSongs) {
            if (out.length >= 2) break;
            if (!seen.add(s.id)) continue;
            if ((s.genre ?? '').trim().toLowerCase() == genre) {
              out.add(_SimTrack(s, ''));
            }
          }
        }
      } catch (_) {}
    }
    return out;
  }

  Widget _simRow(BuildContext ctx, PlayerProvider p, _SimTrack t) {
    return _rowWithSubtitle(
      ctx,
      song: t.song,
      subtitle: t.reason.isNotEmpty ? t.reason : (t.song.artist ?? ''),
      onTap: () => p.playSong(t.song,
          playlist: [t.song], startIndex: 0),
    );
  }

  // ---------- Микс по треку (карточка как в МТС) ----------
  // Плей — волна по текущему треку (мозг, иначе похожие треки миксом).
  Widget _mixCard(BuildContext ctx, PlayerProvider p, Song cur) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _playTrackMix(ctx, cur),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Микс по треку',
                        style: TextStyle(
                            color: Colors.white54, fontSize: 11)),
                    const SizedBox(height: 2),
                    Text(cur.title,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow_rounded,
                    color: Colors.black, size: 28),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _playTrackMix(BuildContext ctx, Song cur) async {
    Navigator.pop(ctx);
    final navCtx = navigatorKey.currentContext;
    if (navCtx == null) return;
    final messenger = ScaffoldMessenger.of(navCtx);
    messenger.showSnackBar(
      const SnackBar(
          content: Text('Генерируем микс по треку...'),
          duration: Duration(seconds: 1)),
    );
    try {
      final sub = Provider.of<SubsonicService>(navCtx, listen: false);
      final bridge =
          Provider.of<KumaFlowBrainBridge>(navCtx, listen: false);
      final player = Provider.of<PlayerProvider>(navCtx, listen: false);
      if (bridge.isActive) {
        try {
          final tracks = await KumaFlowBrainPlayback.startTrackRadio(
            bridge: bridge,
            subsonic: sub,
            trackId: cur.id,
          ).timeout(const Duration(seconds: 75));
          if (tracks.isNotEmpty) {
            await player.playSong(tracks.first,
                playlist: tracks, startIndex: 0);
            return;
          }
        } catch (e) {
          debugPrint('[KumaFlowNew] mix brain failed, fallback: $e');
        }
      }
      final sim = await sub
          .getSimilarSongs(cur.id, count: 20)
          .timeout(const Duration(seconds: 6), onTimeout: () => []);
      final list = <Song>[cur];
      final seen = <String>{cur.id};
      for (final s in sim) {
        if (list.length >= 11) break;
        if (seen.add(s.id)) list.add(s);
      }
      if (list.length > 1) {
        await player.playSong(list.first,
            playlist: list, startIndex: 0);
      } else {
        messenger.showSnackBar(
            const SnackBar(content: Text('Не удалось собрать микс')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  // ---------- Похожие исполнители (кружки в ряд как в МТС) ----------
  // Круг с фото (кэш + прелоад), тап — страница артиста,
  // мини-плей — волна по артисту. Пусто — секции нет.
  final Map<String, Future<String?>> _artistImgCache = {};

  Widget _similarArtists(BuildContext ctx, Song cur) {
    return FutureBuilder<List<String>>(
      future: _simArtistsCache.putIfAbsent(
          cur.id, () => _loadSimilarArtists(ctx, cur)),
      builder: (_, snap) {
        final list = snap.data ?? const <String>[];
        if (list.isEmpty) return const SizedBox.shrink();
        for (final n in list) {
          _artistImgCache.putIfAbsent(n, () => _resolveSheetArtist(n));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 12, 8, 6),
              child: Text('Похожие исполнители',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white70)),
            ),
            SizedBox(
              height: 92,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: list.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: 12),
                itemBuilder: (_, i) =>
                    _artistCircle(ctx, list[i]),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _artistCircle(BuildContext ctx, String name) {
    return SizedBox(
      width: 64,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _openArtistByName(ctx, name),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: ClipOval(
                    child: FutureBuilder<String?>(
                      future: _artistImgCache[name],
                      builder: (_, snap) {
                        final u = snap.data ?? '';
                        if (u.isNotEmpty && u.startsWith('http')) {
                          return CachedNetworkImage(
                            imageUrl: u,
                            width: 56,
                            height: 56,
                            fit: BoxFit.cover,
                            fadeInDuration: Duration.zero,
                            fadeOutDuration: Duration.zero,
                            memCacheWidth: 128,
                            errorWidget: (_, __, ___) =>
                                _sheetInitials(name),
                          );
                        }
                        if (u.isNotEmpty) {
                          return _sheetInitials(name);
                        }
                        if (snap.connectionState ==
                            ConnectionState.waiting) {
                          return _sheetInitials(name, loading: true);
                        }
                        return _sheetInitials(name);
                      },
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _playArtistWaveByName(ctx, name),
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Colors.black54, width: 1),
                    ),
                    child: const Icon(Icons.play_arrow_rounded,
                        color: Colors.black, size: 14),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(name,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _sheetInitials(String name, {bool loading = false}) {
    final ch =
        name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3B4C63), Color(0xFF1E293B)],
        ),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white70),
              )
            : Text(ch,
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 20,
                    fontWeight: FontWeight.bold)),
      ),
    );
  }

  static final _sheetSplitRe = RegExp(
    r'\s*[/,;]\s*|\s+feat\.?\s+|\s+ft\.?\s+|\s+&\s+|\s+×\s+',
    caseSensitive: false,
  );

  /// Разбиваем "Cardi B/Kontra K" на отдельных исполнителей,
  /// иначе поиск фото по составной строке ничего не найдёт.
  static List<String> _splitName(String raw) {
    final parts = raw
        .split(_sheetSplitRe)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return parts.isEmpty ? [raw.trim()] : parts;
  }

  /// Фото артиста для кружка (только чтение): кэш библиотеки ->
  /// artist -> album cover (как дефолт: поиск альбомов по имени).
  Future<String?> _resolveSheetArtist(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    try {
      final navCtx = navigatorKey.currentContext;
      if (navCtx == null) return null;
      final sub =
          Provider.of<SubsonicService>(navCtx, listen: false);
      // 0) Мгновенно: обложка любого трека этого артиста из кэша.
      try {
        final lib =
            Provider.of<LibraryProvider>(navCtx, listen: false);
        final low = trimmed.toLowerCase();
        for (final s in lib.cachedAllSongs) {
          final parts = _splitName(s.artist ?? '');
          if (parts.any((a) => a.toLowerCase() == low)) {
            final ca = s.coverArt;
            if (ca != null && ca.isNotEmpty) {
              if (ca.startsWith('http') || isLocalFilePath(ca)) {
                return ca;
              }
              if (ca.startsWith('abs:')) {
                return AudiobookshelfService()
                    .getCoverUrl(ca.substring(4), width: 200);
              }
              return sub.getCoverArtUrl(ca, size: 200);
            }
          }
        }
      } catch (_) {}
      try {
        final r = await sub
            .search(trimmed,
                artistCount: 5, albumCount: 0, songCount: 0)
            .timeout(const Duration(seconds: 6));
        if (r.artists.isNotEmpty) {
          final m = r.artists.firstWhere(
            (a) => a.name.toLowerCase() == name.toLowerCase(),
            orElse: () => r.artists.first,
          );
          final direct = m.artistImageUrl;
          if (direct != null && direct.startsWith('http')) {
            return direct;
          }
          final ca = m.coverArt;
          if (ca != null && ca.isNotEmpty) {
            if (ca.startsWith('http')) return ca;
            return sub.getCoverArtUrl(ca, size: 200);
          }
        }
      } catch (_) {}
      try {
        final r = await sub
            .search(name, artistCount: 0, albumCount: 1, songCount: 0)
            .timeout(const Duration(seconds: 6));
        if (r.albums.isNotEmpty) {
          final ca = r.albums.first.coverArt;
          if (ca != null && ca.isNotEmpty) {
            if (ca.startsWith('http')) return ca;
            return sub.getCoverArtUrl(ca, size: 200);
          }
        }
      } catch (_) {}
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _loadSimilarArtists(
      BuildContext ctx, Song cur) async {
    // 1) Сид волны (read-only).
    try {
      final bridge =
          Provider.of<KumaFlowBrainBridge>(ctx, listen: false);
      if (bridge.isActive && bridge.client != null) {
        final res = await bridge.client!
            .waveSeedGet(bridge.settings.userId)
            .timeout(const Duration(seconds: 5));
        final raw =
            res['similar_artists'] ?? res['seed']?['similar_artists'];
        if (raw is List) {
          final names = <String>[];
          for (final e in raw) {
            if (names.length >= 4) break;
            if (e is String && e.trim().isNotEmpty) {
              names.add(e.trim());
            } else if (e is Map) {
              final m = Map<String, dynamic>.from(e);
              final n =
                  (m['name'] ?? m['artist_name'] ?? '').toString();
              if (n.trim().isNotEmpty) names.add(n.trim());
            }
          }
          if (names.isNotEmpty) return names;
        }
      }
    } catch (_) {}
    // 2) Артисты из похожих треков (без сида), составных разбиваем.
    final names = <String>[];
    final seen = <String>{(cur.artist ?? '').toLowerCase()};
    for (final part in _splitName(cur.artist ?? '')) {
      seen.add(part.toLowerCase());
    }
    try {
      final sub = Provider.of<SubsonicService>(ctx, listen: false);
      final sim = await sub
          .getSimilarSongs(cur.id, count: 10)
          .timeout(const Duration(seconds: 4), onTimeout: () => []);
      for (final s in sim) {
        if (names.length >= 4) break;
        for (final a in _splitName(s.artist ?? '')) {
          if (names.length >= 4) break;
          if (!seen.add(a.toLowerCase())) continue;
          names.add(a);
        }
      }
    } catch (_) {}
    // 3) Тот же жанр из локального кэша.
    if (names.length < 4) {
      try {
        final genre = (cur.genre ?? '').trim().toLowerCase();
        if (genre.isNotEmpty) {
          final lib =
              Provider.of<LibraryProvider>(ctx, listen: false);
          for (final s in lib.cachedAllSongs) {
            if (names.length >= 4) break;
            if ((s.genre ?? '').trim().toLowerCase() != genre) {
              continue;
            }
            for (final a in _splitName(s.artist ?? '')) {
              if (names.length >= 4) break;
              if (!seen.add(a.toLowerCase())) continue;
              names.add(a);
            }
          }
        }
      } catch (_) {}
    }
    return names;
  }

  /// Волна по артисту из кружка: мозг, иначе топ треки вперемешку.
  /// Шторку закрываем первой, дальше как _playArtistWave у плеера.
  Future<void> _playArtistWaveByName(BuildContext ctx, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    Navigator.pop(ctx);
    final navCtx = navigatorKey.currentContext;
    if (navCtx == null) return;
    final messenger = ScaffoldMessenger.of(navCtx);
    messenger.showSnackBar(
      SnackBar(
          content: Text('Волна по $trimmed...'),
          duration: const Duration(seconds: 1)),
    );
    try {
      final sub = Provider.of<SubsonicService>(navCtx, listen: false);
      final bridge =
          Provider.of<KumaFlowBrainBridge>(navCtx, listen: false);
      final player = Provider.of<PlayerProvider>(navCtx, listen: false);
      if (bridge.isActive) {
        try {
          final tracks = await KumaFlowBrainPlayback.startArtistRadio(
            bridge: bridge,
            subsonic: sub,
            artistName: trimmed,
          ).timeout(const Duration(seconds: 12));
          if (tracks.isNotEmpty) {
            await player.playSong(tracks.first,
                playlist: tracks, startIndex: 0);
            messenger.showSnackBar(
              SnackBar(
                  content: Text(
                      'Волна по $trimmed: ${tracks.length} треков'),
                  duration: const Duration(seconds: 2)),
            );
            return;
          }
        } catch (_) {}
      }
      final found = await sub
          .search(trimmed, artistCount: 5, albumCount: 0, songCount: 0)
          .timeout(const Duration(seconds: 8));
      if (found.artists.isEmpty) {
        messenger.showSnackBar(
            SnackBar(content: Text('Артист не найден: $trimmed')));
        return;
      }
      final matched = found.artists.firstWhere(
        (a) => a.name.toLowerCase() == trimmed.toLowerCase(),
        orElse: () => found.artists.first,
      );
      final tracks = await sub
          .getArtistTopSongs(matched.id, count: 25)
          .timeout(const Duration(seconds: 8));
      if (tracks.isEmpty) {
        messenger.showSnackBar(
            const SnackBar(content: Text('Треки артиста не найдены')));
        return;
      }
      tracks.shuffle();
      await player.playSong(tracks.first,
          playlist: tracks, startIndex: 0);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  Future<void> _openArtistByName(BuildContext ctx, String name) async {    Navigator.pop(ctx);
    await Future.microtask(() {});
    final navCtx = navigatorKey.currentContext;
    if (navCtx == null || !context.mounted) return;
    try {
      final subsonic =
          Provider.of<SubsonicService>(navCtx, listen: false);
      final result = await subsonic.search(name,
          artistCount: 5, albumCount: 0, songCount: 0);
      if (result.artists.isEmpty) return;
      final matched = result.artists.firstWhere(
        (a) => a.name.toLowerCase() == name.toLowerCase(),
        orElse: () => result.artists.first,
      );
      if (!context.mounted) return;
      NavigationHelper.push(
        navigatorKey.currentContext ?? context,
        ArtistScreen(artistId: matched.id),
      );
    } catch (_) {}
  }

  Widget _rowWithSubtitle(BuildContext ctx,
      {required Song song,
      required String subtitle,
      required VoidCallback onTap}) {
    final svc = Provider.of<SubsonicService>(ctx, listen: false);
    String thumb = '';
    final ca = song.coverArt;
    if (ca != null) {
      if (ca.startsWith('http') || isLocalFilePath(ca)) {
        thumb = ca;
      } else if (ca.startsWith('abs:')) {
        thumb = AudiobookshelfService()
            .getCoverUrl(ca.substring(4), width: 100);
      } else {
        thumb = svc.getCoverArtUrl(ca, size: 100);
      }
    }
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration:
                  BoxDecoration(borderRadius: BorderRadius.circular(8)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: thumb.isEmpty
                    ? Container(
                        color: const Color(0xFF2A3542),
                        child: const Icon(Icons.music_note_rounded,
                            color: Colors.white24, size: 20))
                    : CachedNetworkImage(
                        imageUrl: thumb,
                        fit: BoxFit.cover,
                        fadeInDuration: Duration.zero,
                        fadeOutDuration: Duration.zero,
                        memCacheWidth: 112,
                        placeholder: (_, __) => Container(
                            color: const Color(0xFF2A3542),
                            child: const Icon(
                                Icons.music_note_rounded,
                                color: Colors.white24,
                                size: 20)),
                        errorWidget: (_, __, ___) =>
                            const SizedBox.shrink()),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(song.title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w400, fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          color: Colors.white60, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const Icon(Icons.play_arrow_rounded,
                color: Colors.white54, size: 22),
          ],
        ),
      ),
    );
  }
}

/// Похожий трек с причиной («почему похоже» с мозга).
class _SimTrack {
  final Song song;
  final String reason;
  const _SimTrack(this.song, this.reason);
}

/// Правая панель горизонтального layout: табы очередь/текст
/// (как десктопный ContextPanel: context ↔ lyrics, без шторок).
class _ContextPanelKfn extends StatelessWidget {
  final String panel;
  final ValueChanged<String> onPanelChanged;
  final Song? song;
  final String imgUrl;
  const _ContextPanelKfn({
    required this.panel,
    required this.onPanelChanged,
    required this.song,
    required this.imgUrl,
  });

  String _fmtSec(int? sec) {
    if (sec == null || sec <= 0) return '';
    return '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (ctx, p, _) {
        final q = p.queue;
        final idx =
            q.isEmpty ? 0 : p.currentIndex.clamp(0, q.length - 1).toInt();
        final prev = q.isEmpty
            ? <Song>[]
            : q.sublist((idx - 3).clamp(0, q.length).toInt(),
                idx.clamp(0, q.length).toInt());
        final next = q.isEmpty
            ? <Song>[]
            : q.sublist((idx + 1).clamp(0, q.length).toInt(),
                (idx + 9).clamp(0, q.length).toInt());
        final cur = q.isEmpty
            ? p.currentSong
            : q[idx.clamp(0, q.length - 1).toInt()];
        final svc = Provider.of<SubsonicService>(ctx, listen: false);

        Widget thumb(Song s, double sz) {
          String t = '';
          final ca = s.coverArt;
          if (ca != null) {
            if (ca.startsWith('http') || isLocalFilePath(ca)) {
              t = ca;
            } else if (ca.startsWith('abs:')) {
              t = AudiobookshelfService()
                  .getCoverUrl(ca.substring(4), width: 100);
            } else {
              t = svc.getCoverArtUrl(ca, size: 100);
            }
          }
          return Container(
            width: sz,
            height: sz,
            decoration:
                BoxDecoration(borderRadius: BorderRadius.circular(8)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: t.isEmpty
                  ? Container(
                      color: const Color(0xFF2A3542),
                      child: const Icon(Icons.music_note_rounded,
                          color: Colors.white24, size: 18))
                  : (isLocalFilePath(t)
                      ? Image.file(File(t),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              const SizedBox.shrink())
                      : CachedNetworkImage(
                          imageUrl: t,
                          fit: BoxFit.cover,
                          fadeInDuration: Duration.zero,
                          fadeOutDuration: Duration.zero,
                          memCacheWidth: 112,
                          placeholder: (_, __) => Container(
                              color: const Color(0xFF2A3542),
                              child: const Icon(
                                  Icons.music_note_rounded,
                                  color: Colors.white24,
                                  size: 18)),
                          errorWidget: (_, __, ___) =>
                              const SizedBox.shrink())),
            ),
          );
        }

        Widget row(Song s, int i,
            {bool current = false, bool dimmed = false}) {
          return InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => p.skipToIndex(i),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: current
                    ? Colors.white.withValues(alpha: 0.10)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Opacity(
                      opacity: dimmed ? 0.7 : 1.0,
                      child: thumb(s, current ? 48 : 44)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.title,
                            style: TextStyle(
                                fontWeight: current
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                fontSize: 14,
                                color: Colors.white),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        Text(s.artist ?? '',
                            style: const TextStyle(
                                color: Colors.white60, fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  Text(_fmtSec(s.duration),
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12)),
                ],
              ),
            ),
          );
        }

        // Контекст очереди как на десктопе (getActiveContext).
        final qctx = getActiveQueueContext(
          queueName: p.currentQueueName,
          queueHint: p.currentQueueHint,
          isRadio: p.isPlayingRadio,
          radioName: p.currentRadioStation?.name,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(qctx.kicker,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11)),
                      Text(qctx.title,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                _tabBtn(
                    icon: Icons.list_rounded,
                    tooltip: 'Очередь',
                    selected: panel != 'lyrics',
                    onTap: () => onPanelChanged('queue')),
                const SizedBox(width: 4),
                _tabBtn(
                    icon: Icons.mic_rounded,
                    tooltip: 'Текст',
                    selected: panel == 'lyrics',
                    onTap: () => onPanelChanged('lyrics')),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: panel == 'lyrics' && song != null
                  // Текст инлайн в панели (как 3-й скрин десктопа),
                  // отдельная шторка не выезжает.
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SyncedLyricsView(
                          song: song!,
                          imageUrl: imgUrl,
                          // Без своих кнопок/прогресса: иначе дубль
                          // слайдера и плей как на скрине 4.
                          showControls: false),
                    )
                  : ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        if (prev.isNotEmpty)
                          Opacity(
                            opacity: 0.55,
                            child: Column(
                              children: prev
                                  .asMap()
                                  .entries
                                  .map((e) => row(
                                      e.value,
                                      idx - prev.length + e.key,
                                      dimmed: true))
                                  .toList(),
                            ),
                          ),
                        if (cur != null) row(cur, idx, current: true),
                        if (next.isNotEmpty) ...[
                          const Padding(
                            padding: EdgeInsets.fromLTRB(8, 12, 8, 6),
                            child: Text('Далее в очереди',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white70)),
                          ),
                          ...next
                              .asMap()
                              .entries
                              .map((e) => row(e.value, idx + 1 + e.key)),
                        ],
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _tabBtn(
      {required IconData icon,
      required String tooltip,
      required bool selected,
      required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF4E8CA8).withValues(alpha: 0.9)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon,
            size: 18,
            color: selected ? Colors.white : Colors.white60),
      ),
    );
  }
}

/// Строка оценки звёздами с живым обновлением (top-level: классам нельзя
/// жить внутри State). Локальный _local + подтверждённое провайдером —
/// тапы больше не сбрасываются на старое значение при ребилде.
class _RatingRow extends StatefulWidget {
  final Song song;
  const _RatingRow({required this.song});

  @override
  State<_RatingRow> createState() => _RatingRowState();
}

class _RatingRowState extends State<_RatingRow> {
  int? _local;

  @override
  Widget build(BuildContext context) {
    int shown = _local ?? widget.song.userRating ?? 0;
    try {
      final cur = context.watch<PlayerProvider>().currentSong;
      if (cur != null && cur.id == widget.song.id) {
        shown = cur.userRating ?? _local ?? widget.song.userRating ?? 0;
      }
    } catch (_) {}
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.star_rounded, color: Colors.white),
          const SizedBox(width: 16),
          const Expanded(
            child: Text('Оценка',
                style: TextStyle(color: Colors.white, fontSize: 15)),
          ),
          StarRatingWidget(
            rating: shown,
            size: 26,
            onRatingChanged: (r) async {
              setState(() => _local = r);
              try {
                await context
                    .read<PlayerProvider>()
                    .setRating(widget.song.id, r);
              } catch (_) {}
            },
          ),
        ],
      ),
    );
  }
}
