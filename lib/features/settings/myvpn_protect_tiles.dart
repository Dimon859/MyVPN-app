// MyVPN: настройки защиты, детекторов и запасных путей (Настройки → Общие), DNS и проверка сети.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/myvpn_marks.dart';
import 'package:hiddify/features/profile/widget/myvpn_profile_extras.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/myvpn_detectors.dart';
import 'package:hiddify/features/settings/myvpn_events.dart';
import 'package:hiddify/features/settings/myvpn_guard.dart';
import 'package:hiddify/features/settings/myvpn_tools.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const myProtoList = ['Reality', 'VLESS', 'Hysteria2', 'Trojan', 'Shadowsocks', 'VMess', 'TUIC', 'WireGuard'];

/// DNS для адресов самих серверов (провайдер не видит, к каким серверам ты подключаешься).
const myServerDnsPresets = {
  'Обычный, без шифрования (как было)': '1.1.1.1',
  'Cloudflare, зашифрованный': 'https://1.1.1.1/dns-query',
  'Google, зашифрованный': 'https://8.8.8.8/dns-query',
  'AdGuard, зашифрованный': 'https://94.140.14.14/dns-query',
};

class MyProtectTiles extends HookConsumerWidget {
  const MyProtectTiles({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tick = useState(0);
    final check = useFuture(useMemoized(() => MyGuardPrefs.checkServers, [tick.value])).data ?? true;
    final chain = useFuture(useMemoized(() => MyGuardPrefs.chain, [tick.value])).data ?? const <String>[];
    final warp = useFuture(useMemoized(() => MyGuardPrefs.warpFallback, [tick.value])).data ?? false;
    useFuture(useMemoized(MyMarks.load));
    final mux = ref.watch(ConfigOptions.enableMux);
    final serverDns = ref.watch(ConfigOptions.directDnsAddress);
    final serverDnsName = myServerDnsPresets.entries.where((e) => e.value == serverDns).map((e) => e.key).firstOrNull;
    final theme = Theme.of(context);

    String typesText(String net) {
      final t = MyMarks.typesByNet[net];
      return t == null || t.isEmpty ? 'Все протоколы' : t.join(', ');
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Защита и детекторы', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.policy_outlined),
          title: const Text('Проверять серверы'),
          subtitle: const Text(
            'После подключения: не подменяет ли сервер сертификаты сайтов (⚠️), '
            'а на LTE — не замирают ли сайты после первых 16 КБ (🧊). Такие серверы уходят из автовыбора.',
          ),
          value: check,
          onChanged: (v) async {
            await MyGuardPrefs.setCheckServers(v);
            tick.value++;
          },
        ),
        if (MyMarks.bad.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.restart_alt_rounded),
            title: Text('Вернуть серверы, отмеченные детекторами (${MyMarks.bad.length})'),
            subtitle: const Text('Например, если сервер починили'),
            onTap: () async {
              MyMarks.bad.clear();
              await myApplyMarks(ref);
              tick.value++;
              if (context.mounted) mySnack(context, 'Отметки детекторов сняты. Переподключитесь, чтобы применить');
            },
          ),
        ListTile(
          leading: const Icon(Icons.water_drop_outlined),
          title: const Text('Проверка утечек'),
          subtitle: const Text('Видят ли сайты твой настоящий IP, DNS провайдера, IPv6'),
          onTap: () => showMyLeakTest(context),
        ),
        ListTile(
          leading: const Icon(Icons.list_alt_rounded),
          title: const Text('Журнал событий'),
          subtitle: const Text('Переключения, белые списки, отключения, детекторы'),
          onTap: () => showMyEvents(context),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Запасные пути', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.alt_route_rounded),
          title: const Text('Цепочка запасных подписок'),
          subtitle: Text(
            chain.isEmpty
                ? 'Выключена'
                : 'Подписок в цепочке: ${chain.length}. Нет живых серверов — переход к следующей, раз в 15 минут проверка первой',
          ),
          onTap: () async {
            await showMyChain(context, ref);
            tick.value++;
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.cloud_outlined),
          title: const Text('Запасной WARP'),
          subtitle: const Text(
            'Бесплатный Cloudflare WARP последним в цепочке: если не осталось ни одного живого сервера. '
            'Медленнее и проходит не везде.',
          ),
          value: warp,
          onChanged: (v) async {
            await MyGuardPrefs.setWarpFallback(v);
            if (v) {
              final p = await myEnsureWarpProfile(ref);
              if (context.mounted) {
                mySnack(context, p == null ? 'Не удалось добавить WARP' : 'WARP добавлен как запасной');
              }
            }
            tick.value++;
          },
        ),
        ListTile(
          leading: const Icon(Icons.wifi_rounded),
          title: const Text('Протоколы для Wi-Fi'),
          subtitle: Text(typesText('wifi')),
          onTap: () async {
            await showMyNetTypes(context, ref, 'wifi');
            tick.value++;
          },
        ),
        ListTile(
          leading: const Icon(Icons.signal_cellular_alt_rounded),
          title: const Text('Протоколы для LTE'),
          subtitle: Text(typesText('cell')),
          onTap: () async {
            await showMyNetTypes(context, ref, 'cell');
            tick.value++;
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.merge_type_rounded),
          title: const Text('Мультиплексирование (Mux)'),
          subtitle: const Text(
            'Несколько соединений внутри одного: на части серверов сайты открываются быстрее. '
            'Если сервер перестал работать — выключите.',
          ),
          value: mux,
          onChanged: (v) => ref.read(ConfigOptions.enableMux.notifier).update(v),
        ),
        ListTile(
          leading: const Icon(Icons.vpn_key_outlined),
          title: const Text('DNS для адресов серверов'),
          subtitle: Text(
            '${serverDnsName ?? 'Свой: $serverDns'}\n'
            'Зашифрованный — провайдер не видит и не подменяет адреса серверов. Если перестало подключаться — верните обычный',
          ),
          isThreeLine: true,
          onTap: () async {
            final picked = await showDialog<String>(
              context: context,
              useRootNavigator: true,
              builder: (context) => SimpleDialog(
                title: const Text('DNS для адресов серверов'),
                children: [
                  for (final e in myServerDnsPresets.entries)
                    SimpleDialogOption(
                      onPressed: () => Navigator.of(context).pop(e.value),
                      child: Text('${e.value == serverDns ? '✅ ' : ''}${e.key}'),
                    ),
                ],
              ),
            );
            if (picked == null) return;
            await ref.read(ConfigOptions.directDnsAddress.notifier).update(picked);
          },
        ),
      ],
    );
  }
}

/// Выбор цепочки: нажимай подписки по порядку.
Future<void> showMyChain(BuildContext context, WidgetRef ref) async {
  final profiles = (await myAllProfiles(ref)).where((p) => p.name != myWarpName).toList();
  final current = [...await MyGuardPrefs.chain];
  if (!context.mounted) return;
  final picked = await showDialog<List<String>>(
    context: context,
    useRootNavigator: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Цепочка запасных подписок'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('Нажимайте подписки по порядку: первая — основная, дальше запасные. Нажмите ещё раз, чтобы убрать.'),
              ),
              for (final p in profiles)
                ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 12,
                    child: Text(current.contains(p.id) ? '${current.indexOf(p.id) + 1}' : '', style: const TextStyle(fontSize: 12)),
                  ),
                  title: Text(p.name),
                  onTap: () => setState(() => current.contains(p.id) ? current.remove(p.id) : current.add(p.id)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(<String>[]), child: const Text('Выключить')),
          TextButton(onPressed: () => Navigator.of(context).pop(current), child: const Text('Сохранить')),
        ],
      ),
    ),
  );
  if (picked == null) return;
  await MyGuardPrefs.setChain(picked);
  myEvent(picked.isEmpty ? 'Цепочка запасных подписок выключена' : 'Цепочка запасных подписок: ${picked.length} шт.');
}

/// Какие протоколы брать на этой сети.
Future<void> showMyNetTypes(BuildContext context, WidgetRef ref, String net) async {
  await MyMarks.load();
  final cur = {...?MyMarks.typesByNet[net]};
  if (!context.mounted) return;
  final picked = await showDialog<Set<String>>(
    context: context,
    useRootNavigator: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('Протоколы: ${myNetName(net)}'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              const Text('Ничего не отмечено — все протоколы. Узнать, что проходит на сети: «Проверка сети».'),
              for (final t in myProtoList)
                CheckboxListTile(
                  dense: true,
                  title: Text(t),
                  value: cur.contains(t),
                  onChanged: (v) => setState(() => v == true ? cur.add(t) : cur.remove(t)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(<String>{}), child: const Text('Все')),
          TextButton(onPressed: () => Navigator.of(context).pop(cur), child: const Text('Сохранить')),
        ],
      ),
    ),
  );
  if (picked == null) return;
  MyMarks.typesByNet[net] = picked;
  await MyMarks.save();
  if (context.mounted) mySnack(context, 'Сохранено. Применится, когда телефон будет на этой сети');
}

/// DNS-страница: подобрать самый быстрый DNS.
class MyFastDnsTiles extends HookConsumerWidget {
  const MyFastDnsTiles({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tick = useState(0);
    final busy = useState(false);
    final auto = useFuture(useMemoized(() => MyGuardPrefs.fastDnsAuto, [tick.value])).data ?? false;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.speed_rounded),
          title: const Text('Подобрать самый быстрый DNS'),
          subtitle: Text(busy.value ? 'Замеряю…' : 'Замерит готовые DNS на этой сети и поставит быстрый'),
          onTap: busy.value
              ? null
              : () async {
                  busy.value = true;
                  final r = await myPickFastestDns(ref);
                  busy.value = false;
                  if (context.mounted) mySnack(context, r == null ? 'Ни один DNS не ответил' : 'Выбран $r');
                },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.autorenew_rounded),
          title: const Text('Подбирать при смене сети'),
          subtitle: const Text('Перешёл с Wi-Fi на LTE и обратно — DNS подберётся заново'),
          value: auto,
          onChanged: (v) async {
            await MyGuardPrefs.setFastDnsAuto(v);
            tick.value++;
          },
        ),
      ],
    );
  }
}

/// Проверка сети: подмена DNS и живые протоколы.
class MyNetCheckExtra extends HookConsumerWidget {
  const MyNetCheckExtra({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final running = ref.watch(serviceRunningProvider);
    final hijack = useFuture(useMemoized(myDnsHijackCheck)).data;
    final types = useFuture(useMemoized(() => myProtoOfTags(ref))).data;
    final list = running ? ref.watch(mainOutboundsNotifierProvider).valueOrNull : null;
    final stats = myProtoStats(list, types ?? const {});
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(),
        Text('Подмена DNS', style: theme.textTheme.labelLarge),
        if (hijack == null) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
        for (final l in hijack ?? const <String>[]) Text(l, style: theme.textTheme.bodySmall),
        const Divider(),
        Text('Протоколы (живые серверы по последней проверке)', style: theme.textTheme.labelLarge),
        if (!running) Text('Подключите VPN, чтобы увидеть', style: theme.textTheme.bodySmall),
        if (running && stats.isEmpty) Text('Нет данных', style: theme.textTheme.bodySmall),
        for (final e in (stats.entries.toList()..sort((a, b) => b.value.$1.compareTo(a.value.$1))))
          Text(
            '${e.value.$1 > 0 ? '✅' : '❌'} ${e.key}: ${e.value.$1} из ${e.value.$2}',
            style: theme.textTheme.bodySmall,
          ),
        if (running)
          TextButton(
            onPressed: () => unawaited(ref.read(proxyRepositoryProvider).urlTest('select').run()),
            child: const Text('Проверить серверы заново'),
          ),
      ],
    );
  }
}
