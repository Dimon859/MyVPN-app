// MyVPN: избранные и исключённые из автовыбора серверы.
// Сервер узнаётся по своим настройкам (всё, кроме имени), поэтому отметка сохраняется
// после обновления подписки и действует во всех подписках, где он есть.
// Исключённый сервер получает в имени служебную метку «§hide§» — ядро не берёт такие
// серверы в автовыбор и балансировку.
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

const myHideMark = ' §hide§⛔';
const _mySkipTypes = {'selector', 'urltest', 'direct', 'block', 'dns'};

/// Ключ сервера: его настройки без имени.
String myServerKey(Map<String, dynamic> o) => jsonEncode(Map.of(o)..remove('tag'));

abstract final class MyMarks {
  static Set<String> fav = {};
  static Set<String> hidden = {};
  static Future<void>? _loading;

  static Future<void> load() => _loading ??= () async {
    try {
      final p = await SharedPreferences.getInstance();
      fav = (p.getStringList('myvpn_fav') ?? const []).toSet();
      hidden = (p.getStringList('myvpn_hidden') ?? const []).toSet();
    } catch (_) {}
  }();

  static Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('myvpn_fav', fav.toList());
      await p.setStringList('myvpn_hidden', hidden.toList());
    } catch (_) {}
  }
}

/// Проставляет и снимает метку исключения в JSON профиля. Один сервер всегда остаётся
/// доступным, иначе профиль нельзя было бы подключить. Возвращает null, если менять нечего.
String? myApplyHidden(String text, Set<String> hidden) {
  Object? json;
  try {
    json = jsonDecode(text);
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
  if (items.isEmpty) return null;
  String base(Map<String, dynamic> o) => (o['tag'] ?? '').toString().replaceAll(myHideMark, '');
  final want = [for (final o in items) hidden.contains(myServerKey(o))];
  // серверы, скрытые самой подпиской, тоже не в счёт
  final visible = [
    for (var i = 0; i < items.length; i++)
      if (!want[i] && !base(items[i]).contains('§hide§')) i,
  ];
  if (visible.isEmpty) {
    final first = want.indexOf(true);
    if (first >= 0) want[first] = false;
  }
  final renamed = <String, String>{};
  for (var i = 0; i < items.length; i++) {
    final b = base(items[i]);
    final tag = want[i] ? '$b$myHideMark' : b;
    final old = (items[i]['tag'] ?? '').toString();
    if (tag != old) {
      items[i]['tag'] = tag;
      renamed[old] = tag;
    }
  }
  if (renamed.isEmpty) return null;
  // цепочки серверов ссылаются друг на друга по имени — обновляем ссылки
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
  return jsonEncode(json);
}

/// То же для файла профиля.
Future<void> myApplyHiddenToFile(String path) async {
  await MyMarks.load();
  final file = File(path);
  if (!await file.exists()) return;
  final updated = myApplyHidden(await file.readAsString(), MyMarks.hidden);
  if (updated != null) await file.writeAsString(updated);
}
