// MyVPN: режимы Правила / Глобально / Напрямую
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/connections/myvpn_connections.dart';
import 'package:hiddify/features/route_rules/notifier/rules_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';

void main() {
  List<Rule> rules() => [
    BuiltinRule.bypassLan.rule..name = BuiltinRule.bypassLan.key..listOrder = 0..enabled = true,
    BuiltinRule.systemDirect.rule..name = BuiltinRule.systemDirect.key..listOrder = 1..enabled = true,
    BuiltinRule.applePushVpn.rule..name = BuiltinRule.applePushVpn.key..listOrder = 2..enabled = true,
    Rule(name: 'реклама', outbound: Outbound.block, domainSuffixes: ['ads.example'], listOrder: 3, enabled: true),
    Rule(name: 'мой сайт', outbound: Outbound.direct, domainSuffixes: ['ya.ru'], listOrder: 4, enabled: true),
  ];

  test('Правила — без изменений', () {
    expect(myRulesForMode(rules(), 'rule').map((r) => r.name), rules().map((r) => r.name));
  });

  test('Глобально — убраны все «напрямую», кроме локальной сети', () {
    final names = myRulesForMode(rules(), 'global').map((r) => r.name).toList();
    expect(names, [BuiltinRule.bypassLan.key, BuiltinRule.applePushVpn.key, 'реклама']);
  });

  test('Напрямую — два правила в начале, ловят всё', () {
    final r = myRulesForMode(rules(), 'direct');
    expect(r.length, rules().length + 2);
    expect(r[0].outbound, Outbound.direct);
    expect(r[0].domainRegexes, ['.*']);
    expect(r[1].portRanges, ['0:65535']);
    expect([for (final x in r) x.listOrder], [0, 1, 2, 3, 4, 5, 6]);
  });
}
