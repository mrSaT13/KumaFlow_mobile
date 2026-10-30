import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'brain_arrivals_bg.dart'
    show kArrivalsPendingKey, kArrivalsSeenKey;
import 'kumaflow_brain/kumaflow_brain_bridge.dart';

/// Новинки от отслеживаемых артистов.
///
/// Мозг по событию от внешнего сервиса кладёт треки в библиотеку и
/// создаёт уведомление (kind=discovery, link=/library) подписавшимся.
/// Этот вотчер периодически опрашивает счётчик непрочитанных и
/// показывает системное уведомление о новых поступлениях — иначе их
/// видно только вручную на экране KumaFlow Brain.
/// Desktop пропускаем (там виден колокольчик в вебе).
class BrainNewArrivalsService extends ChangeNotifier {
  static final BrainNewArrivalsService instance =
      BrainNewArrivalsService._();
  BrainNewArrivalsService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _ready = false;
  bool _permChecked = false;
  bool _permGranted = false;
  Timer? _timer;
  bool _checking = false;

  // --- In-app состояние (колокольчик с деталями, работает и на десктопе) ---
  int _unread = 0;
  List<Map<String, dynamic>> _items = const [];
  String? _lastError;
  DateTime? _lastCheck;
  bool _bridgeOff = false;

  int get unread => _unread;
  List<Map<String, dynamic>> get items =>
      List.unmodifiable(_items);
  String? get lastError => _lastError;
  DateTime? get lastCheck => _lastCheck;
  bool get bridgeOff => _bridgeOff;

  static const String _channelId = 'kumaflow_arrivals';
  static const int _baseId = 2000;
  static const String _seenKey = kArrivalsSeenKey;
  static const String _pendingKey = kArrivalsPendingKey;

  // Тумблеры (дефолт: докачка ВЫКЛ, только Wi-Fi ВКЛ).
  static const String _kAutoKey = 'brain_arrivals_auto_v1';
  static const String _kWifiKey = 'brain_arrivals_wifi_v1';

  static Future<bool> autoDownloadEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kAutoKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setAutoDownloadEnabled(bool v) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoKey, v);
    } catch (_) {}
  }

  static Future<bool> wifiOnly() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kWifiKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setWifiOnly(bool v) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kWifiKey, v);
    } catch (_) {}
  }

  Future<void> _init() async {
    if (_ready) return;
    try {
      const android =
          AndroidInitializationSettings('@drawable/ic_stat_sync');
      const darwin = DarwinInitializationSettings();
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: android,
          iOS: darwin,
          macOS: darwin,
        ),
      );
      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          'Новинки от артистов',
          importance: Importance.high,
        ),
      );
      _ready = true;
    } catch (e) {
      debugPrint('[Arrivals] init failed: $e');
    }
  }

  Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    if (_permChecked) return _permGranted;
    try {
      var status = await Permission.notification.status;
      if (!status.isGranted &&
          !status.isLimited &&
          !status.isPermanentlyDenied) {
        status = await Permission.notification.request();
      }
      _permGranted = status.isGranted || status.isLimited;
    } catch (_) {
      _permGranted = false;
    }
    _permChecked = true;
    return _permGranted;
  }

  /// Подписка на периодический опрос. Fire-and-forget из main().
  /// onTracks — докачка очереди в офлайн-кеш (возвращает id скачанного).
  /// In-app опрос работает везде (десктоп/без разрешений), системный пуш —
  /// только там где есть permission.
  Future<void> attach(KumaFlowBrainBridge bridge,
      {Future<Set<String>> Function(List<Map<String, String>> tracks)?
          onTracks}) async {
    await _init();
    _onTracks = onTracks;
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => _check(bridge),
    );
    // Первая проверка быстро (10с), повтор на 90с если мост ещё не прогрет.
    Future.delayed(const Duration(seconds: 10), () => _check(bridge));
    Future.delayed(const Duration(seconds: 90), () => _check(bridge));
  }

  /// Ручное обновление из UI (pull-to-refresh / тап по колокольчику).
  Future<void> refreshNow(KumaFlowBrainBridge bridge) => _check(bridge);

  Future<Set<String>> Function(List<Map<String, String>> tracks)? _onTracks;

  /// Ручной дренаж очереди (например, по возврату в приложение).
  Future<void> drainPending() => _drainPending();

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  Future<void> _check(KumaFlowBrainBridge bridge) async {
    if (_checking) return;
    if (!bridge.isActive || bridge.isOfflineNow) {
      _bridgeOff = true;
      _lastError = bridge.isOfflineNow ? 'Мост офлайн' : 'Мозг выключен или не настроен';
      notifyListeners();
      return;
    }
    final client = bridge.client;
    if (client == null) {
      _bridgeOff = true;
      _lastError = 'Нет клиента мозга';
      notifyListeners();
      return;
    }
    _checking = true;
    _bridgeOff = false;
    try {
      final u =
          await client.unreadCount(userId: bridge.settings.userId);
      final unread = (u['unread'] ?? u['count'] ?? u['unread_count']);
      final n = unread is int ? unread : int.tryParse('$unread') ?? 0;
      // Бейдж обновляем сразу — даже если список не влезет в таймаут,
      // колокольчик не врёт про 10 при пустом списке.
      if (_unread != n) {
        _unread = n;
        notifyListeners();
      }
      // Список: сначала 20 (быстро), при таймауте — добор 10.
      List<dynamic>? items;
      try {
        final l = await client.notifications(
            userId: bridge.settings.userId, limit: 20);
        if (l['notifications'] is List) items = l['notifications'];
      } catch (e) {
        debugPrint('[Arrivals] list limit=20 failed: $e — retry 10');
      }
      if (items == null) {
        try {
          final l = await client.notifications(
              userId: bridge.settings.userId, limit: 10);
          if (l['notifications'] is List) items = l['notifications'];
        } catch (e) {
          // Сервер тормозит: кеш не трогаем, показываем ошибку поверх него.
          _lastCheck = DateTime.now();
          _lastError =
              'Сервер долго отвечает (таймаут). Загрузки идут — список подтянется позже.';
          debugPrint('[Arrivals] list limit=10 failed: $e');
          notifyListeners();
          return;
        }
      }
      if (items != null) {
        _items = items
            .whereType<Map>()
            .map(Map<String, dynamic>.from)
            .toList();
        notifyListeners();
      }
      if (n <= 0) {
        _lastCheck = DateTime.now();
        _lastError = null;
        notifyListeners();
        return;
      }
      if (items == null) return;
      final prefs = await SharedPreferences.getInstance();
      final seen =
          (prefs.getStringList(_seenKey) ?? []).toSet();
      final pending =
          (prefs.getStringList(_pendingKey) ?? []).toList();
      var changed = false;
      for (final raw in items) {
        if (raw is! Map) continue;
        final notif = Map<String, dynamic>.from(raw);
        final id = '${notif['id'] ?? ''}';
        if (id.isEmpty ||
            notif['read_at'] != null ||
            seen.contains(id)) {
          continue;
        }
        // Новинки от подписок; остальное (волна/дрейф/техника) не пушим.
        if ('${notif['kind'] ?? ''}' != 'discovery') continue;
        await _show(
          title: '${notif['title'] ?? 'Новое поступление'}',
          body: '${notif['body'] ?? ''}',
          tag: id,
        );
        // Треки в очередь докачки (та же cap 200, что и в фоне).
        final meta = notif['meta'];
        final tracks = (meta is Map) ? meta['tracks'] : null;
        if (tracks is List) {
          for (final t in tracks) {
            if (t is! Map) continue;
            final tid = '${t['id'] ?? ''}';
            if (tid.isEmpty) continue;
            final packed = jsonEncode({
              'id': tid,
              'title': '${t['title'] ?? ''}',
              'artist': '${t['artist'] ?? ''}',
            });
            if (!pending.contains(packed)) pending.add(packed);
          }
          while (pending.length > 200) {
            pending.removeAt(0);
          }
        }
        seen.add(id);
        changed = true;
      }
      if (changed) {
        final trimmed = seen.toList();
        while (trimmed.length > 200) {
          trimmed.removeAt(0);
        }
        await prefs.setStringList(_seenKey, trimmed);
        await prefs.setStringList(_pendingKey, pending);
      }
      _lastCheck = DateTime.now();
      _lastError = null;
      notifyListeners();
    } catch (e) {
      _lastError = '$e';
      notifyListeners();
      debugPrint('[Arrivals] check failed: $e');
    } finally {
      _checking = false;
    }
    // Докачка очереди — не чаще самой проверки, после неё.
    await _drainPending();
  }

  /// Слить очередь фоновых находок в офлайн-кеш.
  /// Условия: тумблер включён, сеть подходит (Wi-Fi), мост активен.
  /// Неудачи остаются в очереди до следующего раза (cap 200).
  Future<void> _drainPending() async {
    final cb = _onTracks;
    if (cb == null || !await autoDownloadEnabled()) return;
    if (!await _networkOk()) return;
    List<String> pending;
    try {
      final prefs = await SharedPreferences.getInstance();
      pending =
          (prefs.getStringList(_pendingKey) ?? []).toList();
    } catch (_) {
      return;
    }
    if (pending.isEmpty) return;
    final tracks = <Map<String, String>>[];
    for (final raw in pending) {
      try {
        final m = jsonDecode(raw);
        if (m is! Map) continue;
        final id = '${m['id'] ?? ''}';
        if (id.isEmpty) continue;
        tracks.add({
          'id': id,
          'title': '${m['title'] ?? ''}',
          'artist': '${m['artist'] ?? ''}',
        });
      } catch (_) {}
    }
    if (tracks.isEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(_pendingKey, const []);
      } catch (_) {}
      return;
    }
    Set<String> done;
    try {
      done = await cb(tracks);
    } catch (_) {
      return;
    }
    if (done.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final rest = pending.where((raw) {
        try {
          final m = jsonDecode(raw);
          return m is! Map || !done.contains('${m['id'] ?? ''}');
        } catch (_) {
          return false;
        }
      }).toList();
      await prefs.setStringList(_pendingKey, rest);
    } catch (_) {}
  }

  /// Пометить одно/другое прочитанным — обновляем и сервер, и локальный бейдж.
  Future<void> markRead(KumaFlowBrainBridge bridge, String id) async {
    final client = bridge.client;
    if (client == null) return;
    try {
      await client.markRead(id);
    } catch (e) {
      debugPrint('[Arrivals] markRead failed: $e');
    }
    _items = _items.map((e) {
      if ('${e['id'] ?? ''}' == id) {
        return {...e, 'read_at': DateTime.now().toIso8601String()};
      }
      return e;
    }).toList();
    _unread = _items
        .where((e) =>
            e['read_at'] == null && '${e['kind'] ?? ''}' == 'discovery')
        .length;
    notifyListeners();
  }

  Future<void> markAllRead(KumaFlowBrainBridge bridge) async {
    final client = bridge.client;
    if (client == null) return;
    try {
      await client.markAllRead(userId: bridge.settings.userId);
    } catch (e) {
      debugPrint('[Arrivals] markAllRead failed: $e');
    }
    _items = _items.map((e) {
      if (e['read_at'] == null) {
        return {...e, 'read_at': DateTime.now().toIso8601String()};
      }
      return e;
    }).toList();
    _unread = 0;
    notifyListeners();
  }

  Future<bool> _networkOk() async {
    try {
      final res = await Connectivity().checkConnectivity();
      final names = res.map((e) => '$e').toSet();
      final anyNet = names.any((s) =>
          s.contains('wifi') ||
          s.contains('ethernet') ||
          s.contains('mobile') ||
          s.contains('vpn'));
      if (!anyNet) return false;
      if (!await wifiOnly()) return true;
      return names.any(
          (s) => s.contains('wifi') || s.contains('ethernet'));
    } catch (_) {
      return false;
    }
  }

  Future<void> _show(
      {required String title, required String body, required String tag}) async {
    if (!_ready) return;
    if (!await _ensurePermission()) return;
    try {
      final androidDetails = AndroidNotificationDetails(
        _channelId,
        'Новинки от артистов',
        importance: Importance.high,
        priority: Priority.high,
        autoCancel: true,
        icon: 'ic_stat_sync',
        largeIcon:
            const DrawableResourceAndroidBitmap('ic_notif_large'),
        color: const Color(0xFF7C4DFF),
      );
      await _plugin.show(
        id: _baseId + (tag.hashCode.abs() % 100),
        title: title,
        body: body,
        notificationDetails:
            NotificationDetails(android: androidDetails),
      );
    } catch (e) {
      debugPrint('[Arrivals] show failed: $e');
    }
  }
}
