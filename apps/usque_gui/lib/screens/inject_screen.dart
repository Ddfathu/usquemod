import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_models.dart';
import '../models/inject_models.dart';
import '../services/inject_store.dart';
import '../services/xray_config.dart';
import '../services/xray_engine.dart';
import '../state/app_controller.dart';

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
        subtitle: const Text('Config VLESS / VMess / Trojan / SS'),
        trailing: const Icon(Icons.chevron_right),
        onTap: onOpen,
      ),
    );
  }
}

/// Layar mode Inject (Fase 2a): daftar config Xray + koneksi VPN.
///
/// Import link/subscription, simpan lokal, pilih config, lalu hubungkan:
/// config JSON digenerate dari link terpilih dan dijalankan oleh
/// XrayVpnService (xray-core native + hev tun2socks). Mode ini eksklusif
/// terhadap MASQUE — tombol konek nonaktif selama MASQUE tersambung.
class InjectScreen extends StatefulWidget {
  const InjectScreen({this.controller, super.key});

  final AppController? controller;

  @override
  State<InjectScreen> createState() => _InjectScreenState();
}

class _InjectScreenState extends State<InjectScreen> {
  List<XrayLink> _links = const [];
  int _selected = -1;
  bool _loading = true;
  bool _xrayRunning = false;
  bool _xrayBusy = false;
  String? _xrayError;
  String _xrayLog = '';
  Timer? _logTimer;

  bool get _masqueActive {
    final phase = widget.controller?.snapshot.phase;
    if (phase == null) return false;
    return phase != ConnectionPhase.disconnected &&
        phase != ConnectionPhase.error;
  }

  XrayLink? get _selectedLink =>
      _selected >= 0 && _selected < _links.length ? _links[_selected] : null;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshXrayStatus();
    _logTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _refreshXrayStatus(),
    );
  }

  @override
  void dispose() {
    _logTimer?.cancel();
    super.dispose();
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

  Future<void> _refreshXrayStatus() async {
    try {
      final status = await XrayEngine.status();
      if (!mounted) return;
      setState(() {
        _xrayRunning = status.running;
        _xrayError = status.error;
        _xrayLog = status.log;
      });
    } on MissingPluginException {
      // Platform tanpa channel Xray (mis. desktop); abaikan.
    } on PlatformException {
      // Channel belum siap; abaikan.
    }
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

  Future<void> _connect() async {
    final link = _selectedLink;
    if (link == null || _xrayBusy) return;
    setState(() {
      _xrayBusy = true;
      _xrayError = null;
    });
    try {
      final granted = await XrayEngine.prepare();
      if (!mounted) return;
      if (!granted) {
        _showSnack('Izin VPN tidak diberikan.');
        return;
      }
      final result = XrayConfig.generate(link);
      final configJson = jsonEncode(result.config);
      final label = link.remark.isEmpty
          ? '${link.protocol} ${link.address}:${link.port}'
          : link.remark;
      await XrayEngine.start(configJson, label);
      if (result.warnings.isNotEmpty && mounted) {
        _showSnack(result.warnings.join(' '));
      }
      // Beri waktu service start (xray + TUN + hev), lalu baca status.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await _refreshXrayStatus();
      if (mounted && _xrayError != null) {
        _showSnack(_xrayError!);
      }
    } on PlatformException catch (error) {
      if (mounted) _showSnack(error.message ?? 'Gagal memulai mode Xray.');
    } finally {
      if (mounted) setState(() => _xrayBusy = false);
    }
  }

  Future<void> _disconnect() async {
    if (_xrayBusy) return;
    setState(() => _xrayBusy = true);
    try {
      await XrayEngine.stop();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _refreshXrayStatus();
    } on PlatformException catch (error) {
      if (mounted) _showSnack(error.message ?? 'Gagal menghentikan mode Xray.');
    } finally {
      if (mounted) setState(() => _xrayBusy = false);
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showImportDialog() async {
    final textController = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Config'),
        content: TextField(
          controller: textController,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText:
                'Tempel URL subscription (mis. /sub panel kamu), atau link '
                'vless:// / vmess:// / trojan:// / ss:// (satu per baris), '
                'atau teks subscription base64…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, textController.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (raw == null || raw.trim().isEmpty || !mounted) return;
    var text = raw;
    if (InjectStore.looksLikeSubscriptionUrl(raw)) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
      try {
        text = await InjectStore.fetchSubscriptionText(
          Uri.parse(raw.trim()),
        );
      } on Object catch (error) {
        if (mounted) {
          Navigator.of(context, rootNavigator: true).pop();
          _showSnack('Gagal mengambil subscription: $error');
        }
        return;
      }
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
    }
    final imported = InjectStore.parseImport(text);
    if (!mounted) return;
    if (imported.isEmpty) {
      _showSnack('Tidak ada link valid yang terbaca.');
      return;
    }
    final links = [..._links, ...imported];
    setState(() => _links = links);
    await InjectStore.saveLinks(links);
    if (!mounted) return;
    _showSnack('${imported.length} config ditambahkan.');
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
                      style: TextStyle(color: Theme.of(ctx).colorScheme.error),
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

  Widget _statusCard(BuildContext context) {
    final theme = Theme.of(context);
    final String statusText;
    if (_xrayRunning) {
      statusText = 'Mode Xray: TERHUBUNG';
    } else if (_xrayError != null) {
      statusText = 'Mode Xray: gagal — $_xrayError';
    } else if (_masqueActive) {
      statusText = 'MASQUE sedang aktif. Putuskan dulu untuk memakai Xray.';
    } else {
      statusText = 'Mode Xray: tidak terhubung';
    }
    final canConnect =
        !_xrayRunning && !_xrayBusy && !_masqueActive && _selectedLink != null;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _xrayRunning ? Icons.check_circle : Icons.circle_outlined,
                  color: _xrayRunning ? Colors.green : null,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(statusText)),
              ],
            ),
            const SizedBox(height: 12),
            if (_xrayRunning)
              FilledButton.icon(
                onPressed: _xrayBusy ? null : _disconnect,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Putuskan'),
              )
            else
              FilledButton.icon(
                onPressed: canConnect ? _connect : null,
                icon: _xrayBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_circle_outline),
                label: Text(
                  _selectedLink == null
                      ? 'Pilih config dulu'
                      : 'Hubungkan config terpilih',
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _logCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.terminal, size: 18),
                const SizedBox(width: 8),
                const Expanded(child: Text('Log Xray')),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: 'Muat ulang log',
                  onPressed: _refreshXrayStatus,
                ),
                IconButton(
                  icon: const Icon(Icons.copy_outlined, size: 20),
                  tooltip: 'Salin log',
                  onPressed: _xrayLog.isEmpty
                      ? null
                      : () async {
                          await Clipboard.setData(
                            ClipboardData(text: _xrayLog),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Log disalin.')),
                            );
                          }
                        },
                ),
              ],
            ),
            Container(
              height: 180,
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                reverse: true,
                child: SelectableText(
                  _xrayLog.isEmpty
                      ? '(log kosong — hubungkan config untuk melihat log)'
                      : _xrayLog,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
          ],
        ),
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: _statusCard(context),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: _logCard(context),
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
