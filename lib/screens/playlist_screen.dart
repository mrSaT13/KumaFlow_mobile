import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../services/subsonic_service.dart';
import '../services/theme_service.dart';
import '../services/offline_service.dart';
import '../services/favorite_playlists_service.dart';
import '../theme/app_theme.dart';
import '../widgets/widgets.dart';
import '../widgets/app_gradient_background.dart';
import '../l10n/app_localizations.dart';
import '../utils/screen_helper.dart';

class PlaylistScreen extends StatefulWidget {
  final String playlistId;
  final String? playlistName;

  const PlaylistScreen({
    super.key,
    required this.playlistId,
    this.playlistName,
  });

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  Playlist? _playlist;
  bool _isLoading = true;
  bool _isDownloading = false;
  bool _isSelecting = false;
  bool _isReordering = false;
  // null = ещё не проверяли (маркер+файлы), true = всё скачано.
  bool? _playlistDownloaded;
  final Set<int> _selectedIndices = {};

  @override
  void initState() {
    super.initState();
    _loadPlaylist();
  }

  Future<void> _loadPlaylist() async {
    final libraryProvider = Provider.of<LibraryProvider>(
      context,
      listen: false,
    );

    try {
      final playlist = await libraryProvider.getPlaylist(widget.playlistId);
      if (mounted) {
        setState(() {
          _playlist = playlist;
          _isLoading = false;
        });
        unawaited(_refreshDownloadState());
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Честная проверка: маркер + ВСЕ файлы на диске. Без этого иконка врала.
  Future<void> _refreshDownloadState() async {
    final songs = _playlist?.songs;
    if (songs == null || songs.isEmpty) {
      if (mounted) setState(() => _playlistDownloaded = false);
      return;
    }
    try {
      final off = OfflineService();
      await off.initialize();
      final marker = off.isPlaylistDownloaded(widget.playlistId);
      final done = off.countDownloadedTracks(songs);
      final all = done >= songs.length;
      if (mounted) setState(() => _playlistDownloaded = marker && all);
    } catch (_) {
      if (mounted) setState(() => _playlistDownloaded = false);
    }
  }

  void _playAll({bool shuffle = false}) {
    if (_playlist?.songs == null || _playlist!.songs!.isEmpty) return;

    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);

    var songs = List.from(_playlist!.songs!);
    if (shuffle) {
      songs.shuffle();
    }

    // Имя плейлиста — в шапку очереди (иначе «Моя коллекция»).
    final qName = _playlist?.name?.trim().isNotEmpty == true
        ? _playlist!.name.trim()
        : 'Плейлист';
    playerProvider.playSong(
      songs.first,
      playlist: songs.cast(),
      startIndex: 0,
      playlistName: qName,
    );
  }

  Future<void> _removeSongFromPlaylist(int index) async {
    final subsonicService = Provider.of<SubsonicService>(
      context,
      listen: false,
    );
    try {
      await subsonicService.updatePlaylist(
        playlistId: widget.playlistId,
        songIndexesToRemove: [index],
      );
      setState(() {
        final updatedSongs = List<Song>.from(_playlist!.songs!)
          ..removeAt(index);
        _playlist = _playlist!.copyWith(
          songCount: updatedSongs.length,
          songs: updatedSongs,
        );
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Song removed from playlist'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error removing song: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _toggleSelectMode() {
    setState(() {
      _isSelecting = !_isSelecting;
      _isReordering = false;
      _selectedIndices.clear();
    });
  }

  void _toggleReorderMode() {
    setState(() {
      _isReordering = !_isReordering;
      _isSelecting = false;
      _selectedIndices.clear();
    });
  }

  Future<void> _onSongReordered(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;

    final subsonicService = Provider.of<SubsonicService>(
      context,
      listen: false,
    );

    setState(() {
      final updatedSongs = List<Song>.from(_playlist!.songs!);
      final song = updatedSongs.removeAt(oldIndex);
      updatedSongs.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, song);
      _playlist = _playlist!.copyWith(songs: updatedSongs);
    });

    try {
      await subsonicService.updatePlaylist(
        playlistId: widget.playlistId,
        songIndexesToRemove: [oldIndex],
        songIdsToAdd: [
          _playlist!.songs![newIndex > oldIndex ? newIndex - 1 : newIndex].id,
        ],
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error reordering song: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      _loadPlaylist();
    }
  }

  void _toggleSelection(int index) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        _selectedIndices.remove(index);
      } else {
        _selectedIndices.add(index);
      }
    });
  }

  void _toggleSelectAll() {
    final songCount = _playlist?.songs?.length ?? 0;
    setState(() {
      if (_selectedIndices.length == songCount) {
        _selectedIndices.clear();
      } else {
        _selectedIndices.addAll(List.generate(songCount, (i) => i));
      }
    });
  }

  Future<void> _removeSelected() async {
    if (_selectedIndices.isEmpty) return;
    final count = _selectedIndices.length;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(ctx)!.removeSongs),
        content: Text(
          AppLocalizations.of(ctx)!.removeSongsConfirm(count),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppLocalizations.of(ctx)!.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppLocalizations.of(ctx)!.remove, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final subsonicService = Provider.of<SubsonicService>(
      context,
      listen: false,
    );

    // Sort descending so we can remove from end first without shifting indices
    final sortedIndices = _selectedIndices.toList()
      ..sort((a, b) => b.compareTo(a));

    try {
      await subsonicService.updatePlaylist(
        playlistId: widget.playlistId,
        songIndexesToRemove: sortedIndices,
      );
      setState(() {
        final updatedSongs = List<Song>.from(_playlist!.songs!);
        for (final idx in sortedIndices) {
          updatedSongs.removeAt(idx);
        }
        _playlist = _playlist!.copyWith(
          songCount: updatedSongs.length,
          songs: updatedSongs,
        );
        _selectedIndices.clear();
        _isSelecting = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$count ${count == 1 ? 'song' : 'songs'} removed from playlist',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error removing songs: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _toggleFavorite() async {
    if (_playlist == null) return;
    await FavoritePlaylistsService().toggleFavorite(widget.playlistId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            FavoritePlaylistsService().isFavorite(widget.playlistId)
                ? 'Added to favorites'
                : 'Removed from favorites',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _downloadPlaylist() async {
    final songs = _playlist?.songs;
    if (songs == null || songs.isEmpty) return;

    final subsonicService = Provider.of<SubsonicService>(
      context,
      listen: false,
    );
    final offlineService = OfflineService();
    await offlineService.initialize();

    setState(() => _isDownloading = true);

    final playlistId = widget.playlistId;
    try {
      // downloadPlaylist качает по одному с верификацией и ставит маркер
      // только когда ВСЕ треки на диске (иначе маркер снимается).
      final ok = await offlineService.downloadPlaylist(
        playlistId: playlistId,
        tracks: songs,
        subsonicService: subsonicService,
      );
      final done = offlineService.countDownloadedTracks(songs);
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _playlistDownloaded = ok;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok
                ? 'Скачано ${songs.length} треков из ${_playlist!.name}'
                : 'Скачано $done из ${songs.length} — проверь соединение и место'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      await _refreshDownloadState();
      if (mounted) {
        setState(() => _isDownloading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка скачивания: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (_isLoading) {
      return Scaffold(backgroundColor: Colors.transparent, 
        appBar: AppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),
          title:
              widget.playlistName != null ? Text(widget.playlistName!) : null,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_playlist == null) {
      return Scaffold( 
        appBar: AppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),),
        body: Center(child: Text(AppLocalizations.of(context)!.playlistNotFound)),
      );
    }

    final isOffline = Provider.of<AuthProvider>(context, listen: false).state ==
        AuthState.offlineMode;

    if (_isReordering) {
      return Scaffold( 
        appBar: AppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),
          title: const Text('Reorder Songs'),
          leading: IconButton(
            icon: const Icon(CupertinoIcons.xmark),
            onPressed: _toggleReorderMode,
          ),
          actions: [
            IconButton(
              tooltip: 'Done reordering',
              icon: const Icon(CupertinoIcons.checkmark),
              onPressed: _toggleReorderMode,
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Container(
                    width: 160,
                    height: 160,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: _playlist!.coverArt != null
                        ? AlbumArtwork(
                            coverArt: _playlist!.coverArt,
                            size: 160,
                            borderRadius: 12,
                          )
                        : Icon(
                            CupertinoIcons.music_note_list,
                            color: Theme.of(context).colorScheme.primary,
                            size: 64,
                          ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _playlist!.name,
                    style: theme.textTheme.headlineMedium,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_playlist!.songs?.length ?? 0} треков • ${_playlist!.formattedDuration}',
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_playlist!.comment != null && _playlist!.comment!.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _playlist!.comment!,
                        style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic, color: isDark ? Colors.white70 : Colors.black54),
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _CircleIconButton(icon: CupertinoIcons.play_fill, onTap: () => _playAll(), primary: true, size: 52),
                      const SizedBox(width: 14),
                      _CircleIconButton(icon: CupertinoIcons.shuffle, onTap: () => _playAll(shuffle: true), primary: false, size: 52),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ReorderableListView.builder(
                padding: const EdgeInsets.only(bottom: 150),
                itemCount: _playlist!.songs!.length,
                buildDefaultDragHandles: false,
                onReorder: _onSongReordered,
                itemBuilder: (context, index) {
                  final song = _playlist!.songs![index];
                  return ListTile(
                    key: ValueKey('reorder_${song.id}_$index'),
                    leading: ReorderableDragStartListener(
                      index: index,
                      child: Icon(
                        CupertinoIcons.line_horizontal_3,
                        color: isDark
                            ? AppTheme.darkSecondaryText
                            : AppTheme.lightSecondaryText,
                      ),
                    ),
                    title: Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      song.artist ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );
    }

    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold( 
      body: CustomScrollView(
        slivers: [
          SliverAppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.85) : Colors.white.withValues(alpha: 0.9), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),
            pinned: true,
            expandedHeight: ScreenHelper.isSmallScreen(context) ? 360 : 420,
            leading: IconButton(
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.black.withValues(alpha: 0.5)
                      : Colors.white.withValues(alpha: 0.7),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  CupertinoIcons.back,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: isDark
                            ? [accent.withValues(alpha: 0.28), Colors.black.withValues(alpha: 0.6)]
                            : [accent.withValues(alpha: 0.14), Colors.white.withValues(alpha: 0.9)],
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(
                      top: MediaQuery.of(context).padding.top + 50,
                      left: ScreenHelper.isSmallScreen(context) ? 24 : 36,
                      right: ScreenHelper.isSmallScreen(context) ? 24 : 36,
                      bottom: ScreenHelper.isSmallScreen(context) ? 40 : 48,
                    ),
                    child: Center(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 20, offset: const Offset(0, 8)),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: _playlist!.coverArt != null
                              ? AlbumArtwork(
                                  coverArt: _playlist!.coverArt,
                                  size: ScreenHelper.isSmallScreen(context) ? 240 : 260,
                                  borderRadius: 16,
                                )
                              : Container(
                                  width: ScreenHelper.isSmallScreen(context) ? 240 : 260,
                                  height: ScreenHelper.isSmallScreen(context) ? 240 : 260,
                                  decoration: BoxDecoration(
                                    color: accent.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Icon(CupertinoIcons.music_note_list, color: accent, size: 72),
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              if (_isSelecting) ...[
                IconButton(
                  tooltip:
                      _selectedIndices.length == (_playlist?.songs?.length ?? 0)
                          ? 'Deselect all'
                          : 'Select all',
                  icon: Icon(
                    _selectedIndices.length == (_playlist?.songs?.length ?? 0)
                        ? CupertinoIcons.checkmark_square
                        : CupertinoIcons.square,
                  ),
                  onPressed: _toggleSelectAll,
                ),
                IconButton(
                  tooltip: 'Remove selected',
                  icon: const Icon(CupertinoIcons.trash),
                  color: _selectedIndices.isNotEmpty ? Colors.red : null,
                  onPressed:
                      _selectedIndices.isNotEmpty ? _removeSelected : null,
                ),
              ] else ...[
                AnimatedBuilder(
                  animation: FavoritePlaylistsService(),
                  builder: (context, child) {
                    final isFavorite = FavoritePlaylistsService()
                        .isFavorite(widget.playlistId);
                    return IconButton(
                      tooltip: isFavorite
                          ? 'Remove from favorites'
                          : 'Add to favorites',
                      icon: Icon(
                        isFavorite
                            ? CupertinoIcons.heart_fill
                            : CupertinoIcons.heart,
                        color: isFavorite ? Colors.red : null,
                      ),
                      onPressed: _toggleFavorite,
                    );
                  },
                ),
                IconButton(
                  tooltip: 'Reorder songs',
                  icon: const Icon(CupertinoIcons.arrow_up_arrow_down),
                  onPressed:
                      _playlist!.songs != null && _playlist!.songs!.length > 1
                          ? _toggleReorderMode
                          : null,
                ),
                IconButton(
                  tooltip: 'Select songs',
                  icon: const Icon(CupertinoIcons.checkmark_circle),
                  onPressed: _toggleSelectMode,
                ),
                // Локальные папки уже на диске — качать нечего.
                if (!isOffline &&
                    !widget.playlistId.startsWith('local-folder:'))
                  IconButton(
                    tooltip: _playlistDownloaded == true
                        ? 'Скачано — нажать для проверки/докачки'
                        : 'Download playlist',
                    onPressed: _isDownloading ? null : _downloadPlaylist,
                    icon: _isDownloading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _playlistDownloaded == true
                                ? CupertinoIcons.cloud_fill
                                : CupertinoIcons.cloud_download,
                            color: _playlistDownloaded == true
                                ? const Color(0xFF34C759)
                                : null,
                          ),
                  ),
              ],
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    _playlist!.name,
                    style: theme.textTheme.headlineMedium,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_playlist!.songs?.length ?? 0} треков • ${_playlist!.formattedDuration}',
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_playlist!.comment != null && _playlist!.comment!.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _playlist!.comment!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 13,
                          color: isDark ? Colors.white70 : Colors.black54,
                          fontStyle: FontStyle.italic,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _CircleIconButton(
                        icon: CupertinoIcons.play_fill,
                        onTap: () => _playAll(),
                        primary: true,
                        size: 56,
                      ),
                      const SizedBox(width: 16),
                      _CircleIconButton(
                        icon: CupertinoIcons.shuffle,
                        onTap: () => _playAll(shuffle: true),
                        primary: false,
                        size: 56,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: Divider()),
          if (_playlist!.songs?.isEmpty ?? true)
            SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: Text(
                    'No songs in this playlist',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppTheme.lightSecondaryText,
                    ),
                  ),
                ),
              ),
            )
          else if (_isSelecting)
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final song = _playlist!.songs![index];
                  final isSelected = _selectedIndices.contains(index);
                  return CheckboxListTile(
                    key: ValueKey('sel_${song.id}_$index'),
                    value: isSelected,
                    onChanged: (_) => _toggleSelection(index),
                    activeColor: Theme.of(context).colorScheme.primary,
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: const EdgeInsets.only(
                      left: 4,
                      right: 16,
                    ),
                    title: Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      song.artist ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    secondary: IconButton(
                      icon: const Icon(CupertinoIcons.trash, size: 20),
                      color: Colors.red,
                      tooltip: 'Remove from playlist',
                      onPressed: () async {
                        setState(() => _selectedIndices.remove(index));
                        await _removeSongFromPlaylist(index);
                      },
                    ),
                  );
                },
                childCount: _playlist!.songs!.length,
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final song = _playlist!.songs![index];
                  final tile = SongTile(
                    song: song,
                    playlist: _playlist!.songs,
                    index: index,
                    showArtist: true,
                    onLongPress: () {
                      _toggleSelectMode();
                      _toggleSelection(index);
                    },
                  );
                  return Dismissible(
                    key: ValueKey('${song.id}_$index'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      color: Colors.red,
                      child: const Icon(
                        CupertinoIcons.trash,
                        color: Colors.white,
                      ),
                    ),
                    confirmDismiss: (_) async {
                      return await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Remove from playlist'),
                              content: Text(
                                'Remove "${song.title}" from this playlist?',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text(
                                    'Remove',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                ),
                              ],
                            ),
                          ) ??
                          false;
                    },
                    onDismissed: (_) => _removeSongFromPlaylist(index),
                    child: tile,
                  );
                },
                childCount: _playlist!.songs!.length,
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 150)),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  const _PlayButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = Theme.of(context).colorScheme.primary;

    if (primary) {
      return Material(
        color: accent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(CupertinoIcons.play_fill, color: Colors.white, size: 18),
                const SizedBox(width: 6),
                Text(label, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      );
    }
    return Material(
      color: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: isDark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.08))),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: isDark ? Colors.white : Colors.black87, size: 18),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 15, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool primary;
  final double size;
  const _CircleIconButton({required this.icon, required this.onTap, this.primary = false, this.size = 56});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = Theme.of(context).colorScheme.primary;
    if (primary) {
      return Material(
        color: accent,
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: size,
            height: size,
            child: const Icon(CupertinoIcons.play_fill, color: Colors.white, size: 26),
          ),
        ),
      );
    }
    return Material(
      color: isDark ? Colors.white.withValues(alpha: 0.10) : Colors.black.withValues(alpha: 0.07),
      shape: CircleBorder(side: BorderSide(color: isDark ? Colors.white.withValues(alpha: 0.14) : Colors.black.withValues(alpha: 0.10))),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: isDark ? Colors.white : Colors.black87, size: 22),
        ),
      ),
    );
  }
}
