import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Порт десктопного wave-identity.ts (C:\kumaflow-pc-new):
/// природа ленты определяется именем очереди, а не составом.
/// Имя — источник истины; состав (my-wave-last) — запасной путь.
class WaveContext {
  final List<String> ids;
  final String hint;
  final String source; // 'local' | 'brain'
  final int at;
  const WaveContext({
    required this.ids,
    required this.hint,
    required this.source,
    required this.at,
  });
}

const _kWaveCtxKey = 'my-wave-last';

Future<void> saveWaveContext(
  List<String> ids,
  String hint,
  String source,
) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final ctx = {
      'ids': (ids).take(100).toList(),
      'hint': hint,
      'source': source,
      'at': DateTime.now().millisecondsSinceEpoch,
    };
    await prefs.setString(_kWaveCtxKey, json.encode(ctx));
  } catch (_) {}
}

Future<WaveContext?> readWaveContext() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kWaveCtxKey);
    if (raw == null || raw.isEmpty) return null;
    final m = json.decode(raw) as Map;
    final ids = ((m['ids'] as List?) ?? const []).map((e) => '$e').toList();
    return WaveContext(
      ids: ids,
      hint: '${m['hint'] ?? ''}',
      source: '${m['source'] ?? 'local'}',
      at: (m['at'] as num?)?.toInt() ?? 0,
    );
  } catch (_) {
    return null;
  }
}

/// Сид волны (порт WaveSeed из wave-identity.ts): лента, посаженная
/// на артиста или трек. Как у Яндекса: «В стиле: Reamonn» / «По треку: …».
/// Сид перекрывает пилюли настроений и живёт отдельно от настроек волны:
/// обычный запуск волны обязан его гасить (clearWaveSeed).
class WaveSeed {
  final String kind; // 'artist' | 'track'
  final String label;
  const WaveSeed({required this.kind, required this.label});
}

const _kWaveSeedKey = 'my-wave-seed';

Future<void> saveWaveSeed(WaveSeed? seed) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    if (seed == null || seed.label.trim().isEmpty) {
      await prefs.remove(_kWaveSeedKey);
      return;
    }
    await prefs.setString(
      _kWaveSeedKey,
      json.encode({
        'kind': seed.kind == 'track' ? 'track' : 'artist',
        'label': seed.label,
        'at': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  } catch (_) {}
}

Future<WaveSeed?> readWaveSeed() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kWaveSeedKey);
    if (raw == null || raw.isEmpty) return null;
    final m = json.decode(raw) as Map;
    final label = '${m['label'] ?? ''}';
    if (label.isEmpty) return null;
    return WaveSeed(
      kind: '${m['kind']}' == 'track' ? 'track' : 'artist',
      label: label,
    );
  } catch (_) {
    return null;
  }
}

Future<void> clearWaveSeed() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kWaveSeedKey);
  } catch (_) {}
}

/// Подпись сида ровно как у Яндекса. Пустая строка — сида нет.
String seedLabel(WaveSeed? seed) {
  if (seed == null || seed.label.isEmpty) return '';
  return seed.kind == 'track'
      ? 'По треку: ${seed.label}'
      : 'В стиле: ${seed.label}';
}

/// Моя волна по имени (рус/анг + сиды как у Яндекса).
bool isWavePlaylistName(String? name) {
  final n = (name ?? '').toLowerCase().trim();
  if (n.isEmpty) return false;
  return n.contains('моя волна') ||
      n.contains('mywave') ||
      n.contains('my wave') ||
      n.contains('в стиле') ||
      n.contains('по треку');
}

/// Волна сейчас играет (как isWaveActive на ПК): имя очереди — источник
/// истины, членство трека в hero-списке — второй признак. Нужно потому что
/// «Продолжить» (resume с сервера) подменяет очередь — трека уже нет
/// в списке hero, а по имени очереди волна опознаётся.
bool isWavePlayingNow({
  required bool isPlaying,
  required String? currentSongId,
  required List<String> heroIds,
  required String? queueName,
}) {
  if (!isPlaying) return false;
  if (currentSongId != null && heroIds.contains(currentSongId)) return true;
  return isWavePlaylistName(queueName);
}

double waveOverlap(List<String> ids, WaveContext? ctx) {
  if (ctx == null || ctx.ids.isEmpty || ids.isEmpty) return 0;
  final saved = ctx.ids.toSet();
  var hit = 0;
  for (final id in ids) {
    if (saved.contains(id)) hit++;
  }
  final denom = ids.length < ctx.ids.length ? ids.length : ctx.ids.length;
  if (denom == 0) return 0;
  return hit / denom;
}

/// Шапка очереди для плеера (порт getActiveContext из now-playing.tsx).
/// Синхронная: имя — источник истины, как на десктопе.
({String kicker, String title}) getActiveQueueContext({
  required String? queueName,
  required String? queueHint,
  required bool isRadio,
  required String? radioName,
}) {
  if (isRadio && (radioName ?? '').trim().isNotEmpty) {
    return (kicker: 'Сейчас играет · Радио', title: radioName!.trim());
  }
  if (isWavePlaylistName(queueName)) {
    final name = queueName!.trim();
    // Сид («В стиле: X» / «По треку: …») — показываем его же.
    final lower = name.toLowerCase();
    if (lower.startsWith('в стиле') || lower.startsWith('по треку')) {
      return (kicker: 'Сейчас играет', title: name);
    }
    final hint = (queueHint ?? '').trim();
    return (
      kicker: 'Сейчас играет · Моя волна',
      title: hint.isNotEmpty ? hint : 'Моя волна',
    );
  }
  if ((queueName ?? '').trim().isNotEmpty) {
    return (kicker: 'Сейчас играет', title: queueName!.trim());
  }
  return (kicker: 'Сейчас играет', title: 'Моя коллекция');
}

/// Принять очередь за волну: обновить контекст, вернуть имя с меткой.
Future<String> adoptWaveQueueAsync(
  List<String> ids,
  String playlistName, {
  String? hint,
}) async {
  final ctx = await readWaveContext();
  final ov = waveOverlap(ids, ctx);
  final byName = isWavePlaylistName(playlistName);
  if (!byName && ov < 0.5) return playlistName;
  final h = hint ?? ctx?.hint ?? '';
  await saveWaveContext(ids, h, ctx?.source ?? 'brain');
  if (RegExp(r'моя волна|mywave|my wave', caseSensitive: false)
      .hasMatch(playlistName)) {
    return playlistName;
  }
  return '$playlistName · Моя волна';
}
