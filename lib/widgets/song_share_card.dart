import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/song.dart';
import '../services/subsonic_service.dart';
import '../theme/app_theme.dart';
import '../widgets/album_artwork.dart' show isLocalFilePath;

class SongShareCard extends StatelessWidget {
  final Song song;
  final String? imageUrl;

  const SongShareCard({
    super.key,
    required this.song,
    required this.imageUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 720,
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF1c1c1e),
              Color(0xFF2c2c2e),
            ],
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _buildArtwork(),
            const SizedBox(width: 28),
            Expanded(child: _buildInfo(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildArtwork() {
    Widget artwork;
    if (imageUrl == null || imageUrl!.isEmpty) {
      artwork = _placeholder();
    } else if (isLocalFilePath(imageUrl)) {
      artwork = Image.file(
        File(imageUrl!),
        width: 280,
        height: 280,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _placeholder(),
      );
    } else {
      artwork = Image.network(
        imageUrl!,
        width: 280,
        height: 280,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _placeholder(),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: artwork,
    );
  }

  Widget _placeholder() {
    return Container(
      width: 280,
      height: 280,
      color: const Color(0xFF2C2C2E),
      child: const Icon(
        Icons.music_note_rounded,
        color: Colors.white24,
        size: 80,
      ),
    );
  }

  Widget _buildInfo(BuildContext context) {
    final artist = song.artist ?? 'Неизвестный исполнитель';
    final album = song.album;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Сейчас играет',
          style: TextStyle(
            color: AppTheme.appleMusicRed,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          song.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 28,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.85),
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (album != null && album.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            album,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 15,
            ),
          ),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'KumaFlow',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class SongShareHelper {
  SongShareHelper._();

  static Future<String?> captureCard({
    required GlobalKey boundaryKey,
  }) async {
    try {
      final boundary = boundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return null;

      final ui.Image image = await boundary.toImage(
        pixelRatio: 3.0,
      );
      final ByteData? byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (byteData == null) return null;

      final Uint8List bytes = byteData.buffer.asUint8List();
      final dir = Directory.systemTemp;
      final file = File(
        '${dir.path}/kumaflow_share_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (e) {
      debugPrint('SongShareHelper.captureCard failed: $e');
      return null;
    }
  }

  static String? resolveArtworkUrl(Song song, BuildContext context) {
    final cover = song.coverArt;
    if (cover == null || cover.isEmpty) return null;
    if (cover.startsWith('http://') || cover.startsWith('https://')) {
      return cover;
    }
    if (isLocalFilePath(cover)) {
      return cover;
    }
    final subsonicService = SubsonicService();
    try {
      return subsonicService.getCoverArtUrl(cover, size: 1200);
    } catch (_) {
      return null;
    }
  }
}

class SongShareCardHost extends StatefulWidget {
  final Song song;
  final String? imageUrl;
  final Future<bool> Function(Uint8List bytes) onBytesReady;
  final GlobalKey cardKey;

  const SongShareCardHost({
    super.key,
    required this.song,
    required this.imageUrl,
    required this.onBytesReady,
    required this.cardKey,
  });

  @override
  State<SongShareCardHost> createState() => _SongShareCardHostState();
}

class _SongShareCardHostState extends State<SongShareCardHost> {
  @override
  Widget build(BuildContext context) {
    return Offstage(
      child: RepaintBoundary(
        key: widget.cardKey,
        child: SongShareCard(song: widget.song, imageUrl: widget.imageUrl),
      ),
    );
  }
}

class ShareSongService {
  ShareSongService._();

  static Future<bool> shareSong({
    required Song song,
    required String? imageUrl,
    required GlobalKey cardKey,
  }) async {
    try {
      final path = await SongShareHelper.captureCard(boundaryKey: cardKey);
      final artist = song.artist ?? '';
      final lines = <String>[
        song.title,
        if (artist.isNotEmpty) artist,
        if (song.album != null && song.album!.isNotEmpty) song.album!,
        '',
        'Shared via KumaFlow',
      ];
      final text = lines.join('\n');

      if (path != null) {
        final f = File(path);
        if (await f.exists() && await f.length() > 1000) {
          await SharePlus.instance.share(
            ShareParams(
              files: [XFile(path, mimeType: 'image/png')],
              text: text,
              subject: '${song.title} - $artist',
            ),
          );
        } else {
          await SharePlus.instance.share(
            ShareParams(
              text: text,
              subject: '${song.title} - $artist',
            ),
          );
        }
      } else {
        await SharePlus.instance.share(
          ShareParams(
            text: text,
            subject: '${song.title} - $artist',
          ),
        );
      }
      HapticFeedback.lightImpact();
      return true;
    } catch (e) {
      debugPrint('ShareSongService.shareSong failed: $e');
      return false;
    }
  }

  static Future<void> shareTextFallback(String text,
      {required Song song}) async {
    final artist = song.artist ?? '';
    await SharePlus.instance.share(
      ShareParams(
        text: text,
        subject: '${song.title} - $artist',
      ),
    );
    HapticFeedback.lightImpact();
  }
}
