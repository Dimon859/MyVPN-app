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

  group('фильтры автовыбора', () {
    Map<String, dynamic> srv(String tag, String server, {bool tls = true, bool insecure = false, String type = 'vless'}) => {
      'type': type,
      'tag': tag,
      'server': server,
      'server_port': 443,
      if (tls) 'tls': {'enabled': true, 'insecure': insecure, 'utls': {'enabled': true, 'fingerprint': 'chrome'}},
    };
    final de1 = srv('🇩🇪 DE | Berlin [1.1] § 0', 'a'), de2 = srv('🇩🇪 DE | Berlin [2.1] § 1', 'b');
    final nl = srv('🇳🇱 NL | Amsterdam § 2', 'c');
    final open = srv('🇺🇸 US | Dallas § 3', 'd', tls: false);
    final bad = srv('🇫🇮 FI | Helsinki § 4', 'e', insecure: true);
    final hy = srv('🇩🇪 DE | Hy § 5', 'f', type: 'hysteria2');
    final orig = jsonEncode({'outbounds': [de1, de2, nl, open, bad, hy]});
    List<bool> hiddenOf(String text) => [
      for (final o in (jsonDecode(text) as Map)['outbounds'] as List) ((o as Map)['tag'] as String).contains(myHideMark),
    ];

    test('страны', () {
      expect(hiddenOf(myTransform(orig, const MyTransformOptions(countries: {'🇩🇪'}))!), [false, false, true, true, true, false]);
    });
    test('раздел', () {
      expect(hiddenOf(myTransform(orig, const MyTransformOptions(section: '🇩🇪 DE | Berlin'))!), [false, false, true, true, true, true]);
    });
    test('пропавший раздел не оставляет без серверов', () {
      expect(hiddenOf(myTransform(orig, const MyTransformOptions(section: 'Нет такого'))!).contains(false), isTrue);
    });
    test('небезопасные', () {
      expect(myInsecureReason(open), 'без шифрования');
      expect(myInsecureReason(bad), 'проверка сертификата отключена');
      expect(myInsecureReason(hy), isNull);
      expect(myInsecureReason(de1), isNull);
      expect(hiddenOf(myTransform(orig, const MyTransformOptions(hideInsecure: true))!), [false, false, false, true, true, false]);
    });
    test('отпечаток TLS подменяется, кроме QUIC, и возвращается из копии', () {
      final out = jsonDecode(myTransform(orig, const MyTransformOptions(fingerprint: 'safari'))!) as Map;
      final list = out['outbounds'] as List;
      expect(((list[0] as Map)['tls'] as Map)['utls'], {'enabled': true, 'fingerprint': 'safari'});
      expect(((list[5] as Map)['tls'] as Map)['utls'], {'enabled': true, 'fingerprint': 'chrome'});
      final back = jsonDecode(myTransform(orig, const MyTransformOptions())!) as Map;
      expect((((back['outbounds'] as List)[0] as Map)['tls'] as Map)['utls'], {'enabled': true, 'fingerprint': 'chrome'});
    });
    test('ключ не зависит от отпечатка, старые ключи 1.3.0 тоже узнаются', () {
      final safari = jsonDecode(myTransform(orig, const MyTransformOptions(fingerprint: 'safari'))!) as Map;
      final de1Safari = ((safari['outbounds'] as List)[0] as Map).cast<String, dynamic>();
      expect(myServerKey(de1Safari), myServerKey(de1));
      expect(myHasKey({myLegacyKey(de1)}, de1), isTrue);
      expect(myHasKey({myServerKey(de1)}, de1Safari), isTrue);
    });
    test('имя, раздел, флаг', () {
      expect(myCleanName('🇩🇪 DE | Berlin [1.1] § 0$myHideMark'), '🇩🇪 DE | Berlin [1.1]');
      expect(myGroupKey('🇩🇪 DE | Berlin [1.1]'), '🇩🇪 DE | Berlin');
      expect(myGroupKey('Автовыбор [12]'), 'Автовыбор');
      expect(myFlagOf('🇩🇪 DE | Berlin'), '🇩🇪');
      expect(myFlagOf('Автовыбор'), '');
    });
  });
}

