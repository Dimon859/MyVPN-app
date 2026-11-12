// MyVPN: отметки серверов и фильтры автовыбора.
//
// У каждого профиля рядом с его файлом лежит копия того, что пришло из подписки
// («<id>.orig.json»). Файл профиля, который читает ядро, каждый раз собирается из этой копии:
//  • исключённые вручную серверы, серверы не из выбранных стран, не из выбранного раздела
//    и (по желанию) небезопасные получают в имени метку «§hide§» — ядро не берёт их
//    в автовыбор и балансировку;
//  • по желанию у всех серверов подменяется отпечаток TLS.
// Поэтому любая настройка включается и выключается без потерь, а после обновления подписки
// применяется заново.
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

const myHideMark = ' §hide§⛔';
const _mySkipTypes = {'selector', 'urltest', 'direct', 'block', 'dns'};
const _myQuicTypes = {'hysteria2', 'hysteria', 'tuic', 'wireguard'};

/// Отпечатки TLS (uTLS), которые понимает ядро.
const myFingerprints = {
  '': 'Как в подписке (лучший вариант)',
  'chrome': 'Chrome — в России часто блокируется',
  'safari': 'Safari',
  'ios': 'iOS',
  'firefox': 'Firefox',
  'edge': 'Edge',
  'android': 'Android',
  'random': 'Случайный',
  'randomized': 'Случайный (каждый раз новый)',
};

Map<String, dynamic> _myWithoutFp(Map<String, dynamic> o) {
  final c = Map<String, dynamic>.of(o)..remove('tag');
  final tls = c['tls'];
  if (tls is Map) c['tls'] = Map.of(tls)..remove('utls');
  return c;
}

/// Ключ сервера: его настройки без имени и без отпечатка TLS.
String myServerKey(Map<String, dynamic> o) => jsonEncode(_myWithoutFp(o));

/// Ключ, как его считала версия 1.3.0 (с отпечатком) — чтобы старые отметки не потерялись.
String myLegacyKey(Map<String, dynamic> o) => jsonEncode(Map.of(o)..remove('tag'));

bool myHasKey(Set<String> set, Map<String, dynamic> o) => set.contains(myServerKey(o)) || set.contains(myLegacyKey(o));

/// Имя без служебной нумерации ядра («имя § 3») и без нашей метки.
String myCleanName(String tag) => tag.replaceAll(myHideMark, '').replaceFirst(RegExp('§.*'), '').trimRight();

/// Раздел, к которому относится сервер: «Автовыбор [3]» → «Автовыбор», «🇩🇪 DE | Berlin [1.2]» → «🇩🇪 DE | Berlin».
String myGroupKey(String cleanName) {
  final key = cleanName.replaceFirst(RegExp(r'\s*(\[\d+(\.\d+)?\]|\(\d+\))$'), '').trim();
  return key.isEmpty ? cleanName : key;
}

/// Флаг страны в начале имени («🇩🇪 DE | Berlin» → «🇩🇪»), иначе пусто.
String myFlagOf(String name) {
  final runes = name.trimLeft().runes.toList();
  bool isRegional(int r) => r >= 0x1F1E6 && r <= 0x1F1FF;
  if (runes.length >= 2 && isRegional(runes[0]) && isRegional(runes[1])) {
    return String.fromCharCodes(runes.take(2));
  }
  return '';
}

/// Почему сервер небезопасен, или null.
String? myInsecureReason(Map<String, dynamic> o) {
  final type = (o['type'] ?? '').toString();
  final tls = o['tls'];
  final tlsOn = tls is Map && tls['enabled'] == true;
  if (tlsOn && tls['insecure'] == true) return 'проверка сертификата отключена';
  // у этих протоколов шифрование своё или обязательное
  if (const {'shadowsocks', 'hysteria2', 'hysteria', 'tuic', 'wireguard', 'ssh', 'shadowtls', 'anytls'}.contains(type)) {
    return null;
  }
  if (!tlsOn && const {'vless', 'vmess', 'trojan', 'http', 'socks'}.contains(type)) {
    if (type == 'vmess' && (o['security'] ?? 'auto') != 'none' && o['security'] != 'zero') return null;
    return 'без шифрования';
  }
  return null;
}

/// Настройки и отметки (хранятся в приложении).
abstract final class MyMarks {
  static Set<String> fav = {};
  static Set<String> hidden = {};
  static Set<String> lteOk = {};
  static Set<String> countries = {}; // общие для всех подписок; пусто — все страны
  static Map<String, Set<String>> profileCountries = {}; // id профиля → страны; пусто — как общие
  static Map<String, String> sections = {}; // id профиля → раздел для автовыбора
  static bool hideInsecure = false;
  static String fingerprint = '';
  static Future<void>? _loading;

  static Future<void> load() => _loading ??= () async {
    try {
      final p = await SharedPreferences.getInstance();
      fav = (p.getStringList('myvpn_fav') ?? const []).toSet();
      hidden = (p.getStringList('myvpn_hidden') ?? const []).toSet();
      lteOk = (p.getStringList('myvpn_lte_ok') ?? const []).toSet();
      countries = (p.getStringList('myvpn_countries') ?? const []).toSet();
      hideInsecure = p.getBool('myvpn_hide_insecure') ?? false;
      fingerprint = p.getString('myvpn_fingerprint') ?? '';
      final pc = p.getString('myvpn_profile_countries');
      if (pc != null) {
        profileCountries = {
          for (final e in (jsonDecode(pc) as Map).entries) e.key.toString(): {for (final f in e.value as List) f.toString()},
        };
      }
      final sec = p.getString('myvpn_sections');
      if (sec != null) sections = (jsonDecode(sec) as Map).map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {}
  }();

  static Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('myvpn_fav', fav.toList());
      await p.setStringList('myvpn_hidden', hidden.toList());
      await p.setStringList('myvpn_lte_ok', lteOk.toList());
      await p.setStringList('myvpn_countries', countries.toList());
      await p.setBool('myvpn_hide_insecure', hideInsecure);
      await p.setString('myvpn_fingerprint', fingerprint);
      await p.setString(
        'myvpn_profile_countries',
        jsonEncode(profileCountries.map((k, v) => MapEntry(k, v.toList()))),
      );
      await p.setString('myvpn_sections', jsonEncode(sections));
    } catch (_) {}
  }

  /// Страны автовыбора для профиля: свои, если выбраны, иначе общие.
  static Set<String> countriesFor(String? profileId) {
    final own = profileId == null ? null : profileCountries[profileId];
    return (own != null && own.isNotEmpty) ? own : countries;
  }
}

/// Что сделать с профилем.
class MyTransformOptions {
  const MyTransformOptions({
    this.hidden = const {},
    this.countries = const {},
    this.section,
    this.hideInsecure = false,
    this.fingerprint = '',
  });

  factory MyTransformOptions.forProfile(String? profileId) => MyTransformOptions(
    hidden: MyMarks.hidden,
    countries: MyMarks.countriesFor(profileId),
    section: profileId == null ? null : MyMarks.sections[profileId],
    hideInsecure: MyMarks.hideInsecure,
    fingerprint: MyMarks.fingerprint,
  );

  final Set<String> hidden;
  final Set<String> countries;
  final String? section;
  final bool hideInsecure;
  final String fingerprint;
}

/// Почему сервер не в автовыборе (для списка), или null.
String? myHiddenReason(Map<String, dynamic> o, MyTransformOptions opt) {
  final name = myCleanName((o['tag'] ?? '').toString());
  if (myHasKey(opt.hidden, o)) return 'исключён вручную';
  if (opt.section != null && myGroupKey(name) != opt.section) return 'не из выбранного раздела';
  final flag = myFlagOf(name);
  if (opt.countries.isNotEmpty && flag.isNotEmpty && !opt.countries.contains(flag)) return 'страна не выбрана';
  if (opt.hideInsecure && myInsecureReason(o) != null) return 'небезопасный';
  return null;
}

/// Собирает файл профиля из копии подписки [origText]. null — если разобрать не удалось.
String? myTransform(String origText, MyTransformOptions opt) {
  Object? json;
  try {
    json = jsonDecode(origText);
  } catch (_) {
    return null;
  }
  if (json is! Map<String, dynamic>) return null;
  final items = <Map<String, dynamic>>[];
  for (final key in const ['outbounds', 'endpoints']) {
    final list = json[key];
    if (list is! List) continue;
    for (final item in list) {
      if (item is Map<String, dynamic> && !_mySkipTypes.contains(item['type'])) items.add(item);
    }
  }
  String base(Map<String, dynamic> o) => (o['tag'] ?? '').toString().replaceAll(myHideMark, '');
  // причины считаем по исходному серверу (до подмены отпечатка)
  final want = [for (final o in items) myHiddenReason(o, opt) != null];
  // раздел, которого больше нет в подписке, не должен оставить её без серверов
  bool noneVisible() => ![
    for (var i = 0; i < items.length; i++) !want[i] && !base(items[i]).contains('§hide§'),
  ].contains(true);
  if (items.isNotEmpty && noneVisible() && opt.section != null) {
    final relaxed = MyTransformOptions(
      hidden: opt.hidden,
      countries: opt.countries,
      hideInsecure: opt.hideInsecure,
      fingerprint: opt.fingerprint,
    );
    for (var i = 0; i < items.length; i++) {
      want[i] = myHiddenReason(items[i], relaxed) != null;
    }
  }
  if (items.isNotEmpty && noneVisible()) {
    final first = want.indexOf(true);
    if (first >= 0) want[first] = false;
  }
  final renamed = <String, String>{};
  for (var i = 0; i < items.length; i++) {
    final o = items[i];
    final b = base(o);
    final tag = want[i] ? '$b$myHideMark' : b;
    final old = (o['tag'] ?? '').toString();
    if (tag != old) {
      o['tag'] = tag;
      renamed[old] = tag;
    }
    // свой отпечаток TLS (кроме QUIC-протоколов, там он не применяется)
    final tls = o['tls'];
    if (opt.fingerprint.isNotEmpty && tls is Map<String, dynamic> && tls['enabled'] == true && !_myQuicTypes.contains(o['type'])) {
      tls['utls'] = {'enabled': true, 'fingerprint': opt.fingerprint};
    }
  }
  // цепочки серверов ссылаются друг на друга по имени — обновляем ссылки
  if (renamed.isNotEmpty) {
    for (final key in const ['outbounds', 'endpoints']) {
      final list = json[key];
      if (list is! List) continue;
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final detour = item['detour'];
        if (detour is String && renamed.containsKey(detour)) item['detour'] = renamed[detour];
        final members = item['outbounds'];
        if (members is List) {
          for (var j = 0; j < members.length; j++) {
            final m = members[j];
            if (m is String && renamed.containsKey(m)) members[j] = renamed[m];
          }
        }
      }
    }
  }
  return jsonEncode(json);
}

/// Совместимость с 1.3.0: только исключённые вручную.
String? myApplyHidden(String text, Set<String> hidden) {
  final out = myTransform(text, MyTransformOptions(hidden: hidden));
  return out == null || out == jsonEncode(jsonDecode(text)) ? null : out;
}

String myOrigPath(String path) => path.endsWith('.json') ? '${path.substring(0, path.length - 5)}.orig.json' : '$path.orig';

/// Профиль по пути его файла: «…/<id>.json» → id.
String? myProfileIdOf(String path) {
  final name = path.split(Platform.pathSeparator).last.split('/').last;
  return name.endsWith('.json') ? name.substring(0, name.length - 5) : null;
}

/// Файл профиля только что записан заново (обновление подписки): сохранить копию и применить настройки.
Future<void> myAfterProfileWritten(String path) async {
  final file = File(path);
  if (!await file.exists()) return;
  await file.copy(myOrigPath(path));
  await myApplyToFile(path);
}

/// Пересобрать файл профиля из копии подписки по текущим настройкам.
Future<void> myApplyToFile(String path) async {
  await MyMarks.load();
  final file = File(path);
  if (!await file.exists()) return;
  final orig = File(myOrigPath(path));
  if (!await orig.exists()) {
    // профиль из прошлой версии: копии ещё нет — создаём из текущего файла без наших меток
    final cleaned = myTransform(await file.readAsString(), const MyTransformOptions());
    if (cleaned == null) return;
    await orig.writeAsString(cleaned);
  }
  final out = myTransform(await orig.readAsString(), MyTransformOptions.forProfile(myProfileIdOf(path)));
  if (out != null && out != await file.readAsString()) await file.writeAsString(out);
}

/// Совместимость с прежним названием.
Future<void> myApplyHiddenToFile(String path) => myApplyToFile(path);
