import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../services/subsonic_service.dart';
import '../services/ml_service.dart';
import '../widgets/kumaflow_my_wave_hero.dart';
import '../theme/app_theme.dart';
import 'now_playing_screen.dart';

/// Android TV leanback-optimized home screen.
///
/// 10ft design: large typography, >48dp touch targets (D-pad), high contrast,
/// overscan-safe padding, visible focus ring, and non-touch traversal.
///
/// The whole screen is a single [Focus] tree. Arrow keys + OK/Enter navigate
/// between sidebar sections and grid items; media keys are handled globally.
class TvHomeScreen extends StatefulWidget {
  const TvHomeScreen({super.key});

  @override
  State<TvHomeScreen> createState() => _TvHomeScreenState();
}

class _TvHomeScreenState extends State<TvHomeScreen> {
  int _selectedSection = 0;
  int _selectedItem = 0;
  final FocusNode _rootFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();

  static const int _sectionCount = 4;
  // how many columns in the TV grid — 4 gives ~220dp cards on 1080p
  static const int _columns = 4;

  @override
  void initState() {
    super.initState();
    // autofocus after first frame so TV remote works without tap
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _rootFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _rootFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkBackground,
      body: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        onKeyEvent: _handleKey,
        child: Consumer<LibraryProvider>(
          builder: (context, libraryProvider, _) {
            if (libraryProvider.isLoading && !libraryProvider.isInitialized) {
              return const Center(
                child: CircularProgressIndicator(color: Colors.red),
              );
            }

            return Row(
              children: [
                _buildSidebar(libraryProvider),
                Expanded(
                  child: Column(
                    children: [
                      Expanded(child: _buildContent(libraryProvider)),
                      _buildNowPlayingBar(),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final isPlaylistSection = _selectedSection == 2;
    final songs = _songsForSection();
    final playlists = _playlistsForSection();
    final itemCount = isPlaylistSection ? playlists.length : songs.length;

    // Helper to move focus and keep selection visible
    void moveSelection(int delta) {
      setState(() {
        _selectedItem = (_selectedItem + delta).clamp(0, (itemCount - 1).clamp(0, 9999));
      });
      _scrollToSelected();
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        if (_selectedItem - _columns >= 0) {
          moveSelection(-_columns);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        if (_selectedItem + _columns < itemCount) {
          moveSelection(_columns);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        if (_selectedItem > 0) {
          // move left within row, with wrap prevention
          if (_selectedItem % _columns != 0) {
            moveSelection(-1);
          } else {
            // at row start → jump to previous row end (natural TV feel)
            moveSelection(-1);
          }
        } else {
          // first item → go to sidebar previous section
          setState(() {
            _selectedSection = (_selectedSection - 1).clamp(0, _sectionCount - 1);
            _selectedItem = 0;
          });
          _scrollToSelected();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        if (_selectedItem < itemCount - 1) {
          moveSelection(1);
        } else {
          setState(() {
            _selectedSection = (_selectedSection + 1).clamp(0, _sectionCount - 1);
            _selectedItem = 0;
          });
          _scrollToSelected();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.gameButtonA:
        _activateSelected();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.space:
        _activateSelected();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaPlay:
      case LogicalKeyboardKey.mediaPlayPause:
        _togglePlay();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaPause:
        final pp = Provider.of<PlayerProvider>(context, listen: false);
        if (pp.isPlaying) pp.togglePlayPause();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaTrackNext:
        Provider.of<PlayerProvider>(context, listen: false).skipNext();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaTrackPrevious:
        Provider.of<PlayerProvider>(context, listen: false).skipPrevious();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.backspace:
      case LogicalKeyboardKey.escape:
      case LogicalKeyboardKey.goBack:
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        } else {
          SystemNavigator.pop();
        }
        return KeyEventResult.handled;
      default:
        break;
    }
    return KeyEventResult.ignored;
  }

  void _scrollToSelected() {
    final rows = _selectedItem ~/ _columns;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        // ~210dp per row + spacing
        _scrollController.animateTo(
          (rows * 228).toDouble().clamp(0, _scrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  void _togglePlay() {
    final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
    if (playerProvider.currentSong == null) {
      _activateSelected();
    } else {
      playerProvider.togglePlayPause();
    }
  }

  void _activateSelected() {
    final isPlaylistSection = _selectedSection == 2;
    if (isPlaylistSection) {
      final pls = _playlistsForSection();
      if (pls.isNotEmpty && _selectedItem < pls.length) {
        _playPlaylist(pls[_selectedItem]);
      }
      return;
    }
    final songs = _songsForSection();
    if (songs.isNotEmpty && _selectedItem < songs.length) {
      Provider.of<PlayerProvider>(context, listen: false).playSong(
        songs[_selectedItem],
        playlist: songs,
        startIndex: _selectedItem,
      );
    }
  }

  Future<void> _playPlaylist(Playlist pl) async {
    try {
      // fetch full playlist with songs
      final sub = Provider.of<SubsonicService>(context, listen: false);
      final full = await sub.getPlaylist(pl.id);
      final songs = full.songs ?? [];
      if (songs.isEmpty) return;
      if (!mounted) return;
      Provider.of<PlayerProvider>(context, listen: false).playSong(
        songs.first,
        playlist: songs,
        startIndex: 0,
      );
    } catch (_) {}
  }

  List<Song> _songsForSection() {
    final libraryProvider = Provider.of<LibraryProvider>(context, listen: false);
    switch (_selectedSection) {
      case 0:
        return libraryProvider.starred?.songs.isNotEmpty == true
            ? libraryProvider.starred!.songs
            : libraryProvider.randomSongs;
      case 1:
        return libraryProvider.cachedAllSongs.isNotEmpty
            ? libraryProvider.cachedAllSongs
            : libraryProvider.randomSongs;
      case 2:
        return []; // playlists handled separately
      case 3:
        return libraryProvider.randomSongs;
      default:
        return [];
    }
  }

  List<Playlist> _playlistsForSection() {
    final libraryProvider = Provider.of<LibraryProvider>(context, listen: false);
    if (_selectedSection != 2) return [];
    return libraryProvider.playlists;
  }

  Widget _buildSidebar(LibraryProvider libraryProvider) {
    const icons = [Icons.favorite, Icons.music_note, Icons.playlist_play, Icons.shuffle];
    const labels = ['Избранное', 'Все треки', 'Плейлисты', 'Случайные'];

    return Container(
      width: 300, // 10ft: wider for readability
      color: AppTheme.darkSurface,
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          const SizedBox(height: 12),
          // overscan-safe top
          const Text(
            'KumaFlow',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: Colors.red,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'для Android TV',
            style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12, letterSpacing: 2),
          ),
          const SizedBox(height: 32),
          ...List.generate(icons.length, (index) {
            final isSelected = _selectedSection == index;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
              decoration: BoxDecoration(
                color: isSelected ? Colors.red.withOpacity(0.22) : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                border: isSelected ? Border.all(color: Colors.red.withOpacity(0.6), width: 1.5) : null,
              ),
              child: ListTile(
                onTap: () => setState(() {
                  _selectedSection = index;
                  _selectedItem = 0;
                  _rootFocus.requestFocus();
                }),
                leading: Icon(icons[index], color: isSelected ? Colors.red : Colors.white54, size: 28),
                title: Text(
                  labels[index],
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.white70,
                    fontSize: 18,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                trailing: isSelected
                    ? Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle))
                    : null,
                selected: isSelected,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            );
          }),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(Icons.live_tv, size: 18, color: Colors.red),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'ТВ-режим  •  D-pad OK = play',
                    style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5),
                  ),
                ),
              ],
            ),
          ),
          // overscan bottom
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildContent(LibraryProvider libraryProvider) {
    final allSongs = libraryProvider.cachedAllSongs.isNotEmpty
        ? libraryProvider.cachedAllSongs
        : libraryProvider.randomSongs;
    final mlService = Provider.of<MLService>(context, listen: false);
    final myWaveSongs = allSongs.isNotEmpty ? mlService.generateLocalMyWave(songs: allSongs, count: 24) : <Song>[];

    return Padding(
      // overscan-safe: 48dp on TV (vs 16dp on phone)
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (myWaveSongs.isNotEmpty && _selectedSection == 0)
            Builder(builder: (ctx) {
              final sub = Provider.of<SubsonicService>(ctx, listen: false);
              final cover = myWaveSongs.first.coverArt != null ? sub.getCoverArtUrl(myWaveSongs.first.coverArt!, size: 600) : null;
              // Make hero focusable: first D-pad focus lands on hero play button
              final isHeroFocused = _selectedItem == -1;
              return Focus(
                autofocus: _selectedSection == 0,
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      (event.logicalKey == LogicalKeyboardKey.select || event.logicalKey == LogicalKeyboardKey.enter)) {
                    final pp = Provider.of<PlayerProvider>(context, listen: false);
                    final idx = DateTime.now().millisecondsSinceEpoch % myWaveSongs.length;
                    pp.playSong(myWaveSongs[idx], playlist: myWaveSongs, startIndex: idx);
                    return KeyEventResult.handled;
                  }
                  if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowDown) {
                    setState(() => _selectedItem = 0);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  decoration: isHeroFocused
                      ? BoxDecoration(border: Border.all(color: Colors.red, width: 3), borderRadius: BorderRadius.circular(24))
                      : null,
                  child: KumaFlowMyWaveHero(
                    isTv: true,
                    songs: myWaveSongs,
                    coverUrl: cover,
                    onPlay: () {
                      final pp = Provider.of<PlayerProvider>(ctx, listen: false);
                      final idx = DateTime.now().millisecondsSinceEpoch % myWaveSongs.length;
                      pp.playSong(myWaveSongs[idx], playlist: myWaveSongs, startIndex: idx);
                    },
                    onShuffle: () {
                      final list = List<Song>.from(myWaveSongs)..shuffle();
                      Provider.of<PlayerProvider>(ctx, listen: false).playSong(list.first, playlist: list);
                    },
                    onCustomize: null,
                  ),
                ),
              );
            }),
          if (myWaveSongs.isNotEmpty && _selectedSection == 0) const SizedBox(height: 24),
          Text(
            _getSectionTitle(),
            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: -0.5),
          ),
          const SizedBox(height: 6),
          Text(
            _getSectionSubtitle(),
            style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 13),
          ),
          const SizedBox(height: 18),
          Expanded(child: _buildGrid(libraryProvider)),
        ],
      ),
    );
  }

  String _getSectionTitle() {
    switch (_selectedSection) {
      case 0:
        return 'Избранное';
      case 1:
        return 'Все треки';
      case 2:
        return 'Плейлисты';
      case 3:
        return 'Случайные треки';
      default:
        return '';
    }
  }

  String _getSectionSubtitle() {
    final count = _selectedSection == 2 ? _playlistsForSection().length : _songsForSection().length;
    switch (_selectedSection) {
      case 0:
        return count > 0 ? '$count любимых треков  •  OK для воспроизведения' : 'Добавьте лайки — они появятся здесь';
      case 1:
        return '$count треков в библиотеке';
      case 2:
        return '$count плейлистов  •  OK чтобы проиграть плейлист';
      case 3:
        return 'Перемешанная подборка для ТВ';
      default:
        return '';
    }
  }

  Widget _buildGrid(LibraryProvider libraryProvider) {
    final isPlaylist = _selectedSection == 2;
    final songs = _songsForSection();
    final playlists = _playlistsForSection();
    final subsonic = Provider.of<SubsonicService>(context, listen: false);

    if (isPlaylist) {
      if (playlists.isEmpty) {
        return Center(
          child: Text('Нет плейлистов', style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 18)),
        );
      }
      return GridView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.only(bottom: 24, right: 8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _columns,
          childAspectRatio: 1.35,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
        ),
        itemCount: playlists.length.clamp(0, 200),
        itemBuilder: (context, index) {
          final pl = playlists[index];
          final isFocused = _selectedItem == index;
          return _TvPlaylistCard(
            playlist: pl,
            isFocused: isFocused,
            subsonic: subsonic,
            onTap: () {
              setState(() => _selectedItem = index);
              _playPlaylist(pl);
            },
          );
        },
      );
    }

    if (songs.isEmpty) {
      return Center(
        child: Text('Нет доступного контента', style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 18)),
      );
    }

    return GridView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 24, right: 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _columns,
        childAspectRatio: 1.35,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: songs.length.clamp(0, 200),
      itemBuilder: (context, index) {
        final song = songs[index];
        final isFocused = _selectedItem == index;
        return _TvSongCard(
          song: song,
          isFocused: isFocused,
          coverUrl: song.coverArt != null ? subsonic.getCoverArtUrl(song.coverArt!, size: 300) : null,
          onTap: () {
            setState(() => _selectedItem = index);
            Provider.of<PlayerProvider>(context, listen: false).playSong(
              song,
              playlist: songs,
              startIndex: index,
            );
          },
        );
      },
    );
  }

  Widget _buildNowPlayingBar() {
    return Consumer<PlayerProvider>(
      builder: (context, playerProvider, _) {
        final currentSong = playerProvider.currentSong;
        final isPlaying = playerProvider.isPlaying;
        final subsonic = Provider.of<SubsonicService>(context, listen: false);

        return Container(
          height: 92,
          decoration: BoxDecoration(
            color: AppTheme.darkSurface,
            border: Border(top: BorderSide(color: Colors.white.withOpacity(0.08))),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 12, offset: const Offset(0, -2))],
          ),
          child: Row(
            children: [
              const SizedBox(width: 24),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: currentSong?.coverArt != null
                    ? Image.network(
                        subsonic.getCoverArtUrl(currentSong!.coverArt!, size: 200),
                        width: 64,
                        height: 64,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(width: 64, height: 64, color: Colors.white10, child: const Icon(Icons.music_note, color: Colors.white38)),
                      )
                    : Container(width: 64, height: 64, color: Colors.white10, child: const Icon(Icons.music_note, color: Colors.white38)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      currentSong?.title ?? 'Ничего не играет',
                      style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      currentSong?.artist ?? 'Выберите трек — управление пультом (OK, ⏯, ⏭)',
                      style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              _TvControlButton(icon: Icons.skip_previous_rounded, onTap: () => playerProvider.skipPrevious()),
              _TvControlButton(icon: isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, isPrimary: true, onTap: () => playerProvider.togglePlayPause()),
              _TvControlButton(icon: Icons.skip_next_rounded, onTap: () => playerProvider.skipNext()),
              _TvControlButton(
                icon: Icons.fullscreen_rounded,
                onTap: () {
                  Navigator.of(context).push(
                    PageRouteBuilder(
                      opaque: true,
                      barrierColor: Colors.black,
                      pageBuilder: (_, __, ___) => const NowPlayingScreen(),
                    ),
                  );
                },
              ),
              const SizedBox(width: 24),
            ],
          ),
        );
      },
    );
  }
}

class _TvSongCard extends StatelessWidget {
  final Song song;
  final bool isFocused;
  final String? coverUrl;
  final VoidCallback onTap;

  const _TvSongCard({required this.song, required this.isFocused, this.coverUrl, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: isFocused ? 1.04 : 1.0,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: isFocused ? Colors.red.withOpacity(0.18) : AppTheme.darkCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: isFocused ? Colors.red : Colors.white.withOpacity(0.06), width: isFocused ? 2.5 : 1),
          boxShadow: isFocused ? [BoxShadow(color: Colors.red.withOpacity(0.3), blurRadius: 16, offset: const Offset(0, 6))] : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(13),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 3,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        coverUrl != null
                            ? Image.network(
                                coverUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(color: Colors.white10, child: const Center(child: Icon(Icons.music_note, size: 36, color: Colors.white24))),
                              )
                            : Container(color: Colors.white10, child: const Center(child: Icon(Icons.music_note, size: 36, color: Colors.white24))),
                        if (isFocused)
                          Positioned.fill(
                            child: Container(
                              color: Colors.black.withOpacity(0.22),
                              child: const Center(child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 44)),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(song.title, style: TextStyle(color: isFocused ? Colors.white : Colors.white.withOpacity(0.9), fontSize: 13, fontWeight: isFocused ? FontWeight.w700 : FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          Text(song.artist ?? 'Неизвестный артист', style: TextStyle(color: isFocused ? Colors.white.withOpacity(0.9) : Colors.white38, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TvPlaylistCard extends StatelessWidget {
  final Playlist playlist;
  final bool isFocused;
  final SubsonicService subsonic;
  final VoidCallback onTap;

  const _TvPlaylistCard({required this.playlist, required this.isFocused, required this.subsonic, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cover = playlist.coverArt != null ? subsonic.getCoverArtUrl(playlist.coverArt!, size: 300) : null;
    return AnimatedScale(
      scale: isFocused ? 1.04 : 1.0,
      duration: const Duration(milliseconds: 160),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: isFocused ? Colors.red.withOpacity(0.18) : AppTheme.darkCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: isFocused ? Colors.red : Colors.white.withOpacity(0.06), width: isFocused ? 2.5 : 1),
          boxShadow: isFocused ? [BoxShadow(color: Colors.red.withOpacity(0.3), blurRadius: 16)] : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(13),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        cover != null
                            ? Image.network(cover, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _fallback())
                            : _fallback(),
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withOpacity(0.55)]),
                          ),
                        ),
                        if (isFocused)
                          const Center(child: Icon(Icons.playlist_play_rounded, color: Colors.white, size: 40)),
                        Positioned(left: 10, right: 10, bottom: 8, child: Text('${playlist.songCount ?? 0} треков', style: const TextStyle(color: Colors.white70, fontSize: 11))),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(playlist.name, style: TextStyle(color: isFocused ? Colors.white : Colors.white.withOpacity(0.9), fontSize: 13, fontWeight: isFocused ? FontWeight.w700 : FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fallback() => Container(color: const Color(0xFF2A2A2E), child: const Center(child: Icon(Icons.playlist_play, size: 40, color: Colors.white24)));
}

class _TvControlButton extends StatelessWidget {
  final IconData icon;
  final bool isPrimary;
  final VoidCallback onTap;

  const _TvControlButton({required this.icon, this.isPrimary = false, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent && (event.logicalKey == LogicalKeyboardKey.select || event.logicalKey == LogicalKeyboardKey.enter)) {
            onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(
          builder: (ctx) {
            final focused = Focus.of(ctx).hasFocus;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isPrimary ? AppTheme.appleMusicRed : Colors.white.withOpacity(focused ? 0.16 : 0.08),
                border: focused ? Border.all(color: Colors.white, width: 2) : null,
                boxShadow: isPrimary ? [BoxShadow(color: Colors.red.withOpacity(0.4), blurRadius: focused ? 12 : 8)] : null,
              ),
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(29),
                child: Icon(icon, size: 30, color: Colors.white),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Synchronous fallback for quick hint — native channel is authoritative.
bool isAndroidTv() {
  if (!Platform.isAndroid) return false;
  return false;
}
