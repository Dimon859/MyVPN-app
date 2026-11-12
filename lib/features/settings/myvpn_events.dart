// MyVPN: журнал событий — что происходило, пока ты не смотрел.
// Переключения сервера, белые списки, запасные подписки, детекторы, обновления подписок, включение и выключение VPN.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract final class MyEvents {
  static const _key = 'myvpn_events';
  static const _max = 300;
  static List<(DateTime, String)> items = [];
  static bool _loaded = false;
  static final changes = ValueNotifier<int>(0);

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getStringList(_key) ?? const [];
      items = [
        for (final r in raw)
          if (r.indexOf('|') case final i when i > 0)
            (DateTime.fromMillisecondsSinceEpoch(int.tryParse(r.substring(0, i)) ?? 0), r.substring(i + 1)),
      ];
    } catch (_) {}
  }

  /// Записать событие. Одинаковые подряд в течение минуты не повторяются.
  static Future<void> add(String text) async {
    await load();
    final now = DateTime.now();
    if (items.isNotEmpty && items.last.$2 == text && now.difference(items.last.$1).inMinutes < 1) return;
    items.add((now, text));
    if (items.length > _max) items = items.sublist(items.length - _max);
    changes.value++;
    try {
      await (await SharedPreferences.getInstance()).setStringList(
        _key,
        [for (final e in items) '${e.$1.millisecondsSinceEpoch}|${e.$2}'],
      );
    } catch (_) {}
  }

  static Future<void> clear() async {
    items = [];
    changes.value++;
    try {
      await (await SharedPreferences.getInstance()).remove(_key);
    } catch (_) {}
  }
}

/// Не ждать запись события.
void myEvent(String text) => unawaited(MyEvents.add(text));

String _two(int v) => v.toString().padLeft(2, '0');

String myEventTime(DateTime t) {
  final now = DateTime.now();
  final hm = '${_two(t.hour)}:${_two(t.minute)}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) return hm;
  return '${_two(t.day)}.${_two(t.month)} $hm';
}

Future<void> showMyEvents(BuildContext context) async {
  await MyEvents.load();
  if (!context.mounted) return;
  await Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(builder: (_) => const _MyEventsPage()),
  );
}

class _MyEventsPage extends StatelessWidget {
  const _MyEventsPage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: MyEvents.changes,
      builder: (context, _, __) {
        final list = MyEvents.items.reversed.toList();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Журнал событий'),
            actions: [
              IconButton(
                tooltip: 'Копировать',
                icon: const Icon(Icons.copy_rounded),
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: [for (final e in list) '${myEventTime(e.$1)}  ${e.$2}'].join('\n')),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Журнал скопирован')));
                  }
                },
              ),
              IconButton(
                tooltip: 'Очистить',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: MyEvents.clear,
              ),
            ],
          ),
          body: list.isEmpty
              ? const Center(child: Text('Пока ничего не происходило'))
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) => ListTile(
                    dense: true,
                    leading: Text(myEventTime(list[i].$1), style: theme.textTheme.bodySmall),
                    title: Text(list[i].$2),
                  ),
                ),
        );
      },
    );
  }
}
