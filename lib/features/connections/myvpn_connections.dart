// MyVPN: вкладка «Соединения» (как в Karing) и режимы «Правила / Глобально / Напрямую».
// Соединения берутся из встроенного в ядро Clash API (127.0.0.1:порт, с паролем web-secret),
// режимы меняют список правил, который уходит в ядро.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/myvpn_marks.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/route_rules/myvpn_rule_import.dart';
import 'package:hiddify/features/route_rules/notifier/rules_notifier.dart';
import 'package:hiddify/features/settings/myvpn_events.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// ---------- Пароль к Clash API ----------

/// Пароль ядра для Clash API: создаётся один раз и хранится, чтобы приложение и ядро всегда совпадали.
final myWebSecretProvider = Provider<String>((ref) {
  final prefs = ref.read(sharedPreferencesProvider).requireValue;
  var s = prefs.getString('myvpn_web_secret') ?? '';
  if (s.isEmpty) {
    final r = math.Random.secure();
    s = List.generate(24, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    unawaited(prefs.setString('myvpn_web_secret', s));
  }
  return s;
});

// ---------- Режимы ----------

/// Режим маршрутизации: rule — по правилам, global — всё через VPN, direct — VPN включён, но всё напрямую.
final myRouteModeProvider = PreferencesNotifier.create<String, String>(
  'myvpn-route-mode',
  'rule',
  validator: (v) => const {'rule', 'global', 'direct'}.contains(v),
);

const myRouteModes = {'rule': 'Правила', 'global': 'Глобально', 'direct': 'Напрямую'};

/// Источник списков geosite/geoip: id готового, «custom|сайты|ip» или «none».
final myGeoSourceProvider = PreferencesNotifier.create<String, String>('myvpn-geo-source', 'tunnex');

/// Меняется, когда включают или выключают правила подписки — чтобы пересобрать настройки ядра.
final mySubRulesVersionProvider = StateProvider<int>((ref) => 0);

final _myMarksLoadedProvider = FutureProvider<void>((ref) => MyMarks.load());

/// id активного профиля (для правил подписки).
final myActiveProfileIdProvider = Provider<String?>(
  (ref) => ref.watch(activeProfileProvider.select((v) => v.valueOrNull?.id)),
);

/// Правила для ядра: свои + правила активной подписки, списки из выбранного источника, режим.
List<Rule> myRulesForConfig(Ref ref, List<Rule> rules, String mode) {
  ref.watch(_myMarksLoadedProvider);
  ref.watch(mySubRulesVersionProvider);
  final id = ref.watch(myActiveProfileIdProvider);
  final all = [...rules];
  final sub = id == null || MyMarks.subRulesOff.contains(id) ? null : MyMarks.subRules[id];
  if (sub != null && sub.isNotEmpty) {
    var order = all.fold<int>(0, (m, r) => r.listOrder > m ? r.listOrder : m) + 1;
    for (final j in sub) {
      all.add(MyRuleSpec.fromJson(j).toRule('📦 правило подписки')..listOrder = order++);
    }
  }
  return myRulesForMode(myResolveGeo(all, ref.watch(myGeoSourceProvider)), mode);
}

/// Правила, которые уйдут в ядро в выбранном режиме.
List<Rule> myRulesForMode(List<Rule> rules, String mode) {
  switch (mode) {
    case 'global':
      // всё через VPN: остаются правила «через VPN» и «блокировать», а из «напрямую» — только локальная сеть
      return [
        for (final r in rules)
          if (r.outbound == Outbound.proxy ||
              r.outbound == Outbound.block ||
              BuiltinRule.of(r) == BuiltinRule.bypassLan)
            r,
      ];
    case 'direct':
      // всё напрямую, включая DNS: два правила в самом начале, остальные сдвигаются (копии, чтобы не трогать список)
      return [
        Rule(listOrder: 0, enabled: true, name: 'myvpn:direct-names', outbound: Outbound.direct, domainRegexes: ['.*']),
        Rule(listOrder: 1, enabled: true, name: 'myvpn:direct-all', outbound: Outbound.direct, portRanges: ['0:65535']),
        for (final r in rules) r.deepCopy()..listOrder = r.listOrder + 2,
      ];
    default:
      return rules;
  }
}

/// Переключатель режимов (на главном экране).
class MyRouteModeSwitch extends ConsumerWidget {
  const MyRouteModeSwitch({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(myRouteModeProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: SegmentedButton<String>(
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity(horizontal: -3, vertical: -3),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
          textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 13)),
        ),
        segments: [
          for (final e in myRouteModes.entries) ButtonSegment(value: e.key, label: Text(e.value)),
        ],
        selected: {mode},
        onSelectionChanged: (s) async {
          myReconnectReason('режим «${myRouteModes[s.first]}»');
          await ref.read(myRouteModeProvider.notifier).update(s.first);
          if (!context.mounted) return;
          final text = switch (s.first) {
            'global' => 'Глобально: весь трафик через VPN, кроме локальной сети',
            'direct' => 'Напрямую: VPN включён, но трафик идёт без сервера',
            _ => 'Правила: российское напрямую, остальное через VPN',
          };
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
        },
      ),
    );
  }
}

// ---------- Соединения ----------

class MyConn {
  MyConn(this.json, this.seen);

  final Map<String, dynamic> json;
  DateTime seen;
  DateTime? closedAt;
  double downSpeed = 0;
  double upSpeed = 0;

  String get id => (json['id'] ?? '').toString();
  Map<String, dynamic> get meta => (json['metadata'] as Map?)?.cast<String, dynamic>() ?? const {};
  String get host => (meta['host'] ?? '').toString();
  String get ip => (meta['destinationIP'] ?? '').toString();
  String get port => (meta['destinationPort'] ?? '').toString();
  String get network => (meta['network'] ?? '').toString().toUpperCase();
  String get target => host.isNotEmpty ? host : ip;
  int get up => (json['upload'] as num?)?.toInt() ?? 0;
  int get down => (json['download'] as num?)?.toInt() ?? 0;
  DateTime? get start => DateTime.tryParse((json['start'] ?? '').toString())?.toLocal();
  List<String> get chains => [for (final c in (json['chains'] as List? ?? const [])) c.toString()];
  String get rule => [json['rule'], json['rulePayload']].where((e) => (e ?? '').toString().isNotEmpty).join(' ');

  /// Через что пошло: сервер, «напрямую» или «блок».
  String get via {
    final c = chains;
    if (c.isEmpty) return '—';
    final last = _myCleanOut(c.first);
    if (c.any((e) => e.startsWith('direct'))) return 'Напрямую';
    if (c.any((e) => e.startsWith('block'))) return 'Заблокировано';
    return last;
  }

  bool get isDirect => via == 'Напрямую';
}

String _myCleanOut(String tag) => tag.replaceAll(RegExp(r'\s*§.*$'), '').trim();

String myBytes(num b) {
  if (b < 1024) return '${b.toInt()} Б';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} КБ';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} МБ';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} ГБ';
}

abstract final class MyClashApi {
  static Future<HttpClientResponse> _req(WidgetRef ref, String method, String path) async {
    final port = ref.read(ConfigOptions.clashApiPort);
    final secret = ref.read(myWebSecretProvider);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
    final resp = await req.close().timeout(const Duration(seconds: 4));
    client.close();
    return resp;
  }

  /// Список соединений или текст ошибки.
  static Future<(List<Map<String, dynamic>>?, String?)> connections(WidgetRef ref) async {
    try {
      final resp = await _req(ref, 'GET', '/connections');
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode == 401) return (null, 'Ядро не пустило. Переподключите VPN — после обновления нужен новый пароль.');
      if (resp.statusCode != 200) return (null, 'Ядро ответило ${resp.statusCode}');
      final data = jsonDecode(body) as Map;
      return ([for (final c in (data['connections'] as List? ?? const [])) (c as Map).cast<String, dynamic>()], null);
    } catch (e) {
      return (null, 'Нет связи с ядром. Включите VPN.');
    }
  }

  static Future<void> close(WidgetRef ref, String id) async {
    try {
      final resp = await _req(ref, 'DELETE', '/connections/$id');
      await resp.drain<void>();
    } catch (_) {}
  }

  static Future<void> closeAll(WidgetRef ref) async {
    try {
      final resp = await _req(ref, 'DELETE', '/connections');
      await resp.drain<void>();
    } catch (_) {}
  }
}

/// Провайдер по IP из базы RIPE: «PLAY2GO - FZCO (AS219337)».
final _myIpOrg = <String, String?>{};
Future<String?> myIpProvider(String ip) async {
  if (ip.isEmpty) return null;
  if (_myIpOrg.containsKey(ip)) return _myIpOrg[ip];
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final req = await client.getUrl(Uri.parse('https://stat.ripe.net/data/prefix-overview/data.json?resource=$ip'));
    final resp = await req.close().timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) return null;
    final data = (jsonDecode(await resp.transform(utf8.decoder).join()) as Map)['data'] as Map?;
    final asns = data?['asns'] as List?;
    if (asns == null || asns.isEmpty) return _myIpOrg[ip] = null;
    final a = asns.first as Map;
    var holder = (a['holder'] ?? '').toString();
    final i = holder.indexOf(' - ');
    if (i > 0 && i + 3 < holder.length) holder = holder.substring(i + 3);
    return _myIpOrg[ip] = '$holder (AS${a['asn']})';
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<void> showMyConnections(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => const MyConnectionsPage()));

class MyConnectionsPage extends HookConsumerWidget {
  const MyConnectionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final running = ref.watch(serviceRunningProvider);
    final conns = useRef(<String, MyConn>{});
    final error = useState<String?>(null);
    final tick = useState(0);
    final paused = useState(false);
    final query = useState('');
    final filter = useState('all'); // all, proxy, direct, closed

    useEffect(() {
      var busy = false;
      Future<void> poll() async {
        if (busy || paused.value) return;
        busy = true;
        final (list, err) = await MyClashApi.connections(ref);
        busy = false;
        if (!context.mounted) return;
        error.value = err;
        if (list == null) return;
        final now = DateTime.now();
        final alive = <String>{};
        for (final j in list) {
          final c = MyConn(j, now);
          alive.add(c.id);
          final old = conns.value[c.id];
          if (old != null) {
            final secs = math.max(0.5, now.difference(old.seen).inMilliseconds / 1000);
            c.downSpeed = math.max(0, c.down - old.down) / secs;
            c.upSpeed = math.max(0, c.up - old.up) / secs;
          }
          conns.value[c.id] = c;
        }
        for (final c in conns.value.values) {
          if (!alive.contains(c.id)) c.closedAt ??= now;
        }
        // закрытые храним 2 минуты, но не больше 300 записей
        conns.value.removeWhere((_, c) => c.closedAt != null && now.difference(c.closedAt!) > const Duration(minutes: 2));
        if (conns.value.length > 300) {
          final closed = conns.value.values.where((c) => c.closedAt != null).toList()
            ..sort((a, b) => a.closedAt!.compareTo(b.closedAt!));
          for (final c in closed.take(conns.value.length - 300)) {
            conns.value.remove(c.id);
          }
        }
        tick.value++;
      }

      unawaited(poll());
      final t = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(poll()));
      return t.cancel;
    }, const []);

    final all = conns.value.values.toList()
      ..sort((a, b) {
        if ((a.closedAt == null) != (b.closedAt == null)) return a.closedAt == null ? -1 : 1;
        return (b.start ?? b.seen).compareTo(a.start ?? a.seen);
      });
    final q = query.value.trim().toLowerCase();
    final shown = all.where((c) {
      if (q.isNotEmpty && !'${c.target} ${c.ip} ${c.via} ${c.port}'.toLowerCase().contains(q)) return false;
      return switch (filter.value) {
        'proxy' => c.closedAt == null && !c.isDirect,
        'direct' => c.closedAt == null && c.isDirect,
        'closed' => c.closedAt != null,
        _ => true,
      };
    }).toList();
    final active = all.where((c) => c.closedAt == null).toList();
    final down = active.fold<double>(0, (a, c) => a + c.downSpeed);
    final up = active.fold<double>(0, (a, c) => a + c.upSpeed);

    Widget chip(String key, String label) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(label: Text(label), selected: filter.value == key, onSelected: (_) => filter.value = key),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Соединения'),
        actions: [
          IconButton(
            tooltip: paused.value ? 'Продолжить' : 'Пауза',
            icon: Icon(paused.value ? Icons.play_arrow_rounded : Icons.pause_rounded),
            onPressed: () => paused.value = !paused.value,
          ),
          IconButton(
            tooltip: 'Закрыть все',
            icon: const Icon(Icons.close_rounded),
            onPressed: () async {
              await MyClashApi.closeAll(ref);
              if (context.mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Все соединения закрыты')));
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Text(
              'Активных: ${active.length} · ↓ ${myBytes(down)}/с ↑ ${myBytes(up)}/с',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Сайт, IP, сервер или порт',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => query.value = v,
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                chip('all', 'Все'),
                chip('proxy', 'Через VPN'),
                chip('direct', 'Напрямую'),
                chip('closed', 'Закрытые'),
              ],
            ),
          ),
          if (!running || error.value != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                !running ? 'VPN выключен — соединений нет.' : error.value!,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: ListView.separated(
              itemCount: shown.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final c = shown[i];
                final closed = c.closedAt != null;
                final color = closed
                    ? theme.colorScheme.onSurfaceVariant
                    : (c.isDirect ? const Color(0xFF34D399) : const Color(0xFF22D3EE));
                return ListTile(
                  dense: true,
                  leading: Icon(
                    closed
                        ? Icons.link_off_rounded
                        : (c.via == 'Заблокировано'
                              ? Icons.block_rounded
                              : (c.isDirect ? Icons.arrow_forward_rounded : Icons.vpn_lock_rounded)),
                    color: color,
                  ),
                  title: Text(
                    '${c.target}:${c.port}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: closed ? TextStyle(color: theme.colorScheme.onSurfaceVariant) : null,
                  ),
                  subtitle: Text(
                    '${c.network} · ${c.via}${closed ? ' · закрыто' : ''}\n'
                    '↓ ${myBytes(c.down)} ↑ ${myBytes(c.up)}'
                    '${closed ? '' : ' · ${myBytes(c.downSpeed)}/с'}',
                    maxLines: 2,
                  ),
                  isThreeLine: true,
                  onTap: () => showMyConnection(context, ref, c),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showMyConnection(BuildContext context, WidgetRef ref, MyConn c) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String s) => messenger?.showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 3)));

  Future<void> addRule(Outbound out, String what) async {
    final host = c.host;
    final rule = Rule(
      name: '${c.target} — $what',
      outbound: out,
      domainSuffixes: host.isNotEmpty ? [host] : null,
      ipCidrs: host.isEmpty && c.ip.isNotEmpty ? [c.ip] : null,
    );
    await ref.read(rulesNotifierProvider.notifier).addRule(rule);
    say('Правило добавлено: ${c.target} — $what. VPN переподключится');
  }

  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (context) {
      final theme = Theme.of(context);
      final start = c.start;
      String row(String k, String v) => '$k: $v';
      final lines = [
        row('Адрес', c.host.isNotEmpty ? c.host : '—'),
        row('IP', c.ip.isNotEmpty ? c.ip : '—'),
        row('Порт', c.port),
        row('Протокол', c.network),
        row('Через', c.via),
        if (c.chains.length > 1) row('Цепочка', c.chains.map(_myCleanOut).join(' → ')),
        if (c.rule.isNotEmpty) row('Правило', c.rule),
        row('Скачано', myBytes(c.down)),
        row('Отправлено', myBytes(c.up)),
        if (start != null)
          row('Длится', c.closedAt == null ? _myDur(DateTime.now().difference(start)) : '${_myDur(c.closedAt!.difference(start))} (закрыто)'),
      ];
      return AlertDialog(
        title: Text(c.target, maxLines: 2, overflow: TextOverflow.ellipsis),
        titleTextStyle: theme.textTheme.titleMedium,
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(lines.join('\n'), style: theme.textTheme.bodySmall),
              if (c.ip.isNotEmpty)
                FutureBuilder<String?>(
                  future: myIpProvider(c.ip),
                  builder: (_, snap) => Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Провайдер: ${snap.connectionState != ConnectionState.done ? '…' : (snap.data ?? 'неизвестно')}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              if (c.closedAt == null)
                OutlinedButton.icon(
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('Закрыть соединение'),
                  onPressed: () async {
                    Navigator.of(context).pop();
                    await MyClashApi.close(ref, c.id);
                    say('Соединение закрыто');
                  },
                ),
              const SizedBox(height: 4),
              OutlinedButton.icon(
                icon: const Icon(Icons.arrow_forward_rounded),
                label: const Text('Всегда напрямую'),
                onPressed: () async {
                  Navigator.of(context).pop();
                  await addRule(Outbound.direct, 'напрямую');
                },
              ),
              const SizedBox(height: 4),
              OutlinedButton.icon(
                icon: const Icon(Icons.vpn_lock_rounded),
                label: const Text('Всегда через VPN'),
                onPressed: () async {
                  Navigator.of(context).pop();
                  await addRule(Outbound.proxy, 'через VPN');
                },
              ),
              const SizedBox(height: 4),
              OutlinedButton.icon(
                icon: const Icon(Icons.block_rounded),
                label: const Text('Блокировать'),
                onPressed: () async {
                  Navigator.of(context).pop();
                  await addRule(Outbound.block, 'блок');
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: c.target));
              if (context.mounted) Navigator.of(context).pop();
              say('Скопировано: ${c.target}');
            },
            child: const Text('Копировать адрес'),
          ),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Закрыть')),
        ],
      );
    },
  );
}

String _myDur(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds} с';
  if (d.inMinutes < 60) return '${d.inMinutes} мин ${d.inSeconds % 60} с';
  return '${d.inHours} ч ${d.inMinutes % 60} мин';
}
