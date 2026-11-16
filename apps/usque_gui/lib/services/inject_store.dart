import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/inject_models.dart';

/// Penyimpanan lokal daftar config Xray untuk mode Inject (Fase 2a).
/// Sengaja terpisah dari profil MASQUE agar tidak mengganggu jalur
/// engine yang sudah ada.
abstract final class InjectStore {
  static const _linksKey = 'inject_xray_links_v1';
  static const _selectedKey = 'inject_xray_selected_v1';

  static Future<List<XrayLink>> loadLinks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_linksKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(XrayLink.fromMap)
          .toList(growable: false);
    } on Object {
      return const [];
    }
  }

  static Future<void> saveLinks(List<XrayLink> links) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _linksKey,
      jsonEncode(links.map((link) => link.toMap()).toList()),
    );
  }

  static Future<int> loadSelected() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_selectedKey) ?? -1;
  }

  static Future<void> saveSelected(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_selectedKey, index);
  }

  /// Parse teks impor: banyak link (satu per baris) atau satu blob
  /// subscription base64 berisi banyak link. Link yang gagal di-parse
  /// dilewati diam-diam; pemanggil membandingkan jumlah hasil.
  static List<XrayLink> parseImport(String text) {
    var lines = text
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.length == 1 && !lines.first.contains('://')) {
      try {
        var blob = lines.first.replaceAll('-', '+').replaceAll('_', '/');
        blob = blob.padRight(blob.length + (4 - blob.length % 4) % 4, '=');
        final decoded = utf8.decode(base64.decode(blob));
        if (decoded.contains('://')) {
          lines = decoded
              .split(RegExp(r'\r?\n'))
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty)
              .toList();
        }
      } on Object {
        // Bukan blob base64 yang valid; kembalikan hasil parse apa adanya.
      }
    }
    final links = <XrayLink>[];
    for (final line in lines) {
      final link = XrayLink.tryParse(line);
      if (link != null) links.add(link);
    }
    return links;
  }
}
