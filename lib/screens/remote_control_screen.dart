import 'dart:async';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/remote_control/remote_client.dart';
import '../services/remote_control/remote_device.dart';
import '../services/remote_control/remote_discovery.dart';
import '../services/remote_control/remote_pin_store.dart';
import '../../main.dart' show engineId;
import 'remote_qr_scan_screen.dart';

/// Удалённое управление десктопом KumaFlow в LAN.
/// ПК включает «Удалённое управление» (порт 4334, опционально PIN) →
/// здесь «Найден KumaFlow» → управление. Стрелка «назад» = отключение
/// (сессия живёт только пока открыта страница).
class RemoteControlScreen extends StatefulWidget {
  const RemoteControlScreen({super.key});

  @override
  State<RemoteControlScreen> createState() => _RemoteControlScreenState();
}

class _RemoteControlScreenState extends State<RemoteControlScreen> {
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '4334');
  final _pinCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _busy = false;
  String? _formError;
  int _scanDone = 0;
  int _scanTotal = 0;
  bool _seeking = false;
  double _seekValue = 0;
  double? _volLocal;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final d = Provider.of<RemoteDiscovery>(context, listen: false);
        d.startPolling();
        // Автоконнект к последнему устройству — нет: только по тапу,
        // чтобы не дёргать чужой ПК без спроса.
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _pinCtrl.dispose();
    _nameCtrl.dispose();
    try {
      Provider.of<RemoteDiscovery>(context, listen: false).stopPolling();
    } catch (_) {}
    super.dispose();
  }

  Future<bool> _onBack(RemoteClient client) async {
    try {
      await client.disconnect();
    } catch (_) {}
    return true;
  }

  /// Подключение с видимым диагнозом: раньше плитка молчала по 8+ сек.
  /// Диалог показывает этапы (TCP → WebSocket) и точную причину:
  /// фаервол/не тот IP/порт/PIN. Успех закрывает диалог сам (плеер откроется).
  /// Реентрантность: дабл-тап по «Пульт» второй диалог не открывает
  /// (иначе два коннекта рвут друг друга и спиннер вечный).
  bool _connectDlgOpen = false;

  Future<void> _connect(RemoteDevice device, {String pin = ''}) async {
    if (_connectDlgOpen) return;
    _connectDlgOpen = true;
    try {
      await _connectFlow(device, pin: pin);
    } finally {
      _connectDlgOpen = false;
    }
  }

  Future<void> _connectFlow(RemoteDevice device, {String pin = ''}) async {
    final client = Provider.of<RemoteClient>(context, listen: false);
    final discovery =
        Provider.of<RemoteDiscovery>(context, listen: false);
    var dev = device;
    var stage = 'Проверяем ${dev.host}:${dev.port}…';
    String? err;
    bool working = true;
    bool closed = false;
    // Контекст именно диалога: pop по контексту экрана после успеха
    // иногда не срабатывал — диалог оставался со спиннером навсегда
    // (факт 16:38: ws=true, редиректа нет), а closed=true уже гасил
    // watchdog. Дожимаем через контекст диалога + проверка canPop.
    BuildContext? dlgCtx;

    void safePop() {
      final c = dlgCtx;
      if (c == null) return;
      // Диалог уже закрыт (юзером или первым pop) — экран не трогаем,
      // иначе сносим сам пульт + рвём соединение через PopScope.
      try {
        if (!c.mounted) return;
      } catch (_) {
        return;
      }
      try {
        if (Navigator.of(c).canPop()) {
          Navigator.of(c).pop();
          return;
        }
      } catch (_) {}
      try {
        if (mounted) Navigator.pop(context);
      } catch (_) {}
    }

    void fail(StateSetter setDlg, String e) {
      if (closed) return;
      err = e;
      working = false;
      try {
        setDlg(() {});
      } catch (_) {}
    }

    Future<void> run(StateSetter setDlg) async {
      working = true;
      err = null;
      debugPrint('[Remote#$engineId] connect start ${dev.host}:${dev.port} pin=${pin.isEmpty ? 'empty' : 'set'}');
      // Watchdog 30с: зависший await превращается в ошибку с повтором,
      // а не в вечный спиннер (зомби-сокеты, чёрная дыра сети).
      Timer(const Duration(seconds: 30), () {
        // NB: только mounted, НЕ context.mounted — геттер State.context
        // бросает Null check после dispose (краш 12.10.2026, remote).
        if (closed || !working || !mounted) return;
        fail(setDlg,
            'Превышено время ожидания (30с).\n'
            'Сеть глотает пакеты молча: проверь Wi-Fi и фаервол ПК.');
      });
      try {
        // 1) TCP-доступность (тот же порт, иначе соседний 4334/4333).
        stage = 'Проверяем ${dev.host}:${dev.port}…';
        setDlg(() {});
        var ok = await discovery.probe(dev.host, dev.port);
        debugPrint('[Remote#$engineId] probe ${dev.host}:${dev.port} -> $ok');
        if (!mounted || closed) return;
        if (!ok) {
          final alt = await discovery.probeAny(dev.host);
          debugPrint('[Remote#$engineId] probeAny ${dev.host} -> $alt');
          if (!mounted || closed) return;
          if (alt == null) {
            fail(setDlg,
                'ПК ${dev.host} не отвечает по TCP.\n'
                'Проверь:\n'
                '• телефон и ПК в одной Wi-Fi сети;\n'
                '• на ПК управление включено (Настройки → Пульт);\n'
                '• Windows разрешил сеть (фаервол, «частные сети»);\n'
                '• в настройках пульта на ПК выбран LAN-IP, а не localhost.');
            return;
          }
          dev = RemoteDevice(
              name: dev.name,
              host: dev.host,
              port: alt,
              pinRequired: dev.pinRequired,
              lastSeen: dev.lastSeen);
        }
        // 2) WebSocket (внутри свой таймаут 8с + понятная ошибка PIN).
        stage = 'Открываем пульт ${dev.host}:${dev.port}…';
        setDlg(() {});
        final connected = await client.connect(dev, pin: pin);
        debugPrint('[Remote#$engineId] ws connect ${dev.host}:${dev.port} -> $connected err=${client.error}');
        if (!mounted) return;
        if (closed) {
          // Диалог просили закрыть, но он ещё открыт (pop не сработал) —
          // дожимаем, иначе вечный спиннер при живом коннекте.
          safePop();
          return;
        }
        if (connected) {
          // Диалог закрываем СРАЗУ — сохранение в фоне с таймаутом,
          // оно больше не держит UI (вис 13.10.2026: шторка стояла
          // на «Открываем пульт…» при живом соединении).
          closed = true;
          working = false;
          try {
            setDlg(() {});
          } catch (_) {}
          safePop();
          // PIN — только в кейчейн, устройство — без секрета.
          // Флаг pinRequired взводим раз и навсегда: иначе следующий тап
          // по сохранёнке пойдёт с пустым PIN и словит 4401.
          final toSave = (pin.isNotEmpty || dev.pinRequired)
              ? RemoteDevice(
                  name: dev.name,
                  host: dev.host,
                  port: dev.port,
                  pinRequired: true,
                  lastSeen: dev.lastSeen)
              : dev;
          try {
            if (pin.isNotEmpty) {
              await RemotePinStore.write(toSave.id, pin)
                  .timeout(const Duration(seconds: 5));
            }
            await discovery
                .saveDevice(toSave)
                .timeout(const Duration(seconds: 5));
          } catch (_) {}
          try {
            await discovery
                .setLastDevice(toSave)
                .timeout(const Duration(seconds: 5));
          } catch (_) {}
          // NB: второго safePop() здесь НЕТ — первый уже закрыл диалог,
          // а повторный сносил сам экран пульта (мгновенное закрытие
          // плеера + disconnect через PopScope). Если первый pop не
          // сработал, диалог висит с кнопкой «Закрыть», экран цел.
          return;
        }
        final raw = (client.error ?? '').toLowerCase();
        if (raw.contains('4401') || raw.contains('pin')) {
          // 4401 при пустом пине: устройство не знало что нужен PIN (флаг
          // pinRequired=false у найденного/сохранённого) — спрашиваем PIN
          // и повторяем с ним, флаг запоминаем. Иначе честная ошибка.
          if (pin.isEmpty && mounted && !closed) {
            final entered = await _askPin();
            if (entered != null && entered.isNotEmpty) {
              try {
                await discovery.updateDevice(
                  dev.id,
                  RemoteDevice(
                    name: dev.name,
                    host: dev.host,
                    port: dev.port,
                    pinRequired: true,
                    lastSeen: dev.lastSeen,
                  ),
                );
              } catch (_) {}
              try {
                await RemotePinStore.write(dev.id, entered);
              } catch (_) {}
              closed = true;
              safePop();
              await _connectFlow(dev, pin: entered);
              return;
            }
          } else if (pin.isNotEmpty && mounted && !closed) {
            // Сохранённый PIN протух (сменили на ПК): стираем, чтобы не
            // долбить неверным по кругу (клиент ретрай при 4401 запрещает),
            // и даём ввести заново одной итерацией.
            try {
              await RemotePinStore.delete(dev.id);
            } catch (_) {}
            final entered = await _askPin();
            if (entered != null && entered.isNotEmpty) {
              try {
                await RemotePinStore.write(dev.id, entered);
              } catch (_) {}
              closed = true;
              safePop();
              await _connectFlow(dev, pin: entered);
              return;
            }
          }
          fail(setDlg,
              'ПК отклонил подключение: неверный PIN.\n'
              'Посмотри код в настройках пульта на ПК и введи заново.');
        } else {
          fail(setDlg,
              'WebSocket не открылся: ${client.error ?? 'неизвестная ошибка'}.\n'
              'TCP есть, а WS нет — обычно это фаервол Windows или '
              'старый билд ПК без /remote-ws. Обнови exe.');
        }
      } catch (e) {
        fail(setDlg, 'Сбой подключения: $e');
      }
    }

    var started = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (c, setDlg) {
          dlgCtx ??= c;
          if (!started) {
            started = true;
            // run() первый await — до сети, синхронного setState нет.
            run(setDlg);
          }
          return AlertDialog(
            title: Text(dev.name.isEmpty ? dev.host : dev.name),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (working) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(stage,
                      style: const TextStyle(fontSize: 13)),
                ] else if (err != null) ...[
                  Text(err!,
                      style: const TextStyle(fontSize: 13)),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  closed = true;
                  try {
                    client.disconnect();
                  } catch (_) {}
                  Navigator.pop(c);
                },
                child: const Text('Закрыть'),
              ),
              if (!working && err != null)
                FilledButton(
                  onPressed: () => run(setDlg),
                  child: const Text('Повторить'),
                ),
            ],
          );
        },
      ),
    );
    closed = true;
  }

  @override
  Widget build(BuildContext context) {
    final client = context.watch<RemoteClient>();
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          try {
            client.disconnect();
          } catch (_) {}
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: 'Отключиться и выйти',
            onPressed: () async {
              await _onBack(client);
              if (context.mounted) Navigator.pop(context);
            },
          ),
          title: Text(client.isConnected
              ? (client.device?.name ?? 'Пульт')
              : 'Пульт · ПК в сети'),
          actions: [
            if (client.isConnected)
              IconButton(
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'Обновить состояние',
                onPressed: client.refresh,
              ),
          ],
        ),
        body: client.isConnected
            ? _playerBody(context, client)
            : _connectBody(context),
      ),
    );
  }

  // ---------------- подключение ----------------

  Widget _connectBody(BuildContext context) {
    final discovery = context.watch<RemoteDiscovery>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_formError != null)
          Card(
            color: Colors.red.withValues(alpha: 0.12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_formError!,
                  style: const TextStyle(color: Colors.red)),
            ),
          ),
        if (discovery.saved.isNotEmpty) ...[
          const _H('Сохранённые'),
          ...discovery.saved.map((d) => _deviceTile(d, saved: true)),
        ],
        const _H('Найдено в сети'),
        if (discovery.found.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Пока пусто. Включи «Удалённое управление» на ПК (Настройки → Пульт) — придёт само. Либо введи IP вручную.',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
          )
        else
          ...discovery.found.map((d) => _deviceTile(d)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: discovery.isScanning
                    ? null
                    : () => discovery.discover(silent: false),
                icon: discovery.isScanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child:
                            CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.search_rounded),
                label: const Text('Искать (mDNS)'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: discovery.isScanning
                    ? null
                    : () async {
                        setState(() {
                          _scanDone = 0;
                          _scanTotal = 254;
                        });
                        await discovery.scanSubnet(
                            onProgress: (done, total) {
                          if (!mounted) return;
                          setState(() {
                            _scanDone = done;
                            _scanTotal = total;
                          });
                        });
                      },
                icon: const Icon(Icons.radar_rounded),
                label: const Text('Найти в сети'),
              ),
            ),
          ],
        ),
        if (discovery.isScanning && _scanTotal > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(
                value: _scanTotal > 0 ? _scanDone / _scanTotal : null),
          ),
        if (discovery.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(discovery.error!,
                style: const TextStyle(color: Colors.orange, fontSize: 12)),
          ),
        const SizedBox(height: 16),
        const _H('Вручную'),
        TextField(
          controller: _nameCtrl,
          decoration: const InputDecoration(
              labelText: 'Имя (необязательно)', hintText: 'Мой ПК'),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _hostCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'IP', hintText: '192.168.1.42'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _portCtrl,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Порт'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _pinCtrl,
          keyboardType: TextInputType.number,
          obscureText: true,
          decoration: const InputDecoration(
              labelText: 'PIN (если задан на ПК)'),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _connectManual,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.link_rounded),
          label: const Text('Подключиться'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy ? null : _scanQr,
          icon: const Icon(Icons.qr_code_scanner_rounded),
          label: const Text('Сканировать QR с ПК'),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Future<void> _connectManual() async {
    final host = _hostCtrl.text.trim();
    if (host.isEmpty) {
      setState(() => _formError = 'Введи IP адрес ПК');
      return;
    }
    final discovery =
        Provider.of<RemoteDiscovery>(context, listen: false);
    setState(() {
      _busy = true;
      _formError = null;
    });
    try {
      var port = int.tryParse(_portCtrl.text.trim()) ?? 4334;
      var ok = await discovery.probe(host, port);
      if (!ok) {
        // 1.6.6 слушает 4333 — пробуем соседний порт тем же IP.
        final alt = await discovery.probeAny(host);
        if (alt == null) {
          if (!mounted) return;
          setState(() {
            _formError =
                'ПК не отвечает на $host — проверь IP и что управление включено';
            _busy = false;
          });
          return;
        }
        port = alt;
      }
      final name = _nameCtrl.text.trim().isEmpty
          ? host
          : _nameCtrl.text.trim();
      final d = RemoteDevice(name: name, host: host, port: port);
      await _connect(d, pin: _pinCtrl.text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _deviceTile(RemoteDevice d, {bool saved = false}) {
    final discovery =
        Provider.of<RemoteDiscovery>(context, listen: false);
    return Card(
      child: ListTile(
        leading: const Icon(CupertinoIcons.desktopcomputer, size: 26),
        title: Text(d.name.isEmpty ? d.host : d.name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${d.host}:${d.port}'
            '${d.pinRequired ? ' · нужен PIN' : ''}'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (saved) ...[
              IconButton(
                icon: const Icon(Icons.edit_rounded,
                    size: 18, color: Colors.white70),
                tooltip: 'Изменить',
                onPressed: () => _editDevice(d),
              ),
              IconButton(
                icon: const Icon(CupertinoIcons.delete,
                    size: 18, color: Colors.red),
                tooltip: 'Забыть',
                onPressed: () {
                  discovery.forgetDevice(d.id);
                  RemotePinStore.delete(d.id);
                },
              ),
            ],
            FilledButton(
              onPressed: _busy ? null : () => _connectWithPinIfNeeded(d),
              child: const Text('Пульт'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editDevice(RemoteDevice d) async {
    final nameCtrl = TextEditingController(text: d.name);
    final hostCtrl = TextEditingController(text: d.host);
    final portCtrl = TextEditingController(text: d.port.toString());
    final pinCtrl = TextEditingController(text: await RemotePinStore.read(d.id));
    if (!mounted) {
      nameCtrl.dispose();
      hostCtrl.dispose();
      portCtrl.dispose();
      pinCtrl.dispose();
      return;
    }
    final res = await showDialog<RemoteDevice>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Плеер'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameCtrl,
                decoration:
                    const InputDecoration(labelText: 'Имя')),
            const SizedBox(height: 8),
            TextField(
                controller: hostCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'IP')),
            const SizedBox(height: 8),
            TextField(
                controller: portCtrl,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Порт')),
            const SizedBox(height: 8),
            TextField(
                controller: pinCtrl,
                keyboardType: TextInputType.number,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'PIN (пусто — без PIN)')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              final host = hostCtrl.text.trim();
              final port =
                  int.tryParse(portCtrl.text.trim()) ?? d.port;
              if (host.isEmpty || port <= 0 || port > 65535) {
                return;
              }
              Navigator.pop(
                  c,
                  RemoteDevice(
                    name: nameCtrl.text.trim().isEmpty
                        ? host
                        : nameCtrl.text.trim(),
                    host: host,
                    port: port,
                    pinRequired: pinCtrl.text.trim().isNotEmpty ||
                        d.pinRequired,
                    lastSeen: d.lastSeen,
                  ));
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    final newPin = pinCtrl.text.trim();
    nameCtrl.dispose();
    hostCtrl.dispose();
    portCtrl.dispose();
    pinCtrl.dispose();
    if (res == null || !mounted) return;
    try {
      await Provider.of<RemoteDiscovery>(context, listen: false)
          .updateDevice(d.id, res);
      // Перенос PIN на новый id (смена IP/порта) или удаление при пустом.
      if (res.id != d.id) {
        await RemotePinStore.move(d.id, res.id);
      }
      await RemotePinStore.write(res.id, newPin);
    } catch (_) {}
  }

  Future<void> _scanQr() async {
    final raw = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const RemoteQrScanScreen()),
    );
    if (raw == null || raw.trim().isEmpty || !mounted) return;
    final parsed = RemoteDevice.parseQr(raw);
    if (parsed == null) {
      setState(() => _formError =
          'В QR нет адреса ПК — наведи на код из настроек пульта');
      return;
    }
    final discovery =
        Provider.of<RemoteDiscovery>(context, listen: false);
    setState(() {
      _busy = true;
      _formError = null;
    });
    try {
      // Порт из QR приоритетен, иначе подбираем (4334/4333).
      var port = parsed.port;
      if (port <= 0) {
        final found = await discovery.probeAny(parsed.host);
        if (found == null) {
          if (!mounted) return;
          setState(() => _formError =
              'ПК ${parsed.host} не отвечает — проверь, что управление включено');
          return;
        }
        port = found;
      } else {
        final ok = await discovery.probe(parsed.host, port);
        if (!ok) {
          final alt = await discovery.probeAny(parsed.host);
          if (alt == null) {
            if (!mounted) return;
            setState(() => _formError =
                'ПК ${parsed.host}:$port не отвечает — проверь, что управление включено');
            return;
          }
          port = alt;
        }
      }
      final d = RemoteDevice(
          name: parsed.name, host: parsed.host, port: port);
      await _connect(d);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// PIN-диалог пульта (общий для плитки и для ретрая после 4401).
  /// null = отмена/закрыт экран.
  Future<String?> _askPin() async {
    if (!mounted) return null;
    final ctrl = TextEditingController();
    try {
      return await showDialog<String>(
      context: context,
      builder: (c) {
        return AlertDialog(
          title: const Text('PIN пульта'),
          content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            obscureText: true,
            autofocus: true,
            decoration:
                const InputDecoration(hintText: '4–12 цифр с экрана ПК'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Отмена')),
            FilledButton(
                onPressed: () => Navigator.pop(c, ctrl.text.trim()),
                child: const Text('ОК')),
          ],
        );
      },
      );
    } finally {
      ctrl.dispose();
    }
  }

  Future<void> _connectWithPinIfNeeded(RemoteDevice d) async {
    // Сохранённый PIN — первым: тап по знакомому ПК коннектится молча.
    try {
      final saved = await RemotePinStore.read(d.id);
      if (!mounted) return;
      if (saved.isNotEmpty) {
        await _connect(d, pin: saved);
        return;
      }
    } catch (_) {}
    if (!mounted) return;
    if (!d.pinRequired) {
      await _connect(d);
      return;
    }
    final pinCtrl = TextEditingController();
    String? pin;
    try {
      pin = await showDialog<String>(
      context: context,
      builder: (c) {
        return AlertDialog(
          title: const Text('PIN пульта'),
          content: TextField(
            controller: pinCtrl,
            keyboardType: TextInputType.number,
            obscureText: true,
            autofocus: true,
            decoration:
                const InputDecoration(hintText: '4–12 цифр с экрана ПК'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Отмена')),
            FilledButton(
                onPressed: () => Navigator.pop(c, pinCtrl.text.trim()),
                child: const Text('ОК')),
          ],
        );
      },
      );
    } finally {
      pinCtrl.dispose();
    }
    if (pin == null || pin.isEmpty) return;
    await _connect(d, pin: pin);
  }

  // ---------------- плеер (KumaFlow New) ----------------

  /// URL обложки с ДЕСКТОПА: сервер шлёт относительный `/getCoverArt?...`
  /// (прокси с PIN-защитой), абсолютный http — как есть. Старый код пихал
  /// это в SubsonicService телефона и обложки не грузились никогда.
  String _remoteCoverUrl(RemoteDevice? dev, String pin, String coverArt) {
    if (coverArt.isEmpty) return '';
    var u = coverArt;
    if (!u.startsWith('http') && dev != null) {
      u = 'http://${dev.host}:${dev.port}$coverArt';
    }
    if (pin.isNotEmpty && !u.contains('pin=')) {
      final sep = u.contains('?') ? '&' : '?';
      u = '$u${sep}pin=${Uri.encodeComponent(pin)}';
    }
    return u;
  }

  Widget _playerBody(BuildContext context, RemoteClient client) {
    final st = client.state;
    final dev = client.device;
    final coverUrl = _remoteCoverUrl(dev, client.pin, st.coverArt);
    final connecting = client.isConnecting;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Backdrop: блюр обложки + затемнение (как KumaFlow New).
        if (coverUrl.isNotEmpty)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: CachedNetworkImage(
              imageUrl: coverUrl,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: coverUrl.isEmpty ? 0.0 : 0.45),
                Colors.black.withValues(alpha: 0.72),
              ],
            ),
          ),
        ),
        ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            if (!client.isConnected || connecting)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('Переподключаемся…',
                    style: TextStyle(color: Colors.orange, fontSize: 12),
                    textAlign: TextAlign.center),
              ),
            // Статус-строка как в веб-пульте.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                      color: Colors.green, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(
                  dev?.name.isEmpty ?? true
                      ? 'Подключено'
                      : dev!.name,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: Colors.white10,
                  boxShadow: const [
                    BoxShadow(
                        color: Colors.black54,
                        blurRadius: 24,
                        offset: Offset(0, 8))
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: coverUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: coverUrl,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => const Icon(
                            Icons.music_note_rounded,
                            size: 72,
                            color: Colors.white38),
                      )
                    : const Icon(Icons.music_note_rounded,
                        size: 72, color: Colors.white38),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              st.title.isEmpty ? 'Нет трека' : st.title,
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Colors.white),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              [st.artist, st.album].where((e) => e.isNotEmpty).join(' · '),
              style:
                  const TextStyle(fontSize: 14, color: Colors.white60),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(st.positionLabel,
                    style: const TextStyle(
                        fontSize: 12, color: Colors.white54)),
                Expanded(
                  child: Slider(
                    value: _seeking
                        ? _seekValue
                        : st.progress.clamp(
                            0,
                            st.duration > 0
                                ? st.duration.toDouble()
                                : st.progress),
                    max: st.duration > 0 ? st.duration.toDouble() : 1,
                    onChangeStart: (v) {
                      setState(() {
                        _seeking = true;
                        _seekValue = v;
                      });
                    },
                    onChanged: (v) => setState(() => _seekValue = v),
                    onChangeEnd: (v) {
                      setState(() => _seeking = false);
                      client.seek(v);
                    },
                  ),
                ),
                Text(st.durationLabel,
                    style: const TextStyle(
                        fontSize: 12, color: Colors.white54)),
              ],
            ),
            const SizedBox(height: 4),
            // Транспорт как в KumaFlow New: дизлайк | назад | плей | дальше | лайк.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.thumb_down_rounded, size: 26),
                  color: Colors.white70,
                  tooltip: 'Не нравится',
                  onPressed: client.dislike,
                ),
                IconButton(
                  icon:
                      const Icon(Icons.skip_previous_rounded, size: 36),
                  color: Colors.white,
                  onPressed: client.previous,
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: const EdgeInsets.all(18),
                  ),
                  onPressed: client.toggle,
                  child: Icon(
                    st.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: 38,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded, size: 36),
                  color: Colors.white,
                  onPressed: client.next,
                ),
                IconButton(
                  icon: Icon(
                    st.isLiked
                        ? CupertinoIcons.heart_fill
                        : CupertinoIcons.heart,
                    size: 26,
                  ),
                  color: st.isLiked ? Colors.red : Colors.white70,
                  tooltip: 'Нравится',
                  onPressed: client.toggleLike,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    st.isShuffle
                        ? Icons.shuffle_on_rounded
                        : Icons.shuffle_rounded,
                    color:
                        st.isShuffle ? Colors.green : Colors.white70,
                  ),
                  tooltip: 'Перемешать',
                  onPressed: client.toggleShuffle,
                ),
                IconButton(
                  icon: Icon(
                    st.repeatMode == 'one'
                        ? Icons.repeat_one_on_rounded
                        : (st.repeatMode == 'all'
                            ? Icons.repeat_on_rounded
                            : Icons.repeat_rounded),
                    color: st.repeatMode != 'off'
                        ? Colors.green
                        : Colors.white70,
                  ),
                  tooltip: 'Повтор',
                  onPressed: client.cycleRepeat,
                ),
                const Icon(CupertinoIcons.volume_down,
                    size: 18, color: Colors.white54),
                Expanded(
                  child: Slider(
                    value: (_volLocal ??
                            st.volume.clamp(0, 100).toDouble())
                        .clamp(0, 100),
                    max: 100,
                    onChanged: (v) =>
                        setState(() => _volLocal = v),
                    onChangeEnd: (v) {
                      setState(() => _volLocal = null);
                      client.setVolume(v);
                    },
                  ),
                ),
                Text('${st.volume.clamp(0, 100).toInt()}',
                    style: const TextStyle(
                        fontSize: 11, color: Colors.white54)),
                const Icon(CupertinoIcons.volume_up,
                    size: 18, color: Colors.white54),
              ],
            ),
            if (st.queue.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Очередь на ПК',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              ...st.queue.take(20).map((q) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                        (q['title'] ?? q['name'] ?? '').toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                        (q['artist'] ?? q['artist_name'] ?? '')
                            .toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11)),
                  )),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ],
    );
  }
}

class _H extends StatelessWidget {
  final String text;
  const _H(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
      child: Text(text,
          style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white70)),
    );
  }
}
