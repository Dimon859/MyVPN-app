// MyVPN: проверка превращения серверов sing-box в ссылки
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/profile/widget/myvpn_share_links.dart';
import 'package:hiddify/utils/link_parsers.dart';

void main() {
  test('VLESS Reality gRPC', () {
    final link = myOutboundToLink({
      'type': 'vless',
      'tag': '🇩🇪 DE | Berlin [1.1]',
      'server': '1.2.3.4',
      'server_port': 443,
      'uuid': 'abc-123',
      'flow': '',
      'tls': {
        'enabled': true,
        'server_name': 'www.example.com',
        'utls': {'enabled': true, 'fingerprint': 'chrome'},
        'reality': {'enabled': true, 'public_key': 'PBK', 'short_id': 'ab12'},
      },
      'transport': {'type': 'grpc', 'service_name': 'svc'},
    })!;
    final uri = Uri.parse(link);
    expect(uri.scheme, 'vless');
    expect(uri.userInfo, 'abc-123');
    expect(uri.host, '1.2.3.4');
    expect(uri.port, 443);
    expect(uri.queryParameters['type'], 'grpc');
    expect(uri.queryParameters['serviceName'], 'svc');
    expect(uri.queryParameters['security'], 'reality');
    expect(uri.queryParameters['pbk'], 'PBK');
    expect(uri.queryParameters['sid'], 'ab12');
    expect(uri.queryParameters['sni'], 'www.example.com');
    expect(uri.queryParameters['fp'], 'chrome');
    expect(uri.queryParameters.containsKey('flow'), isFalse);
    expect(Uri.decodeComponent(uri.fragment), '🇩🇪 DE | Berlin [1.1]');
  });

  test('VLESS WS TLS', () {
    final uri = Uri.parse(myOutboundToLink({
      'type': 'vless',
      'tag': 'x',
      'server': 'host.example',
      'server_port': 8443,
      'uuid': 'u',
      'tls': {'enabled': true, 'server_name': 'host.example', 'alpn': ['h2', 'http/1.1']},
      'transport': {'type': 'ws', 'path': '/ws?ed=2048', 'headers': {'Host': 'cdn.example'}},
    })!);
    expect(uri.queryParameters['type'], 'ws');
    expect(uri.queryParameters['path'], '/ws?ed=2048');
    expect(uri.queryParameters['host'], 'cdn.example');
    expect(uri.queryParameters['security'], 'tls');
    expect(uri.queryParameters['alpn'], 'h2,http/1.1');
  });

  test('Hysteria2 с obfs', () {
    final uri = Uri.parse(myOutboundToLink({
      'type': 'hysteria2',
      'tag': 'hy',
      'server': '5.6.7.8',
      'server_port': 8443,
      'password': 'p@ss',
      'obfs': {'type': 'salamander', 'password': 'ob'},
      'tls': {'enabled': true, 'server_name': 'sni.example', 'insecure': true},
    })!);
    expect(uri.scheme, 'hysteria2');
    expect(Uri.decodeComponent(uri.userInfo), 'p@ss');
    expect(uri.queryParameters['obfs'], 'salamander');
    expect(uri.queryParameters['obfs-password'], 'ob');
    expect(uri.queryParameters['insecure'], '1');
    expect(uri.queryParameters.containsKey('security'), isFalse);
  });

  test('VMess', () {
    final link = myOutboundToLink({
      'type': 'vmess',
      'tag': 'vm',
      'server': '9.9.9.9',
      'server_port': 80,
      'uuid': 'id',
      'transport': {'type': 'ws', 'path': '/p'},
    })!;
    final json = jsonDecode(utf8.decode(base64.decode(link.substring('vmess://'.length)))) as Map;
    expect(json['add'], '9.9.9.9');
    expect(json['port'], '80');
    expect(json['net'], 'ws');
    expect(json['path'], '/p');
    expect(json['ps'], 'vm');
  });

  test('Shadowsocks и IPv6', () {
    final link = myOutboundToLink({
      'type': 'shadowsocks',
      'tag': 'ss',
      'server': '2001:db8::1',
      'server_port': 8388,
      'method': 'aes-128-gcm',
      'password': 'pw',
    })!;
    expect(link.startsWith('ss://'), isTrue);
    expect(link.contains('@[2001:db8::1]:8388'), isTrue);
  });

  test('WireGuard — без ссылки', () {
    expect(myOutboundToLink({'type': 'wireguard', 'tag': 'wg'}), isNull);
  });

  test('ссылка VLESS снова читается приложением как сервер, а не подписка', () {
    final link = myOutboundToLink({'type': 'vless', 'tag': 't', 'server': '1.1.1.1', 'server_port': 443, 'uuid': 'u'})!;
    expect(LinkParser.parse(link), isNull);
  });
}
