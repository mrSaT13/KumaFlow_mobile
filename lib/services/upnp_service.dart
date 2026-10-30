
library;

import 'dart:async';
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'android_system_service.dart';

class UpnpDevice {
  final String friendlyName;
  final String location; 
  final String manufacturer;
  final String modelName;
  final String avTransportUrl; 
  final String? renderingControlUrl; 
  final String? avTransportEventSubUrl;

  const UpnpDevice({
    required this.friendlyName,
    required this.location,
    required this.manufacturer,
    required this.modelName,
    required this.avTransportUrl,
    this.renderingControlUrl,
    this.avTransportEventSubUrl,
  });

  @override
  String toString() => 'UpnpDevice($friendlyName @ $avTransportUrl)';
}

class UpnpPlaybackState {
  final String transportState; 
  final Duration position;
  final Duration duration;

  const UpnpPlaybackState({
    required this.transportState,
    required this.position,
    required this.duration,
  });
}

class UpnpService extends ChangeNotifier {
  static final UpnpService _instance = UpnpService._internal();
  factory UpnpService() => _instance;
  UpnpService._internal();

  final List<UpnpDevice> _devices = [];
  UpnpDevice? _connectedDevice;
  bool _isDiscovering = false;
  Timer? _pollTimer;

  // GENA event subscription (instant LastChange instead of 1s polling)
  HttpServer? _genaServer;
  String? _genaSid;
  Timer? _genaRenewTimer;
  String? _genaEventSubUrl;
  bool _genaSubscribed = false;
  int _lastGenaSeq = -1;

  Duration _rendererPosition = Duration.zero;
  Duration _rendererDuration = Duration.zero;
  String _rendererState = 'STOPPED';
  int _volume = -1; 
  bool get isGenaSubscribed => _genaSubscribed;

  Duration get rendererPosition => _rendererPosition;
  Duration get rendererDuration => _rendererDuration;
  String get rendererState => _rendererState;
  bool get isRendererPlaying => _rendererState == 'PLAYING';
  int get volume => _volume;
  int get consecutivePollErrors => _consecutivePollErrors;

  /// Called when the renderer becomes unreachable after 30 consecutive poll
  /// failures (~30 s). The service has already called disconnect() internally.
  VoidCallback? onRendererLost;

  List<UpnpDevice> get devices => List.unmodifiable(_devices);
  UpnpDevice? get connectedDevice => _connectedDevice;
  bool get isConnected => _connectedDevice != null;
  bool get isDiscovering => _isDiscovering;

  static const String _ssdpAddress = '239.255.255.250';
  static const int _ssdpPort = 1900;
  static const Duration _discoveryTimeout = Duration(seconds: 8);
  static const int _msearchRetries = 3;

  final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 3),
      receiveTimeout: const Duration(seconds: 3),
      // Force a fresh TCP connection for every SOAP request.  Many UPnP
      // renderer HTTP servers (upmpdcli, BubbleUPnP Server, etc.) close
      // their end of the TCP socket after a short keepalive timeout (~5–10 s).
      // Without this header Dio's connection pool reuses the dead socket, the
      // next write throws a SocketException, getPlaybackState() swallows it
      // silently, and the progress bar freezes for the rest of the song.
      headers: {'Connection': 'close'},
    ),
  );

  Future<List<UpnpDevice>> discover() async {
    if (_isDiscovering) return _devices;
    // Runtime permission for Android 12+ NEARBY_WIFI_DEVICES (как у Яндекс Музыки — "находить устройства в локальных сетях")
    try {
      if (Platform.isAndroid) {
        final status = await _requestNearbyWifiPermission();
        if (status == false) debugPrint('UPnP: NEARBY_WIFI_DEVICES denied');
      }
    } catch (_) {}
    _isDiscovering = true;
    _devices.clear();
    notifyListeners();

    // Мультикаст-лок: без него Android в power-save режет входящий
    // multicast и ответы ТВ не доходят, хотя сеть одна и та же.
    try {
      if (Platform.isAndroid) {
        await AndroidSystemService().acquireMulticastLock();
      }
    } catch (_) {}

    try {
      final seen = <String>{};
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      try {
        socket.multicastHops = 4;
      } catch (_) {}

      socket.joinMulticast(InternetAddress(_ssdpAddress));
      socket.broadcastEnabled = true;

      // Многие ТВ (Samsung Tizen, LG webOS) отвечают только на ssdp:all
      // или upnp:rootdevice и игнорируют точечный MediaRenderer:1.
      const searchTargets = [
        'urn:schemas-upnp-org:device:MediaRenderer:1',
        'ssdp:all',
        'upnp:rootdevice',
      ];

      String mSearch(String st) =>
          'M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 3\r\n'
          'ST: $st\r\n'
          '\r\n';

      final completer = Completer<void>();
      final timer = Timer(_discoveryTimeout, () {
        if (!completer.isCompleted) completer.complete();
      });

      // Слушаем ДО отправки, чтобы не потерять быстрые ответы.
      socket.listen((event) async {
        if (event != RawSocketEvent.read) return;
        final dg = socket.receive();
        if (dg == null) return;

        final response = String.fromCharCodes(dg.data);
        final location = _headerValue(response, 'LOCATION');
        if (location == null || seen.contains(location)) return;
        seen.add(location);

        try {
          final device = await _fetchDeviceDescription(location);
          if (device != null) {
            _devices.add(device);
            notifyListeners();
            debugPrint('UPnP: Found ${device.friendlyName}');
          }
        } catch (e) {
          debugPrint('UPnP: Error fetching device at $location: $e');
        }
      });

      // Send multiple M-SEARCH packets with small delays for better discovery
      for (final st in searchTargets) {
        final packet = mSearch(st).codeUnits;
        for (int i = 0; i < _msearchRetries; i++) {
          socket.send(packet, InternetAddress(_ssdpAddress), _ssdpPort);
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }

      await completer.future;
      timer.cancel();
      socket.close();
    } catch (e) {
      debugPrint('UPnP: Discovery error: $e');
    } finally {
      try {
        if (Platform.isAndroid) {
          await AndroidSystemService().releaseMulticastLock();
        }
      } catch (_) {}
      _isDiscovering = false;
      notifyListeners();
    }

    return _devices;
  }

  static String? _headerValue(String response, String header) {
    final pattern = RegExp(
      '${RegExp.escape(header)}: *([^\r\n]+)',
      caseSensitive: false,
    );
    return pattern.firstMatch(response)?.group(1)?.trim();
  }

  Future<UpnpDevice?> _fetchDeviceDescription(String location) async {
    final response = await _dio.get<String>(location);
    final xml = response.data ?? '';

    final friendlyName = _xmlText(xml, 'friendlyName') ?? 'Unknown Device';
    final manufacturer = _xmlText(xml, 'manufacturer') ?? '';
    final modelName = _xmlText(xml, 'modelName') ?? '';

    final avTransportUrl = _extractAvTransportUrl(xml, location);
    if (avTransportUrl == null) {
      debugPrint('UPnP: No AVTransport service found at $location');
      return null;
    }

    final renderingControlUrl = _extractRenderingControlUrl(xml, location);
    final avTransportEventSubUrl = _extractAvTransportEventSubUrl(xml, location);

    return UpnpDevice(
      friendlyName: friendlyName,
      location: location,
      manufacturer: manufacturer,
      modelName: modelName,
      avTransportUrl: avTransportUrl,
      renderingControlUrl: renderingControlUrl,
      avTransportEventSubUrl: avTransportEventSubUrl,
    );
  }

  static String? _xmlText(String xml, String tag) {
    final pattern = RegExp('<$tag>([^<]*)</$tag>', caseSensitive: false);
    return pattern.firstMatch(xml)?.group(1)?.trim();
  }

  static String? _extractAvTransportUrl(String xml, String location) {
    
    final servicePattern = RegExp(
      r'<service>(.*?)</service>',
      dotAll: true,
      caseSensitive: false,
    );
    for (final match in servicePattern.allMatches(xml)) {
      final serviceBlock = match.group(1) ?? '';
      final serviceType = _xmlText(serviceBlock, 'serviceType') ?? '';
      if (serviceType.toLowerCase().contains('avtransport')) {
        final controlPath = _xmlText(serviceBlock, 'controlURL');
        if (controlPath == null) continue;

        final base = Uri.parse(location);
        final absolute = base.resolve(controlPath).toString();
        return absolute;
      }
    }
    return null;
  }

  static String? _extractRenderingControlUrl(String xml, String location) {
    final servicePattern = RegExp(
      r'<service>(.*?)</service>',
      dotAll: true,
      caseSensitive: false,
    );
    for (final match in servicePattern.allMatches(xml)) {
      final serviceBlock = match.group(1) ?? '';
      final serviceType = _xmlText(serviceBlock, 'serviceType') ?? '';
      if (serviceType.toLowerCase().contains('renderingcontrol')) {
        final controlPath = _xmlText(serviceBlock, 'controlURL');
        if (controlPath == null) continue;
        final base = Uri.parse(location);
        return base.resolve(controlPath).toString();
      }
    }
    return null;
  }

  static String? _extractAvTransportEventSubUrl(String xml, String location) {
    final servicePattern = RegExp(
      r'<service>(.*?)</service>',
      dotAll: true,
      caseSensitive: false,
    );
    for (final match in servicePattern.allMatches(xml)) {
      final serviceBlock = match.group(1) ?? '';
      final serviceType = _xmlText(serviceBlock, 'serviceType') ?? '';
      if (serviceType.toLowerCase().contains('avtransport')) {
        final eventSubPath = _xmlText(serviceBlock, 'eventSubURL');
        if (eventSubPath == null) continue;
        final base = Uri.parse(location);
        return base.resolve(eventSubPath).toString();
      }
    }
    return null;
  }

  Future<bool> connect(UpnpDevice device) async {
    try {
      await _soap(device.avTransportUrl, 'GetTransportInfo', '');
      _connectedDevice = device;
      _genaEventSubUrl = device.avTransportEventSubUrl;
      debugPrint('UPnP: Connected to ${device.friendlyName}');
      debugPrint('UPnP: eventSubURL=${device.avTransportEventSubUrl}');

      if (device.renderingControlUrl != null) {
        _volume = await getVolume();
      }
      _consecutivePollErrors = 0;
      _startPolling();
      // Try GENA SUBSCRIBE for instant events, keep polling as fallback
      if (_genaEventSubUrl != null) {
        unawaited(_startGenaServerAndSubscribe());
      }
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('UPnP: Failed to connect to ${device.friendlyName}: $e');
      return false;
    }
  }

  void disconnect() {
    final device = _connectedDevice;
    debugPrint('UPnP: Disconnecting from ${device?.friendlyName}');
    _stopPolling();
    unawaited(_unsubscribeGena());
    _connectedDevice = null;
    _genaEventSubUrl = null;
    _rendererState = 'STOPPED';
    _rendererPosition = Duration.zero;
    _rendererDuration = Duration.zero;
    _volume = -1;
    _consecutivePollErrors = 0;
    notifyListeners();

    if (device != null) {
      _soap(device.avTransportUrl, 'Stop', '').then((_) {
        debugPrint('UPnP: Stop sent on disconnect');
      }).catchError((e) {
        debugPrint('UPnP: Stop on disconnect failed (ok): $e');
      });
    }
  }

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  // ============= GENA SUBSCRIBE (instant LastChange) =============
  Future<void> _startGenaServerAndSubscribe() async {
    if (_genaEventSubUrl == null) return;
    try {
      await _startGenaServer();
      final ok = await _subscribeGena();
      if (ok) {
        // GENA works — reduce polling to 5s fallback (was 1s)
        _pollTimer?.cancel();
        _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
        debugPrint('UPnP: GENA subscribed, polling reduced to 5s fallback');
      }
    } catch (e) {
      debugPrint('UPnP: GENA subscribe failed (polling fallback): $e');
    }
  }

  Future<void> _startGenaServer() async {
    if (_genaServer != null) return;
    try {
      _genaServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _genaServer!.listen(_handleGenaNotify);
      debugPrint('UPnP: GENA server listening on port ${_genaServer!.port}');
    } catch (e) {
      debugPrint('UPnP: GENA server bind failed: $e');
      _genaServer = null;
    }
  }

  Future<void> _stopGenaServer() async {
    _genaRenewTimer?.cancel();
    _genaRenewTimer = null;
    _genaSubscribed = false;
    _genaSid = null;
    try {
      await _genaServer?.close(force: true);
    } catch (_) {}
    _genaServer = null;
  }



  Future<String?> _detectGenaLanIp(String? targetHost) async {
    if (targetHost != null) {
      try {
        final socket = await Socket.connect(targetHost, 80,
            timeout: const Duration(milliseconds: 800));
        final ip = socket.address.address;
        socket.destroy();
        if (!ip.startsWith('127.') && !ip.startsWith('169.254.')) return ip;
      } catch (_) {}
    }
    try {
      final ifs = await NetworkInterface.list(
          includeLoopback: false, type: InternetAddressType.IPv4);
      String? candidate;
      for (final iface in ifs) {
        final n = iface.name.toLowerCase();
        final isVpn = n.contains('tun') ||
            n.contains('tap') ||
            n.contains('vpn') ||
            n.contains('rmnet');
        for (final a in iface.addresses) {
          final ip = a.address;
          if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;
          if (isVpn) {
            candidate ??= ip;
            continue;
          }
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              RegExp(r'^172\.(1[6-9]|2\d|3[0-1])\.').hasMatch(ip)) return ip;
          candidate ??= ip;
        }
      }
      return candidate;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _subscribeGena() async {
    final eventSubUrl = _genaEventSubUrl;
    final server = _genaServer;
    if (eventSubUrl == null || server == null) return false;
    final uri = Uri.parse(eventSubUrl);
    final targetHost = uri.host;
    final lanIp = await _detectGenaLanIp(targetHost);
    if (lanIp == null) {
      debugPrint('UPnP: GENA could not detect LAN IP for $targetHost');
      return false;
    }
    final callback = 'http://$lanIp:${server.port}/upnp/event';
    debugPrint('UPnP: GENA SUBSCRIBE → $eventSubUrl callback=$callback');
    try {
      final client = HttpClient();
      final req = await client.openUrl('SUBSCRIBE', uri);
      req.headers.set('CALLBACK', '<$callback>');
      req.headers.set('NT', 'upnp:event');
      req.headers.set('TIMEOUT', 'Second-300');
      // Some renderers require Content-Length: 0
      req.headers.set('Content-Length', '0');
      final resp = await req.close().timeout(const Duration(seconds: 5));
      final sid = resp.headers.value('sid');
      final timeout = resp.headers.value('timeout');
      // Drain body
      await resp.drain();
      client.close();
      if (resp.statusCode >= 200 && resp.statusCode < 300 && sid != null) {
        _genaSid = sid;
        _genaSubscribed = true;
        _lastGenaSeq = -1;
        debugPrint('UPnP: GENA subscribed SID=$sid timeout=$timeout');
        // Renew at 50% of timeout (300s → 150s)
        final secs = _parseTimeout(timeout) ?? 300;
        final renewIn = Duration(seconds: (secs ~/ 2).clamp(60, 150));
        _genaRenewTimer?.cancel();
        _genaRenewTimer = Timer(renewIn, _renewGena);
        return true;
      } else {
        debugPrint('UPnP: GENA SUBSCRIBE failed ${resp.statusCode} sid=$sid');
        return false;
      }
    } catch (e) {
      debugPrint('UPnP: GENA SUBSCRIBE error: $e');
      return false;
    }
  }

  Future<void> _renewGena() async {
    final sid = _genaSid;
    final url = _genaEventSubUrl;
    if (sid == null || url == null) return;
    try {
      final uri = Uri.parse(url);
      final client = HttpClient();
      final req = await client.openUrl('SUBSCRIBE', uri);
      req.headers.set('SID', sid);
      req.headers.set('TIMEOUT', 'Second-300');
      req.headers.set('Content-Length', '0');
      final resp = await req.close().timeout(const Duration(seconds: 5));
      final timeout = resp.headers.value('timeout');
      await resp.drain();
      client.close();
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        debugPrint('UPnP: GENA renewed timeout=$timeout');
        final secs = _parseTimeout(timeout) ?? 300;
        final renewIn = Duration(seconds: (secs ~/ 2).clamp(60, 150));
        _genaRenewTimer?.cancel();
        _genaRenewTimer = Timer(renewIn, _renewGena);
      } else {
        debugPrint('UPnP: GENA renew failed ${resp.statusCode}, re-subscribing');
        _genaSubscribed = false;
        await _subscribeGena();
      }
    } catch (e) {
      debugPrint('UPnP: GENA renew error: $e');
      _genaSubscribed = false;
      // Try re-subscribe once
      await Future.delayed(const Duration(seconds: 2));
      await _subscribeGena();
    }
  }

  Future<void> _unsubscribeGena() async {
    _genaRenewTimer?.cancel();
    _genaRenewTimer = null;
    final sid = _genaSid;
    final url = _genaEventSubUrl;
    _genaSubscribed = false;
    _genaSid = null;
    if (sid == null || url == null) {
      await _stopGenaServer();
      return;
    }
    try {
      final uri = Uri.parse(url);
      final client = HttpClient();
      final req = await client.openUrl('UNSUBSCRIBE', uri);
      req.headers.set('SID', sid);
      final resp = await req.close().timeout(const Duration(seconds: 3));
      await resp.drain();
      client.close();
      debugPrint('UPnP: GENA UNSUBSCRIBE ${resp.statusCode}');
    } catch (_) {}
    await _stopGenaServer();
  }

  int? _parseTimeout(String? timeout) {
    if (timeout == null) return null;
    final m = RegExp(r'Second-(\d+)', caseSensitive: false).firstMatch(timeout);
    if (m != null) return int.tryParse(m.group(1)!);
    return null;
  }

  Future<void> _handleGenaNotify(HttpRequest req) async {
    try {
      if (req.method != 'NOTIFY') {
        // Also handle GET /upnp/event for some renderers probing
        req.response.statusCode = HttpStatus.ok;
        await req.response.close();
        return;
      }
      final sid = req.headers.value('sid');
      final seqHeader = req.headers.value('seq');
      final seq = seqHeader != null ? int.tryParse(seqHeader) ?? -1 : -1;
      // Validate SID if we have one
      if (_genaSid != null && sid != null && sid != _genaSid) {
        req.response.statusCode = HttpStatus.preconditionFailed;
        await req.response.close();
        return;
      }
      // SEQ dedup (wrap at 4294967295)
      if (seq != -1 && seq <= _lastGenaSeq && _lastGenaSeq != -1) {
        // Out-of-order duplicate, ignore but ack
        req.response.statusCode = HttpStatus.ok;
        await req.response.close();
        return;
      }
      if (seq != -1) _lastGenaSeq = seq;

      // Read body first, then ACK (must be fast, renderer retries on timeout)
      final body = await _readGenaBody(req);
      req.response.statusCode = HttpStatus.ok;
      await req.response.close();

      if (body.isEmpty) return;
      _parseGenaLastChange(body);
    } catch (e) {
      debugPrint('UPnP: GENA notify error: $e');
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<String> _readGenaBody(HttpRequest req) async {
    final bytes = await req.fold<List<int>>([], (p, e) => p..addAll(e));
    return String.fromCharCodes(bytes);
  }

  void _parseGenaLastChange(String xml) {
    try {
      // Extract LastChange property (escaped XML)
      final lastChangeMatch = RegExp(
              r'<LastChange[^>]*>(.*?)</LastChange>',
              dotAll: true,
              caseSensitive: false)
          .firstMatch(xml);
      String? lastChange = lastChangeMatch?.group(1);
      if (lastChange == null) return;
      // Unescape
      lastChange = lastChange
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&amp;', '&')
          .replaceAll('&apos;', "'");

      bool changed = false;
      String? newState;
      Duration? newPos;
      Duration? newDur;
      int? newVol;

      // TransportState val="PLAYING"
      final stateMatch = RegExp(
              r'TransportState[^>]*val="([^"]+)"',
              caseSensitive: false)
          .firstMatch(lastChange);
      if (stateMatch != null) {
        newState = stateMatch.group(1);
        if (newState != null && newState != _rendererState) {
          _rendererState = newState;
          changed = true;
        }
      }
      // RelativeTimePosition val="00:01:23"
      final posMatch = RegExp(
              r'RelativeTimePosition[^>]*val="([^"]+)"',
              caseSensitive: false)
          .firstMatch(lastChange);
      if (posMatch != null) {
        final v = posMatch.group(1)!;
        newPos = _parseTime(v);
        if (newPos != _rendererPosition) {
          _rendererPosition = newPos;
          changed = true;
        }
      }
      // Also try AVTransportURI change, CurrentTrackDuration
      final durMatch = RegExp(
              r'CurrentTrackDuration[^>]*val="([^"]+)"',
              caseSensitive: false)
          .firstMatch(lastChange);
      if (durMatch != null) {
        final v = durMatch.group(1)!;
        newDur = _parseTime(v);
        if (newDur != _rendererDuration && newDur != Duration.zero) {
          _rendererDuration = newDur;
          changed = true;
        }
      }
      // Volume via RenderingControl LastChange not here, but some renderers include it
      final volMatch = RegExp(r'Volume[^>]*val="(\d+)"', caseSensitive: false)
          .firstMatch(lastChange);
      if (volMatch != null) {
        final v = int.tryParse(volMatch.group(1)!);
        if (v != null && v != _volume) {
          _volume = v;
          changed = true;
        }
      }

      if (changed) {
        debugPrint(
            'UPnP: GENA LastChange → state=$_rendererState pos=$_rendererPosition dur=$_rendererDuration');
        // Reset poll error because we got live event
        _consecutivePollErrors = 0;
        notifyListeners();
        // Detect natural track end: STOPPED after PLAYING triggers _onUpnpStateChanged logic in provider
      }
    } catch (e) {
      debugPrint('UPnP: GENA parse error: $e');
    }
  }

  bool _isPolling = false;
  int _pollCount = 0;
  int _consecutivePollErrors = 0;

  Future<void> _poll() async {
    if (_isPolling) return;
    final device = _connectedDevice;
    if (device == null) return;
    _isPolling = true;
    _pollCount++;

    try {
      final state = await getPlaybackState();
      if (state == null) {
        // getPlaybackState() caught an exception internally and returned null.
        _consecutivePollErrors++;
        notifyListeners();
        if (_consecutivePollErrors == 1 || _consecutivePollErrors % 5 == 0) {
          debugPrint(
            'UPnP: poll failed $_consecutivePollErrors time(s) in a row '
            '— renderer may be unreachable',
          );
        }
        // 30 consecutive failures (~30 s) — treat the renderer as gone.
        // Network hiccups and AP roaming typically resolve within 10–15 s,
        // so 30 s gives enough headroom without leaving the user stuck.
        if (_consecutivePollErrors >= 30) {
          debugPrint('UPnP: 30 consecutive poll failures — auto-disconnecting renderer');
          disconnect();
          onRendererLost?.call();
        }
        return;
      }

      if (_consecutivePollErrors != 0) {
        _consecutivePollErrors = 0;
        notifyListeners();
      }

      bool changed = false;
      if (state.transportState != _rendererState) {
        _rendererState = state.transportState;
        changed = true;
      }
      if (state.position != _rendererPosition) {
        _rendererPosition = state.position;
        changed = true;
      }
      if (state.duration != _rendererDuration) {
        _rendererDuration = state.duration;
        changed = true;
      }

      if (device.renderingControlUrl != null && _pollCount % 5 == 0) {
        final vol = await getVolume();
        if (vol >= 0 && vol != _volume) {
          _volume = vol;
          changed = true;
        }
      }

      if (changed) {
        notifyListeners();
      }
    } catch (e) {
      _consecutivePollErrors++;
      notifyListeners();
      debugPrint('UPnP: poll error: $e');
      if (_consecutivePollErrors >= 30) {
        debugPrint('UPnP: 30 consecutive poll failures — auto-disconnecting renderer');
        disconnect();
        onRendererLost?.call();
      }
    } finally {
      _isPolling = false;
    }
  }

  Future<UpnpPlaybackState?> getPlaybackState() async {
    final device = _connectedDevice;
    if (device == null) return null;

    try {
      
      final transportXml = await _soapQuery(
        device.avTransportUrl,
        'GetTransportInfo',
        '',
      );
      final state =
          _xmlText(transportXml, 'CurrentTransportState') ?? 'STOPPED';

      final posXml = await _soapQuery(
        device.avTransportUrl,
        'GetPositionInfo',
        '',
      );
      final relTime = _xmlText(posXml, 'RelTime') ?? '0:00:00';
      final trackDuration = _xmlText(posXml, 'TrackDuration') ?? '0:00:00';

      return UpnpPlaybackState(
        transportState: state,
        position: _parseTime(relTime),
        duration: _parseTime(trackDuration),
      );
    } catch (e) {
      debugPrint('UPnP: getPlaybackState error: $e');
      return null;
    }
  }

  Future<bool> loadAndPlay({
    required String url,
    required String title,
    required String artist,
    String? album,
    String? albumArtUrl,
    int? durationSecs,
    String? contentType,
  }) async {
    final device = _connectedDevice;
    if (device == null) {
      debugPrint('UPnP: loadAndPlay called but no device connected');
      return false;
    }

    debugPrint('UPnP: loadAndPlay → ${device.friendlyName}');
    debugPrint('UPnP:   URL: $url');
    debugPrint('UPnP:   AVTransport: ${device.avTransportUrl}');

    try {
      await _soap(device.avTransportUrl, 'Stop', '');
      debugPrint('UPnP: Stop OK');
    } catch (e) {
      debugPrint('UPnP: Stop failed (ignoring): $e');
    }

    final didl = _didl(
      title: title,
      artist: artist,
      url: url,
      album: album,
      albumArtUrl: albumArtUrl,
      durationSecs: durationSecs,
      contentType: contentType,
    );
    debugPrint('UPnP: SetAVTransportURI…');
    await _soap(
      device.avTransportUrl,
      'SetAVTransportURI',
      '<CurrentURI>${_xmlEscapeAttr(url)}</CurrentURI>\n'
          '<CurrentURIMetaData>$didl</CurrentURIMetaData>',
    );
    debugPrint('UPnP: SetAVTransportURI OK');

    try {
      await _soap(device.avTransportUrl, 'Play', '<Speed>1</Speed>');
      debugPrint('UPnP: Playing "$title" on ${device.friendlyName} (instant)');
      return true;
    } catch (e) {
      debugPrint('UPnP: Instant Play failed ($e), retrying with backoff…');
    }

    const maxAttempts = 5;
    var delay = const Duration(milliseconds: 150);

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      await Future.delayed(delay);

      try {
        final xml = await _soapQuery(
          device.avTransportUrl,
          'GetTransportInfo',
          '',
        );
        final state = _xmlText(xml, 'CurrentTransportState') ?? '';
        if (state == 'TRANSITIONING') {
          debugPrint('UPnP: Renderer TRANSITIONING (attempt $attempt)');
          delay = delay * 2 < const Duration(milliseconds: 2400)
              ? delay * 2
              : const Duration(milliseconds: 2400);
          continue;
        }
      } catch (_) {
        
      }

      try {
        await _soap(device.avTransportUrl, 'Play', '<Speed>1</Speed>');
        debugPrint('UPnP: Playing "$title" on ${device.friendlyName} (attempt $attempt)');
        return true;
      } catch (e) {
        debugPrint('UPnP: Play attempt $attempt/$maxAttempts failed: $e');
        if (attempt == maxAttempts) return false;
        delay = delay * 2 < const Duration(milliseconds: 2400)
            ? delay * 2
            : const Duration(milliseconds: 2400);
      }
    }
    return false;
  }

  /// Prefetches next track for gapless playback (AVTransport:1 SetNextAVTransportURI).
  /// Call after successful loadAndPlay; renderer will auto-advance.
  /// Returns true if renderer accepted the next URI, false if unsupported (e.g. 501).
  Future<bool> setNextTrack({
    required String url,
    required String title,
    required String artist,
    String? album,
    String? albumArtUrl,
    int? durationSecs,
    String? contentType,
  }) async {
    final device = _connectedDevice;
    if (device == null) return false;
    final didl = _didl(
      title: title,
      artist: artist,
      url: url,
      album: album,
      albumArtUrl: albumArtUrl,
      durationSecs: durationSecs,
      contentType: contentType,
    );
    try {
      await _soap(
        device.avTransportUrl,
        'SetNextAVTransportURI',
        '<NextURI>${_xmlEscapeAttr(url)}</NextURI>\n'
            '<NextURIMetaData>$didl</NextURIMetaData>',
      );
      debugPrint('UPnP: SetNextAVTransportURI OK for "$title"');
      return true;
    } catch (e) {
      debugPrint('UPnP: SetNextAVTransportURI failed (unsupported ok): $e');
      return false;
    }
  }

  Future<void> pause() async {
    final device = _connectedDevice;
    if (device == null) return;
    try {
      await _soap(device.avTransportUrl, 'Pause', '');
    } catch (e) {
      debugPrint('UPnP: pause error: $e');
    }
  }

  Future<void> play() async {
    final device = _connectedDevice;
    if (device == null) return;
    try {
      await _soap(device.avTransportUrl, 'Play', '<Speed>1</Speed>');
    } catch (e) {
      debugPrint('UPnP: play error: $e');
    }
  }

  Future<void> stop() async {
    final device = _connectedDevice;
    if (device == null) return;
    try {
      await _soap(device.avTransportUrl, 'Stop', '');
    } catch (e) {
      debugPrint('UPnP: stop error: $e');
    }
  }

  Future<void> seek(Duration position) async {
    final device = _connectedDevice;
    if (device == null) return;
    try {
      final hms = _formatTime(position);
      await _soap(
        device.avTransportUrl,
        'Seek',
        '<Unit>REL_TIME</Unit><Target>$hms</Target>',
      );
    } catch (e) {
      debugPrint('UPnP: seek error: $e');
    }
  }

  Future<void> _soap(String controlUrl, String action, String body) async {
    const serviceType = 'urn:schemas-upnp-org:service:AVTransport:1';
    final envelope =
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"'
        ' s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\n'
        '  <s:Body>\n'
        '    <u:$action xmlns:u="$serviceType">\n'
        '      <InstanceID>0</InstanceID>\n'
        '      $body\n'
        '    </u:$action>\n'
        '  </s:Body>\n'
        '</s:Envelope>';

    debugPrint('UPnP SOAP → $action @ $controlUrl');

    final response = await _dio.post<String>(
      controlUrl,
      data: envelope,
      options: Options(
        headers: {
          'Content-Type': 'text/xml; charset="utf-8"',
          'SOAPAction': '"$serviceType#$action"',
        },
        validateStatus: (_) => true, 
        responseType: ResponseType.plain,
      ),
    );

    final status = response.statusCode ?? 0;
    final responseBody = response.data ?? '';
    debugPrint(
      'UPnP SOAP ← $action HTTP $status | ${responseBody.length} bytes',
    );
    if (responseBody.isNotEmpty) {
      
      debugPrint(
        'UPnP SOAP body: ${responseBody.substring(0, responseBody.length.clamp(0, 600))}',
      );
    }

    if (status < 200 || status >= 300) {
      throw Exception('UPnP SOAP $action failed — HTTP $status: $responseBody');
    }

    final lowerBody = responseBody.toLowerCase();
    if (lowerBody.contains('<s:fault>') ||
        lowerBody.contains('<soap:fault>') ||
        lowerBody.contains('<fault>')) {
      
      final code =
          RegExp(
            r'<errorCode>([^<]*)</errorCode>',
            caseSensitive: false,
          ).firstMatch(responseBody)?.group(1) ??
          RegExp(
            r'<faultcode>([^<]*)</faultcode>',
            caseSensitive: false,
          ).firstMatch(responseBody)?.group(1);
      final desc =
          RegExp(
            r'<errorDescription>([^<]*)</errorDescription>',
            caseSensitive: false,
          ).firstMatch(responseBody)?.group(1) ??
          RegExp(
            r'<faultstring>([^<]*)</faultstring>',
            caseSensitive: false,
          ).firstMatch(responseBody)?.group(1);
      throw Exception('UPnP SOAP fault for $action — code: $code, desc: $desc');
    }
  }

  Future<String> _soapQuery(
    String controlUrl,
    String action,
    String body,
  ) async {
    const serviceType = 'urn:schemas-upnp-org:service:AVTransport:1';
    final envelope =
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"'
        ' s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\n'
        '  <s:Body>\n'
        '    <u:$action xmlns:u="$serviceType">\n'
        '      <InstanceID>0</InstanceID>\n'
        '      $body\n'
        '    </u:$action>\n'
        '  </s:Body>\n'
        '</s:Envelope>';

    final response = await _dio.post<String>(
      controlUrl,
      data: envelope,
      options: Options(
        headers: {
          'Content-Type': 'text/xml; charset="utf-8"',
          'SOAPAction': '"$serviceType#$action"',
        },
        validateStatus: (_) => true,
        responseType: ResponseType.plain,
      ),
    );

    final status = response.statusCode ?? 0;
    final responseBody = response.data ?? '';
    if (status < 200 || status >= 300) {
      throw Exception('UPnP SOAP $action failed — HTTP $status');
    }
    final lowerBody = responseBody.toLowerCase();
    if (lowerBody.contains('<s:fault>') ||
        lowerBody.contains('<soap:fault>') ||
        lowerBody.contains('<fault>')) {
      throw Exception('UPnP SOAP fault for $action');
    }
    return responseBody;
  }

  Future<String> _renderingQuery(String action, String body) async {
    final device = _connectedDevice;
    if (device?.renderingControlUrl == null) {
      throw Exception('No RenderingControl URL');
    }
    const serviceType = 'urn:schemas-upnp-org:service:RenderingControl:1';
    final envelope =
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"'
        ' s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\n'
        '  <s:Body>\n'
        '    <u:$action xmlns:u="$serviceType">\n'
        '      <InstanceID>0</InstanceID>\n'
        '      $body\n'
        '    </u:$action>\n'
        '  </s:Body>\n'
        '</s:Envelope>';

    final response = await _dio.post<String>(
      device!.renderingControlUrl!,
      data: envelope,
      options: Options(
        headers: {
          'Content-Type': 'text/xml; charset="utf-8"',
          'SOAPAction': '"$serviceType#$action"',
        },
        validateStatus: (_) => true,
        responseType: ResponseType.plain,
      ),
    );

    final status = response.statusCode ?? 0;
    final responseBody = response.data ?? '';
    if (status < 200 || status >= 300) {
      throw Exception('UPnP RenderingControl $action failed — HTTP $status');
    }
    final lowerBody = responseBody.toLowerCase();
    if (lowerBody.contains('<s:fault>') ||
        lowerBody.contains('<soap:fault>') ||
        lowerBody.contains('<fault>')) {
      throw Exception('UPnP RenderingControl fault for $action');
    }
    return responseBody;
  }

  Future<void> setVolume(int vol) async {
    vol = vol.clamp(0, 100);
    try {
      await _renderingQuery(
        'SetVolume',
        '<Channel>Master</Channel><DesiredVolume>$vol</DesiredVolume>',
      );
      _volume = vol;
      notifyListeners();
    } catch (e) {
      debugPrint('UPnP: SetVolume failed: $e');
    }
  }

  Future<int> getVolume() async {
    try {
      final xml = await _renderingQuery(
        'GetVolume',
        '<Channel>Master</Channel>',
      );
      final val = _xmlText(xml, 'CurrentVolume');
      return val != null ? int.tryParse(val) ?? -1 : -1;
    } catch (_) {
      return -1;
    }
  }

  /// Returns a MIME type string for [suffix] (e.g. 'mp3' → 'audio/mpeg').
  /// Returns null when the suffix is unknown so callers can fall back to '*'.
  static String? mimeTypeFromSuffix(String? suffix) {
    switch (suffix?.toLowerCase()) {
      case 'mp3':
        return 'audio/mpeg';
      case 'flac':
        return 'audio/flac';
      case 'ogg':
      case 'oga':
        return 'audio/ogg';
      case 'opus':
        return 'audio/opus';
      case 'aac':
        return 'audio/aac';
      case 'm4a':
        return 'audio/mp4';
      case 'wav':
        return 'audio/wav';
      case 'wma':
        return 'audio/x-ms-wma';
      case 'aiff':
      case 'aif':
        return 'audio/aiff';
      default:
        return null;
    }
  }

  static String _normalizeMime(String? mime) {
    if (mime == null || mime == '*') return 'audio/mpeg';
    final lower = mime.toLowerCase().trim();
    // Navidrome sometimes sends audio/x-flac, x-aac etc — normalize for strict renderers
    if (lower == 'audio/x-flac') return 'audio/flac';
    if (lower == 'audio/x-aac' || lower == 'audio/aacp') return 'audio/aac';
    if (lower == 'audio/x-mpeg' || lower == 'audio/mp3') return 'audio/mpeg';
    if (lower == 'audio/x-wav') return 'audio/wav';
    if (lower == 'audio/x-m4a' || lower == 'audio/mp4a-latm') return 'audio/mp4';
    if (lower == 'audio/x-opus') return 'audio/ogg';
    if (lower.contains(';')) return lower.split(';').first.trim();
    return lower;
  }

  static String _didl({
    required String title,
    required String artist,
    required String url,
    String? album,
    String? albumArtUrl,
    int? durationSecs,
    String? contentType,
  }) {
    String esc(String s) => s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');

    final mimeType = _normalizeMime(contentType);
    // Strict renderers (Samsung Tizen, LG webOS, BubbleUPnP, moode) validate DLNA flags
    final dlnaFlags = 'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000';
    final protocol = 'http-get:*:$mimeType:$dlnaFlags';

    final durationAttr = durationSecs != null
        ? ' duration="${_formatTimeSecs(durationSecs)}"'
        : '';

    final albumTag =
        album != null ? '<upnp:album>${esc(album)}</upnp:album>' : '';
    final artTag = albumArtUrl != null
        ? '<upnp:albumArtURI>${esc(albumArtUrl)}</upnp:albumArtURI>'
        : '';

    final didl =
        '<DIDL-Lite '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
        'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">'
        '<item id="1" parentID="0" restricted="1">'
        '<dc:title>${esc(title)}</dc:title>'
        '<dc:creator>${esc(artist)}</dc:creator>'
        '<upnp:artist>${esc(artist)}</upnp:artist>'
        '$albumTag'
        '$artTag'
        '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
        '<res protocolInfo="${esc(protocol)}"$durationAttr>${esc(url)}</res>'
        '</item></DIDL-Lite>';

    return esc(didl);
  }

  static String _xmlEscapeAttr(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _formatTime(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static String _formatTimeSecs(int totalSeconds) {
    final h = (totalSeconds ~/ 3600).toString().padLeft(2, '0');
    final m = ((totalSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static Duration _parseTime(String hms) {
    if (hms == 'NOT_IMPLEMENTED' || hms.isEmpty) return Duration.zero;
    final parts = hms.split(':');
    if (parts.length != 3) return Duration.zero;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    final s = int.tryParse(parts[2].split('.')[0]) ?? 0;
    return Duration(hours: h, minutes: m, seconds: s);
  }

  Future<bool?> _requestNearbyWifiPermission() async {
    try {
      if (!Platform.isAndroid) return true;
      // Android 12+ needs NEARBY_WIFI_DEVICES; permission_handler maps it
      var status = await Permission.nearbyWifiDevices.status;
      if (status.isGranted) return true;
      if (status.isDenied) {
        status = await Permission.nearbyWifiDevices.request();
        return status.isGranted;
      }
      return status.isGranted;
    } catch (e) {
      debugPrint('UPnP permission check failed: $e');
      return null;
    }
  }

  @override
  void dispose() {
    _stopPolling();
    unawaited(_unsubscribeGena());
    _dio.close();
    super.dispose();
  }
}
