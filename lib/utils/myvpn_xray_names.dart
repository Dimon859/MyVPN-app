// MyVPN: имена серверов для подписок в формате Xray JSON (Happ/Incy/v2RayTun).
// Панель отдаёт список конфигов, у каждого понятное имя в "remarks", а у серверов внутри —
// служебные теги вроде "proxy-1". Ядро берёт имя сервера из тега, поэтому без этого
// в списке видно «proxy-1 § 0». Здесь теги заменяются на "remarks" их конфига.
import 'dart:convert';

const _myProxyProtocols = {
  'vless',
  'vmess',
  'trojan',
  'shadowsocks',
  'hysteria2',
  'hysteria',
  'tuic',
  'wireguard',
  'socks',
  'http',
};

/// [text] с понятными именами серверов, или [text] без изменений, если это не Xray JSON с "remarks".
String myNameXrayJson(String text) {
  final t = text.trimLeft();
  if (!t.startsWith('[') && !t.startsWith('{')) return text;
  Object? data;
  try {
    data = jsonDecode(t);
  } catch (_) {
    return text;
  }
  final List<Object?> configs;
  if (data is List) {
    configs = data;
  } else if (data is Map) {
    configs = [data];
  } else {
    return text;
  }
  var changed = false;
  final names = <String, String>{}; // сервер (без тега) → имя
  final used = <String>{};
  final groups = <String, List<String>>{}; // группа подписки → имена серверов в ней
  List? rules;
  for (final c in configs) {
    if (c is! Map) continue;
    final remarks = (c['remarks'] ?? '').toString().trim();
    final outs = c['outbounds'];
    if (remarks.isEmpty || outs is! List) continue;
    final proxies = [
      for (final o in outs)
        if (o is Map && o['type'] == null && _myProxyProtocols.contains(o['protocol'])) o,
    ];
    // серверы, которые подписка сама выбирает автоматически (балансировщики); нет их — все серверы конфига.
    // Берётся только основной балансировщик — тот, куда правила отправляют трафик. Остальные у панели
    // запасные (включаются, когда основной весь недоступен), их серверы в группу не попадают —
    // иначе автовыбор по пингу уходит на запасные (часто российские) серверы.
    final routing = c['routing'];
    final balancers = [
      if (routing is Map)
        for (final b in (routing['balancers'] as List? ?? const []))
          if (b is Map) b,
    ];
    String? mainTag;
    if (routing is Map) {
      for (final r in (routing['rules'] as List? ?? const [])) {
        if (r is Map && r['inboundTag'] == null && r['balancerTag'] != null) mainTag = r['balancerTag'].toString();
      }
    }
    final main = balancers.where((b) => b['tag']?.toString() == mainTag).toList();
    final selectors = <String>[
      for (final b in main.isNotEmpty ? main : balancers)
        for (final sel in (b['selector'] as List? ?? const [])) sel.toString(),
    ];
    if (rules == null && routing is Map && routing['rules'] is List) rules = routing['rules'] as List;
    bool inGroup(Map o) {
      if (selectors.isEmpty) return true;
      // как в Xray: выбор по началу тега
      final tag = (o['tag'] ?? '').toString();
      return selectors.any(tag.startsWith);
    }
    final members = <Map>[for (final o in proxies) if (inGroup(o)) o];
    for (var i = 0; i < proxies.length; i++) {
      final o = proxies[i];
      final key = jsonEncode(Map.of(o)..remove('tag'));
      final known = names[key];
      final String name;
      if (known != null) {
        name = known;
      } else {
        final base = proxies.length == 1 ? remarks : '$remarks [${i + 1}]';
        var candidate = base;
        for (var n = 2; used.contains(candidate); n++) {
          candidate = '$base ($n)';
        }
        name = candidate;
        used.add(name);
        names[key] = name;
      }
      o['tag'] = name;
      changed = true;
    }
    final memberNames = [for (final o in members) o['tag'].toString()];
    if (memberNames.isNotEmpty) groups[remarks] = memberNames;
  }
  // группы и правила подписки — заберёт приложение, когда профиль запишется
  if (changed && (groups.length > 1 || (rules?.isNotEmpty ?? false))) {
    MyXrayMeta.pending.add(MyXrayMeta(groups, rules ?? const []));
    if (MyXrayMeta.pending.length > 8) MyXrayMeta.pending.removeAt(0);
  }
  return changed ? jsonEncode(data) : text;
}

/// Группы и правила подписки в формате Xray JSON (до записи профиля).
class MyXrayMeta {
  MyXrayMeta(this.groups, this.rules);

  final Map<String, List<String>> groups;
  final List rules;

  static final pending = <MyXrayMeta>[];
}

/// Имя сервера без служебной нумерации ядра («имя § 3») — так, как его показывает приложение.
String myCleanTag(String tag) => tag.replaceFirst(RegExp('§.*'), '').trimRight();
