import 'package:flutter/services.dart';

/// Jembatan Dart ke XrayVpnService (Kotlin) untuk mode Inject Fase 2a.
///
/// Channel `com.usque.dfathu/xray` dihandle MainActivity:
/// - `prepare` → izin VpnService (true bila sudah/baru diberikan)
/// - `start`   → mulai service dengan config JSON hasil [XrayConfig]
/// - `stop`    → hentikan service
/// - `status`  → {running: bool, error: String?}
abstract final class XrayEngine {
  static const MethodChannel _channel = MethodChannel('com.usque.dfathu/xray');

  static Future<bool> prepare() async {
    final granted = await _channel.invokeMethod<bool>('prepare');
    return granted ?? false;
  }

  static Future<void> start(String configJson, String label) async {
    await _channel.invokeMethod<void>('start', {
      'config': configJson,
      'label': label,
    });
  }

  static Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
  }

  static Future<({bool running, String? error})> status() async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('status');
    if (raw == null) return (running: false, error: null);
    return (running: raw['running'] == true, error: raw['error'] as String?);
  }
}
