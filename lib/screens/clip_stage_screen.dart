import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../models/song.dart';
import '../services/yandex_music_public_api.dart';

/// Отдельная страница клипа 40 сек — как страница текста песни.
/// Muted зацикленное видео (шоты как в Яндекс Музыке), открывается
/// по кнопке видеокамеры рядом с шафлом. Реклама авто-пропускается
/// JS-инжектом (клик Skip + перемотка preroll), поверх первые секунды
/// висит плашка "Пропускаем рекламу…", чтобы пользователь её не видел.
class ClipStageScreen extends StatefulWidget {
  final Song song;
  const ClipStageScreen({super.key, required this.song});

  @override
  State<ClipStageScreen> createState() => _ClipStageScreenState();
}

class _ClipStageScreenState extends State<ClipStageScreen> {
  WebViewController? _controller;
  String? _videoId;
  String? _thumbUrl;
  bool _loading = true;
  bool _noClip = false;
  bool _showAdVeil = true;
  Timer? _veilTimer;
  Timer? _skipTimer;

  static const _adSkipJs = '''
(function(){
  if(window._kumaAdSkip) return; window._kumaAdSkip=true;
  setInterval(function(){
    try{
      var btns=document.querySelectorAll('.ytp-skip-ad-button,.ytp-ad-skip-button,.ytp-ad-skip-button-modern,.ytp-ad-skip-button-slot button,#skip-button button');
      for(var i=0;i<btns.length;i++){ try{btns[i].click();}catch(e){} }
      var ad=document.querySelector('.ad-showing');
      var v=document.querySelector('video');
      if(ad && v){
        try{
          v.muted=true; v.playbackRate=8;
          if(v.duration && isFinite(v.duration) && v.duration<180 && v.duration-v.currentTime>0.8){
            v.currentTime=v.duration-0.3;
          }
        }catch(e){}
      }
    }catch(e){}
  },500);
})();
''';

  @override
  void initState() {
    super.initState();
    _fetchClip();
    // Плашка поверх рекламы — прячем через 5 сек в любом случае
    _veilTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showAdVeil = false);
    });
  }

  @override
  void dispose() {
    _veilTimer?.cancel();
    _skipTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchClip() async {
    final q = '${widget.song.artist ?? ''} ${widget.song.title} clip'.trim();
    try {
      final api = YandexMusicPublicApi();
      final clips =
          await api.getArtistVideosByName(q, limit: 3).timeout(const Duration(seconds: 8));
      if (clips.isNotEmpty) {
        final c = clips.first;
        String? pid = c['providerVideoId']?.toString() ?? c['id']?.toString();
        String? thumb = c['cover']?.toString() ??
            c['thumbnail']?.toString() ??
            c['ogImage']?.toString();
        if (thumb != null && thumb.isNotEmpty) {
          thumb = thumb.replaceAll('%%', '400x225');
          if (!thumb.startsWith('http')) thumb = 'https://$thumb';
        }
        if (pid != null && RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(pid)) {
          _videoId = pid;
          _thumbUrl = thumb ?? 'https://img.youtube.com/vi/$pid/hqdefault.jpg';
        } else if (thumb != null) {
          _thumbUrl = thumb;
        }
        if (_videoId == null && c['embedUrl'] != null) {
          final m = RegExp(
                  r'(?:youtu\.be/|youtube\.com/(?:embed/|watch\?v=))([a-zA-Z0-9_-]{11})')
              .firstMatch(c['embedUrl'].toString());
          if (m != null) {
            _videoId = m.group(1);
            _thumbUrl ??= 'https://img.youtube.com/vi/$_videoId/hqdefault.jpg';
          }
        }
      }
    } catch (_) {}
    if (!mounted) return;
    if (_videoId == null) {
      setState(() {
        _loading = false;
        _noClip = true;
      });
      return;
    }
    final id = _videoId!;
    final html = '''
<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
<style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}iframe{width:100%;height:100%;border:0}</style>
</head><body>
<iframe src="https://www.youtube-nocookie.com/embed/$id?autoplay=1&mute=1&loop=1&playlist=$id&controls=0&rel=0&modestbranding=1&playsinline=1&start=0&end=40&enablejsapi=1" allow="autoplay; encrypted-media; fullscreen" allowfullscreen></iframe>
<script>$_adSkipJs</script>
</body></html>''';
    final controller = WebViewController();
    controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    controller.setBackgroundColor(const Color(0xFF000000));
    controller.setNavigationDelegate(NavigationDelegate(
      onPageFinished: (_) async {
        if (mounted) setState(() => _loading = false);
        try {
          await controller.runJavaScript(_adSkipJs);
        } catch (_) {}
      },
      onWebResourceError: (_) {
        if (mounted) setState(() => _loading = false);
      },
    ));
    controller.loadHtmlString(html);
    // Дублируем скип из Dart-раз в секунду — если страницу пересоздало
    _skipTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        await controller.runJavaScript(_adSkipJs);
      } catch (_) {}
    });
    if (mounted) {
      setState(() {
        _controller = controller;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = '${widget.song.artist ?? ''} — ${widget.song.title}';
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(CupertinoIcons.chevron_down,
                        color: Colors.white, size: 28),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          'КЛИП • 40 СЕК',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                        Text(
                          title,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: _noClip
                    ? const Text('Клип не найден',
                        style: TextStyle(color: Colors.white54))
                    : AspectRatio(
                        aspectRatio: 16 / 9,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (_controller != null)
                              WebViewWidget(controller: _controller!),
                            if (_loading || _showAdVeil)
                              Container(
                                color: Colors.black,
                                child: Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white54),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        _loading
                                            ? 'Загружаем клип…'
                                            : 'Пропускаем рекламу…',
                                        style: const TextStyle(
                                            color: Colors.white54,
                                            fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Без звука • повтор 40 сек • как шоты',
                  style: TextStyle(color: Colors.white38, fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }
}
