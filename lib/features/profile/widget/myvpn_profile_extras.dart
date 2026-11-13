// MyVPN: число серверов, время обновления и список серверов профиля без подключения:
// поиск, фильтры, TCP-пинг, избранное, исключение, страны и раздел для автовыбора,
// подключение к серверу или разделу, отметки 🔓 и 📶, JSON, ссылка и QR.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/features/common/qr_code_dialog.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/myvpn_marks.dart';
import 'package:hiddify/features/connections/myvpn_connections.dart' show mySubRulesVersionProvider;
import 'package:hiddify/features/profile/widget/profile_tile.dart';
import 'package:hiddify/features/stats/myvpn_counters.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/widget/myvpn_share_links.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Один сервер профиля.
typedef MyServer = ({
  String name,
  String tag,
  String info,
  String type,
  Map<String, dynamic> json,
  String key,
  bool hidden,
  String? hiddenReason,
  bool fav,
  bool lte,
  String? insecure,
  String host,
  int port,
  bool udp,
});

const _mySkipTypes = {'selector', 'urltest', 'direct', 'block', 'dns'};
const _myUdpTypes = {'hysteria2', 'hysteria', 'tuic', 'wireguard'};

/// Сервер из JSON файла профиля.
MyServer myServerFrom(Map<String, dynamic> item, {bool endpoint = false, String? profileId}) {
  final type = (item['type'] ?? '').toString();
  final tag = (item['tag'] ?? type).toString();
  final hidden = tag.contains(myHideMark);
  return (
    name: myCleanName(tag),
    tag: tag,
    info: _myInfo(item),
    type: type,
    json: item,
    key: myServerKey(item),
    hidden: hidden,
    hiddenReason: hidden ? (myHiddenReason(item, MyTransformOptions.forProfile(profileId)) ?? 'скрыт') : null,
    fav: myHasKey(MyMarks.fav, item),
    lte: myHasKey(MyMarks.lteOk, item),
    insecure: myInsecureReason(item),
    host: (item['server'] ?? '').toString(),
    port: item['server_port'] is int ? item['server_port'] as int : 0,
    udp: endpoint || _myUdpTypes.contains(type),
  );
}

/// Серверы профиля, прочитанные из его файла (VPN не нужен).
Future<List<MyServer>> myProfileServers(WidgetRef ref, String id) async {
  try {
    await MyMarks.load();
    final file = ref.read(profilePathResolverProvider).file(id);
    if (!await file.exists()) return const [];
    return myServersFromText(await file.readAsString(), profileId: id);
  } catch (_) {
    return const [];
  }
}

List<MyServer> myServersFromText(String text, {String? profileId}) {
  final json = jsonDecode(text);
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
      result.add(myServerFrom(item, endpoint: key == 'endpoints', profileId: profileId));
    }
  }
  return result;
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
  if (o['server_port'] != null) parts.add(':${o['server_port']}');
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

/// Имя профиля, а справа — число серверов и время обновления.
class MyNameRow extends StatelessWidget {
  const MyNameRow({super.key, required this.profile, required this.text});

  final ProfileEntity profile;
  final Widget text;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final hasBar = p is RemoteProfileEntity && p.subInfo != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: text),
            Padding(padding: const EdgeInsetsDirectional.only(start: 8), child: MyProfileMeta(profile)),
          ],
        ),
        MyCounterLine(name: profile.name, hasProviderBar: hasBar),
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
    final section = MyMarks.sections[profile.id];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 140),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(count == null ? '…' : myServersWord(count), style: style, maxLines: 1),
          Text(myUpdatedText(profile.lastUpdate), style: style, maxLines: 1),
          if (section != null)
            Text('📂 $section', style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
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
      ),
    );
  }
}

/// Серверы по разделам; порядок как в подписке.
List<({String name, List<MyServer> servers})> myGroupServers(List<MyServer> servers) {
  final map = <String, List<MyServer>>{};
  for (final s in servers) {
    map.putIfAbsent(myGroupKey(s.name), () => []).add(s);
  }
  return [for (final e in map.entries) (name: e.key, servers: e.value)];
}

/// Отбор по строке поиска, протоколу, флагу страны и отметке «работал на LTE».
List<MyServer> myFilterServers(
  List<MyServer> servers, {
  String query = '',
  String? type,
  String? flag,
  bool onlyLte = false,
}) {
  final q = query.trim().toLowerCase();
  return [
    for (final s in servers)
      if ((q.isEmpty || s.name.toLowerCase().contains(q) || s.host.toLowerCase().contains(q)) &&
          (type == null || s.type == type) &&
          (flag == null || myFlagOf(s.name) == flag) &&
          (!onlyLte || s.lte))
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
  mySnack(context, message);
}

void mySnack(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
  );
}

/// Применить отметки и настройки ко всем профилям (и пересобрать общие профили).
Future<void> myApplyMarks(WidgetRef ref) async {
  await MyMarks.save();
  final repo = await ref.read(profileRepositoryProvider.future);
  await repo.myMarksChanged();
}

/// Подключиться к профилю, а если указан [serverTag] — сразу к этому серверу.
/// [reload] — профиль уже активен и подключён, но его файл поменялся: переподключить.
/// Возвращает текст ошибки или null.
Future<String?> myConnectTo(WidgetRef ref, ProfileEntity profile, {String? serverTag, bool reload = false}) async {
  try {
    final active = await ref.read(activeProfileProvider.future);
    final wasRunning = ref.read(serviceRunningProvider);
    if (active?.id != profile.id) {
      // при смене профиля приложение само переподключается, если VPN включён
      final repo = await ref.read(profileRepositoryProvider.future);
      await repo.setAsActive(profile.id).run();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    } else if (wasRunning && reload) {
      await ref.read(connectionNotifierProvider.notifier).reconnect(profile);
    }
    if (!ref.read(serviceRunningProvider)) {
      await ref.read(connectionNotifierProvider.notifier).toggleConnection();
    }
    if (serverTag == null) return null;
    // ждём, пока ядро запустится и покажет серверы
    for (var i = 0; i < 50; i++) {
      final list = ref.read(mainOutboundsNotifierProvider).valueOrNull;
      if (list != null && list.items.isNotEmpty) {
        final res = await ref.read(proxyRepositoryProvider).selectProxy('select', serverTag).run();
        if (res.isRight()) return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return 'Не удалось выбрать сервер: VPN не подключился';
  } catch (e) {
    return 'Не удалось подключиться: $e';
  }
}

/// Подписка во вкладке «Серверы»: карточка (нажатие — выбрать, ⋯ — действия),
/// под ней стрелка — раскрывает группы и серверы прямо здесь.
class MyTabProfile extends HookConsumerWidget {
  const MyTabProfile({super.key, required this.profile});

  final ProfileEntity profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final open = useState(false);
    final active = ref.watch(activeProfileProvider).valueOrNull?.id == profile.id;
    final section = MyMarks.sections[profile.id];
    final hasGroups = MyMarks.subGroups[profile.id]?.isNotEmpty ?? false;
    final label = [
      if (hasGroups) 'Группы и серверы' else 'Серверы',
      if (active && section != null) '📂 $section',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ProfileTile(profile: profile),
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => open.value = !open.value,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
                  ),
                ),
                AnimatedRotation(
                  turns: open.value ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.expand_more_rounded, color: theme.colorScheme.primary),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topCenter,
          child: open.value
              ? Card(
                  margin: const EdgeInsets.only(bottom: 4),
                  clipBehavior: Clip.antiAlias,
                  child: _MyServersDialog(profile: profile, inline: true),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
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
  const _MyServersDialog({required this.profile, this.inline = false});

  final ProfileEntity profile;
  final bool inline; // прямо в карточке подписки во вкладке «Серверы»

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final reload = useState(0);
    final servers = useFuture(useMemoized(() => myProfileServers(ref, profile.id), [reload.value])).data;
    final query = useState('');
    final type = useState<String?>(null);
    final flag = useState<String?>(null);
    final onlyAlive = useState(false);
    final onlyLte = useState(false);
    final pings = useState<Map<String, int?>>({});
    final pinging = useState(false);
    final busy = useState(false);

    if (servers == null) {
      if (inline) return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
      return const AlertDialog(content: SizedBox(height: 80, child: Center(child: CircularProgressIndicator())));
    }
    final types = {for (final s in servers) s.type}.toList()..sort();
    final flags = [
      for (final f in {for (final s in servers) myFlagOf(s.name)})
        if (f.isNotEmpty) f,
    ];
    var shown = myFilterServers(servers, query: query.value, type: type.value, flag: flag.value, onlyLte: onlyLte.value);
    if (onlyAlive.value) shown = [for (final s in shown) if (s.udp || pings.value[s.key] != null) s];
    // группы самой подписки (свой «Автовыбор» и т. п.) — сначала, потом остальные разделы
    final subGroups = MyMarks.subGroups[profile.id] ?? const <String, List<String>>{};
    final groups = <({String name, List<MyServer> servers, bool sub})>[
      for (final g in subGroups.entries)
        if ([for (final s in shown) if (g.value.contains(s.key)) s] case final list when list.isNotEmpty)
          (name: g.key, servers: list, sub: true),
    ];
    final inSub = {for (final g in subGroups.values) ...g};
    for (final g in myGroupServers([for (final s in shown) if (!inSub.contains(s.key)) s])) {
      groups.add((name: g.name, servers: g.servers, sub: false));
    }
    final hasSubRules = MyMarks.subRules[profile.id]?.isNotEmpty ?? false;
    final subRulesOn = hasSubRules && !MyMarks.subRulesOff.contains(profile.id);
    final visibleCount = servers.where((s) => !s.hidden).length;
    final links = [for (final s in shown) ?myOutboundToLink({...s.json, 'tag': s.name})];
    final section = MyMarks.sections[profile.id];
    final anyLte = servers.any((s) => s.lte);

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
        mySnack(context, 'TCP: отвечают $alive из ${result.length}');
      }
    }

    Future<void> connectSection(String? name) async {
      busy.value = true;
      if (name == null) {
        MyMarks.sections.remove(profile.id);
      } else {
        MyMarks.sections[profile.id] = name;
      }
      await myApplyMarks(ref);
      final err = await myConnectTo(ref, profile, reload: true);
      busy.value = false;
      reload.value++;
      if (context.mounted) {
        mySnack(context, err ?? (name == null ? 'Автовыбор по всей подписке' : 'Автовыбор только в разделе «$name»'));
      }
    }

    Future<void> chooseCountries() async {
      final current = {...?MyMarks.profileCountries[profile.id]};
      final picked = await showMyFlagsDialog(
        context,
        title: 'Страны автовыбора для «${profile.name}»',
        flags: flags,
        selected: current,
        hint: 'Ничего не выбрано — действуют общие страны из настроек',
      );
      if (picked == null) return;
      busy.value = true;
      if (picked.isEmpty) {
        MyMarks.profileCountries.remove(profile.id);
      } else {
        MyMarks.profileCountries[profile.id] = picked;
      }
      await myApplyMarks(ref);
      busy.value = false;
      reload.value++;
      if (context.mounted) mySnack(context, 'Готово. Переподключитесь, чтобы применить');
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
      final marks = [if (s.fav) '⭐', if (s.lte) '📶', if (s.insecure != null) '🔓'].join();
      final sub = [
        s.info,
        if (s.insecure != null) s.insecure!,
        if (s.hidden) 'не в автовыборе: ${s.hiddenReason}',
      ].join(' · ');
      return ListTile(
        dense: true,
        title: Text(
          marks.isEmpty ? s.name : '$marks ${s.name}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            decoration: s.hidden ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: Text(
          sub,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        trailing: trailing,
        onTap: () async {
          final changed = await showMyServer(context, ref, s, profile);
          if (changed) reload.value++;
        },
      );
    }

    Widget chip(String label, bool selected, VoidCallback onTap) => Padding(
      padding: const EdgeInsetsDirectional.only(end: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
      ),
    );

    final media = MediaQuery.of(context).size;
    final headStyle = theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600);
    final smallStyle = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget action(String label, VoidCallback? onTap, {IconData? icon}) => TextButton.icon(
      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      icon: Icon(icon ?? Icons.circle, size: 18),
      label: Text(label),
      onPressed: onTap,
    );

    Widget list(Widget child) => inline ? child : Expanded(child: child);

    final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (inline)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${myServersWord(visibleCount)} в автовыборе · ${myUpdatedText(profile.lastUpdate)}',
                      style: smallStyle,
                    ),
                    if (section != null) Text('📂 подключено к: $section', style: smallStyle),
                    if (hasSubRules) Text('📜 правила подписки: ${subRulesOn ? 'включены' : 'выключены'}', style: smallStyle),
                  ],
                ),
              )
            else
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 8, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(profile.name, style: headStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text(
                          '${myServersWord(visibleCount)} в автовыборе · ${myUpdatedText(profile.lastUpdate)}',
                          style: smallStyle,
                        ),
                        if (section != null) Text('📂 подключено к: $section', style: smallStyle),
                        if (hasSubRules) Text('📜 правила подписки: ${subRulesOn ? 'включены' : 'выключены'}', style: smallStyle),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            if (busy.value) const LinearProgressIndicator(minHeight: 2),
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
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                children: [
                  chip(
                    'Все',
                    type.value == null && flag.value == null && !onlyAlive.value && !onlyLte.value,
                    () {
                      type.value = null;
                      flag.value = null;
                      onlyAlive.value = false;
                      onlyLte.value = false;
                    },
                  ),
                  if (pings.value.isNotEmpty) chip('Живые', onlyAlive.value, () => onlyAlive.value = !onlyAlive.value),
                  if (anyLte) chip('📶 LTE', onlyLte.value, () => onlyLte.value = !onlyLte.value),
                  if (types.length > 1)
                    for (final t in types)
                      chip(t.toUpperCase(), type.value == t, () => type.value = type.value == t ? null : t),
                  if (flags.length > 1)
                    for (final f in flags) chip(f, flag.value == f, () => flag.value = flag.value == f ? null : f),
                ],
              ),
            ),
            list(
              shown.isEmpty
                  ? const Padding(padding: EdgeInsets.all(16), child: Center(child: Text('Ничего не найдено')))
                  : ListView.builder(
                      shrinkWrap: inline,
                      physics: inline ? const NeverScrollableScrollPhysics() : null,
                      padding: inline ? EdgeInsets.zero : null,
                      itemCount: groups.length,
                      itemBuilder: (context, i) {
                        final g = groups[i];
                        if (g.servers.length == 1 && !g.sub) return tile(g.servers.first);
                        final alive = g.servers.where((s) => pings.value[s.key] != null).length;
                        final tested = g.servers.where((s) => pings.value.containsKey(s.key)).length;
                        final isSection = section == g.name;
                        final count = tested == 0
                            ? myServersWord(g.servers.length)
                            : '${myServersWord(g.servers.length)} · отвечают $alive';
                        return ExpansionTile(
                          initiallyExpanded: groups.length == 1 || query.value.isNotEmpty,
                          shape: const Border(),
                          collapsedShape: const Border(),
                          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                          title: Text(
                            '${g.sub ? '⚡ ' : ''}${isSection ? '📂 ' : ''}${g.name}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(g.sub ? 'группа подписки · $count' : count, style: smallStyle),
                          childrenPadding: const EdgeInsetsDirectional.only(start: 12),
                          children: [
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: Padding(
                                padding: const EdgeInsetsDirectional.only(start: 4, bottom: 4),
                                child: FilledButton.tonalIcon(
                                  icon: Icon(isSection ? Icons.layers_clear_rounded : Icons.play_arrow_rounded),
                                  label: Text(
                                    isSection
                                        ? 'Автовыбор по всей подписке'
                                        : (g.sub ? 'Подключиться к группе' : 'Подключить раздел (автовыбор в нём)'),
                                  ),
                                  onPressed: busy.value ? null : () => connectSection(isSection ? null : g.name),
                                ),
                              ),
                            ),
                            for (final s in g.servers) tile(s),
                          ],
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 2,
                children: [
                  action(pinging.value ? 'Пинг…' : 'Пинг TCP', pinging.value ? null : runPing, icon: Icons.network_ping_rounded),
                  if (flags.length > 1) action('Страны', busy.value ? null : chooseCountries, icon: Icons.flag_outlined),
                  if (section != null)
                    action('Вся подписка', busy.value ? null : () => connectSection(null), icon: Icons.layers_clear_rounded),
                  if (hasSubRules)
                    action(
                      subRulesOn ? 'Выключить правила подписки' : 'Включить правила подписки',
                      () async {
                        if (subRulesOn) {
                          MyMarks.subRulesOff.add(profile.id);
                        } else {
                          MyMarks.subRulesOff.remove(profile.id);
                        }
                        await MyMarks.save();
                        ref.read(mySubRulesVersionProvider.notifier).state++;
                        reload.value++;
                      },
                      icon: Icons.rule_rounded,
                    ),
                  if (links.isNotEmpty)
                    action(
                      'Копировать все',
                      () => _myCopy(context, links.join('\n'), 'Скопировано ссылок: ${links.length}'),
                      icon: Icons.copy_all_rounded,
                    ),
                ],
              ),
            ),
          ],
        );
    if (inline) return content;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 36),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(width: media.width, height: media.height * 0.86, child: content),
    );
  }
}

/// Выбор флагов стран. Возвращает выбранные (пусто — без ограничений) или null при отмене.
Future<Set<String>?> showMyFlagsDialog(
  BuildContext context, {
  required String title,
  required List<String> flags,
  required Set<String> selected,
  String? hint,
}) {
  return showDialog<Set<String>>(
    context: context,
    useRootNavigator: true,
    builder: (context) {
      final picked = {...selected};
      return StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hint != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(hint)),
                if (flags.isEmpty) const Text('В подписках нет серверов с флагами стран'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final f in flags)
                      FilterChip(
                        label: Text(f, style: const TextStyle(fontSize: 20)),
                        selected: picked.contains(f),
                        onSelected: (v) => setState(() => v ? picked.add(f) : picked.remove(f)),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(<String>{}), child: const Text('Все страны')),
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
            TextButton(onPressed: () => Navigator.of(context).pop(picked), child: const Text('Готово')),
          ],
        ),
      );
    },
  );
}

/// Один сервер: подключение, JSON, ссылка, QR-код, избранное, исключение. true — отметки поменялись.
Future<bool> showMyServer(BuildContext context, WidgetRef ref, MyServer server, ProfileEntity profile) async {
  final link = myOutboundToLink({...server.json, 'tag': server.name});
  final json = myPrettyJson({...server.json, 'tag': server.name});
  var changed = false;

  Future<void> mark({bool? fav, bool? hidden}) async {
    await MyMarks.load();
    void set(Set<String> s, bool on) {
      s
        ..remove(myLegacyKey(server.json))
        ..remove(server.key);
      if (on) s.add(server.key);
    }

    if (fav != null) set(MyMarks.fav, fav);
    if (hidden != null) set(MyMarks.hidden, hidden);
    changed = true;
    await myApplyMarks(ref);
  }

  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (context) {
      final theme = Theme.of(context);
      final manual = myHasKey(MyMarks.hidden, server.json);
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
                if (server.insecure != null || server.lte || server.hidden)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      [
                        if (server.insecure != null)
                          '🔓 Небезопасный: ${server.insecure}. Не открывайте через него банк, почту и пароли.',
                        if (server.lte) '📶 Работал у вас на мобильной сети.',
                        if (server.hidden) '⛔ Не в автовыборе: ${server.hiddenReason}.',
                      ].join('\n'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                FilledButton.icon(
                  icon: const Icon(Icons.power_settings_new_rounded),
                  label: const Text('Подключиться к этому серверу'),
                  onPressed: server.hidden
                      ? null
                      : () async {
                          final messenger = ScaffoldMessenger.maybeOf(context);
                          messenger?.showSnackBar(const SnackBar(content: Text('Подключаюсь…')));
                          Navigator.of(context).pop();
                          final err = await myConnectTo(ref, profile, serverTag: server.tag);
                          messenger?.showSnackBar(SnackBar(content: Text(err ?? 'Подключено: ${server.name}')));
                        },
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: Icon(
                    server.fav ? Icons.star_rounded : Icons.star_outline_rounded,
                    color: const Color(0xFFF59E0B),
                  ),
                  label: Text(server.fav ? 'Убрать из избранного' : 'В избранное'),
                  onPressed: () async {
                    await mark(fav: !server.fav);
                    if (context.mounted) {
                      mySnack(context, server.fav ? 'Убрано из «Избранного»' : 'Добавлено в «Избранное»');
                      Navigator.of(context).pop();
                    }
                  },
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: Icon(manual ? Icons.undo_rounded : Icons.block_rounded),
                  label: Text(manual ? 'Вернуть в автовыбор' : 'Исключить из автовыбора'),
                  onPressed: () async {
                    await mark(hidden: !manual);
                    if (context.mounted) {
                      mySnack(context, 'Готово. Переподключитесь, чтобы применить');
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
