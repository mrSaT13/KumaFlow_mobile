import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/subsonic_service.dart';
import '../services/theme_service.dart';
import '../models/album.dart';
import '../theme/app_theme.dart';
import '../widgets/widgets.dart';
import '../widgets/app_gradient_background.dart';
import 'album_screen.dart';

class NewReleasesScreen extends StatefulWidget {
  const NewReleasesScreen({super.key});

  @override
  State<NewReleasesScreen> createState() => _NewReleasesScreenState();
}

class _NewReleasesScreenState extends State<NewReleasesScreen> {
  List<Album>? _albums;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAlbums();
  }

  Future<void> _loadAlbums() async {
    try {
      final subsonicService = Provider.of<SubsonicService>(
        context,
        listen: false,
      );
      final albums = await subsonicService.getAlbumList(
        type: 'newest',
        size: 50,
      );
      if (mounted) {
        setState(() {
          _albums = albums;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(backgroundColor: Colors.transparent, 
      body: CustomScrollView(
        slivers: [
          SliverAppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),
            pinned: true,
            expandedHeight: 140,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                'New Releases',
                style: theme.appBarTheme.titleTextStyle,
              ),
              titlePadding: const EdgeInsets.only(left: 52, bottom: 16),
            ),
          ),
          if (_isLoading)
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.8,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) =>
                      const AlbumCardShimmer(size: double.infinity),
                  childCount: 8,
                ),
              ),
            )
          else if (_error != null)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 64,
                      color: AppTheme.lightSecondaryText,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Error loading albums',
                      style: theme.textTheme.headlineSmall,
                    ),
                  ],
                ),
              ),
            )
          else if (_albums == null || _albums!.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.album,
                      size: 64,
                      color: AppTheme.lightSecondaryText,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No new releases',
                      style: theme.textTheme.headlineSmall,
                    ),
                  ],
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.75,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final album = _albums![index];
                  return AlbumCard(
                    album: album,
                    size: double.infinity,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => AlbumScreen(albumId: album.id),
                        ),
                      );
                    },
                  );
                }, childCount: _albums!.length),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
      ),
    );
  }
}
