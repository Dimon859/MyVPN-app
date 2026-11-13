// MyVPN: импорт правил маршрутизации из других VPN-клиентов и правила самих подписок.
// Понимает: Happ (happ://routing/…), Xray JSON (v2RayTun, v2rayN, Incy и подписки вроде VoxGate),
// sing-box JSON (Streisand, Karing, Hiddify), Shadowrocket (.conf), Clash/Mihomo (YAML) и простой список.
// Списки вида geosite:vk / geoip:ru хранятся как есть и превращаются в ссылки при подключении
// (из выбранного источника списков, см. MyGeoSource).
import 'dart:convert';

import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';

// ---------- общий вид правила ----------

class MyRuleSpec {
  MyRuleSpec(this.action);

  final String action; // direct, proxy, block
  final domains = <String>[];
  final suffixes = <String>[];
  final keywords = <String>[];
  final regexes = <String>[];
  final ips = <String>[];
  final geo = <String>[]; // geosite:x, geoip:x
  final ports = <String>[];
  final protocols = <String>[];
  String? network; // tcp, udp

  bool get isEmpty =>
      domains.isEmpty &&
      suffixes.isEmpty &&
      keywords.isEmpty &&
      regexes.isEmpty &&
      ips.isEmpty &&
      geo.isEmpty &&
      ports.isEmpty &&
      protocols.isEmpty &&
      network == null;

  int get size =>
      domains.length + suffixes.length + keywords.length + regexes.length + ips.length + geo.length + ports.length;

  Map<String, dynamic> toJson() => {
    'a': action,
    if (domains.isNotEmpty) 'd': domains,
    if (suffixes.isNotEmpty) 's': suffixes,
    if (keywords.isNotEmpty) 'k': keywords,
    if (regexes.isNotEmpty) 'r': regexes,
    if (ips.isNotEmpty) 'i': ips,
    if (geo.isNotEmpty) 'g': geo,
    if (ports.isNotEmpty) 'p': ports,
    if (protocols.isNotEmpty) 'pr': protocols,
    if (network != null) 'n': network,
  };

  static MyRuleSpec fromJson(Map m) {
    List<String> l(String k) => [for (final x in (m[k] as List? ?? const [])) x.toString()];
    return MyRuleSpec((m['a'] ?? 'proxy').toString())
      ..domains.addAll(l('d'))
      ..suffixes.addAll(l('s'))
      ..keywords.addAll(l('k'))
      ..regexes.addAll(l('r'))
      ..ips.addAll(l('i'))
      ..geo.addAll(l('g'))
      ..ports.addAll(l('p'))
      ..protocols.addAll(l('pr'))
      ..network = m['n'] as String?;
  }

  /// Правило ядра (списки geosite:/geoip: остаются как есть — их подставит myResolveGeo).
  Rule toRule(String name) {
    final out = switch (action) {
      'direct' => Outbound.direct,
      'block' => Outbound.block,
      _ => Outbound.proxy,
    };
    final protos = [
      for (final p in protocols)
        ?Protocol.values.where((e) => e.name == p).firstOrNull,
    ];
    return Rule(
      name: name,
      enabled: true,
      outbound: out,
      domains: domains,
      domainSuffixes: suffixes,
      domainKeywords: keywords,
      domainRegexes: regexes,
      ipCidrs: ips,
      ruleSets: geo,
      portRanges: ports,
      protocols: protos,
      network: switch (network) {
        'tcp' => Network.tcp,
        'udp' => Network.udp,
        _ => null,
      },
    );
  }
}

class MyImportResult {
  MyImportResult(this.format, this.name);

  final String format; // Happ, Xray, sing-box, Shadowrocket, Clash, список
  String name;
  final rules = <MyRuleSpec>[];
  final skipped = <String>[];
  String? remoteDns, directDns;
  bool? globalProxy; // false — «всё остальное напрямую»

  int get count => rules.fold(0, (a, r) => a + r.size + (r.size == 0 ? 1 : 0));
}

// ---------- мелочи ----------

/// Сайты проверки IP: правило «их напрямую» не переносим — иначе проверка утечек покажет настоящий IP.
const _myIpCheckHosts = ['ipify', 'ifconfig', 'checkip', 'ipinfo', 'ip-api', 'myip', '2ip', 'whatismyip', 'icanhazip'];

bool _myIsIpCheck(MyRuleSpec r) =>
    r.action == 'direct' &&
    [...r.domains, ...r.suffixes, ...r.keywords].any((d) => _myIpCheckHosts.any(d.toLowerCase().contains));

String _myCidr(String v) {
  final s = v.trim();
  if (s.contains('/')) return s;
  return s.contains(':') ? '$s/128' : '$s/32';
}

final _myIpRe = RegExp(r'^[0-9a-fA-F:.]+(/\d+)?$');

bool _myLooksIp(String v) => _myIpRe.hasMatch(v.trim()) && (v.contains('.') || v.contains(':'));

String _myPort(String p) => p.trim().replaceAll('-', ':');

/// Действие из названия выхода: direct / block / proxy (или null — правило служебное).
String? _myAction(String? tag) {
  final t = (tag ?? '').toLowerCase();
  if (t.isEmpty) return 'proxy';
  if (t == 'dns-out' || t == 'dns-server' || t == 'dns') return null;
  if (t.contains('direct') || t.contains('freedom') || t == 'bypass') return 'direct';
  if (t.contains('block') || t.contains('blackhole') || t.contains('reject')) return 'block';
  return 'proxy';
}

/// Запись домена в стиле Xray: domain:, full:, keyword:, regexp:, geosite:, без префикса — подстрока.
void _myXrayDomain(MyRuleSpec r, String v, List<String> skipped) {
  final s = v.trim();
  if (s.isEmpty) return;
  final i = s.indexOf(':');
  final kind = i > 0 ? s.substring(0, i).toLowerCase() : '';
  final val = i > 0 ? s.substring(i + 1) : s;
  switch (kind) {
    case 'domain':
    case 'domain_suffix':
      r.suffixes.add(val);
    case 'full':
    case 'domain_full':
      r.domains.add(val);
    case 'keyword':
    case 'domain_keyword':
      r.keywords.add(val);
    case 'regexp':
    case 'domain_regex':
      r.regexes.add(val);
    case 'geosite':
      r.geo.add('geosite:${val.toLowerCase()}');
    case 'ext':
    case 'ext-domain':
      skipped.add('$s — внешний файл списков не поддерживается');
    default:
      // в Xray строка без префикса — «содержит»; голое имя сайта удобнее считать доменом с поддоменами
      if (i < 0 && s.contains('.')) {
        r.suffixes.add(s);
      } else {
        r.keywords.add(s);
      }
  }
}

void _myXrayIp(MyRuleSpec r, String v, List<String> skipped) {
  final s = v.trim();
  if (s.isEmpty) return;
  if (s.toLowerCase().startsWith('geoip:')) {
    final name = s.substring(6).toLowerCase();
    r.geo.add(name.startsWith('!') ? 'geoip:${name.substring(1)}' : 'geoip:$name');
    if (name.startsWith('!')) skipped.add('$s — «кроме» не поддерживается, взято как обычный список');
    return;
  }
  if (s.startsWith('ext:')) {
    skipped.add('$s — внешний файл списков не поддерживается');
    return;
  }
  if (_myLooksIp(s)) {
    r.ips.add(_myCidr(s));
  } else {
    skipped.add('$s — непонятный IP');
  }
}

List<String> _myList(Object? v) {
  if (v == null) return const [];
  if (v is List) return [for (final x in v) x.toString()];
  return v.toString().split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
}

// ---------- Xray (v2RayTun, v2rayN, Incy, подписки) ----------

/// Правила из routing.rules Xray. Служебные (inboundTag, DNS) и «всё остальное» пропускаются.
List<MyRuleSpec> myRulesFromXray(List rules, List<String> skipped) {
  final out = <MyRuleSpec>[];
  for (final raw in rules) {
    if (raw is! Map) continue;
    if (raw['inboundTag'] != null) continue; // служебные правила балансировщиков и DNS
    final action = raw['balancerTag'] != null ? 'proxy' : _myAction(raw['outboundTag']?.toString());
    if (action == null) continue;
    final r = MyRuleSpec(action);
    for (final d in _myList(raw['domain'] ?? raw['domains'])) {
      _myXrayDomain(r, d, skipped);
    }
    for (final ip in _myList(raw['ip'])) {
      _myXrayIp(r, ip, skipped);
    }
    for (final p in _myList(raw['port'])) {
      r.ports.add(_myPort(p));
    }
    final net = _myList(raw['network']).map((e) => e.toLowerCase()).toSet();
    if (net.length == 1) r.network = net.first;
    for (final p in _myList(raw['protocol'])) {
      if (const ['bittorrent', 'quic', 'tls', 'http', 'stun', 'dns'].contains(p.toLowerCase())) {
        r.protocols.add(p.toLowerCase());
      }
    }
    // порт 53 — это DNS, им управляет само приложение
    if (r.ports.length == 1 && r.ports.first == '53' && r.size == 1) continue;
    // «всё остальное через VPN» — и так поведение по умолчанию
    if (r.size == 0 && r.protocols.isEmpty && (r.network == null || action == 'proxy')) {
      if (action == 'proxy') continue;
      if (r.network == null) {
        skipped.add('«всё остальное → $action» — в Tunnex всё остальное идёт через VPN');
        continue;
      }
    }
    if (_myIsIpCheck(r)) {
      skipped.add('сайты проверки IP напрямую — не перенесено, иначе проверка утечек покажет настоящий IP');
      continue;
    }
    out.add(r);
  }
  return out;
}

// ---------- sing-box ----------

List<MyRuleSpec> myRulesFromSingBox(Map json, List<String> skipped) {
  final route = json['route'] is Map ? json['route'] as Map : json;
  final rules = route['rules'] as List? ?? const [];
  // rule_set: тег → имя списка (geosite-vk → geosite:vk)
  final sets = <String, String>{};
  for (final rs in route['rule_set'] as List? ?? const []) {
    if (rs is! Map) continue;
    final tag = (rs['tag'] ?? '').toString();
    final m = RegExp(r'(geosite|geoip)-([a-z0-9!@._-]+)').firstMatch('$tag ${rs['url'] ?? rs['path'] ?? ''}');
    if (m != null) sets[tag] = '${m[1]}:${m[2]}';
  }
  final out = <MyRuleSpec>[];
  for (final raw in rules) {
    if (raw is! Map) continue;
    final act = (raw['action'] ?? 'route').toString();
    String? action;
    if (act == 'reject') {
      action = 'block';
    } else if (act == 'route') {
      action = _myAction(raw['outbound']?.toString());
    } else {
      continue; // sniff, hijack-dns, resolve — служебные
    }
    if (action == null) continue;
    if (raw['inbound'] != null || raw['clash_mode'] != null) continue;
    final r = MyRuleSpec(action);
    r.domains.addAll(_myList(raw['domain']));
    r.suffixes.addAll(_myList(raw['domain_suffix']).map((e) => e.startsWith('.') ? e.substring(1) : e));
    r.keywords.addAll(_myList(raw['domain_keyword']));
    r.regexes.addAll(_myList(raw['domain_regex']));
    r.ips.addAll(_myList(raw['ip_cidr']).map(_myCidr));
    if (raw['ip_is_private'] == true) r.geo.add('geoip:private');
    for (final g in _myList(raw['geosite'])) {
      r.geo.add('geosite:$g');
    }
    for (final g in _myList(raw['geoip'])) {
      r.geo.add('geoip:$g');
    }
    for (final t in _myList(raw['rule_set'])) {
      final g = sets[t];
      if (g != null) {
        r.geo.add(g);
      } else {
        skipped.add('rule_set «$t» — неизвестный список');
      }
    }
    r.ports.addAll(_myList(raw['port']));
    r.ports.addAll(_myList(raw['port_range']));
    final net = _myList(raw['network']);
    if (net.length == 1) r.network = net.first;
    r.protocols.addAll(_myList(raw['protocol']));
    if (raw['process_name'] != null || raw['package_name'] != null || raw['process_path'] != null) {
      skipped.add('правило по приложениям — на iPhone невозможно');
      if (r.isEmpty) continue;
    }
    if (r.isEmpty) continue;
    if (_myIsIpCheck(r)) {
      skipped.add('сайты проверки IP напрямую — не перенесено');
      continue;
    }
    out.add(r);
  }
  return out;
}

// ---------- Happ ----------

MyImportResult myImportHapp(Map j) {
  final res = MyImportResult('Happ', (j['Name'] ?? 'Happ').toString());
  MyRuleSpec make(String action, Object? sites, Object? ips) {
    final r = MyRuleSpec(action);
    for (final s in _myList(sites)) {
      _myXrayDomain(r, s, res.skipped);
    }
    for (final ip in _myList(ips)) {
      _myXrayIp(r, ip, res.skipped);
    }
    return r;
  }

  final block = make('block', j['BlockSites'], j['BlockIp']);
  final direct = make('direct', j['DirectSites'], j['DirectIp']);
  final proxy = make('proxy', j['ProxySites'], j['ProxyIp']);
  final order = (j['RouteOrder'] ?? 'block-direct-proxy').toString().split('-');
  final byName = {'block': block, 'direct': direct, 'proxy': proxy};
  for (final o in order) {
    final r = byName.remove(o);
    if (r != null && !r.isEmpty) res.rules.add(r);
  }
  for (final r in byName.values) {
    if (!r.isEmpty) res.rules.add(r);
  }
  res.rules.removeWhere((r) {
    if (_myIsIpCheck(r)) {
      res.skipped.add('сайты проверки IP напрямую — не перенесено');
      return true;
    }
    return false;
  });
  String? dns(String type, String domain, String ip) {
    final t = (j[type] ?? '').toString().toLowerCase();
    final d = (j[domain] ?? '').toString().trim();
    final i = (j[ip] ?? '').toString().trim();
    if (t == 'doh' && d.isNotEmpty) return d;
    if (i.isNotEmpty) return t == 'dot' ? 'tls://$i' : i;
    return d.isEmpty ? null : d;
  }

  res.remoteDns = dns('RemoteDNSType', 'RemoteDNSDomain', 'RemoteDNSIp');
  res.directDns = dns('DomesticDNSType', 'DomesticDNSDomain', 'DomesticDNSIp');
  res.globalProxy = j['GlobalProxy'] as bool?;
  if (res.globalProxy == false) res.skipped.add('«всё остальное напрямую» — в Tunnex всё остальное идёт через VPN');
  return res;
}

// ---------- Shadowrocket / Clash ----------

/// Строки вида «DOMAIN-SUFFIX,example.com,DIRECT» (Shadowrocket [Rule] и Clash rules:).
MyImportResult myImportLineRules(List<String> lines, String format, String name) {
  final res = MyImportResult(format, name);
  final byAction = <String, MyRuleSpec>{};
  MyRuleSpec spec(String a) => byAction.putIfAbsent(a, () => MyRuleSpec(a));
  for (var line in lines) {
    line = line.trim();
    if (line.startsWith('- ')) line = line.substring(2).trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) continue;
    line = line.replaceAll(RegExp(r'''^["']|["']$'''), '');
    final parts = line.split(',').map((e) => e.trim()).toList();
    if (parts.length < 2) continue;
    final kind = parts[0].toUpperCase();
    if (kind == 'FINAL' || kind == 'MATCH') {
      final a = _myAction(parts[1]);
      if (a != 'proxy') res.skipped.add('«всё остальное → ${parts[1]}» — в Tunnex всё остальное идёт через VPN');
      continue;
    }
    if (parts.length < 3) continue;
    final value = parts[1];
    final target = parts[2].toUpperCase();
    final action = target == 'DIRECT'
        ? 'direct'
        : (target == 'REJECT' || target.startsWith('REJECT-') || target == 'BLOCK')
        ? 'block'
        : 'proxy';
    final r = spec(action);
    switch (kind) {
      case 'DOMAIN':
        r.domains.add(value);
      case 'DOMAIN-SUFFIX':
        r.suffixes.add(value.startsWith('.') ? value.substring(1) : value);
      case 'DOMAIN-KEYWORD':
        r.keywords.add(value);
      case 'DOMAIN-REGEX':
        r.regexes.add(value);
      case 'IP-CIDR':
      case 'IP-CIDR6':
        r.ips.add(_myCidr(value));
      case 'GEOIP':
        r.geo.add('geoip:${value.toLowerCase()}');
      case 'GEOSITE':
        r.geo.add('geosite:${value.toLowerCase()}');
      case 'DST-PORT':
      case 'DEST-PORT':
        r.ports.add(_myPort(value));
      case 'PROCESS-NAME':
      case 'USER-AGENT':
        res.skipped.add('$kind,$value — на iPhone невозможно');
      default:
        res.skipped.add('$kind,$value — не поддерживается');
    }
  }
  for (final a in const ['block', 'direct', 'proxy']) {
    final r = byAction[a];
    if (r != null && !r.isEmpty) {
      if (_myIsIpCheck(r)) {
        res.skipped.add('сайты проверки IP напрямую — не перенесено');
        continue;
      }
      res.rules.add(r);
    }
  }
  return res;
}

// ---------- простой список ----------

MyImportResult myImportPlainList(List<String> lines, String action) {
  final res = MyImportResult('список', 'Мой список');
  final r = MyRuleSpec(action);
  for (var l in lines) {
    l = l.trim();
    if (l.isEmpty || l.startsWith('#')) continue;
    l = l.replaceFirst(RegExp(r'^https?://'), '').split('/').first;
    if (l.startsWith('geosite:') || l.startsWith('geoip:')) {
      r.geo.add(l.toLowerCase());
    } else if (_myLooksIp(l)) {
      r.ips.add(_myCidr(l));
    } else if (l.contains('.')) {
      r.suffixes.add(l.startsWith('*.') ? l.substring(2) : l);
    } else {
      res.skipped.add('$l — не похоже на сайт или IP');
    }
  }
  if (!r.isEmpty) res.rules.add(r);
  return res;
}

// ---------- определение формата ----------

/// Разбор любого текста: ссылка Happ, JSON (Happ / Xray / sing-box), Shadowrocket, Clash, список.
/// null — правила не найдены; для простого списка нужен [plainAction].
MyImportResult? myImportRules(String input, {String plainAction = 'proxy'}) {
  var text = input.trim();
  // ссылки happ://routing/add/<base64> и похожие
  final link = RegExp(r'^[a-z0-9+.-]+://routing/(?:add|onadd)/([A-Za-z0-9+/=_-]+)', caseSensitive: false).firstMatch(text);
  if (link != null) {
    try {
      final b = link[1]!.replaceAll('-', '+').replaceAll('_', '/');
      text = utf8.decode(base64.decode(b + '=' * ((4 - b.length % 4) % 4)));
    } catch (_) {
      return null;
    }
  }
  if (text.startsWith('{') || text.startsWith('[')) {
    Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      json = null;
    }
    if (json is Map) {
      if (json.containsKey('DirectSites') || json.containsKey('BlockSites') || json.containsKey('ProxySites')) {
        return myImportHapp(json);
      }
      if (json['routing'] is Map || (json['rules'] is List && (json['rules'] as List).any((e) => e is Map && e.containsKey('outboundTag')))) {
        final res = MyImportResult('Xray', (json['remarks'] ?? 'Xray').toString());
        final rules = (json['routing'] is Map ? (json['routing'] as Map)['rules'] : json['rules']) as List? ?? const [];
        res.rules.addAll(myRulesFromXray(rules, res.skipped));
        return res;
      }
      if (json['route'] is Map || json['rules'] is List) {
        final res = MyImportResult('sing-box', 'sing-box');
        res.rules.addAll(myRulesFromSingBox(json, res.skipped));
        final dns = json['dns'];
        if (dns is Map && dns['servers'] is List) {
          for (final s in dns['servers'] as List) {
            if (s is Map && (s['detour'] == null || s['detour'] != 'direct')) {
              final a = s['address'] ?? (s['server'] != null ? '${s['type'] ?? 'udp'}://${s['server']}' : null);
              if (a != null) {
                res.remoteDns ??= a.toString();
              }
            }
          }
        }
        return res;
      }
    }
    if (json is List && json.isNotEmpty && json.first is Map && (json.first as Map)['routing'] is Map) {
      final first = json.first as Map;
      final res = MyImportResult('Xray', (first['remarks'] ?? 'Xray').toString());
      res.rules.addAll(myRulesFromXray((first['routing'] as Map)['rules'] as List? ?? const [], res.skipped));
      return res;
    }
  }
  final lines = const LineSplitter().convert(text);
  // Shadowrocket: раздел [Rule]
  final ruleStart = lines.indexWhere((l) => l.trim().toLowerCase() == '[rule]');
  if (ruleStart >= 0) {
    final body = <String>[];
    for (final l in lines.skip(ruleStart + 1)) {
      if (l.trim().startsWith('[')) break;
      body.add(l);
    }
    return myImportLineRules(body, 'Shadowrocket', 'Shadowrocket');
  }
  // Clash / Mihomo: rules:
  final clashStart = lines.indexWhere((l) => l.trim() == 'rules:');
  if (clashStart >= 0) {
    final body = <String>[];
    for (final l in lines.skip(clashStart + 1)) {
      if (l.isNotEmpty && !l.startsWith(' ') && !l.startsWith('-')) break;
      body.add(l);
    }
    return myImportLineRules(body, 'Clash', 'Clash');
  }
  // строки правил без заголовка
  if (lines.where((l) => RegExp(r'^\s*-?\s*(DOMAIN|IP-CIDR|GEOIP|GEOSITE)', caseSensitive: false).hasMatch(l)).length >=
      (lines.length / 2)) {
    return myImportLineRules(lines, 'Clash', 'Правила');
  }
  final res = myImportPlainList(lines, plainAction);
  return res.rules.isEmpty ? null : res;
}

// ---------- источники списков geosite / geoip ----------

class MyGeoSource {
  const MyGeoSource(this.id, this.name, this.geosite, this.geoip, {this.note = ''});

  final String id;
  final String name;
  final String geosite; // шаблон с {name}
  final String geoip;
  final String note;
}

const myTunnexRaw = 'https://raw.githubusercontent.com/Dimon859/MyVPN-app/rule-set';

const myGeoSources = [
  MyGeoSource(
    'tunnex',
    'Tunnex (своя копия на GitHub)',
    '$myTunnexRaw/geosite/geosite-{name}.srs',
    '$myTunnexRaw/geoip/geoip-{name}.srs',
    note: 'Копия списков runetfreedom, обновляется раз в неделю. Не зависит от чужих репозиториев',
  ),
  MyGeoSource(
    'runetfreedom',
    'runetfreedom (для России)',
    'https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-{name}.srs',
    'https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geoip/geoip-{name}.srs',
    note: 'Как Loyalsoldier в Happ, плюс российские списки (ru-blocked и др.)',
  ),
  MyGeoSource(
    'sagernet',
    'SagerNet (официальные sing-box)',
    'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-{name}.srs',
    'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-{name}.srs',
  ),
  MyGeoSource(
    'metacubex',
    'MetaCubeX (сайты) + SagerNet (IP)',
    'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/{name}.srs',
    'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-{name}.srs',
  ),
];

/// Источник по сохранённому значению: id готового, «custom|сайты|ip» или «none» (не загружать).
MyGeoSource? myGeoSourceOf(String value) {
  if (value == 'none') return null;
  if (value.startsWith('custom|')) {
    final p = value.split('|');
    return MyGeoSource('custom', 'Свои ссылки', p.length > 1 ? p[1] : '', p.length > 2 ? p[2] : '');
  }
  return myGeoSources.where((s) => s.id == value).firstOrNull ?? myGeoSources.first;
}

/// geosite:x / geoip:x → ссылки выбранного источника; без источника такие списки убираются.
List<Rule> myResolveGeo(List<Rule> rules, String sourceValue) {
  final src = myGeoSourceOf(sourceValue);
  final out = <Rule>[];
  for (final r in rules) {
    if (!r.ruleSets.any((u) => u.startsWith('geosite:') || u.startsWith('geoip:'))) {
      out.add(r);
      continue;
    }
    final c = r.deepCopy();
    final sets = <String>[];
    for (final u in r.ruleSets) {
      final m = RegExp(r'^(geosite|geoip):(.+)$').firstMatch(u);
      if (m == null) {
        sets.add(u);
        continue;
      }
      if (src == null) continue;
      final tpl = m[1] == 'geosite' ? src.geosite : src.geoip;
      if (tpl.isEmpty) continue;
      sets.add(tpl.replaceAll('{name}', m[2]!));
    }
    c.ruleSets
      ..clear()
      ..addAll(sets);
    out.add(c);
  }
  return out;
}

/// Короткое описание правила для людей.
String myDescribeSpec(MyRuleSpec r) {
  final what = <String>[
    if (r.geo.isNotEmpty) '${r.geo.length} списков',
    if (r.suffixes.length + r.domains.length + r.keywords.length + r.regexes.length > 0)
      '${r.suffixes.length + r.domains.length + r.keywords.length + r.regexes.length} сайтов',
    if (r.ips.isNotEmpty) '${r.ips.length} IP',
    if (r.ports.isNotEmpty) 'порты ${r.ports.join(', ')}',
    if (r.protocols.isNotEmpty) r.protocols.join(', '),
    if (r.network != null) r.network!.toUpperCase(),
  ].join(', ');
  final act = switch (r.action) {
    'direct' => 'напрямую',
    'block' => 'блокировать',
    _ => 'через VPN',
  };
  return '$act: $what';
}
