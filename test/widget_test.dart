import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:kumaflow/main.dart';
import 'package:kumaflow/providers/auth_provider.dart';
import 'package:kumaflow/services/locale_service.dart';
import 'package:kumaflow/services/theme_service.dart';
import 'package:kumaflow/services/subsonic_service.dart';
import 'package:kumaflow/services/storage_service.dart';

void main() {
  testWidgets('App should build', (WidgetTester tester) async {
    final subsonic = SubsonicService();
    final storage = StorageService();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LocaleService>(create: (_) => LocaleService()),
          ChangeNotifierProvider<ThemeService>(create: (_) => ThemeService()),
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => AuthProvider(subsonic, storage),
          ),
        ],
        child: const KumaFlowApp(),
      ),
    );
    expect(find.byType(KumaFlowApp), findsOneWidget);
  });
}
