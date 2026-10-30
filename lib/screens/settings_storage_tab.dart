import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import '../widgets/app_gradient_background.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../services/safe_image_cache_manager.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';
import '../services/subsonic_service.dart';
import '../services/theme_service.dart';
import '../services/bpm_analyzer_service.dart';
import '../services/cache_settings_service.dart';
import '../services/local_music_service.dart';
import '../services/offline_service.dart';
import '../theme/app_theme.dart';
import 'downloads_screen.dart';

class SettingsStorageTab extends StatefulWidget {
  const SettingsStorageTab({super.key});

  @override
  State<SettingsStorageTab> createState() => _SettingsStorageTabState();
}

class _SettingsStorageTabState extends State<SettingsStorageTab> {
  final _bpmAnalyzer = BpmAnalyzerService();
  final _cacheSettings = CacheSettingsService();
  final _offlineService = OfflineService();

  bool _imageCacheEnabled = true;
  bool _musicCacheEnabled = true;
  bool _bpmCacheEnabled = true;
  final bool _isCaching = false;
  final int _currentProgress = 0;
  final int _totalSongs = 0;
  int _downloadedCount = 0;
  String _downloadedSize = '0 B';
  int _parallelDownloads = 3;
  bool _keepScreenOn = true;
  int _preloadCount = 3;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _setupDownloadListener();
  }

  @override
  void dispose() {
    _offlineService.downloadState.removeListener(_onDownloadStateChanged);
    super.dispose();
  }

  void _setupDownloadListener() {
    _offlineService.downloadState.addListener(_onDownloadStateChanged);
  }

  void _onDownloadStateChanged() {
    if (!mounted) return;
    final state = _offlineService.downloadState.value;
    setState(() {
      _downloadedCount = state.downloadedCount;
    });
  }

  Future<void> _loadSettings() async {
    await _cacheSettings.initialize();
    await _offlineService.initialize();
    await _loadOfflineInfo();

    setState(() {
      _imageCacheEnabled = _cacheSettings.getImageCacheEnabled();
      _musicCacheEnabled = _cacheSettings.getMusicCacheEnabled();
      _bpmCacheEnabled = _cacheSettings.getBpmCacheEnabled();
      _preloadCount = _cacheSettings.getPreloadCount();
      _parallelDownloads = _offlineService.getParallelDownloadsCount();
      _keepScreenOn = _offlineService.getKeepScreenOn();
    });
  }

  Future<void> _loadOfflineInfo() async {
    final count = _offlineService.getDownloadedCount();
    final size = await _offlineService.getDownloadedSize();
    if (mounted) {
      setState(() {
        _downloadedCount = count;
        _downloadedSize = _offlineService.formatSize(size);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        _buildSection(
          title: AppLocalizations.of(context)!.sectionCacheSettings,
          children: [
            _buildCacheToggle(
              icon: CupertinoIcons.photo,
              iconGradient: const [Color(0xFFFF3B30), Color(0xFFFF453A)],
              title: AppLocalizations.of(context)!.imageCacheTitle,
              subtitle: AppLocalizations.of(context)!.imageCacheSubtitle,
              value: _imageCacheEnabled,
              onChanged: _toggleImageCache,
            ),
            _buildDivider(),
            _buildCacheToggle(
              icon: CupertinoIcons.music_note,
              iconGradient: const [Color(0xFF34C759), Color(0xFF30D158)],
              title: AppLocalizations.of(context)!.musicCacheTitle,
              subtitle: AppLocalizations.of(context)!.musicCacheSubtitle,
              value: _musicCacheEnabled,
              onChanged: _toggleMusicCache,
            ),
            _buildDivider(),
            _buildCacheToggle(
              icon: CupertinoIcons.speedometer,
              iconGradient: const [Color(0xFF5856D6), Color(0xFF7B68EE)],
              title: AppLocalizations.of(context)!.bpmCacheTitle,
              subtitle: AppLocalizations.of(context)!.bpmCacheSubtitle,
              value: _bpmCacheEnabled,
              onChanged: _toggleBpmCache,
            ),
          ],
        ),
        const SizedBox(height: 24),
        _buildSection(
          title: AppLocalizations.of(context)!.sectionCacheCleanup,
          children: [_buildClearAllCacheButton()],
        ),
        const SizedBox(height: 24),
        _buildSection(
          title: AppLocalizations.of(context)!.sectionOfflineDownloads,
          children: [
            _buildParallelDownloadsTile(),
            _buildDivider(),
            _buildKeepScreenOnTile(),
            _buildDivider(),
            _buildPreloadCountTile(),
            _buildDivider(),
            _buildOfflineInfo(),
            _buildDivider(),
            _buildDownloadsScreenButton(),
            _buildDivider(),
            _buildDownloadAllLibraryButton(),
            _buildDivider(),
            _buildDeleteDownloadsButton(),
          ],
        ),
        const SizedBox(height: 24),
        _buildLocalMusicSection(),
        const SizedBox(height: 24),
        _buildSection(
          title: AppLocalizations.of(context)!.sectionBpmAnalysis,
          children: [
            _buildBPMCacheInfo(),
            if (_isCaching) _buildCachingProgress(),
            _buildCacheAllButton(),
            _buildClearCacheButton(),
          ],
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

  Widget _buildCacheToggle({
    required IconData icon,
    required List<Color> iconGradient,
    required String title,
    required String subtitle,
    required bool value,
    required Function(bool) onChanged,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: iconGradient),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: Colors.white, size: 18),
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
      ),
      trailing: CupertinoSwitch(
        value: value,
        activeTrackColor: Theme.of(context).colorScheme.primary,
        onChanged: onChanged,
      ),
    );
  }

  void _toggleImageCache(bool value) async {
    setState(() => _imageCacheEnabled = value);
    await _cacheSettings.setImageCacheEnabled(value);
    if (!value) {
      await DefaultCacheManager().emptyCache();
      try {
        await SafeImageCacheManager.instance.emptyCache();
      } catch (_) {}
    }
  }

  void _toggleMusicCache(bool value) async {
    setState(() => _musicCacheEnabled = value);
    await _cacheSettings.setMusicCacheEnabled(value);
  }

  void _toggleBpmCache(bool value) async {
    setState(() => _bpmCacheEnabled = value);
    await _cacheSettings.setBpmCacheEnabled(value);
    if (!value) await _bpmAnalyzer.clearCache();
  }

  Widget _buildLocalMusicSection() {
    return Consumer<LocalMusicService>(
      builder: (context, localMusic, _) {
        final l10n = AppLocalizations.of(context)!;
        final customPaths = localMusic.customScanPaths;

        return _buildSection(
          title: l10n.localMusicLibrary,
          children: [
            // Merge toggle
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              secondary: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF8B5CF6), Color(0xFFA78BFA)],
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(CupertinoIcons.music_albums, color: Colors.white, size: 18),
              ),
              title: Text(l10n.mergeLocalLibrary, style: const TextStyle(fontSize: 16)),
              subtitle: Text(
                l10n.mergeLocalLibrarySubtitle,
                style: TextStyle(
                  fontSize: 13,
                  color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText,
                ),
              ),
              value: context.watch<LibraryProvider>().mergeLocalLibrary,
              onChanged: (value) {
                final libraryProvider = context.read<LibraryProvider>();
                if (value) {
                  // Enable merge mode
                  libraryProvider.setLocalMusicService(localMusic, mergeWithServer: true);
                } else {
                  // Disable merge mode
                  libraryProvider.setMergeLocalLibrary(false);
                }
              },
            ),
            _buildDivider(),
            // Local music stats
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              leading: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF34C759), Color(0xFF30D158)],
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(CupertinoIcons.music_note, color: Colors.white, size: 18),
              ),
              title: Text(l10n.localMusicStats, style: const TextStyle(fontSize: 16)),
              trailing: Text(
                '${localMusic.songCount} ${l10n.songs.toLowerCase()}',
                style: TextStyle(
                  fontSize: 14,
                  color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText,
                ),
              ),
              subtitle: localMusic.isScanning
                ? Text(localMusic.scanStatus, style: const TextStyle(fontSize: 12))
                : null,
            ),
            _buildDivider(),
            // Add folder button
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              leading: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF007AFF), Color(0xFF5AC8FA)],
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(CupertinoIcons.plus, color: Colors.white, size: 18),
              ),
              title: Text(l10n.addMusicFolder, style: const TextStyle(fontSize: 16)),
              onTap: () => _addMusicFolder(context, localMusic),
            ),
            // Show custom paths
            if (customPaths.isNotEmpty) ...[
              _buildDivider(),
              ...customPaths.map((path) => ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                leading: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFF9500), Color(0xFFFFB340)],
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(CupertinoIcons.folder_fill, color: Colors.white, size: 18),
                ),
                title: Text(
                  path.split('/').last,
                  style: const TextStyle(fontSize: 16),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  path,
                  style: TextStyle(
                    fontSize: 12,
                    color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  icon: const Icon(CupertinoIcons.delete, color: Colors.red, size: 20),
                  onPressed: () => _removeMusicFolder(context, localMusic, path),
                ),
              )),
            ],
            _buildDivider(),
            // Rescan button
            ListTile(
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
                child: const Icon(CupertinoIcons.refresh, color: Colors.white, size: 18),
              ),
              title: Text(l10n.rescanLocalMusic, style: const TextStyle(fontSize: 16)),
              enabled: !localMusic.isScanning,
              onTap: () => _rescanLocalMusic(context, localMusic),
            ),
          ],
        );
      },
    );
  }

  Future<void> _addMusicFolder(BuildContext context, LocalMusicService service) async {
    final path = await service.pickMusicDirectory();
    if (path == null) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Added folder: $path — scanning...')),
    );
    try {
      // Incremental scan only this folder to avoid hanging on full Music/Download rescan
      await service.scanForMusic(overridePaths: [path]);
      if (!mounted) return;
      final count = service.songCount;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Scan complete: $count songs total (${service.scanStatus})')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Scan failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _removeMusicFolder(BuildContext context, LocalMusicService service, String path) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Folder'),
        content: Text('Remove "$path" from scan paths?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await service.removeCustomScanPath(path);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Folder removed')),
    );
  }

  Widget _buildKeepScreenOnTile() {
    final l10n = AppLocalizations.of(context)!;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFFF9500), Color(0xFFFFCC00)],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(CupertinoIcons.bolt_fill, color: Colors.white, size: 18),
      ),
      title: Text(l10n.keepScreenOnDuringDownload, style: const TextStyle(fontSize: 16)),
      subtitle: Text(
        l10n.keepScreenOnDuringDownloadSubtitle,
        style: TextStyle(
          fontSize: 13,
          color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText,
        ),
      ),
      trailing: CupertinoSwitch(
        value: _keepScreenOn,
        activeTrackColor: Theme.of(context).colorScheme.primary,
        onChanged: (value) async {
          setState(() => _keepScreenOn = value);
          await _offlineService.setKeepScreenOn(value);
        },
      ),
    );
  }

  Widget _buildParallelDownloadsTile() {
    final l10n = AppLocalizations.of(context)!;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF007AFF), Color(0xFF5AC8FA)],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(CupertinoIcons.arrow_down_to_line, color: Colors.white, size: 18),
      ),
      title: Text(l10n.parallelDownloads, style: const TextStyle(fontSize: 16)),
      subtitle: Text(
        l10n.parallelDownloadsSubtitle,
        style: TextStyle(
          fontSize: 13,
          color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$_parallelDownloads',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            CupertinoIcons.chevron_right,
            size: 16,
            color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText,
          ),
        ],
      ),
      onTap: _showParallelDownloadsDialog,
    );
  }

  Future<void> _showParallelDownloadsDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.parallelDownloads),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [1, 2, 3, 4, 5].map((count) {
            final isSelected = count == _parallelDownloads;
            return ListTile(
              title: Text('$count ${count == 1 ? l10n.downloadSingular : l10n.downloadPlural}'),
              subtitle: count == 1
                ? Text(l10n.slowerButStable)
                : count == 5
                  ? Text(l10n.fasterButMoreData)
                  : null,
              leading: Icon(
                isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: isSelected ? Theme.of(context).colorScheme.primary : null,
              ),
              onTap: () => Navigator.pop(context, count),
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
        ],
      ),
    );

    if (selected != null && selected != _parallelDownloads) {
      await _offlineService.setParallelDownloadsCount(selected);
      setState(() {
        _parallelDownloads = selected;
      });
    }
  }

  Widget _buildPreloadCountTile() {
    final l10n = AppLocalizations.of(context)!;
    final isRu = l10n.localeName.startsWith('ru');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF5856D6), Color(0xFF7B68EE)]),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(CupertinoIcons.arrow_down_circle_fill, color: Colors.white, size: 18),
      ),
      title: Text(isRu ? 'Предзагрузка очереди' : 'Queue preload', style: const TextStyle(fontSize: 16)),
      subtitle: Text(
        isRu ? 'Кешировать следующих $_preloadCount песен для оффлайна' : 'Cache next $_preloadCount songs for offline',
        style: TextStyle(fontSize: 13, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$_preloadCount', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary)),
          const SizedBox(width: 4),
          Icon(CupertinoIcons.chevron_right, size: 16, color: _isDark ? AppTheme.darkSecondaryText : AppTheme.lightSecondaryText),
        ],
      ),
      onTap: _showPreloadCountDialog,
    );
  }

  Future<void> _showPreloadCountDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final isRu = l10n.localeName.startsWith('ru');
    int temp = _preloadCount;
    final selected = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(isRu ? 'Предзагрузка' : 'Preload count'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(isRu ? 'Сколько следующих песен кешировать при воспроизведении' : 'How many next songs to cache while playing'),
              const SizedBox(height: 16),
              Row(
                children: [
                  IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: temp > 0 ? () => setS(() => temp--) : null),
                  Expanded(
                    child: Slider(
                      value: temp.toDouble(),
                      min: 0,
                      max: 30,
                      divisions: 30,
                      label: '$temp',
                      onChanged: (v) => setS(() => temp = v.toInt()),
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: temp < 30 ? () => setS(() => temp++) : null),
                ],
              ),
              Text('$temp ${isRu ? "песен" : "songs"}', style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(isRu ? '0 — выключить предзагрузку' : '0 — disable preload', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, temp), child: Text(l10n.ok)),
          ],
        ),
      ),
    );
    if (selected != null && selected != _preloadCount) {
      await _cacheSettings.setPreloadCount(selected);
      setState(() => _preloadCount = selected);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(isRu ? 'Предзагрузка: $selected песен' : 'Preload: $selected songs')));
      }
    }
  }

  Future<void> _rescanLocalMusic(BuildContext context, LocalMusicService service) async {
    if (service.isScanning) return;

    // Request permission first
    final hasPermission = await service.requestPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Storage permission required')),
        );
      }
      return;
    }

    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rescanning local library...')),
        );
      }
      await service.scanForMusic();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rescan complete: ${service.songCount} songs')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rescan failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _buildClearAllCacheButton() {
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
          CupertinoIcons.trash_fill,
          color: Colors.white,
          size: 16,
        ),
      ),
      title: Text(
        AppLocalizations.of(context)!.clearAllCache,
        style: const TextStyle(fontSize: 16, color: Color(0xFFFF3B30)),
      ),
      onTap: _clearAllCache,
    );
  }

  void _clearAllCache() async {
    await DefaultCacheManager().emptyCache();
    try {
      await SafeImageCacheManager.instance.emptyCache();
    } catch (_) {}
    await _bpmAnalyzer.clearCache();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context)!.allCacheCleared)),
      );
      setState(() {});
    }
  }

  Widget _buildOfflineInfo() {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF007AFF), Color(0xFF5AC8FA)],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          CupertinoIcons.arrow_down_circle,
          color: Colors.white,
          size: 18,
        ),
      ),
      title: Text(
        AppLocalizations.of(context)!.downloadedSongs,
        style: const TextStyle(fontSize: 16),
      ),
      trailing: Text(
        AppLocalizations.of(
          context,
        )!.downloadedStats(_downloadedCount, _downloadedSize),
        style: TextStyle(
          fontSize: 14,
          color: _isDark
              ? AppTheme.darkSecondaryText
              : AppTheme.lightSecondaryText,
        ),
      ),
    );
  }

  Widget _buildDownloadsScreenButton() {
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
        child: const Icon(
          CupertinoIcons.folder_fill,
          color: Colors.white,
          size: 18,
        ),
      ),
      title: const Text('Мои загрузки', style: TextStyle(fontSize: 16)),
      subtitle: Text(
        'Треки, книги, подкасты · экспорт в Музыку',
        style: TextStyle(
          fontSize: 13,
          color: _isDark
              ? AppTheme.darkSecondaryText
              : AppTheme.lightSecondaryText,
        ),
      ),
      trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const DownloadsScreen()),
        ).then((_) => _loadOfflineInfo());
      },
    );
  }

  Widget _buildDownloadAllLibraryButton() {
    return ValueListenableBuilder<DownloadState>(
      valueListenable: _offlineService.downloadState,
      builder: (context, downloadState, _) {
        final isDownloading = downloadState.isDownloading;
        final progress = downloadState.totalCount > 0
            ? downloadState.currentProgress / downloadState.totalCount
            : 0.0;

        if (isDownloading) {
          return Column(
            children: [
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                leading: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF34C759), Color(0xFF30D158)],
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    CupertinoIcons.arrow_down_circle_fill,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                title: Text(
                  AppLocalizations.of(context)!.downloadingLibrary(
                    downloadState.currentProgress,
                    downloadState.totalCount,
                  ),
                  style: const TextStyle(fontSize: 16),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    _offlineService.cancelBackgroundDownload();
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: LinearProgressIndicator(
                  value: progress,
                  backgroundColor: _isDark
                      ? AppTheme.darkCard
                      : AppTheme.lightDivider,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    Color(0xFF34C759),
                  ),
                ),
              ),
            ],
          );
        }

        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF34C759), Color(0xFF30D158)],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              CupertinoIcons.cloud_download,
              color: Colors.white,
              size: 18,
            ),
          ),
          title: Text(
            AppLocalizations.of(context)!.downloadAllLibrary,
            style: const TextStyle(fontSize: 16, color: Color(0xFF34C759)),
          ),
          onTap: _downloadAllLibrary,
        );
      },
    );
  }

  Future<void> _downloadAllLibrary() async {
    try {
      final libraryProvider = context.read<LibraryProvider>();
      final subsonicService = context.read<SubsonicService>();

      // Show loading indicator
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Loading library...'),
            duration: Duration(seconds: 1),
          ),
        );
      }

      await libraryProvider.ensureLibraryLoaded();

      // Было: вся библиотека в RAM одним списком. Стало: точный COUNT + чанки.
      var total = 0;
      try {
        total = await libraryProvider.getSongsTotal();
      } catch (_) {}
      // If still empty, try to refresh from server with a small delay
      if (total == 0) {
        await Future.delayed(const Duration(milliseconds: 500));
        // Force refresh by calling refresh method
        await libraryProvider.refresh();
        try {
          total = await libraryProvider.getSongsTotal();
        } catch (_) {}
      }

      if (total == 0) {
        if (!mounted) return;
        final retry = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(AppLocalizations.of(context)!.noSongsAvailable),
            content: const Text(
              'Library appears to be empty or failed to load. Make sure your server supports full library scanning.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(AppLocalizations.of(context)!.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Retry'),
              ),
            ],
          ),
        );
        if (retry == true) {
          return _downloadAllLibrary();
        }
        return;
      }

      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(AppLocalizations.of(context)!.downloadAllLibrary),
          content: Text(
            AppLocalizations.of(
              context,
            )!.downloadLibraryConfirm(total),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(AppLocalizations.of(context)!.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(AppLocalizations.of(context)!.download),
            ),
          ],
        ),
      );

      if (confirm != true || !mounted) return;

      // Чанками по 2000 легких песен: полный список 80к в RAM больше не собираем.
      const chunk = 2000;
      for (var offset = 0; offset < total; offset += chunk) {
        if (!mounted) break;
        final page = await libraryProvider.getSongsPage(limit: chunk, offset: offset, sort: 'titleAsc');
        if (page.isEmpty) break;
        await _offlineService.startBackgroundDownload(page, subsonicService);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.libraryDownloadStarted),
            duration: const Duration(seconds: 2),
          ),
        );
        await _loadOfflineInfo();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.errorStartingDownload(e),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildDeleteDownloadsButton() {
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
          CupertinoIcons.trash_fill,
          color: Colors.white,
          size: 16,
        ),
      ),
      title: Text(
        AppLocalizations.of(context)!.deleteDownloads,
        style: const TextStyle(fontSize: 16, color: Color(0xFFFF3B30)),
      ),
      onTap: () async {
        await _offlineService.deleteAllDownloads();
        await _loadOfflineInfo();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context)!.downloadsDeleted),
            ),
          );
        }
      },
    );
  }

  Widget _buildBPMCacheInfo() {
    return FutureBuilder<int>(
      future: _bpmAnalyzer.getCachedCount(),
      builder: (context, snapshot) {
        final cachedCount = snapshot.data ?? 0;
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
        child: const Icon(
          CupertinoIcons.speedometer,
          color: Colors.white,
          size: 18,
        ),
      ),
      title: Text(
        AppLocalizations.of(context)!.cachedBpms,
        style: const TextStyle(fontSize: 16),
      ),
      trailing: Text(
        '$cachedCount',
        style: TextStyle(
          fontSize: 16,
          color: _isDark
              ? AppTheme.darkSecondaryText
              : AppTheme.lightSecondaryText,
        ),
      ),
    );
      },
    );
  }

  Widget _buildCachingProgress() {
    final progress = _totalSongs > 0 ? _currentProgress / _totalSongs : 0.0;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: LinearProgressIndicator(
        value: progress,
        backgroundColor: _isDark ? AppTheme.darkCard : AppTheme.lightDivider,
        valueColor: AlwaysStoppedAnimation<Color>(
          Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildCacheAllButton() {
    return Column(
      children: [
        _buildDivider(),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          enabled: !_isCaching,
          title: Text(
            AppLocalizations.of(context)!.cacheAllBpms,
            style: TextStyle(
              fontSize: 16,
              color: _isCaching ? Colors.grey : null,
            ),
          ),
          trailing: _isCaching
              ? const CupertinoActivityIndicator()
              : const Icon(CupertinoIcons.chevron_right, size: 16),
          onTap: _isCaching ? null : () {},
        ),
      ],
    );
  }

  Widget _buildClearCacheButton() {
    return Column(
      children: [
        _buildDivider(),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          title: Text(
            AppLocalizations.of(context)!.clearBpmCache,
            style: const TextStyle(fontSize: 16, color: Color(0xFFFF3B30)),
          ),
          onTap: () async {
            await _bpmAnalyzer.clearCache();
            setState(() {});
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(AppLocalizations.of(context)!.bpmCacheCleared),
                ),
              );
            }
          },
        ),
      ],
    );
  }
}
