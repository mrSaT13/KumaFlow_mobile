import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

/// Фоновая проверка новинок от отслеживаемых артистов.
///
/// Лёгкий опрос (unread-count + список), без скачивания: найденное
/// складываем в очередь `brain_arrivals_pending_v1`, качает foreground
/// при открытом приложении (там же проверяются тумблер и Wi-Fi).
/// Дедуп общий с foreground-вотчером (`brain_arrivals_seen_v1`):
/// что уже показано — повторно не пушим ни оттуда, ни отсюда.
const String kBrainArrivalsTask = 'kf_brain_arrivals';
const String kArrivalsSeenKey = 'brain_arrivals_seen_v1';
const String kArrivalsPendingKey = 'brain_arrivals_pending_v1';
const String kArrivalsChannelId = 'kumaflow_arrivals';

@pragma('vm:entry-point')
void brainArrivalsDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == kBrainArrivalsTask) {
      try {
        await runBrainArrivalsCheck();
      } catch (_) {
        // Тихо: следующая попытка по расписанию.
      }
    }
    return Future.value(true);
  });
}

/// Регистрация периодического фона. Вызывать из main() после
/// ensureInitialized, best-effort. iOS требует шагов в Xcode
/// (BGTaskScheduler) — там задача просто не стартует без них.
Future<void> scheduleBrainArrivals() async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  try {
    await Workmanager().initialize(brainArrivalsDispatcher);
    await Workmanager().registerPeriodicTask(
      'kf-brain-arrivals-periodic',
      kBrainArrivalsTask,
      frequency: const Duration(minutes: 30),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
    );
  } catch (e) {
    debugPrint('[ArrivalsBG] schedule failed: $e');
  }
}

/// Сам опрос. Публичная, чтобы foreground мог дернуть вручную при желании.
Future<void> runBrainArrivalsCheck() async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool('brain_enabled') != true) return;
  final base = (prefs.getString('brain_base_url') ?? '').trim();
  final token = (prefs.getString('brain_api_token') ?? '').trim();
  final userId = (prefs.getString('brain_user_id') ?? '').trim();
  if (base.isEmpty || userId.isEmpty) return;
  final b =
      base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    headers: {
      'Content-Type': 'application/json',
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    },
  ));
  try {
    final u = await dio.get('$b/api/notifications/unread-count',
        queryParameters: {'user_id': userId});
    final unread = _asInt((u.data is Map)
        ? ((u.data as Map)['unread'] ??
            (u.data as Map)['count'] ??
            (u.data as Map)['unread_count'])
        : null);
    if (unread <= 0) return;
    final l = await dio.get('$b/api/notifications/',
        queryParameters: {'user_id': userId, 'limit': 20});
    final items = (l.data is Map) ? (l.data as Map)['notifications'] : null;
    if (items is! List) return;
    final seen =
        (prefs.getStringList(kArrivalsSeenKey) ?? []).toSet();
    final pending =
        (prefs.getStringList(kArrivalsPendingKey) ?? []).toList();
    var changed = false;
    for (final raw in items) {
      if (raw is! Map) continue;
      final n = Map<String, dynamic>.from(raw);
      final id = '${n['id'] ?? ''}';
      if (id.isEmpty || n['read_at'] != null || seen.contains(id)) {
        continue;
      }
      if ('${n['kind'] ?? ''}' != 'discovery') continue;
      await _showArrival(
          title: '${n['title'] ?? 'Новое поступление'}',
          body: '${n['body'] ?? ''}',
          tag: id);
      final meta = n['meta'];
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
      await prefs.setStringList(kArrivalsSeenKey, trimmed);
      await prefs.setStringList(kArrivalsPendingKey, pending);
    }
  } catch (_) {
    // Тихо: сеть/сервер недоступны — проверим в следующий раз.
  } finally {
    dio.close(force: true);
  }
}

int _asInt(dynamic v) {
  if (v is int) return v;
  return int.tryParse('$v') ?? 0;
}

Future<void> _showArrival(
    {required String title,
    required String body,
    required String tag}) async {
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    const android =
        AndroidInitializationSettings('@drawable/ic_stat_sync');
    const darwin = DarwinInitializationSettings();
    await plugin.initialize(
      settings: const InitializationSettings(
        android: android,
        iOS: darwin,
        macOS: darwin,
      ),
    );
    final androidPlugin = plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        kArrivalsChannelId,
        'Новинки от артистов',
        importance: Importance.high,
      ),
    );
    await plugin.show(
      id: 2000 + (tag.hashCode.abs() % 100),
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          kArrivalsChannelId,
          'Новинки от артистов',
          importance: Importance.high,
          priority: Priority.high,
          autoCancel: true,
          icon: 'ic_stat_sync',
          largeIcon:
              DrawableResourceAndroidBitmap('ic_notif_large'),
          color: Color(0xFF7C4DFF),
        ),
      ),
    );
  } catch (e) {
    debugPrint('[ArrivalsBG] show failed: $e');
  }
}
