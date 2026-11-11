// MyVPN: инструменты и настройки Tunnex — таймер VPN, проверка сети и портов,
// детектор белых списков, замер скорости с VPN и без, готовые DNS, общие страны,
// небезопасные серверы, отпечаток TLS, подписка для белых списков.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/myvpn_marks.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/widget/myvpn_profile_extras.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------- Сеть ----------

/// Тип сети: «wifi», «cell» (мобильная) или «unknown».
Future<String> myNetType() async {
  try {
    final ifs = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
    bool has(String prefix) => ifs.any((i) => i.name.startsWith(prefix) && i.addresses.isNotEmpty);
    if (has('en0')) return 'wifi';
    if (has('pdp_ip')) return 'cell';
  } catch (_) {}
  return 'unknown';
}

String myNetName(String type) => switch (type) {
  'wifi' => 'Wi-Fi',
  'cell' => 'мобильная сеть',
  _ => 'сеть',
};

Future<bool> _myAny(List<(String, int)> targets) async {
  final results = await Future.wait([
    for (final t in targets) myTcpPing(t.$1, t.$2, timeout: const Duration(milliseconds: 2500)),
  ]);
  return results.any((r) => r != null);
}

/// «whitelist» — открываются только российские адреса, «ok» — всё открывается, «nonet» — ничего.
/// Проверка прямая, без VPN: при включённом VPN результат покажет связь через сервер.
Future<String> myDetectWhitelist() async {
  final ru = await _myAny([('77.88.8.8', 443), ('ya.ru', 443), ('vk.com', 443)]);
  final foreign = await _myAny([('1.1.1.1', 443), ('9.9.9.9', 443), ('www.wikipedia.org', 443)]);
  if (!ru && !foreign) return 'nonet';
  if (ru && !foreign) return 'whitelist';
  return 'ok';
}

const myCheckPorts = [80, 443, 2053, 2083, 2087, 2096, 8080, 8443];

/// Какие порты проходят: подключение к Cloudflare (слушает все эти порты).
Future<Map<int, int?>> myCheckPortsNow() async {
  final results = await Future.wait([
    for (final p in myCheckPorts) myTcpPing('cloudflare.com', p, timeout: const Duration(seconds: 3)),
  ]);
  return {for (var i = 0; i < myCheckPorts.length; i++) myCheckPorts[i]: results[i]};
}

Future<void> showMyNetworkCheck(BuildContext context, WidgetRef ref) async {
  final running = ref.read(serviceRunningProvider);
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (context) => FutureBuilder<(String, String, Map<int, int?>)>(
      future: () async {
        final net = await myNetType();
        final wl = await myDetectWhitelist();
        final ports = await myCheckPortsNow();
        return (net, wl, ports);
      }(),
      builder: (context, snap) {
        final theme = Theme.of(context);
        final data = snap.data;
        return AlertDialog(
          title: const Text('Проверка сети'),
          content: SizedBox(
            width: double.maxFinite,
            child: data == null
                ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
                : ListView(
                    shrinkWrap: true,
                    children: [
                      if (running)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            '⚠ VPN включён — проверка идёт через сервер. Чтобы проверить саму сеть, отключите VPN.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ListTile(dense: true, title: const Text('Сеть'), trailing: Text(myNetName(data.$1))),
                      ListTile(
                        dense: true,
                        title: const Text('Белые списки'),
                        trailing: Text(switch (data.$2) {
                          'whitelist' => '📶 похоже, включены',
                          'nonet' => '✖ нет интернета',
                          _ => '✅ нет',
                        }),
                      ),
                      const Divider(),
                      Text('Порты (Cloudflare)', style: theme.textTheme.labelLarge),
                      for (final e in data.$3.entries)
                        ListTile(
                          dense: true,
                          title: Text(':${e.key}'),
                          trailing: Text(
                            e.value == null ? '✖ закрыт' : '✅ ${e.value} ms',
                            style: TextStyle(color: e.value == null ? theme.colorScheme.error : const Color(0xFF34D399)),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Если на белых списках все порты закрыты — сеть пускает только разрешённые адреса. '
                          'Тогда помогают серверы у российских хостингов: отметьте их ⭐ или найдите фильтром 📶.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
          ),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Закрыть'))],
        );
      },
    ),
  );
}

// ---------- Подписка для белых списков ----------

abstract final class MyWhitelist {
  static Future<String?> profileId() async {
    try {
      return (await SharedPreferences.getInstance()).getString('myvpn_wl_profile');
    } catch (_) {
      return null;
    }
  }

  static Future<void> setProfileId(String? id) async {
    try {
      final p = await SharedPreferences.getInstance();
      id == null ? await p.remove('myvpn_wl_profile') : await p.setString('myvpn_wl_profile', id);
    } catch (_) {}
  }
}

Future<List<ProfileEntity>> myAllProfiles(WidgetRef ref) async {
  final repo = await ref.read(profileRepositoryProvider.future);
  return (await repo.watchAll().first).getOrElse((_) => const []);
}

Future<void> showMyWhitelistProfile(BuildContext context, WidgetRef ref) async {
  final profiles = await myAllProfiles(ref);
  final current = await MyWhitelist.profileId();
  if (!context.mounted) return;
  final picked = await showDialog<String>(
    context: context,
    useRootNavigator: true,
    builder: (context) => SimpleDialog(
      title: const Text('Подписка для белых списков'),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text('Когда Tunnex заметит белые списки, он предложит подключиться к ней.'),
        ),
        for (final p in profiles)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(p.id),
            child: Text('${p.id == current ? '✅ ' : ''}${p.name}'),
          ),
        SimpleDialogOption(onPressed: () => Navigator.of(context).pop(''), child: const Text('Не выбрана')),
      ],
    ),
  );
  if (picked == null) return;
  await MyWhitelist.setProfileId(picked.isEmpty ? null : picked);
  if (context.mounted) mySnack(context, picked.isEmpty ? 'Подписка не выбрана' : 'Сохранено');
}

// ---------- Таймер VPN ----------
// Файлы лежат в общей папке приложения; расширение VPN проверяет их и само отключается.

abstract final class MyTimer {
  static File _file(WidgetRef ref, String name) =>
      File('${ref.read(appDirectoriesProvider).requireValue.baseDir.path}/$name');

  static DateTime? stopAt(WidgetRef ref) {
    try {
      final f = _file(ref, 'myvpn_stop_at');
      if (!f.existsSync()) return null;
      final s = double.tryParse(f.readAsStringSync().trim());
      if (s == null || s <= 0) return null;
      final t = DateTime.fromMillisecondsSinceEpoch((s * 1000).round());
      return t.isAfter(DateTime.now()) ? t : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> setStopAfter(WidgetRef ref, Duration? d) async {
    final f = _file(ref, 'myvpn_stop_at');
    if (d == null) {
      if (await f.exists()) await f.delete();
      return;
    }
    await f.writeAsString('${DateTime.now().add(d).millisecondsSinceEpoch / 1000}');
  }

  static String? dailyOff(WidgetRef ref) {
    try {
      final f = _file(ref, 'myvpn_daily_off');
      if (!f.existsSync()) return null;
      final s = f.readAsStringSync().trim();
      return RegExp(r'^\d{1,2}:\d{2}$').hasMatch(s) ? s : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> setDailyOff(WidgetRef ref, TimeOfDay? t) async {
    final f = _file(ref, 'myvpn_daily_off');
    if (t == null) {
      if (await f.exists()) await f.delete();
      return;
    }
    await f.writeAsString('${t.hour}:${t.minute.toString().padLeft(2, '0')}');
  }
}

String myHm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

Future<void> showMyTimer(BuildContext context, WidgetRef ref) async {
  final options = <String, Duration?>{
    'Не выключать': null,
    '15 минут': const Duration(minutes: 15),
    '30 минут': const Duration(minutes: 30),
    '1 час': const Duration(hours: 1),
    '2 часа': const Duration(hours: 2),
    '4 часа': const Duration(hours: 4),
    '8 часов': const Duration(hours: 8),
  };
  final now = MyTimer.stopAt(ref);
  final picked = await showDialog<String>(
    context: context,
    useRootNavigator: true,
    builder: (context) => SimpleDialog(
      title: const Text('Выключить VPN через…'),
      children: [
        if (now != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('Сейчас: выключится в ${myHm(now)}'),
          ),
        for (final k in options.keys)
          SimpleDialogOption(onPressed: () => Navigator.of(context).pop(k), child: Text(k)),
      ],
    ),
  );
  if (picked == null) return;
  await MyTimer.setStopAfter(ref, options[picked]);
  final at = MyTimer.stopAt(ref);
  if (context.mounted) mySnack(context, at == null ? 'Таймер выключен' : 'VPN выключится в ${myHm(at)}');
}

Future<void> showMyDailyOff(BuildContext context, WidgetRef ref) async {
  final current = MyTimer.dailyOff(ref);
  final choice = await showDialog<String>(
    context: context,
    useRootNavigator: true,
    builder: (context) => SimpleDialog(
      title: const Text('Выключать VPN каждый день'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(current == null ? 'Сейчас: не выключать' : 'Сейчас: в $current'),
        ),
        SimpleDialogOption(onPressed: () => Navigator.of(context).pop('set'), child: const Text('Выбрать время')),
        SimpleDialogOption(onPressed: () => Navigator.of(context).pop('off'), child: const Text('Не выключать')),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'off') {
    await MyTimer.setDailyOff(ref, null);
    if (context.mounted) mySnack(context, 'Ежедневное выключение отменено');
    return;
  }
  final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 23, minute: 0));
  if (t == null) return;
  await MyTimer.setDailyOff(ref, t);
  if (context.mounted) mySnack(context, 'VPN будет выключаться каждый день в ${MyTimer.dailyOff(ref)}');
}

// ---------- Скорость с VPN и без ----------

abstract final class MySpeed {
  static Future<double?> _measure(List<String> urls) async {
    for (final url in urls) {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      try {
        final sw = Stopwatch()..start();
        final req = await client.getUrl(Uri.parse(url));
        final resp = await req.close().timeout(const Duration(seconds: 10));
        if (resp.statusCode != 200) continue;
        var bytes = 0;
        await for (final chunk in resp.timeout(const Duration(seconds: 10))) {
          bytes += chunk.length;
          if (sw.elapsed > const Duration(seconds: 12)) break;
        }
        sw.stop();
        if (bytes >= 200000) return bytes * 8 / sw.elapsedMicroseconds; // Мбит/с
      } catch (_) {
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  /// Замер скорости скачивания: без VPN — до российского сервера, через VPN — до Cloudflare.
  static Future<double?> run({required bool viaVpn}) async {
    final mbps = await _measure(
      viaVpn
          ? ['https://speed.cloudflare.com/__down?bytes=15000000', 'https://speedtest.selectel.ru/10MB']
          : ['https://speedtest.selectel.ru/10MB', 'https://speed.cloudflare.com/__down?bytes=15000000'],
    );
    if (mbps != null) {
      try {
        final p = await SharedPreferences.getInstance();
        await p.setString(
          viaVpn ? 'myvpn_speed_vpn' : 'myvpn_speed_direct',
          jsonEncode({'mbps': mbps, 'at': DateTime.now().millisecondsSinceEpoch}),
        );
      } catch (_) {}
    }
    return mbps;
  }

  static Future<({double mbps, DateTime at})?> last({required bool viaVpn}) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(viaVpn ? 'myvpn_speed_vpn' : 'myvpn_speed_direct');
      if (raw == null) return null;
      final m = jsonDecode(raw) as Map;
      return (mbps: (m['mbps'] as num).toDouble(), at: DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt()));
    } catch (_) {
      return null;
    }
  }
}

String myMbps(double v) => v >= 10 ? '${v.round()} Мбит/с' : '${v.toStringAsFixed(1)} Мбит/с';

// ---------- Готовые DNS ----------

const myDnsPresets = {
  'Cloudflare': 'https://1.1.1.1/dns-query',
  'Google': 'https://dns.google/dns-query',
  'Яндекс': 'https://common.dot.dns.yandex.net/dns-query',
  'AdGuard (режет рекламу)': 'https://dns.adguard-dns.com/dns-query',
  'Quad9': 'https://dns.quad9.net/dns-query',
};

class MyDnsPresetsTile extends ConsumerWidget {
  const MyDnsPresetsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(ConfigOptions.remoteDnsAddress);
    final name = myDnsPresets.entries.where((e) => e.value == current).map((e) => e.key).firstOrNull;
    return ListTile(
      leading: const Icon(Icons.dns_rounded),
      title: const Text('Готовые DNS'),
      subtitle: Text(name ?? 'Свой: $current'),
      onTap: () async {
        final picked = await showDialog<String>(
          context: context,
          useRootNavigator: true,
          builder: (context) => SimpleDialog(
            title: const Text('DNS через VPN'),
            children: [
              for (final e in myDnsPresets.entries)
                SimpleDialogOption(
                  onPressed: () => Navigator.of(context).pop(e.value),
                  child: Text('${e.value == current ? '✅ ' : ''}${e.key}'),
                ),
            ],
          ),
        );
        if (picked == null) return;
        await ref.read(ConfigOptions.remoteDnsAddress.notifier).update(picked);
        if (context.mounted) mySnack(context, 'DNS изменён. Переподключитесь, чтобы применить');
      },
    );
  }
}

// ---------- Общие фильтры автовыбора ----------

/// Флаги стран всех серверов во всех профилях.
Future<List<String>> myAllFlags(WidgetRef ref) async {
  final flags = <String>{};
  final resolver = ref.read(profilePathResolverProvider);
  for (final p in await myAllProfiles(ref)) {
    final file = resolver.file(p.id);
    if (!await file.exists()) continue;
    try {
      for (final s in myServersFromText(await file.readAsString())) {
        final f = myFlagOf(s.name);
        if (f.isNotEmpty) flags.add(f);
      }
    } catch (_) {}
  }
  return flags.toList()..sort();
}

class MyAutoSelectTiles extends HookConsumerWidget {
  const MyAutoSelectTiles({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tick = useState(0);
    useFuture(useMemoized(MyMarks.load));
    Future<void> apply(String message) async {
      await myApplyMarks(ref);
      tick.value++;
      if (context.mounted) mySnack(context, message);
    }

    final countries = MyMarks.countries;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.public_rounded),
          title: const Text('Страны для автовыбора'),
          subtitle: Text(countries.isEmpty ? 'Все страны' : (countries.toList()..sort()).join(' ')),
          onTap: () async {
            final flags = await myAllFlags(ref);
            if (!context.mounted) return;
            final picked = await showMyFlagsDialog(
              context,
              title: 'Страны для автовыбора',
              flags: flags,
              selected: {...countries},
              hint: 'Для всех подписок. У отдельной подписки можно выбрать свои: «•••» → «Серверы» → «Страны».',
            );
            if (picked == null) return;
            MyMarks.countries = picked;
            await apply('Готово. Переподключитесь, чтобы применить');
          },
        ),
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.lock_open_rounded),
          title: const Text('Не брать небезопасные 🔓'),
          subtitle: const Text('Без шифрования или с отключённой проверкой сертификата'),
          value: MyMarks.hideInsecure,
          onChanged: (v) async {
            MyMarks.hideInsecure = v;
            await apply(v ? 'Небезопасные исключены из автовыбора' : 'Небезопасные снова в автовыборе');
          },
        ),
        ListTile(
          leading: const Icon(Icons.fingerprint_rounded),
          title: const Text('Отпечаток TLS'),
          subtitle: Text(myFingerprints[MyMarks.fingerprint] ?? MyMarks.fingerprint),
          onTap: () async {
            final picked = await showDialog<String>(
              context: context,
              useRootNavigator: true,
              builder: (context) => SimpleDialog(
                title: const Text('Отпечаток TLS для всех серверов'),
                children: [
                  for (final e in myFingerprints.entries)
                    SimpleDialogOption(
                      onPressed: () => Navigator.of(context).pop(e.key),
                      child: Text('${e.key == MyMarks.fingerprint ? '✅ ' : ''}${e.value}'),
                    ),
                ],
              ),
            );
            if (picked == null) return;
            MyMarks.fingerprint = picked;
            await apply('Готово. Переподключитесь, чтобы применить');
          },
        ),
      ],
    );
  }
}

/// Пункты для «Настройки» → «Общие».
class MyToolsTiles extends HookConsumerWidget {
  const MyToolsTiles({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tick = useState(0);
    final stopAt = MyTimer.stopAt(ref);
    final daily = MyTimer.dailyOff(ref);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const MyAutoSelectTiles(),
        ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: const Text('Выключить VPN через…'),
          subtitle: Text(stopAt == null ? 'Не выключать' : 'Выключится в ${myHm(stopAt)}'),
          onTap: () async {
            await showMyTimer(context, ref);
            tick.value++;
          },
        ),
        ListTile(
          leading: const Icon(Icons.bedtime_outlined),
          title: const Text('Выключать каждый день'),
          subtitle: Text(daily == null ? 'Не выключать' : 'В $daily'),
          onTap: () async {
            await showMyDailyOff(context, ref);
            tick.value++;
          },
        ),
        ListTile(
          leading: const Icon(Icons.signal_cellular_alt_rounded),
          title: const Text('Подписка для белых списков'),
          subtitle: const Text('Её Tunnex предложит, когда заметит белые списки'),
          onTap: () => showMyWhitelistProfile(context, ref),
        ),
        ListTile(
          leading: const Icon(Icons.network_check_rounded),
          title: const Text('Проверка сети'),
          subtitle: const Text('Белые списки и открытые порты'),
          onTap: () => showMyNetworkCheck(context, ref),
        ),
      ],
    );
  }
}
