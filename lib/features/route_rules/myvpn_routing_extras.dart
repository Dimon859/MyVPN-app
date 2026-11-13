// MyVPN: в «Маршрутизации» — импорт правил из других приложений, импортированные наборы
// и «Источники списков» (откуда брать geosite/geoip, автообновление).
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/connections/myvpn_connections.dart';
import 'package:hiddify/features/route_rules/myvpn_rule_import.dart';
import 'package:hiddify/features/route_rules/notifier/rules_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/myvpn_events.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const myImportMark = '📥 ';

void _mySay(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));

/// Имя набора из имени правила «📥 GeIP · блок».
String? myImportSetOf(Rule r) {
  if (!r.name.startsWith(myImportMark)) return null;
  final rest = r.name.substring(myImportMark.length);
  final i = rest.lastIndexOf(' · ');
  return i > 0 ? rest.substring(0, i) : rest;
}

class MyRoutingExtras extends HookConsumerWidget {
  const MyRoutingExtras({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final rules = ref.watch(rulesNotifierProvider);
    final sets = <String, List<Rule>>{};
    for (final r in rules) {
      final s = myImportSetOf(r);
      if (s != null) sets.putIfAbsent(s, () => []).add(r);
    }
    final source = ref.watch(myGeoSourceProvider);
    final src = myGeoSourceOf(source);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.download_rounded),
          title: const Text('Импорт правил из других приложений'),
          subtitle: const Text('Happ, v2RayTun, Incy, Streisand, Karing, Shadowrocket, Clash — ссылкой, текстом или файлом'),
          onTap: () => showMyImport(context, ref),
        ),
        ListTile(
          leading: const Icon(Icons.dataset_outlined),
          title: const Text('Источники списков (geosite / geoip)'),
          subtitle: Text(src == null ? 'Не загружать — списки не используются' : src.name),
          onTap: () => showMyGeoSources(context, ref),
        ),
        for (final e in sets.entries)
          ListTile(
            dense: true,
            leading: const Icon(Icons.inventory_2_outlined),
            title: Text('Набор «${e.key}»', style: theme.textTheme.bodyLarge),
            subtitle: Text(
              '${e.value.length} правил · ${e.value.every((r) => r.enabled) ? 'включены' : (e.value.any((r) => r.enabled) ? 'частично' : 'выключены')}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: e.value.any((r) => r.enabled),
                  onChanged: (v) async {
                    final n = ref.read(rulesNotifierProvider.notifier);
                    for (final r in e.value) {
                      await n.updateEnabled(v, r.listOrder);
                    }
                  },
                ),
                IconButton(
                  tooltip: 'Удалить набор',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () async {
                    await myDeleteImportSet(ref, e.key);
                    if (context.mounted) _mySay(context, 'Набор «${e.key}» удалён');
                  },
                ),
              ],
            ),
          ),
        const Divider(),
      ],
    );
  }
}

Future<void> myDeleteImportSet(WidgetRef ref, String name) async {
  final n = ref.read(rulesNotifierProvider.notifier);
  for (;;) {
    final r = ref.read(rulesNotifierProvider).where((r) => myImportSetOf(r) == name).firstOrNull;
    if (r == null) break;
    await n.deleteRule(r.listOrder);
  }
}

// ---------- импорт ----------

Future<void> showMyImport(BuildContext context, WidgetRef ref) async {
  final ctrl = TextEditingController();
  final text = await showDialog<String>(
    context: context,
    useRootNavigator: true,
    builder: (context) => AlertDialog(
      title: const Text('Импорт правил'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Вставьте ссылку (например happ://routing/…), JSON правил, конфиг Shadowrocket или Clash, '
              'или просто список сайтов и IP — по одному на строку.',
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              minLines: 4,
              maxLines: 8,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Вставьте сюда'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            final data = await Clipboard.getData(Clipboard.kTextPlain);
            ctrl.text = data?.text ?? '';
          },
          child: const Text('Из буфера'),
        ),
        TextButton(
          onPressed: () async {
            try {
              final res = await FilePicker.platform.pickFiles();
              final path = res?.files.single.path;
              if (path != null) ctrl.text = await File(path).readAsString();
            } catch (_) {
              if (context.mounted) _mySay(context, 'Не удалось прочитать файл');
            }
          },
          child: const Text('Из файла'),
        ),
        FilledButton(onPressed: () => Navigator.of(context).pop(ctrl.text), child: const Text('Разобрать')),
      ],
    ),
  );
  if (text == null || text.trim().isEmpty || !context.mounted) return;
  var plainAction = 'proxy';
  var res = myImportRules(text, plainAction: plainAction);
  if (res == null) {
    _mySay(context, 'Правил не нашлось — проверьте, что вставили');
    return;
  }
  if (res.format == 'список') {
    final a = await showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (context) => SimpleDialog(
        title: const Text('Что делать с этими сайтами?'),
        children: [
          for (final e in const {'proxy': 'Через VPN', 'direct': 'Напрямую', 'block': 'Блокировать'}.entries)
            SimpleDialogOption(onPressed: () => Navigator.of(context).pop(e.key), child: Text(e.value)),
        ],
      ),
    );
    if (a == null || !context.mounted) return;
    plainAction = a;
    res = myImportRules(text, plainAction: plainAction)!;
  }
  await _myImportPreview(context, ref, res);
}

Future<void> _myImportPreview(BuildContext context, WidgetRef ref, MyImportResult res) async {
  final name = TextEditingController(text: res.name);
  var applyDns = res.remoteDns != null || res.directDns != null;
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: Text('Формат: ${res.format}'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Название набора', isDense: true),
                ),
                const SizedBox(height: 10),
                Text('Будет перенесено (${res.count}):', style: theme.textTheme.labelLarge),
                for (final r in res.rules) Text('✅ ${myDescribeSpec(r)}', style: theme.textTheme.bodySmall),
                if (res.rules.any((r) => r.geo.isNotEmpty))
                  Text(
                    'Списки (geosite/geoip) берутся из «Источников списков».',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                if (res.remoteDns != null || res.directDns != null)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: applyDns,
                    onChanged: (v) => setState(() => applyDns = v ?? false),
                    title: const Text('Взять и DNS'),
                    subtitle: Text(
                      [
                        if (res.remoteDns != null) 'для VPN: ${res.remoteDns}',
                        if (res.directDns != null) 'напрямую: ${res.directDns}',
                      ].join('\n'),
                    ),
                  ),
                if (res.skipped.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Пропущено (${res.skipped.length}):', style: theme.textTheme.labelLarge),
                  for (final s in res.skipped.toSet()) Text('⚠️ $s', style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
            FilledButton(
              onPressed: () async {
                final setName = name.text.trim().isEmpty ? res.name : name.text.trim();
                await myDeleteImportSet(ref, setName);
                final n = ref.read(rulesNotifierProvider.notifier);
                // новое правило встаёт первым — добавляем с конца, чтобы порядок остался как в источнике
                for (final r in res.rules.reversed) {
                  final act = switch (r.action) {
                    'direct' => 'напрямую',
                    'block' => 'блок',
                    _ => 'через VPN',
                  };
                  await n.addRule(r.toRule('$myImportMark$setName · $act'));
                }
                if (applyDns) {
                  if (res.remoteDns != null) await ref.read(ConfigOptions.remoteDnsAddress.notifier).update(res.remoteDns!);
                  if (res.directDns != null) await ref.read(ConfigOptions.directDnsAddress.notifier).update(res.directDns!);
                }
                myEvent('Импорт правил «$setName» (${res.format}): ${res.rules.length} правил, пропущено ${res.skipped.length}');
                if (context.mounted) {
                  Navigator.of(context).pop();
                  _mySay(context, 'Импортировано: «$setName». VPN переподключится');
                }
              },
              child: const Text('Импортировать'),
            ),
          ],
        );
      },
    ),
  );
}

// ---------- источники списков ----------

abstract final class MyGeoUpdate {
  static Future<SharedPreferences> get _p => SharedPreferences.getInstance();
  static Future<bool> get auto async => (await _p).getBool('myvpn_geo_auto') ?? true;
  static Future<void> setAuto(bool v) async => (await _p).setBool('myvpn_geo_auto', v);
  static Future<int> get days async => (await _p).getInt('myvpn_geo_days') ?? 7;
  static Future<void> setDays(int v) async => (await _p).setInt('myvpn_geo_days', v);
  static Future<DateTime?> get last async {
    final v = (await _p).getInt('myvpn_geo_last');
    return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v);
  }

  static Future<void> _markNow() async => (await _p).setInt('myvpn_geo_last', DateTime.now().millisecondsSinceEpoch);

  /// Удалить скачанные ядром списки — при следующем подключении они скачаются заново.
  static Future<bool> _dropCache(WidgetRef ref) async {
    try {
      final dirs = await ref.read(appDirectoriesProvider.future);
      var any = false;
      for (final d in {dirs.baseDir.path, dirs.workingDir.path}) {
        for (final name in const ['data/clash.db', 'clash.db', 'data/cache.db', 'cache.db']) {
          final f = File('$d/$name');
          if (await f.exists()) {
            await f.delete();
            any = true;
          }
        }
      }
      return any;
    } catch (_) {
      return false;
    }
  }

  /// Обновить списки сейчас. Если VPN включён — он переподключится.
  static Future<void> now(WidgetRef ref) async {
    final running = ref.read(serviceRunningProvider);
    final conn = ref.read(connectionNotifierProvider.notifier);
    if (running) {
      await conn.toggleConnection();
      for (var i = 0; i < 20 && ref.read(serviceRunningProvider); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    await _dropCache(ref);
    await _markNow();
    myEvent('Списки geosite/geoip: обновление');
    if (running) await conn.toggleConnection();
  }

  /// Автообновление: когда VPN выключен и подошёл срок.
  static Future<void> tick(WidgetRef ref) async {
    if (ref.read(serviceRunningProvider) || !await auto) return;
    final l = await last;
    if (l == null) {
      await _markNow();
      return;
    }
    if (DateTime.now().difference(l) < Duration(days: await days)) return;
    await _dropCache(ref);
    await _markNow();
    myEvent('Списки geosite/geoip: автообновление (скачаются при подключении)');
  }
}

Future<void> showMyGeoSources(BuildContext context, WidgetRef ref) async {
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (_) => const _MyGeoDialog(),
  );
}

class _MyGeoDialog extends HookConsumerWidget {
  const _MyGeoDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final value = ref.watch(myGeoSourceProvider);
    final custom = value.startsWith('custom|') ? value.split('|') : null;
    final site = useTextEditingController(text: custom != null && custom.length > 1 ? custom[1] : '');
    final ip = useTextEditingController(text: custom != null && custom.length > 2 ? custom[2] : '');
    final tick = useState(0);
    final auto = useFuture(useMemoized(() => MyGeoUpdate.auto, [tick.value])).data ?? true;
    final days = useFuture(useMemoized(() => MyGeoUpdate.days, [tick.value])).data ?? 7;
    final last = useFuture(useMemoized(() => MyGeoUpdate.last, [tick.value])).data;
    final busy = useState(false);
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    Future<void> set(String v) async {
      await ref.read(myGeoSourceProvider.notifier).update(v);
      myEvent('Источник списков: ${myGeoSourceOf(v)?.name ?? 'не загружать'}');
    }

    Widget option(String id, String title, String sub) => ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        (id == 'custom' ? custom != null : value == id) ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
      ),
      title: Text(title),
      subtitle: sub.isEmpty ? null : Text(sub, style: small, maxLines: 3, overflow: TextOverflow.ellipsis),
      onTap: () async {
        if (id == 'custom') {
          if (site.text.trim().isEmpty && ip.text.trim().isEmpty) {
            site.text = myGeoSources.first.geosite;
            ip.text = myGeoSources.first.geoip;
          }
          await set('custom|${site.text.trim()}|${ip.text.trim()}');
        } else {
          await set(id);
        }
      },
    );

    String two(int v) => v.toString().padLeft(2, '0');
    return AlertDialog(
      title: const Text('Источники списков'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              'Откуда брать готовые списки сайтов (geosite:youtube, geosite:vk…) и IP (geoip:ru…) '
              'для импортированных правил и правил подписок.',
              style: small,
            ),
            for (final s in myGeoSources) option(s.id, s.name, s.note.isEmpty ? s.geosite : s.note),
            option('custom', 'Свои ссылки', 'Шаблон ссылки, вместо имени списка — {name}'),
            if (custom != null) ...[
              TextField(
                controller: site,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(isDense: true, labelText: 'Сайты (geosite), с {name}'),
                onSubmitted: (_) => set('custom|${site.text.trim()}|${ip.text.trim()}'),
              ),
              TextField(
                controller: ip,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(isDense: true, labelText: 'IP (geoip), с {name}, файл geoip-…'),
                onSubmitted: (_) => set('custom|${site.text.trim()}|${ip.text.trim()}'),
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: () => set('custom|${site.text.trim()}|${ip.text.trim()}'),
                  child: const Text('Сохранить ссылки'),
                ),
              ),
            ],
            option('none', 'Не загружать', 'Ничего не качать из интернета — правила со списками не действуют'),
            const Divider(),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Обновлять автоматически'),
              subtitle: Text(
                last == null ? 'Ещё не обновлялись' : 'Последнее: ${two(last.day)}.${two(last.month)} ${two(last.hour)}:${two(last.minute)}',
                style: small,
              ),
              value: auto,
              onChanged: (v) async {
                await MyGeoUpdate.setAuto(v);
                tick.value++;
              },
            ),
            if (auto)
              Wrap(
                spacing: 6,
                children: [
                  for (final d in const [1, 3, 7, 30])
                    ChoiceChip(
                      label: Text(switch (d) {
                        1 => 'раз в день',
                        3 => 'раз в 3 дня',
                        7 => 'раз в неделю',
                        _ => 'раз в месяц',
                      }),
                      selected: days == d,
                      onSelected: (_) async {
                        await MyGeoUpdate.setDays(d);
                        tick.value++;
                      },
                    ),
                ],
              ),
            Text(
              'Пока VPN включён, ядро само освежает списки раз в 5 дней.',
              style: small,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy.value
              ? null
              : () async {
                  busy.value = true;
                  await MyGeoUpdate.now(ref);
                  busy.value = false;
                  tick.value++;
                  if (context.mounted) _mySay(context, 'Списки скачаются заново при подключении');
                },
          child: Text(busy.value ? 'Обновляю…' : 'Обновить сейчас'),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Готово')),
      ],
    );
  }
}
