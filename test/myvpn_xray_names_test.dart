// MyVPN: проверка имён серверов из Xray JSON
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/utils/myvpn_xray_names.dart';

Map<String, dynamic> _vless(String tag, String host) => {
  'tag': tag,
  'protocol': 'vless',
  'settings': {
    'vnext': [
      {'address': host, 'port': 443},
    ],
  },
};

void main() {
  test('теги заменяются на remarks', () {
    final input = jsonEncode([
      {
        'remarks': 'Автовыбор',
        'outbounds': [
          _vless('proxy-1', 'a.example'),
          _vless('proxy-2', 'b.example'),
          {'tag': 'direct', 'protocol': 'freedom'},
        ],
      },
      {
        'remarks': '[WI-FI] Германия',
        'outbounds': [_vless('proxy-3', 'c.example')],
      },
      {
        'remarks': 'Резерв',
        // тот же сервер, что в «Автовыбор» — имя остаётся первым
        'outbounds': [_vless('proxy-9', 'a.example')],
      },
    ]);
    final out = jsonDecode(myNameXrayJson(input)) as List;
    final tags = [
      for (final c in out)
        for (final o in (c as Map)['outbounds'] as List) (o as Map)['tag'],
    ];
    expect(tags, ['Автовыбор [1]', 'Автовыбор [2]', 'direct', '[WI-FI] Германия', 'Автовыбор [1]']);
  });

  test('одинаковые remarks у разных серверов', () {
    final input = jsonEncode([
      {
        'remarks': 'X',
        'outbounds': [_vless('p1', 'a')],
      },
      {
        'remarks': 'X',
        'outbounds': [_vless('p2', 'b')],
      },
    ]);
    final out = jsonDecode(myNameXrayJson(input)) as List;
    expect(((out[1] as Map)['outbounds'] as List).first['tag'], 'X (2)');
  });

  test('не JSON и sing-box остаются как есть', () {
    const links = 'vless://u@1.1.1.1:443#a\nvless://u@2.2.2.2:443#b';
    expect(myNameXrayJson(links), links);
    final singbox = jsonEncode({
      'outbounds': [
        {'type': 'vless', 'tag': 'a', 'server': '1.1.1.1'},
      ],
    });
    expect(myNameXrayJson(singbox), singbox);
  });

  test('чистое имя без нумерации ядра', () {
    expect(myCleanTag('Автовыбор [1] § 3'), 'Автовыбор [1]');
    expect(myCleanTag('🇩🇪 DE | Berlin'), '🇩🇪 DE | Berlin');
  });
}
