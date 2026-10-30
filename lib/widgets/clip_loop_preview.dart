import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter/services.dart';
import '../models/song.dart';
import '../services/yandex_music_public_api.dart';
import '../screens/artist_video_player_screen.dart';
import '../services/yandex_music_service.dart';

/// Clip loop preview under Now Playing (30-40s muted loop like Yandex Music).
/// Isolated RepaintBoundary, lazy fetch, no player blocking.
/// Shows 16:9 thumbnail with auto-loop if clip found, else hidden.
class ClipLoopPreview extends StatefulWidget {
  final Song song;
  const ClipLoopPreview({super.key, required this.song});

  @override
  State<ClipLoopPreview> createState() => _ClipLoopPreviewState();
}

class _ClipLoopPreviewState extends State<ClipLoopPreview> {
  String? _videoId;
  String? _thumbUrl;
  String? _embedHtml;
  bool _loading = true;
  bool _noClip = false;

  @override
  void initState() {
    super.initState();
    _fetchClip();
  }

  @override
  void didUpdateWidget(covariant ClipLoopPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id) {
      _videoId = null;
      _thumbUrl = null;
      _embedHtml = null;
      _loading = true;
      _noClip = false;
      _fetchClip();
    }
  }

  Future<void> _fetchClip() async {
    final q = '${widget.song.artist ?? ''} ${widget.song.title} clip'.trim();
    try {
      // Prefer Yandex public clips (has thumbnails), fallback to thumbnail only
      final api = YandexMusicPublicApi();
      final clips = await api.getArtistVideosByName(q, limit: 3).timeout(const Duration(seconds: 6));
      if (clips.isNotEmpty) {
        final c = clips.first;
        String? pid = c['providerVideoId']?.toString() ?? c['id']?.toString();
        String? thumb = c['cover']?.toString() ?? c['thumbnail']?.toString() ?? c['ogImage']?.toString();
        if (thumb != null && thumb.isNotEmpty) {
          thumb = thumb.replaceAll('%%', '400x225');
          if (!thumb.startsWith('http')) thumb = 'https://$thumb';
        }
        if (pid != null && RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(pid)) {
          _videoId = pid;
          _thumbUrl = thumb ?? 'https://img.youtube.com/vi/$pid/hqdefault.jpg';
        } else if (thumb != null) {
          // Yandex clip without youtube id — still show thumb without loop
          _thumbUrl = thumb;
        }
        // Also try embedUrl for youtube id extraction
        if (_videoId == null && c['embedUrl'] != null) {
          final m = RegExp(r'(?:youtu\.be/|youtube\.com/(?:embed/|watch\?v=))([a-zA-Z0-9_-]{11})').firstMatch(c['embedUrl'].toString());
          if (m != null) {
            _videoId = m.group(1);
            _thumbUrl ??= 'https://img.youtube.com/vi/$_videoId/hqdefault.jpg';
          }
        }
      }
      // If still no thumb, try youtube thumbnail directly via videoId from embed
      if (_videoId != null && !mounted) return;
    } catch (_) {}

    if (mounted) {
      setState(() {
        _loading = false;
        if (_videoId == null && _thumbUrl == null) _noClip = true;
        if (_videoId != null) {
          // muted autoplay loop 30-40s segment: youtube loop param needs playlist=id
          _embedHtml = '''
<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1.0"><style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}iframe{width:100%;height:100%;border:0}</style></head>
<body><iframe src="https://www.youtube-nocookie.com/embed/$_videoId?autoplay=1&mute=1&loop=1&playlist=$_videoId&controls=0&rel=0&modestbranding=1&playsinline=1" allow="autoplay; encrypted-media" allowfullscreen></iframe></body></html>''';
        }
      });
    }
  }

  void _openFullscreen() {
    if (_videoId == null) return;
    // Build YandexVideoResult for player screen
    final title = '${widget.song.artist ?? ''} — ${widget.song.title}';
    final vid = YandexVideoResult(
      title: title,
      thumbnailUrl: _thumbUrl,
      embedUrl: 'https://www.youtube.com/watch?v=$_videoId',
      provider: 'YouTube',
      providerVideoId: _videoId,
    );
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ArtistVideoPlayerScreen(video: vid, artistName: widget.song.artist ?? '')),
    );
  }

  void _openLandscape() {
    if (_embedHtml == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _ClipFullscreen(embedHtml: _embedHtml!, title: widget.song.title)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_noClip && !_loading) return const SizedBox.shrink();
    if (_loading) return const SizedBox(height: 120, child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24))));
    if (_videoId == null && _thumbUrl == null) return const SizedBox.shrink();

    // Isolated container — RepaintBoundary prevents clip repaints from bubbling to player
    return RepaintBoundary(
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        height: 170,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4))],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Preview — только картинка (изоляция: никакого WebView в списке, иначе краш плеера)
            if (_thumbUrl != null)
              CachedNetworkImage(
                imageUrl: _thumbUrl!,
                fit: BoxFit.cover,
                memCacheWidth: 600,
                maxWidthDiskCache: 600,
                placeholder: (_, __) => Container(color: Colors.grey[900]),
                errorWidget: (_, __, ___) => Container(color: Colors.grey[900], child: const Icon(Icons.videocam_rounded, color: Colors.white24)),
              )
            else
              Container(color: Colors.grey[900], child: const Icon(Icons.videocam_rounded, color: Colors.white24)),
            // Gradient overlay for text
            Container(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withValues(alpha: 0.65)]))),
            // Center play
            Center(
              child: GestureDetector(
                onTap: _openFullscreen,
                child: Container(width: 48, height: 48, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: 0.55)), child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 30)),
              ),
            ),
            // Bottom label + fullscreen button
            Positioned(
              bottom: 8, left: 10, right: 48,
              child: Text('Клип • ${widget.song.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
            Positioned(
              bottom: 4, right: 4,
              child: IconButton(icon: const Icon(Icons.fullscreen_rounded, color: Colors.white70), onPressed: _openLandscape, tooltip: 'Во весь экран'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClipFullscreen extends StatefulWidget {
  final String embedHtml;
  final String title;
  const _ClipFullscreen({required this.embedHtml, required this.title});
  @override
  State<_ClipFullscreen> createState() => _ClipFullscreenState();
}

class _ClipFullscreenState extends State<_ClipFullscreen> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }
  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown, DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    final c = WebViewController()..setJavaScriptMode(JavaScriptMode.unrestricted)..setBackgroundColor(const Color(0xFF000000))..loadHtmlString(widget.embedHtml);
    return Scaffold(backgroundColor: Colors.black, body: Stack(children: [WebViewWidget(controller: c), Positioned(top: 8, left: 8, child: SafeArea(child: IconButton(icon: const Icon(Icons.fullscreen_exit_rounded, color: Colors.white70), onPressed: () => Navigator.pop(context))))]));
  }
}
