import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Analytics service — DISABLED in KumaFlow
/// No data is collected, no tracking, no third-party services.
class AnalyticsService {
  static final AnalyticsService _instance = AnalyticsService._internal();
  factory AnalyticsService() => _instance;
  AnalyticsService._internal();

  bool get isEnabled => false;
  bool get isInitialized => true;

  Future<void> initialize() async {
    debugPrint('Analytics disabled: KumaFlow does not collect any data');
  }

  Future<void> setEnabled(bool enabled) async {}

  Future<void> recordEvent(String eventKey, [Map<String, dynamic>? segmentation]) async {}

  Future<void> recordScreenView(String screenName) async {}

  Future<void> recordRating(int rating, [String? feedback]) async {}

  Future<void> recordFeatureUsage(String featureName) async {}

  Future<void> recordPlaybackStarted(String source) async {}

  Future<void> recordDownload(String type, int count) async {}

  Future<void> markAppAsRated() async {}

  Future<bool> shouldShowRatingPrompt() async => false;

  Future<void> setConsent(String consent, bool enabled) async {}

  Future<void> recordError(String error, StackTrace? stackTrace) async {}

  Future<String?> getDeviceId() async => null;
}

class AnalyticsNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {}

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {}
}
