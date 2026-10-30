import 'dart:ui';
import 'package:flutter/material.dart';
import '../widgets/app_gradient_background.dart';
import 'package:flutter/services.dart';
import '../services/unified_music_auth.dart' show UnifiedMusicAuth, AuthStatus, MusicAuthProvider;
import '../theme/app_theme.dart';
import '../services/theme_service.dart';

/// Settings tab for Music Service authorization.
/// Shows connection status for Yandex Music and MTS Music.
class SettingsMusicAuthTab extends StatefulWidget {
  /// embedded=true — карточка внутри вкладки «Интеграции» (без собственного
  /// скролла, скроллит родитель).
  final bool embedded;
  const SettingsMusicAuthTab({super.key, this.embedded = false});

  @override
  State<SettingsMusicAuthTab> createState() => _SettingsMusicAuthTabState();
}

class _SettingsMusicAuthTabState extends State<SettingsMusicAuthTab> {
  final UnifiedMusicAuth _auth = UnifiedMusicAuth();

  AuthStatus _yandexStatus = const AuthStatus();
  AuthStatus _mtsStatus = const AuthStatus();
  Map<String, bool> _features = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    setState(() => _isLoading = true);

    final yandexStatus = await _auth.getYandexStatus();
    final mtsStatus = await _auth.getMtsStatus();
    final features = await _auth.getAvailableFeatures();

    if (mounted) {
      setState(() {
        _yandexStatus = yandexStatus;
        _mtsStatus = mtsStatus;
        _features = features;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding:
          widget.embedded ? EdgeInsets.zero : const EdgeInsets.all(16),
      shrinkWrap: widget.embedded,
      physics: widget.embedded
          ? const NeverScrollableScrollPhysics()
          : null,
      children: [
        // Yandex Music Section
        _buildSectionHeader('Яндекс Музыка'),
        _buildProviderCard(
          name: 'Яндекс Музыка',
          icon: Icons.music_note,
          isConnected: _yandexStatus.isConnected,
          isPremium: _yandexStatus.isPremium,
          username: _yandexStatus.username,
          onConnect: _connectYandex,
          onDisconnect: _disconnectYandex,
          onManualToken: _showYandexTokenDialog,
        ),
        const SizedBox(height: 24),

        // MTS Music Section
        _buildSectionHeader('МТС Музыка (KION)'),
        _buildProviderCard(
          name: 'МТС Музыка',
          icon: Icons.phone_android,
          isConnected: _mtsStatus.isConnected,
          isPremium: _mtsStatus.isPremium,
          username: _mtsStatus.username,
          onConnect: _connectMts,
          onDisconnect: _disconnectMts,
          onManualToken: _showMtsTokenDialog,
        ),
        const SizedBox(height: 24),

        // Available Features
        _buildSectionHeader('Доступные функции'),
        _buildFeaturesList(),
        const SizedBox(height: 24),

        // Active Provider
        _buildSectionHeader('Активный сервис'),
        _buildActiveProviderSelector(),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          color: AppTheme.appleMusicRed,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildProviderCard({
    required String name,
    required IconData icon,
    required bool isConnected,
    required bool isPremium,
    String? username,
    required VoidCallback onConnect,
    required VoidCallback onDisconnect,
    required VoidCallback onManualToken,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: isConnected
                      ? const Color(0xFF1DB954).withValues(alpha: 0.2)
                      : AppTheme.darkElevated,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  color: isConnected ? const Color(0xFF1DB954) : AppTheme.darkSecondaryText,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isConnected
                                ? (isPremium ? const Color(0xFFFFD700).withValues(alpha: 0.2) : const Color(0xFF1DB954).withValues(alpha: 0.2))
                                : AppTheme.darkElevated,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            isConnected
                                ? (isPremium ? 'PREMIUM' : 'ПОДКЛЮЧЁН')
                                : 'ОТКЛЮЧЁН',
                            style: TextStyle(
                              color: isConnected
                                  ? (isPremium ? const Color(0xFFFFD700) : const Color(0xFF1DB954))
                                  : AppTheme.darkSecondaryText,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (username != null && username.isNotEmpty)
                      Text(
                        username,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (isConnected)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onDisconnect,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Отключить',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: onConnect,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.appleMusicRed,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text('Подключить'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: onManualToken,
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Text(
                      'Ввести токен',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildFeaturesList() {
    final features = [
      ('Поиск артистов/альбомов', 'search', true),
      ('Информация об артистах', 'artist_info', true),
      ('Похожие треки', 'similar_tracks', true),
      ('Обложки альбомов', 'cover_art', true),
      ('Тексты песен', 'lyrics', true),
      ('Новинки', 'new_releases', true),
      ('Жанры', 'genres', true),
      ('Плейлисты', 'playlists', false),
      ('Лайки/Избранное', 'likes', false),
      ('Плейлист дня', 'playlist_of_day', false),
      ('Моя волна', 'my_wave', false),
      ('История прослушиваний', 'listening_history', false),
      ('Высокое качество', 'high_quality', false),
      ('Без ограничений пропусков', 'unlimited_skips', false),
      ('Оффлайн режим', 'offline_mode', false),
      ('Без рекламы', 'no_ads', false),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: features.map((feature) {
          final (name, key, alwaysAvailable) = feature;
          final isAvailable = _features[key] ?? alwaysAvailable;

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(
                  isAvailable ? Icons.check_circle : Icons.cancel,
                  color: isAvailable ? const Color(0xFF1DB954) : Colors.red,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name,
                    style: TextStyle(
                      color: isAvailable ? Colors.white : Colors.white.withValues(alpha: 0.5),
                      fontSize: 14,
                    ),
                  ),
                ),
                if (!alwaysAvailable && !isAvailable)
                  Text(
                    'Требуется авторизация',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.3),
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildActiveProviderSelector() {
    return FutureBuilder<MusicAuthProvider>(
      future: _auth.getActiveProvider(),
      builder: (context, snapshot) {
        final activeProvider = snapshot.data ?? MusicAuthProvider.none;

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.darkCard,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              _buildRadioOption(
                title: 'Яндекс Музыка',
                value: MusicAuthProvider.yandex,
                isEnabled: _yandexStatus.isConnected,
                groupValue: activeProvider,
                onChanged: (value) => _setActiveProvider(value!),
              ),
              _buildRadioOption(
                title: 'МТС Музыка',
                value: MusicAuthProvider.mts,
                isEnabled: _mtsStatus.isConnected,
                groupValue: activeProvider,
                onChanged: (value) => _setActiveProvider(value!),
              ),
              _buildRadioOption(
                title: 'Автоматически (лучший доступный)',
                value: MusicAuthProvider.none,
                isEnabled: true,
                groupValue: activeProvider,
                onChanged: (value) => _setActiveProvider(value!),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRadioOption({
    required String title,
    required MusicAuthProvider value,
    required bool isEnabled,
    required MusicAuthProvider groupValue,
    required ValueChanged<MusicAuthProvider?> onChanged,
  }) {
    return RadioListTile<MusicAuthProvider>(
      title: Text(
        title,
        style: TextStyle(
          color: isEnabled ? Colors.white : Colors.white.withValues(alpha: 0.3),
          fontSize: 14,
        ),
      ),
      value: value,
      groupValue: groupValue,
      onChanged: isEnabled ? onChanged : null,
      activeColor: AppTheme.appleMusicRed,
      contentPadding: EdgeInsets.zero,
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Actions
  // ──────────────────────────────────────────────────────────────────────────

  void _connectYandex() {
    // Open Yandex OAuth in browser
    final url = _auth.getYandexOAuthUrl(
      redirectUri: 'https://kumaflow.app/auth/yandex/callback',
    );
    // In real app, open in browser and handle callback
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Откройте Яндекс OAuth в браузере и вставьте токен'),
      ),
    );
  }

  void _connectMts() {
    final url = _auth.getMtsAuthUrl(
      redirectUri: 'https://kumaflow.app/auth/mts/callback',
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Откройте МТС авторизацию в браузере и вставьте токен'),
      ),
    );
  }

  void _disconnectYandex() async {
    await _auth.logoutYandex();
    _loadStatus();
  }

  void _disconnectMts() async {
    await _auth.logoutMts();
    _loadStatus();
  }

  void _setActiveProvider(MusicAuthProvider provider) async {
    await _auth.setActiveProvider(provider);
    _loadStatus();
  }

  void _showYandexTokenDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.darkCard,
        title: const Text(
          'Яндекс OAuth Токен',
          style: TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Вставьте OAuth токен из Яндекс Музыки',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'OAuth токен',
                hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                filled: true,
                fillColor: AppTheme.darkElevated,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () async {
              final token = controller.text.trim();
              if (token.isNotEmpty) {
                await _auth.saveYandexTokenDirect(token);
                if (mounted) {
                  Navigator.pop(ctx);
                  _loadStatus();
                }
              }
            },
            child: const Text(
              'Сохранить',
              style: TextStyle(color: AppTheme.appleMusicRed),
            ),
          ),
        ],
      ),
    ).whenComplete(() => controller.dispose());
  }

  void _showMtsTokenDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.darkCard,
        title: const Text(
          'МТС ID Токен',
          style: TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Вставьте токен из МТС Музыки (KION)',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'MTS ID токен',
                hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                filled: true,
                fillColor: AppTheme.darkElevated,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () async {
              final token = controller.text.trim();
              if (token.isNotEmpty) {
                await _auth.saveMtsTokenDirect(token);
                if (mounted) {
                  Navigator.pop(ctx);
                  _loadStatus();
                }
              }
            },
            child: const Text(
              'Сохранить',
              style: TextStyle(color: AppTheme.appleMusicRed),
            ),
          ),
        ],
      ),
    ).whenComplete(() => controller.dispose());
  }
}
