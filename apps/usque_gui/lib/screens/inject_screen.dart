import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/inject_models.dart';
import '../services/inject_store.dart';
import '../services/xray_config.dart';

/// Pintu masuk mode Inject dari section Proxy (pola yang sama dengan
/// ChainProxyEntry di proxy_screen.dart).
class InjectEntry extends StatelessWidget {
  const InjectEntry({required this.onOpen, super.key});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: const Icon(Icons.bolt_outlined),
        title: const Text('Inject — Xray'),
        subtitle: const Text(
          'Config VLESS / VMess / Trojan / SS (Fase 2a: import & config)',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onOpen,
      ),
    );
  }
}

/// Layar daftar config Xray untuk mode Inject (Fase 2a, lapis 1).
///
/// Yang sudah jalan: import link / subscription, simpan lokal, pilih
/// config aktif, dan hasilkan config JSON Xray yang siap dipakai.
/// Yang belum: menjalankan xray-core native dan mengambil alih TUN —
/// itu langkah berikutnya dan ditandai jujur di UI.
class InjectScreen extends StatefulWidget {
  const InjectScreen({super.key});

  @override
  State<InjectScreen> createState() => _InjectScreenState();
}

class _InjectScreenState extends State<InjectScreen> {
  List<XrayLink> _links = const [];
  int _selected = -1;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final links = await InjectStore.loadLinks();
    final selected = await InjectStore.loadSelected();
    if (!mounted) return;
    setState(() {
      _links = links;
      _selected = selected >= 0 && selected < links.length ? selected : -1;
      _loading = false;
    });
  }

  Future<void> _select(int index) async {
    setState(() => _selected = index);
    await InjectStore.saveSelected(index);
  }

  Future<void> _delete(int index) async {
    final links = [..._links]..removeAt(index);
    var selected = _selected;
    if (selected == index) {
      selected = -1;
    } else if (selected > index) {
      selected -= 1;
    }
    setState(() {
      _links = links;
      _selected = selected;
    });
    await InjectStore.saveLinks(links);
    await InjectStore.saveSelected(selected);
  }

  Future<void> _showImportDialog() async {
    final textController = TextEditingController();
    final imported = await showDialog<List<XrayLink>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Config'),
        content: TextField(
          controller: textController,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText:
                'Tempel link vless:// / vmess:// / trojan:// / ss:// '
                '(satu per baris) atau teks subscription base64…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              ctx,
              InjectStore.parseImport(textController.text),
            ),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (imported == null || !mounted) return;
    if (imported.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tidak ada link valid yang terbaca.')),
      );
      return;
    }
    final links = [..._links, ...imported];
    setState(() => _links = links);
    await InjectStore.saveLinks(links);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${imported.length} config ditambahkan.')),
    );
  }

  void _showConfigJson(XrayLink link) {
    final result = XrayConfig.generate(link);
    final pretty = const JsonEncoder.withIndent('  ').convert(result.config);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(link.remark.isEmpty ? link.address : link.remark),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (result.warnings.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      result.warnings.join('\n'),
                      style: TextStyle(
                        color: Theme.of(ctx).colorScheme.error,
                      ),
                    ),
                  ),
                SelectableText(
                  pretty,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: pretty));
              Navigator.pop(ctx);
            },
            child: const Text('Salin JSON'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Tutup'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inject — Xray'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Import config',
            onPressed: _showImportDialog,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'Fase 2a (lapis 1): import, simpan, dan hasilkan config '
                    'sudah jalan. Menjalankan xray-core native + TUN '
                    'menyusul di langkah berikutnya.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                Expanded(
                  child: _links.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'Belum ada config. Ketuk + untuk import link '
                              'dari panel kamu.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _links.length,
                          itemBuilder: (context, index) {
                            final link = _links[index];
                            final selected = index == _selected;
                            return ListTile(
                              leading: Icon(
                                selected
                                    ? Icons.check_circle
                                    : Icons.circle_outlined,
                              ),
                              title: Text(
                                link.remark.isEmpty
                                    ? '${link.address}:${link.port}'
                                    : link.remark,
                              ),
                              subtitle: Text(
                                '${link.protocol} • ${link.transportType} • '
                                '${link.address}:${link.port}',
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.code),
                                    tooltip: 'Lihat config JSON',
                                    onPressed: () => _showConfigJson(link),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    tooltip: 'Hapus',
                                    onPressed: () => _delete(index),
                                  ),
                                ],
                              ),
                              onTap: () => _select(index),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
