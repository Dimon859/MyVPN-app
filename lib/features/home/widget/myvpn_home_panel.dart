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
import 'package:hiddify/features/connections/myvpn_connections.dart';
import 'package:hiddify/features/profile/data/myvpn_marks.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/widget/myvpn_profile_extras.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/settings/myvpn_detectors.dart';
import 'package:hiddify/features/settings/myvpn_events.dart';
import 'package:hiddify/features/settings/myvpn_guard.dart';
import 'package:hiddify/features/settings/myvpn_tools.dart';
import 'package:hiddify/features/settings/myvpn_update_check.dart';
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
    MyUpdateAlert.init();
    final theme = Theme.of(context);
    final running = ref.watch(serviceRunningProvider);
    final stats = running ? ref.watch(statsNotifierProvider).valueOrNull : null;
    final list = running ? ref.watch(mainOutboundsNotifierProvider).valueOrNull : null;
    final ipInfo = running ? ref.watch(ipInfoNotifierProvider).valueOrNull : null;
    final asnRaw = (ipInfo?.asn ?? '').trim();
    final asn = asnRaw.isEmpty ? '' : (asnRaw.toUpperCase().startsWith('AS') ? asnRaw.toUpperCase() : 'AS$asnRaw');
    final fullOrg = useFuture(useMemoized(() => myAsnHolder(asn), [asn])).data;
    final activeProfile = ref.watch(activeProfileProvider).valueOrNull;
    MyMarks.activeSection = activeProfile == null ? null : MyMarks.sections[activeProfile.id];

    // автопереключение при белых списках (проверка раз в 30 секунд, пока приложение открыто)
    useEffect(() {
      Future<void> run() async {
        if (context.mounted) await MyWlAuto.tick(context, ref);
      }

      final first = Timer(const Duration(seconds: 5), () => unawaited(run()));
      final timer = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(run()));
      return () {
        first.cancel();
        timer.cancel();
      };
    }, const []);
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
        if (!await MyWhitelist.banner()) {
          if (!cancelled) whitelist.value = null;
          return;
        }
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
    if (currentTag != null) myServerSeen(myCleanName(currentTag));
    // включение/выключение VPN — в журнал (быстрое выкл→вкл одной строкой)
    final runningRef = useRef<bool?>(null);
    if (runningRef.value != running) {
      if (runningRef.value != null) myVpnState(running);
      runningRef.value = running;
    }

    // сервер тормозит: пинг сильно выше обычного для этого сервера
    final currentDelay = list?.items.firstOrNull?.items.where((o) => o.tag == currentTag).firstOrNull?.urlTestDelay ?? 0;
    final slowInfo = useMemoized(() {
      if (currentTag == null) return null;
      final typical = MySlow.observe(currentTag, currentDelay);
      return MySlow.isSlow(currentDelay, typical) ? typical : null;
    }, [currentTag, currentDelay]);
    final slowTypical = slowInfo;

    // сторож: проверки серверов, цепочка запасных, протоколы по сетям (раз в 30 секунд)
    final listRef = useRef(list);
    listRef.value = list;
    useEffect(() {
      unawaited(MySlow.load());
      Future<void> run() async {
        if (context.mounted) await MyGuard.tick(context, ref, listRef.value);
      }

      final first = Timer(const Duration(seconds: 8), () => unawaited(run()));
      final timer = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(run()));
      return () {
        first.cancel();
        timer.cancel();
      };
    }, const []);

    // подозрительное обновление подписки и проверка добавленного сервера
    final alert = useValueListenable(MyUpdateAlert.notifier);
    useEffect(() {
      if (alert == null) return null;
      MyUpdateAlert.notifier.value = null;
      unawaited(Future<void>.delayed(const Duration(milliseconds: 800), () {
        if (context.mounted) unawaited(showMyUpdateAlert(context, ref, alert));
      }));
      return null;
    }, [alert]);
    final added = useValueListenable(MyAddCheck.notifier);
    useEffect(() {
      if (added == null) return null;
      MyAddCheck.notifier.value = null;
      unawaited(Future<void>.delayed(const Duration(milliseconds: 800), () {
        if (context.mounted) unawaited(showMyAddCheck(context, ref, added));
      }));
      return null;
    }, [added]);

    // запоминаем рабочий сервер для этой сети: держится минуту и через него реально идёт трафик
    final traffic = MySession.down.fold<int>(0, (a, b) => a + b);
    final stable = currentTag != null &&
        MySession.stableTag == currentTag &&
        MySession.stableSince != null &&
        DateTime.now().difference(MySession.stableSince!) > const Duration(minutes: 1) &&
        traffic > 20 * 1024;
    useEffect(() {
      if (!stable || activeProfile == null || net.value == 'unknown') return null;
      unawaited(_myRememberWorking(ref, activeProfile, currentTag, net.value));
      return null;
    }, [stable, currentTag, net.value]);

    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final compactBtn = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      minimumSize: const Size(0, 28),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
    final children = <Widget>[];

    if (running) {
      final start = MySession.start;
      final stopAt = MyTimer.stopAt(ref);
      children.add(
        Text(
          [
            if (start != null) '⏱ ${_myDuration(DateTime.now().difference(start))}',
            'смен: ${MySession.switches}',
            if (stats != null) '↓ ${stats.downlink.toInt().speed()} ↑ ${stats.uplink.toInt().speed()}',
            if (stopAt != null) '⏲ ${myHm(stopAt)}',
          ].join(' · '),
          style: muted,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: SizedBox(
            height: 22,
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
        ),
      );
      if (ipInfo != null) {
        final host = [
          if ((ipInfo.city ?? '').isNotEmpty) ipInfo.city!,
          if ((fullOrg ?? ipInfo.org ?? '').isNotEmpty) fullOrg ?? ipInfo.org!,
          if (asn.isNotEmpty) asn,
        ].join(' · ');
        if (host.isNotEmpty) {
          children.add(Text('📍 $host', style: muted, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis));
        }
      }
      // сервер тормозит
      if (slowTypical != null) {
        children.add(
          TextButton.icon(
            style: compactBtn,
            icon: const Icon(Icons.speed_rounded, size: 16, color: Color(0xFFF59E0B)),
            label: Text(
              '🐢 Тормозит: пинг $currentDelay мс вместо обычных $slowTypical — сменить',
              style: const TextStyle(color: Color(0xFFF59E0B)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: () async {
              myEvent('🐢 Сервер тормозил (пинг $currentDelay вместо $slowTypical) — переключение на автовыбор');
              await ref.read(proxyRepositoryProvider).urlTest('select').run();
              await ref.read(proxyRepositoryProvider).selectProxy('select', 'lowest').run();
              if (context.mounted) mySnack(context, 'Переключаю на лучший по пингу');
            },
          ),
        );
      }
      // последний рабочий сервер для этой сети
      final last = MyLastServer.byNet[net.value];
      if (last != null && activeProfile != null && last['profile'] == activeProfile.id && last['tag'] != currentTag) {
        children.add(
          TextButton.icon(
            style: compactBtn,
            icon: Icon(net.value == 'cell' ? Icons.signal_cellular_alt_rounded : Icons.wifi_rounded, size: 16),
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

    // скорость с VPN и без — одной строкой; нажатие — замер, долгое нажатие — когда мерили
    children.add(
      InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: speedBusy.value
            ? null
            : () async {
                speedBusy.value = true;
                final r = await MySpeed.run(viaVpn: running);
                speedBusy.value = false;
                speedTick.value++;
                if (context.mounted) {
                  mySnack(
                    context,
                    r == null
                        ? 'Не удалось замерить скорость: серверы для замера не ответили'
                        : '${running ? 'Через VPN' : 'Без VPN'}: ${myMbps(r)}',
                  );
                }
              },
        onLongPress: () => mySnack(
          context,
          'Без VPN: ${directSpeed == null ? 'не мерили' : '${myMbps(directSpeed.mbps)}, ${_myAgo(directSpeed.at)}'}\n'
          'Через VPN: ${vpnSpeed == null ? 'не мерили' : '${myMbps(vpnSpeed.mbps)}, ${_myAgo(vpnSpeed.at)}'}',
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Text(
            speedBusy.value
                ? '⚡ Замеряю скорость ${running ? 'через VPN' : 'без VPN'}…'
                : '⚡ без VPN ${directSpeed == null ? '—' : directSpeed.mbps.round()} · '
                      'через VPN ${vpnSpeed == null ? '—' : vpnSpeed.mbps.round()} Мбит/с',
            style: muted?.copyWith(color: theme.colorScheme.primary),
          ),
        ),
      ),
    );

    // режимы и соединения в одну строку
    children.add(
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MyRouteModeSwitch(),
          if (running)
            IconButton(
              tooltip: 'Соединения',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.lan_outlined, size: 20),
              onPressed: () => showMyConnections(context),
            ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(top: 4),
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

/// «только что», «5 мин назад», «3 ч назад», «12.11».
String _myAgo(DateTime at) {
  final d = DateTime.now().difference(at);
  if (d.inMinutes < 1) return 'только что';
  if (d.inMinutes < 60) return '${d.inMinutes} мин назад';
  if (d.inHours < 24) return '${d.inHours} ч назад';
  return '${at.day.toString().padLeft(2, '0')}.${at.month.toString().padLeft(2, '0')}';
}

final _myAsnCache = <String, String>{};

/// Полное название владельца AS из базы RIPE (например «PLAY2GO - FZCO»), с запоминанием.
Future<String?> myAsnHolder(String asn) async {
  if (asn.isEmpty) return null;
  if (_myAsnCache.containsKey(asn)) return _myAsnCache[asn];
  final p = await SharedPreferences.getInstance();
  final saved = p.getString('myvpn_asn_$asn');
  if (saved != null) return _myAsnCache[asn] = saved;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final req = await client.getUrl(Uri.parse('https://stat.ripe.net/data/as-overview/data.json?resource=$asn'));
    final resp = await req.close().timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) return null;
    final body = await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 8));
    final holder = (((jsonDecode(body) as Map)['data'] as Map?)?['holder'] ?? '').toString().trim();
    if (holder.isEmpty) return null;
    // «PLAY2GO-FZCO - PLAY2GO - FZCO» → «PLAY2GO - FZCO»
    final i = holder.indexOf(' - ');
    final name = i > 0 && i + 3 < holder.length ? holder.substring(i + 3).trim() : holder;
    await p.setString('myvpn_asn_$asn', name);
    return _myAsnCache[asn] = name;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Автопереключение на подписку для белых списков и обратно.
abstract final class MyWlAuto {
  static bool _busy = false;
  static int _strikes = 0;
  static DateTime? _lastTryMain;
  static String? _lastNet;

  static Future<void> tick(BuildContext context, WidgetRef ref) async {
    if (_busy) return;
    _busy = true;
    try {
      if (!await MyWhitelist.auto()) return;
      final wlId = await MyWhitelist.profileId();
      if (wlId == null) return;
      final profiles = await myAllProfiles(ref);
      final wl = profiles.where((p) => p.id == wlId).firstOrNull;
      if (wl == null) return;
      final active = await ref.read(activeProfileProvider.future);
      final running = ref.read(serviceRunningProvider);
      final net = await myNetType();
      final netChanged = _lastNet != null && _lastNet != net;
      _lastNet = net;
      final mainId = await MyWhitelist.mainId();
      final main = profiles.where((p) => p.id == mainId).firstOrNull;

      void say(String text) {
        myEvent(text);
        if (context.mounted) mySnack(context, text);
      }

      if (active?.id != wlId) {
        // основная подписка: следим, не включились ли белые списки (только на мобильной сети)
        if (net != 'cell') {
          _strikes = 0;
          return;
        }
        final r = await myDetectWhitelist();
        _strikes = r == 'whitelist' ? _strikes + 1 : 0;
        // без VPN хватает одной проверки; с VPN — двух подряд (чтобы не путать с упавшим сервером)
        if (_strikes < (running ? 2 : 1)) return;
        _strikes = 0;
        await MyWhitelist.setMainId(active?.id);
        _lastTryMain = DateTime.now();
        if (running) {
          await myConnectTo(ref, wl);
          say('📶 Похоже на белые списки — переключил на «${wl.name}»');
        } else {
          final repo = await ref.read(profileRepositoryProvider.future);
          await repo.setAsActive(wl.id).run();
          say('📶 Похоже на белые списки — выбрана «${wl.name}». Нажмите кнопку, чтобы подключиться');
        }
        return;
      }

      // сейчас подписка для белых списков: пробуем вернуться на основную
      if (main == null) return; // на белые списки перешли вручную — ничего не трогаем
      if (!running) {
        if (net == 'wifi' || await myDetectWhitelist() == 'ok') {
          final repo = await ref.read(profileRepositoryProvider.future);
          await repo.setAsActive(main.id).run();
          await MyWhitelist.setMainId(null);
          say('Белых списков нет — снова выбрана «${main.name}»');
        }
        return;
      }
      final due = _lastTryMain == null || DateTime.now().difference(_lastTryMain!) > const Duration(minutes: 15);
      if (!(net == 'wifi' && netChanged) && !due) return;
      _lastTryMain = DateTime.now();
      await myConnectTo(ref, main);
      await Future<void>.delayed(const Duration(seconds: 20));
      if (await myDetectWhitelist() == 'ok') {
        await MyWhitelist.setMainId(null);
        say('Белые списки сняли — вернулся на «${main.name}»');
      } else {
        await myConnectTo(ref, wl);
        await MyWhitelist.setMainId(main.id);
      }
    } catch (_) {
    } finally {
      _busy = false;
    }
  }
}
