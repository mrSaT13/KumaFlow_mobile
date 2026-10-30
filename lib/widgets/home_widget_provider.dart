import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/subsonic_service.dart';
import '../services/audiobookshelf_service.dart';
import '../services/offline_service.dart';

/// Provider for home screen widgets.
///
/// Handles communication between the app and platform widgets.
/// Supports KION-style widget with like/dislike, play/pause, next/prev.
class HomeWidgetProvider {
  static const _channel = MethodChannel('com.kumaflow/widgets');

  static Function(String)? _onAction;

  /// Route widget button presses to the app. Wire this once (e.g. from the
  /// player provider) so like/dislike/play/pause/next/prev actually control
  /// playback.
  static void setActionHandler(Function(String) callback) {
    _onAction = callback;
    _channel.setMethodCallHandler((call) async {
      _onAction?.call(call.method);
      return true;
    });
  }

  static Future<void> init() async {
    try {
      _channel.setMethodCallHandler((call) async {
        _onAction?.call(call.method);
        return true;
      });
    } catch (e) {
      debugPrint('[HomeWidget] Failed to initialize: $e');
    }
  }

  /// Update widget with current track info.
  /// [isOffline] lights the OFFLINE badge on the compact v2 widget.
  static Future<void> updateNowPlaying({
    required String title,
    required String artist,
    String? albumArtUrl,
    required bool isPlaying,
    bool isLiked = false,
    int positionMs = 0,
    int durationMs = 0,
    int? accentColor,
    bool isOffline = false,
  }) async {
    try {
      final color = accentColor ?? 0xFF4E8CA8;
      await _channel.invokeMethod('updateNowPlaying', {
        'title': title,
        'artist': artist,
        'albumArtUrl': albumArtUrl,
        'isPlaying': isPlaying,
        'isLiked': isLiked,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'accentColor': color,
        'isOffline': isOffline,
      });
    } catch (e) {
      debugPrint('[HomeWidget] Error updating: $e');
    }
  }

  /// Update widget with recent tracks.
  static Future<void> updateRecentTracks(List<Song> tracks) async {
    try {
      final trackData = tracks.take(5).map((track) => {
        'id': track.id,
        'title': track.title,
        'artist': track.artist ?? 'Unknown',
        'coverArt': track.coverArt,
      }).toList();

      await _channel.invokeMethod('updateRecentTracks', {
        'tracks': trackData,
      });
    } catch (e) {
      debugPrint('[HomeWidget] Error updating recent tracks: $e');
    }
  }

  /// Show widget.
  static Future<void> showWidget() async {
    try {
      await _channel.invokeMethod('showWidget');
    } catch (e) {
      debugPrint('[HomeWidget] Error showing widget: $e');
    }
  }
}

/// Widget that displays now playing info on home screen.
class NowPlayingWidget extends StatelessWidget {
  const NowPlayingWidget({super.key});

  /// Троттлинг пушей в виджеты: build вызывается на каждый тик позиции,
  /// было 20+ updateAppWidget в секунду (IPC + prefs + RemoteViews,
  /// лог-спам, батарея). Шлём при смене состояния мгновенно,
  /// прогресс — с точностью до секунды, не чаще 1/с.
  static String _lastPushKey = '';
  static int _lastPushAt = 0;

  @override
  Widget build(BuildContext context) {
    final playerProvider = Provider.of<PlayerProvider>(context);
    final currentSong = playerProvider.currentSong;
    final isPlaying = playerProvider.isPlaying;
    final subsonicService = Provider.of<SubsonicService>(context, listen: false);

    // Update platform widget when state changes
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (currentSong != null) {
        final posSec = playerProvider.position.inSeconds;
        final key =
            '${currentSong.id}|$isPlaying|${currentSong.starred == true}|$posSec';
        final now = DateTime.now().millisecondsSinceEpoch;
        if (key == _lastPushKey && now - _lastPushAt < 1000) return;
        _lastPushKey = key;
        _lastPushAt = now;
        String? coverUrl;
        if (currentSong.coverArt != null) {
          if (currentSong.coverArt!.startsWith('abs:')) {
            final id = currentSong.coverArt!.substring(4);
            coverUrl = AudiobookshelfService().getCoverUrl(id, width: 400);
          } else {
            coverUrl = subsonicService.getCoverArtUrl(currentSong.coverArt!, size: 200);
          }
        }

        HomeWidgetProvider.updateNowPlaying(
          title: currentSong.title,
          artist: currentSong.artist ?? 'Unknown Artist',
          albumArtUrl: coverUrl,
          isPlaying: isPlaying,
          isLiked: currentSong.starred == true,
          positionMs: playerProvider.position.inMilliseconds,
          durationMs: playerProvider.duration.inMilliseconds,
          isOffline: OfflineService().isOfflineMode,
        );
      }
    });

    return const SizedBox.shrink(); // This is a background provider, not a visible widget
  }
}
