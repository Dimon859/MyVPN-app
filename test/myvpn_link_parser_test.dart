// MyVPN: проверка разбора ссылок «Добавить в …» от разных клиентов
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/utils/link_parsers.dart';

void main() {
  const sub = 'https://panel.example.com/sub/AbC123?token=x';

  void expectLink(String link, {String url = sub, String name = ''}) {
    final r = LinkParser.parse(link);
    expect(r, isNotNull, reason: link);
    expect(r!.url, url, reason: link);
    expect(r.name, name, reason: link);
  }

  test('обычная ссылка', () => expectLink(sub));
  test('Happ', () => expectLink('happ://add/$sub'));
  test('Happ с закодированным адресом', () => expectLink('happ://add/${Uri.encodeComponent(sub)}'));
  test('Incy import', () => expectLink('incy://import/$sub'));
  test('Incy add', () => expectLink('incy://add/$sub'));
  test('Streisand с именем', () => expectLink('streisand://import/$sub#My%20VPN', name: 'My VPN'));
  test('Shadowrocket add', () => expectLink('shadowrocket://add/$sub#Name', name: 'Name'));
  test('Shadowrocket sub://', () {
    final b64 = base64Url.encode(utf8.encode(sub)).replaceAll('=', '');
    expectLink('sub://$b64#Name', name: 'Name');
    expectLink('shadowrocket://add/sub://$b64');
  });
  test('Karing', () => expectLink('karing://install-config?url=${Uri.encodeComponent(sub)}&name=K', name: 'K'));
  test('V2Box', () => expectLink('v2box://install-sub?url=${Uri.encodeComponent(sub)}&name=B', name: 'B'));
  test('FoXray', () => expectLink('foxray://yiguo.dev/sub/add/?url=${Uri.encodeComponent(sub)}#F', name: 'F'));
  test('v2rayNG', () => expectLink('v2rayng://install-sub?url=${Uri.encodeComponent(sub)}&name=N', name: 'N'));
  test('sing-box', () => expectLink('sing-box://import-remote-profile?url=${Uri.encodeComponent(sub)}#S', name: 'S'));
  test('Stash', () => expectLink('stash://install-config?url=${Uri.encodeComponent(sub)}'));
  test('hiddify как раньше', () => expectLink('hiddify://install-config?url=${Uri.encodeComponent(sub)}#H', name: 'H'));

  test('зашифрованные ссылки не ломают разбор', () {
    expect(LinkParser.parse('happ://crypt4/AAAABBBB'), isNull);
    expect(LinkParser.parse('incy://crypt1/AAAABBBB'), isNull);
  });

  test('конфиг внутри ссылки Incy', () {
    const cfg = 'vless://uuid@1.2.3.4:443?security=reality#Srv';
    expect(LinkParser.myUnwrapConfig('incy://add/$cfg'), cfg);
    expect(LinkParser.myUnwrapConfig(cfg), cfg);
  });
}
