import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/kumaflow_brain/kumaflow_brain_bridge.dart';
import '../services/kumaflow_brain/kumaflow_brain_client.dart';
import '../services/brain_new_arrivals_service.dart';
import '../services/kumaflow_brain/kumaflow_brain_mapper.dart';
import '../services/kumaflow_brain/kumaflow_brain_playback.dart';
import '../services/kumaflow_brain/kumaflow_brain_settings.dart';
import '../services/kumaflow_brain/kumaflow_brain_wave_resolver.dart';
import '../services/subsonic_service.dart';
import '../services/wave_identity.dart';
import '../providers/player_provider.dart';

/// Экраны KumaFlow Brain: волна / weekly / vault / динамика / уведомления / обложки.
/// Всё best-effort: сервер недоступен -> тихий fallback, очередь не рвём.
/// Открывается из Настройки -> ML -> KumaFlow Brain -> "Открыть экраны KumaFlow Brain".
class KumaFlowBrainScreen extends StatelessWidget {
  const KumaFlowBrainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<KumaFlowBrainSettings>(context);
    return Scaffold(
      appBar: AppBar(title: const Text('KumaFlow Brain')),
      body: !settings.isActive
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'KumaFlow Brain не подключён.\nНастройки → ML → KumaFlow Brain: ВКЛ + URL + Подключить.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: const [
                _WaveCard(),
                SizedBox(height: 12),
                _WeeklyCard(),
                SizedBox(height: 12),
                _VaultCard(),
                SizedBox(height: 12),
                _DynamicsCard(),
                SizedBox(height: 12),
                _NotifCard(),
                SizedBox(height: 12),
                _TuningCard(),
                SizedBox(height: 12),
                _CoversCard(),
                SizedBox(height: 32),
              ],
            ),
    );
  }
}

// ---------------- Волна ----------------

class _WaveCard extends StatefulWidget {
  const _WaveCard();
  @override
  State<_WaveCard> createState() => _WaveCardState();
}

class _WaveCardState extends State<_WaveCard> {
  bool _busy = false;
  double _progress = 0;
  List<KumaFlowBrainResolved> _found = const [];
  List<KumaFlowBrainTrack> _missing = const [];
  List<KumaFlowBrainTrack> _raw = const [];
  String? _error;

  Future<void> _fetch() async {
    final settings = Provider.of<KumaFlowBrainSettings>(context, listen: false);
    final bridge = Provider.of<KumaFlowBrainBridge>(context, listen: false);
    final subsonic = Provider.of<SubsonicService>(context, listen: false);
    final player = Provider.of<PlayerProvider>(context, listen: false);
    final client = bridge.client;
    if (client == null) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _error = null;
      _found = const [];
      _missing = const [];
      _raw = const [];
    });
    try {
      final queueIds = player.queue.map((s) => s.id).toList();
      final currentId = player.queue.isNotEmpty &&
              player.currentIndex >= 0 &&
              player.currentIndex < player.queue.length
          ? player.queue[player.currentIndex].id
          : null;
      // Живые фильтры: общие с мозга (кеш в бридже) + глобальный снапшот.
      // Глобальный почти всегда пуст (пилюли живут в шите home), но если
      // задан — побеждает.
      final shared = await bridge.fetchSharedWaveSettings();
      final waveSettings = <String, dynamic>{
        ...shared,
        ...settings.waveSettingsMap,
      };
      final res = await client.waveContinue(
        userId: settings.userId,
        queue: queueIds,
        currentTrackId: currentId,
        count: settings.waveCount,
        settings: waveSettings,
      );
      final tracks = KumaFlowBrainMapper.parseWaveTracks(res);
      if (!mounted) return;
      setState(() => _raw = tracks);
      final resolved = await KumaFlowBrainWaveResolver(subsonic).resolve(
        tracks,
        onProgress: (done, total) async {
          if (mounted) setState(() => _progress = done / total);
        },
      );
      if (!mounted) return;
      setState(() {
        _found = resolved.found;
        _missing = resolved.missing;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _enqueueAll() {
    final player = Provider.of<PlayerProvider>(context, listen: false);
    var added = 0;
    for (final r in _found) {
      final before = player.queue.length;
      player.addToQueue(r.song);
      if (player.queue.length > before) added++;
    }
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('В очередь: $added (найдено ${_found.length})')));
  }

  Future<void> _playNow() async {
    if (_found.isEmpty) return;
    final player = Provider.of<PlayerProvider>(context, listen: false);
    final songs = _found.map((r) => r.song).toList();
    // Волна мозга — обычная волна: сид гасим, контекст пишем.
    await clearWaveSeed();
    await saveWaveContext(
        songs.map((s) => s.id).toList(), 'Моя волна', 'brain');
    await player.playSong(
      songs.first,
      playlist: songs,
      startIndex: 0,
      playlistName: 'Моя волна',
      isWave: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<KumaFlowBrainSettings>(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.waves_rounded, color: Color(0xFF007AFF)),
            const SizedBox(width: 8),
            const Expanded(
                child: Text('Волна',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
            Switch(
              value: settings.waveEnabled,
              onChanged: (v) => settings.setWaveEnabled(v),
            ),
          ]),
          const Text(
            'Очередь живёт в клиенте, KumaFlow Brain только докладывает. Подмес — только кнопками ниже, авто-подмеса в плеер нет.',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : _fetch,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: Text(_busy ? 'Идёт…' : 'Запросить (${settings.waveCount})'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _found.isEmpty ? null : _enqueueAll,
                icon: const Icon(Icons.queue_music_rounded, size: 16),
                label: const Text('В очередь'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _found.isEmpty ? null : _playNow,
                icon: const Icon(Icons.play_arrow_rounded, size: 16),
                label: const Text('Играть'),
              ),
            ),
          ]),
          if (_busy) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
          ],
          if (_raw.isNotEmpty || _found.isNotEmpty || _missing.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
                'KumaFlow Brain дал ${_raw.length}, играбельно ${_found.length}, не найдено ${_missing.length} (ищем по title+artist — uuid без external_id).',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ..._found.take(20).map((r) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                      r.brain.title.isNotEmpty ? r.brain.title : r.song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      '${r.brain.artist.isNotEmpty ? r.brain.artist : (r.song.artist ?? '')} • ${r.brain.score.toStringAsFixed(2)}${r.brain.reason.isNotEmpty ? ' • ${r.brain.reason}' : ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    icon: const Icon(Icons.add_rounded, size: 18),
                    onPressed: () =>
                        Provider.of<PlayerProvider>(context, listen: false)
                            .addToQueue(r.song),
                  ),
                )),
            if (_missing.isNotEmpty)
              Text('Нет в библиотеке: ${_missing.take(5).map((t) => t.title.isNotEmpty ? t.title : t.trackId).join(', ')}${_missing.length > 5 ? '…' : ''}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ]),
      ),
    );
  }
}

// ---------------- Weekly ----------------

class _WeeklyCard extends StatefulWidget {
  const _WeeklyCard();
  @override
  State<_WeeklyCard> createState() => _WeeklyCardState();
}

class _WeeklyCardState extends State<_WeeklyCard> {
  int _n = 30;
  bool _busy = false;
  String? _mode;
  String? _playlistId;
  List<Map<String, dynamic>> _expl = const [];
  String? _error;

  Future<void> _fetch() async {
    final settings = Provider.of<KumaFlowBrainSettings>(context, listen: false);
    final bridge = Provider.of<KumaFlowBrainBridge>(context, listen: false);
    final client = bridge.client;
    if (client == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await client.weeklyDiscovery(settings.userId, n: _n);
      if (!mounted) return;
      final expl = res['explanations'];
      setState(() {
        _mode = (res['mode'] ?? '').toString();
        _playlistId = (res['playlist_id'] ?? '').toString();
        _expl = expl is List
            ? expl.whereType<Map>().map(Map<String, dynamic>.from).toList()
            : const [];
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enqueueExpl() async {
    final subsonic = Provider.of<SubsonicService>(context, listen: false);
    final player = Provider.of<PlayerProvider>(context, listen: false);
    final tracks = _expl
        .map((e) => KumaFlowBrainTrack(
              trackId: (e['track_id'] ?? '').toString(),
              title: (e['because_of_title'] ?? '').toString(),
              artist: '',
              score: (e['score'] is num) ? (e['score'] as num).toDouble() : 0,
              reason: (e['text'] ?? '').toString(),
            ))
        .where((t) => t.trackId.isNotEmpty)
        .toList();
    final resolved =
        await KumaFlowBrainWaveResolver(subsonic).resolve(tracks, maxTracks: 30);
    var added = 0;
    for (final r in resolved.found) {
      final before = player.queue.length;
      player.addToQueue(r.song);
      if (player.queue.length > before) added++;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Weekly в очередь: $added (не найдено ${resolved.missing.length})')));
    }
  }

  /// M5: пункт «Weekly Discovery» в playback: weeklyDiscovery(n) -> резолв
  /// как в _getKumaFlowBrainSongs (uuid обогащаем через getTrack) -> играть.
  Future<void> _playWeeklyNow() async {
    final bridge = Provider.of<KumaFlowBrainBridge>(context, listen: false);
    final subsonic = Provider.of<SubsonicService>(context, listen: false);
    final player = Provider.of<PlayerProvider>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final songs = await KumaFlowBrainPlayback.fetchWeekly(
        bridge: bridge,
        subsonic: subsonic,
        n: _n,
      );
      if (!mounted) return;
      await clearWaveSeed();
      await player.playSong(
        songs.first,
        playlist: songs,
        startIndex: 0,
        playlistName: 'Открытия недели',
      );
      messenger.showSnackBar(
          SnackBar(content: Text('🧠 Открытия недели: ${songs.length} треков')));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.auto_awesome_rounded, color: Color(0xFFAF52DE)),
            SizedBox(width: 8),
            Expanded(
                child: Text('Открытия недели',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
          ]),
          const Text('CLAP или cold_start_fallback. «Почему трек» — из поля text.',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
          Row(children: [
            Expanded(
                child: Slider(
                    value: _n.toDouble(),
                    min: 5,
                    max: 50,
                    divisions: 9,
                    label: '$_n',
                    onChanged: (v) => setState(() => _n = v.round()))),
            Text('$_n'),
            const SizedBox(width: 8),
            FilledButton(
                onPressed: _busy ? null : _fetch,
                child: Text(_busy ? '…' : 'Собрать')),
          ]),
          if (_error != null)
            Text(_error!,
                style: const TextStyle(color: Colors.red, fontSize: 12)),
          if (_mode != null) ...[
            Text('mode: $_mode • playlist: ${_playlistId ?? '—'}',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _expl.isEmpty ? null : _enqueueExpl,
                  icon: const Icon(Icons.queue_music_rounded, size: 16),
                  label: const Text('В очередь'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: (_busy || _expl.isEmpty) ? null : _playWeeklyNow,
                  icon: const Icon(Icons.play_arrow_rounded, size: 16),
                  label: const Text('Играть'),
                ),
              ),
            ]),
            ..._expl.take(15).map((e) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text((e['text'] ?? e['track_id'] ?? '').toString(),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      'score ${(e['score'] ?? '').toString()} • из-за «${e['because_of_title'] ?? ''}»',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                )),
          ],
        ]),
      ),
    );
  }
}

// ---------------- Vault ----------------

class _VaultCard extends StatefulWidget {
  const _VaultCard();
  @override
  State<_VaultCard> createState() => _VaultCardState();
}

class _VaultCardState extends State<_VaultCard> {
  final _passCtrl = TextEditingController();
  bool _busy = false;
  String? _status;
  String? _run;
  bool _vaultAutoChecked = false;

  @override
  void dispose() {
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _runFn(Future<String> Function() fn) async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final s = await fn();
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) setState(() => _status = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<KumaFlowBrainSettings>(context);
    final bridge = Provider.of<KumaFlowBrainBridge>(context);
    final client = bridge.client;
    // Лёгкая проверка сейфа один раз при открытии (best-effort, без импорта).
    if (!_vaultAutoChecked && client != null && !_busy) {
      _vaultAutoChecked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          bridge.fetchVaultStatus();
        } catch (_) {}
      });
    }
    final badge = bridge.vaultBadge;
    final needsAttention = bridge.vaultNeedsAttention;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.lock_rounded, color: Color(0xFFFF9500)),
            const SizedBox(width: 8),
            const Expanded(
                child: Text('Вкусы фоном (vault)',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
            if (badge != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: needsAttention
                      ? Colors.orange.withValues(alpha: 0.15)
                      : Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text('сейф: $badge',
                    style: TextStyle(
                        fontSize: 11,
                        color: needsAttention
                            ? Colors.orange
                            : Colors.green)),
              ),
          ]),
          const Text('Opt-in, Fernet (TASTE_VAULT_KEY на сервере). Пароль — только сюда.',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _passCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Пароль Navidrome',
                    border: OutlineInputBorder(),
                    isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: (_busy || client == null)
                  ? null
                      : () => _runFn(() async {
                        final cc = bridge.client;
                        if (cc == null) throw KumaFlowBrainException('KumaFlow Brain выключен');
                        await cc.postVault(settings.userId, _passCtrl.text);
                        _passCtrl.clear();
                        try {
                          await bridge.fetchVaultStatus(force: true);
                        } catch (_) {}
                        return 'Пароль сохранён (vault).';
                      }),
              child: const Text('Запомнить'),
            ),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(
                onPressed: (_busy || client == null)
                    ? null
                    : () => _runFn(() async {
                          final cc = bridge.client;
                          if (cc == null) throw KumaFlowBrainException('KumaFlow Brain выключен');
                          final r = await cc.getVault(settings.userId);
                          return 'Статус: ${jsonEncode(r).characters.take(200)}';
                        }),
                child: const Text('Статус')),
            OutlinedButton(
                onPressed: (_busy || client == null)
                    ? null
                    : () => _runFn(() async {
                          final cc = bridge.client;
                          if (cc == null) throw KumaFlowBrainException('KumaFlow Brain выключен');
                          final r = await bridge.fetchVaultStatus(force: true);
                          final b = bridge.vaultBadge ?? '—';
                          return 'Сейф: $b (${jsonEncode(r).characters.take(160)})';
                        }),
                child: const Text('Проверить сейф')),
            OutlinedButton(
                onPressed: (_busy || client == null)
                    ? null
                    : () => _runFn(() async {
                          final cc = bridge.client;
                          if (cc == null) throw KumaFlowBrainException('KumaFlow Brain выключен');
                          await cc.deleteVault(settings.userId);
                          bridge.clearVaultStatus();
                          return 'Забыто (vault удалён).';
                        }),
                child: const Text('Забыть')),
            OutlinedButton(
                onPressed: (_busy || client == null)
                    ? null
                    : () => _runFn(() async {
                          final cc = bridge.client;
                          if (cc == null) throw KumaFlowBrainException('KumaFlow Brain выключен');
                          final r = await cc.refreshNow(settings.userId);
                          return 'refresh-now: ${jsonEncode(r).characters.take(200)}';
                        }),
                child: const Text('Обновить сейчас')),
            OutlinedButton(
                onPressed: (_busy || client == null)
                    ? null
                    : () => _runFn(() async {
                          final cc = bridge.client;
                          if (cc == null) throw KumaFlowBrainException('KumaFlow Brain выключен');
                          final r = await cc.refreshAsync(settings.userId);
                          _run = (r['run_id'] ?? '').toString();
                          return 'refresh-async run: $_run';
                        }),
                child: const Text('Фоном (async)')),
            OutlinedButton(
                onPressed: (_busy || client == null)
                    ? null
                    : () => _runFn(() async {
                          final cc = bridge.client;
                          if (cc == null) throw KumaFlowBrainException('KumaFlow Brain выключен');
                          final r = await cc.scanCurrent();
                          return 'scan/current: ${jsonEncode(r).characters.take(200)}';
                        }),
                child: const Text('Прогресс')),
          ]),
          if (_busy) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator()
          ],
          if (_status != null) ...[
            const SizedBox(height: 8),
            SelectableText(_status!, style: const TextStyle(fontSize: 12)),
          ],
        ]),
      ),
    );
  }
}

// ---------------- Динамика ----------------

class _DynamicsCard extends StatefulWidget {
  const _DynamicsCard();
  @override
  State<_DynamicsCard> createState() => _DynamicsCardState();
}

class _DynamicsCardState extends State<_DynamicsCard> {
  bool _busy = false;
  String? _out;

  Future<void> _runFn(Future<Map<String, dynamic>> Function(KumaFlowBrainClient, String) fn) async {
    final bridge = Provider.of<KumaFlowBrainBridge>(context, listen: false);
    final settings = Provider.of<KumaFlowBrainSettings>(context, listen: false);
    final client = bridge.client;
    if (client == null) return;
    setState(() {
      _busy = true;
      _out = null;
    });
    try {
      final r = await fn(client, settings.userId);
      if (mounted) {
        setState(() => _out =
            const JsonEncoder.withIndent('  ').convert(r).characters.take(2000).toString());
      }
    } catch (e) {
      if (mounted) setState(() => _out = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.insights_rounded, color: Color(0xFF34C759)),
            SizedBox(width: 8),
            Expanded(
                child: Text('Динамика вкуса',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
          ]),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _runFn((c, u) => c.getDrift(u, weeksAgo: 4)),
                child: const Text('drift 4н')),
            OutlinedButton(
                onPressed: _busy ? null : () => _runFn((c, u) => c.postDriftSnapshot(u)),
                child: const Text('snapshot')),
            OutlinedButton(
                onPressed: _busy ? null : () => _runFn((c, u) => c.getActivity(u)),
                child: const Text('activity')),
            OutlinedButton(
                onPressed: _busy ? null : () => _runFn((c, u) => c.getWrapped(u)),
                child: const Text('wrapped')),
            OutlinedButton(
                onPressed: () async {
                  final bridge =
                      Provider.of<KumaFlowBrainBridge>(context, listen: false);
                  final settings =
                      Provider.of<KumaFlowBrainSettings>(context, listen: false);
                  final client = bridge.client;
                  if (client == null) return;
                  setState(() {
                    _busy = true;
                    _out = null;
                  });
                  try {
                    final p = await client.getProfile(settings.userId);
                    if (mounted) {
                      setState(() => _out = const JsonEncoder.withIndent('  ')
                          .convert(p)
                          .characters
                          .take(2000)
                          .toString());
                    }
                  } catch (e) {
                    if (mounted) setState(() => _out = 'Ошибка: $e');
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
                child: const Text('profile')),
          ]),
          if (_busy) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator()
          ],
          if (_out != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8)),
              child: SelectableText(_out!,
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
            ),
          ],
        ]),
      ),
    );
  }
}

// ---------------- Уведомления ----------------

class _NotifCard extends StatefulWidget {
  const _NotifCard();
  @override
  State<_NotifCard> createState() => _NotifCardState();
}

class _NotifCardState extends State<_NotifCard> {
  bool _busy = false;
  int? _unread;
  List<Map<String, dynamic>> _items = const [];
  String? _error;
  bool _autoDl = false;
  bool _wifiOnly = true;

  Future<void> _load() async {
    final bridge = Provider.of<KumaFlowBrainBridge>(context, listen: false);
    final settings = Provider.of<KumaFlowBrainSettings>(context, listen: false);
    final client = bridge.client;
    final auto = await BrainNewArrivalsService.autoDownloadEnabled();
    final wifi = await BrainNewArrivalsService.wifiOnly();
    if (!mounted) return;
    setState(() {
      _autoDl = auto;
      _wifiOnly = wifi;
    });
    if (client == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final u = await client.unreadCount(userId: settings.userId);
      final l = await client.notifications(userId: settings.userId, limit: 20);
      if (!mounted) return;
      final items = l['notifications'];
      setState(() {
        _unread = (u['unread'] ?? u['count'] ?? u['unread_count']) is int
            ? (u['unread'] ?? u['count'] ?? u['unread_count']) as int
            : int.tryParse('${u['unread'] ?? u['count'] ?? ''}');
        _items = items is List
            ? items.whereType<Map>().map(Map<String, dynamic>.from).toList()
            : const [];
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    final bridge = Provider.of<KumaFlowBrainBridge>(context, listen: false);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.notifications_rounded,
                color: Color(0xFFFF3B30)),
            const SizedBox(width: 8),
            Expanded(
                child: Text(
                    'Уведомления${_unread != null ? ' ($_unread)' : ''}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold))),
            IconButton(
                onPressed: _busy ? null : _load,
                icon: const Icon(Icons.refresh_rounded, size: 18)),
            TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        final settings = Provider.of<KumaFlowBrainSettings>(context,
                            listen: false);
                        final client = bridge.client;
                        if (client == null) return;
                        await client.markAllRead(userId: settings.userId);
                        _load();
                      },
                child: const Text('Все прочит.')),
          ]),
          const Text('Новые kinds: drift, discovery (+ info/success/warn/error).',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Качать новинки офлайн',
                style: TextStyle(fontSize: 13)),
            subtitle: const Text(
                'Новые треки подписанных артистов — в кеш',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            value: _autoDl,
            onChanged: (v) async {
              setState(() => _autoDl = v);
              await BrainNewArrivalsService.setAutoDownloadEnabled(v);
            },
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Только по Wi-Fi',
                style: TextStyle(fontSize: 13)),
            value: _wifiOnly,
            onChanged: !_autoDl
                ? null
                : (v) async {
                    setState(() => _wifiOnly = v);
                    await BrainNewArrivalsService.setWifiOnly(v);
                  },
          ),
          if (_error != null)
            Text(_error!,
                style: const TextStyle(color: Colors.red, fontSize: 12)),
          ..._items.take(20).map((n) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                    n['read_at'] == null
                        ? Icons.markunread_rounded
                        : Icons.drafts_outlined,
                    size: 16,
                    color: n['read_at'] == null ? Colors.blue : Colors.grey),
                title: Text((n['title'] ?? n['kind'] ?? '').toString(),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text((n['body'] ?? '').toString(),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: n['read_at'] == null
                    ? TextButton(
                        child: const Text('Ок'),
                        onPressed: () async {
                          final client = bridge.client;
                          if (client == null) return;
                          await client.markRead((n['id'] ?? '').toString());
                          _load();
                        },
                      )
                    : null,
              )),
        ]),
      ),
    );
  }
}

// ---------------- Эпоха и глубина (rec-tuning overlay) ----------------

class _TuningCard extends StatefulWidget {
  const _TuningCard();
  @override
  State<_TuningCard> createState() => _TuningCardState();
}

class _TuningCardState extends State<_TuningCard> {
  bool _busy = false;
  bool _saving = false;
  double _era = 0.05;
  double _depth = 0.0;
  String? _error;

  Future<void> _load() async {
    final bridge = Provider.of<KumaFlowBrainBridge>(context, listen: false);
    final settings = Provider.of<KumaFlowBrainSettings>(context, listen: false);
    final client = bridge.client;
    if (client == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await client.getRecTuning(settings.userId);
      final eff = r['effective'];
      final ch = eff is Map ? eff['character'] : null;
      if (!mounted) return;
      setState(() {
        if (ch is Map) {
          final era = (ch['era_weight'] as num?)?.toDouble();
          final dep = (ch['depth'] as num?)?.toDouble();
          if (era != null) _era = era.clamp(0.0, 1.0);
          if (dep != null) _depth = dep.clamp(-1.0, 1.0);
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e${'$e'.contains('403') ? ' (нужен мозг 0.3.32+)' : ''}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final bridge = Provider.of<KumaFlowBrainBridge>(context, listen: false);
    final settings = Provider.of<KumaFlowBrainSettings>(context, listen: false);
    final client = bridge.client;
    if (client == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await client.putRecTuning(settings.userId, {
        'character': {'era_weight': _era, 'depth': _depth}
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e${'$e'.contains('403') ? ' (нужен мозг 0.3.32+)' : ''}');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.tune_rounded, color: Color(0xFF34C759)),
            const SizedBox(width: 8),
            const Expanded(
                child: Text('Эпоха и глубина',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
            if (_saving)
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            IconButton(
                onPressed: _busy ? null : _load,
                icon: const Icon(Icons.refresh_rounded, size: 18)),
          ]),
          const Text('Свой overlay волны: эпоха — бонус любимым десятилетиям, глубина — хиты (+) или дип-каты (−).',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
          Row(children: [
            const SizedBox(width: 96, child: Text('Эпоха', style: TextStyle(fontSize: 13))),
            Expanded(
                child: Slider(
                    value: _era,
                    min: 0,
                    max: 1,
                    divisions: 20,
                    label: _era.toStringAsFixed(2),
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _era = v),
                    onChangeEnd: (_) => _save())),
            SizedBox(
                width: 40,
                child: Text(_era.toStringAsFixed(2),
                    style: const TextStyle(fontSize: 12),
                    textAlign: TextAlign.right)),
          ]),
          Row(children: [
            const SizedBox(width: 96, child: Text('Глубина', style: TextStyle(fontSize: 13))),
            Expanded(
                child: Slider(
                    value: _depth,
                    min: -1,
                    max: 1,
                    divisions: 40,
                    label: '${_depth >= 0 ? '+' : ''}${_depth.toStringAsFixed(2)}',
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _depth = v),
                    onChangeEnd: (_) => _save())),
            SizedBox(
                width: 40,
                child: Text(
                    '${_depth >= 0 ? '+' : ''}${_depth.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 12),
                    textAlign: TextAlign.right)),
          ]),
          Text(
              _depth > 0.01
                  ? 'Тянет к заигранному'
                  : _depth < -0.01
                      ? 'Тянет к редкому'
                      : 'Нейтрально',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          if (_error != null)
            Text(_error!,
                style: const TextStyle(color: Colors.red, fontSize: 12)),
        ]),
      ),
    );
  }
}

// ---------------- Обложки ----------------

class _CoversCard extends StatefulWidget {
  const _CoversCard();
  @override
  State<_CoversCard> createState() => _CoversCardState();
}

class _CoversCardState extends State<_CoversCard> {
  bool _busy = false;
  String? _status;

  Future<void> _prefetchQueue() async {
    final bridge = Provider.of<KumaFlowBrainBridge>(context, listen: false);
    final player = Provider.of<PlayerProvider>(context, listen: false);
    final client = bridge.client;
    if (client == null) return;
    setState(() {
      _busy = true;
      _status = 'Грею…';
    });
    try {
      // Треки KumaFlow Brain = uuid текущей очереди (если очередь из KumaFlow Brain) —
      // греем пачками по 8, как в заметке.
      final ids = player.queue.take(24).map((s) => s.id).toList();
      var ok = 0;
      for (var i = 0; i < ids.length; i += 8) {
        final chunk = ids.sublist(i, i + 8 > ids.length ? ids.length : i + 8);
        try {
          await client.prefetchCovers(chunk, size: 300);
          ok += chunk.length;
        } catch (_) {}
      }
      if (mounted) setState(() => _status = 'Прогрето: $ok/${ids.length} (пачки по 8).');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bridge = Provider.of<KumaFlowBrainBridge>(context);
    final player = Provider.of<PlayerProvider>(context);
    final client = bridge.client;
    final previewTracks = player.queue.take(8).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.image_rounded, color: Color(0xFF5856D6)),
            SizedBox(width: 8),
            Expanded(
                child: Text('Обложки',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
          ]),
          const Text(
              'GET /api/covers/track/{id}?size=100|300, ETag + 304 — кешируем агрессивно, греем пачками по 8.',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: (_busy || client == null) ? null : _prefetchQueue,
            icon: const Icon(Icons.local_fire_department_outlined, size: 16),
            label: Text(_busy ? 'Грею…' : 'Прогреть очередь (до 24)'),
          ),
          if (_status != null) ...[
            const SizedBox(height: 4),
            Text(_status!, style: const TextStyle(fontSize: 12)),
          ],
          if (client != null && previewTracks.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 72,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: previewTracks.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) {
                  final s = previewTracks[i];
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      client.coverUrl(s.id, size: 100),
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 72,
                        height: 72,
                        color: Colors.grey.withValues(alpha: 0.2),
                        child: const Icon(Icons.music_note_rounded,
                            size: 24, color: Colors.grey),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
