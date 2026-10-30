import 'dart:async';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/kumaflow_brain/kumaflow_brain_bridge.dart';
import '../services/kumaflow_brain/kumaflow_brain_client.dart';
import '../services/kumaflow_brain/kumaflow_brain_mapper.dart';
import '../services/kumaflow_brain/kumaflow_brain_wave_resolver.dart';
import '../services/subsonic_service.dart';

/// Sonar: узнавание трека через микрофон (как Шазам, в цветах KumaFlow).
/// Кнопка микрофона (home AppBar) ведёт сюда редиректом.
/// Поток: статус сонара -> запись ~10с (WAV) -> POST /api/sonar/recognize
/// -> карточка совпадения с обложкой (Играть / В очередь) или «не узнал».
/// Всё best-effort: мост выкл/офлайн/сеть — хинт, ничего не рвём.
class SonarScreen extends StatefulWidget {
  const SonarScreen({super.key});

  @override
  State<SonarScreen> createState() => _SonarScreenState();
}

enum _SonarPhase {
  checking,
  ready,
  recording,
  recognizing,
  done,
}

class _SonarMatch {
  final String title;
  final String artist;
  final Song? song;
  final int tookMs;
  const _SonarMatch({
    required this.title,
    required this.artist,
    this.song,
    this.tookMs = 0,
  });
}

class _SonarScreenState extends State<SonarScreen>
    with SingleTickerProviderStateMixin {
  _SonarPhase _phase = _SonarPhase.checking;
  String? _statusError;
  bool _sonarEnabled = false;
  /// Предупреждение о покрытии отпечатками (не блокирует кнопку):
  /// сонар включён, но enroll не снят — узнавание вернёт «не узнал».
  String? _coverageNote;
  final AudioRecorder _recorder = AudioRecorder();
  late final AnimationController _pulse;
  Timer? _tick;
  int _secondsLeft = 0;
  static const int _recordSeconds = 10;
  _SonarMatch? _match;
  String? _error;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _checkStatus();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _pulse.dispose();
    try {
      _recorder.dispose();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _checkStatus() async {
    setState(() {
      _phase = _SonarPhase.checking;
      _statusError = null;
      _coverageNote = null;
    });
    try {
      final bridge =
          Provider.of<KumaFlowBrainBridge>(context, listen: false);
      if (!bridge.isActive) {
        if (!mounted) return;
        setState(() {
          _phase = _SonarPhase.ready;
          _sonarEnabled = false;
          _statusError =
              'KumaFlow Brain не подключён.\nНастройки → ML → KumaFlow Brain: ВКЛ + URL + Подключить.';
        });
        return;
      }
      final client = bridge.client;
      if (client == null) throw StateError('no client');
      final st =
          await client.sonarStatus().timeout(const Duration(seconds: 8));
      if (!mounted) return;
      final enabled = st['enabled'] == true;
      // Покрытие отпечатками: включили тумблер, но enroll не снят —
      // узнавать нечего. Показываем хинт, кнопку не блокируем.
      String? coverageNote;
      String? disabledMsg;
      if (enabled) {
        final cov = st['coverage'];
        if (cov is Map) {
          final cm = Map<String, dynamic>.from(cov);
          final fp = cm['fingerprinted'];
          final total = cm['tracks_total'];
          final fpN = fp is num ? fp.toInt() : int.tryParse('$fp') ?? -1;
          final totalN =
              total is num ? total.toInt() : int.tryParse('$total') ?? -1;
          if (fpN == 0) {
            coverageNote = totalN > 0
                ? 'Сонар включён, но отпечатков нет (0 из $totalN).\n'
                    'Запусти сканирование: админ → POST /api/sonar/enroll.'
                : 'Сонар включён, но отпечатков нет.\n'
                    'Запусти сканирование: админ → POST /api/sonar/enroll.';
          }
        }
      } else {
        disabledMsg =
            'Сонар выключен на сервере.\nВключи тумблер: веб → Настройки → Автоматизация → Сонар.';
      }
      setState(() {
        _phase = _SonarPhase.ready;
        _sonarEnabled = enabled;
        _statusError = disabledMsg;
        _coverageNote = coverageNote;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _SonarPhase.ready;
        _sonarEnabled = false;
        _statusError = _friendlySonarError(e);
      });
    }
  }

  /// Человекочитаемая ошибка сонара вместо сырого
  /// `KumaFlowBrainException(404): Not Found`.
  /// Сервер: _ensure_enabled кидает 403 при выключенном тумблере
  /// (server/app/api/sonar.py), 404 — неверный URL/старый мозг.
  static String _friendlySonarError(Object e) {
    if (e is KumaFlowBrainException && e.statusCode == 403) {
      return 'Сонар выключен тумблером.\n'
          'Веб → Настройки → Автоматизация → Сонар: ВКЛ.';
    }
    if (e is KumaFlowBrainException && e.statusCode == 404) {
      return 'Эндпоинт не найден (404).\n'
          'Проверь URL мозга в Настройки → ML — нужен корень сервера,\n'
          'напр. http://192.168.1.10:3030 (без /api хвоста).';
    }
    if (e is TimeoutException) {
      return 'Сервер не отвечает (таймаут).\nПроверь, что мозг запущен и доступен в LAN.';
    }
    final msg = e.toString().replaceAll(
        RegExp(r'KumaFlowBrainException\(\d+\):\s*'), '');
    return 'Сервер не отвечает: $msg';
  }

  Future<void> _startListening() async {
    if (_phase == _SonarPhase.recording ||
        _phase == _SonarPhase.recognizing) {
      return;
    }
    setState(() {
      _error = null;
      _match = null;
    });
    // 1) Разрешение на микрофон.
    try {
      var status = await Permission.microphone.status;
      if (!status.isGranted) {
        status = await Permission.microphone.request();
      }
      if (!status.isGranted) {
        if (!mounted) return;
        setState(() => _error =
            'Нет доступа к микрофону. Разреши в настройках телефона.');
        return;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Микрофон недоступен: $e');
      return;
    }
    // 2) Запись ~10с в WAV (сервер точно декодирует; m4a требует ffmpeg).
    String path;
    try {
      final dir = await getTemporaryDirectory();
      path =
          '${dir.path}/sonar_${DateTime.now().millisecondsSinceEpoch}.wav';
      final hasPerm = await _recorder.hasPermission();
      if (!hasPerm) {
        if (!mounted) return;
        setState(() => _error = 'Нет доступа к микрофону.');
        return;
      }
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.wav),
        path: path,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Не started запись: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _phase = _SonarPhase.recording;
      _secondsLeft = _recordSeconds;
    });
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted) return;
      if (_secondsLeft <= 1) {
        _tick?.cancel();
        await _stopAndRecognize(path);
        return;
      }
      setState(() => _secondsLeft--);
    });
  }

  Future<void> _cancelRecording() async {
    _tick?.cancel();
    try {
      await _recorder.stop();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _phase = _SonarPhase.ready);
  }

  Future<void> _stopAndRecognize(String path) async {
    _tick?.cancel();
    final bridge =
        Provider.of<KumaFlowBrainBridge>(context, listen: false);
    final subsonic =
        Provider.of<SubsonicService>(context, listen: false);
    String? stoppedPath;
    try {
      stoppedPath = await _recorder.stop();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _phase = _SonarPhase.recognizing);
    try {
      final file = File(stoppedPath ?? path);
      if (!await file.exists()) throw StateError('запись пропала');
      final bytes = await file.readAsBytes();
      try {
        await file.delete();
      } catch (_) {}
      if (bytes.length < 8000) {
        throw StateError('слишком тихо — поднеси ближе к звуку');
      }
      final client = bridge.client;
      if (client == null) throw StateError('KumaFlow Brain выключен');
      final res = await client
          .sonarRecognize(bytes, filename: 'query.wav')
          .timeout(const Duration(seconds: 30));
      final m = res['match'];
      if (m is! Map) {
        if (!mounted) return;
        setState(() {
          _phase = _SonarPhase.done;
          _match = null;
          _error = null;
        });
        return;
      }
      final mm = Map<String, dynamic>.from(m);
      final title = (mm['title'] ?? '').toString();
      final artist = (mm['artist_name'] ?? mm['artist'] ?? '').toString();
      final took =
          res['took_ms'] is num ? (res['took_ms'] as num).toInt() : 0;
      // Резолв в играбельный Song: external_id напрямую, иначе поиск.
      Song? song;
      try {
        final ext = (mm['external_id'] ?? '').toString();
        final tid = (mm['track_id'] ?? '').toString();
        if (ext.isNotEmpty) {
          try {
            song = await subsonic
                .getSong(ext)
                .timeout(const Duration(seconds: 6));
          } catch (_) {}
        }
        if (song == null) {
          final resolved = await KumaFlowBrainWaveResolver(subsonic)
              .resolve(
                [
                  KumaFlowBrainTrack(
                    trackId: tid.isNotEmpty ? tid : ext,
                    externalId: ext.isNotEmpty ? ext : null,
                    title: title,
                    artist: artist,
                    score: 0,
                    reason: 'sonar',
                  )
                ],
                maxTracks: 1,
              )
              .timeout(const Duration(seconds: 15));
          if (resolved.found.isNotEmpty) song = resolved.found.first.song;
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _phase = _SonarPhase.done;
        _error = null;
        _match = _SonarMatch(
          title: title.isNotEmpty ? title : 'Без названия',
          artist: artist,
          song: song,
          tookMs: took,
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _SonarPhase.done;
        _match = null;
        _error = _friendlySonarError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/logobig.png', width: 28, height: 28),
            const SizedBox(width: 8),
            const Text('Sonar'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(CupertinoIcons.refresh, size: 20),
            onPressed: _phase == _SonarPhase.checking ? null : _checkStatus,
          ),
        ],
      ),
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0B1035), Color(0xFF1B1147), Color(0xFF2A0E4F)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_phase == _SonarPhase.checking) ...[
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 16),
                    const Text('Проверяю сонар…',
                        style: TextStyle(
                            color: Colors.white70, fontSize: 14)),
                  ] else if (_statusError != null &&
                      _phase != _SonarPhase.recording &&
                      _phase != _SonarPhase.recognizing) ...[
                    const Icon(CupertinoIcons.mic_slash,
                        size: 56, color: Colors.white38),
                    const SizedBox(height: 16),
                    Text(_statusError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 14)),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _checkStatus,
                      icon: const Icon(CupertinoIcons.refresh, size: 16),
                      label: const Text('Проверить снова'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white),
                    ),
                  ] else ...[
                    _buildMicButton(),
                    const SizedBox(height: 24),
                    _buildHint(),
                    if (_coverageNote != null &&
                        _phase != _SonarPhase.recording &&
                        _phase != _SonarPhase.recognizing) ...[
                      const SizedBox(height: 12),
                      Text(_coverageNote!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.orangeAccent, fontSize: 13)),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.redAccent, fontSize: 13)),
                    ],
                    if (_match != null) ...[
                      const SizedBox(height: 24),
                      _buildResultCard(),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHint() {
    const grey = TextStyle(fontSize: 14, color: Colors.white70);
    const white = TextStyle(
        fontSize: 17, color: Colors.white, fontWeight: FontWeight.w600);
    switch (_phase) {
      case _SonarPhase.recording:
        return Column(children: [
          Text('Слушаю… $_secondsLeft с', style: white),
          const SizedBox(height: 4),
          const Text('тап по кнопке — отмена',
              style: TextStyle(fontSize: 12, color: Colors.white54)),
        ]);
      case _SonarPhase.recognizing:
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white)),
            SizedBox(width: 10),
            Text('Узнаю трек…', style: grey),
          ],
        );
      case _SonarPhase.done:
        return const Text('Нажми ещё раз, чтобы узнать другой трек',
            style: TextStyle(fontSize: 13, color: Colors.white54));
      default:
        return const Text(
            'Нажми и поднеси телефон к звуку\n(~10 секунд)',
            textAlign: TextAlign.center,
            style: grey);
    }
  }

  /// Кнопка микрофона: в покое — сине-фиолетовая с медленным дыханием,
  /// при записи — красно-оранжевая, вокруг расходящиеся кольца + кольцо
  /// прогресса 10с. Иконка плеера — лого KumaFlow по центру? Нет: микрофон
  /// крупно, лого уже в AppBar — не лепим всё в кучу.
  Widget _buildMicButton() {
    final listening = _phase == _SonarPhase.recording;
    final busy = listening || _phase == _SonarPhase.recognizing;
    final progress =
        listening ? 1.0 - _secondsLeft / _recordSeconds : 0.0;
    return GestureDetector(
      onTap: listening
          ? _cancelRecording
          : (_sonarEnabled && !busy ? _startListening : null),
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (ctx, _) {
          final breathe = 0.5 + _pulse.value * 0.5; // 0.5..1
          return SizedBox(
            width: 240,
            height: 240,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Расходящиеся кольца при записи.
                if (listening)
                  for (var i = 0; i < 3; i++)
                    _Ring(
                      progress: ((_pulse.value + i / 3) % 1.0),
                      color: const Color(0xFFFF3B30),
                    ),
                // Кольцо прогресса записи 10с.
                SizedBox(
                  width: 200,
                  height: 200,
                  child: CircularProgressIndicator(
                    value: listening ? progress : 0,
                    strokeWidth: 5,
                    backgroundColor: Colors.white12,
                    valueColor: AlwaysStoppedAnimation<Color>(
                        listening
                            ? const Color(0xFFFF9500)
                            : Colors.white30),
                  ),
                ),
                // Сама кнопка.
                Transform.scale(
                  scale: listening ? 1.0 + _pulse.value * 0.06 : 1.0,
                  child: Container(
                    width: 160,
                    height: 160,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: listening
                            ? const [
                                Color(0xFFFF3B30),
                                Color(0xFFFF9500)
                              ]
                            : const [
                                Color(0xFF007AFF),
                                Color(0xFF5856D6)
                              ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: (listening
                                  ? const Color(0xFFFF3B30)
                                  : const Color(0xFF007AFF))
                              .withValues(
                                  alpha: listening
                                      ? 0.35 + breathe * 0.25
                                      : 0.25 + breathe * 0.15),
                          blurRadius: listening ? 40 : 24,
                          spreadRadius: listening ? 6 : 2,
                        ),
                      ],
                    ),
                    child: Icon(
                      listening
                          ? CupertinoIcons.stop_fill
                          : CupertinoIcons.mic_fill,
                      color: Colors.white,
                      size: 64,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildResultCard() {
    final m = _match!;
    if (m.song == null) {
      return _ResultShell(
        icon: CupertinoIcons.question_circle,
        iconColor: Colors.white54,
        title: m.title,
        subtitle: m.artist.isNotEmpty ? m.artist : null,
        note: 'Узнал, но трека нет в твоей библиотеке',
        child: OutlinedButton.icon(
          onPressed: _sonarEnabled ? _startListening : null,
          icon: const Icon(CupertinoIcons.refresh, size: 16),
          label: const Text('Попробовать ещё'),
          style:
              OutlinedButton.styleFrom(foregroundColor: Colors.white),
        ),
      );
    }
    final s = m.song!;
    final player = Provider.of<PlayerProvider>(context, listen: false);
    String coverUrl = '';
    try {
      final subsonic =
          Provider.of<SubsonicService>(context, listen: false);
      coverUrl = subsonic.getCoverArtUrl(s.coverArt, size: 300);
    } catch (_) {}
    return _ResultShell(
      icon: null,
      iconColor: null,
      title: s.title,
      subtitle: (s.artist ?? '').isNotEmpty ? s.artist : null,
      note: m.tookMs > 0 ? '${m.tookMs} мс • Sonar' : 'Sonar',
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: coverUrl.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: coverUrl,
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) =>
                    _fallbackArt(),
              )
            : _fallbackArt(),
      ),
      child: Row(children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: () =>
                player.playSong(s, playlist: [s], startIndex: 0),
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('Играть'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () {
              player.addToQueue(s);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('В очереди'),
                  duration: Duration(seconds: 2)));
            },
            icon: const Icon(Icons.queue_music_rounded, size: 18),
            label: const Text('В очередь'),
            style:
                OutlinedButton.styleFrom(foregroundColor: Colors.white),
          ),
        ),
      ]),
    );
  }

  Widget _fallbackArt() {
    return Container(
      width: 64,
      height: 64,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF007AFF), Color(0xFF5856D6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Icon(Icons.music_note_rounded,
          color: Colors.white, size: 32),
    );
  }
}

/// Карточка результата: стекло поверх градиента.
class _ResultShell extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final String? note;
  final Widget? leading;
  final Widget? child;
  const _ResultShell({
    this.icon,
    this.iconColor,
    required this.title,
    this.subtitle,
    this.note,
    this.leading,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Column(children: [
        Row(children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 12),
          ] else if (icon != null) ...[
            Icon(icon, size: 44, color: iconColor ?? Colors.white),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.bold)),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Text(subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 14)),
                if (note != null)
                  Text(note!,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 11)),
              ],
            ),
          ),
        ]),
        if (child != null) ...[
          const SizedBox(height: 12),
          child!,
        ],
      ]),
    );
  }
}

/// Расходящееся кольцо пульса (0=центр → 1=край, затухание).
class _Ring extends StatelessWidget {
  final double progress;
  final Color color;
  const _Ring({required this.progress, required this.color});

  @override
  Widget build(BuildContext context) {
    final size = 170 + progress * 70;
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: color.withValues(alpha: (1 - progress) * 0.6),
            width: 3,
          ),
        ),
      ),
    );
  }
}
