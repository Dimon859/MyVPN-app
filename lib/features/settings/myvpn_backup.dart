// MyVPN: резервная копия подписок, «Моих серверов», отметок, всех настроек и правил маршрутизации.
// Нужна и для переезда на новый сертификат: там другое приложение, данные сами не переходят.
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/features/profile/data/myvpn_marks.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mySpecial = {'Все подписки', 'Избранное'};
const _myMine = 'Мои серверы';

void _mySnack(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 4)));
}

/// Профиль узнаётся в другом приложении по ссылке (подписка) или по имени — id там будут новые.
String _myKeyOf(ProfileEntity p) => switch (p) {
  RemoteProfileEntity(:final url) => 'r:$url',
  _ => 'l:${p.name}',
};

/// Собирает копию: подписки ссылками, локальные профили содержимым, отметки.
Future<Map<String, dynamic>> myBuildBackup(WidgetRef ref) async {
  final repo = await ref.read(profileRepositoryProvider.future);
  final profiles = (await repo.watchAll().first).getOrElse((_) => const []);
  final resolver = ref.read(profilePathResolverProvider);
  final items = <Map<String, dynamic>>[];
  final ids = <String, String>{for (final p in profiles) p.id: _myKeyOf(p)};
  final active = profiles.where((p) => p.active).map(_myKeyOf).firstOrNull;
  for (final p in profiles) {
    if (_mySpecial.contains(p.name)) continue;
    switch (p) {
      case RemoteProfileEntity(:final url):
        items.add({'type': 'remote', 'name': p.name, 'url': url});
      case LocalProfileEntity():
        final file = resolver.file(p.id);
        if (await file.exists()) items.add({'type': 'local', 'name': p.name, 'content': await file.readAsString()});
    }
  }
  await MyMarks.load();
  // все настройки приложения (HWID, лимиты, DNS, режимы, источники гео и т. д.)
  final prefs = await SharedPreferences.getInstance();
  final settings = <String, Map<String, Object?>>{};
  for (final k in prefs.getKeys()) {
    final v = prefs.get(k);
    final t = switch (v) {
      bool() => 'b',
      int() => 'i',
      double() => 'd',
      String() => 's',
      List() => 'l',
      _ => null,
    };
    if (t != null) settings[k] = {'t': t, 'v': v};
  }
  String? rules;
  try {
    final dirs = await ref.read(appDirectoriesProvider.future);
    final f = File('${dirs.baseDir.path}/route_rule.proto');
    if (await f.exists()) rules = base64Encode(await f.readAsBytes());
  } catch (_) {}
  return {
    'app': 'Tunnex',
    'version': 3,
    'settings': settings,
    'ids': ids,
    if (active != null) 'active': active,
    if (rules != null) 'routeRules': rules,
    'created': DateTime.now().toIso8601String(),
    'profiles': items,
    'favorites': MyMarks.fav.toList(),
    'excluded': MyMarks.hidden.toList(),
  };
}

Future<void> myExportBackup(BuildContext context, WidgetRef ref) async {
  try {
    final data = await myBuildBackup(ref);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/tunnex-backup-${now.year}-${two(now.month)}-${two(now.day)}.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    final ok = await UriUtils.tryShareFile(file.uri, mimeType: 'application/json');
    if (context.mounted && ok) _mySnack(context, 'Копия сохранена: ${(data['profiles'] as List).length} профилей и все настройки');
  } catch (e) {
    if (context.mounted) _mySnack(context, 'Не удалось сохранить копию: $e');
  }
}

Future<void> myImportBackup(BuildContext context, WidgetRef ref) async {
  try {
    final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
    final path = picked?.files.single.path;
    if (path == null) return;
    final data = jsonDecode(await File(path).readAsString());
    if (data is! Map || data['profiles'] is! List) throw const FormatException('это не копия Tunnex');
    if (context.mounted) _mySnack(context, 'Восстанавливаю… это может занять минуту');
    // настройки и правила маршрутизации (копия версии 2 и новее) — до подписок, чтобы подписки
    // сразу скачались со старым HWID, а не с новым случайным
    var withSettings = false;
    final settings = data['settings'];
    if (settings is Map && settings.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      for (final e in settings.entries) {
        final k = e.key.toString(), m = e.value;
        if (m is! Map) continue;
        final v = m['v'];
        try {
          switch (m['t']) {
            case 'b':
              await prefs.setBool(k, v as bool);
            case 'i':
              await prefs.setInt(k, (v as num).toInt());
            case 'd':
              await prefs.setDouble(k, (v as num).toDouble());
            case 's':
              await prefs.setString(k, v as String);
            case 'l':
              await prefs.setStringList(k, [for (final x in v as List) x.toString()]);
          }
        } catch (_) {}
      }
      withSettings = true;
    }
    final rules = data['routeRules'];
    if (rules is String && rules.isNotEmpty) {
      try {
        final dirs = await ref.read(appDirectoriesProvider.future);
        await File('${dirs.baseDir.path}/route_rule.proto').writeAsBytes(base64Decode(rules));
        withSettings = true;
      } catch (_) {}
    }
    DioHttpClient.myHwidReset();
    // отметки в памяти — ещё пустые от нового приложения; иначе первая же запись затрёт восстановленные
    if (withSettings) await MyMarks.reload();
    final repo = await ref.read(profileRepositoryProvider.future);
    final existing = (await repo.watchAll().first).getOrElse((_) => const []);
    final urls = {for (final p in existing) if (p case RemoteProfileEntity(:final url)) url};
    final names = {for (final p in existing) p.name};
    var added = 0, skipped = 0, failed = 0;
    for (final item in data['profiles'] as List) {
      if (item is! Map) continue;
      final name = (item['name'] ?? '').toString();
      if (item['type'] == 'remote') {
        final url = (item['url'] ?? '').toString();
        if (url.isEmpty || urls.contains(url)) {
          skipped++;
          continue;
        }
        final res = await repo
            .upsertRemote(url, userOverride: name.isEmpty ? null : UserOverride(name: name))
            .run();
        res.isRight() ? added++ : failed++;
      } else if (item['type'] == 'local') {
        final content = (item['content'] ?? '').toString();
        if (content.isEmpty) continue;
        if (name == _myMine) {
          // «Мои серверы» дополняются, дубли не добавятся
          final res = await repo.myAddToMine(content).run();
          res.isRight() ? added++ : failed++;
        } else if (names.contains(name)) {
          skipped++;
        } else {
          final res = await repo.addLocal(content, userOverride: name.isEmpty ? null : UserOverride(name: name)).run();
          res.isRight() ? added++ : failed++;
        }
      }
    }
    // отметки, привязанные к id профилей (выбранная группа, страны, правила подписки), — на новые id
    final now = (await repo.watchAll().first).getOrElse((_) => const []);
    final byKey = {for (final p in now) _myKeyOf(p): p.id};
    final oldIds = data['ids'] is Map ? (data['ids'] as Map).map((k, v) => MapEntry(k.toString(), v.toString())) : <String, String>{};
    String? newId(String old) => oldIds[old] == null ? null : byKey[oldIds[old]];
    Map<String, T> move<T>(Map<String, T> m) => {
      for (final e in m.entries)
        if (newId(e.key) != null) newId(e.key)! : e.value else if (byKey.containsValue(e.key)) e.key: e.value,
    };
    await MyMarks.reload();
    if (oldIds.isNotEmpty) {
      MyMarks.sections = move(MyMarks.sections);
      MyMarks.profileCountries = move(MyMarks.profileCountries);
      MyMarks.subGroups = move(MyMarks.subGroups);
      MyMarks.subRules = move(MyMarks.subRules);
      MyMarks.subRulesOff = {for (final id in MyMarks.subRulesOff) newId(id) ?? id};
    }
    MyMarks.fav.addAll([for (final k in (data['favorites'] as List?) ?? const []) k.toString()]);
    MyMarks.hidden.addAll([for (final k in (data['excluded'] as List?) ?? const []) k.toString()]);
    await MyMarks.save();
    await repo.myMarksChanged();
    // активный профиль — как был
    final activeId = data['active'] == null ? null : byKey[data['active'].toString()];
    if (activeId != null) await repo.setAsActive(activeId).run();
    final summary = 'Восстановлено: $added'
        '${skipped > 0 ? ', уже были: $skipped' : ''}'
        '${failed > 0 ? ', не удалось: $failed' : ''}';
    if (!context.mounted) return;
    if (!withSettings) {
      _mySnack(context, summary);
      return;
    }
    // настройки держатся в памяти и при работе перезаписываются — приложение надо открыть заново
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        title: const Text('Готово'),
        content: Text('$summary, плюс настройки и правила.\n\nПриложение закроется — откройте его снова, чтобы всё применилось.'),
        actions: [FilledButton(onPressed: () => exit(0), child: const Text('Закрыть приложение'))],
      ),
    );
  } catch (e) {
    if (context.mounted) _mySnack(context, 'Не удалось восстановить: $e');
  }
}
