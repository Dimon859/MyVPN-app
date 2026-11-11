// MyVPN: статистика трафика по дням, месяцам и подпискам.
// Ядро присылает сколько всего прошло за текущее подключение; здесь копится разница.
// Трафик, прошедший пока приложение было закрыто, учитывается при следующем открытии.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hiddify/utils/number_formatters.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract final class MyTraffic {
  static const _key = 'myvpn_traffic';
  static Map<String, dynamic> _data = {};
  static bool _loaded = false;
  static bool _loading = false;
  static DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<void> load() async {
    if (_loaded || _loading) return;
    _loading = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw != null) _data = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      _data = {};
    }
    _loaded = true;
    _loading = false;
  }

  static Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode(_data));
    } catch (_) {}
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
  static String dayKey(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}';
  static String monthKey(DateTime t) => '${t.year}-${_two(t.month)}';

  static void _add(String bucket, String key, int up, int down) {
    final b = (_data[bucket] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final cur = (b[key] as List?) ?? const [0, 0];
    b[key] = [(cur[0] as num).toInt() + up, (cur[1] as num).toInt() + down];
    _data[bucket] = b;
  }

  /// Новые значения от ядра: всего отдано и получено за текущее подключение.
  static void feed(int upTotal, int downTotal, String profile) {
    if (!_loaded) {
      unawaited(load());
      return;
    }
    final last = (_data['last'] as List?) ?? const [0, 0];
    final lastUp = (last[0] as num).toInt(), lastDown = (last[1] as num).toInt();
    // меньше прошлого — новое подключение, считаем с нуля
    final dUp = upTotal >= lastUp ? upTotal - lastUp : upTotal;
    final dDown = downTotal >= lastDown ? downTotal - lastDown : downTotal;
    _data['last'] = [upTotal, downTotal];
    if (dUp == 0 && dDown == 0) return;
    final now = DateTime.now();
    _add('days', dayKey(now), dUp, dDown);
    _add('months', monthKey(now), dUp, dDown);
    _add('profiles', '${monthKey(now)}|${profile.isEmpty ? 'Без названия' : profile}', dUp, dDown);
    if (now.difference(_lastSave).inSeconds >= 15) {
      _lastSave = now;
      unawaited(_save());
    }
  }

  static (int, int) _get(String bucket, String key) {
    final v = ((_data[bucket] as Map?)?[key] as List?) ?? const [0, 0];
    return ((v[0] as num).toInt(), (v[1] as num).toInt());
  }

  static Future<void> reset() async {
    final last = _data['last'];
    _data = {'last': ?last};
    await _save();
  }
}

String _fmt((int, int) v) => '↓ ${v.$2.size()}   ↑ ${v.$1.size()}';

Future<void> showMyTraffic(BuildContext context) async {
  await MyTraffic.load();
  if (!context.mounted) return;
  final now = DateTime.now();
  final yesterday = now.subtract(const Duration(days: 1));
  final prevMonth = DateTime(now.year, now.month - 1);
  final month = MyTraffic.monthKey(now);
  final byProfile = <(String, (int, int))>[];
  final profiles = (MyTraffic._data['profiles'] as Map?) ?? const {};
  for (final k in profiles.keys) {
    final key = k.toString();
    if (!key.startsWith('$month|')) continue;
    byProfile.add((key.substring(month.length + 1), MyTraffic._get('profiles', key)));
  }
  byProfile.sort((a, b) => (b.$2.$1 + b.$2.$2).compareTo(a.$2.$1 + a.$2.$2));
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (context) {
      final theme = Theme.of(context);
      Widget row(String title, (int, int) v) => ListTile(
        dense: true,
        title: Text(title),
        subtitle: Text(_fmt(v)),
        trailing: Text((v.$1 + v.$2).size(), style: theme.textTheme.titleSmall),
      );
      return AlertDialog(
        title: const Text('Статистика трафика'),
        contentPadding: const EdgeInsets.only(top: 12),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              row('Сегодня', MyTraffic._get('days', MyTraffic.dayKey(now))),
              row('Вчера', MyTraffic._get('days', MyTraffic.dayKey(yesterday))),
              row('Этот месяц', MyTraffic._get('months', month)),
              row('Прошлый месяц', MyTraffic._get('months', MyTraffic.monthKey(prevMonth))),
              if (byProfile.isNotEmpty) ...[
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text('По подпискам за месяц', style: theme.textTheme.labelLarge),
                ),
                for (final p in byProfile) row(p.$1, p.$2),
              ],
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Считается, пока подключение идёт через Tunnex. Трафик за время, когда приложение было закрыто, добавится при следующем открытии.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await MyTraffic.reset();
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('Сбросить'),
          ),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Закрыть')),
        ],
      );
    },
  );
}
