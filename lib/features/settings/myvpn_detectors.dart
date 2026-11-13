// MyVPN: детекторы.
// • подмена сертификатов у сервера (⚠️) и «заморозка после 16 КБ» (🧊) — для текущего сервера, сам после подключения;
// • сервер тормозит — пинг сильно выше обычного для этого сервера;
// • смена IP выхода у сервера в процессе работы;
// • утечки (IP, DNS, IPv6) и подмена DNS провайдером — по кнопке;
// • какие протоколы живы на этой сети и самый быстрый DNS.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hiddify/features/connections/myvpn_connections.dart' show myIpProvider;
import 'package:hiddify/features/profile/data/myvpn_marks.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/widget/myvpn_profile_extras.dart';
import 'package:hiddify/features/settings/myvpn_events.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart' hide IpInfo;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------- общее ----------

Future<String?> _myGet(String url, {Duration timeout = const Duration(seconds: 8), Map<String, String>? headers}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final req = await client.getUrl(Uri.parse(url));
    headers?.forEach(req.headers.set);
    final resp = await req.close().timeout(timeout);
    if (resp.statusCode != 200) {
      await resp.drain<void>();
      return null;
    }
    return await resp.transform(utf8.decoder).join().timeout(timeout);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Сервер профиля по тегу (из файла профиля).
Future<MyServer?> myServerOfTag(WidgetRef ref, ProfileEntity profile, String tag) async {
  try {
    final file = ref.read(profilePathResolverProvider).file(profile.id);
    if (!await file.exists()) return null;
    return myServersFromText(await file.readAsString(), profileId: profile.id).where((s) => s.tag == tag).firstOrNull;
  } catch (_) {
    return null;
  }
}

/// Пометить сервер детектором: он уходит из автовыбора, VPN переподключается.
Future<void> myMarkBad(WidgetRef ref, MyServer server, String reason) async {
  await MyMarks.load();
  if (MyMarks.bad[server.key] == reason) return;
  MyMarks.bad[server.key] = reason;
  myEvent('$reason: ${server.name}');
  myReconnectReason('сервер исключён детектором');
  await myApplyMarks(ref);
  final active = await ref.read(activeProfileProvider.future);
  if (active != null) await myConnectTo(ref, active, reload: true);
}

// ---------- подмена сертификатов ----------

const _myTlsHosts = ['www.google.com', 'www.cloudflare.com', 'www.apple.com', 'github.com', 'www.microsoft.com'];

/// true — сервер подменяет сертификаты известных сайтов; false — всё честно; null — проверить не вышло.
Future<bool?> myCheckMitm() async {
  var ok = 0, bad = 0;
  await Future.wait([
    for (final host in _myTlsHosts)
      () async {
        try {
          final s = await SecureSocket.connect(host, 443, timeout: const Duration(seconds: 8));
          ok++;
          s.destroy();
        } on HandshakeException catch (e) {
          if (e.toString().toUpperCase().contains('CERTIFICATE')) bad++;
        } catch (_) {}
      }(),
  ]);
  if (bad >= 2 && bad > ok) return true;
  if (ok >= 2) return false;
  return null;
}

// ---------- заморозка после 16 КБ ----------

/// true — соединение замирает после первых ~16 КБ; false — данные идут; null — проверить не вышло.
Future<bool?> myCheckFreeze() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  var got = 0;
  try {
    final req = await client.getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=131072'));
    final resp = await req.close().timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) return null;
    await for (final chunk in resp.timeout(const Duration(seconds: 6))) {
      got += chunk.length;
      if (got >= 100000) return false;
    }
    return got >= 100000 ? false : null;
  } on TimeoutException {
    // встало посреди: классическая «заморозка» — пришло немного и тишина
    if (got >= 4000 && got <= 40000) return true;
    return null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

// ---------- сервер тормозит ----------

/// Обычный пинг каждого сервера (скользящее среднее).
abstract final class MySlow {
  static Map<String, List<num>> _avg = {}; // ключ → [среднее, число замеров]
  static bool _loaded = false;
  static DateTime _saved = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = (await SharedPreferences.getInstance()).getString('myvpn_slow');
      if (raw != null) {
        _avg = (jsonDecode(raw) as Map).map((k, v) => MapEntry(k.toString(), [for (final x in v as List) x as num]));
      }
    } catch (_) {}
  }

  /// Новый пинг сервера. Возвращает обычный пинг (до учёта нового) или null, если замеров мало.
  static int? observe(String tag, int delay) {
    if (!_loaded || delay <= 0 || delay >= 65000) return null;
    final cur = _avg[tag];
    int? typical;
    if (cur == null) {
      _avg[tag] = [delay, 1];
    } else {
      final avg = cur[0].toDouble(), n = cur[1].toInt();
      if (n >= 5) typical = avg.round();
      // всплески учитываются слабо, чтобы «обычный» пинг не уплывал от одного торможения
      final w = delay > avg * 2 ? 0.05 : 0.2;
      _avg[tag] = [avg * (1 - w) + delay * w, math.min(n + 1, 1000)];
    }
    if (DateTime.now().difference(_saved).inMinutes >= 2) {
      _saved = DateTime.now();
      unawaited(SharedPreferences.getInstance().then((p) => p.setString('myvpn_slow', jsonEncode(_avg))));
    }
    return typical;
  }

  static bool isSlow(int delay, int? typical) => typical != null && delay > math.max(typical * 3, typical + 400);
}

// ---------- IP выхода ----------

Future<String?> myExitIp() async => (await _myGet('https://api.ipify.org'))?.trim();

// ---------- утечки ----------

class MyLeakResult {
  String? realIp, realOrg, vpnIp, vpnOrg, ipv6, ipv6Org;
  List<String> dns = [];
  bool dnsChecked = false;
  bool get ipLeak => realIp != null && vpnIp != null && realIp == vpnIp;
}

/// Проверка утечек: настоящий IP (через российский сайт, он идёт напрямую), IP через VPN, IPv6 и DNS-серверы.
Future<MyLeakResult> myLeakTest() async {
  final r = MyLeakResult();
  await Future.wait<void>([
    () async {
      final t = await _myGet('https://yandex.ru/internet/api/v0/ip');
      r.realIp = t?.replaceAll('"', '').trim();
    }(),
    () async {
      r.vpnIp = await myExitIp();
    }(),
    () async {
      r.ipv6 = (await _myGet('https://api6.ipify.org', timeout: const Duration(seconds: 5)))?.trim();
    }(),
    () async {
      // DNS: bash.ws видит, какие DNS-серверы спрашивали случайные имена
      final id = (await _myGet('https://bash.ws/id'))?.trim();
      if (id == null || id.isEmpty) return;
      await Future.wait([
        for (var i = 1; i <= 6; i++)
          InternetAddress.lookup('$i.$id.bash.ws').timeout(const Duration(seconds: 4)).catchError((_) => <InternetAddress>[]),
      ]);
      final res = await _myGet('https://bash.ws/dnsleak/test/$id?json');
      if (res == null) return;
      r.dnsChecked = true;
      for (final e in (jsonDecode(res) as List)) {
        final m = e as Map;
        if (m['type'] != 'dns') continue;
        r.dns.add([
          m['ip'],
          if ((m['country_name'] ?? '').toString().isNotEmpty) m['country_name'],
          if ((m['asn'] ?? '').toString().isNotEmpty) m['asn'],
        ].join(' · '));
      }
    }(),
  ]);
  final orgs = await Future.wait([
    myIpProvider(r.realIp ?? ''),
    myIpProvider(r.vpnIp ?? ''),
    myIpProvider(r.ipv6 ?? ''),
  ]);
  r.realOrg = orgs[0];
  r.vpnOrg = orgs[1];
  r.ipv6Org = orgs[2];
  return r;
}

Future<void> showMyLeakTest(BuildContext context) async {
  final future = myLeakTest();
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (context) => AlertDialog(
      title: const Text('Проверка утечек'),
      content: FutureBuilder<MyLeakResult>(
        future: future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()));
          }
          final r = snap.data!;
          final ipv6Leak = r.ipv6 != null && r.realOrg != null && r.ipv6Org != null && r.ipv6Org == r.realOrg;
          final lines = <String>[
            if (r.vpnIp == null) '❓ IP через VPN узнать не удалось',
            if (r.vpnIp != null) (r.ipLeak ? '❌ Сайты видят твой настоящий IP: ${r.vpnIp}' : '✅ Сайты видят IP сервера: ${r.vpnIp}${r.vpnOrg == null ? '' : '\n    ${r.vpnOrg}'}'),
            if (r.realIp != null) '   Твой настоящий IP: ${r.realIp}${r.realOrg == null ? '' : ' (${r.realOrg})'}',
            if (r.ipv6 == null) '✅ IPv6 не утекает (нет соединения по IPv6)',
            if (r.ipv6 != null) (ipv6Leak ? '❌ IPv6 идёт мимо VPN: ${r.ipv6}' : '✅ IPv6: ${r.ipv6}${r.ipv6Org == null ? '' : ' (${r.ipv6Org})'}'),
            if (!r.dnsChecked) '❓ DNS проверить не удалось',
            if (r.dnsChecked) 'DNS-серверы, которые видят сайты:',
            for (final d in r.dns) '   • $d',
          ];
          return SingleChildScrollView(child: SelectableText(lines.join('\n')));
        },
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Закрыть'))],
    ),
  );
}

// ---------- подмена DNS провайдером ----------

bool _myStubIp(InternetAddress a) {
  if (a.isLoopback || a.isLinkLocal) return true;
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    if (b[0] == 0 || b[0] == 10 || b[0] == 127) return true;
    if (b[0] == 192 && b[1] == 168) return true;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
  }
  return false;
}

Future<List<String>> _myDoh(String name) async {
  final t = await _myGet(
    'https://1.1.1.1/dns-query?name=$name&type=A',
    headers: {'accept': 'application/dns-json'},
  );
  if (t == null) return const [];
  final ans = (jsonDecode(t) as Map)['Answer'] as List?;
  return [for (final a in ans ?? const []) if ((a as Map)['type'] == 1) a['data'].toString()];
}

/// Проверка подмены DNS: сравнение ответа сети с защищённым DNS. Возвращает строки отчёта.
Future<List<String>> myDnsHijackCheck() async {
  const names = ['rutracker.org', 'www.linkedin.com', 'www.wikipedia.org', 'www.google.com'];
  final out = <String>[];
  var hijack = 0, checked = 0;
  for (final n in names) {
    List<InternetAddress> sys;
    try {
      sys = await InternetAddress.lookup(n, type: InternetAddressType.IPv4).timeout(const Duration(seconds: 5));
    } catch (_) {
      sys = const [];
    }
    final doh = await _myDoh(n);
    if (doh.isEmpty) continue;
    checked++;
    if (sys.isEmpty) {
      hijack++;
      out.add('❌ $n: сеть говорит, что сайта нет');
    } else if (sys.every(_myStubIp)) {
      hijack++;
      out.add('❌ $n: сеть подставляет заглушку ${sys.first.address}');
    } else {
      out.add('✅ $n');
    }
  }
  if (checked == 0) return ['❓ Защищённый DNS не ответил — проверить не вышло'];
  out.insert(0, hijack == 0 ? 'DNS этой сети ничего не подменяет' : 'Сеть подменяет DNS у $hijack сайтов');
  return out;
}

// ---------- протоколы на этой сети ----------

/// Живые серверы по протоколам по последней проверке пинга: протокол → (живых, всего).
Map<String, (int, int)> myProtoStats(OutboundGroupList? list, Map<String, String> typeOfTag) {
  final out = <String, (int, int)>{};
  final group = list?.items.firstOrNull;
  if (group == null) return out;
  for (final o in group.items) {
    if (o.isGroup) continue;
    final proto = typeOfTag[o.tag];
    if (proto == null) continue;
    final alive = o.urlTestDelay > 0 && o.urlTestDelay < 65000;
    final cur = out[proto] ?? (0, 0);
    out[proto] = (cur.$1 + (alive ? 1 : 0), cur.$2 + 1);
  }
  return out;
}

/// Протокол каждого сервера активного профиля: тег → протокол.
Future<Map<String, String>> myProtoOfTags(WidgetRef ref) async {
  final active = await ref.read(activeProfileProvider.future);
  if (active == null) return const {};
  try {
    final file = ref.read(profilePathResolverProvider).file(active.id);
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return {
      for (final key in const ['outbounds', 'endpoints'])
        for (final o in (json[key] as List? ?? const []))
          if (o is Map<String, dynamic>) (o['tag'] ?? '').toString(): myProtoOf(o),
    };
  } catch (_) {
    return const {};
  }
}

// ---------- самый быстрый DNS ----------

String _myDnsQuery() {
  // запрос A для example.com в формате DNS (RFC 8484, GET ?dns=)
  final b = <int>[0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0];
  for (final part in ['example', 'com']) {
    b.add(part.length);
    b.addAll(part.codeUnits);
  }
  b.addAll([0, 0, 1, 0, 1]);
  return base64Url.encode(b).replaceAll('=', '');
}

/// Время ответа DoH-сервера (лучшее из трёх), мс; null — не отвечает.
Future<int?> myDnsLatency(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  final q = _myDnsQuery();
  int? best;
  try {
    for (var i = 0; i < 3; i++) {
      final sw = Stopwatch()..start();
      try {
        final req = await client.getUrl(Uri.parse('$url?dns=$q'));
        req.headers.set('accept', 'application/dns-message');
        final resp = await req.close().timeout(const Duration(seconds: 4));
        await resp.drain<void>();
        if (resp.statusCode != 200) continue;
        final ms = sw.elapsedMilliseconds;
        if (best == null || ms < best) best = ms;
      } catch (_) {}
    }
  } finally {
    client.close(force: true);
  }
  return best;
}

/// Замер всех вариантов: название → мс (null — не отвечает).
Future<Map<String, int?>> myMeasureDns(Map<String, String> presets) async {
  final res = await Future.wait([for (final e in presets.entries) myDnsLatency(e.value)]);
  return {for (var i = 0; i < presets.length; i++) presets.keys.elementAt(i): res[i]};
}
