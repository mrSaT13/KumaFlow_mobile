import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'cache_settings_service.dart';

/// A validating image cache manager.
///
/// `flutter_cache_manager` by default persists *whatever bytes* a server
/// returns — including HTML error pages, truncated downloads and gzipped
/// bodies — under an image extension. Android's `ImageDecoder` then fails
/// decoding that corrupt file on every rebuild, flooding the log with
/// "Failed to create image decoder with message 'unimplemented'".
///
/// This manager fixes that by:
///  1. Rejecting non-image bodies during download so garbage never reaches the
///     disk cache (a [_ValidatingFileService] checks magic bytes in the stream).
///  2. Validating cached files when read and evicting + re-fetching corrupt
///     ones, so a previously-corrupted entry self-heals instead of failing
///     forever.
///  3. Offering a [purgeCorruptFiles] sweep to flush existing bad entries.
class SafeImageCacheManager extends CacheManager {
  /// Unique cache key so it never shares data with the default manager.
  static const String cacheKey = 'safe_kumaflow_images_v1';

  /// Singleton — `CacheManager` is designed to be used as one instance.
  static final SafeImageCacheManager instance = SafeImageCacheManager._();

  SafeImageCacheManager._()
        : super(Config(
          cacheKey,
          stalePeriod: const Duration(days: 7),
          maxNrOfCacheObjects: 400,
          fileService: _ValidatingFileService(),
        ));

  /// True when [bytes] starts with the magic bytes of a known image format.
  static bool isImageBytes(Uint8List bytes) {
    if (bytes.length < 12) return false;
    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return true;
    }
    // GIF87a / GIF89a
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[4] == 0x38) {
      return true;
    }
    // WebP: RIFF (4) size (4) WEBP
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    // BMP: BM 00 00
    if (bytes[0] == 0x42 &&
        bytes[1] == 0x4D &&
        bytes[2] == 0x00 &&
        bytes[3] == 0x00) {
      return true;
    }
    // AVIF / HEIC / HEIF: ISO-BMFF ftyp box at offset 4
    if (bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79) return true;
    return false;
  }

  /// Validate a previously cached file on disk. Returns true when the file
  /// starts with image magic bytes, false when it is corrupt/not-an-image.
  static Future<bool> isFileAnImage(File file) async {
    try {
      if (!await file.exists()) return false;
      final bytes = await file
          .openRead()
          .first
          .timeout(const Duration(seconds: 5));
      return isImageBytes(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    } on Object catch (e) {
      debugPrint('[SafeImageCacheManager] read error: $e');
      return false;
    }
  }

  /// Override so corrupt cached files are never served. When a cached entry is
  /// fresh but its bytes are not a real image, it is evicted and re-downloaded.
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    key ??= url;
    final imageCacheEnabled = CacheSettingsService().getImageCacheEnabled();
    if (imageCacheEnabled) {
      final cacheFile = await _validCachedFile(key);
      if (cacheFile != null) {
        yield cacheFile;
        return;
      }
    }
    yield* super.getFileStream(
      url,
      key: key,
      headers: headers,
      withProgress: withProgress,
    );
    // If cache disabled, evict just-cached file so next load re-fetches
    if (!imageCacheEnabled) {
      try {
        await removeFile(key);
      } catch (_) {}
    }
  }

  /// Returns the cached [FileInfo] only when it is fresh AND its bytes are a
  /// real image. Corrupt entries are evicted. A missing/stale entry is null.
  Future<FileInfo?> _validCachedFile(String key) async {
    FileInfo? info;
    try {
      info = await getFileFromCache(key);
    } on Object catch (e) {
      debugPrint('[SafeImageCacheManager] cache read error: $e');
    }
    if (info == null) return null;
    if (!info.validTill.isAfter(DateTime.now())) return null;
    if (!await isFileAnImage(info.file)) {
      debugPrint('[SafeImageCacheManager] Evicting corrupt cached file '
          '(key=$key, path=${info.file.path})');
      try {
        await removeFile(key);
      } on Object catch (e) {
        debugPrint('[SafeImageCacheManager] removeFile failed: $e');
      }
      return null;
    }
    return info;
  }

  /// Sweep the cache directory and delete every file whose content is not a
  /// real image. Call once at app startup to flush entries corrupted by the
  /// default manager. Returns the number of files deleted.
  Future<int> purgeCorruptFiles() async {
    var removed = 0;
    try {
      final dir = await getCacheDirectory();
      if (!await dir.exists()) return 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (!await isFileAnImage(entity)) {
          try {
            await entity.delete();
            removed++;
          } on Object catch (e) {
            debugPrint('[SafeImageCacheManager] delete failed: $e');
          }
        }
      }
    } on Object catch (e) {
      debugPrint('[SafeImageCacheManager] purge error: $e');
    }
    if (removed > 0) {
      debugPrint('[SafeImageCacheManager] Purged $removed corrupt cache files');
    }
    return removed;
  }

  /// Where this manager stores its files on disk.
  Future<Directory> getCacheDirectory() async {
    return Directory(p.join((await getTemporaryDirectory()).path, cacheKey));
  }
}

/// A [FileService] that validates response bodies before leaving them cached.
///
/// The default [HttpFileService] streams raw bytes straight to disk regardless
/// of content — so an HTML error page or truncated download is persisted under
/// an image extension. This implementation wraps `http` directly, checks the
/// `Content-Type` header and the first bytes of the body, and errors the
/// stream when the payload is not a real image. Because [WebHelper] only
/// registers a file in its cache after the body has been fully written, a
/// rejected body is never indexed, so the same URL is simply re-downloaded on
/// the next request instead of serving a broken file.
class _ValidatingFileService extends FileService {
  _ValidatingFileService();

  static const Set<String> _imageContentTypes = {
    'image/jpeg',
    'image/jpg',
    'image/png',
    'image/gif',
    'image/webp',
    'image/bmp',
    'image/x-icon',
    'image/avif',
    'image/heic',
    'image/heif',
  };

  static bool _isImageContentType(String? value) {
    if (value == null) return false;
    final type = value.split(';').first.trim().toLowerCase();
    if (type.startsWith('image/')) return true;
    return _imageContentTypes.contains(type);
  }

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url));
      if (headers != null) req.headers.addAll(headers);
      final res = await client.send(req);

      final contentType = res.headers.containsKey(HttpHeaders.contentTypeHeader)
          ? res.headers[HttpHeaders.contentTypeHeader]
          : null;

      // Only filter when the server *tells* us it is an image. Absent content
      // type is allowed and left to the byte-level check below to avoid
      // rejecting images served as octet-stream.
      if (contentType != null && !_isImageContentType(contentType)) {
        res.stream.listen(null, cancelOnError: true).cancel();
        throw HttpException('Non-image Content-Type ($contentType) for $url',
            uri: Uri.parse(url));
      }

      final validated = _ValidatingResponse(HttpGetResponse(res));
      return validated;
    } on Object {
      client.close();
      rethrow;
    }
  }
}

/// Wraps a streamed HTTP response and guards its body with a magic-byte check.
class _ValidatingResponse implements FileServiceResponse {
  _ValidatingResponse(this._inner) {
    _stream = _wrap(_inner.content);
  }

  final FileServiceResponse _inner;
  late final Stream<List<int>> _stream;

  Stream<List<int>> _wrap(Stream<List<int>> source) {
    final buffer = BytesBuilder(copy: true);
    final held = <List<int>>[];
    var released = false;
    return source.transform<List<int>>(StreamTransformer.fromHandlers(
      handleData: (data, sink) {
        if (released) {
          sink.add(data);
          return;
        }
        if (buffer.length < 4096) {
          buffer.add(data);
          held.add(data);
          if (buffer.length >= 4096) {
            final probe = buffer.takeBytes();
            if (!SafeImageCacheManager.isImageBytes(probe)) {
              sink.addError(HttpException('Response is not an image'));
              return;
            }
            for (final chunk in held) {
              sink.add(chunk);
            }
            held.clear();
            released = true;
          }
        }
      },
      handleDone: (sink) {
        if (!released) {
          final probe = buffer.takeBytes();
          if (!SafeImageCacheManager.isImageBytes(probe)) {
            sink.addError(HttpException('Response is not an image'));
            return;
          }
        }
        for (final chunk in held) {
          sink.add(chunk);
        }
        held.clear();
        sink.close();
      },
      handleError: (Object e, StackTrace st, sink) => sink.addError(e, st),
    ));
  }

  @override
  Stream<List<int>> get content => _stream;

  @override
  int? get contentLength => _inner.contentLength;

  @override
  String? get eTag => _inner.eTag;

  @override
  String get fileExtension {
    var ext = _inner.fileExtension;
    if (ext == '' || ext == '.html' || ext == '.txt' || ext == '.json' ||
        ext == '.file') {
      ext = '.jpg';
    }
    return ext;
  }

  @override
  int get statusCode => _inner.statusCode;

  @override
  DateTime get validTill => _inner.validTill;
}