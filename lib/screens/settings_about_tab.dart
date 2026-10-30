import 'dart:ui';
import 'package:flutter/material.dart';
import '../widgets/app_gradient_background.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../services/theme_service.dart';
import '../services/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsAboutTab extends StatefulWidget {
  const SettingsAboutTab({super.key});

  @override
  State<SettingsAboutTab> createState() => _SettingsAboutTabState();
}

class _SettingsAboutTabState extends State<SettingsAboutTab> {
  bool _hasRated = false;
  String _version = '3.6.0';
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    String ver = '3.6.0';
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty) ver = info.version;
      if (info.buildNumber.isNotEmpty) ver = '${info.version}+${info.buildNumber}';
    } catch (_) {}
    setState(() {
      _hasRated = prefs.getBool('has_rated_app') ?? false;
      _version = ver;
    });
  }

  /// Ручная проверка обновления с GitHub Release: есть новее — диалог
  /// со скачиванием APK, нет — снэк «уже последняя».
  Future<void> _checkUpdateManually() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      final release = await UpdateService.checkForUpdate();
      if (!mounted) return;
      if (release == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Установлена последняя версия ($_version)'),
              duration: const Duration(seconds: 2)),
        );
        return;
      }
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Доступно обновление'),
          content: Text(
              '${UpdateService.currentVersion} → ${release.version}\n\n${UpdateService.stripMarkdown(release.body).characters.take(500)}'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Позже')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(
                    release.hasDirectApk ? 'Скачать APK' : 'Открыть релиз')),
          ],
        ),
      );
      if (ok == true) {
        final uri = Uri.parse(release.downloadUrl);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  bool _isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        _buildSection(
          context,
          title: AppLocalizations.of(context)!.sectionAboutInformation,
          children: [
            _buildInfoTile(
              context,
              icon: CupertinoIcons.info,
              iconColor: Theme.of(context).colorScheme.primary,
              title: AppLocalizations.of(context)!.aboutVersion,
              subtitle: _version,
            ),
            _buildDivider(context),
            _buildInfoTile(
              context,
              icon: CupertinoIcons.device_phone_portrait,
              iconColor: const Color(0xFF007AFF),
              title: AppLocalizations.of(context)!.aboutPlatform,
              subtitle: Theme.of(context).platform.name.toUpperCase(),
            ),
            _buildDivider(context),
            _buildActionTile(
              context,
              icon: CupertinoIcons.cloud_download,
              iconColor: const Color(0xFF34C759),
              title: 'Проверить обновления',
              subtitle: _checkingUpdate
                  ? 'Проверяю…'
                  : 'GitHub Release → APK',
              onTap: _checkingUpdate ? null : _checkUpdateManually,
            ),
          ],
        ),
        const SizedBox(height: 24),
        _buildSection(
          context,
          title: AppLocalizations.of(context)!.sectionAboutDeveloper,
          children: [_buildDeveloperInfo(context)],
        ),
        const SizedBox(height: 24),
        _buildSection(
          context,
          title: AppLocalizations.of(context)!.sectionAboutLinks,
          children: [
            _buildLinkTile(
              context,
              icon: Icons.code_rounded,
              title: AppLocalizations.of(context)!.aboutLinkGitHub,
              url: 'https://github.com/mrSaT13/kumaflow',
            ),
            _buildDivider(context),
            _buildLinkTile(
              context,
              icon: CupertinoIcons.doc_text,
              title: AppLocalizations.of(context)!.aboutLinkChangelog,
              url: 'https://github.com/mrSaT13/kumaflow/releases/latest',
            ),
            _buildDivider(context),
            _buildLinkTile(
              context,
              icon: CupertinoIcons.exclamationmark_bubble,
              title: AppLocalizations.of(context)!.aboutLinkReportIssue,
              url: 'https://github.com/mrSaT13/kumaflow/issues/new',
            ),
          ],
        ),
        const SizedBox(height: 24),
        _buildSection(
          context,
          title: AppLocalizations.of(context)!.tabSupport,
          children: [
            _buildSupportText(context),
            _buildDivider(context),
            _buildActionTile(
              context,
              icon: CupertinoIcons.star_fill,
              iconColor: const Color(0xFFFFCC00),
              title: _hasRated
                  ? AppLocalizations.of(context)!.thankYouFeedback
                  : AppLocalizations.of(context)!.rateKumaflow,
              subtitle: _hasRated
                  ? ''
                  : AppLocalizations.of(context)!.rateExperience,
              onTap: _hasRated ? null : () => _showRatingDialog(context),
            ),
            _buildDivider(context),
            _buildSupportItem(
              context,
              icon: CupertinoIcons.share,
              text: AppLocalizations.of(context)!.supportWayShare,
            ),
            _buildDivider(context),
            _buildSupportItem(
              context,
              icon: CupertinoIcons.exclamationmark_circle,
              text: AppLocalizations.of(context)!.supportWayBugs,
            ),
            _buildDivider(context),
            _buildSupportItem(
              context,
              icon: CupertinoIcons.heart_fill,
              text: AppLocalizations.of(context)!.supportWayEnjoy,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            AppLocalizations.of(context)!.supportMadeWithLove,
            style: TextStyle(
              fontSize: 14,
              color: _isDark(context)
                  ? AppTheme.darkSecondaryText
                  : AppTheme.lightSecondaryText,
            ),
          ),
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: _isDark(context)
                  ? AppTheme.darkSecondaryText
                  : AppTheme.lightSecondaryText,
              letterSpacing: 0.2,
            ),
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: _isDark(context) ? AppTheme.darkSurface : Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Column(children: children),
          ),
        ),
      ],
    );
  }

  Widget _buildDivider(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 56),
      child: Container(
        height: 0.5,
        color: _isDark(context) ? AppTheme.darkDivider : AppTheme.lightDivider,
      ),
    );
  }

  Widget _buildInfoTile(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: iconColor, size: 18),
      ),
      title: Text(title, style: const TextStyle(fontSize: 16)),
      trailing: Text(
        subtitle,
        style: TextStyle(
          fontSize: 16,
          color: _isDark(context)
              ? AppTheme.darkSecondaryText
              : AppTheme.lightSecondaryText,
        ),
      ),
    );
  }

  Widget _buildDeveloperInfo(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF5856D6), Color(0xFFAF52DE)],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.code_rounded, color: Colors.white, size: 18),
      ),
      title: Text(
        AppLocalizations.of(context)!.aboutMadeBy,
        style: const TextStyle(fontSize: 16),
      ),
      subtitle: Text(
        AppLocalizations.of(context)!.aboutGitHub,
        style: const TextStyle(fontSize: 13),
      ),
      trailing: const Icon(Icons.open_in_new_rounded, size: 18),
      onTap: () => _openUrl('https://github.com/mrSaT13/kumaflow'),
    );
  }

  Widget _buildLinkTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String url,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          color: Theme.of(context).colorScheme.primary,
          size: 18,
        ),
      ),
      title: Text(title, style: const TextStyle(fontSize: 16)),
      trailing: Icon(
        Icons.open_in_new_rounded,
        size: 18,
        color: _isDark(context)
            ? AppTheme.darkSecondaryText
            : AppTheme.lightSecondaryText,
      ),
      onTap: () => _openUrl(url),
    );
  }

  void _openUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('Error opening URL: $e');
    }
  }

  /// Текст поддержки: без ссылок на Discord и чужие кошельки —
  /// только «что это за проект» и «как помочь без денег».
  Widget _buildSupportText(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final textColor = _isDark(context) ? Colors.white : Colors.black87;
    final secondaryTextColor = _isDark(context)
        ? AppTheme.darkSecondaryText
        : AppTheme.lightSecondaryText;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.supportGreeting,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.supportParagraph1,
            style: TextStyle(fontSize: 14, height: 1.5, color: textColor),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.supportParagraph2,
            style: TextStyle(fontSize: 14, height: 1.5, color: textColor),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.supportParagraph4,
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              fontStyle: FontStyle.italic,
              color: secondaryTextColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSupportItem(
    BuildContext context, {
    required IconData icon,
    required String text,
  }) {
    final textColor = _isDark(context) ? Colors.white : Colors.black87;
    final secondaryTextColor = _isDark(context)
        ? AppTheme.darkSecondaryText
        : AppTheme.lightSecondaryText;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: secondaryTextColor),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 14, color: textColor)),
          ),
        ],
      ),
    );
  }

  void _showRatingDialog(BuildContext context) async {
    final ratingController = TextEditingController();
    int selectedRating = 5;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(AppLocalizations.of(context)!.rateKumaflow),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(AppLocalizations.of(context)!.rateExperience),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (index) {
                    final starIndex = index + 1;
                    return IconButton(
                      icon: Icon(
                        starIndex <= selectedRating
                            ? CupertinoIcons.star_fill
                            : CupertinoIcons.star,
                        color: const Color(0xFFFFCC00),
                      ),
                      onPressed: () {
                        setDialogState(() => selectedRating = starIndex);
                      },
                    );
                  }),
                ),
                const SizedBox(height: 16),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 100),
                  child: TextField(
                    controller: ratingController,
                    decoration: const InputDecoration(
                      hintText: 'Optional feedback...',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Submit'),
            ),
          ],
        ),
      ),
    );

    if (result == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_rated_app', true);
      if (mounted) {
        setState(() => _hasRated = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.thankYouFeedback)),
        );
      }
    }
    ratingController.dispose();
  }

  Widget _buildActionTile(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [iconColor, iconColor.withValues(alpha: 0.7)],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: Colors.white, size: 18),
      ),
      title: Text(title, style: const TextStyle(fontSize: 16)),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontSize: 12,
          color: _isDark(context)
              ? AppTheme.darkSecondaryText
              : AppTheme.lightSecondaryText,
        ),
      ),
      trailing: onTap != null
          ? Icon(
              CupertinoIcons.chevron_forward,
              size: 18,
              color: _isDark(context)
                  ? AppTheme.darkSecondaryText
                  : AppTheme.lightSecondaryText,
            )
          : null,
      onTap: onTap,
    );
  }
}
