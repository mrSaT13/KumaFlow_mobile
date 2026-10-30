import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../services/theme_service.dart';
import '../l10n/app_localizations.dart';
import 'settings_playback_tab.dart';
import 'settings_storage_tab.dart';
import 'settings_server_tab.dart';
import 'settings_display_tab.dart';
import 'settings_about_tab.dart';
import 'settings_ml_tab.dart';
import 'settings_integrations_tab.dart';
import '../theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  final int initialTab;
  const SettingsScreen({super.key, this.initialTab = 0});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this, initialIndex: widget.initialTab.clamp(0, 6));
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final intensity = context.select<ThemeService, double>((t) => t.gradientIntensity);
    final l10n = AppLocalizations.of(context)!;
    final accentColor =
        context.select<ThemeService, Color>((t) => t.accentColor.color);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(l10n.settingsTitle),
        centerTitle: false,
        backgroundColor: _isDark
            ? const Color(0xFF121212).withValues(alpha: 0.72)
            : Colors.white.withValues(alpha: 0.82),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    accentColor.withValues(alpha: (_isDark ? 0.40 : 0.20) * intensity),
                    accentColor.withValues(alpha: (_isDark ? 0.16 : 0.08) * intensity),
                    (_isDark ? Colors.black : Colors.white)
                        .withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
                border: Border(
                  bottom: BorderSide(
                    color: _isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.07),
                    width: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          indicatorColor: Theme.of(context).colorScheme.primary,
          labelColor: Theme.of(context).colorScheme.primary,
          unselectedLabelColor: _isDark
              ? AppTheme.darkSecondaryText
              : AppTheme.lightSecondaryText,
          labelStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          unselectedLabelStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w400,
          ),
          tabs: [
            Tab(
              icon: const Icon(CupertinoIcons.play_circle, size: 20),
              text: l10n.tabPlayback,
            ),
            Tab(
              icon: const Icon(CupertinoIcons.folder, size: 20),
              text: l10n.tabStorage,
            ),
            Tab(
              icon: const Icon(CupertinoIcons.cloud, size: 20),
              text: l10n.tabServer,
            ),
            Tab(
              icon: const Icon(CupertinoIcons.paintbrush, size: 20),
              text: l10n.tabDisplay,
            ),
            Tab(
              icon: const Icon(CupertinoIcons.info, size: 20),
              text: l10n.tabAbout,
            ),
            const Tab(
              icon: Icon(CupertinoIcons.sparkles, size: 20),
              text: 'ML',
            ),
            const Tab(
              icon: Icon(CupertinoIcons.link, size: 20),
              text: 'Интеграции',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          SettingsPlaybackTab(),
          SettingsStorageTab(),
          SettingsServerTab(),
          SettingsDisplayTab(),
          SettingsAboutTab(),
          SettingsMlTab(),
          SettingsIntegrationsTab(),
        ],
      ),
    );
  }
}
