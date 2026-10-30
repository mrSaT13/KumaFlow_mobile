import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:kumaflow/models/song.dart';
import 'package:kumaflow/providers/player_provider.dart';
import 'package:kumaflow/services/subsonic_service.dart';
import 'package:kumaflow/services/storage_service.dart';
import 'package:kumaflow/services/upnp_service.dart';
import 'package:kumaflow/services/audio_handler.dart';
import 'package:kumaflow/services/jukebox_service.dart';
import 'package:kumaflow/widgets/song_tile.dart';
import '../test_helpers.dart';
import '../bootstrap.dart';

void main() {
  initializeTestEnvironment();
  group('SongTile', () {
    late SubsonicService subsonicService;
    late PlayerProvider playerProvider;

    setUp(() {
      subsonicService = SubsonicService();
      subsonicService = SubsonicService();
      playerProvider = PlayerProvider(
        subsonicService,
        StorageService(),
        FakeCastService(),
        UpnpService(),
        KumaFlowAudioHandler(),
        JukeboxService(),
      );
    });

    tearDown(() {
      playerProvider.dispose();
    });

    testWidgets('should display song information', (tester) async {
      final song = Song(
        id: '1',
        title: 'Test Song',
        artist: 'Test Artist',
        album: 'Test Album',
        duration: 180,
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<SubsonicService>.value(value: subsonicService),
            ChangeNotifierProvider<PlayerProvider>.value(value: playerProvider),
          ],
          child: MaterialApp(
            home: Scaffold(body: SongTile(song: song, showArtist: true)),
          ),
        ),
      );

      expect(find.text('Test Song'), findsOneWidget);
      expect(find.text('Test Artist'), findsOneWidget);
    });

    testWidgets('should show duration when enabled', (tester) async {
      final song = Song(
        id: '1',
        title: 'Test Song',
        artist: 'Test Artist',
        duration: 180,
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<SubsonicService>.value(value: subsonicService),
            ChangeNotifierProvider<PlayerProvider>.value(value: playerProvider),
          ],
          child: MaterialApp(
            home: Scaffold(body: SongTile(song: song, showDuration: true)),
          ),
        ),
      );

      expect(find.text('3:00'), findsOneWidget);
    });

    testWidgets('should show album when enabled', (tester) async {
      final song = Song(
        id: '1',
        title: 'Test Song',
        artist: 'Test Artist',
        album: 'Test Album',
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<SubsonicService>.value(value: subsonicService),
            ChangeNotifierProvider<PlayerProvider>.value(value: playerProvider),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SongTile(song: song, showArtist: true, showAlbum: true),
            ),
          ),
        ),
      );

      expect(find.textContaining('Test Artist'), findsOneWidget);
      expect(find.textContaining('Test Album'), findsOneWidget);
    });
  });
}
