import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../services/subsonic_service.dart';
import '../services/theme_service.dart';
import '../widgets/widgets.dart';
import '../widgets/app_gradient_background.dart';
import '../l10n/app_localizations.dart';
import 'album_screen.dart';

/// Screen displaying all liked/starred albums
class LikedAlbumsScreen extends StatefulWidget {
  const LikedAlbumsScreen({super.key});

  @override
  State<LikedAlbumsScreen> createState() => _LikedAlbumsScreenState();
}

class _LikedAlbumsScreenState extends State<LikedAlbumsScreen> {
  List<Album> _likedAlbums = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadLikedAlbums();
  }

  Future<void> _loadLikedAlbums() async {
    setState(() => _isLoading = true);

    final subsonicService = Provider.of<SubsonicService>(
      context,
      listen: false,
    );

    try {
      final starred = await subsonicService.getStarred();
      if (mounted) {
        setState(() {
          _likedAlbums = starred.albums;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(backgroundColor: Colors.transparent, 
      appBar: AppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),
        title: Text(l10n.likedAlbums),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _likedAlbums.isEmpty
              ? _buildEmptyState()
              : _buildAlbumsGrid(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(CupertinoIcons.star, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            AppLocalizations.of(context)!.noLikedAlbums,
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlbumsGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(16).copyWith(bottom: 150),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 0.75,
      ),
      itemCount: _likedAlbums.length,
      itemBuilder: (context, index) {
        final album = _likedAlbums[index];
        return AlbumCard(
          album: album,
          size: double.infinity,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => AlbumScreen(albumId: album.id),
            ),
          ),
        );
      },
    );
  }
}
