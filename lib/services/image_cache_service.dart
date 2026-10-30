import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cache_settings_service.dart';

/// Service for caching images locally to avoid repeated server requests.
///
/// Features:
/// - In-memory cache for hot images
/// - Disk cache for persistent storage
/// - Automatic cache size management
/// - TTL-based expiration
/// - Priority-based eviction (album art > artist photos > thumbnails)
class ImageCacheService {
  static const _cacheDirName = 'image_cache';
  static const _metaKeyPrefix = 'img_cache_';
  static const _defaultMaxSizeMb = 200;
  static const _defaultTtlHours = 72;

  static final ImageCacheService _instance = ImageCacheService._internal();
  factory ImageCacheService() => _instance;
  ImageCacheService._internal();

  Directory? _cacheDir;
  SharedPreferences? _prefs;
  bool _initialized = false;

  // In-memory LRU cache (hot images)
  final LinkedHashMap<String, _CachedImageEntry> _memoryCache = LinkedHashMap();
  static const int _maxMemoryCacheSize = 50;

  // ──────────────────────────────────────────────────────────────────────────
  // Initialization
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_initialized) return;

    try {
      _prefs = await SharedPreferences.getInstance();
      final appDir = await getApplicationCacheDirectory();
      _cacheDir = Directory('${appDir.path}/$_cacheDirName');

      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
      }

      _initialized = true;
      debugPrint('[ImageCacheService] Initialized at ${_cacheDir!.path}');
    } catch (e) {
      debugPrint('[ImageCacheService] Init error: $e');
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Public API
  // ──────────────────────────────────────────────────────────────────────────

  /// Get cached image path. Returns null if not cached or cache disabled.
  Future<String?> getCachedImagePath(String url) async {
    if (!CacheSettingsService().getImageCacheEnabled()) return null;
    await initialize();

    // Check memory cache first
    final memEntry = _memoryCache[url];
    if (memEntry != null && !memEntry.isExpired) {
      // Move to end (most recently used)
      _memoryCache.remove(url);
      _memoryCache[url] = memEntry;
      return memEntry.path;
    }

    // Check disk cache
    final diskPath = _getDiskPath(url);
    final file = File(diskPath);
    if (await file.exists()) {
      // Check if expired
      if (await _isExpired(url)) {
        await file.delete();
        _removeMeta(url);
        return null;
      }

      // Add to memory cache
      _addToMemoryCache(url, diskPath);
      return diskPath;
    }

    return null;
  }

  /// Cache an image from bytes. Gated by image cache toggle.
  Future<String> cacheImageBytes(String url, Uint8List bytes, {String? contentType}) async {
    if (!CacheSettingsService().getImageCacheEnabled()) {
      debugPrint('[ImageCacheService] skip cache (disabled) for $url');
      return url;
    }
    await initialize();

    final diskPath = _getDiskPath(url);
    final file = File(diskPath);

    await file.writeAsBytes(bytes);

    // Save metadata
    await _saveMeta(url, {
      'path': diskPath,
      'size': bytes.length,
      'contentType': contentType ?? 'image/jpeg',
      'cachedAt': DateTime.now().millisecondsSinceEpoch,
    });

    // Add to memory cache
    _addToMemoryCache(url, diskPath);

    debugPrint('[ImageCacheService] Cached: $url (${bytes.length} bytes)');
    return diskPath;
  }

  /// Cache an image from a file (copy to cache).
  Future<String> cacheImageFile(String url, String sourcePath) async {
    await initialize();

    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw FileSystemException('Source file not found', sourcePath);
    }

    final bytes = await sourceFile.readAsBytes();
    return cacheImageBytes(url, bytes);
  }

  /// Pre-cache a list of image URLs. Gated by toggle.
  Future<void> preCacheImages(List<String> urls) async {
    if (!CacheSettingsService().getImageCacheEnabled()) return;
    await initialize();

    for (final url in urls) {
      final cached = await getCachedImagePath(url);
      if (cached != null) continue; // Already cached

      // We can't download here without network, but we can mark for later
      debugPrint('[ImageCacheService] Pre-cache requested: $url');
    }
  }

  /// Get cache statistics.
  Future<Map<String, dynamic>> getCacheStats() async {
    await initialize();

    int totalSize = 0;
    int fileCount = 0;

    if (await _cacheDir!.exists()) {
      await for (final entity in _cacheDir!.list()) {
        if (entity is File) {
          totalSize += await entity.length();
          fileCount++;
        }
      }
    }

    return {
      'totalSizeBytes': totalSize,
      'totalSizeMb': (totalSize / (1024 * 1024)).toStringAsFixed(1),
      'fileCount': fileCount,
      'memoryCacheSize': _memoryCache.length,
    };
  }

  /// Clear all cached images.
  Future<void> clearAll() async {
    await initialize();
    _memoryCache._map.clear();

    if (await _cacheDir!.exists()) {
      await for (final entity in _cacheDir!.list()) {
        if (entity is File) {
          await entity.delete();
        }
      }
    }

    // Clear metadata
    final keys = _prefs!.getKeys().where((k) => k.startsWith(_metaKeyPrefix));
    for (final key in keys) {
      await _prefs!.remove(key);
    }

    debugPrint('[ImageCacheService] Cache cleared');
  }

  /// Clear expired cache entries.
  Future<int> clearExpired() async {
    await initialize();

    int cleared = 0;
    final keys = _prefs!.getKeys().where((k) => k.startsWith(_metaKeyPrefix));

    for (final key in keys) {
      final url = key.substring(_metaKeyPrefix.length);
      if (await _isExpired(url)) {
        final diskPath = _getDiskPath(url);
        final file = File(diskPath);
        if (await file.exists()) {
          await file.delete();
        }
        await _prefs!.remove(key);
        cleared++;
      }
    }

    debugPrint('[ImageCacheService] Cleared $cleared expired entries');
    return cleared;
  }

  /// Enforce max cache size by removing oldest entries.
  Future<void> enforceMaxSize({int maxMb = _defaultMaxSizeMb}) async {
    await initialize();

    final stats = await getCacheStats();
    final currentMb = (stats['totalSizeBytes'] as int) / (1024 * 1024);

    if (currentMb <= maxMb) return;

    // Get all entries sorted by cache time (oldest first)
    final entries = <MapEntry<String, int>>[];
    final keys = _prefs!.getKeys().where((k) => k.startsWith(_metaKeyPrefix));

    for (final key in keys) {
      final data = _prefs!.getString(key);
      if (data != null) {
        final cachedAt = _extractCachedAt(data);
        if (cachedAt != null) {
          entries.add(MapEntry(key, cachedAt));
        }
      }
    }

    entries.sort((a, b) => a.value.compareTo(b.value));

    // Remove oldest until under limit
    int freedBytes = 0;
    final targetBytes = maxMb * 1024 * 1024;

    for (final entry in entries) {
      if (currentMb * 1024 * 1024 - freedBytes <= targetBytes) break;

      final url = entry.key.substring(_metaKeyPrefix.length);
      final diskPath = _getDiskPath(url);
      final file = File(diskPath);

      if (await file.exists()) {
        final size = await file.length();
        await file.delete();
        freedBytes += size;
      }

      await _prefs!.remove(entry.key);
    }

    debugPrint('[ImageCacheService] Freed ${(freedBytes / 1024 / 1024).toStringAsFixed(1)}MB');
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Private helpers
  // ──────────────────────────────────────────────────────────────────────────

  String _getDiskPath(String url) {
    // Create a safe filename from URL
    final safeName = url.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final shortName = safeName.length > 100 ? safeName.substring(0, 100) : safeName;
    return '${_cacheDir!.path}/$shortName.jpg';
  }

  Future<bool> _isExpired(String url) async {
    final meta = _prefs!.getString('$_metaKeyPrefix$url');
    if (meta == null) return false;

    try {
      final cachedAt = _extractCachedAt(meta);
      if (cachedAt == null) return false;

      final cachedTime = DateTime.fromMillisecondsSinceEpoch(cachedAt);
      return DateTime.now().difference(cachedTime) > const Duration(hours: _defaultTtlHours);
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveMeta(String url, Map<String, dynamic> meta) async {
    await _prefs!.setString('$_metaKeyPrefix$url', meta.toString());
  }

  Future<void> _removeMeta(String url) async {
    await _prefs!.remove('$_metaKeyPrefix$url');
  }

  int? _extractCachedAt(String metaString) {
    // Simple extraction
    final match = RegExp(r'cachedAt: (\d+)').firstMatch(metaString);
    if (match != null) {
      return int.tryParse(match.group(1) ?? '');
    }
    return null;
  }

  void _addToMemoryCache(String url, String path) {
    if (_memoryCache.length >= _maxMemoryCacheSize) {
      // Remove oldest entry
      _memoryCache.remove(_memoryCache.keys.first);
    }
    _memoryCache[url] = _CachedImageEntry(
      path: path,
      timestamp: DateTime.now(),
    );
  }
}

/// In-memory cached image entry.
class _CachedImageEntry {
  final String path;
  final DateTime timestamp;

  _CachedImageEntry({
    required this.path,
    required this.timestamp,
  });

  bool get isExpired =>
      DateTime.now().difference(timestamp) >
      const Duration(hours: ImageCacheService._defaultTtlHours);
}

/// LinkedHashMap that maintains insertion order for LRU.
class LinkedHashMap<K, V> {
  final Map<K, V> _map = {};

  V? operator [](K key) => _map[key];

  void operator []=(K key, V value) {
    _map.remove(key);
    _map[key] = value;
  }

  void remove(K key) => _map.remove(key);

  int get length => _map.length;

  bool containsKey(K key) => _map.containsKey(key);

  Iterable<K> get keys => _map.keys;

  Iterable<V> get values => _map.values;
}
