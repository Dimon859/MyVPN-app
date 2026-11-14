// MyVPN: импорт правил из других клиентов
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/route_rules/myvpn_rule_import.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';
import 'package:hiddify/utils/myvpn_xray_names.dart';

const happLink = 'happ://routing/add/eyJEaXJlY3RJcCI6WyIxMC4wLjAuMC84IiwiMTAwLjY0LjAuMC8xMCIsIjE3Mi4xNi4wLjAvMTIiLCIxOTIuMTY4LjAuMC8xNiIsIjE2OS4yNTQuMC4wLzE2IiwiMjI0LjAuMC4wLzQiLCIyNTUuMjU1LjI1NS4yNTUiLCJnZW9pcDpwcml2YXRlIl0sIlByb3h5SXAiOltdLCJCbG9ja0lwIjpbXSwiRmFrZURucyI6ZmFsc2UsIlByb3h5U2l0ZXMiOlsiZG9tYWluX3N1ZmZpeDpkcml2ZTIucnUiLCJkb21haW5fc3VmZml4OmRyaXZlMi5hcHAiLCJkb21haW5fc3VmZml4OmRyaXZlMi5uZXQiLCJkb21haW5fc3VmZml4OmQyLnJ1IiwiZG9tYWluX3N1ZmZpeDpkLWNkLm5ldCIsImRvbWFpbl9zdWZmaXg6c2JlcmJhbmsucnUiLCJkb21haW5fc3VmZml4OnNiZXIucnUiLCJkb21haW5fc3VmZml4OnNiZXJiYW5rLmFwcCIsImRvbWFpbl9zdWZmaXg6c2JlcmRldmljZXMucnUiLCJkb21haW5fc3VmZml4OnNidC5ydSJdLCJHZW9pcFVybCI6Imh0dHBzOi8vZ2l0aHViLmNvbS9Mb3lhbHNvbGRpZXIvdjJyYXktcnVsZXMtZGF0L3JlbGVhc2VzL2xhdGVzdC9kb3dubG9hZC9nZW9pcC5kYXQiLCJEb21haW5TdHJhdGVneSI6IklQSWZOb25NYXRjaCIsIk5hbWUiOiJHZUlQIiwiRG9tZXN0aWNETlNEb21haW4iOiJodHRwczovL2Rucy5nb29nbGUvZG5zLXF1ZXJ5IiwiRG9tZXN0aWNETlNJcCI6IjguOC44LjgiLCJMYXN0VXBkYXRlZCI6MCwiR2xvYmFsUHJveHkiOnRydWUsIlJlbW90ZUROU0RvbWFpbiI6Imh0dHBzOi8vY2xvdWRmbGFyZS1kbnMuY29tL2Rucy1xdWVyeSIsIkRuc0hvc3RzIjp7fSwiRGlyZWN0U2l0ZXMiOlsiZ2Vvc2l0ZTp2ayIsImdlb3NpdGU6a2lub3BvaXNrIiwiZ2Vvc2l0ZTphdmlhc2FsZXMiLCJnZW9zaXRlOmRyd2ViIiwiZ2Vvc2l0ZTp3aWxkYmVycmllcyIsImdlb3NpdGU6cnV0dWJlIiwiZ2Vvc2l0ZTpvem9uIiwiZ2Vvc2l0ZTp3aW5rIiwiZ2Vvc2l0ZToyZ2lzIiwiZ2Vvc2l0ZTprYXNwZXJza3kiLCJnZW9zaXRlOm9rIiwiZ2Vvc2l0ZTp5YW5kZXgiLCJnZW9zaXRlOm9ra28iLCJnZW9zaXRlOmF2aXRvIiwiZ2Vvc2l0ZTptb3NtZXRybyIsImdlb3NpdGU6ZHplbiIsImdlb3NpdGU6bWFpbHJ1IiwiZ2Vvc2l0ZTptYWlscnUtZ3JvdXAiLCJnZW9zaXRlOmNhdGVnb3J5LXRyYXZlbC1ydSIsImdlb3NpdGU6eDUiLCJnZW9zaXRlOmNhdGVnb3J5LWdvdi1ydSIsImdlb3NpdGU6Y2F0ZWdvcnktcmV0YWlsLXJ1IiwiZ2Vvc2l0ZTpjYXRlZ29yeS1tZWRpY2luZS1ydSIsImdlb3NpdGU6Y2F0ZWdvcnktZWNvbW1lcmNlLXJ1Il0sIlJlbW90ZUROU1R5cGUiOiJEb0giLCJVc2VDaHVua0ZpbGVzIjp0cnVlLCJSb3V0ZU9yZGVyIjoiYmxvY2stZGlyZWN0LXByb3h5IiwiR2Vvc2l0ZVVybCI6Imh0dHBzOi8vZ2l0aHViLmNvbS9Mb3lhbHNvbGRpZXIvdjJyYXktcnVsZXMtZGF0L3JlbGVhc2VzL2xhdGVzdC9kb3dubG9hZC9nZW9zaXRlLmRhdCIsIkJsb2NrU2l0ZXMiOlsiYW4ueWFuZGV4LnJ1IiwibWMueWFuZGV4LnJ1IiwibWV0cmlrYS55YW5kZXgucnUiLCJtYy53ZWJ2aXNvci5jb20iLCJtYy53ZWJ2aXNvci5vcmciLCJ3ZWJ2aXNvci5jb20iLCJ5YW5kZXhhZHNlcnZpY2VzLmNvbSIsImNsY2sueWFuZGV4LnJ1IiwiYnMueWFuZGV4LnJ1IiwiYWRmb3gucnUiLCJhZC5tYWlsLnJ1IiwidGFyZ2V0Lm15LmNvbSIsInRvcC1md3oxLm1haWwucnUiLCJkb3VibGVjbGljay5uZXQiLCJnb29nbGVzeW5kaWNhdGlvbi5jb20iLCJnb29nbGVhZHNlcnZpY2VzLmNvbSIsImdvb2dsZS1hbmFseXRpY3MuY29tIiwiaG90amFyLmNvbSIsInN0YXRpYy5ob3RqYXIuY29tIiwic2NyaXB0LmhvdGphci5jb20iLCJhZHZtYWtlci5uZXQiLCJhZHZtYWtlci5ydSIsInNlbnRyeS5pbyIsImJ1Z3NuYWcuY29tIiwic21pMi5ydSIsInJlbGFwLmlvIiwiYnV6em9vbGEuY29tIiwiYWRoaWdoLm5ldCIsImNvdW50ZXIueWFkcm8ucnUiLCJrcmFrZW4ucmFtYmxlci5ydSIsImFkcml2ZXIucnUiLCJtZ2lkLmNvbSIsImNvbm5lY3QuZmFjZWJvb2submV0IiwicGl4ZWwuZmFjZWJvb2suY29tIiwiYW5hbHl0aWNzLnRpa3Rvay5jb20iLCJhZHMudW5pdHkzZC5jb20iLCJhcHBsb3Zpbi5jb20iLCJpcm9uc3JjLmNvbSIsInZ1bmdsZS5jb20iLCJhbXBsaXR1ZGUuY29tIiwibWl4cGFuZWwuY29tIiwiY2hhcnRib29zdC5jb20iLCJpbm1vYmkuY29tIiwidGFwam95LmNvbSIsInN1cGVyc29uaWNhZHMuY29tIiwiZnliZXIuY29tIiwiZmx1cnJ5LmNvbSIsInNlZ21lbnQuaW8iLCJjcml0ZW8uY29tIiwiY3JpdGVvLm5ldCIsIm91dGJyYWluLmNvbSIsInRhYm9vbGEuY29tIiwiYWRuZXQucnUiLCJhZHRydWUuY29tIiwia2V0Y2hhcHBnYW1lcy5jb20iLCJrZXRjaGFwcC5vcmciLCJhcGkua2V0Y2hhcHAub3JnIiwibWludGVncmFsLmNvbSIsIm1icmlkZ2UuaW8iLCJwYW5nbGUuaW8iLCJhZGNvbG9ueS5jb20iLCJsaWZ0b2ZmLmlvIiwiaHlwcm14LmNvbSIsImdhbWVhbmFseXRpY3MuY29tIiwiaXNuYWRzLmNvbSIsImJ5dGVvdmVyc2VhLmNvbSIsImlieXRlZHRvcy5jb20iLCJwYW5nb2xpbi1zZGstdG91dGlhby5jb20iLCJ0b3BvbmFkLmNvbSIsInRyYWRwbHVzYWQuY29tIiwiYWR0cnVlLmNvbSIsInRhcHRhcC5pbyIsInViaXNvZnQuY29tIiwiYXBpLnViaXNvZnQuY29tIiwia2V0Y2hhcHAuY29tIiwiZ3Z0MS5jb20iLCJndnQyLmNvbSIsImFwcHNwb3QuY29tIiwiMXAxMy5jb20iLCJhcHBsaXhpci5jb20iXSwiRG9tZXN0aWNETlNUeXBlIjoiRG9IIiwiUmVtb3RlRE5TSXAiOiIxLjEuMS4xIn0=';

void main() {
  test('Happ: ссылка GeIP переносится полностью', () {
    final r = myImportRules(happLink)!;
    expect(r.format, 'Happ');
    expect(r.name, 'GeIP');
    expect(r.rules.map((e) => e.action), ['block', 'direct', 'proxy']);
    final block = r.rules[0], direct = r.rules[1], proxy = r.rules[2];
    expect(block.suffixes.length, 80);
    expect(direct.geo.length, 24 + 1); // 24 geosite + geoip:private
    expect(direct.geo, contains('geosite:vk'));
    expect(direct.geo, contains('geoip:private'));
    expect(direct.ips.length, 7);
    expect(proxy.suffixes, contains('sberbank.ru'));
    expect(r.remoteDns, 'https://cloudflare-dns.com/dns-query');
    expect(r.directDns, 'https://dns.google/dns-query');
    expect(r.skipped, isEmpty);
  });

  test('Xray: правила подписки вроде VoxGate', () {
    const json = """{"remarks":"VG","routing":{"rules":[
      {"inboundTag":["balancer-loop-1-in"],"balancerTag":"b1"},
      {"protocol":["bittorrent"],"outboundTag":"direct"},
      {"domain":["dht.transmissionbt.com","domain:router.bittorrent.com"],"outboundTag":"direct"},
      {"ip":["10.0.0.0/8","geoip:private"],"outboundTag":"direct"},
      {"domain":["api.ipify.org","ifconfig.me"],"outboundTag":"direct"},
      {"inboundTag":["dns-direct"],"outboundTag":"direct"},
      {"port":"53","network":"tcp,udp","outboundTag":"dns-server"},
      {"port":"443","network":"udp","outboundTag":"block"},
      {"network":"tcp,udp","balancerTag":"proxy_balancer_priority"}]}}""";
    final r = myImportRules(json)!;
    expect(r.format, 'Xray');
    expect(r.rules.length, 4);
    expect(r.rules[0].protocols, ['bittorrent']);
    expect(r.rules[1].suffixes, ['dht.transmissionbt.com', 'router.bittorrent.com']);
    expect(r.rules[2].geo, ['geoip:private']);
    expect(r.rules[3].action, 'block');
    expect(r.rules[3].network, 'udp');
    expect(r.rules[3].ports, ['443']);
    expect(r.skipped.single, contains('проверки IP'));
  });

  test('Shadowrocket и Clash', () {
    final sr = myImportRules('[General]\nbypass-system = true\n[Rule]\nDOMAIN-SUFFIX,youtube.com,PROXY\nGEOIP,RU,DIRECT\nDOMAIN-KEYWORD,ads,REJECT\nPROCESS-NAME,tg,DIRECT\nFINAL,PROXY\n[Host]\n')!;
    expect(sr.format, 'Shadowrocket');
    expect(sr.rules.map((e) => e.action), ['block', 'direct', 'proxy']);
    expect(sr.rules[1].geo, ['geoip:ru']);
    expect(sr.skipped.single, contains('PROCESS-NAME'));
    final cl = myImportRules('port: 7890\nrules:\n  - DOMAIN-SUFFIX,ya.ru,DIRECT\n  - GEOSITE,youtube,PROXY\n  - MATCH,PROXY\n')!;
    expect(cl.format, 'Clash');
    expect(cl.rules.length, 2);
    expect(cl.rules[1].geo, ['geosite:youtube']);
  });

  test('sing-box', () {
    const json = """{"route":{"rule_set":[{"tag":"geosite-youtube","url":"https://x/geosite-youtube.srs"}],
      "rules":[{"action":"sniff"},{"rule_set":["geosite-youtube"],"outbound":"proxy"},
      {"domain_suffix":[".ru"],"outbound":"direct"},{"ip_is_private":true,"outbound":"direct"},
      {"process_name":["Telegram"],"outbound":"direct"},{"protocol":"quic","action":"reject"}]}}""";
    final r = myImportRules(json)!;
    expect(r.format, 'sing-box');
    expect(r.rules.length, 4);
    expect(r.rules[0].geo, ['geosite:youtube']);
    expect(r.rules[1].suffixes, ['ru']);
    expect(r.rules[3].action, 'block');
  });

  test('простой список', () {
    final r = myImportRules('youtube.com\nhttps://www.instagram.com/x\n1.2.3.4\n# коммент\n', plainAction: 'proxy')!;
    expect(r.rules.single.suffixes, ['youtube.com', 'www.instagram.com']);
    expect(r.rules.single.ips, ['1.2.3.4/32']);
  });

  test('источник списков подставляет ссылки', () {
    final rule = MyRuleSpec('direct')..geo.addAll(['geosite:vk', 'geoip:ru']);
    final r = myResolveGeo([rule.toRule('x')], 'sagernet').single;
    expect(r.ruleSets, [
      'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-vk.srs',
      'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs',
    ]);
    expect(myResolveGeo([rule.toRule('x')], 'none').single.ruleSets, isEmpty);
    final c = myResolveGeo([rule.toRule('x')], 'custom|https://a/{name}.srs|https://b/geoip-{name}.srs').single;
    expect(c.ruleSets, ['https://a/vk.srs', 'https://b/geoip-ru.srs']);
    final plain = Rule(name: 'p', ruleSets: ['https://x/y.srs']);
    expect(myResolveGeo([plain], 'tunnex').single.ruleSets, ['https://x/y.srs']);
  });

  test('правило туда и обратно', () {
    final s = MyRuleSpec('block')..ports.add('443')..network = 'udp'..protocols.add('quic');
    final back = MyRuleSpec.fromJson(s.toJson());
    expect(back.toJson(), s.toJson());
    final rule = back.toRule('q');
    expect(rule.outbound, Outbound.block);
    expect(rule.network, Network.udp);
    expect(rule.protocols, [Protocol.quic]);
  });

  test('группы подписки Xray: балансировщик по началу тега, общие серверы', () {
    String v(String host) => '{"protocol":"vless","tag":"T","settings":{"vnext":[{"address":"$host","port":443,"users":[{"id":"u"}]}]}}';
    final json = '[{"remarks":"🇪🇺 Автовыбор","outbounds":[${v('a').replaceFirst('"T"', '"proxy-1"')},${v('b').replaceFirst('"T"', '"proxy-2"')},${v('c').replaceFirst('"T"', '"proxy-17"')},{"protocol":"freedom","tag":"direct"}],'
        '"routing":{"balancers":[{"tag":"b","selector":["proxy-1"]}],"rules":[{"protocol":["bittorrent"],"outboundTag":"direct"}]}},'
        '{"remarks":"🇫🇮 Финляндия","outbounds":[${v('b').replaceFirst('"T"', '"proxy-2"')}],"routing":{"balancers":[{"tag":"b","selector":["proxy-2"]}]}}]';
    MyXrayMeta.pending.clear();
    myNameXrayJson(json);
    final meta = MyXrayMeta.pending.single;
    // proxy-1 захватывает и proxy-17 (как в Xray), но не proxy-2
    expect(meta.groups['🇪🇺 Автовыбор'], ['🇪🇺 Автовыбор [1]', '🇪🇺 Автовыбор [3]']);
    // общий сервер сохраняет имя из первой группы
    expect(meta.groups['🇫🇮 Финляндия'], ['🇪🇺 Автовыбор [2]']);
    expect(meta.rules.length, 1);
  });

  test('группы подписки Xray: только основной балансировщик, запасные не смешиваются', () {
    String v(String tag, String host) => '{"protocol":"vless","tag":"$tag","settings":{"vnext":[{"address":"$host","port":443,"users":[{"id":"u"}]}]}}';
    final json = '[{"remarks":"🇪🇺 Автовыбор","outbounds":[${v('proxy-6', 'de')},${v('proxy-7', 'nl')},${v('proxy-1', 'ru1')},${v('proxy-2', 'ru2')},${v('proxy-16', 'x')}],'
        '"routing":{"balancers":[{"tag":"proxy_balancer_priority","selector":["proxy-6","proxy-7"]},'
        '{"tag":"proxy_balancer_1","selector":["proxy-1","proxy-2"]},{"tag":"proxy_balancer_2","selector":["proxy-16"]}],'
        '"rules":[{"inboundTag":["balancer-loop-1-in"],"balancerTag":"proxy_balancer_1"},'
        '{"protocol":["bittorrent"],"outboundTag":"direct"},{"network":"tcp,udp","balancerTag":"proxy_balancer_priority"}]}},'
        '{"remarks":"РЕЗЕРВ","outbounds":[${v('proxy-34', 'r')}],"routing":{"balancers":[{"tag":"proxy_balancer_priority","selector":["proxy-34"]}]}}]';
    MyXrayMeta.pending.clear();
    myNameXrayJson(json);
    final meta = MyXrayMeta.pending.single;
    expect(meta.groups['🇪🇺 Автовыбор'], ['🇪🇺 Автовыбор [1]', '🇪🇺 Автовыбор [2]']);
    // нет правил — берутся все балансировщики конфига
    expect(meta.groups['РЕЗЕРВ'], ['РЕЗЕРВ']);
  });
}
