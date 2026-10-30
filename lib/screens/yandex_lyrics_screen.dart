import 'dart:ui';
import 'package:flutter/material.dart';
import '../widgets/app_gradient_background.dart';
import '../services/yandex_music_service.dart';
import '../theme/yandex_music_theme.dart';

/// Screen for displaying lyrics from Yandex Music.
class YandexLyricsScreen extends StatefulWidget {
  final String trackId;
  final String trackTitle;
  final String artistName;

  const YandexLyricsScreen({
    super.key,
    required this.trackId,
    required this.trackTitle,
    required this.artistName,
  });

  @override
  State<YandexLyricsScreen> createState() => _YandexLyricsScreenState();
}

class _YandexLyricsScreenState extends State<YandexLyricsScreen> {
  YandexLyricsResult? _lyrics;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadLyrics();
  }

  Future<void> _loadLyrics() async {
    final service = YandexMusicService();
    final lyrics = await service.getTrackLyrics(widget.trackId);

    if (mounted) {
      setState(() {
        _lyrics = lyrics;
        _isLoading = false;
      });
    }
    service.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: Colors.transparent, 
      appBar: AppBar(backgroundColor: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF121212).withValues(alpha: 0.72) : Colors.white.withValues(alpha: 0.82), surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 8, shadowColor: Colors.black.withValues(alpha: 0.35),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.trackTitle,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            Text(
              widget.artistName,
              style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.7)),
            ),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _lyrics == null || (_lyrics!.text == null && _lyrics!.lines == null)
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.lyrics_rounded, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text('No lyrics available', style: TextStyle(color: Colors.grey)),
                      SizedBox(height: 8),
                      Text(
                        'Lyrics may not be available for this track',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                )
              : _buildLyricsContent(),
    );
  }

  Widget _buildLyricsContent() {
    // If we have synced lyrics (lines with timestamps)
    if (_lyrics!.lines != null && _lyrics!.lines!.isNotEmpty) {
      return _buildSyncedLyrics();
    }

    // If we have plain text lyrics
    if (_lyrics!.text != null) {
      return _buildPlainTextLyrics();
    }

    return const SizedBox.shrink();
  }

  Widget _buildSyncedLyrics() {
    return ListView.builder(
      padding: const EdgeInsets.all(24),
      itemCount: _lyrics!.lines!.length,
      itemBuilder: (context, index) {
        final line = _lyrics!.lines![index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            line.text,
            style: TextStyle(
              fontSize: 20,
              height: 1.5,
              color: Colors.white.withValues(alpha: 0.9),
            ),
            textAlign: TextAlign.center,
          ),
        );
      },
    );
  }

  Widget _buildPlainTextLyrics() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Text(
        _lyrics!.text!,
        style: TextStyle(
          fontSize: 18,
          height: 1.8,
          color: Colors.white.withValues(alpha: 0.9),
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
