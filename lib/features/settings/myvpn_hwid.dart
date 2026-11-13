// MyVPN: смена HWID — общего (Настройки → Общие) и своего у каждой подписки.
// Подписка без своей настройки берёт общий HWID; своя настройка подписки не трогает остальные.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

void _mySay(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));

String _myNewId() => const Uuid().v4().replaceAll('-', '');

bool _myValid(String v) => RegExp(r'^[A-Za-z0-9=_.:-]{4,128}$').hasMatch(v);

/// Общий HWID: показать, скопировать, изменить, новый случайный, вернуть исходный.
Future<void> showMyHwidDialog(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  final current = await DioHttpClient.myHwid();
  final custom = prefs.getString('myvpn_hwid_custom') ?? '';
  final ctrl = TextEditingController(text: current);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (context) => AlertDialog(
      title: const Text('HWID устройства'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            custom.isEmpty ? 'Сейчас: исходный HWID этого телефона' : 'Сейчас: свой HWID (изменён вручную)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: ctrl,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'HWID'),
          ),
          const SizedBox(height: 8),
          Text(
            'Подписки без своей настройки получат этот HWID. Многие подписки с лимитом устройств '
            'посчитают новый HWID новым устройством.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: ctrl.text.trim()));
            if (context.mounted) _mySay(context, 'HWID скопирован');
          },
          child: const Text('Копировать'),
        ),
        TextButton(onPressed: () => ctrl.text = _myNewId(), child: const Text('Новый случайный')),
        TextButton(
          onPressed: () async {
            await prefs.remove('myvpn_hwid_custom');
            DioHttpClient.myHwidReset();
            if (context.mounted) {
              Navigator.of(context).pop();
              _mySay(context, 'Вернул исходный HWID: ${await DioHttpClient.myHwid()}');
            }
          },
          child: const Text('Вернуть исходный'),
        ),
        FilledButton(
          onPressed: () async {
            final v = ctrl.text.trim();
            if (!_myValid(v)) {
              _mySay(context, 'HWID: только латиница, цифры и - _ . : =, от 4 символов');
              return;
            }
            final original = prefs.getString('myvpn_hwid') ?? '';
            if (v == original) {
              await prefs.remove('myvpn_hwid_custom');
            } else {
              await prefs.setString('myvpn_hwid_custom', v);
            }
            DioHttpClient.myHwidReset();
            if (context.mounted) {
              Navigator.of(context).pop();
              _mySay(context, 'HWID сохранён. Обновите подписки, чтобы они его получили');
            }
          },
          child: const Text('Сохранить'),
        ),
      ],
    ),
  );
}

Future<Map<String, dynamic>> _myBySub(SharedPreferences prefs) async {
  try {
    final m = jsonDecode(prefs.getString('myvpn_hwid_by_sub') ?? '{}');
    if (m is Map) return m.cast<String, dynamic>();
  } catch (_) {}
  return {};
}

/// HWID для одной подписки: как в общих настройках / устройства / не отправлять / свой.
Future<void> showMySubHwid(BuildContext context, ProfileEntity profile) async {
  if (profile is! RemoteProfileEntity) {
    _mySay(context, 'HWID нужен только подпискам по ссылке');
    return;
  }
  final prefs = await SharedPreferences.getInstance();
  final key = DioHttpClient.myHwidKey(profile.url);
  final by = await _myBySub(prefs);
  final cur = by[key] as String?;
  var mode = cur == null ? 'global' : (cur == '' ? 'hide' : (cur == 'device' ? 'device' : 'custom'));
  final ctrl = TextEditingController(text: mode == 'custom' ? cur : await DioHttpClient.myHwid());
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('HWID: ${profile.name}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in const {
                'global': 'Как в общих настройках',
                'device': 'Отправлять HWID устройства',
                'hide': 'Не отправлять (скрыть)',
                'custom': 'Свой HWID для этой подписки',
              }.entries)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(mode == e.key ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded),
                  title: Text(e.value),
                  onTap: () => setState(() => mode = e.key),
                ),
              if (mode == 'custom') ...[
                TextField(
                  controller: ctrl,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    isDense: true,
                    labelText: 'HWID',
                    suffixIcon: IconButton(
                      tooltip: 'Новый случайный',
                      icon: const Icon(Icons.casino_outlined),
                      onPressed: () => setState(() => ctrl.text = _myNewId()),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Например, тот же HWID, что у этой подписки в Happ — тогда она не займёт ещё одно устройство.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
          FilledButton(
            onPressed: () async {
              final v = ctrl.text.trim();
              if (mode == 'custom' && !_myValid(v)) {
                _mySay(context, 'HWID: только латиница, цифры и - _ . : =, от 4 символов');
                return;
              }
              final m = await _myBySub(prefs);
              switch (mode) {
                case 'global':
                  m.remove(key);
                case 'device':
                  m[key] = 'device';
                case 'hide':
                  m[key] = '';
                default:
                  m[key] = v;
              }
              await prefs.setString('myvpn_hwid_by_sub', jsonEncode(m));
              if (context.mounted) {
                Navigator.of(context).pop();
                _mySay(context, 'Сохранено. Обновите подписку, чтобы применить');
              }
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    ),
  );
}
