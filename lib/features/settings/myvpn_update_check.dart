// MyVPN: подозрительное обновление подписки (с откатом) и проверка серверов, добавленных в «Мои серверы».
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/myvpn_marks.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/widget/myvpn_profile_extras.dart';
import 'package:hiddify/features/settings/myvpn_events.dart';
import 'package:hiddify/features/settings/myvpn_tools.dart';
import 'package:hiddify/features/stats/myvpn_counters.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract final class MyUpdateAlert {
  static final notifier = ValueNotifier<(String, String)?>(null); // (id профиля, что не так)

  static void init() {
    myOnSuspiciousUpdate ??= (id, reason) => notifier.value = (id, reason);
    myOnServersAdded ??= (servers) => MyAddCheck.notifier.value = servers;
  }

  static Future<Set<String>> muted() async =>
      ((await SharedPreferences.getInstance()).getStringList('myvpn_update_alert_off') ?? const []).toSet();

  static Future<void> mute(String id) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('myvpn_update_alert_off', [...await muted(), id]);
  }
}

abstract final class MyAddCheck {
  static final notifier = ValueNotifier<List<Map<String, dynamic>>?>(null);
}

/// Откатить подписку на версию до последнего обновления; переподключить, если она активна.
Future<bool> myRollback(WidgetRef ref, ProfileEntity profile) async {
  final path = ref.read(profilePathResolverProvider).file(profile.id).path;
  final ok = await myRollbackProfile(path);
  if (!ok) return false;
  myEvent('Подписка «${profile.name}» откачена на прошлую версию');
  final active = await ref.read(activeProfileProvider.future);
  if (active?.id == profile.id && ref.read(serviceRunningProvider)) {
    await myConnectTo(ref, profile, reload: true);
  }
  return true;
}

Future<void> showMyUpdateAlert(BuildContext context, WidgetRef ref, (String, String) alert) async {
  final (id, reason) = alert;
  if ((await MyUpdateAlert.muted()).contains(id)) return;
  final profile = (await myAllProfiles(ref)).where((p) => p.id == id).firstOrNull;
  if (profile == null || MyCounters.combined.contains(profile.name) || profile.name == 'Мои серверы') return;
  myEvent('⚠️ Подозрительное обновление «${profile.name}»: $reason');
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (context) => AlertDialog(
      title: const Text('⚠️ Подписка странно обновилась'),
      content: Text(
        '«${profile.name}»: $reason.\n\n'
        'Так бывает, если провайдер просто сменил серверы. Но если не ожидали — можно вернуть прошлую версию.',
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await MyUpdateAlert.mute(id);
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('Не предупреждать'),
        ),
        TextButton(
          onPressed: () async {
            final ok = await myRollback(ref, profile);
            if (context.mounted) {
              Navigator.of(context).pop();
              mySnack(context, ok ? 'Вернул прошлую версию «${profile.name}»' : 'Прошлой версии нет');
            }
          },
          child: const Text('Откатить'),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Оставить')),
      ],
    ),
  );
}

/// Проверка серверов, только что добавленных в «Мои серверы»: шифрование, дубли в подписках, живой ли.
Future<void> showMyAddCheck(BuildContext context, WidgetRef ref, List<Map<String, dynamic>> servers) async {
  if (servers.isEmpty) {
    mySnack(context, 'Такой сервер уже есть в «Моих серверах»');
    return;
  }
  // ключи серверов из остальных подписок
  final otherKeys = <String, String>{};
  final resolver = ref.read(profilePathResolverProvider);
  for (final p in await myAllProfiles(ref)) {
    if (p.name == 'Мои серверы' || MyCounters.combined.contains(p.name)) continue;
    try {
      final f = resolver.file(p.id);
      if (!await f.exists()) continue;
      for (final s in myServersFromText(await f.readAsString())) {
        otherKeys.putIfAbsent(s.key, () => p.name);
      }
    } catch (_) {}
  }
  final lines = await Future.wait([
    for (final o in servers)
      () async {
        final s = myServerFrom(o);
        final parts = <String>[];
        final insecure = myInsecureReason(o);
        parts.add(insecure == null ? '🔒 защищён' : '🔓 $insecure');
        final dup = otherKeys[s.key];
        if (dup != null) parts.add('🔁 уже есть в «$dup»');
        if (s.host.isNotEmpty && s.port > 0) {
          final ms = await myTcpPing(s.host, s.port);
          parts.add(ms == null ? '✖ не отвечает' : '✅ отвечает, $ms мс');
        }
        return '${s.name}\n   ${parts.join(' · ')}';
      }(),
  ]);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (context) => AlertDialog(
      title: Text(servers.length == 1 ? 'Сервер добавлен' : 'Добавлено серверов: ${servers.length}'),
      content: SingleChildScrollView(child: Text(lines.join('\n'))),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Понятно'))],
    ),
  );
}
