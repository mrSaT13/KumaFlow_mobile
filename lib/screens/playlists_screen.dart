import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../services/theme_service.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../widgets/widgets.dart';
import '../widgets/app_gradient_background.dart';
import 'playlist_screen.dart';

class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final libraryProvider = Provider.of<LibraryProvider>(context);
    final theme = Theme.of(context);

    return Scaffold(backgroundColor: Colors.transparent, 
      appBar: AppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),
        title: Text(AppLocalizations.of(context)!.playlists),
        actions: [
          IconButton(
            icon: const Icon(CupertinoIcons.add),
            onPressed: () => _showCreatePlaylistDialog(context),
          ),
        ],
      ),
      body: Builder(
        builder: (ctx) {
          // Виртуальные плейлисты из добавленных локальных папок — только
          // чтение (без удаления на сервере), открываются тем же экраном.
          final localPls = libraryProvider.localFolderPlaylists;
          final serverPls = libraryProvider.playlists;
          if (localPls.isEmpty && serverPls.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    CupertinoIcons.music_note_list,
                    size: 64,
                    color: AppTheme.lightSecondaryText,
                  ),
                  const SizedBox(height: 16),
                  Text(AppLocalizations.of(context)!.noPlaylists, style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 8),
                  Text(
                    AppLocalizations.of(context)!.createPlaylistToStart,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppTheme.lightSecondaryText,
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () => _showCreatePlaylistDialog(context),
                    icon: const Icon(CupertinoIcons.add),
                    label: Text(AppLocalizations.of(context)!.newPlaylist),
                    style: ElevatedButton.styleFrom(
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 150),
            children: [
              if (localPls.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'Локальные папки',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ...localPls.map(
                  (playlist) => _PlaylistTile(
                    playlist: playlist,
                    onTap: () => _openPlaylist(context, playlist),
                    // без long-press: виртуальный плейлист удалять нечего
                  ),
                ),
              ],
              if (serverPls.isNotEmpty) ...[
                if (localPls.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      AppLocalizations.of(context)!.playlists,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ...serverPls.map(
                  (playlist) => _PlaylistTile(
                    playlist: playlist,
                    onTap: () => _openPlaylist(context, playlist),
                    onLongPress: () =>
                        _showPlaylistOptions(context, playlist),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  void _openPlaylist(BuildContext context, Playlist playlist) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PlaylistScreen(
          playlistId: playlist.id,
          playlistName: playlist.name,
        ),
      ),
    );
  }

  Future<void> _showCreatePlaylistDialog(BuildContext context) async {
    final controller = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              if (controller.text.trim().isNotEmpty) {
                final libraryProvider = Provider.of<LibraryProvider>(
                  context,
                  listen: false,
                );
                await libraryProvider.createPlaylist(controller.text.trim());
                if (context.mounted) {
                  Navigator.pop(context);
                }
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  void _showPlaylistOptions(BuildContext context, Playlist playlist) {
    final libraryProvider = Provider.of<LibraryProvider>(
      context,
      listen: false,
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkSurface : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
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
                  color: isDark ? AppTheme.darkDivider : AppTheme.lightDivider,
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(CupertinoIcons.trash, color: Colors.red),
                title: Text(AppLocalizations.of(context)!.deletePlaylist),
                onTap: () async {
                  Navigator.pop(context);
                  await libraryProvider.deletePlaylist(playlist.id);
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  final Playlist playlist;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _PlaylistTile({required this.playlist, this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: playlist.coverArt != null
            ? AlbumArtwork(
                coverArt: playlist.coverArt,
                size: 64,
                borderRadius: 10,
              )
            : Icon(
                CupertinoIcons.music_note_list,
                color: accent,
                size: 30,
              ),
      ),
      title: Text(
        playlist.name,
        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${playlist.songCount ?? 0} треков • ${playlist.formattedDuration}',
            style: theme.textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (playlist.comment != null && playlist.comment!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                playlist.comment!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  color: isDark ? Colors.white60 : Colors.black54,
                  fontStyle: FontStyle.italic,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
      trailing: Icon(
        CupertinoIcons.chevron_right,
        size: 18,
        color: isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText,
      ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
