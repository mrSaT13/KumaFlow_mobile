import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/app_gradient_background.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/yandex_music_service.dart';

/// Встроенный плеер для видео артиста — внутри приложения (не браузер).
/// Поддерживает YouTube (providerVideoId) и Yandex embedUrl.
/// На десктопе fallback в браузер (webview не поддерживается).
class ArtistVideoPlayerScreen extends StatefulWidget {
  final YandexVideoResult video;
  final Map<String, dynamic>? clipData; // для клипов из searchVideos
  final String artistName;

  const ArtistVideoPlayerScreen({
    super.key,
    required this.video,
    this.clipData,
    required this.artistName,
  });

  /// Helper для клипов (Map)
  factory ArtistVideoPlayerScreen.fromClip({
    required Map<String, dynamic> clip,
    required String artistName,
  }) {
    final title = clip['title']?.toString() ?? clip['name']?.toString() ?? artistName;
    final thumb = clip['cover']?.toString() ?? clip['thumbnail']?.toString() ?? clip['ogImage']?.toString() ?? clip['coverUri']?.toString();
    final embed = clip['embedUrl']?.toString() ?? clip['url']?.toString();
    final pid = clip['providerVideoId']?.toString() ?? clip['id']?.toString();
    final prov = clip['provider']?.toString() ?? 'Yandex';
    return ArtistVideoPlayerScreen(
      video: YandexVideoResult(
        title: title,
        thumbnailUrl: thumb,
        embedUrl: embed,
        provider: prov,
        providerVideoId: pid,
      ),
      clipData: clip,
      artistName: artistName,
    );
  }

  @override
  State<ArtistVideoPlayerScreen> createState() => _ArtistVideoPlayerScreenState();
}

class _ArtistVideoPlayerScreenState extends State<ArtistVideoPlayerScreen> {
  WebViewController? _controller;
  String? _embedHtml;
  String? _directUrl;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  void _prepare() {
    final v = widget.video;
    String? url;
    String? youTubeId = v.providerVideoId;

    // Попробуем вытащить youtube id из embedUrl
    if (youTubeId == null && v.embedUrl != null) {
      final u = v.embedUrl!;
      final uri = Uri.tryParse(u);
      if (uri != null) {
        if (uri.queryParameters.containsKey('v')) youTubeId = uri.queryParameters['v'];
        else if (u.contains('youtu.be/')) youTubeId = u.split('youtu.be/').last.split('?').first;
        else if (u.contains('embed/')) youTubeId = u.split('embed/').last.split('?').first.split('/').first;
      }
    }
    // Из clipData тоже
    if (youTubeId == null && widget.clipData != null) {
      youTubeId = widget.clipData!['providerVideoId']?.toString() ?? widget.clipData!['id']?.toString();
    }

    final isYouTube = (v.provider?.toLowerCase().contains('youtube') ?? false) || (youTubeId != null && youTubeId.isNotEmpty && RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(youTubeId!));
    // Также пробуем вытянуть id из thumbnail youtube
    if ((youTubeId == null || youTubeId.isEmpty) && v.thumbnailUrl != null && v.thumbnailUrl!.contains('img.youtube.com')) {
      final m = RegExp(r'img\.youtube\.com/vi/([a-zA-Z0-9_-]{11})').firstMatch(v.thumbnailUrl!);
      if (m != null) youTubeId = m.group(1);
    }

    if (isYouTube && youTubeId != null && youTubeId.isNotEmpty && RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(youTubeId)) {
      final id = youTubeId;
      // YouTube embed via html — без рекламы yandex, с нормальным плеером
      _embedHtml = '''
<!DOCTYPE html>
<html>
<head><meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
<style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}iframe{width:100%;height:100%;border:0}</style>
</head>
<body>
<iframe src="https://www.youtube-nocookie.com/embed/$id?autoplay=1&playsinline=1&rel=0&modestbranding=1" allow="autoplay; encrypted-media; fullscreen; picture-in-picture" allowfullscreen></iframe>
</body>
</html>
''';
      _directUrl = 'https://www.youtube.com/watch?v=$id';
    } else if (v.embedUrl != null && v.embedUrl!.isNotEmpty) {
      url = v.embedUrl!;
      if (url.startsWith('http')) {
        _directUrl = url;
        // Для yandex и прочих — грузим страницу напрямую, а не в iframe (иначе черный экран)
        // Оставляем _embedHtml пустым — будет loadRequest
        _embedHtml = null;
      }
    } else if (v.thumbnailUrl != null && v.thumbnailUrl!.startsWith('http')) {
      _directUrl = v.thumbnailUrl;
    }

    // Для десктопа — сразу fallback в браузер позже
    if (!Platform.isAndroid && !Platform.isIOS) {
      // на desktop webview не завезли — покажем кнопку открыть в браузере
      _isLoading = false;
      return;
    }

    if (_embedHtml != null || _directUrl != null) {
      try {
        final controller = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(const Color(0xFF000000))
          ..setNavigationDelegate(NavigationDelegate(
            onPageStarted: (_) => setState(() => _isLoading = true),
            onPageFinished: (_) => setState(() => _isLoading = false),
            onWebResourceError: (e) => setState(() {
              _error = e.description;
              _isLoading = false;
            }),
          ));
        if (_embedHtml != null) {
          controller.loadHtmlString(_embedHtml!);
        } else if (_directUrl != null) {
          controller.loadRequest(Uri.parse(_directUrl!));
        }
        _controller = controller;
      } catch (e) {
        _error = e.toString();
        _isLoading = false;
      }
    } else {
      _error = 'Нет ссылки на видео';
      _isLoading = false;
    }
  }

  Future<void> _openInBrowser() async {
    final urlStr = _directUrl ?? widget.video.embedUrl ?? widget.video.thumbnailUrl;
    if (urlStr == null) return;
    final uri = Uri.tryParse(urlStr);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _openFullscreen() {
    if (_embedHtml == null && _directUrl == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FullscreenVideoScreen(
          embedHtml: _embedHtml,
          directUrl: _directUrl,
          title: widget.video.title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(widget.video.title, style: const TextStyle(color: Colors.white, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if ((_embedHtml != null || _directUrl != null) && !isDesktop)
            IconButton(
              icon: const Icon(Icons.fullscreen_rounded, color: Colors.white70),
              tooltip: 'Во весь экран (горизонтально)',
              onPressed: _openFullscreen,
            ),
          if (_directUrl != null)
            IconButton(
              icon: const Icon(Icons.open_in_new_rounded, color: Colors.white70),
              tooltip: 'Открыть в браузере',
              onPressed: _openInBrowser,
            ),
        ],
      ),
      body: isDesktop
          ? _buildDesktopFallback()
          : _controller == null
              ? Center(child: Text(_error ?? 'Ошибка загрузки', style: const TextStyle(color: Colors.white70)))
              : Stack(
                  children: [
                    WebViewWidget(controller: _controller!),
                    if (_isLoading)
                      const Center(child: CircularProgressIndicator(color: Colors.white)),
                    if (_error != null)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.error_outline, color: Colors.white54, size: 48),
                              const SizedBox(height: 12),
                              Text(_error!, style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
                              const SizedBox(height: 16),
                              ElevatedButton(onPressed: _openInBrowser, child: const Text('Открыть в браузере')),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }

  Widget _buildDesktopFallback() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.videocam_rounded, color: Colors.white24, size: 64),
            const SizedBox(height: 16),
            Text(widget.video.title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            if (widget.video.provider != null) Text(widget.video.provider!, style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 24),
            if (_directUrl != null)
              ElevatedButton.icon(
                onPressed: _openInBrowser,
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Открыть видео в браузере'),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFCC00), foregroundColor: Colors.black),
              ),
            const SizedBox(height: 12),
            const Text('Встроенный плеер на десктопе пока открывается в браузере', style: TextStyle(color: Colors.white38, fontSize: 11), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// Fullscreen landscape video — forces horizontal orientation while in route.
class _FullscreenVideoScreen extends StatefulWidget {
  final String? embedHtml;
  final String? directUrl;
  final String title;
  const _FullscreenVideoScreen({required this.embedHtml, required this.directUrl, required this.title});

  @override
  State<_FullscreenVideoScreen> createState() => _FullscreenVideoScreenState();
}

class _FullscreenVideoScreenState extends State<_FullscreenVideoScreen> {
  WebViewController? _controller;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    // Force landscape
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _init();
  }

  void _init() {
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000))
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) => setState(() => _isLoading = false),
      ));
    if (widget.embedHtml != null) {
      c.loadHtmlString(widget.embedHtml!);
    } else if (widget.directUrl != null) {
      c.loadRequest(Uri.parse(widget.directUrl!));
    }
    _controller = c;
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown, DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_controller != null) WebViewWidget(controller: _controller!),
          if (_isLoading) const Center(child: CircularProgressIndicator(color: Colors.white)),
          Positioned(
            top: 8,
            left: 8,
            child: SafeArea(
              child: IconButton(
                icon: const Icon(Icons.fullscreen_exit_rounded, color: Colors.white70),
                onPressed: () => Navigator.of(context).pop(),
                tooltip: 'Выйти',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
