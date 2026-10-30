import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/brain_new_arrivals_service.dart';
import '../services/kumaflow_brain/kumaflow_brain_bridge.dart';

/// Колокольчик новинок: своя страница с деталями.
/// Работает везде (и без системных разрешений) — данные из моста,
/// системный пуш лишь дублирует.
class ArrivalsScreen extends StatefulWidget {
  const ArrivalsScreen({super.key});

  @override
  State<ArrivalsScreen> createState() => _ArrivalsScreenState();
}

class _ArrivalsScreenState extends State<ArrivalsScreen> {
  bool _busy = false;
  String _filter = 'all'; // all | discovery | other

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_busy) return;
    final bridge =
        Provider.of<KumaFlowBrainBridge>(context, listen: false);
    setState(() => _busy = true);
    try {
      await BrainNewArrivalsService.instance.refreshNow(bridge);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final arrivals = context.watch<BrainNewArrivalsService>();
    final bridge = context.watch<KumaFlowBrainBridge>();
    final all = arrivals.items;
    final items = _filter == 'all'
        ? all
        : _filter == 'discovery'
            ? all
                .where((e) => '${e['kind'] ?? ''}' == 'discovery')
                .toList()
            : all
                .where((e) => '${e['kind'] ?? ''}' != 'discovery')
                .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('Новинки${arrivals.unread > 0 ? ' (${arrivals.unread})' : ''}'),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Обновить',
              onPressed: _refresh,
            ),
          TextButton(
            onPressed: items.any((e) => e['read_at'] == null)
                ? () => BrainNewArrivalsService.instance
                    .markAllRead(bridge)
                : null,
            child: const Text('Все прочит.'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _body(context, arrivals, bridge, items),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    BrainNewArrivalsService arrivals,
    KumaFlowBrainBridge bridge,
    List<Map<String, dynamic>> items,
  ) {
    if (!bridge.isActive) {
      return ListView(children: const [
        SizedBox(height: 80),
        Icon(Icons.cloud_off_outlined, size: 48, color: Colors.grey),
        SizedBox(height: 12),
        Center(child: Text('Мозг выключен или не настроен')),
        SizedBox(height: 4),
        Center(
            child: Text('Включи KumaFlow Brain в настройках',
                style: TextStyle(color: Colors.grey, fontSize: 12))),
      ]);
    }
    if (bridge.isOfflineNow) {
      return ListView(children: const [
        SizedBox(height: 80),
        Icon(Icons.wifi_off_outlined, size: 48, color: Colors.grey),
        SizedBox(height: 12),
        Center(child: Text('Мост офлайн — покажем при связи')),
      ]);
    }
    if (_busy && items.isEmpty && arrivals.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    // Ошибка поверх кеша: список не затираем, показываем баннер + старые.
    if (arrivals.lastError != null && arrivals.items.isEmpty) {
      return ListView(children: [
        const SizedBox(height: 80),
        const Icon(Icons.error_outline, size: 48, color: Colors.red),
        const SizedBox(height: 12),
        Center(child: Text('Не удалось загрузить: ${arrivals.lastError}')),
        const SizedBox(height: 12),
        Center(
            child: FilledButton(
                onPressed: _refresh, child: const Text('Повторить'))),
      ]);
    }
    if (items.isEmpty) {
      // Бейдж 10 а тут пусто = фильтр/все прочитано: показываем честно.
      final total = arrivals.items.length;
      return ListView(children: [
        const SizedBox(height: 80),
        const Icon(Icons.notifications_none_rounded,
            size: 48, color: Colors.grey),
        const SizedBox(height: 12),
        Center(
            child: Text(total > 0
                ? 'В этом фильтре пусто (всего: $total)'
                : 'Пока тихо')),
        const SizedBox(height: 4),
        Center(
            child: Text(
                arrivals.lastCheck != null
                    ? 'Проверено: ${arrivals.lastCheck!.toLocal()}'
                    : 'Подпишись на артиста колокольчиком — новинки придут сюда',
                style:
                    const TextStyle(color: Colors.grey, fontSize: 12))),
        if (arrivals.lastError != null) ...[
          const SizedBox(height: 8),
          Center(
              child: Text('${arrivals.lastError}',
                  style:
                      const TextStyle(color: Colors.orange, fontSize: 12))),
        ],
      ]);
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Row(children: [
          ChoiceChip(
              label: const Text('Все'),
              selected: _filter == 'all',
              onSelected: (_) => setState(() => _filter = 'all')),
          const SizedBox(width: 8),
          ChoiceChip(
              label: const Text('Новинки'),
              selected: _filter == 'discovery',
              onSelected: (_) =>
                  setState(() => _filter = 'discovery')),
          const SizedBox(width: 8),
          ChoiceChip(
              label: const Text('Остальное'),
              selected: _filter == 'other',
              onSelected: (_) => setState(() => _filter = 'other')),
        ]),
      ),
      if (arrivals.lastError != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded,
                size: 16, color: Colors.orange),
            const SizedBox(width: 6),
            Expanded(
                child: Text('${arrivals.lastError}',
                    style: const TextStyle(
                        fontSize: 11, color: Colors.orange))),
          ]),
        ),
      Expanded(
        child: ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final n = items[i];
        final id = '${n['id'] ?? ''}';
        final read = n['read_at'] != null;
        final meta = n['meta'];
        final tracks =
            (meta is Map && meta['tracks'] is List) ? meta['tracks'] as List : const [];
        return ListTile(
          leading: Icon(
              read ? Icons.drafts_outlined : Icons.markunread_rounded,
              color: read ? Colors.grey : Colors.blue),
          title: Text('${n['title'] ?? 'Новое поступление'}',
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontWeight:
                      read ? FontWeight.normal : FontWeight.bold)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${n['kind'] ?? ''} • ${n['created_at'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 10, color: Colors.grey)),
              if ('${n['body'] ?? ''}'.isNotEmpty)
                Text('${n['body']}',
                    maxLines: 4, overflow: TextOverflow.ellipsis),
              if (tracks.isNotEmpty) ...[
                const SizedBox(height: 6),
                ...tracks.take(5).map((t) {
                  if (t is! Map) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                        '• ${t['title'] ?? ''} — ${t['artist'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12)),
                  );
                }),
                if (tracks.length > 5)
                  Text('…и ещё ${tracks.length - 5}',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.grey)),
              ],
            ],
          ),
          isThreeLine: true,
          trailing: read
              ? null
              : TextButton(
                  child: const Text('Ок'),
                  onPressed: () => BrainNewArrivalsService.instance
                      .markRead(bridge, id),
                ),
          onTap: read
              ? null
              : () => BrainNewArrivalsService.instance
                  .markRead(bridge, id),
        );
      },
        ),
      ),
    ]);
  }
}
