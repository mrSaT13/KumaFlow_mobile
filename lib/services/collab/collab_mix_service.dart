import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/song.dart';
import '../ai_service.dart';
import '../library_database_service.dart';
import '../ml_service.dart';
import '../playlist_orchestrator.dart';
import '../subsonic_service.dart';
import 'collab_account.dart';
import 'collab_merge_service.dart';
import 'collab_taste_service.dart';
import 'multi_server_resolver.dart';

/// Генератор коллаборативного микса: merge вкусов → chunked energy wave →
/// ИИ-название → кэш → play / сохранить на сервер / снимок локально.
///
/// Микс автообновляемый: TTL 12ч, плюс ручная кнопка refresh.
class CollabMixService extends ChangeNotifier {
  static const _kCacheKey = 'collab_mix_v1';
  static const _kSettingsKey = 'collab_mix_settings_v1';
  static const _kSnapshotsKey = 'collab_mix_snapshots_v1';
  static const Duration mixTtl = Duration(hours: 12);
  static const int maxSnapshots = 5;

  static final CollabMixService _instance = CollabMixService._internal();
  factory CollabMixService() => _instance;
  CollabMixService._internal();

  final _db = LibraryDatabaseService();

  List<Song> _songs = [];
  String _name = 'Коллаб-микс';
  String _description = '';
  List<String> _contributors = [];
  DateTime? _updatedAt;
  bool _generating = false;
  String? _error;
  CollabMixSettings _settings = const CollabMixSettings();

  List<Song> get songs => List.unmodifiable(_songs);
  String get name => _name;
  String get description => _description;
  List<String> get contributors => List.unmodifiable(_contributors);
  DateTime? get updatedAt => _updatedAt;
  bool get generating => _generating;
  String? get error => _error;
  bool get hasMix => _songs.isNotEmpty;
  CollabMixSettings get settings => _settings;

  /// Треков от друзей (не с основного сервера) в миксе.
  int get friendTracksCount => _songs.where((s) => s.isRemoteCollab).length;

  Future<void> setSettings(CollabMixSettings s) async {
    _settings = s;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSettingsKey, json.encode({
        'selfWeight': s.selfWeight,
        'limit': s.limit,
      }));
    } catch (_) {}
  }

  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kSettingsKey);
      if (raw == null) return;
      final j = json.decode(raw) as Map<String, dynamic>;
      _settings = CollabMixSettings(
        selfWeight: (j['selfWeight'] as num?)?.toDouble() ?? 0.5,
        limit: (j['limit'] as num?)?.toInt() ?? 30,
      );
      notifyListeners();
    } catch (_) {}
  }

  /// Загрузить кэш микса (полные Song JSON — чужие треки не резолвятся по id).
  Future<bool> loadCached() async {
    try {
      final data = await _db.loadMixCache(_kCacheKey);
      if (data == null) return false;
      final at = data['at'] as int? ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - at > mixTtl.inMilliseconds) {
        return false;
      }
      final raw = data['songs'] as List? ?? [];
      final songs = <Song>[];
      for (final e in raw) {
        try {
          songs.add(Song.fromJson((e as Map).cast<String, dynamic>()));
        } catch (_) {}
      }
      if (songs.isEmpty) return false;
      _songs = songs;
      _name = data['name'] as String? ?? 'Коллаб-микс';
      _description = data['description'] as String? ?? '';
      _contributors = (data['contributors'] as List? ?? [])
          .map((e) => e.toString())
          .toList();
      final updated = data['updatedAt'] as String?;
      _updatedAt =
          updated != null ? DateTime.tryParse(updated) : DateTime.now();
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[CollabMix] load cache failed: $e');
      return false;
    }
  }

  Future<void> _persistCache() async {
    try {
      await _db.saveMixCache(_kCacheKey, 'collab_mix', {
        'at': DateTime.now().millisecondsSinceEpoch,
        'name': _name,
        'description': _description,
        'contributors': _contributors,
        'updatedAt': DateTime.now().toIso8601String(),
        'songs': _songs.map((s) => s.toJson()).toList(),
      });
    } catch (e) {
      debugPrint('[CollabMix] save cache failed: $e');
    }
  }

  /// Собрать (или пересобрать) микс. OOM-safe: только метадата, без аудио.
  Future<bool> generate({
    required List<Song> ownPool,
    MultiServerResolver? resolver,
    bool force = false,
  }) async {
    if (_generating) return false;
    await CollabAccountStore().load();
    await CollabTasteService().load();
    final accounts = CollabAccountStore().enabledAccounts;
    if (accounts.isEmpty) {
      _error = 'Нет друзей — добавь сервер в Настройки → Сервер → Друзья';
      notifyListeners();
      return false;
    }
    // Автообновление: свежий кэш без force не пересобираем.
    if (!force && hasMix && _updatedAt != null) {
      if (DateTime.now().difference(_updatedAt!) < mixTtl) return true;
    }
    _generating = true;
    _error = null;
    notifyListeners();
    try {
      final tastes = CollabTasteService();
      // Подтягиваем протухшие вкусы по очереди (максимум — все).
      for (final acc in accounts) {
        if (tastes.isStale(acc.id)) {
          await tastes.refreshAccount(acc, resolver: resolver);
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }
      final ml = MLService();
      try {
        await ml.initialize();
      } catch (_) {}

      final friendTracks = <String, List<Song>>{};
      final labels = <String, String>{CollabMergeService.selfId: 'Вы'};
      for (final acc in accounts) {
        labels[acc.id] = acc.displayLabel;
        final taste = tastes.tasteFor(acc.id);
        if (taste != null && taste.starred.isNotEmpty) {
          friendTracks[acc.id] = taste.starred;
        }
      }
      if (friendTracks.isEmpty) {
        _error = 'У друзей пока нет лайков (getStarred пуст)';
        _generating = false;
        notifyListeners();
        return false;
      }

      final merged = CollabMergeService.merge(
        ownPool: ownPool,
        friendTracks: friendTracks,
        contributorLabels: labels,
        dislikedIds: {
          ...ml.profile.dislikedSongs,
          ...ml.ratings.entries
              .where((e) => e.value.like == false)
              .map((e) => e.key),
        },
        bannedArtistIds: ml.profile.bannedArtists.toSet(),
        bannedArtistNamesLower:
            ml.profile.bannedArtistNames.values.map((e) => e.toLowerCase()).toSet(),
        ownTopArtistsLower: ml.profile.preferredArtists.keys
            .map((e) => e.toLowerCase())
            .toSet(),
        ownScore: (s) => ml.calculateTrackScore(s.id),
        settings: _settings,
      );
      if (merged.isEmpty) {
        _error = 'Нечего смешивать — всё отфильтровано veto';
        _generating = false;
        notifyListeners();
        return false;
      }

      // Chunked energy wave: чанки по 6 — fairness порядок в целом kept,
      // внутри чанка плавная энергия (чётные чанки вверх, нечётные вниз).
      final waved = _smoothChunks(merged);
      _songs = waved.map((t) => t.song).toList();

      final usedContributors = waved.map((t) => t.contributorLabel).toSet();
      _contributors = usedContributors.toList();
      _description = _buildDescription(waved, accounts.length);

      // ИИ-название (если настроен), иначе детерминированное.
      _name = await _mixName(_songs, usedContributors);

      _updatedAt = DateTime.now();
      await _persistCache();
      _generating = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Сборка упала: $e';
      _generating = false;
      notifyListeners();
      return false;
    }
  }

  List<MergedTrack> _smoothChunks(List<MergedTrack> merged) {
    const chunk = 6;
    final out = <MergedTrack>[];
    for (var i = 0; i < merged.length; i += chunk) {
      final part = merged.skip(i).take(chunk).toList();
      part.sort((a, b) => PlaylistOrchestrator.energyOf(a.song)
          .compareTo(PlaylistOrchestrator.energyOf(b.song)));
      // Нечётные чанки — сверху вниз: получается волна calm→energy→calm.
      if ((i ~/ chunk).isOdd) {
        out.addAll(part.reversed);
      } else {
        out.addAll(part);
      }
    }
    return out;
  }

  String _buildDescription(List<MergedTrack> tracks, int friendsCount) {
    final shared = tracks.where((t) => t.shared).length;
    final perContributor = <String, int>{};
    for (final t in tracks) {
      perContributor[t.contributorLabel] =
          (perContributor[t.contributorLabel] ?? 0) + 1;
    }
    final parts = perContributor.entries.map((e) => '${e.key}: ${e.value}').toList();
    var desc = 'Коллаб на ${friendsCount + 1} • ${parts.join(' • ')}';
    if (shared > 0) desc += ' • общих: $shared';
    return desc;
  }

  Future<String> _mixName(List<Song> songs, Set<String> labelsUsed) async {
    final who = labelsUsed.where((l) => l != 'Вы').take(2).join(' + ');
    final hint = who.isEmpty ? 'мой коллаб-микс' : 'коллаб-микс с $who';
    try {
      final ai = AiService();
      await ai.initialize();
      if (ai.isConfigured) {
        final hasRu = RegExp('[А-Яа-яЁё]').hasMatch(hint);
        final generated = await ai
            .generateMixName(songs, hint: hint, locale: hasRu ? 'ru' : 'en')
            .timeout(const Duration(seconds: 16), onTimeout: () => '');
        if (generated.trim().isNotEmpty) return generated.trim();
      }
    } catch (_) {}
    // Fallback: жанр + участники.
    final genre = songs.isNotEmpty ? (songs.first.genre ?? '') : '';
    final g = genre.isNotEmpty
        ? '${genre[0].toUpperCase()}${genre.substring(1)}'
        : 'Микс';
    return who.isEmpty ? '$g вместе' : '$g с $who';
  }

  /// Сохранить на сервер. Чужие треки сервер не знает — кладём только свои,
  /// честно пишем это в comment.
  Future<(int saved, int skipped)> saveToServer(SubsonicService subsonic) async {
    if (_songs.isEmpty) throw Exception('Микс пуст');
    final own = _songs.where((s) => !s.isRemoteCollab).toList();
    final foreign = _songs.length - own.length;
    if (own.isEmpty) {
      throw Exception('На сервер нечего сохранять — все треки с серверов друзей');
    }
    final comment = foreign > 0
        ? '$_description • +$foreign с серверов друзей (только локально в приложении)'
        : _description;
    await subsonic.createPlaylist(
      name: _name,
      comment: comment,
      songIds: own.map((s) => s.id).toList(),
    );
    return (own.length, foreign);
  }

  /// Снимок локально (играется из кэша, переживает пересборки).
  Future<void> saveSnapshot() async {
    if (_songs.isEmpty) throw Exception('Микс пуст');
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kSnapshotsKey);
      final list = raw != null && raw.isNotEmpty
          ? List<Map<String, dynamic>>.from(json.decode(raw) as List)
          : <Map<String, dynamic>>[];
      list.insert(0, {
        'name': _name,
        'savedAt': DateTime.now().toIso8601String(),
        'description': _description,
        'contributors': _contributors,
        'songs': _songs.map((s) => s.toJson()).toList(),
      });
      await prefs.setString(
          _kSnapshotsKey, json.encode(list.take(maxSnapshots).toList()));
    } catch (e) {
      debugPrint('[CollabMix] snapshot failed: $e');
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> snapshots() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kSnapshotsKey);
      if (raw == null || raw.isEmpty) return [];
      return List<Map<String, dynamic>>.from(json.decode(raw) as List);
    } catch (_) {
      return [];
    }
  }
}
