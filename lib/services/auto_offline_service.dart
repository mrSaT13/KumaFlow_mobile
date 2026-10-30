import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Режим авто-офлайн
enum AutoOfflineMode {
  /// Выключен - никогда не переключать автоматически
  never,

  /// Только на домашнем WiFi
  homeWifi,

  /// На любом WiFi
  allWifi,
}

/// Уведомление о переключении режима
class OfflineSwitchNotification {
  final bool isOffline;
  final String reason;
  final DateTime timestamp;

  OfflineSwitchNotification({
    required this.isOffline,
    required this.reason,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Сервис автоматического переключения в офлайн режим
/// Определяет текущую WiFi сеть и переключает режим прослушивания
class AutoOfflineService extends ChangeNotifier {
  AutoOfflineService({
    this.mode = AutoOfflineMode.never,
    this.checkIntervalSeconds = 30,
    this.homeWifiSsid = '',
  });

  /// Текущий режим
  AutoOfflineMode mode;

  /// Интервал проверки сети (секунды)
  final int checkIntervalSeconds;

  /// SSID домашней WiFi сети
  String homeWifiSsid;

  // Состояние
  bool _isCurrentlyOffline = false;
  bool get isCurrentlyOffline => _isCurrentlyOffline;

  String _currentSsid = '';
  String get currentSsid => _currentSsid;

  bool _isConnectedToWifi = false;
  bool get isConnectedToWifi => _isConnectedToWifi;

  StreamSubscription? _connectivitySubscription;
  Timer? _checkTimer;

  // Уведомления
  final List<OfflineSwitchNotification> _notifications = [];
  List<OfflineSwitchNotification> get notifications =>
      List.unmodifiable(_notifications);

  StreamController<OfflineSwitchNotification>? _notificationController;
  Stream<OfflineSwitchNotification> get onSwitch =>
      _notificationController!.stream;

  /// Инициализация сервиса
  Future<void> init() async {
    _notificationController = StreamController<OfflineSwitchNotification>.broadcast();
    await _loadSettings();
    await _checkNetworkStatus();
    _startListening();
    _startPeriodicCheck();
  }

  /// Загрузка настроек из SharedPreferences
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();

    final modeIndex = prefs.getInt('auto_offline_mode') ?? 0;
    mode = AutoOfflineMode.values[modeIndex];

    homeWifiSsid = prefs.getString('home_wifi_ssid') ?? '';
    _isCurrentlyOffline = prefs.getBool('is_offline_mode') ?? false;
  }

  /// Сохранение настроек
  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('auto_offline_mode', mode.index);
    await prefs.setString('home_wifi_ssid', homeWifiSsid);
    await prefs.setBool('is_offline_mode', _isCurrentlyOffline);
  }

  /// Проверка текущего статуса сети
  Future<void> _checkNetworkStatus() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();

      if (connectivityResult == ConnectivityResult.wifi) {
        _isConnectedToWifi = true;
        _currentSsid = 'wifi'; // SSID detection requires platform channel
      } else {
        _isConnectedToWifi = false;
        _currentSsid = '';
      }

      _updateOfflineStatus();
      notifyListeners();
    } catch (e) {
      _isConnectedToWifi = false;
      _currentSsid = '';
    }
  }

  /// Обновление статуса офлайн на основе текущей сети
  void _updateOfflineStatus() {
    bool shouldBeOffline = false;

    switch (mode) {
      case AutoOfflineMode.never:
        // Никогда не переключаем автоматически
        shouldBeOffline = false;
        break;

      case AutoOfflineMode.homeWifi:
        // Офлайн только если НЕ подключены к домашнему WiFi
        if (_isConnectedToWifi && homeWifiSsid.isNotEmpty) {
          shouldBeOffline = _currentSsid != homeWifiSsid;
        } else if (!_isConnectedToWifi) {
          shouldBeOffline = true;
        }
        break;

      case AutoOfflineMode.allWifi:
        // Офлайн если НЕ подключены ни к какой WiFi
        shouldBeOffline = !_isConnectedToWifi;
        break;
    }

    if (shouldBeOffline != _isCurrentlyOffline) {
      _isCurrentlyOffline = shouldBeOffline;
      _sendNotification(
        isOffline: shouldBeOffline,
        reason: _getSwitchReason(),
      );
      _saveSettings();
    }
  }

  /// Получение причины переключения
  String _getSwitchReason() {
    if (_isCurrentlyOffline) {
      if (!_isConnectedToWifi) {
        return 'Нет подключения к WiFi';
      } else if (mode == AutoOfflineMode.homeWifi) {
        return 'Режим homeWifi: подключено к WiFi';
      }
    }
    return 'Подключено к сети: ${_isConnectedToWifi ? "WiFi" : "мобильная сеть"}';
  }

  /// Отправка уведомления о переключении
  void _sendNotification({
    required bool isOffline,
    required String reason,
  }) {
    final notification = OfflineSwitchNotification(
      isOffline: isOffline,
      reason: reason,
    );

    _notifications.add(notification);

    // Ограничиваем историю уведомлений
    if (_notifications.length > 50) {
      _notifications.removeAt(0);
    }

    _notificationController?.add(notification);
    notifyListeners();
  }

  /// Слушатель изменений подключения
  void _startListening() {
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) {
      _checkNetworkStatus();
    });
  }

  /// Периодическая проверка сети
  void _startPeriodicCheck() {
    _checkTimer?.cancel();
    _checkTimer = Timer.periodic(
      Duration(seconds: checkIntervalSeconds),
      (_) => _checkNetworkStatus(),
    );
  }

  /// Установка режима
  Future<void> setMode(AutoOfflineMode newMode) async {
    mode = newMode;
    await _saveSettings();
    _checkNetworkStatus();
    notifyListeners();
  }

  /// Установка SSID домашней WiFi сети
  Future<void> setHomeWifiSsid(String ssid) async {
    homeWifiSsid = ssid;
    await _saveSettings();
    _checkNetworkStatus();
    notifyListeners();
  }

  /// Принудительное включение/отключение офлайн
  void setOffline(bool value) {
    _isCurrentlyOffline = value;
    _saveSettings();
    _sendNotification(
      isOffline: value,
      reason: value ? 'Ручное включение офлайн' : 'Ручное включение онлайн',
    );
    notifyListeners();
  }

  /// Очистка истории уведомлений
  void clearNotifications() {
    _notifications.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _checkTimer?.cancel();
    _notificationController?.close();
    super.dispose();
  }
}

/// Провайдер для доступа к AutoOfflineService из виджетов
class AutoOfflineServiceProvider extends StatelessWidget {
  const AutoOfflineServiceProvider({
    super.key,
    required this.child,
    this.mode = AutoOfflineMode.never,
    this.checkIntervalSeconds = 30,
    this.homeWifiSsid = '',
  });

  final Widget child;
  final AutoOfflineMode mode;
  final int checkIntervalSeconds;
  final String homeWifiSsid;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AutoOfflineService>(
      create: (_) => AutoOfflineService(
        mode: mode,
        checkIntervalSeconds: checkIntervalSeconds,
        homeWifiSsid: homeWifiSsid,
      )..init(),
      child: child,
    );
  }
}

/// Виджет для отображения статуса авто-офлайн
class AutoOfflineStatusWidget extends StatelessWidget {
  const AutoOfflineStatusWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AutoOfflineService>(
      builder: (context, service, _) {
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: service.isCurrentlyOffline
                ? const Color(0xFF1E3A5F)
                : const Color(0xFF1A472A),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                service.isCurrentlyOffline
                    ? Icons.wifi_off
                    : Icons.wifi,
                color: service.isCurrentlyOffline
                    ? const Color(0xFFFF6B6B)
                    : const Color(0xFF4ECB71),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      service.isCurrentlyOffline
                          ? 'Офлайн режим'
                          : 'Онлайн режим',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: service.isCurrentlyOffline
                            ? const Color(0xFFFF6B6B)
                            : const Color(0xFF4ECB71),
                      ),
                    ),
                    if (service.currentSsid.isNotEmpty)
                      Text(
                        'WiFi: ${service.currentSsid}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF9E9E9E),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
