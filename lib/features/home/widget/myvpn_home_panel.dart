// MyVPN: панель под кнопкой подключения.
// Подключено: время сессии, сколько раз сменился сервер, таймер, график скорости,
// кто держит сервер (город, провайдер, сеть), последний рабочий сервер для этой сети.
// Не подключено: детектор белых списков. Всегда: замер скорости с VPN и без.
// Ещё здесь показывается сводка по только что добавленной подписке.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/myvpn_marks.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/widget/myvpn_profile_extras.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/settings/myvpn_tools.dart';
import 'package:hiddify/features/stats/notifier/stats_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart' hide IpInfo;
import 'package:hiddify/utils/number_formatters.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------- Сессия ----------

abstract final class MySession {
  static DateTime? start;
  static int switches = 0;
  static String? lastTag;
  static String? stableTag;
  static DateTime? stableSince;
  static final down = <int>[]; // байт/с за последнюю минуту
  static final up = <int>[];
  static bool _loaded = false;

  /// Скорость от ядра раз в секунду.
  static void feedStats(int upPerSec, int downPerSec) {
    up.add(upPerSec);
    down.add(downPerSec);
    while (down.length > 60) {
      down.removeAt(0);
    }
    while (up.length > 60) {
      up.removeAt(0);
    }
  }

  static Future<void> onRunning(bool running) async {
    final p = await SharedPreferences.getInstance();
    if (!_loaded) {
      _loaded = true;
      final s = p.getInt('myvpn_session_start');
      if (running && s != null) {
        start = DateTime.fromMillisecondsSinceEpoch(s);
        switches = p.getInt('myvpn_session_switches') ?? 0;
        return;
      }
    }
    if (running && start == null) {
      start = DateTime.now();
      switches = 0;
      lastTag = null;
      await p.setInt('myvpn_session_start', start!.millisecondsSinceEpoch);
      await p.setInt('myvpn_session_switches', 0);
    } else if (!running && start != null) {
      start = null;
      switches = 0;
      lastTag = null;
      stableTag = null;
      down.clear();
      up.clear();
      await p.remove('myvpn_session_start');
    }
  }

  static void onServer(String? tag) {
    if (tag == null || tag.isEmpty) return;
    if (lastTag != null && lastTag != tag) {
      switches++;
      unawaited(SharedPreferences.getInstance().then((p) => p.setInt('myvpn_session_switches', switches)));
    }
    lastTag = tag;
    if (stableTag != tag) {
      stableTag = tag;
      stableSince = DateTime.now();
    }
  }
}

/// Последний рабочий сервер для каждой сети.
abstract final class MyLastServer {
  static Map<String, Map<String, String>> byNet = {};
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getString('myvpn_last_by_net');
      if (raw != null) {
        byNet = (jsonDecode(raw) as Map).map(
          (k, v) => MapEntry(k.toString(), (v as Map).map((a, b) => MapEntry(a.toString(), b.toString()))),
        );
      }
    } catch (_) {}
  }

  static Future<void> remember(String net, String profileId, String tag, String name) async {
    final cur = byNet[net];
    if (cur != null && cur['tag'] == tag && cur['profile'] == profileId) return;
    byNet[net] = {'profile': profileId, 'tag': tag, 'name': name};
    try {
      await (await SharedPreferences.getInstance()).setString('myvpn_last_by_net', jsonEncode(byNet));
    } catch (_) {}
  }
}

/// Сводка по только что добавленной подписке.
abstract final class MyAddSummary {
  static String? _prepared;
  static final notifier = ValueNotifier<String?>(null);

  static void prepare(String url) => _prepared = url;

  static void commit() {
    if (_prepared != null) notifier.value = _prepared;
    _prepared = null;
  }
}

/// Сервер, через который сейчас идёт трафик: выбранный или выбранный автовыбором.
String? myCurrentServerTag(OutboundGroupList list) {
  final sel = list.items.firstOrNull?.items.firstOrNull;
  if (sel == null) return null;
  if (sel.isGroup) return sel.hasGroupSelectedTag() && sel.groupSelectedTag.isNotEmpty ? sel.groupSelectedTag : null;
  return sel.tag;
}

String _myDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

class MyHomePanel extends HookConsumerWidget {
  const MyHomePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final running = ref.watch(serviceRunningProvider);
    final stats = running ? ref.watch(statsNotifierProvider).valueOrNull : null;
    final list = running ? ref.watch(mainOutboundsNotifierProvider).valueOrNull : null;
    final ipInfo = running ? ref.watch(ipInfoNotifierProvider).valueOrNull : null;
    final activeProfile = ref.watch(activeProfileProvider).valueOrNull;
    final tick = useState(0);
    final net = useState('unknown');
    final whitelist = useState<String?>(null);
    final speedBusy = useState(false);
    final speedTick = useState(0);
    final directSpeed = useFuture(useMemoized(() => MySpeed.last(viaVpn: false), [speedTick.value])).data;
    final vpnSpeed = useFuture(useMemoized(() => MySpeed.last(viaVpn: true), [speedTick.value])).data;

    // секундный тик для таймера сессии; сеть — раз в 15 секунд
    useEffect(() {
      unawaited(MyLastServer.load());
      unawaited(MyMarks.load());
      Future<void> pollNet() async {
        final t = await myNetType();
        if (t != net.value) net.value = t;
      }

      unawaited(pollNet());
      var n = 0;
      final timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (++n % 15 == 0) unawaited(pollNet());
        if (running) tick.value++;
      });
      return timer.cancel;
    }, [running]);

    useEffect(() {
      unawaited(MySession.onRunning(running));
      return null;
    }, [running]);

    // детектор белых списков — только без VPN
    useEffect(() {
      if (running) {
        whitelist.value = null;
        return null;
      }
      var cancelled = false;
      Future<void> check() async {
        final r = await myDetectWhitelist();
        if (!cancelled) whitelist.value = r;
      }

      unawaited(check());
      final timer = Timer.periodic(const Duration(minutes: 2), (_) => unawaited(check()));
      return () {
        cancelled = true;
        timer.cancel();
      };
    }, [running, net.value]);

    // сводка по новой подписке
    final pendingUrl = useValueListenable(MyAddSummary.notifier);
    useEffect(() {
      if (pendingUrl == null) return null;
      MyAddSummary.notifier.value = null;
      unawaited(Future<void>.delayed(const Duration(milliseconds: 1500), () {
        if (context.mounted) unawaited(showMyAddSummary(context, ref, pendingUrl));
      }));
      return null;
    }, [pendingUrl]);

    final currentTag = list == null ? null : myCurrentServerTag(list);
    MySession.onServer(currentTag);

    // запоминаем рабочий сервер для этой сети (держится минуту с нормальным пингом)
    final delay = list?.items.firstOrNull?.items.firstOrNull?.urlTestDelay ?? 0;
    final stable = currentTag != null &&
        MySession.stableTag == currentTag &&
        MySession.stableSince != null &&
        DateTime.now().difference(MySession.stableSince!) > const Duration(minutes: 1) &&
        delay > 0 &&
        delay < 65000;
    useEffect(() {
      if (!stable || activeProfile == null || net.value == 'unknown') return null;
      unawaited(_myRememberWorking(ref, activeProfile, currentTag, net.value));
      return null;
    }, [stable, currentTag, net.value]);

    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final children = <Widget>[];

    if (running) {
      final start = MySession.start;
      final stopAt = MyTimer.stopAt(ref);
      children.add(
        Text(
          [
            if (start != null) '⏱ ${_myDuration(DateTime.now().difference(start))}',
            'смен сервера: ${MySession.switches}',
            if (stopAt != null) '⏲ выкл. в ${myHm(stopAt)}',
          ].join(' · '),
          style: muted,
        ),
      );
      children.add(const SizedBox(height: 6));
      children.add(
        SizedBox(
          height: 34,
          width: 220,
          child: CustomPaint(
            painter: _MySpeedPainter(
              down: List.of(MySession.down),
              up: List.of(MySession.up),
              downColor: const Color(0xFF22D3EE),
              upColor: const Color(0xFF34D399),
            ),
          ),
        ),
      );
      if (stats != null) {
        children.add(Text('↓ ${stats.downlink.toInt().speed()}   ↑ ${stats.uplink.toInt().speed()}', style: muted));
      }
      if (ipInfo != null) {
        final host = [
          if ((ipInfo.city ?? '').isNotEmpty) ipInfo.city!,
          if ((ipInfo.org ?? '').isNotEmpty) ipInfo.org!,
          if ((ipInfo.asn ?? '').isNotEmpty) (ipInfo.asn!.toUpperCase().startsWith('AS') ? ipInfo.asn! : 'AS${ipInfo.asn}'),
        ].join(' · ');
        if (host.isNotEmpty) children.add(Text('📍 $host', style: muted, textAlign: TextAlign.center));
      }
      // последний рабочий сервер для этой сети
      final last = MyLastServer.byNet[net.value];
      if (last != null && activeProfile != null && last['profile'] == activeProfile.id && last['tag'] != currentTag) {
        children.add(
          TextButton.icon(
            icon: Icon(net.value == 'cell' ? Icons.signal_cellular_alt_rounded : Icons.wifi_rounded, size: 18),
            label: Text(
              '${switch (net.value) {
                'cell' => 'На LTE',
                'wifi' => 'На Wi-Fi',
                _ => 'Здесь',
              }} работал: ${last['name']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: () async {
              final res = await ref.read(proxyRepositoryProvider).selectProxy('select', last['tag']!).run();
              if (context.mounted) mySnack(context, res.isRight() ? 'Подключено: ${last['name']}' : 'Этого сервера больше нет');
            },
          ),
        );
      }
    } else if (whitelist.value == 'whitelist') {
      children.add(_MyWhitelistBanner(netName: myNetName(net.value)));
    }

    // скорость с VPN и без
    children.add(
      TextButton(
        onPressed: speedBusy.value
            ? null
            : () async {
                speedBusy.value = true;
                final r = await MySpeed.run(viaVpn: running);
                speedBusy.value = false;
                speedTick.value++;
                if (context.mounted) {
                  mySnack(context, r == null ? 'Не удалось замерить скорость' : '${running ? 'Через VPN' : 'Без VPN'}: ${myMbps(r)}');
                }
              },
        child: Text(
          speedBusy.value
              ? 'Замеряю скорость…'
              : 'Скорость: без VPN ${directSpeed == null ? '—' : myMbps(directSpeed.mbps)} · '
                    'через VPN ${vpnSpeed == null ? '—' : myMbps(vpnSpeed.mbps)}',
          style: muted,
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

Future<void> _myRememberWorking(WidgetRef ref, ProfileEntity profile, String tag, String net) async {
  try {
    final file = ref.read(profilePathResolverProvider).file(profile.id);
    if (!await file.exists()) return;
    final server = myServersFromText(await file.readAsString(), profileId: profile.id)
        .where((s) => s.tag == tag)
        .firstOrNull;
    if (server == null) return;
    await MyLastServer.remember(net, profile.id, tag, server.name);
    if (net == 'cell' && !myHasKey(MyMarks.lteOk, server.json)) {
      await MyMarks.load();
      MyMarks.lteOk.add(server.key);
      await MyMarks.save();
    }
  } catch (_) {}
}

class _MyWhitelistBanner extends HookConsumerWidget {
  const _MyWhitelistBanner({required this.netName});

  final String netName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final target = useFuture(
      useMemoized(() async {
        final id = await MyWhitelist.profileId();
        if (id == null) return null;
        return (await myAllProfiles(ref)).where((p) => p.id == id).firstOrNull;
      }),
    ).data;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('📶 Похоже, на этой сети белые списки ($netName)', style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            if (target != null)
              FilledButton(
                onPressed: () async {
                  final err = await myConnectTo(ref, target);
                  if (context.mounted && err != null) mySnack(context, err);
                },
                child: Text('Подключить «${target.name}»'),
              )
            else
              TextButton(
                onPressed: () => showMyWhitelistProfile(context, ref),
                child: const Text('Выбрать подписку для белых списков'),
              ),
          ],
        ),
      ),
    );
  }
}

class _MySpeedPainter extends CustomPainter {
  _MySpeedPainter({required this.down, required this.up, required this.downColor, required this.upColor});

  final List<int> down;
  final List<int> up;
  final Color downColor;
  final Color upColor;

  @override
  void paint(Canvas canvas, Size size) {
    final maxV = math.max(1, [...down, ...up].fold<int>(0, math.max)).toDouble();
    void line(List<int> v, Color c, {bool fill = false}) {
      if (v.length < 2) return;
      final path = Path();
      for (var i = 0; i < v.length; i++) {
        final x = size.width * (60 - v.length + i) / 59;
        final y = size.height - size.height * v[i] / maxV;
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      if (fill) {
        final area = Path.from(path)
          ..lineTo(size.width, size.height)
          ..lineTo(size.width * (60 - v.length) / 59, size.height)
          ..close();
        canvas.drawPath(area, Paint()..color = c.withValues(alpha: .15));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = c
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }

    line(down, downColor, fill: true);
    line(up, upColor);
  }

  @override
  bool shouldRepaint(covariant _MySpeedPainter old) => true;
}

/// Сводка после добавления подписки: сколько серверов, страны, протоколы, срок, совпадения с другими.
Future<void> showMyAddSummary(BuildContext context, WidgetRef ref, String url) async {
  try {
    final repo = await ref.read(profileRepositoryProvider.future);
    final resolver = ref.read(profilePathResolverProvider);
    ProfileEntity? added;
    List<ProfileEntity> all = const [];
    for (var i = 0; i < 10 && added == null; i++) {
      all = (await repo.watchAll().first).getOrElse((_) => const []);
      added = all.where((p) => p is RemoteProfileEntity && p.url == url).firstOrNull;
      if (added == null) await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (added == null) return;
    final file = resolver.file(added.id);
    if (!await file.exists()) return;
    final servers = myServersFromText(await file.readAsString(), profileId: added.id);
    final keys = {for (final s in servers) s.key};
    final flags = {for (final s in servers) myFlagOf(s.name)}..remove('');
    final types = {for (final s in servers) s.type.toUpperCase()};
    // совпадения с другими подписками
    String? dup;
    var best = 0.0;
    for (final p in all) {
      if (p.id == added.id || p.name == 'Все подписки' || p.name == 'Избранное') continue;
      final f = resolver.file(p.id);
      if (!await f.exists()) continue;
      final other = {for (final s in myServersFromText(await f.readAsString(), profileId: p.id)) s.key};
      if (keys.isEmpty || other.isEmpty) continue;
      final share = keys.intersection(other).length / keys.length;
      if (share > best) {
        best = share;
        dup = p.name;
      }
    }
    String? term;
    if (added case RemoteProfileEntity(:final subInfo?)) {
      final days = subInfo.remaining.inDays;
      term = [
        if (days < 3650) 'осталось $days дн.',
        if (subInfo.total < 1 << 50) 'трафик ${subInfo.consumption.size()} из ${subInfo.total.size()}',
      ].join(' · ');
    }
    if (!context.mounted) return;
    final profile = added;
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        title: Text('Добавлено: ${profile.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('🖥 ${myServersWord(servers.length)}'),
            if (flags.isNotEmpty) Text('🌍 ${(flags.toList()..sort()).take(15).join(' ')}${flags.length > 15 ? ' …' : ''}'),
            if (types.isNotEmpty) Text('🔐 ${(types.toList()..sort()).join(', ')}'),
            if (term != null && term.isNotEmpty) Text('⏳ $term'),
            if (servers.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('⚠ Серверов нет. Если подписка платная, проверьте HWID и User-Agent в настройках.'),
              ),
            if (dup != null && best >= 0.5)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('⚠ ${(best * 100).round()}% серверов уже есть в «$dup»'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await repo.deleteById(profile.id, profile.active).run();
            },
            child: const Text('Удалить'),
          ),
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Оставить')),
        ],
      ),
    );
  } catch (_) {}
}
