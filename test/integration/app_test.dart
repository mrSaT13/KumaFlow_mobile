import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:kumaflow/main.dart';
import 'package:kumaflow/providers/auth_provider.dart';
import 'package:kumaflow/services/services.dart';
import 'package:kumaflow/services/locale_service.dart';
import 'package:kumaflow/services/theme_service.dart';
import '../bootstrap.dart';

void main() {
  initializeTestEnvironment();
  group('KumaFlow App Integration Tests', () {
    testWidgets('should display login screen when not authenticated', (
      tester,
    ) async {
      final storageService = StorageService();
      final subsonicService = SubsonicService();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<StorageService>.value(value: storageService),
            Provider<SubsonicService>.value(value: subsonicService),
            ChangeNotifierProvider<LocaleService>(
                create: (_) => LocaleService()),
            ChangeNotifierProvider<ThemeService>(create: (_) => ThemeService()),
            ChangeNotifierProvider(
              create: (_) => AuthProvider(subsonicService, storageService),
            ),
          ],
          child: const MaterialApp(home: KumaFlowApp()),
        ),
      );

      await tester.pump();

      expect(find.text('KumaFlow'), findsWidgets);
      expect(find.text('Connect to your Subsonic server'), findsOneWidget);
    });

    testWidgets('should have login form fields', (tester) async {
      final storageService = StorageService();
      final subsonicService = SubsonicService();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<StorageService>.value(value: storageService),
            Provider<SubsonicService>.value(value: subsonicService),
            ChangeNotifierProvider<LocaleService>(
                create: (_) => LocaleService()),
            ChangeNotifierProvider<ThemeService>(create: (_) => ThemeService()),
            ChangeNotifierProvider(
              create: (_) => AuthProvider(subsonicService, storageService),
            ),
          ],
          child: const MaterialApp(home: KumaFlowApp()),
        ),
      );

      await tester.pump();

      expect(find.text('Server URL'), findsOneWidget);
      expect(find.text('Username'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);
    });

    testWidgets('should validate empty form fields', (tester) async {
      final storageService = StorageService();
      final subsonicService = SubsonicService();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<StorageService>.value(value: storageService),
            Provider<SubsonicService>.value(value: subsonicService),
            ChangeNotifierProvider<LocaleService>(
                create: (_) => LocaleService()),
            ChangeNotifierProvider<ThemeService>(create: (_) => ThemeService()),
            ChangeNotifierProvider(
              create: (_) => AuthProvider(subsonicService, storageService),
            ),
          ],
          child: const MaterialApp(home: KumaFlowApp()),
        ),
      );

      await tester.pump();

      final connectButton = find.text('Connect');
      await tester.ensureVisible(connectButton);
      await tester.tap(connectButton);
      await tester.pump();

      expect(find.text('Please enter server URL'), findsOneWidget);
      expect(find.text('Please enter username'), findsOneWidget);
      expect(find.text('Please enter password'), findsOneWidget);
    });
  });
}
