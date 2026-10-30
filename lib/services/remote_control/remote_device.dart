import 'dart:convert';

/// Десктоп KumaFlow в LAN с включённым «Удалённым управлением»
/// (WebSocket `ws://host:4334/remote-ws`, см. remote-control.ts).
class RemoteDevice {
  final String name;
  final String host;
  final int port;
  final bool pinRequired;
  DateTime lastSeen;

  RemoteDevice({
    required this.name,
    required this.host,
    required this.port,
    this.pinRequired = false,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  String get id => '$host:$port';
  String get wsBase => 'ws://$host:$port/remote-ws';

  String wsUrl({String pin = ''}) {
    final p = pin.trim();
    if (p.isEmpty) return wsBase;
    return '$wsBase?pin=${Uri.encodeComponent(p)}';
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'host': host,
        'port': port,
        'pinRequired': pinRequired,
      };

  factory RemoteDevice.fromJson(Map<String, dynamic> j) => RemoteDevice(
        name: (j['name'] ?? '').toString(),
        host: (j['host'] ?? '').toString(),
        port: (j['port'] is num)
            ? (j['port'] as num).toInt()
            : int.tryParse('${j['port']}') ?? 4334,
        pinRequired: j['pinRequired'] == true,
      );

  static String encodeList(List<RemoteDevice> ds) =>
      jsonEncode(ds.map((d) => d.toJson()).toList());
  static List<RemoteDevice> decodeList(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! List) return const [];
      return j
          .whereType<Map>()
          .map((e) => RemoteDevice.fromJson(Map<String, dynamic>.from(e)))
          .where((d) => d.host.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Разбор QR с экрана ПК: `http://192.168.1.42:4334` (connectionUrl),
  /// также терпим `ws://`, голый `host:port`, путь/query игнорируем.
  /// Порт 0 = не указан → вызывающий подберёт через probe (4334/4333).
  static RemoteDevice? parseQr(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    // Первый токен: QR может содержать пробелы/переносы.
    s = s.split(RegExp(r'\s+')).firstWhere((e) => e.isNotEmpty,
        orElse: () => '');
    if (s.isEmpty) return null;
    if (!s.contains('://')) s = 'http://$s';
    Uri? u;
    try {
      u = Uri.parse(s);
    } catch (_) {
      return null;
    }
    final host = u.host.trim();
    if (host.isEmpty || host == 'localhost') return null;
    final port = u.hasPort ? u.port : 0;
    return RemoteDevice(name: host, host: host, port: port);
  }
}
