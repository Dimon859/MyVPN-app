// MyVPN: свой счётчик трафика у каждой подписки — «Потрачено X с даты», свой лимит с полоской, сброс.
// Ядро присылает, сколько всего прошло за подключение; сюда идёт разница, на подписку, через которую шёл трафик.
// Если подключение через «Все подписки» или «Избранное», трафик раскладывается по исходным подпискам.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MyCounter {
  MyCounter({this.up = 0, this.down = 0, DateTime? since, this.limitGb = 0}) : since = since ?? DateTime.now();

  int up, down;
  DateTime since;
  double limitGb; // 0 — без лимита

  int get total => up + down;

  Map<String, dynamic> toJson() => {'u': up, 'd': down, 's': since.millisecondsSinceEpoch, 'l': limitGb};

  static MyCounter fromJson(Map m) => MyCounter(
    up: (m['u'] as num?)?.toInt() ?? 0,
    down: (m['d'] as num?)?.toInt() ?? 0,
    since: DateTime.fromMillisecondsSinceEpoch((m['s'] as num?)?.toInt() ?? 0),
    limitGb: (m['l'] as num?)?.toDouble() ?? 0,
  );
}

String _mySize(num b) {
  if (b < 1024) return '${b.toInt()} Б';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} КБ';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} МБ';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} ГБ';
}

abstract final class MyCounters {
  static const _key = 'myvpn_counters';
  static Map<String, MyCounter> _data = {}; // имя подписки → счётчик
  static bool _loaded = false;
  static int _lastUp = -1, _lastDown = -1;
  static DateTime _saved = DateTime.fromMillisecondsSinceEpoch(0);
  static final changes = ValueNotifier<int>(0);

  /// Для общих профилей: тег сервера → имя исходной подписки (заполняется приложением).
  static Map<String, String> owners = {};

  /// Общие профили, трафик которых раскладывается по исходным подпискам.
  static const combined = {'Все подписки', 'Избранное'};

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw != null) {
        _data = (jsonDecode(raw) as Map).map((k, v) => MapEntry(k.toString(), MyCounter.fromJson(v as Map)));
      }
    } catch (_) {}
    changes.value++;
  }

  static Future<void> _save() async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        _key,
        jsonEncode(_data.map((k, v) => MapEntry(k, v.toJson()))),
      );
    } catch (_) {}
  }

  static MyCounter? of(String name) => _data[name];

  /// Новые значения от ядра (всего за подключение), имя подписки и сервер, через который идёт трафик.
  static void feed(int upTotal, int downTotal, String profile, String outbound) {
    if (!_loaded) {
      unawaited(load());
      return;
    }
    final dUp = _lastUp < 0 ? 0 : (upTotal >= _lastUp ? upTotal - _lastUp : upTotal);
    final dDown = _lastDown < 0 ? 0 : (downTotal >= _lastDown ? downTotal - _lastDown : downTotal);
    _lastUp = upTotal;
    _lastDown = downTotal;
    if (dUp == 0 && dDown == 0) return;
    final names = <String>{if (profile.isNotEmpty) profile};
    if (combined.contains(profile)) {
      final owner = owners[outbound];
      if (owner != null) names.add(owner);
    }
    for (final n in names) {
      final c = _data.putIfAbsent(n, MyCounter.new);
      c.up += dUp;
      c.down += dDown;
    }
    changes.value++;
    if (DateTime.now().difference(_saved).inSeconds >= 15) {
      _saved = DateTime.now();
      unawaited(_save());
    }
  }

  static Future<void> reset(String name) async {
    await load();
    final old = _data[name];
    _data[name] = MyCounter(limitGb: old?.limitGb ?? 0);
    changes.value++;
    await _save();
  }

  static Future<void> setLimit(String name, double gb) async {
    await load();
    _data.putIfAbsent(name, MyCounter.new).limitGb = gb;
    changes.value++;
    await _save();
  }
}

String _two(int v) => v.toString().padLeft(2, '0');

/// Строка счётчика под названием подписки.
class MyCounterLine extends StatelessWidget {
  const MyCounterLine({super.key, required this.name, required this.hasProviderBar});

  final String name;
  final bool hasProviderBar; // у подписки своя полоска от провайдера — свой счётчик мелко

  @override
  Widget build(BuildContext context) {
    unawaited(MyCounters.load());
    final theme = Theme.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: MyCounters.changes,
      builder: (context, _, __) {
        final c = MyCounters.of(name);
        if (c == null || (c.total == 0 && c.limitGb == 0)) return const SizedBox.shrink();
        final style = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
        final text = '${hasProviderBar ? 'С этого телефона' : 'Потрачено'}: ${_mySize(c.total)}'
            '${c.limitGb > 0 ? ' из ${c.limitGb.toStringAsFixed(c.limitGb % 1 == 0 ? 0 : 1)} ГБ' : ''}'
            ' · с ${_two(c.since.day)}.${_two(c.since.month)}';
        final ratio = c.limitGb > 0 ? (c.total / (c.limitGb * 1024 * 1024 * 1024)).clamp(0.0, 1.0) : null;
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (ratio != null && !hasProviderBar)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(3),
                    color: ratio > 0.9 ? theme.colorScheme.error : null,
                  ),
                ),
              Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        );
      },
    );
  }
}

/// Окно счётчика: сколько потрачено, лимит, сброс.
Future<void> showMyCounter(BuildContext context, String name) async {
  await MyCounters.load();
  if (!context.mounted) return;
  final c = MyCounters.of(name);
  final limit = TextEditingController(
    text: (c?.limitGb ?? 0) > 0 ? c!.limitGb.toStringAsFixed(c.limitGb % 1 == 0 ? 0 : 1) : '',
  );
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (context) => AlertDialog(
      title: Text('Трафик: $name'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            c == null
                ? 'Пока ничего не потрачено.'
                : 'Потрачено: ${_mySize(c.total)} (↓ ${_mySize(c.down)} ↑ ${_mySize(c.up)})\n'
                      'Считается с ${_two(c.since.day)}.${_two(c.since.month)}.${c.since.year}',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: limit,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            decoration: const InputDecoration(
              labelText: 'Свой лимит, ГБ',
              helperText: 'Пусто — без лимита и без полоски',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await MyCounters.reset(name);
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('Сбросить счётчик'),
        ),
        TextButton(
          onPressed: () async {
            final v = double.tryParse(limit.text.replaceAll(',', '.').trim()) ?? 0;
            await MyCounters.setLimit(name, v < 0 ? 0 : v);
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('Сохранить'),
        ),
      ],
    ),
  );
}
