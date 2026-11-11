// MyVPN: сервер из подписки (sing-box JSON) → ссылка vless://, vmess://, trojan://, hysteria2://, ss://, tuic://
import 'dart:convert';

String _host(Object? s) {
  final h = (s ?? '').toString();
  return h.contains(':') && !h.startsWith('[') ? '[$h]' : h;
}

String _enc(String s) => Uri.encodeComponent(s);

String _query(Map<String, Object?> p) {
  final parts = <String>[];
  p.forEach((k, v) {
    if (v == null) return;
    final s = v is List ? v.join(',') : v.toString();
    if (s.isEmpty) return;
    parts.add('$k=${Uri.encodeQueryComponent(s)}');
  });
  return parts.isEmpty ? '' : '?${parts.join('&')}';
}

Map<String, dynamic> _map(Object? v) => v is Map<String, dynamic> ? v : const {};

/// Параметры транспорта и TLS в виде, как в ссылках Xray.
Map<String, Object?> _common(Map<String, dynamic> o, {bool withTransport = true}) {
  final p = <String, Object?>{};
  if (withTransport) {
    final tr = _map(o['transport']);
    final type = (tr['type'] ?? 'tcp').toString();
    switch (type) {
      case 'ws':
        p['type'] = 'ws';
        p['path'] = tr['path'];
        p['host'] = _map(tr['headers'])['Host'];
      case 'grpc':
        p['type'] = 'grpc';
        p['serviceName'] = tr['service_name'];
      case 'http':
        p['type'] = 'http';
        p['path'] = tr['path'];
        p['host'] = tr['host'];
      case 'httpupgrade':
        p['type'] = 'httpupgrade';
        p['path'] = tr['path'];
        p['host'] = tr['host'];
      case 'xhttp':
        p['type'] = 'xhttp';
        p['path'] = tr['path'];
        p['host'] = tr['host'];
        p['mode'] = tr['mode'];
      default:
        p['type'] = 'tcp';
    }
  }
  final tls = _map(o['tls']);
  if (tls['enabled'] == true) {
    final reality = _map(tls['reality']);
    p['security'] = reality['enabled'] == true ? 'reality' : 'tls';
    p['sni'] = tls['server_name'];
    p['alpn'] = tls['alpn'];
    p['fp'] = _map(tls['utls'])['fingerprint'];
    if (reality['enabled'] == true) {
      p['pbk'] = reality['public_key'];
      p['sid'] = reality['short_id'];
    }
    if (tls['insecure'] == true) p['allowInsecure'] = '1';
  } else if (withTransport) {
    p['security'] = 'none';
  }
  return p;
}

/// Ссылка на сервер или null, если для этого типа ссылок не бывает (например WireGuard).
String? myOutboundToLink(Map<String, dynamic> o) {
  final type = (o['type'] ?? '').toString();
  final name = _enc((o['tag'] ?? '').toString());
  final server = _host(o['server']);
  final port = o['server_port'] ?? 443;
  switch (type) {
    case 'vless':
      final p = _common(o)..['encryption'] = 'none';
      p['flow'] = o['flow'];
      return 'vless://${o['uuid']}@$server:$port${_query(p)}#$name';
    case 'trojan':
      return 'trojan://${_enc((o['password'] ?? '').toString())}@$server:$port${_query(_common(o))}#$name';
    case 'vmess':
      final p = _common(o);
      final json = <String, Object?>{
        'v': '2',
        'ps': o['tag'],
        'add': o['server'],
        'port': '$port',
        'id': o['uuid'],
        'aid': '${o['alter_id'] ?? 0}',
        'scy': o['security'] ?? 'auto',
        'net': p['type'],
        'type': 'none',
        'host': p['host'] ?? '',
        'path': p['type'] == 'grpc' ? (p['serviceName'] ?? '') : (p['path'] ?? ''),
        'tls': p['security'] == 'none' ? '' : p['security'],
        'sni': p['sni'] ?? '',
        'alpn': p['alpn'] is List ? (p['alpn']! as List).join(',') : (p['alpn'] ?? ''),
        'fp': p['fp'] ?? '',
      };
      return 'vmess://${base64.encode(utf8.encode(jsonEncode(json)))}';
    case 'hysteria2':
      final p = _common(o, withTransport: false)..remove('security');
      final obfs = _map(o['obfs']);
      if (obfs['type'] != null) {
        p['obfs'] = obfs['type'];
        p['obfs-password'] = obfs['password'];
      }
      if (p.remove('allowInsecure') != null) p['insecure'] = '1';
      return 'hysteria2://${_enc((o['password'] ?? '').toString())}@$server:$port${_query(p)}#$name';
    case 'tuic':
      final p = _common(o, withTransport: false)..remove('security');
      p['congestion_control'] = o['congestion_control'];
      p['udp_relay_mode'] = o['udp_relay_mode'];
      if (p.remove('allowInsecure') != null) p['allow_insecure'] = '1';
      return 'tuic://${o['uuid']}:${_enc((o['password'] ?? '').toString())}@$server:$port${_query(p)}#$name';
    case 'shadowsocks':
      final user = base64Url.encode(utf8.encode('${o['method']}:${o['password']}')).replaceAll('=', '');
      final plugin = (o['plugin'] ?? '').toString();
      final opts = (o['plugin_opts'] ?? '').toString();
      final q = plugin.isEmpty ? '' : '?plugin=${Uri.encodeQueryComponent(opts.isEmpty ? plugin : '$plugin;$opts')}';
      return 'ss://$user@$server:$port$q#$name';
    default:
      return null;
  }
}

/// Красиво оформленный JSON сервера.
String myPrettyJson(Map<String, dynamic> o) => const JsonEncoder.withIndent('  ').convert(o);
