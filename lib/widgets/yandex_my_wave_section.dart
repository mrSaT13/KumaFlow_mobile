import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/player_provider.dart';
import '../providers/yandex_music_provider.dart';
import '../services/subsonic_service.dart';
import '../services/yandex_integration_service.dart';
import '../services/yandex_music_service.dart';
import '../theme/app_theme.dart';

/// Section for Yandex Music "My Wave" on the home screen.
class YandexMyWaveSection extends StatefulWidget {
  final double hPad;
  final bool isDesktop;

  const YandexMyWaveSection({
    super.key,
    this.hPad = 16.0,
    this.isDesktop = false,
  });

  @override
  State<YandexMyWaveSection> createState() => _YandexMyWaveSectionState();
}

class _YandexMyWaveSectionState extends State<YandexMyWaveSection> {
  List<Song> _tracks = [];
  bool _isLoading = false;
  bool _hasError = false;
  bool _hasLoaded = false;

  @override
  void initState() {
    super.initState();
    // Don't auto-load - wait for user tap
  }

  @override
  Widget build(BuildContext context) {
    final yandexProvider = Provider.of<YandexMusicProvider>(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Don't show if Yandex Music is disabled or no token
    if (!yandexProvider.isEnabled || !yandexProvider.hasToken) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.hPad),
      child: GestureDetector(
        onTap: _loadAndPlayWave,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: widget.isDesktop ? 100 : 80,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppTheme.appleMusicRed.withValues(alpha: 0.15),
                const Color(0xFF16293D).withValues(alpha: 0.15),
              ],
            ),
            border: Border.all(
              color: AppTheme.appleMusicRed.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                // Icon with animated gradient
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppTheme.appleMusicRed, Color(0xFF16293D)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.appleMusicRed.withValues(alpha: 0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(
                          Icons.waves_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                ),
                const SizedBox(width: 16),
                // Text
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Яндекс Музыка Волна',
                        style: TextStyle(
                          fontSize: widget.isDesktop ? 18 : 16,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _isLoading
                            ? 'Генерация персонального микса...'
                            : _hasError
                                ? 'Нажмите для повтора'
                                : 'Персональный микс из Яндекс Музыки',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white54 : Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
                // Refresh (когда волна уже загружалась) или стрелка
                if (_isLoading)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTheme.appleMusicRed,
                    ),
                  )
                else if (_hasLoaded)
                  IconButton(
                    icon: Icon(
                      Icons.refresh_rounded,
                      size: 20,
                      color: isDark ? Colors.white54 : Colors.black45,
                    ),
                    tooltip: 'Обновить волну',
                    onPressed: () => _loadAndPlayWave(force: true),
                  )
                else
                  Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: isDark ? Colors.white24 : Colors.black26,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// [force]=true — кнопка «обновить»: сбрасываем кеш секции и генерим заново.
  /// Раньше повторный тап просто переигрывал те же [_tracks].
  Future<void> _loadAndPlayWave({bool force = false}) async {
    if (_isLoading) return;

    HapticFeedback.mediumImpact();

    final yandexProvider = Provider.of<YandexMusicProvider>(context, listen: false);
    if (!yandexProvider.isEnabled || !yandexProvider.hasToken) return;

    setState(() {
      _isLoading = true;
      _hasError = false;
      if (force) {
        _tracks = [];
        _hasLoaded = false;
      }
    });

    try {
      final subsonicService = Provider.of<SubsonicService>(context, listen: false);
      final integrationService = YandexIntegrationService(
        yandexService: YandexMusicService(oauthToken: yandexProvider.oauthToken),
        subsonicService: subsonicService,
      );

      final tracks = await integrationService.getMyWaveTracks(limit: 50);

      if (mounted) {
        setState(() {
          _tracks = tracks;
          _isLoading = false;
          _hasLoaded = true;
        });

        if (tracks.isNotEmpty) {
          context.read<PlayerProvider>().playSong(
            tracks.first,
            playlist: tracks,
            startIndex: 0,
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No tracks found on server for My Wave'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading My Wave: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }
}
