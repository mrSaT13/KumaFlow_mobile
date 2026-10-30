import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:nsd/nsd.dart' as nsd;
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_device.dart';

/// Поиск десктопа KumaFlow в LAN + сохранённые устройства.
/// Источники по приоритету:
/// 1) mDNS `_kumaflow-remote._tcp.local` (десктоп анонсирует через bonjour-service);
/// 2) ручной ввод IP:порт+PIN;
/// 3) кнопка «Найти в сети» — быстрый скан подсети по порту 4334.
/// Найденное-несохранённое отдаём через onFound (баннер/уведомление, с кулдауном).
class RemoteDiscovery extends ChangeNotifier {
  static const String mdnsService = '_kumaflow-remote._tcp.local';
  static const String nsdService = '_kumaflow-remote._tcp';
  /// Порт origin/main (4334, как у Feishin); локальный 1.6.6 слушает 4333 —
  /// скан и probe покрывают оба.
  static const int defaultPort = 4334;
  static const int legacyPort = 4333;

  static const _kSavedKey = 'remote_saved_devices';
  static const _kLastKey = 'remote_last_device';

  final List<RemoteDevice> _found = [];
  List<RemoteDevice> _saved = [];
  String? _lastId;
  bool _scanning = false;
  String? _error;
  Timer? _pollTimer;
  StreamSubscription? _connSub;
  final Map<String, DateTime> _bannerAt = {};

  void Function(RemoteDevice device)? onFound;
  /// Сохранённый ПК снова в сети (проба прошла). Отдельный колбэк чтобы
  /// не менять поведение onFound (только новое несохранённое).
  void Function(RemoteDevice device)? onSavedOnline;
  final Map<String, DateTime> _savedBannerAt = {};

  List<RemoteDevice> get found => List.unmodifiable(_found);
  List<RemoteDevice> get saved => List.unmodifiable(_saved);
  bool get isScanning => _scanning;
  String? get error => _error;

  RemoteDevice? get lastDevice {
    if (_lastId == null) return null;
    for (final d in [..._saved, ..._found]) {
      if (d.id == _lastId) return d;
    }
    return null;
  }

  Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      _saved = RemoteDevice.decodeList(p.getString(_kSavedKey) ?? '[]');
      _lastId = p.getString(_kLastKey);
    } catch (_) {}
    try {
      _connSub = Connectivity().onConnectivityChanged.listen((_) async {
        try {
          await discover(silent: true);
        } catch (_) {}
        try {
          await checkSavedOnline();
        } catch (_) {}
      });
    } catch (_) {}
    notifyListeners();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _connSub?.cancel();
    super.dispose();
  }

  /// Периодический опрос пока экран Remote открыт (стоп — вызвать stopPolling).
  void startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      discover(silent: true);
    });
    discover(silent: true);
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kSavedKey, RemoteDevice.encodeList(_saved));
      if (_lastId != null) await p.setString(_kLastKey, _lastId!);
    } catch (_) {}
  }

  void _upsertFound(RemoteDevice d) {
    final i = _found.indexWhere((e) => e.id == d.id);
    if (i >= 0) {
      _found[i].lastSeen = DateTime.now();
      if (d.name.isNotEmpty) _found[i] = d;
    } else {
      _found.add(d);
    }
    // Баннер/уведомление — только про новое несохранённое, не чаще раза в час.
    final isSaved = _saved.any((e) => e.id == d.id);
    if (!isSaved) {
      final last = _bannerAt[d.id];
      if (last == null ||
          DateTime.now().difference(last) > const Duration(hours: 1)) {
        _bannerAt[d.id] = DateTime.now();
        try {
          onFound?.call(d);
        } catch (_) {}
      }
    }
  }

  /// Проба сохранённых хостов: дёшево (1-3 хоста, ~1.5с), без полного
  /// скана подсети. При успехе — found обновляется и стреляет onSavedOnline
  /// (кулдаун 1ч/устройство). Сам коннект не трогаем, только уведомления.
  Future<List<RemoteDevice>> checkSavedOnline() async {
    if (_saved.isEmpty) return found;
    final hits = <RemoteDevice>[];
    try {
      final results = await Future.wait(
        _saved.map((d) async {
          try {
            final port = await probeAny(d.host);
            if (port == null) return null;
            return RemoteDevice(
              name: d.name.isNotEmpty ? d.name : d.host,
              host: d.host,
              port: d.port,
              pinRequired: d.pinRequired,
            );
          } catch (_) {
            return null;
          }
        }),
        eagerError: false,
      ).timeout(const Duration(seconds: 6), onTimeout: () => <RemoteDevice?>[]);
      for (final r in results) {
        if (r == null) continue;
        // Обновляем lastSeen в found чтобы пилюля видела свежесть.
        final i = _found.indexWhere((e) => e.host == r.host);
        if (i >= 0) {
          _found[i].lastSeen = DateTime.now();
        } else {
          r.lastSeen = DateTime.now();
          _found.add(r);
        }
        hits.add(r);
        final last = _savedBannerAt[r.host];
        if (last == null ||
            DateTime.now().difference(last) > const Duration(hours: 1)) {
          _savedBannerAt[r.host] = DateTime.now();
          try {
            onSavedOnline?.call(r);
          } catch (_) {}
        }
      }
      if (hits.isNotEmpty) notifyListeners();
    } catch (_) {}
    return found;
  }

  /// mDNS-опрос (тихий по умолчанию). Возвращает найденные.
  /// Путь: системный NSD (NsdManager/Bonjour) → legacy multicast_dns
  /// (Linux + фолбек). Старый путь падал на этом телефоне с
  /// `reusePort not supported` и никого не находил.
  Future<List<RemoteDevice>> discover({bool silent = true}) async {
    if (_scanning) return found;
    _scanning = true;
    if (!silent) {
      _error = null;
      notifyListeners();
    }
    try {
      if (!Platform.isLinux) {
        try {
          await _discoverNsd().timeout(const Duration(seconds: 9));
        } catch (e) {
          debugPrint('[RemoteDiscovery] nsd failed: $e');
        }
      }
      // Legacy-путь: на Linux основной, на остальных — только если NSD пуст.
      if (Platform.isLinux || _found.isEmpty) {
        await _discoverLegacyMdns(silent: true);
      }
    } catch (e) {
      if (!silent) _error = '$e';
      debugPrint('[RemoteDiscovery] discover failed: $e');
    } finally {
      _scanning = false;
      notifyListeners();
    }
    // Сохранённые добиваем пробой напрямую (mDNS их не находит если ПК
    // не анонсирует). Дёшево, коннект не трогает.
    try {
      await checkSavedOnline().timeout(const Duration(seconds: 7));
    } catch (_) {}
    return found;
  }

  /// Системный NSD: собираем ответы ~4 сек, потом останавливаем.
  Future<void> _discoverNsd() async {
    nsd.Discovery? discovery;
    try {
      discovery = await nsd
          .startDiscovery(nsdService,
              ipLookupType: nsd.IpLookupType.any)
          .timeout(const Duration(seconds: 4));
      final deadline =
          DateTime.now().add(const Duration(seconds: 4));
      while (DateTime.now().isBefore(deadline)) {
        try {
          for (final s in List.of(discovery.services)) {
            _upsertNsdService(s);
          }
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      try {
        for (final s in List.of(discovery.services)) {
          _upsertNsdService(s);
        }
      } catch (_) {}
    } finally {
      try {
        if (discovery != null) {
          await nsd
              .stopDiscovery(discovery)
              .timeout(const Duration(seconds: 2));
        }
      } catch (_) {}
    }
  }

  void _upsertNsdService(dynamic s) {
    try {
      final host = _nsdHost(s);
      final port = _nsdPort(s);
      if (host == null || host.isEmpty || port == null || port <= 0) {
        return;
      }
      var name = '';
      var pinRequired = false;
      try {
        final txt = (s as dynamic).txt;
        if (txt is Map) {
          String txtStr(String k) {
            try {
              dynamic v;
              for (final key in txt.keys) {
                if (key.toString().toLowerCase() == k) {
                  v = txt[key];
                  break;
                }
              }
              if (v == null) return '';
              if (v is String) return v;
              if (v is List<int>) {
                return utf8.decode(v, allowMalformed: true);
              }
              try {
                return utf8.decode(
                    List<int>.from(v as List), allowMalformed: true);
              } catch (_) {
                return '$v';
              }
            } catch (_) {
              return '';
            }
          }

          final n = txtStr('name');
          if (n.isNotEmpty) name = n;
          final p = txtStr('pin').toLowerCase();
          if (p == '1' || p == 'true') pinRequired = true;
        }
      } catch (_) {}
      if (name.isEmpty) {
        try {
          name = ((s as dynamic).name ?? '').toString();
        } catch (_) {}
      }
      // ПК анонсирует "KumaFlow HOSTNAME" — префикс чистим.
      if (name.startsWith('KumaFlow ')) {
        name = name.substring(9).trim();
      }
      _upsertFound(RemoteDevice(
        name: name.isEmpty ? host : name,
        host: host,
        port: port,
        pinRequired: pinRequired,
      ));
    } catch (_) {}
  }

  String? _nsdHost(dynamic s) {
    try {
      dynamic addrs;
      try {
        addrs = (s as dynamic).addresses;
      } catch (_) {}
      addrs ??= (() {
        try {
          return (s as dynamic).ips;
        } catch (_) {
          return null;
        }
      })();
      if (addrs is Iterable) {
        for (final a in addrs) {
          try {
            final ip =
                (a is InternetAddress) ? a.address : '$a'.trim();
            if (ip.isNotEmpty &&
                !ip.contains(':') &&
                ip != '127.0.0.1') {
              return ip;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
    try {
      final h = ((s as dynamic).host ?? '').toString().trim();
      if (h.isEmpty) return null;
      return h;
    } catch (_) {
      return null;
    }
  }

  int? _nsdPort(dynamic s) {
    try {
      final p = (s as dynamic).port;
      if (p is int) return p;
      return int.tryParse('$p');
    } catch (_) {
      return null;
    }
  }

  /// Старый опрос через multicast_dns (Linux + фолбек).
  Future<void> _discoverLegacyMdns({bool silent = true}) async {
    MDnsClient? client;
    try {
      client = MDnsClient();
      await client.start().timeout(const Duration(seconds: 4));
      // Stream.timeout onTimeout: void Function(EventSink) — закрываем sink.
      final ptrs = await client
          .lookup<PtrResourceRecord>(
              ResourceRecordQuery.serverPointer(mdnsService))
          .timeout(const Duration(seconds: 6),
              onTimeout: (sink) => sink.close())
          .toList();
      for (final ptr in ptrs) {
        try {
          final srv = await client
              .lookup<SrvResourceRecord>(
                  ResourceRecordQuery.service(ptr.domainName))
              .timeout(const Duration(seconds: 3),
                  onTimeout: (sink) => sink.close())
              .first;
          final ips = await client
              .lookup<IPAddressResourceRecord>(
                  ResourceRecordQuery.addressIPv4(srv.target))
              .timeout(const Duration(seconds: 3),
                  onTimeout: (sink) => sink.close())
              .toList();
          if (ips.isEmpty) continue;
          var name = ptr.domainName.split('.').first;
          var pinRequired = false;
          try {
            final txts = await client
                .lookup<TxtResourceRecord>(
                    ResourceRecordQuery.text(ptr.domainName))
                .timeout(const Duration(seconds: 2),
                    onTimeout: (sink) => sink.close())
                .toList();
            for (final t in txts) {
              // TXT сырой строкой: "name=Мой ПК pin=1" (ключ=значение через пробел).
              for (final part in t.text.split(RegExp(r'\s+'))) {
                final kv = part.split('=');
                if (kv.length != 2) continue;
                final k = kv[0].trim().toLowerCase();
                final v = kv[1].trim();
                if (k == 'name' && v.isNotEmpty) name = v;
                if ((k == 'pin' || k == 'pinrequired') &&
                    (v == '1' || v.toLowerCase() == 'true')) {
                  pinRequired = true;
                }
              }
            }
          } catch (_) {}
          _upsertFound(RemoteDevice(
            name: name.isEmpty ? ips.first.address.address : name,
            host: ips.first.address.address,
            port: srv.port,
            pinRequired: pinRequired,
          ));
        } catch (_) {}
      }
    } catch (e) {
      if (!silent) _error = '$e';
      debugPrint('[RemoteDiscovery] mdns failed: $e');
    } finally {
      try {
        client?.stop();
      } catch (_) {}
    }
  }

  /// Быстрый скан подсети по порту (фолбек без mDNS, iOS без entitlement).
  /// Проверяем только HTTP-корень десктопа; батчами по 32, таймаут 500мс.
  Future<List<RemoteDevice>> scanSubnet({void Function(int done, int total)? onProgress}) async {
    if (_scanning) return found;
    _scanning = true;
    _error = null;
    notifyListeners();
    try {
      String? wifiIp;
      try {
        for (final itf in await NetworkInterface.list()) {
          for (final a in itf.addresses) {
            if (a.type == InternetAddressType.IPv4 && !a.isLoopback) {
              final ip = a.address;
              if (ip.startsWith('192.168.') ||
                  ip.startsWith('10.') ||
                  ip.startsWith('172.')) {
                wifiIp = ip;
                break;
              }
            }
          }
          if (wifiIp != null) break;
        }
      } catch (_) {}
      if (wifiIp == null) {
        _error = 'Нет Wi-Fi — введи IP вручную';
        return found;
      }
      final prefix = wifiIp.substring(0, wifiIp.lastIndexOf('.') + 1);
      final self = wifiIp;
      final total = 254;
      var done = 0;
      for (var base = 1; base <= 254; base += 32) {
        final batch = <Future<void>>[];
        for (var i = base; i < base + 32 && i <= 254; i++) {
          final host = '$prefix$i';
          if (host == self) {
            done++;
            continue;
          }
          batch.add(_probeHost(host, defaultPort).then((ok) {
            if (ok) {
              _upsertFound(RemoteDevice(
                  name: host, host: host, port: defaultPort));
            } else {
              // 1.6.6 слушает 4333 — второй шанс тем же коннектом.
              _probeHost(host, legacyPort).then((okLegacy) {
                if (okLegacy) {
                  _upsertFound(RemoteDevice(
                      name: host, host: host, port: legacyPort));
                }
              });
            }
          }).whenComplete(() {
            done++;
            try {
              onProgress?.call(done, total);
            } catch (_) {}
          }));
        }
        await Future.wait(batch);
      }
      notifyListeners();
    } catch (e) {
      _error = '$e';
      notifyListeners();
    } finally {
      _scanning = false;
      notifyListeners();
    }
    return found;
  }

  Future<bool> _probeHost(String host, int port,
      {int timeoutMs = 500}) async {
    HttpClient? c;
    try {
      c = HttpClient();
      c.connectionTimeout = Duration(milliseconds: timeoutMs);
      final req = await c
          .getUrl(Uri.parse('http://$host:$port/'))
          .timeout(Duration(milliseconds: timeoutMs));
      final resp = await req
          .close()
          .timeout(Duration(milliseconds: timeoutMs));
      await resp.drain<void>().catchError((_) {});
      return resp.statusCode < 500;
    } catch (_) {
      return false;
    } finally {
      try {
        c?.close(force: true);
      } catch (_) {}
    }
  }

  /// Проверка хоста перед сохранением (ручной ввод). Таймаут 1.5с:
  /// 500мс на лагающем Wi-Fi/VPN давал ложные «ПК не отвечает»
  /// (факт 13.10.2026: тот же хост то проходил, то нет за минуты).
  Future<bool> probe(String host, int port) =>
      _probeHost(host.trim(), port, timeoutMs: 1500);

  /// Рабочий порт хоста (4334office → 4333 legacy). null = не отвечает.
  Future<int?> probeAny(String host) async {
    final h = host.trim();
    if (h.isEmpty) return null;
    if (await _probeHost(h, defaultPort, timeoutMs: 1500)) {
      return defaultPort;
    }
    if (await _probeHost(h, legacyPort, timeoutMs: 1500)) return legacyPort;
    return null;
  }

  Future<void> saveDevice(RemoteDevice d) async {
    _saved.removeWhere((e) => e.id == d.id);
    _saved.insert(0, d);
    _lastId = d.id;
    await _persist();
    notifyListeners();
  }

  Future<void> forgetDevice(String id) async {
    _saved.removeWhere((e) => e.id == id);
    if (_lastId == id) _lastId = _saved.isNotEmpty ? _saved.first.id : null;
    await _persist();
    notifyListeners();
  }

  /// Правка сохранённого устройства (имя/хост/порт). Старый id убираем,
  /// новый встаёт первым и становится последним используемым.
  Future<void> updateDevice(String oldId, RemoteDevice d) async {
    _saved.removeWhere((e) => e.id == oldId);
    _saved.removeWhere((e) => e.id == d.id);
    _saved.insert(0, d);
    _lastId = d.id;
    await _persist();
    notifyListeners();
  }
  Future<void> setLastDevice(RemoteDevice d) async {
    _lastId = d.id;
    await _persist();
  }

  void pruneStale() {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 10));
    _found.removeWhere((d) => d.lastSeen.isBefore(cutoff));
    notifyListeners();
  }

  bool _autoOnce = false;

  /// Один автозаход за запуск: mDNS + проба сохранённых, а если пусто
  /// и мы на Wi-Fi — тихий скан подсети (1.6.6 себя не анонсирует).
  /// Найденное придёт через onFound/onSavedOnline → пилюля + уведомление.
  Future<void> autoDiscoverOnce() async {
    if (_autoOnce) return;
    _autoOnce = true;
    try {
      await discover(silent: true);
    } catch (_) {}
    try {
      await checkSavedOnline();
    } catch (_) {}
    if (_found.isNotEmpty) return;
    try {
      final conn = await Connectivity().checkConnectivity();
      final wifi = conn.any((r) =>
          r == ConnectivityResult.wifi || r == ConnectivityResult.ethernet);
      if (!wifi) return;
      await scanSubnet();
    } catch (_) {}
  }
}
