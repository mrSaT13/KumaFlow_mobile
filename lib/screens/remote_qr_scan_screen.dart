import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Сканер QR-кода пульта с экрана ПК (Настройки → Пульт → QR).
/// Возвращает сырую строку QR через Navigator.pop.
class RemoteQrScanScreen extends StatefulWidget {
  const RemoteQrScanScreen({super.key});

  @override
  State<RemoteQrScanScreen> createState() => _RemoteQrScanScreenState();
}

class _RemoteQrScanScreenState extends State<RemoteQrScanScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );
  bool _done = false;
  bool _torch = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture cap) {
    if (_done) return;
    for (final b in cap.barcodes) {
      final raw = (b.rawValue ?? '').trim();
      if (raw.isNotEmpty) {
        _done = true;
        if (mounted) Navigator.pop(context, raw);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('QR с экрана ПК'),
        actions: [
          IconButton(
            icon: Icon(_torch
                ? Icons.flash_on_rounded
                : Icons.flash_off_rounded),
            tooltip: 'Фонарик',
            onPressed: () async {
              try {
                await _controller.toggleTorch();
                if (mounted) setState(() => _torch = !_torch);
              } catch (_) {}
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.75),
                  ],
                ),
              ),
              child: const Text(
                'Наведи на QR-код из настроек пульта на компьютере',
                style: TextStyle(color: Colors.white, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
