import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../widgets/app_gradient_background.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../models/models.dart';
import '../services/subsonic_service.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';
import '../utils/navigation_helper.dart';
import 'album_screen.dart';
import 'artist_screen.dart';
import 'playlist_screen.dart';

class LibrarySearchDelegate extends SearchDelegate<String> {
  final LibraryProvider libraryProvider;
  final bool isDark;

  LibrarySearchDelegate({required this.libraryProvider, required this.isDark, String? searchFieldHint})
      : super(
          searchFieldLabel: searchFieldHint ?? 'Search in Library...',
          searchFieldStyle: TextStyle(
            color: isDark ? Colors.white : Colors.black,
          ),
        );

  @override
  ThemeData appBarTheme(BuildContext context) {
    final theme = Theme.of(context);
    return theme.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0.5,
        iconTheme: IconThemeData(color: isDark ? Colors.white : Colors.black),
      ),
      inputDecorationTheme: InputDecorationTheme(
        hintStyle: TextStyle(color: isDark ? Colors.white54 : Colors.black45),
      ),
    );
  }

  @override
  List<Widget> buildActions(BuildContext context) {
    return [
      if (query.isNotEmpty)
        IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
    ];
  }

  @override
  Widget buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () => close(context, ''),
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    return _buildSearchResults(context);
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    if (query.isEmpty) {
      final l10n = AppLocalizations.of(context)!;
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              CupertinoIcons.search,
              size: 64,
              color: isDark ? Colors.white38 : Colors.black26,
            ),
            const SizedBox(height: 16),
            Text(
              l10n.searchHint,
              style: TextStyle(
                color: isDark ? Colors.white54 : Colors.black45,
                fontSize: 16,
              ),
            ),
          ],
        ),
      );
    }
    return _buildSearchResults(context);
  }

  Widget _buildSearchResults(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final lowerQuery = query.toLowerCase();
    final results = libraryProvider.search(query);

    return FutureBuilder<SearchResult>(
      future: results,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final searchResult = snapshot.data;

        final matchingPlaylists = libraryProvider.playlists
            .where((p) => p.name.toLowerCase().contains(lowerQuery))
            .toList();

        final matchingSongs = searchResult?.songs ?? [];
        final matchingArtists = searchResult?.artists ?? [];
        final matchingAlbums = searchResult?.albums ?? [];

        if (matchingSongs.isEmpty &&
            matchingArtists.isEmpty &&
            matchingAlbums.isEmpty &&
            matchingPlaylists.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  CupertinoIcons.search,
                  size: 64,
                  color: isDark ? Colors.white38 : Colors.black26,
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.noResults,
                  style: TextStyle(
                    color: isDark ? Colors.white54 : Colors.black45,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          );
        }

        return ListView(
          children: [
            if (matchingArtists.isNotEmpty) ...[
              _buildSectionHeader(l10n.artists),
              ...matchingArtists.take(5).map(
                    (artist) => ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            AppTheme.appleMusicRed.withValues(alpha: 0.2),
                        child: const Icon(
                          CupertinoIcons.person,
                          color: AppTheme.appleMusicRed,
                          size: 20,
                        ),
                      ),
                      title: Text(artist.name),
                      onTap: () {
                        close(context, '');
                        NavigationHelper.push(
                          context,
                          ArtistScreen(artistId: artist.id),
                        );
                      },
                    ),
                  ),
            ],
            if (matchingAlbums.isNotEmpty) ...[
              _buildSectionHeader(l10n.albums),
              ...matchingAlbums.take(5).map(
                    (album) => ListTile(
                      leading: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          color: AppTheme.appleMusicRed.withValues(alpha: 0.2),
                        ),
                        child: const Icon(
                          CupertinoIcons.music_albums,
                          color: AppTheme.appleMusicRed,
                        ),
                      ),
                      title: Text(album.name),
                      subtitle: album.artist != null
                          ? Text(album.artist!,
                              maxLines: 1, overflow: TextOverflow.ellipsis)
                          : null,
                      onTap: () {
                        close(context, '');
                        NavigationHelper.push(
                          context,
                          AlbumScreen(albumId: album.id),
                        );
                      },
                    ),
                  ),
            ],
            if (matchingSongs.isNotEmpty) ...[
              _buildSectionHeader(l10n.songs),
              ...matchingSongs.take(10).map(
                    (song) => ListTile(
                      leading: const Icon(
                        CupertinoIcons.music_note,
                        color: AppTheme.appleMusicRed,
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
                      onTap: () {
                        close(context, '');
                        final playerProvider = Provider.of<PlayerProvider>(
                          context,
                          listen: false,
                        );
                        playerProvider.playSong(
                          song,
                          playlist: matchingSongs,
                          startIndex: matchingSongs.indexOf(song),
                        );
                      },
                    ),
                  ),
            ],
            if (matchingPlaylists.isNotEmpty) ...[
              _buildSectionHeader(l10n.playlists),
              ...matchingPlaylists.map(
                (playlist) => ListTile(
                  leading: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: AppTheme.appleMusicRed.withValues(alpha: 0.2),
                    ),
                    child: const Icon(
                      CupertinoIcons.music_note_list,
                      color: AppTheme.appleMusicRed,
                    ),
                  ),
                      title: Text(playlist.name),
                      subtitle: Text(l10n.songsCount(playlist.songCount ?? 0)),
                  onTap: () {
                    close(context, '');
                    NavigationHelper.push(
                      context,
                      PlaylistScreen(
                        playlistId: playlist.id,
                        playlistName: playlist.name,
                      ),
                    );
                  },
                ),
              ),
            ],
            const SizedBox(height: 80),
          ],
        );
      },
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: isDark ? Colors.white : Colors.black,
        ),
      ),
    );
  }
}
