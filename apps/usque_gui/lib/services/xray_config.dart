import '../models/inject_models.dart';

/// Generator config Xray (Fase 2a) dari [XrayLink].
///
/// Menghasilkan config JSON siap jalan untuk xray-core:
/// inbound SOCKS lokal (untuk dialiri tun2socks pada langkah native
/// berikutnya) + satu outbound sesuai protokol link + outbound freedom.
/// Transport yang didukung: ws, httpupgrade, xhttp, grpc, tcp.
/// Keamanan yang didukung: tls dan none. Reality belum — link dengan
/// `security=reality` menghasilkan tlsSettings kosong dan ditandai
/// lewat [XrayConfigResult.warnings] agar UI bisa memperingatkan user.
class XrayConfigResult {
  const XrayConfigResult(this.config, this.warnings);

  final Map<String, dynamic> config;
  final List<String> warnings;
}

abstract final class XrayConfig {
  static XrayConfigResult generate(XrayLink link, {int socksPort = 10808}) {
    final warnings = <String>[];
    final config = <String, dynamic>{
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {
          'tag': 'socks-in',
          'listen': '127.0.0.1',
          'port': socksPort,
          'protocol': 'socks',
          'settings': {'udp': true},
        },
      ],
      'outbounds': [
        _outbound(link, warnings),
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
      'routing': {
        'rules': [
          {'type': 'field', 'inboundTag': ['socks-in'], 'outboundTag': 'proxy'},
        ],
      },
    };
    return XrayConfigResult(config, warnings);
  }

  static Map<String, dynamic> _outbound(
    XrayLink link,
    List<String> warnings,
  ) {
    final outbound = <String, dynamic>{
      'tag': 'proxy',
      'protocol': link.protocol,
      'streamSettings': _streamSettings(link, warnings),
    };
    switch (link.protocol) {
      case 'vless':
        outbound['settings'] = {
          'vnext': [
            {
              'address': link.address,
              'port': link.port,
              'users': [
                {
                  'id': link.id,
                  'encryption': 'none',
                  if (link.flow.isNotEmpty) 'flow': link.flow,
                },
              ],
            },
          ],
        };
      case 'vmess':
        outbound['settings'] = {
          'vnext': [
            {
              'address': link.address,
              'port': link.port,
              'users': [
                {'id': link.id, 'alterId': 0, 'security': 'auto'},
              ],
            },
          ],
        };
      case 'trojan':
        outbound['settings'] = {
          'servers': [
            {'address': link.address, 'port': link.port, 'password': link.id},
          ],
        };
      case 'ss':
        // Pada XrayLink hasil parse ss://, `security` memegang method
        // cipher dan `id` memegang password.
        outbound['settings'] = {
          'servers': [
            {
              'address': link.address,
              'port': link.port,
              'method': link.security.isEmpty ? 'aes-128-gcm' : link.security,
              'password': link.id,
            },
          ],
        };
      default:
        warnings.add('Protokol tidak dikenal: ${link.protocol}');
        outbound['settings'] = {};
    }
    return outbound;
  }

  static Map<String, dynamic> _streamSettings(
    XrayLink link,
    List<String> warnings,
  ) {
    final stream = <String, dynamic>{'network': link.transportType};
    switch (link.transportType) {
      case 'ws':
        stream['wsSettings'] = {
          'path': link.path.isEmpty ? '/' : link.path,
          if (link.host.isNotEmpty) 'headers': {'Host': link.host},
        };
      case 'httpupgrade':
        stream['httpupgradeSettings'] = {
          'path': link.path.isEmpty ? '/' : link.path,
          if (link.host.isNotEmpty) 'host': link.host,
        };
      case 'xhttp':
        stream['xhttpSettings'] = {
          'path': link.path.isEmpty ? '/' : link.path,
          'mode': 'stream-one',
          if (link.host.isNotEmpty) 'host': link.host,
        };
      case 'grpc':
        stream['grpcSettings'] = {'serviceName': link.path};
    }
    if (link.security == 'tls') {
      stream['security'] = 'tls';
      stream['tlsSettings'] = {
        'serverName': link.sni.isNotEmpty
            ? link.sni
            : (link.host.isNotEmpty ? link.host : link.address),
        'fingerprint': 'chrome',
        'alpn': ['h2', 'http/1.1'],
      };
    } else if (link.security == 'reality') {
      warnings.add(
        'Reality belum didukung generator Fase 2a; config dihasilkan '
        'tanpa realitySettings.',
      );
      stream['security'] = 'none';
    } else {
      stream['security'] = 'none';
    }
    return stream;
  }
}
