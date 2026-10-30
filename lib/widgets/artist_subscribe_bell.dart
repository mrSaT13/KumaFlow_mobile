import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/kumaflow_brain/kumaflow_brain_bridge.dart';

/// Колокольчик подписки на артиста (плеер -> мозг -> внешний сервис).
/// Только подписка: лайк и избранное не трогает. Отписка колокольчиком
/// из любимых не исключает. Состояние — из моста (локальный кеш +
/// best-effort сверка со списком сервера при появлении).
class ArtistSubscribeBell extends StatefulWidget {
  final String artistId;
  final String artistName;

  /// Круглый контейнер как кнопки на странице артиста (иначе —
  /// компактная иконка для строк списков).
  final bool circle;
  final double circleSize;
  final double iconSize;

  const ArtistSubscribeBell({
    super.key,
    required this.artistId,
    required this.artistName,
    this.circle = false,
    this.circleSize = 44,
    this.iconSize = 20,
  });

  @override
  State<ArtistSubscribeBell> createState() => _ArtistSubscribeBellState();
}

class _ArtistSubscribeBellState extends State<ArtistSubscribeBell> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        Provider.of<KumaFlowBrainBridge>(context, listen: false)
            .ensureSubscriptions();
      } catch (_) {}
    });
  }

  void _toggle(KumaFlowBrainBridge bridge, bool on) {
    if (on) {
      bridge.unsubscribeArtistRemote(
          widget.artistId, widget.artistName);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Подписка снята: ${widget.artistName} (лайк остался)'),
          duration: const Duration(seconds: 2)));
    } else {
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(SnackBar(
          content: Text(
              'Подписываемся: ${widget.artistName}…'),
          duration: const Duration(seconds: 1)));
      bridge
          .subscribeArtistRemote(widget.artistId, widget.artistName)
          .then((provider) {
        if (!mounted) return;
        if (provider == null) {
          messenger.showSnackBar(const SnackBar(
              content: Text(
                  'Мост офлайн — подписка только локально, сервер проверим позже'),
              duration: Duration(seconds: 3)));
        } else if (provider['ok'] == true &&
            provider['skipped'] != true) {
          messenger.showSnackBar(SnackBar(
              content: Text(
                  'Подписка оформлена: ${widget.artistName} — новинки придут уведомлением'),
              duration: const Duration(seconds: 2)));
        } else {
          messenger.showSnackBar(SnackBar(
              content: Text(
                  'Сервер: ${provider['error'] ?? 'загрузчик не принял подписку'}'),
              duration: const Duration(seconds: 4)));
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bridge = Provider.of<KumaFlowBrainBridge>(context);
    final on = bridge.isSubscribedSync(widget.artistName);
    final offColor = widget.circle
        ? Colors.white
        : (Theme.of(context).iconTheme.color ?? Colors.grey);
    final icon = Icon(
        on
            ? Icons.notifications_active_rounded
            : Icons.notifications_none_rounded,
        color: on ? const Color(0xFFFFC107) : offColor,
        size: widget.iconSize);
    if (!widget.circle) {
      return IconButton(
        icon: icon,
        tooltip: on ? 'Подписка оформлена' : 'Подписаться на новинки',
        visualDensity: VisualDensity.compact,
        onPressed: () => _toggle(bridge, on),
      );
    }
    return GestureDetector(
      onTap: () => _toggle(bridge, on),
      child: Container(
          width: widget.circleSize,
          height: widget.circleSize,
          decoration: BoxDecoration(
              color: on
                  ? const Color(0xFFFFC107).withValues(alpha: 0.25)
                  : Colors.white.withValues(alpha: 0.18),
              shape: BoxShape.circle,
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.15))),
          child: Center(child: icon)),
    );
  }
}
