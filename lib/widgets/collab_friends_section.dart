import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../services/collab/collab_account.dart';
import '../services/collab/collab_taste_service.dart';
import '../services/collab/multi_server_resolver.dart';
import '../services/subsonic_service.dart';
import '../theme/app_theme.dart';

/// Секция «Друзья / Collab» для настроек сервера (под Audiobookshelf).
/// URL + логин + пароль друга → фоново тянем его вкус (лайки) строго
/// по одному аккаунту, чтобы не словить OOM.
class CollabFriendsSection extends StatefulWidget {
  final bool isDark;
  const CollabFriendsSection({super.key, required this.isDark});

  @override
  State<CollabFriendsSection> createState() => _CollabFriendsSectionState();
}

class _CollabFriendsSectionState extends State<CollabFriendsSection> {
  final _store = CollabAccountStore();
  final _tastes = CollabTasteService();

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await _store.load();
      await _tastes.load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_store, _tastes]),
      builder: (context, _) {
        final accounts = _store.accounts;
        return Column(
          children: [
            if (accounts.isEmpty)
              const ListTile(
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                leading: Icon(CupertinoIcons.person_2,
                    color: Color(0xFF34C759), size: 22),
                title: Text('Пока никого нет',
                    style: TextStyle(fontSize: 15)),
                subtitle: Text(
                    'Добавь сервер друга — плеер сам соберёт общий микс',
                    style: TextStyle(fontSize: 13)),
              ),
            for (var i = 0; i < accounts.length; i++) ...[
              if (i > 0)
                Divider(
                    height: 1,
                    indent: 56,
                    color: widget.isDark
                        ? AppTheme.darkDivider
                        : AppTheme.lightDivider),
              _accountTile(accounts[i]),
            ],
            if (_tastes.isRefreshing && _tastes.refreshStatus != null)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const SizedBox(
                        width: 14,
                        height: 14,
                        child:
                            CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(_tastes.refreshStatus!,
                          style: TextStyle(
                              fontSize: 12,
                              color: widget.isDark
                                  ? AppTheme.darkSecondaryText
                                  : AppTheme.lightSecondaryText)),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _showAddDialog(),
                      icon: const Icon(CupertinoIcons.plus, size: 18),
                      label: const Text('Добавить друга'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _tastes.isRefreshing || accounts.isEmpty
                          ? null
                          : () => _refreshAll(),
                      icon: const Icon(Icons.sync_rounded, size: 18),
                      label: const Text('Обновить вкусы'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _accountTile(CollabAccount acc) {
    final taste = _tastes.tasteFor(acc.id);
    String status;
    if (taste == null || (!taste.hasData && taste.error == null)) {
      status = 'Вкус ещё не собран — нажми «Обновить вкусы»';
    } else if (taste.error != null && !taste.hasData) {
      status = 'Ошибка: ${taste.error}';
    } else {
      final when = taste.updatedAt != null
          ? '${taste.updatedAt!.day}.${taste.updatedAt!.month} ${taste.updatedAt!.hour.toString().padLeft(2, '0')}:${taste.updatedAt!.minute.toString().padLeft(2, '0')}'
          : '—';
      status =
          'Вкус: ${taste.starred.length} тр. • топ: ${_topNames(taste)} • $when';
      if (taste.error != null) status += ' (обновление упало)';
    }
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        backgroundColor:
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
        child: Text(
          acc.displayLabel.isNotEmpty
              ? acc.displayLabel[0].toUpperCase()
              : '?',
          style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold),
        ),
      ),
      title: Text(acc.displayLabel,
          style: const TextStyle(fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${acc.username} • ${acc.serverUrl}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  color: widget.isDark
                      ? AppTheme.darkSecondaryText
                      : AppTheme.lightSecondaryText)),
          Text(status,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  color: widget.isDark
                      ? AppTheme.darkSecondaryText
                      : AppTheme.lightSecondaryText)),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: acc.enabled,
            onChanged: (v) => _store.setEnabled(acc.id, v),
          ),
          IconButton(
            icon: const Icon(CupertinoIcons.trash, size: 20),
            color: Colors.redAccent,
            tooltip: 'Удалить',
            onPressed: () => _confirmDelete(acc),
          ),
        ],
      ),
      isThreeLine: true,
    );
  }

  String _topNames(CollabTaste taste) {
    final entries = taste.topArtists.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (entries.isEmpty) return '—';
    return entries.take(2).map((e) => e.key).join(', ');
  }

  Future<void> _refreshAll() async {
    MultiServerResolver? resolver;
    try {
      resolver =
          Provider.of<PlayerProvider>(context, listen: false).multiServerResolver;
    } catch (_) {}
    await _tastes.refreshAll(resolver: resolver);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Готово: ${_tastes.totalTracks} треков от друзей')));
    }
  }

  Future<void> _confirmDelete(CollabAccount acc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить друга?'),
        content: Text(
            '«${acc.displayLabel}» и его сохранённый вкус будут удалены.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _store.remove(acc.id);
      await _tastes.clearTaste(acc.id);
    }
  }

  Future<void> _showAddDialog() async {
    final urlCtrl = TextEditingController();
    final loginCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final labelCtrl = TextEditingController();
    String? testResult;
    bool testing = false;
    bool saving = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('Друг / второй сервер'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: urlCtrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Server URL',
                    hintText: 'https://music.friend.com',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: loginCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Логин',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: passCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Пароль',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: labelCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Имя (как показывать)',
                    hintText: 'Например: Ваня',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                if (testResult != null) ...[
                  const SizedBox(height: 10),
                  Text(testResult!,
                      style: TextStyle(
                          fontSize: 12,
                          color: testResult!.startsWith('✓')
                              ? Colors.green
                              : Colors.red)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: testing || saving ? null : () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: testing || saving
                  ? null
                  : () async {
                      final url = urlCtrl.text.trim();
                      final login = loginCtrl.text.trim();
                      final pass = passCtrl.text;
                      if (url.isEmpty || login.isEmpty || pass.isEmpty) {
                        setSt(() =>
                            testResult = '✗ Заполни URL, логин и пароль');
                        return;
                      }
                      setSt(() {
                        testing = true;
                        testResult = 'Проверка…';
                      });
                      try {
                        final svc = SubsonicService();
                        await svc.configure(
                            CollabAccount(
                          id: 'tmp',
                          serverUrl: url,
                          username: login,
                          password: pass,
                        ).toServerConfig());
                        final res = await svc.pingWithError().timeout(
                            const Duration(seconds: 12));
                        setSt(() {
                          testing = false;
                          testResult = res.success
                              ? '✓ ${res.serverType ?? 'OK'} ${res.serverVersion ?? ''}'
                              : '✗ ${res.error ?? 'не отвечает'}';
                        });
                      } catch (e) {
                        setSt(() {
                          testing = false;
                          testResult =
                              '✗ ${e.toString().length > 100 ? '${e.toString().substring(0, 100)}…' : e}';
                        });
                      }
                    },
              child: testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Тест'),
            ),
            FilledButton(
              onPressed: testing || saving
                  ? null
                  : () async {
                      final url = urlCtrl.text.trim();
                      final login = loginCtrl.text.trim();
                      final pass = passCtrl.text;
                      if (url.isEmpty || login.isEmpty || pass.isEmpty) {
                        setSt(() =>
                            testResult = '✗ Заполни URL, логин и пароль');
                        return;
                      }
                      setSt(() => saving = true);
                      final acc = await _store.add(
                        serverUrl: url,
                        username: login,
                        password: pass,
                        label: labelCtrl.text.trim(),
                      );
                      // Сразу тянем вкус нового друга в фоне.
                      MultiServerResolver? resolver;
                      try {
                        if (context.mounted) {
                          resolver = Provider.of<PlayerProvider>(context,
                                  listen: false)
                              .multiServerResolver;
                        }
                      } catch (_) {}
                      await _tastes.refreshAccount(acc, resolver: resolver);
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
              child: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    urlCtrl.dispose();
    loginCtrl.dispose();
    passCtrl.dispose();
    labelCtrl.dispose();
  }
}
