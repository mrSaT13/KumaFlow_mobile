import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../main.dart' show navigatorKey;
import '../../screens/remote_control_screen.dart';
import 'remote_device.dart';

/// Системное уведомление «Найден KumaFlow в сети» (Android).
/// Тап открывает страницу пульта. Кулдаун — на стороне discovery (1ч/устройство).
class RemoteFoundNotify {
  static final RemoteFoundNotify instance = RemoteFoundNotify._();
  RemoteFoundNotify._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static const _channelId = 'kumaflow_remote';
  static const _notifId = 1003;

  Future<void> _init() async {
    if (_ready) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android:
              AndroidInitializationSettings('@drawable/ic_stat_sync'),
          iOS: DarwinInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: (resp) {
          if (resp.payload == 'remote') {
            try {
              final ctx = navigatorKey.currentContext;
              if (ctx != null) {
                Navigator.push(
                  ctx,
                  MaterialPageRoute(
                      builder: (_) => const RemoteControlScreen()),
                );
              }
            } catch (_) {}
          }
        },
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              'Пульт · ПК в сети',
              importance: Importance.high,
            ),
          );
      _ready = true;
    } catch (_) {}
  }

  Future<void> showFound(RemoteDevice d) async {
    if (!Platform.isAndroid) return;
    await _init();
    if (!_ready) return;
    // Android 13+: без runtime-разрешения уведомление молча не покажется.
    try {
      var st = await Permission.notification.status;
      if (!st.isGranted && !st.isLimited && !st.isPermanentlyDenied) {
        st = await Permission.notification.request();
      }
      if (!st.isGranted && !st.isLimited) return;
    } catch (_) {
      return;
    }
    try {
      await _plugin.show(
        id: _notifId,
        title: 'Найден KumaFlow в сети',
        body: '${d.name} · ${d.host} — нажми, чтобы управлять',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Пульт · ПК в сети',
            importance: Importance.high,
            priority: Priority.high,
            autoCancel: true,
            icon: 'ic_stat_sync',
          ),
        ),
        payload: 'remote',
      );
    } catch (_) {}
  }
}
