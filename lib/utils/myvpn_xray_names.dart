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
  for (final c in configs) {
    if (c is! Map) continue;
    final remarks = (c['remarks'] ?? '').toString().trim();
    final outs = c['outbounds'];
    if (remarks.isEmpty || outs is! List) continue;
    final proxies = [
      for (final o in outs)
        if (o is Map && o['type'] == null && _myProxyProtocols.contains(o['protocol'])) o,
    ];
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
  }
  return changed ? jsonEncode(data) : text;
}

/// Имя сервера без служебной нумерации ядра («имя § 3») — так, как его показывает приложение.
String myCleanTag(String tag) => tag.replaceFirst(RegExp('§.*'), '').trimRight();
