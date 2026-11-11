// MyVPN: число серверов, время обновления и список серверов профиля без подключения.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/features/common/qr_code_dialog.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/widget/myvpn_share_links.dart';
import 'package:hiddify/utils/myvpn_xray_names.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Один сервер профиля: имя и короткое описание (протокол, транспорт).
typedef MyServer = ({String name, String info, Map<String, dynamic> json});

const _mySkipTypes = {'selector', 'urltest', 'direct', 'block', 'dns'};

/// Серверы профиля, прочитанные из его сохранённого файла (VPN не нужен).
Future<List<MyServer>> myProfileServers(WidgetRef ref, String id) async {
  try {
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
        final type = (item['type'] ?? '').toString();
        if (_mySkipTypes.contains(type)) continue;
        final tag = (item['tag'] ?? type).toString();
        if (tag.contains('§hide§')) continue;
        result.add((name: myCleanTag(tag), info: _myInfo(item), json: item));
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(servers == null ? '…' : myServersWord(servers.length), style: style, maxLines: 1),
        Text(myUpdatedText(profile.lastUpdate), style: style, maxLines: 1),
      ],
    );
  }
}

/// Окно со списком серверов профиля.
Future<void> showMyServers(BuildContext context, WidgetRef ref, ProfileEntity profile) async {
  final servers = await myProfileServers(ref, profile.id);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (context) {
      final theme = Theme.of(context);
      final links = [for (final s in servers) ?myOutboundToLink({...s.json, 'tag': s.name})];
      return AlertDialog(
        title: Text('${profile.name}\n${myServersWord(servers.length)} · ${myUpdatedText(profile.lastUpdate)}'),
        titleTextStyle: theme.textTheme.titleMedium,
        contentPadding: const EdgeInsets.only(top: 12),
        content: SizedBox(
          width: double.maxFinite,
          child: servers.isEmpty
              ? const Padding(padding: EdgeInsets.all(24), child: Text('Серверов нет'))
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: servers.length,
                  itemBuilder: (context, i) => ListTile(
                    dense: true,
                    title: Text(servers[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(servers[i].info),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => showMyServer(context, servers[i]),
                  ),
                ),
        ),
        actions: [
          if (links.isNotEmpty)
            TextButton(
              onPressed: () => _myCopy(context, links.join('\n'), 'Скопировано ссылок: ${links.length}'),
              child: const Text('Копировать все'),
            ),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Закрыть')),
        ],
      );
    },
  );
}

void _myCopy(BuildContext context, String text, String message) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
  );
}

/// Один сервер: JSON, ссылка, QR-код.
Future<void> showMyServer(BuildContext context, MyServer server) async {
  final link = myOutboundToLink({...server.json, 'tag': server.name});
  final json = myPrettyJson(server.json);
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
            child: SelectableText(json, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
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
}
