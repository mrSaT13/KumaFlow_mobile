import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/yandex_music_provider.dart';
import '../theme/app_theme.dart';

/// Яндекс Музыка (публичное API: похожие артисты, обложки, динамические цвета).
/// Живёт во вкладке «Интеграции»; раньше дублем лежала в Playback.
class YandexMusicSection extends StatefulWidget {
  const YandexMusicSection({super.key});

  @override
  State<YandexMusicSection> createState() => _YandexMusicSectionState();
}

class _YandexMusicSectionState extends State<YandexMusicSection> {
  TextEditingController? _tokenCtrl;
  String? _lastToken;

  @override
  void dispose() {
    _tokenCtrl?.dispose();
    super.dispose();
  }

  bool _isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.explore_rounded,
                  color: Color(0xFFFFCC00), size: 22),
              SizedBox(width: 10),
              Text('Yandex Music',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 4),
          _toggle(context),
          const Divider(height: 16),
          _tokenInput(context),
          const Divider(height: 16),
          _info(context),
        ],
      ),
    );
  }

  Widget _toggle(BuildContext context) {
    final yandexProvider = Provider.of<YandexMusicProvider>(context);
    final isDark = _isDark(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFFFFCC00).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.explore_rounded,
              color: Color(0xFFFFCC00),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Yandex Music Integration',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: isDark ? Colors.white : Colors.black,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Similar artists, albums, and cover art',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white54 : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: yandexProvider.isEnabled,
            onChanged: (value) => yandexProvider.setEnabled(value),
            activeColor: AppTheme.appleMusicRed,
          ),
        ],
      ),
    );
  }

  Widget _tokenInput(BuildContext context) {
    final yandexProvider = Provider.of<YandexMusicProvider>(context);
    final isDark = _isDark(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.vpn_key_rounded,
                size: 20,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'OAuth Token',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: isDark ? Colors.white : Colors.black,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      yandexProvider.hasToken
                          ? 'Token configured'
                          : 'No token set',
                      style: TextStyle(
                        fontSize: 12,
                        color: yandexProvider.hasToken
                            ? Colors.green
                            : (isDark ? Colors.white54 : Colors.black54),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Builder(
            builder: (context) {
              final token = yandexProvider.oauthToken ?? '';
              if (_tokenCtrl == null || _lastToken != token) {
                _tokenCtrl?.dispose();
                _tokenCtrl = TextEditingController(text: token);
                _lastToken = token;
              }
              return TextField(
            controller: _tokenCtrl,
            obscureText: true,
            decoration: InputDecoration(
              hintText: 'y0__x...',
              hintStyle: TextStyle(
                color: isDark ? Colors.white38 : Colors.black38,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
            onChanged: (value) {
              _lastToken = value;
              yandexProvider.setOAuthToken(value);
            },
              );
            },
          ),
          const SizedBox(height: 4),
          Text(
            'Get token from Yandex Music app or browser DevTools',
            style: TextStyle(
              fontSize: 11,
              color: isDark ? Colors.white38 : Colors.black38,
            ),
          ),
        ],
      ),
    );
  }

  Widget _info(BuildContext context) {
    final isDark = _isDark(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 20,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Features',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: isDark ? Colors.white : Colors.black,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _featureItem(context, 'Similar artists from Yandex Music'),
          _featureItem(context, 'Related albums matching'),
          _featureItem(context, 'High-quality cover art'),
          _featureItem(context, 'Dynamic color theming'),
          _featureItem(context, 'Enhanced recommendations'),
        ],
      ),
    );
  }

  Widget _featureItem(BuildContext context, String text) {
    final isDark = _isDark(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 16,
            color: Colors.cyan.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
