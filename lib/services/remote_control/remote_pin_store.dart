import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// PIN пульта в системном кейчейне (Keystore/Keychain), по id устройства `host:port`.
/// В SharedPreferences PIN не храним — там только RemoteDevice без секрета.
class RemotePinStore {
  static const _prefix = 'remote_pin_';
  static final _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static String keyFor(String deviceId) =>
      '$_prefix${deviceId.trim()}';

  static Future<String> read(String deviceId) async {
    try {
      return (await _storage.read(key: keyFor(deviceId)))?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> write(String deviceId, String pin) async {
    final p = pin.trim();
    try {
      if (p.isEmpty) {
        await _storage.delete(key: keyFor(deviceId));
      } else {
        await _storage.write(key: keyFor(deviceId), value: p);
      }
    } catch (_) {}
  }

  static Future<void> delete(String deviceId) async {
    try {
      await _storage.delete(key: keyFor(deviceId));
    } catch (_) {}
  }

  /// Старый id `host:oldPort` → новый при смене IP/порта в диалоге правки.
  static Future<void> move(String oldId, String newId) async {
    if (oldId == newId) return;
    try {
      final p = await read(oldId);
      if (p.isNotEmpty) await write(newId, p);
      await delete(oldId);
    } catch (_) {}
  }
}
