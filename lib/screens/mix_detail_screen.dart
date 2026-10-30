import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/player_ui_settings_service.dart';
import '../services/playlist_orchestrator.dart';
import '../widgets/song_tile.dart';
import '../theme/app_theme.dart';

class MixDetailScreen extends StatelessWidget {
  final String mixName;
  final List<Song> songs;
  const MixDetailScreen({super.key, required this.mixName, required this.songs});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radiusVal = PlayerUiSettingsService().getAlbumArtCornerRadius();
    final shape = PlayerUiSettingsService().getArtworkShape();
    final borderRadius = shape == 'circle' ? 9999.0 : shape == 'square' ? 0.0 : radiusVal;
    return Scaffold(
      appBar: AppBar(
        title: Text(mixName),
        backgroundColor: isDark ? const Color(0xFF121212) : Colors.white,
      ),
      body: ListView.builder(
        padding: const EdgeInsets.only(bottom: 100),
        itemCount: songs.length,
        itemBuilder: (ctx, i) {
          final s = songs[i];
          return SongTile(song: s, playlist: songs, index: i, showAlbum: true);
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          if (songs.isEmpty) return;
          // Оркестрация на тап: плавные переходы, генерацию не утяжеляет.
          List<Song> ordered = songs;
          try {
            ordered = PlaylistOrchestrator.orchestrate(
              songs, startWith: 'mixed', endWith: 'mixed');
          } catch (_) {}
          context.read<PlayerProvider>().playSong(ordered.first, playlist: ordered, startIndex: 0);
        },
        icon: const Icon(Icons.play_arrow_rounded),
        label: const Text('Слушать'),
        backgroundColor: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}
