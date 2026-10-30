import 'dart:io';

/// Analytics configuration - loaded from environment variables during build
/// 
/// This file uses compile-time environment variables to inject the Countly
/// app key securely. The actual values are never stored in the repository.
///
/// Setup instructions:
/// 1. Create a `.env` file locally (add to .gitignore!)
/// 2. Set environment variables in CI/CD (GitHub Actions secrets)
/// 3. Use --dart-define during build
///
/// Example build command:
/// flutter build apk --dart-define=COUNTLY_APP_KEY=your_key --dart-define=COUNTLY_SERVER_URL=your_url
class AnalyticsConfig {
  /// Countly server URL
  /// 
  /// Set via: --dart-define=COUNTLY_SERVER_URL=https://your-countly.com
  /// Fallback for development (should be empty in production)
  static const String serverUrl = String.fromEnvironment(
    'COUNTLY_SERVER_URL',
    defaultValue: '',
  );

  /// Countly app key
  /// 
  /// Set via: --dart-define=COUNTLY_APP_KEY=your_app_key_here
  /// Fallback for development (should be empty in production)
  static const String appKey = String.fromEnvironment(
    'COUNTLY_APP_KEY',
    defaultValue: '',
  );

  /// Check if analytics is properly configured
  static bool get isConfigured => serverUrl.isNotEmpty && appKey.isNotEmpty;

  /// Get a masked version of the app key for logging
  static String get maskedAppKey {
    if (appKey.length < 8) return '***';
    return '${appKey.substring(0, 4)}...${appKey.substring(appKey.length - 4)}';
  }
}

/// Development configuration (for local testing only)
/// 
/// NEVER commit this with real values!
/// Add to .gitignore:
/// - lib/config/analytics_config_dev.dart
/// - .env
class AnalyticsConfigDev {
  /// Use this only for local development
  /// Load from .env file or local environment variables
  static String? get serverUrl => Platform.environment['COUNTLY_SERVER_URL'];
  static String? get appKey => Platform.environment['COUNTLY_APP_KEY'];
}
