import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Serves local music files over HTTP so DLNA/UPnP renderers (TVs, speakers)
/// can fetch files that live on this device. A renderer cannot open a
/// `file://` URI from the phone, so we expose a small HTTP endpoint on the
/// local network and hand the renderer an `http://<phone-ip>:<port>/...` URL.
class LocalFileServer {
  LocalFileServer._internal();
  static final LocalFileServer instance = LocalFileServer._internal();

  HttpServer? _server;
  int _port = 0;
  String? _lanIp;

  bool get isRunning => _server != null;
  int get port => _port;

  /// The LAN IP the phone can be reached at, or null if it can't be detected.
  String? get lanIp => _lanIp;

  /// Re-detects the LAN IP. Wi-Fi reconnects change it; without refresh the
  /// TV gets a stale/unreachable address and the track never starts.
  /// Safe to call any time; starts the server if needed.
  Future<void> refreshLanIp() async {
    await start();
    _lanIp = await _detectLanIp();
    debugPrint('LocalFileServer: refreshed LAN IP: $_lanIp');
  }

  /// Starts the HTTP server on all interfaces. Safe to call multiple times.
  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _port = _server!.port;
      _lanIp = await _detectLanIp();
      debugPrint('LocalFileServer: listening on port $_port (ip: $_lanIp)');
      _server!.listen(_handleRequest);
    } catch (e) {
      debugPrint('LocalFileServer: failed to start: $e');
      _server = null;
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = 0;
  }

  /// Builds an HTTP URL the renderer can use to stream [filePath].
  /// Returns null when the server isn't running or no LAN IP is known.
  String? urlForFile(String filePath) {
    if (_server == null || _lanIp == null) return null;
    final encoded = Uri.encodeComponent(filePath);
    return 'http://$_lanIp:$_port/stream?path=$encoded';
  }

  /// Builds URL using IP that can reach [rendererHost] (fixes VPN/multi-WiFi).
  Future<String?> urlForFileForRenderer(
      String filePath, String? rendererHost) async {
    if (_server == null) return null;
    String? ip = _lanIp;
    if (rendererHost != null) {
      final better = await detectLanIpForTarget(rendererHost);
      if (better != null) {
        ip = better;
        _lanIp = better;
      }
    }
    if (ip == null) return null;
    final encoded = Uri.encodeComponent(filePath);
    return 'http://$ip:$_port/stream?path=$encoded';
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final uri = request.uri;
      if (uri.path != '/stream' || uri.queryParameters['path'] == null) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }

      final filePath = Uri.decodeComponent(uri.queryParameters['path']!);
      final file = File(filePath);
      if (!await file.exists()) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      final length = await file.length();
      final mime = _contentTypeFor(filePath);
      request.response.headers.contentType = ContentType.parse(mime);
      request.response.headers.set('Accept-Ranges', 'bytes');
      // DLNA renderers probe with HEAD before GET
      if (request.method == 'HEAD') {
        request.response.headers.contentLength = length;
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        return;
      }

      final rangeHeader = request.headers.value('range');
      if (rangeHeader != null) {
        final match = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(rangeHeader);
        if (match != null) {
          final startStr = match.group(1);
          final endStr = match.group(2);
          int start = startStr != null && startStr.isNotEmpty
              ? int.tryParse(startStr) ?? 0
              : 0;
          int end = endStr != null && endStr.isNotEmpty
              ? int.tryParse(endStr) ?? (length - 1)
              : (length - 1);
          if (start >= length) {
            request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            request.response.headers.set('Content-Range', 'bytes */$length');
            await request.response.close();
            return;
          }
          if (end >= length) end = length - 1;
          if (end < start) end = start;
          final contentLength = end - start + 1;
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set('Content-Range', 'bytes $start-$end/$length');
          request.response.headers.contentLength = contentLength;
          await request.response.addStream(file.openRead(start, end + 1));
          await request.response.close();
          return;
        }
      }

      request.response.headers.contentLength = length;
      request.response.statusCode = HttpStatus.ok;
      await request.response.addStream(file.openRead());
      await request.response.close();
    } catch (e) {
      debugPrint('LocalFileServer: error serving request: $e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  String _contentTypeFor(String filePath) {
    final lower = filePath.toLowerCase();
    if (lower.endsWith('.flac')) return 'audio/flac';
    if (lower.endsWith('.ogg') || lower.endsWith('.oga')) return 'audio/ogg';
    if (lower.endsWith('.opus')) return 'audio/ogg';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.aac')) return 'audio/aac';
    if (lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.wma')) return 'audio/x-ms-wma';
    return 'application/octet-stream';
  }

  /// Picks LAN IP that can actually reach [targetHost] (renderer).
  /// Falls back to first non-link-local interface (old behavior).
  static Future<String?> detectLanIpForTarget(String? targetHost) async {
    if (targetHost != null) {
      try {
        final socket = await Socket.connect(
          targetHost,
          80,
          timeout: const Duration(milliseconds: 800),
        );
        final localIp = socket.address.address;
        socket.destroy();
        if (!localIp.startsWith('127.') && !localIp.startsWith('169.254.')) {
          return localIp;
        }
      } catch (_) {}
      // UDP trick: no packet sent, OS picks correct source address
      try {
        final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        final target = InternetAddress.tryParse(targetHost);
        if (target != null) {
          // ignore: unused_local_variable
          udp.send([0], target, 1900);
          final localIp = udp.address.address;
          // If bound to 0.0.0.0, get actual via connects
          if (localIp != '0.0.0.0' && !localIp.startsWith('127.')) {
            udp.close();
            return localIp;
          }
        }
        udp.close();
      } catch (_) {}
    }
    return _detectLanIp();
  }

  static Future<String?> _detectLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      String? candidate;
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        // Prefer wlan/wifi, deprioritize vpn/tun/rmnet/p2p
        final isVpn = name.contains('tun') ||
            name.contains('tap') ||
            name.contains('vpn') ||
            name.contains('rmnet') ||
            name.contains('ccmni') ||
            name.contains('p2p');
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('169.254.') ||
              ip.startsWith('127.') ||
              ip.startsWith('0.')) continue;
          // Skip CGNAT 100.64/10 but allow 192.168/10.x — filter only link-local
          if (isVpn) {
            candidate ??= ip;
            continue;
          }
          // Prefer 192.168.x / 10.x / 172.16-31.x (typical LAN)
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              RegExp(r'^172\.(1[6-9]|2\d|3[0-1])\.').hasMatch(ip)) {
            return ip;
          }
          candidate ??= ip;
        }
      }
      return candidate;
    } catch (e) {
      debugPrint('LocalFileServer: could not detect LAN IP: $e');
    }
    return null;
  }
}