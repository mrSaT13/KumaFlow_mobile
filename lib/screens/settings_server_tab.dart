import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../widgets/app_gradient_background.dart';
import '../l10n/app_localizations.dart';
import '../models/music_folder.dart';
import '../models/server_config.dart';
import '../providers/auth_provider.dart';
import '../providers/player_provider.dart';
import '../services/jukebox_service.dart';
import '../services/subsonic_service.dart';
import '../services/theme_service.dart';
import '../services/audiobookshelf_service.dart';
import '../widgets/collab_friends_section.dart';
import '../theme/app_theme.dart';
import '../utils/navigation_helper.dart';
import 'jukebox_screen.dart';
import 'audiobookshelf_screen.dart';

class SettingsServerTab extends StatefulWidget {
  const SettingsServerTab({super.key});

  @override
  State<SettingsServerTab> createState() => _SettingsServerTabState();
}

class _SettingsServerTabState extends State<SettingsServerTab> {
  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final authProvider = Provider.of<AuthProvider>(context);
    final serverType = authProvider.config?.serverType;
    final serverVersion = authProvider.config?.serverVersion;

    String serverSubtitle = 'Subsonic API';
    if (serverType != null && serverType.isNotEmpty) {
      serverSubtitle = serverType;
      if (serverVersion != null && serverVersion.isNotEmpty) {
        serverSubtitle += ' $serverVersion';
      }
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        _buildSection(
          title: l10n.sectionServerConnection,
          children: [
            _buildInfoTile(
              icon: CupertinoIcons.cloud,
              iconColor: Theme.of(context).colorScheme.primary,
              title: l10n.serverType,
              subtitle: serverSubtitle,
            ),
            _buildDivider(),
            _buildInfoTile(
              icon: CupertinoIcons.link,
              iconColor: const Color(0xFF007AFF),
              title: l10n.serverUrl,
              subtitle: authProvider.config?.effectiveUrl ??
                  authProvider.config?.serverUrl ??
                  l10n.notConnected,
            ),
            _buildDivider(),
            _buildInfoTile(
              icon: CupertinoIcons.person,
              iconColor: const Color(0xFF34C759),
              title: l10n.username,
              subtitle: authProvider.config?.username ?? l10n.unknown,
            ),
            _buildDivider(),
            _buildServerUrlsTile(),
          ],
        ),
        const SizedBox(height: 24),
        _buildSavedProfilesSection(),
        const SizedBox(height: 24),
        _buildSection(
          title: l10n.sectionMusicFolders,
          children: [_buildMusicFoldersButton()],
        ),
        const SizedBox(height: 24),
        _buildSection(
          title: l10n.sectionJukebox,
          children: [_buildJukeboxSection()],
        ),
        const SizedBox(height: 24),
        _buildSection(
          title: 'Audiobookshelf',
          children: [_buildAudiobookshelfSection()],
        ),
        const SizedBox(height: 24),
        _buildSection(
          title: 'Друзья / Collab',
          children: [CollabFriendsSection(isDark: _isDark)],
        ),
        const SizedBox(height: 24),
        _buildSection(
          title: l10n.sectionAccount,
          children: [_buildLogoutButton()],
        ),
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _buildSection({
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
              color: _isDark
                  ? AppTheme.darkSecondaryText
                  : AppTheme.lightSecondaryText,
              letterSpacing: 0.2,
            ),
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: _isDark ? AppTheme.darkSurface : Colors.white,
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

  Widget _buildDivider() {
    return Padding(
      padding: const EdgeInsets.only(left: 56),
      child: Container(
        height: 0.5,
        color: _isDark ? AppTheme.darkDivider : AppTheme.lightDivider,
      ),
    );
  }

  Widget _buildInfoTile({
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
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontSize: 13,
          color: _isDark
              ? AppTheme.darkSecondaryText
              : AppTheme.lightSecondaryText,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// Адреса сервера: основной + запасные (аналог переключения домена).
  /// Активный отмечен галочкой, при открытии адреса пингуются автоматически.
  Widget _buildServerUrlsTile() {
    final auth = Provider.of<AuthProvider>(context);
    final config = auth.config;
    final backups = config?.backupUrls ?? const <String>[];
    final active = (config?.activeUrl ?? '').trim();
    final primary = config?.serverUrl ?? '';
    final String subtitle;
    if (backups.isEmpty) {
      subtitle = 'Только основной адрес';
    } else if (active.isNotEmpty) {
      subtitle = 'Активен запасной\nЗапасных: ${backups.length}';
    } else {
      subtitle = 'Активен основной: $primary\nЗапасных: ${backups.length}';
    }
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: const Color(0xFF4E8CA8).withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(CupertinoIcons.arrow_swap,
            color: Color(0xFF4E8CA8), size: 18),
      ),
      title: const Text('Адреса сервера', style: TextStyle(fontSize: 16)),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontSize: 13,
          color: _isDark
              ? AppTheme.darkSecondaryText
              : AppTheme.lightSecondaryText,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
      onTap: _openServerUrlsDialog,
    );
  }

  Future<void> _openServerUrlsDialog() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    await showDialog<void>(
      context: context,
      builder: (ctx) => _ServerUrlsDialog(
        auth: auth,
        isDark: _isDark,
      ),
    );
    if (mounted) setState(() {});
  }
  Widget _buildMusicFoldersButton() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF5856D6), Color(0xFF7B68EE)],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(CupertinoIcons.folder, color: Colors.white, size: 18),
      ),
      title: Text(
        AppLocalizations.of(context)!.musicFolders,
        style: const TextStyle(fontSize: 16),
      ),
      trailing: Icon(
        CupertinoIcons.chevron_right,
        size: 16,
        color: _isDark
            ? AppTheme.darkSecondaryText
            : AppTheme.lightSecondaryText,
      ),
      onTap: _showMusicFoldersDialog,
    );
  }

  void _showMusicFoldersDialog() async {
    final subsonicService = Provider.of<SubsonicService>(
      context,
      listen: false,
    );
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final folders = await subsonicService.getMusicFolders();

    if (!mounted) return;

    final currentSelection = Set<String>.from(
      authProvider.config?.selectedMusicFolderIds ?? [],
    );

    await showDialog(
      context: context,
      builder: (context) => _MusicFoldersDialog(
        folders: folders,
        initialSelection: currentSelection,
        onSave: (selected) async {
          await authProvider.updateSelectedMusicFolderIds(selected.toList());
        },
      ),
    );
  }

  Widget _buildJukeboxSection() {
    final l10n = AppLocalizations.of(context)!;
    return Consumer<JukeboxService>(
      builder: (context, jukebox, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            secondary: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF9500), Color(0xFFFF6000)],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                CupertinoIcons.speaker_2,
                color: Colors.white,
                size: 18,
              ),
            ),
            title: Text(l10n.jukeboxMode, style: const TextStyle(fontSize: 16)),
            subtitle: Text(
              l10n.jukeboxModeSubtitle,
              style: TextStyle(
                fontSize: 13,
                color: _isDark
                    ? AppTheme.darkSecondaryText
                    : AppTheme.lightSecondaryText,
              ),
            ),
            value: jukebox.enabled,
            activeThumbColor: Theme.of(context).colorScheme.primary,
            onChanged: (v) => jukebox.setEnabled(v),
          ),
          if (jukebox.enabled) ...[
            Padding(
              padding: const EdgeInsets.only(left: 56),
              child: Container(
                height: 0.5,
                color: _isDark ? AppTheme.darkDivider : AppTheme.lightDivider,
              ),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              leading: const SizedBox(width: 32),
              title: Text(
                l10n.openJukeboxController,
                style: const TextStyle(fontSize: 16),
              ),
              trailing: Icon(
                CupertinoIcons.chevron_right,
                size: 16,
                color: _isDark
                    ? AppTheme.darkSecondaryText
                    : AppTheme.lightSecondaryText,
              ),
              onTap: () =>
                  NavigationHelper.push(context, const JukeboxScreen()),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAudiobookshelfSection() {
    final abs = AudiobookshelfService();
    return _AudiobookshelfSettingsTile(isDark: _isDark);
  }

  Widget _buildLogoutButton() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFFF3B30), Color(0xFFFF453A)],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          CupertinoIcons.square_arrow_right,
          color: Colors.white,
          size: 18,
        ),
      ),
      title: Text(
        AppLocalizations.of(context)!.logout,
        style: const TextStyle(fontSize: 16, color: Color(0xFFFF3B30)),
      ),
      onTap: () {
        final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
        final authProvider = Provider.of<AuthProvider>(context, listen: false);
        showDialog(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(AppLocalizations.of(context)!.logout),
            content: Text(AppLocalizations.of(context)!.logoutConfirmation),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(AppLocalizations.of(context)!.cancel),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  playerProvider.stop();
                  authProvider.logout();
                },
                child: Text(
                  AppLocalizations.of(context)!.logout,
                  style: const TextStyle(color: Color(0xFFFF3B30)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSavedProfilesSection() {
    return FutureBuilder<List<ServerConfig>>(
      future: Provider.of<AuthProvider>(context, listen: false).getSavedProfiles(),
      builder: (context, snapshot) {
        final profiles = snapshot.data ?? [];
        if (profiles.isEmpty) return const SizedBox.shrink();

        final l10n = AppLocalizations.of(context)!;
        final authProvider = Provider.of<AuthProvider>(context);
        final currentConfig = authProvider.config;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l10n.sectionSavedProfiles,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: _isDark
                      ? AppTheme.darkSecondaryText
                      : AppTheme.lightSecondaryText,
                  letterSpacing: 0.2,
                ),
              ),
            ),
              Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: _isDark ? AppTheme.darkSurface : Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Column(
                  children: [
                    ...profiles.map((profile) {
                      final isActive = currentConfig?.serverUrl == profile.serverUrl &&
                          currentConfig?.username == profile.username;
                      final label = profile.name?.isNotEmpty == true
                          ? profile.name!
                          : '${profile.username}@${Uri.tryParse(profile.serverUrl)?.host ?? profile.serverUrl}';

                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                        leading: Icon(
                          isActive
                              ? CupertinoIcons.checkmark_circle_fill
                              : CupertinoIcons.person_crop_circle,
                          color: isActive
                              ? const Color(0xFF34C759)
                              : (_isDark
                                  ? AppTheme.darkSecondaryText
                                  : AppTheme.lightSecondaryText),
                        ),
                        title: Text(
                          label,
                          style: TextStyle(
                            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                            color: isActive
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                        ),
                        subtitle: Text(
                          profile.serverUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: _isDark
                                ? AppTheme.darkSecondaryText
                                : AppTheme.lightSecondaryText,
                          ),
                        ),
                        trailing: isActive
                            ? const Icon(CupertinoIcons.checkmark,
                                color: Color(0xFF34C759), size: 18)
                            : null,
                        onTap: isActive
                            ? null
                            : () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text(l10n.switchProfile),
                                    content: Text(l10n.switchProfileConfirmation(label)),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx, false),
                                        child: Text(l10n.cancel),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx, true),
                                        child: Text(l10n.ok),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed == true) {
                                  if (!mounted) return;
                                  final playerProvider =
                                      Provider.of<PlayerProvider>(context, listen: false);
                                  await playerProvider.stop();
                                  await authProvider.switchProfile(profile);
                                }
                              },
                      );
                    }),
                    Divider(height: 1, color: _isDark ? AppTheme.darkDivider : AppTheme.lightDivider),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                      leading: Icon(
                        CupertinoIcons.plus_circle,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      title: Text(
                        l10n.addProfile,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      onTap: () {
                        // Navigate to login screen to add new profile
                        final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
                        playerProvider.stop();
                        authProvider.disconnect();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
class _ServerUrlsDialog extends StatefulWidget {
  final AuthProvider auth;
  final bool isDark;
  const _ServerUrlsDialog({required this.auth, required this.isDark});

  @override
  State<_ServerUrlsDialog> createState() => _ServerUrlsDialogState();
}

class _ServerUrlsDialogState extends State<_ServerUrlsDialog> {
  Map<String, bool?> _status = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _pingAll();
  }

  ServerConfig? get _config => widget.auth.config;

  List<String> _urls() {
    final c = _config;
    if (c == null) return const [];
    final list = <String>[c.serverUrl.trim(), ...c.backupUrls];
    final seen = <String>{};
    return [
      for (final u in list)
        if (u.trim().isNotEmpty && seen.add(u.trim())) u.trim()
    ];
  }

  String _active() {
    final c = _config;
    if (c == null) return '';
    final a = (c.activeUrl ?? '').trim();
    return a.isEmpty ? c.serverUrl.trim() : a;
  }

  Future<void> _pingAll() async {
    final urls = _urls();
    setState(() {
      _status = {for (final u in urls) u: null};
    });
    await Future.wait(urls.map((u) async {
      final ok = await widget.auth.pingServerUrl(u);
      if (!mounted) return;
      setState(() => _status[u] = ok);
    }));
  }

  Future<void> _switchTo(String url) async {
    if (_busy) return;
    if (url == _active()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Этот адрес уже активен')),
        );
      }
      return;
    }
    setState(() => _busy = true);
    try {
      final ok = await widget.auth.switchActiveServerUrl(url);
      if (!mounted) return;
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Переключено на $url')),
        );
        setState(() {});
        await _pingAll();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Не удалось переключиться: ${widget.auth.lastError ?? "сервер недоступен"}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addUrl() async {
    final ctrl = TextEditingController();
    final res = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Добавить запасной URL'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: 'https://backup.example.com',
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Адрес того же сервера (другой домен/порт, reverse proxy). '
              'Можно указать порт, напр. https://домен:8443',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (res == null || res.isEmpty || !mounted) return;
    await widget.auth.addBackupServerUrl(res);
    if (mounted) {
      setState(() {});
      await _pingAll();
    }
  }

  Future<String?> _pickBackup(String title) async {
    final backups = _config?.backupUrls ?? const <String>[];
    if (backups.isEmpty) return null;
    if (backups.length == 1) return backups.first;
    return showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(title),
        children: [
          for (final u in backups)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, u),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(u),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _editUrl() async {
    final target = await _pickBackup('Изменить запасной URL');
    if (target == null || !mounted) return;
    final ctrl = TextEditingController(text: target);
    final res = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Изменить запасной URL'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://backup.example.com',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (res == null || res.isEmpty || !mounted) return;
    await widget.auth.updateBackupServerUrl(target, res);
    if (mounted) {
      setState(() {});
      await _pingAll();
    }
  }

  Future<void> _deleteUrl() async {
    final target = await _pickBackup('Удалить запасной URL');
    if (target == null || !mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Удалить запасной URL?'),
        content: Text(target),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFF3B30),
            ),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await widget.auth.removeBackupServerUrl(target);
    if (mounted) {
      setState(() {});
      await _pingAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final urls = _urls();
    final active = _active();
    final primary = _config?.serverUrl.trim() ?? '';
    final hasBackups = (_config?.backupUrls ?? const []).isNotEmpty;

    return AlertDialog(
      title: const Text('Адреса сервера'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (urls.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Нет адресов'),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: urls.length,
                  itemBuilder: (context, i) {
                    final url = urls[i];
                    final isActive = url == active;
                    final st = _status[url];
                    final isPrimary = url == primary;
                    final label = isPrimary ? 'Основной' : 'Запасной';
                    final statusText = st == null
                        ? 'проверяется…'
                        : st
                            ? 'доступен'
                            : 'нет ответа';
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        isActive
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: isActive
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: Text(
                        '$label${isActive ? ' ✓' : ''}',
                        style: TextStyle(
                          fontWeight:
                              isActive ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(
                        '$url\n$statusText',
                        style: TextStyle(
                          fontSize: 12,
                          color: st == false ? Colors.orange : null,
                        ),
                      ),
                      isThreeLine: true,
                      onTap: _busy ? null : () => _switchTo(url),
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  onPressed: _busy ? null : _addUrl,
                  icon: const Icon(Icons.add_link, size: 18),
                  label: const Text('Добавить'),
                ),
                if (hasBackups)
                  TextButton.icon(
                    onPressed: _busy ? null : _editUrl,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Изменить'),
                  ),
                if (hasBackups)
                  TextButton.icon(
                    onPressed: _busy ? null : _deleteUrl,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Удалить'),
                  ),
                TextButton.icon(
                  onPressed: _busy ? null : _pingAll,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Проверить'),
                ),
              ],
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}

class _AudiobookshelfSettingsTile extends StatefulWidget {
  final bool isDark;
  const _AudiobookshelfSettingsTile({required this.isDark});
  @override
  State<_AudiobookshelfSettingsTile> createState() => _AudiobookshelfSettingsTileState();
}

class _AudiobookshelfSettingsTileState extends State<_AudiobookshelfSettingsTile> {
  final _abs = AudiobookshelfService();
  final _urlCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  bool _enabled = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _abs.initialize();
    _urlCtrl.text = _abs.getUrl();
    _tokenCtrl.text = _abs.getToken();
    if (mounted) setState(() { _enabled = _abs.enabled; _loading = false; });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const ListTile(title: Text('Загрузка...'));
    return Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: const Color(0xFF5856D6).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(CupertinoIcons.book_fill, color: Color(0xFF5856D6), size: 18),
          ),
          title: const Text('Audiobookshelf', style: TextStyle(fontSize: 16)),
          subtitle: Text(
            _enabled ? 'Включено' : 'Выключено',
            style: TextStyle(fontSize: 13, color: widget.isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText),
          ),
          trailing: Switch(
            value: _enabled,
            onChanged: (v) async {
              await _abs.setEnabled(v);
              if (mounted) setState(() => _enabled = v);
            },
          ),
        ),
        if (_enabled) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(labelText: 'ABS URL', hintText: 'https://abs.example.com', border: OutlineInputBorder(), isDense: true),
              style: const TextStyle(fontSize: 14),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _tokenCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'ABS Token', border: OutlineInputBorder(), isDense: true),
              style: const TextStyle(fontSize: 14),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      await _abs.setUrl(_urlCtrl.text.trim());
                      await _abs.setToken(_tokenCtrl.text.trim());
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Сохранено'))); 
                    },
                    icon: const Icon(Icons.save_rounded, size: 18),
                    label: const Text('Сохранить'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => NavigationHelper.push(context, const AudiobookshelfScreen()),
                  icon: const Icon(CupertinoIcons.book, size: 18),
                  label: const Text('Книги'),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _MusicFoldersDialog extends StatefulWidget {
  final List<MusicFolder> folders;
  final Set<String> initialSelection;
  final Future<void> Function(Set<String> selected) onSave;

  const _MusicFoldersDialog({
    required this.folders,
    required this.initialSelection,
    required this.onSave,
  });

  @override
  State<_MusicFoldersDialog> createState() => _MusicFoldersDialogState();
}

class _MusicFoldersDialogState extends State<_MusicFoldersDialog> {
  late Set<String> _selected;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selected = Set.from(widget.initialSelection);
  }

  bool _isFolderEnabled(MusicFolder folder) {
    
    return _selected.isEmpty || _selected.contains(folder.id);
  }

  void _toggle(MusicFolder folder) {
    setState(() {
      if (_selected.isEmpty) {
        
        _selected = widget.folders
            .map((f) => f.id)
            .where((id) => id != folder.id)
            .toSet();
      } else if (_selected.contains(folder.id)) {
        _selected.remove(folder.id);
        
        if (_selected.isEmpty) _selected = {};
      } else {
        _selected.add(folder.id);
        
        if (_selected.length == widget.folders.length) _selected = {};
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Text(l10n.musicFolders),
      content: widget.folders.isEmpty
          ? Text(l10n.noMusicFolders)
          : SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.musicFoldersHint,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  ...widget.folders.map(
                    (folder) => CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(CupertinoIcons.folder),
                      title: Text(folder.name),
                      value: _isFolderEnabled(folder),
                      onChanged: (v) => _toggle(folder),
                    ),
                  ),
                ],
              ),
            ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: _saving
              ? null
              : () async {
                  setState(() => _saving = true);
                  await widget.onSave(_selected);
                  if (context.mounted) Navigator.pop(context);
                },
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.save),
        ),
      ],
    );
  }
}

