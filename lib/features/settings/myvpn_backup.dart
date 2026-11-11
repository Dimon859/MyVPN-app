// MyVPN: резервная копия подписок, «Моих серверов» и отметок (избранное, исключённые).
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hiddify/features/profile/data/myvpn_marks.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';

const _mySpecial = {'Все подписки', 'Избранное'};
const _myMine = 'Мои серверы';

void _mySnack(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 4)));
}

/// Собирает копию: подписки ссылками, локальные профили содержимым, отметки.
Future<Map<String, dynamic>> myBuildBackup(WidgetRef ref) async {
  final repo = await ref.read(profileRepositoryProvider.future);
  final profiles = (await repo.watchAll().first).getOrElse((_) => const []);
  final resolver = ref.read(profilePathResolverProvider);
  final items = <Map<String, dynamic>>[];
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
  return {
    'app': 'Tunnex',
    'version': 1,
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
    if (context.mounted && ok) _mySnack(context, 'Копия сохранена: ${(data['profiles'] as List).length} профилей');
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
    await MyMarks.load();
    MyMarks.fav.addAll([for (final k in (data['favorites'] as List?) ?? const []) k.toString()]);
    MyMarks.hidden.addAll([for (final k in (data['excluded'] as List?) ?? const []) k.toString()]);
    await MyMarks.save();
    await repo.myMarksChanged();
    if (context.mounted) {
      _mySnack(
        context,
        'Восстановлено: $added'
        '${skipped > 0 ? ', уже были: $skipped' : ''}'
        '${failed > 0 ? ', не удалось: $failed' : ''}',
      );
    }
  } catch (e) {
    if (context.mounted) _mySnack(context, 'Не удалось восстановить: $e');
  }
}
