import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import '../providers/player_provider.dart';
import '../services/cast_service.dart';
import '../services/upnp_service.dart';
import '../models/models.dart' show UpnpDevice;
import '../theme/app_theme.dart';

/// Picker for Cast (Chromecast) and DLNA (UPnP) devices.
class CastDevicePicker extends StatefulWidget {
  const CastDevicePicker({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const CastDevicePicker(),
    );
  }

  @override
  State<CastDevicePicker> createState() => _CastDevicePickerState();
}

class _CastDevicePickerState extends State<CastDevicePicker> {
  final GoogleCastDiscoveryManagerPlatformInterface _castDiscovery =
      GoogleCastDiscoveryManager.instance;

  List<GoogleCastDevice> _castDevices = [];
  List<UpnpDevice> _upnpDevices = [];
  StreamSubscription<List<GoogleCastDevice>>? _castSub;
  bool _isLoadingUpnp = false;

  @override
  void initState() {
    super.initState();
    // На устройствах без GMS discovery может бросить — не роняем шторку,
    // остаёмся на DLNA-секции.
    try {
      _castDevices = List.from(_castDiscovery.devices);
      _castSub = _castDiscovery.devicesStream.listen((list) {
        if (!mounted) return;
        setState(() => _castDevices = list);
      });
      _castDiscovery.startDiscovery();
    } catch (_) {}
    _refreshUpnp();
  }

  @override
  void dispose() {
    _castSub?.cancel();
    try {
      _castDiscovery.stopDiscovery();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _refreshUpnp() async {
    if (!mounted) return;
    setState(() => _isLoadingUpnp = true);
    try {
      final upnp = context.read<PlayerProvider>().upnpService;
      final list = await upnp.discover();
      if (!mounted) return;
      setState(() => _upnpDevices = list);
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => _isLoadingUpnp = false);
    }
  }

  Future<void> _connectCast(GoogleCastDevice device) async {
    final cast = context.read<PlayerProvider>().castService;
    final upnp = context.read<PlayerProvider>().upnpService;
    // Messenger берём ДО pop: после закрытия шторки context размонтирован
    // и SnackBar через него уже не показать (молча пропадала ошибка).
    final messenger = ScaffoldMessenger.of(context);

    if (cast.isConnected) {
      await cast.disconnect();
    }
    if (upnp.isConnected) {
      upnp.disconnect();
    }

    if (!mounted) return;
    Navigator.pop(context);
    final ok = await cast.connectToDevice(device);
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Не удалось подключиться к Cast-устройству')),
      );
    }
  }

  Future<void> _connectUpnp(UpnpDevice device) async {
    final cast = context.read<PlayerProvider>().castService;
    final upnp = context.read<PlayerProvider>().upnpService;
    final messenger = ScaffoldMessenger.of(context);

    if (cast.isConnected) {
      await cast.disconnect();
    }
    if (upnp.isConnected) {
      upnp.disconnect();
    }

    if (!mounted) return;
    Navigator.pop(context);
    final ok = await upnp.connect(device);
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Не удалось подключиться к DLNA-устройству')),
      );
    }
  }

  Future<void> _disconnect() async {
    final cast = context.read<PlayerProvider>().castService;
    final upnp = context.read<PlayerProvider>().upnpService;
    if (cast.isConnected) await cast.disconnect();
    if (upnp.isConnected) upnp.disconnect();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final castConnected = player.castService.isConnected;
    final upnpConnected = player.upnpService.isConnected;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.darkSurface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: AppTheme.darkDivider,
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Трансляция / DLNA',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (castConnected || upnpConnected)
                    TextButton.icon(
                      onPressed: _disconnect,
                      icon: const Icon(Icons.link_off, color: Colors.red, size: 18),
                      label: const Text(
                        'Отключить',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (castConnected || upnpConnected)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.appleMusicRed.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.cast_connected, color: AppTheme.appleMusicRed),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          castConnected
                              ? 'Cast: ${player.castService.deviceName ?? "подключено"}'
                              : 'DLNA: ${player.upnpService.connectedDevice?.friendlyName ?? "подключено"}',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: ListView(
                controller: scrollController,
                children: [
                  _SectionHeader(title: 'Chromecast'),
                  if (_castDevices.isEmpty)
                    const _EmptyHint(text: 'Устройства Cast не найдены'),
                  ..._castDevices.map(
                    (d) => ListTile(
                      leading: const Icon(Icons.cast, color: Colors.white70),
                      title: Text(
                        d.friendlyName,
                        style: const TextStyle(color: Colors.white),
                      ),
                      trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                      onTap: () => _connectCast(d),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _SectionHeader(
                    title: 'DLNA-устройства',
                    trailing: IconButton(
                      icon: _isLoadingUpnp
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white70,
                              ),
                            )
                          : const Icon(Icons.refresh, color: Colors.white70),
                      onPressed: _isLoadingUpnp ? null : _refreshUpnp,
                    ),
                  ),
                  if (_upnpDevices.isEmpty && !_isLoadingUpnp)
                    const _EmptyHint(text: 'DLNA-устройства не найдены'),
                  ..._upnpDevices.map(
                    (d) => ListTile(
                      leading: const Icon(Icons.speaker, color: Colors.white70),
                      title: Text(
                        d.friendlyName,
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: d.modelName != null
                          ? Text(
                              d.modelName!,
                              style: const TextStyle(color: Colors.white54, fontSize: 12),
                            )
                          : null,
                      trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                      onTap: () => _connectUpnp(d),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const _SectionHeader({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white54, fontSize: 13),
      ),
    );
  }
}