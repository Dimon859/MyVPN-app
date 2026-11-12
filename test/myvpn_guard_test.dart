// MyVPN: детекторы в фильтре автовыбора, протоколы по сетям, подозрительные обновления подписки
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/profile/data/myvpn_marks.dart';

Map<String, dynamic> vless(String tag, String host, {bool reality = true}) => {
  'type': 'vless',
  'tag': tag,
  'server': host,
  'server_port': 443,
  'uuid': 'u',
  'tls': {
    'enabled': true,
    'server_name': 'ya.ru',
    if (reality) 'reality': {'enabled': true, 'public_key': 'k'},
  },
};

Map<String, dynamic> hy2(String tag, String host) => {
  'type': 'hysteria2',
  'tag': tag,
  'server': host,
  'server_port': 443,
  'password': 'p',
  'tls': {'enabled': true, 'server_name': 'x.com'},
};

Map<String, dynamic> ss(String tag, String host) => {
  'type': 'shadowsocks',
  'tag': tag,
  'server': host,
  'server_port': 8388,
  'method': 'none',
  'password': 'p',
};

void main() {
  test('протокол сервера', () {
    expect(myProtoOf(vless('a', '1.1.1.1')), 'Reality');
    expect(myProtoOf(vless('a', '1.1.1.1', reality: false)), 'VLESS');
    expect(myProtoOf(hy2('a', '1.1.1.1')), 'Hysteria2');
    expect(myProtoOf(ss('a', '1.1.1.1')), 'Shadowsocks');
  });

  test('детекторы и протоколы убирают сервер из автовыбора', () {
    final a = vless('🇳🇱 A', '1.1.1.1');
    final b = hy2('🇩🇪 B', '2.2.2.2');
    final bad = {myServerKey(a): '🧊 замирает после 16 КБ'};
    expect(myHiddenReason(a, MyTransformOptions(bad: bad)), '🧊 замирает после 16 КБ');
    expect(myHiddenReason(b, MyTransformOptions(bad: bad)), isNull);
    final onlyReality = MyTransformOptions(allowTypes: {'Reality'});
    expect(myHiddenReason(a, onlyReality), isNull);
    expect(myHiddenReason(b, onlyReality), 'протокол не для этой сети');
  });

  String sub(List<Map<String, dynamic>> s) => jsonEncode({'outbounds': s});

  test('обычное обновление не подозрительно', () {
    final old = [for (var i = 0; i < 10; i++) vless('🇳🇱 S$i', '10.0.0.$i')];
    final upd = [...old.take(8), vless('🇳🇱 N1', '10.1.0.1'), vless('🇳🇱 N2', '10.1.0.2')];
    expect(myCompareUpdate(sub(old), sub(upd)), isNull);
  });

  test('сменились почти все серверы', () {
    final old = [for (var i = 0; i < 10; i++) vless('🇳🇱 S$i', '10.0.0.$i')];
    final upd = [for (var i = 0; i < 10; i++) vless('🇳🇱 X$i', '10.9.0.$i')];
    expect(myCompareUpdate(sub(old), sub(upd)), contains('сменились почти все'));
  });

  test('появились незащищённые и серверы из новых стран', () {
    final old = [for (var i = 0; i < 6; i++) vless('🇳🇱 S$i', '10.0.0.$i')];
    final upd = [...old, for (var i = 0; i < 8; i++) {...vless('🇨🇳 Z$i', '10.5.0.$i'), 'tls': {'enabled': false}}];
    final r = myCompareUpdate(sub(old), sub(upd))!;
    expect(r, contains('без защиты'));
    expect(r, contains('новых стран'));
  });

  test('маленькие подписки не проверяются', () {
    expect(myCompareUpdate(sub([vless('a', '1.1.1.1')]), sub([hy2('b', '2.2.2.2')])), isNull);
  });
}
