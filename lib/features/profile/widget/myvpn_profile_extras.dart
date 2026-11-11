// MyVPN: число серверов, время обновления и список серверов профиля без подключения:
// поиск, фильтры, TCP-пинг, избранное, исключение из автовыбора, JSON, ссылка и QR.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/features/common/qr_code_dialog.dart';
import 'package:hiddify/features/profile/data/myvpn_marks.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/widget/myvpn_share_links.dart';
import 'package:hiddify/utils/myvpn_xray_names.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Один сервер профиля.
typedef MyServer = ({
  String name,
  String info,
  String type,
  Map<String, dynamic> json,
  String key,
  bool hidden,
  bool fav,
  String host,
  int port,
  bool udp,
});

const _mySkipTypes = {'selector', 'urltest', 'direct', 'block', 'dns'};
const _myUdpTypes = {'hysteria2', 'hysteria', 'tuic', 'wireguard'};

/// Сервер из JSON (без файла и отметок) — для тестов и разбора.
MyServer myServerFrom(Map<String, dynamic> item, {bool endpoint = false}) {
  final type = (item['type'] ?? '').toString();
  final tag = (item['tag'] ?? type).toString();
  final key = myServerKey(item);
  return (
    name: myCleanTag(tag.replaceAll(myHideMark, '')),
    info: _myInfo(item),
    type: type,
    json: item,
    key: key,
    hidden: tag.contains(myHideMark),
    fav: MyMarks.fav.contains(key),
    host: (item['server'] ?? '').toString(),
    port: item['server_port'] is int ? item['server_port'] as int : 0,
    udp: endpoint || _myUdpTypes.contains(type),
  );
}

/// Серверы профиля, прочитанные из его сохранённого файла (VPN не нужен).
Future<List<MyServer>> myProfileServers(WidgetRef ref, String id) async {
  try {
    await MyMarks.load();
    final file = ref.read(profilePathResolverProvider).file(id);
    if (!await file.exists()) return const [];
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, dynamic>) return const [];
    final result = <MyServer>[];
    for (final key in const ['outbounds', 'endpoints']) {
      final list = json[key];
      if (list is! List) continue;
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        if (_mySkipTypes.contains(item['type'])) continue;
        final tag = (item['tag'] ?? '').toString();
        // серверы, скрытые самой подпиской (не нами), не показываем
        if (tag.replaceAll(myHideMark, '').contains('§hide§')) continue;
        result.add(myServerFrom(item, endpoint: key == 'endpoints'));
      }
    }
    return result;
  } catch (_) {
    return const [];
  }
}

String _myInfo(Map<String, dynamic> o) {
  final parts = <String>[(o['type'] ?? '').toString().toUpperCase()];
  final transport = o['transport'];
  parts.add(transport is Map && transport['type'] != null ? transport['type'].toString() : 'tcp');
  final tls = o['tls'];
  if (tls is Map && tls['enabled'] == true) {
    final reality = tls['reality'];
    parts.add(reality is Map && reality['enabled'] == true ? 'reality' : 'tls');
  }
  if (o['obfs'] is Map) parts.add('obfs');
  return parts.join(' · ');
}

/// «1 сервер», «3 сервера», «25 серверов»
String myServersWord(int n) {
  final a = n % 10, b = n % 100;
  if (a == 1 && b != 11) return '$n сервер';
  if (a >= 2 && a <= 4 && (b < 12 || b > 14)) return '$n сервера';
  return '$n серверов';
}

/// «сегодня 12:30», «вчера 09:05», «03.11 18:40», «03.11.25»
String myUpdatedText(DateTime time) {
  final t = time.toLocal();
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'сегодня $hm';
  if (diff == 1) return 'вчера $hm';
  if (t.year == now.year) return '${two(t.day)}.${two(t.month)} $hm';
  return '${two(t.day)}.${two(t.month)}.${two(t.year % 100)}';
}

/// Предупреждение о скором конце подписки или трафика, иначе null.
String? myExpiryWarning(ProfileEntity profile) {
  if (profile case RemoteProfileEntity(:final subInfo?)) {
    if (subInfo.isExpired) return '⛔ подписка истекла';
    if (subInfo.ratio >= 1) return '⛔ трафик закончился';
    final days = subInfo.remaining.inDays;
    if (days < 3) return days <= 0 ? '⚠ меньше суток' : '⚠ осталось $days дн.';
    if (subInfo.ratio >= 0.9) return '⚠ трафик ${(subInfo.ratio * 100).round()}%';
  }
  return null;
}

/// Флаг страны в начале имени («🇩🇪 DE | Berlin» → «🇩🇪»), иначе пусто.
String myFlagOf(String name) {
  final runes = name.runes.toList();
  bool isRegional(int r) => r >= 0x1F1E6 && r <= 0x1F1FF;
  if (runes.length >= 2 && isRegional(runes[0]) && isRegional(runes[1])) {
    return String.fromCharCodes(runes.take(2));
  }
  return '';
}

/// Имя профиля, а справа — число серверов и время обновления.
class MyNameRow extends StatelessWidget {
  const MyNameRow({super.key, required this.profile, required this.text});

  final ProfileEntity profile;
  final Widget text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: text),
        Padding(padding: const EdgeInsetsDirectional.only(start: 8), child: MyProfileMeta(profile)),
      ],
    );
  }
}

class MyProfileMeta extends HookConsumerWidget {
  const MyProfileMeta(this.profile, {super.key});

  final ProfileEntity profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final servers = useFuture(
      useMemoized(() => myProfileServers(ref, profile.id), [profile.id, profile.lastUpdate]),
    ).data;
    final style = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.2);
    final warning = myExpiryWarning(profile);
    final count = servers?.where((s) => !s.hidden).length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(count == null ? '…' : myServersWord(count), style: style, maxLines: 1),
        Text(myUpdatedText(profile.lastUpdate), style: style, maxLines: 1),
        if (warning != null)
          Text(
            warning,
            maxLines: 1,
            style: style?.copyWith(
              color: warning.startsWith('⛔') ? theme.colorScheme.error : const Color(0xFFF59E0B),
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }
}

/// Серверы по разделам: «Автовыбор [1]», «Автовыбор [2]» → раздел «Автовыбор»; порядок как в подписке.
List<({String name, List<MyServer> servers})> myGroupServers(List<MyServer> servers) {
  final map = <String, List<MyServer>>{};
  for (final s in servers) {
    final key = s.name.replaceFirst(RegExp(r'\s*(\[\d+(\.\d+)?\]|\(\d+\))$'), '').trim();
    map.putIfAbsent(key.isEmpty ? s.name : key, () => []).add(s);
  }
  return [for (final e in map.entries) (name: e.key, servers: e.value)];
}

/// Отбор по строке поиска, протоколу и флагу страны.
List<MyServer> myFilterServers(List<MyServer> servers, {String query = '', String? type, String? flag}) {
  final q = query.trim().toLowerCase();
  return [
    for (final s in servers)
      if ((q.isEmpty || s.name.toLowerCase().contains(q) || s.host.toLowerCase().contains(q)) &&
          (type == null || s.type == type) &&
          (flag == null || myFlagOf(s.name) == flag))
        s,
  ];
}

/// TCP-пинг: время подключения к серверу в мс, null — не ответил. Через VPN, если он включён.
Future<int?> myTcpPing(String host, int port, {Duration timeout = const Duration(seconds: 3)}) async {
  if (host.isEmpty || port <= 0) return null;
  final sw = Stopwatch()..start();
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    sw.stop();
    socket.destroy();
    return sw.elapsedMilliseconds;
  } catch (_) {
    return null;
  }
}

void _myCopy(BuildContext context, String text, String message) {
  Clipboard.setData(ClipboardData(text: text));
  _mySnack(context, message);
}

void _mySnack(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
  );
}

/// Окно со списком серверов профиля.
Future<void> showMyServers(BuildContext context, WidgetRef ref, ProfileEntity profile) async {
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (_) => _MyServersDialog(profile: profile),
  );
}

class _MyServersDialog extends HookConsumerWidget {
  const _MyServersDialog({required this.profile});

  final ProfileEntity profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final reload = useState(0);
    final servers = useFuture(useMemoized(() => myProfileServers(ref, profile.id), [reload.value])).data;
    final query = useState('');
    final type = useState<String?>(null);
    final flag = useState<String?>(null);
    final onlyAlive = useState(false);
    final pings = useState<Map<String, int?>>({});
    final pinging = useState(false);

    if (servers == null) {
      return const AlertDialog(content: SizedBox(height: 80, child: Center(child: CircularProgressIndicator())));
    }
    final types = {for (final s in servers) s.type}.toList()..sort();
    final flags = [
      for (final f in {for (final s in servers) myFlagOf(s.name)})
        if (f.isNotEmpty) f,
    ];
    var shown = myFilterServers(servers, query: query.value, type: type.value, flag: flag.value);
    if (onlyAlive.value) shown = [for (final s in shown) if (s.udp || pings.value[s.key] != null) s];
    final groups = myGroupServers(shown);
    final visibleCount = servers.where((s) => !s.hidden).length;
    final links = [for (final s in shown) ?myOutboundToLink({...s.json, 'tag': s.name})];

    Future<void> runPing() async {
      pinging.value = true;
      final result = <String, int?>{};
      final queue = [for (final s in shown) if (!s.udp) s];
      Future<void> worker() async {
        while (queue.isNotEmpty) {
          final s = queue.removeLast();
          result[s.key] = await myTcpPing(s.host, s.port);
          pings.value = {...pings.value, s.key: result[s.key]};
        }
      }
      await Future.wait([for (var i = 0; i < 16; i++) worker()]);
      pinging.value = false;
      if (context.mounted) {
        final alive = result.values.whereType<int>().length;
        _mySnack(context, 'TCP: отвечают $alive из ${result.length}');
      }
    }

    Widget tile(MyServer s) {
      final ping = pings.value[s.key];
      final tested = pings.value.containsKey(s.key);
      final Widget trailing = s.udp
          ? Text('UDP', style: theme.textTheme.bodySmall)
          : !tested
          ? const Icon(Icons.chevron_right_rounded)
          : Text(
              ping == null ? '✖' : '$ping ms',
              style: theme.textTheme.bodySmall?.copyWith(
                color: ping == null ? theme.colorScheme.error : const Color(0xFF34D399),
                fontWeight: FontWeight.w600,
              ),
            );
      return ListTile(
        dense: true,
        leading: s.fav ? const Icon(Icons.star_rounded, color: Color(0xFFF59E0B), size: 20) : null,
        minLeadingWidth: 20,
        title: Text(
          s.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: s.hidden ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
        ),
        subtitle: Text(s.hidden ? '${s.info} · исключён из автовыбора' : s.info),
        trailing: trailing,
        onTap: () async {
          final changed = await showMyServer(context, ref, s);
          if (changed) reload.value++;
        },
      );
    }

    Widget chip(String label, bool selected, VoidCallback onTap) => Padding(
      padding: const EdgeInsetsDirectional.only(end: 6),
      child: ChoiceChip(label: Text(label), selected: selected, onSelected: (_) => onTap(), visualDensity: VisualDensity.compact),
    );

    return AlertDialog(
      title: Text('${profile.name}\n${myServersWord(visibleCount)} · ${myUpdatedText(profile.lastUpdate)}'),
      titleTextStyle: theme.textTheme.titleMedium,
      contentPadding: const EdgeInsets.only(top: 8),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search_rounded),
                  hintText: 'Поиск по имени или адресу',
                ),
                onChanged: (v) => query.value = v,
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                children: [
                  chip('Все', type.value == null && flag.value == null && !onlyAlive.value, () {
                    type.value = null;
                    flag.value = null;
                    onlyAlive.value = false;
                  }),
                  if (pings.value.isNotEmpty) chip('Живые', onlyAlive.value, () => onlyAlive.value = !onlyAlive.value),
                  if (types.length > 1)
                    for (final t in types) chip(t.toUpperCase(), type.value == t, () => type.value = type.value == t ? null : t),
                  if (flags.length > 1)
                    for (final f in flags) chip(f, flag.value == f, () => flag.value = flag.value == f ? null : f),
                ],
              ),
            ),
            Flexible(
              child: shown.isEmpty
                  ? const Padding(padding: EdgeInsets.all(24), child: Text('Ничего не найдено'))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: groups.length,
                      itemBuilder: (context, i) {
                        final g = groups[i];
                        if (g.servers.length == 1) return tile(g.servers.first);
                        final alive = g.servers.where((s) => pings.value[s.key] != null).length;
                        final tested = g.servers.where((s) => pings.value.containsKey(s.key)).length;
                        return ExpansionTile(
                          initiallyExpanded: groups.length == 1 || query.value.isNotEmpty,
                          shape: const Border(),
                          collapsedShape: const Border(),
                          title: Text(g.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            tested == 0 ? myServersWord(g.servers.length) : '${myServersWord(g.servers.length)} · отвечают $alive',
                          ),
                          childrenPadding: const EdgeInsetsDirectional.only(start: 12),
                          children: [for (final s in g.servers) tile(s)],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actionsOverflowButtonSpacing: 4,
      actions: [
        TextButton(
          onPressed: pinging.value ? null : runPing,
          child: Text(pinging.value ? 'Пинг…' : 'Пинг TCP'),
        ),
        if (links.isNotEmpty)
          TextButton(
            onPressed: () => _myCopy(context, links.join('\n'), 'Скопировано ссылок: ${links.length}'),
            child: const Text('Копировать все'),
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Закрыть')),
      ],
    );
  }
}

/// Один сервер: JSON, ссылка, QR-код, избранное, исключение. Возвращает true, если отметки поменялись.
Future<bool> showMyServer(BuildContext context, WidgetRef ref, MyServer server) async {
  final link = myOutboundToLink({...server.json, 'tag': server.name});
  final json = myPrettyJson({...server.json, 'tag': server.name});
  var changed = false;

  Future<void> mark({bool? fav, bool? hidden}) async {
    await MyMarks.load();
    if (fav != null) fav ? MyMarks.fav.add(server.key) : MyMarks.fav.remove(server.key);
    if (hidden != null) hidden ? MyMarks.hidden.add(server.key) : MyMarks.hidden.remove(server.key);
    await MyMarks.save();
    changed = true;
    final repo = await ref.read(profileRepositoryProvider.future);
    await repo.myMarksChanged();
  }

  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: Text(server.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        titleTextStyle: theme.textTheme.titleMedium,
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  icon: Icon(server.fav ? Icons.star_rounded : Icons.star_outline_rounded, color: const Color(0xFFF59E0B)),
                  label: Text(server.fav ? 'Убрать из избранного' : 'В избранное'),
                  onPressed: () async {
                    await mark(fav: !server.fav);
                    if (context.mounted) {
                      _mySnack(context, server.fav ? 'Убрано из «Избранного»' : 'Добавлено в «Избранное»');
                      Navigator.of(context).pop();
                    }
                  },
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: Icon(server.hidden ? Icons.undo_rounded : Icons.block_rounded),
                  label: Text(server.hidden ? 'Вернуть в автовыбор' : 'Исключить из автовыбора'),
                  onPressed: () async {
                    await mark(hidden: !server.hidden);
                    if (context.mounted) {
                      _mySnack(context, 'Готово. Переподключитесь, чтобы применить');
                      Navigator.of(context).pop();
                    }
                  },
                ),
                const SizedBox(height: 12),
                SelectableText(json, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ],
            ),
          ),
        ),
        actionsOverflowButtonSpacing: 4,
        actions: [
          if (link != null) ...[
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                useRootNavigator: true,
                builder: (_) => QrCodeDialog(link, title: server.name, link: link),
              ),
              child: const Text('QR-код'),
            ),
            TextButton(onPressed: () => _myCopy(context, link, 'Ссылка скопирована'), child: const Text('Ссылка')),
          ],
          TextButton(onPressed: () => _myCopy(context, json, 'JSON скопирован'), child: const Text('JSON')),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Закрыть')),
        ],
      );
    },
  );
  return changed;
}
