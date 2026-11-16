import 'dart:convert';

/// Fondasi Fase 2: model data untuk mode Inject (Xray & SSH) dan sistem
/// payload. File ini murni model + parser, belum terhubung ke UI atau
/// engine mana pun — lihat docs/xray-ssh-payload-design.md untuk rencana
/// integrasinya. Semua parser mengembalikan null saat gagal, tidak throw.

/// Mode mesin yang memiliki TUN. Android hanya mengizinkan satu
/// VpnService aktif, jadi ketiganya saling eksklusif.
enum InjectMode { masque, xray, ssh }

/// Cara koneksi inject dibuka.
enum InjectMethod {
  /// Langsung ke server (WS/TLS polos tanpa payload kustom).
  direct,

  /// Payload HTTP dikirim lebih dulu, lalu upgrade WebSocket bersih.
  payloadWebSocket,

  /// Payload dikirim di dalam TLS dengan SNI bug host.
  payloadTls,

  /// Satu/lebih blok payload umpan (decoy) dikirim sebelum request asli,
  /// dengan opsi kirim terpisah ([split]) dan jeda ([delay]). Cerminan di
  /// sisi klien dari gateway filter ws-proxy.js / ws-xray.js di server.
  payloadEnhanced,
}

/// Hasil parse link Xray: vless://, vmess://, trojan://, ss://.
class XrayLink {
  const XrayLink({
    required this.protocol,
    required this.address,
    required this.port,
    required this.id,
    this.security = '',
    this.transportType = 'tcp',
    this.host = '',
    this.path = '',
    this.sni = '',
    this.flow = '',
    this.remark = '',
  });

  /// 'vless' | 'vmess' | 'trojan' | 'ss'
  final String protocol;
  final String address;
  final int port;

  /// UUID (vless/vmess) atau password (trojan/ss).
  final String id;

  /// '', 'tls', 'reality', 'none'
  final String security;

  /// 'ws' | 'grpc' | 'xhttp' | 'httpupgrade' | 'tcp'
  final String transportType;
  final String host;
  final String path;
  final String sni;
  final String flow;
  final String remark;

  static XrayLink? tryParse(String raw) {
    final input = raw.trim();
    if (input.startsWith('vmess://')) return _parseVmess(input);
    if (input.startsWith('vless://')) return _parseUriForm(input, 'vless');
    if (input.startsWith('trojan://')) return _parseUriForm(input, 'trojan');
    if (input.startsWith('ss://')) return _parseSs(input);
    return null;
  }

  static XrayLink? _parseUriForm(String input, String protocol) {
    final Uri uri;
    try {
      uri = Uri.parse(input);
    } on FormatException {
      return null;
    }
    if (uri.host.isEmpty || uri.port == 0 || uri.userInfo.isEmpty) {
      return null;
    }
    final params = uri.queryParameters;
    return XrayLink(
      protocol: protocol,
      address: uri.host,
      port: uri.port,
      id: Uri.decodeComponent(uri.userInfo),
      security: params['security'] ?? '',
      transportType: params['type'] ?? 'tcp',
      host: params['host'] ?? '',
      path: params['path'] ?? '',
      sni: params['sni'] ?? params['peer'] ?? '',
      flow: params['flow'] ?? '',
      remark: uri.fragment.isEmpty
          ? ''
          : Uri.decodeComponent(uri.fragment),
    );
  }

  static XrayLink? _parseVmess(String input) {
    try {
      var body = input.substring('vmess://'.length).trim();
      body = body.replaceAll('-', '+').replaceAll('_', '/');
      body = body.padRight(body.length + (4 - body.length % 4) % 4, '=');
      final decoded = utf8.decode(base64.decode(body));
      final map = jsonDecode(decoded);
      if (map is! Map<String, dynamic>) return null;
      final port = int.tryParse('${map['port'] ?? ''}') ?? 0;
      final address = '${map['add'] ?? ''}';
      final id = '${map['id'] ?? ''}';
      if (address.isEmpty || port == 0 || id.isEmpty) return null;
      return XrayLink(
        protocol: 'vmess',
        address: address,
        port: port,
        id: id,
        security: '${map['tls'] ?? ''}',
        transportType: '${map['net'] ?? 'tcp'}',
        host: '${map['host'] ?? ''}',
        path: '${map['path'] ?? ''}',
        sni: '${map['sni'] ?? ''}',
        remark: '${map['ps'] ?? ''}',
      );
    } on Object {
      return null;
    }
  }

  static XrayLink? _parseSs(String input) {
    // Bentuk SIP002: ss://base64(method:password)@host:port#remark
    try {
      final uri = Uri.parse(input);
      if (uri.host.isEmpty || uri.port == 0) return null;
      var userInfo = uri.userInfo;
      if (!userInfo.contains(':')) {
        var body = userInfo.replaceAll('-', '+').replaceAll('_', '/');
        body = body.padRight(
          userInfo.length + (4 - userInfo.length % 4) % 4,
          '=',
        );
        userInfo = utf8.decode(base64.decode(body));
      }
      final sep = userInfo.indexOf(':');
      if (sep < 0) return null;
      return XrayLink(
        protocol: 'ss',
        address: uri.host,
        port: uri.port,
        id: userInfo.substring(sep + 1),
        security: userInfo.substring(0, sep),
        remark: uri.fragment.isEmpty
            ? ''
            : Uri.decodeComponent(uri.fragment),
      );
    } on Object {
      return null;
    }
  }

  Map<String, dynamic> toMap() => {
    'protocol': protocol,
    'address': address,
    'port': port,
    'id': id,
    'security': security,
    'transport_type': transportType,
    'host': host,
    'path': path,
    'sni': sni,
    'flow': flow,
    'remark': remark,
  };

  factory XrayLink.fromMap(Map<String, dynamic> map) {
    return XrayLink(
      protocol: '${map['protocol'] ?? ''}',
      address: '${map['address'] ?? ''}',
      port: (map['port'] as num?)?.toInt() ?? 0,
      id: '${map['id'] ?? ''}',
      security: '${map['security'] ?? ''}',
      transportType: '${map['transport_type'] ?? 'tcp'}',
      host: '${map['host'] ?? ''}',
      path: '${map['path'] ?? ''}',
      sni: '${map['sni'] ?? ''}',
      flow: '${map['flow'] ?? ''}',
      remark: '${map['remark'] ?? ''}',
    );
  }
}

/// Akun SSH untuk mode SSH (tunnel -D / SOCKS lokal + payload opsional).
class SshAccount {
  const SshAccount({
    required this.host,
    required this.username,
    this.port = 22,
    this.password = '',
    this.payload = '',
    this.sniHost = '',
    this.method = InjectMethod.direct,
  });

  final String host;
  final int port;
  final String username;
  final String password;

  /// Template payload mentah (dengan placeholder [host] dsb.), kosong
  /// berarti tanpa payload.
  final String payload;

  /// Bug host untuk SNI saat method payloadTls / payloadEnhanced+TLS.
  final String sniHost;
  final InjectMethod method;

  Map<String, dynamic> toMap() => {
    'host': host,
    'port': port,
    'username': username,
    'password': password,
    'payload': payload,
    'sni_host': sniHost,
    'method': method.name,
  };

  factory SshAccount.fromMap(Map<String, dynamic> map) {
    return SshAccount(
      host: '${map['host'] ?? ''}',
      port: (map['port'] as num?)?.toInt() ?? 22,
      username: '${map['username'] ?? ''}',
      password: '${map['password'] ?? ''}',
      payload: '${map['payload'] ?? ''}',
      sniHost: '${map['sni_host'] ?? ''}',
      method: InjectMethod.values.asNameMap()[map['method']] ??
          InjectMethod.direct,
    );
  }
}

/// Pembangun payload bergaya HTTP Injector.
///
/// Placeholder yang diganti saat build:
/// [method] [host] [host_port] [protocol] [crlf] [lf] [crf]
///
/// Placeholder yang SENGAJA dibiarkan saat build karena merupakan
/// perintah saat pengiriman, bukan isi: [split] dan [delay].
class PayloadTemplate {
  static String build(
    String template, {
    required String host,
    required int port,
    String method = 'CONNECT',
  }) {
    return template
        .replaceAll('[host_port]', '$host:$port')
        .replaceAll('[host]', host)
        .replaceAll('[method]', method)
        .replaceAll('[protocol]', 'HTTP/1.1')
        .replaceAll('[crlf]', '\r\n')
        .replaceAll('[lf]', '\n')
        .replaceAll('[crf]', '\r');
  }

  /// Pecah payload hasil build pada penanda [split]; setiap segmen
  /// dikirim terpisah oleh lapisan transport (dengan jeda bila ada
  /// penanda [delay] di awal segmen berikutnya).
  static List<String> splitSegments(String built) {
    return built
        .split('[split]')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
  }
}
