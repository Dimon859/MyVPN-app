// MyVPN: исключение серверов из автовыбора
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/profile/data/myvpn_marks.dart';

Map<String, dynamic> _o(String tag, String server, {String? detour}) => {
  'type': 'vless',
  'tag': tag,
  'server': server,
  'server_port': 443,
  'detour': ?detour,
};

List<String> _tags(String text) => [
  for (final o in (jsonDecode(text) as Map)['outbounds'] as List) (o as Map)['tag'] as String,
];

void main() {
  final a = _o('A', '1.1.1.1'), b = _o('B', '2.2.2.2'), c = _o('C', '3.3.3.3', detour: 'B');
  final text = jsonEncode({
    'outbounds': [a, b, c, {'type': 'selector', 'tag': 'G', 'outbounds': ['A', 'B']}],
  });

  test('ключ не зависит от имени', () {
    expect(myServerKey(a), myServerKey({...a, 'tag': 'другое имя'}));
    expect(myServerKey(a) == myServerKey(b), isFalse);
  });

  test('исключённый сервер получает метку, ссылки обновляются', () {
    final out = myApplyHidden(text, {myServerKey(b)})!;
    expect(_tags(out), ['A', 'B$myHideMark', 'C', 'G']);
    final json = jsonDecode(out) as Map;
    expect(((json['outbounds'] as List)[2] as Map)['detour'], 'B$myHideMark');
    expect(((json['outbounds'] as List)[3] as Map)['outbounds'], ['A', 'B$myHideMark']);
  });

  test('метка снимается, когда сервер вернули', () {
    final hidden = myApplyHidden(text, {myServerKey(b)})!;
    final back = myApplyHidden(hidden, {})!;
    expect(_tags(back), ['A', 'B', 'C', 'G']);
    expect(myApplyHidden(back, {}), isNull);
  });

  test('хотя бы один сервер остаётся', () {
    final all = {myServerKey(a), myServerKey(b), myServerKey(c)};
    final out = myApplyHidden(text, all)!;
    expect(_tags(out).take(3).where((t) => !t.contains('§hide§')).length, 1);
  });
}
