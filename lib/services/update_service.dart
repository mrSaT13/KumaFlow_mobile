import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

class ReleaseAsset {
  final String name;
  final String browserDownloadUrl;

  const ReleaseAsset({required this.name, required this.browserDownloadUrl});

  factory ReleaseAsset.fromJson(Map<String, dynamic> json) => ReleaseAsset(
        name: json['name'] as String? ?? '',
        browserDownloadUrl: json['browser_download_url'] as String? ?? '',
      );
}

class ReleaseInfo {
  final String version;
  final String tagName;
  final String htmlUrl;

  final String body;
  final List<ReleaseAsset> assets;

  const ReleaseInfo({
    required this.version,
    required this.tagName,
    required this.htmlUrl,
    required this.body,
    required this.assets,
  });

  factory ReleaseInfo.fromJson(Map<String, dynamic> json) {
    final tag = json['tag_name'] as String? ?? '';
    // Теги вида MC_3.6.1+28 / v3.6.1: вытаскиваем числовую версию.
    final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(tag);
    final version = m != null
        ? '${m.group(1)}.${m.group(2)}.${m.group(3)}'
        : tag.replaceFirst(RegExp(r'^v'), '');
    return ReleaseInfo(
      version: version,
      tagName: tag,
      htmlUrl: json['html_url'] as String? ?? '',
      body: json['body'] as String? ?? '',
      assets: (json['assets'] as List<dynamic>?)
              ?.map((a) => ReleaseAsset.fromJson(a as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  /// APK для телефона: универсальный app-release.apk в приоритете,
  /// иначе первый .apk. null = apk в релизе нет (открываем страницу релиза).
  ReleaseAsset? get apkAsset {
    final apks = assets
        .where((a) =>
            a.name.toLowerCase().endsWith('.apk') &&
            a.browserDownloadUrl.isNotEmpty)
        .toList();
    if (apks.isEmpty) return null;
    for (final a in apks) {
      final n = a.name.toLowerCase();
      if (n.contains('universal') || n == 'app-release.apk') return a;
    }
    // arm64-v8a предпочтительнее armeabi для большинства телефонов.
    for (final a in apks) {
      if (a.name.toLowerCase().contains('arm64')) return a;
    }
    return apks.first;
  }

  /// Прямая ссылка на скачивание: APK если есть, иначе страница релиза.
  /// Открывается через браузер — система сама скачает и предложит установку.
  /// Схема: выложил GitHub Release (workflow Build & Release) -> телефон
  /// при старте проверяет latest -> диалог -> загрузка -> установка.
  String get downloadUrl => apkAsset?.browserDownloadUrl ?? htmlUrl;
  bool get hasDirectApk => apkAsset != null;
}

class UpdateService {
  /// Fallback = версия pubspec на момент сборки. Точное значение подтягивается
  /// из PackageInfo при каждой проверке (checkForUpdate обновляет кэш).
  static String _currentVersion = '3.6.2';
  static String get currentVersion => _currentVersion;

  static const String _apiUrl =
      'https://api.github.com/repos/mrSaT13/kumaflow/releases?per_page=30';

  static final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      headers: {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      },
    ),
  );

  static Future<void> _refreshCurrentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty) _currentVersion = info.version;
    } catch (_) {}
  }

  static Future<ReleaseInfo?> checkForUpdate() async {
    try {
      await _refreshCurrentVersion();
      final response = await _dio.get<List<dynamic>>(_apiUrl);
      final items = response.data;
      if (items == null || items.isEmpty) return null;

      // В одном репозитории живут оба плеера: десктопные v-теги и
      // мобильные MC_. Берём свежий релиз с мобильным тегом — общий
      // /releases/latest после десктопного релиза показывал бы v1.14.0,
      // и сравнение 1.14.0 < 3.7.x вечно говорило бы «нового нет».
      Map<String, dynamic>? mobile;
      for (final raw in items) {
        if (raw is! Map<String, dynamic>) continue;
        final tag = (raw['tag_name'] as String? ?? '').toUpperCase();
        if (tag.startsWith('MC_')) {
          mobile = raw;
          break;
        }
      }
      if (mobile == null) return null;

      final release = ReleaseInfo.fromJson(mobile);
      if (release.version.isEmpty) return null;
      if (_isNewer(release.version, _currentVersion)) {
        return release;
      }
      return null;
    } catch (e) {
      debugPrint('UpdateService: check failed – $e');
      return null;
    }
  }

  /// Сравнение x.y.z[+build]: сначала тройка, при равенстве — билд
  /// (3.7.51+2082 новее 3.7.51+2081).
  static bool _isNewer(String remote, String current) {
    try {
      List<int> parse(String v) => v
          .split('+')
          .first
          .split('.')
          .map((p) => int.tryParse(p) ?? 0)
          .toList();
      int buildOf(String v) {
        final parts = v.split('+');
        if (parts.length < 2) return 0;
        return int.tryParse(parts.sublist(1).join('')) ?? 0;
      }

      final r = parse(remote);
      final c = parse(current);
      final len = r.length > c.length ? r.length : c.length;
      while (r.length < len) {
        r.add(0);
      }
      while (c.length < len) {
        c.add(0);
      }

      for (int i = 0; i < len; i++) {
        if (r[i] > c[i]) return true;
        if (r[i] < c[i]) return false;
      }
      return buildOf(remote) > buildOf(current);
    } catch (_) {
      return false;
    }
  }

  static String stripMarkdown(String md) {
    return md
        .replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '')
        .replaceAllMapped(RegExp(r'\*\*(.*?)\*\*'), (m) => m.group(1) ?? '')
        .replaceAllMapped(RegExp(r'\*(.*?)\*'), (m) => m.group(1) ?? '')
        .replaceAllMapped(RegExp(r'`{1,3}(.*?)`{1,3}'), (m) => m.group(1) ?? '')
        .replaceAllMapped(
            RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m.group(1) ?? '')
        .replaceAll(RegExp(r'^---+$', multiLine: true), '─────────────')
        .trim();
  }
}
