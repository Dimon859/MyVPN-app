// MyVPN: фоновый «сторож», пока приложение открыто.
// • после смены сервера проверяет его на подмену сертификатов (⚠️) и «заморозку после 16 КБ» (🧊, только LTE);
// • следит, не сменился ли у сервера IP выхода;
// • цепочка запасных подписок: если в текущей не осталось живых серверов — переход к следующей (последней может быть WARP);
// • протоколы для каждой сети (Wi-Fi / LTE);
// • раскладка трафика общих профилей по исходным подпискам;
// • подписки, которые не скачались напрямую, обновляются через VPN после подключения;
// • самый быстрый DNS при смене сети (если включено).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/myvpn_marks.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/notifier/profiles_update_notifier.dart';
import 'package:hiddify/features/profile/widget/myvpn_profile_extras.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/myvpn_detectors.dart';
import 'package:hiddify/features/settings/myvpn_events.dart';
import 'package:hiddify/features/settings/myvpn_tools.dart';
import 'package:hiddify/features/stats/myvpn_counters.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart' hide IpInfo;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const myWarpName = '☁️ WARP';

/// Настройки сторожа (в SharedPreferences).
abstract final class MyGuardPrefs {
  static Future<SharedPreferences> get _p => SharedPreferences.getInstance();

  static Future<bool> get checkServers async => (await _p).getBool('myvpn_guard_check') ?? true;
  static Future<void> setCheckServers(bool v) async => (await _p).setBool('myvpn_guard_check', v);

  static Future<bool> get fastDnsAuto async => (await _p).getBool('myvpn_fast_dns_auto') ?? false;
  static Future<void> setFastDnsAuto(bool v) async => (await _p).setBool('myvpn_fast_dns_auto', v);

  /// Цепочка запасных подписок: id по порядку (пусто — выключено).
  static Future<List<String>> get chain async => (await _p).getStringList('myvpn_chain') ?? const [];
  static Future<void> setChain(List<String> ids) async => (await _p).setStringList('myvpn_chain', ids);

  static Future<bool> get warpFallback async => (await _p).getBool('myvpn_warp_fallback') ?? false;
  static Future<void> setWarpFallback(bool v) async => (await _p).setBool('myvpn_warp_fallback', v);
}

/// Профиль WARP: создаётся один раз (ядро само регистрирует бесплатный аккаунт Cloudflare).
Future<ProfileEntity?> myEnsureWarpProfile(WidgetRef ref) async {
  final profiles = await myAllProfiles(ref);
  final have = profiles.where((p) => p.name == myWarpName).firstOrNull;
  if (have != null) return have;
  final repo = await ref.read(profileRepositoryProvider.future);
  final content = jsonEncode({
    'endpoints': [
      {
        'type': 'warp',
        'tag': '☁️ WARP',
        'unique_identifier': 'tunnex-warp-fallback',
        'mode': 'auto',
        'scanner': <String, dynamic>{},
      },
    ],
  });
  final res = await repo.addLocal(content, userOverride: const UserOverride(name: myWarpName)).run();
  if (res.isLeft()) return null;
  return (await myAllProfiles(ref)).where((p) => p.name == myWarpName).firstOrNull;
}

abstract final class MyGuard {
  static bool _busy = false;
  static String? _checkedTag;
  static String? _lastNet;
  static String? _ipTag, _ipValue;
  static DateTime? _ipAt;
  static int _deadTicks = 0;
  static DateTime? _lastTryFirst;
  static bool _retriedUpdates = false;
  static bool _wasRunning = false;
  static String? _ownersFor;

  /// Раз в 30 секунд с главного экрана.
  static Future<void> tick(BuildContext context, WidgetRef ref, OutboundGroupList? list) async {
    if (_busy) return;
    _busy = true;
    try {
      final running = ref.read(serviceRunningProvider);
      final net = await myNetType();
      final netChanged = _lastNet != null && _lastNet != net;
      _lastNet = net;

      if (running != _wasRunning) {
        myEvent(running ? 'VPN включён' : 'VPN выключен');
        _wasRunning = running;
        if (!running) {
          _checkedTag = null;
          _deadTicks = 0;
          _retriedUpdates = false;
        }
      }
      if (netChanged) myEvent('Сеть: ${myNetName(net)}');

      await MyMarks.load();
      // протоколы для этой сети
      if (net != 'unknown') {
        final want = MyMarks.typesByNet[net] ?? const <String>{};
        if (want.length != MyMarks.allowTypes.length || !want.containsAll(MyMarks.allowTypes)) {
          MyMarks.allowTypes = {...want};
          await myApplyMarks(ref);
          myEvent('Протоколы для сети «${myNetName(net)}»: ${want.isEmpty ? 'все' : want.join(', ')}');
          final active = await ref.read(activeProfileProvider.future);
          if (running && active != null) await myConnectTo(ref, active, reload: true);
          return;
        }
      }
      // самый быстрый DNS при смене сети
      if (netChanged && await MyGuardPrefs.fastDnsAuto) unawaited(myPickFastestDns(ref, quiet: true));

      if (!running) return;
      final active = await ref.read(activeProfileProvider.future);
      if (active == null) return;

      // раскладка трафика общих профилей
      if (MyCounters.combined.contains(active.name) && _ownersFor != '${active.id}${active.lastUpdate}') {
        _ownersFor = '${active.id}${active.lastUpdate}';
        MyCounters.owners = await myBuildOwners(ref, active);
      }

      // подписки, которые не скачались напрямую — через VPN
      if (!_retriedUpdates) {
        _retriedUpdates = true;
        unawaited(_myRetryFailingUpdates(ref));
      }

      final tag = list == null ? null : _myCurrentTag(list);
      if (tag == null) return;
      final server = await myServerOfTag(ref, active, tag);

      // проверка нового сервера: подмена сертификатов и «заморозка»
      if (server != null && _checkedTag != tag && await MyGuardPrefs.checkServers) {
        _checkedTag = tag;
        final mitm = await myCheckMitm();
        if (mitm == true) {
          await myMarkBad(ref, server, '⚠️ подменяет сертификаты');
          if (context.mounted) mySnack(context, '⚠️ ${server.name} подменяет сертификаты сайтов — исключён из автовыбора');
          return;
        }
        if (net == 'cell') {
          final frozen = await myCheckFreeze();
          if (frozen == true) {
            await myMarkBad(ref, server, '🧊 замирает после 16 КБ');
            if (context.mounted) mySnack(context, '🧊 ${server.name}: сайты замирают после первых КБ — исключён из автовыбора');
            return;
          }
        }
      }

      // смена IP выхода у того же сервера (раз в 5 минут)
      if (_ipAt == null || DateTime.now().difference(_ipAt!) > const Duration(minutes: 5) || _ipTag != tag) {
        final ip = await myExitIp();
        _ipAt = DateTime.now();
        if (ip != null) {
          if (_ipTag == tag && _ipValue != null && _ipValue != ip) {
            myEvent('🔄 ${server?.name ?? tag} сменил IP выхода: $_ipValue → $ip');
            if (context.mounted) mySnack(context, '🔄 Сервер сменил IP выхода — сайты могут попросить войти заново');
          }
          _ipTag = tag;
          _ipValue = ip;
        }
      }

      // цепочка запасных подписок
      await _myChainStep(context, ref, list!, active, net);
    } catch (_) {
    } finally {
      _busy = false;
    }
  }

  static String? _myCurrentTag(OutboundGroupList list) {
    final sel = list.items.firstOrNull?.items.firstOrNull;
    if (sel == null) return null;
    if (sel.isGroup) return sel.hasGroupSelectedTag() && sel.groupSelectedTag.isNotEmpty ? sel.groupSelectedTag : null;
    return sel.tag;
  }

  static bool _allDead(OutboundGroupList list) {
    final servers = list.items.firstOrNull?.items.where((o) => !o.isGroup).toList() ?? const [];
    if (servers.isEmpty) return false;
    // все проверены и ни один не ответил
    return servers.every((o) => o.urlTestDelay >= 65000);
  }

  static Future<void> _myChainStep(
    BuildContext context,
    WidgetRef ref,
    OutboundGroupList list,
    ProfileEntity active,
    String net,
  ) async {
    final ids = [...await MyGuardPrefs.chain];
    if (await MyGuardPrefs.warpFallback) {
      final warp = await myEnsureWarpProfile(ref);
      if (warp != null && !ids.contains(warp.id)) ids.add(warp.id);
    }
    if (ids.isEmpty) return;
    final profiles = await myAllProfiles(ref);
    ProfileEntity? byId(String id) => profiles.where((p) => p.id == id).firstOrNull;
    final pos = ids.indexOf(active.id);

    if (_allDead(list)) {
      if (++_deadTicks < 2) {
        // проверим ещё раз, прежде чем уходить
        unawaited(ref.read(proxyRepositoryProvider).urlTest('select').run());
        return;
      }
      _deadTicks = 0;
      for (var i = pos + 1; i < ids.length; i++) {
        final next = byId(ids[i]);
        if (next == null) continue;
        myEvent('Нет живых серверов в «${active.name}» — переход на «${next.name}»');
        if (context.mounted) mySnack(context, 'Нет живых серверов — переключаю на «${next.name}»');
        _lastTryFirst = DateTime.now();
        _checkedTag = null;
        await myConnectTo(ref, next);
        return;
      }
      return;
    }
    _deadTicks = 0;

    // мы на запасной: раз в 15 минут пробуем вернуться на первую
    if (pos > 0) {
      final due = _lastTryFirst == null || DateTime.now().difference(_lastTryFirst!) > const Duration(minutes: 15);
      if (!due) return;
      _lastTryFirst = DateTime.now();
      final first = byId(ids.first);
      if (first == null) return;
      await myConnectTo(ref, first);
      await Future<void>.delayed(const Duration(seconds: 25));
      final fresh = await ref.read(mainOutboundsNotifierProvider.future).catchError((_) => OutboundGroupList());
      if (_allDead(fresh)) {
        await myConnectTo(ref, active);
      } else {
        myEvent('«${first.name}» снова работает — вернулся на неё');
        if (context.mounted) mySnack(context, '«${first.name}» снова работает — вернулся');
      }
    }
  }
}

/// Для общих профилей: тег сервера → имя исходной подписки.
Future<Map<String, String>> myBuildOwners(WidgetRef ref, ProfileEntity combined) async {
  final out = <String, String>{};
  try {
    final resolver = ref.read(profilePathResolverProvider);
    final keyOwner = <String, String>{};
    for (final p in await myAllProfiles(ref)) {
      if (p.id == combined.id || MyCounters.combined.contains(p.name) || p.name == myWarpName) continue;
      final file = resolver.file(p.id);
      final orig = File(myOrigPath(file.path));
      final f = await orig.exists() ? orig : file;
      if (!await f.exists()) continue;
      for (final s in myServersFromText(await f.readAsString())) {
        keyOwner.putIfAbsent(s.key, () => p.name);
      }
    }
    final file = resolver.file(combined.id);
    for (final s in myServersFromText(await file.readAsString())) {
      final owner = keyOwner[s.key];
      if (owner != null) out[s.tag] = owner;
    }
  } catch (_) {}
  return out;
}

/// Подписки, которые не обновились напрямую, — обновить сейчас, когда VPN включён.
Future<void> _myRetryFailingUpdates(WidgetRef ref) async {
  await Future<void>.delayed(const Duration(seconds: 15));
  try {
    final prefs = await SharedPreferences.getInstance();
    final failing = ForegroundProfilesUpdateNotifier.readFailingSince(prefs);
    if (failing.isEmpty) return;
    final repo = await ref.read(profileRepositoryProvider.future);
    for (final p in await myAllProfiles(ref)) {
      if (p is! RemoteProfileEntity || !failing.containsKey(p.id)) continue;
      final res = await repo.upsertRemote(p.url).run();
      myEvent(res.isRight() ? 'Подписка «${p.name}» обновилась через VPN' : 'Подписка «${p.name}» не обновилась и через VPN');
    }
  } catch (_) {}
}

/// Подобрать самый быстрый DNS из готовых и поставить его.
Future<String?> myPickFastestDns(WidgetRef ref, {bool quiet = false}) async {
  final res = await myMeasureDns(myDnsPresets);
  final ok = res.entries.where((e) => e.value != null).toList()..sort((a, b) => a.value!.compareTo(b.value!));
  if (ok.isEmpty) return null;
  final best = ok.first.key;
  final url = myDnsPresets[best]!;
  if (ref.read(ConfigOptions.remoteDnsAddress) != url) {
    await ref.read(ConfigOptions.remoteDnsAddress.notifier).update(url);
    myEvent('Самый быстрый DNS: $best (${ok.first.value} мс)');
  }
  return '$best — ${ok.first.value} мс';
}
