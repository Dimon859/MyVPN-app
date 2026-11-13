#!/usr/bin/env bash
# MyVPN: замена всего видимого «Hiddify» при сборке (код форка остаётся как у оригинала)
set -euo pipefail
APPNAME="${APPNAME:-Tunnex}"
REPO_URL="${REPO_URL:-https://github.com/Dimon859/MyVPN-app}"

python3 - "$APPNAME" "$REPO_URL" <<'PY'
import sys, re, glob
app, repo = sys.argv[1], sys.argv[2]
api = repo.replace("https://github.com/", "https://api.github.com/repos/") + "/releases"

def edit(path, fn):
    s = open(path, encoding="utf-8").read()
    s2 = fn(s)
    open(path, "w", encoding="utf-8").write(s2)
    print("✅", path)

# 1. Название и ссылки (обновления смотрят в твой репозиторий)
def consts(s):
    s, n = re.subn(r'static const appName = "[^"]*";', f'static const appName = "{app}";', s)
    assert n == 1, "appName"
    for k, v in {"githubUrl": repo, "licenseUrl": repo, "githubReleasesApiUrl": api,
                 "githubLatestReleaseUrl": repo + "/releases/latest", "telegramChannelUrl": repo,
                 "privacyPolicyUrl": repo, "termsAndConditionsUrl": repo}.items():
        s, n = re.subn(rf'static const {k} = "[^"]*";', f'static const {k} = "{v}";', s)
        assert n == 1, k
    return s
edit("lib/core/model/constants.dart", consts)

# 2. «О программе»: убрать Telegram, условия и политику конфиденциальности
def about(s):
    for key in ["telegramChannel", "termsAndConditions", "privacyPolicy"]:
        s, n = re.subn(r"\n\s*ListTile\(\s*title: Text\(t\.pages\.about\." + key + r"\),.*?\n\s*\),(?=\n)",
                       "", s, count=1, flags=re.S)
        assert n == 1, key
    return s
edit("lib/features/about/widget/about_page.dart", about)

# 2б. Дополнить русский перевод недостающими строками (файл ru_extra.json)
import json, os
if os.path.exists("ru_extra.json"):
    extra = json.load(open("ru_extra.json", encoding="utf-8"))
    rp = "assets/translations/ru.i18n.json"
    ru = json.load(open(rp, encoding="utf-8"))
    added = 0
    for path, val in extra.items():
        node = ru
        *parts, last = path.split(".")
        for p in parts:
            node = node.setdefault(p, {})
        if node.get(last) != val:
            node[last] = val
            added += 1
    json.dump(ru, open(rp, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("✅ русский перевод: добавлено и исправлено строк:", added)

# 3. Тексты интерфейса на всех языках
for f in sorted(glob.glob("assets/translations/*.i18n.json")):
    edit(f, lambda s: s.replace("Hiddify", app).replace("https://hiddify.com/manager/", repo))

# 4. Имя VPN в Настройки → VPN (iOS) и подпись на Android
edit("ios/Runner/VPN/VPNManager.swift",
     lambda s: s.replace('localizedDescription = "Hiddify"', f'localizedDescription = "{app}"'))
edit("android/app/src/main/AndroidManifest.xml",
     lambda s: s.replace('android:label="Hiddify"', f'android:label="{app}"'))

# 5. Логотип внутри приложения (QR-окно и т. п.)
open("assets/images/logo.svg", "w").write(
    '<svg width="64" height="64" viewBox="18 16 64 64" fill="none" xmlns="http://www.w3.org/2000/svg">\n'
    '<path d="M18 78 V50 A32 32 0 0 1 82 50 V78 H70 V50 A20 20 0 0 0 30 50 V78 Z '
    'M38 78 V52 A12 12 0 0 1 62 52 V78 H54 V53 A4 4 0 0 0 46 53 V78 Z" fill="#22D3EE"/>\n</svg>\n')
print("✅ assets/images/logo.svg")

# 6. Кнопка подключения: туннель вместо анимированного «Hi»
LOGO = """abstract final class _HiLogo {
  // MyVPN: туннель (64 × 64) из двух целых арок: внутренняя (части 0–1) и внешняя (часть 2)
  static final h = _svgPath('__INNER__');
  static final stem = _svgPath('__OUTER__');
  static final dot = Path();

  static final all = Path.combine(PathOperation.union, h, stem);

  static Path pathOf(int part) => part < 2 ? h : (part == 2 ? stem : dot);

  // часть 1 пустая, чтобы внутренняя арка не рисовалась дважды
  static Rect clipOf(int part) => switch (part) {
    1 => Rect.zero,
    _ => const Rect.fromLTRB(-2, -2, 66, 66),
  };

  static const tops = [24.0, 24.0, 2.0, 2.0];
  static const bottoms = [62.0, 62.0, 62.0, 62.0];
  static const centersX = [32.0, 32.0, 32.0, 32.0];

  static const bar = [0, 0, 2, 2];

  // сначала внутренняя арка, потом внешняя: волна изнутри наружу
  static const rank = [0.0, 0.0, 1.0, 1.6];
}""".replace("__OUTER__", 'M0 62V34C0 16.326 14.326 2 32 2C49.674 2 64 16.326 64 34V62H52V34C52 22.954 43.046 14 32 14C20.954 14 12 22.954 12 34V62Z').replace("__INNER__", 'M20 62V36C20 29.372 25.372 24 32 24C38.628 24 44 29.372 44 36V62H36V37C36 34.791 34.209 33 32 33C29.791 33 28 34.791 28 37V62Z')
def button(s):
    s, n = re.subn(r"abstract final class _HiLogo \{.*?static const rank = \[[^\]]*\];\n\}", lambda m: LOGO, s, count=1, flags=re.S)
    assert n == 1, "_HiLogo"
    return s
edit("lib/features/home/widget/eclipse_button_painter.dart", button)

# 7. Приветственный экран: убрать условия, политику и «Сделано с ...»
def intro(s):
    s, n = re.subn(r"(const Gap\(24\),)\s*Focus\(\s*focusNode: focusNodes\[IntroConst\.termsAndConditionsKey\].*?(\n\s*// only for managing license node focus)",
                   r"\1\2", s, count=1, flags=re.S)
    assert n == 1, "intro"
    return s
edit("lib/features/intro/widget/intro_page.dart", intro)

# 9. Мои настройки по умолчанию (после установки ничего не надо выставлять заново)
def defaults(s):
    for a, b in [
        ('"balancer-strategy",\n    BalancerStrategy.roundRobin,', '"balancer-strategy",\n    BalancerStrategy.consistentHash,'),
        ('"default-proxy",\n    DefaultProxy.balance,', '"default-proxy",\n    DefaultProxy.lowest,'),
        ('"region",\n    Region.other,', '"region",\n    Region.ru,'),
        ('create<bool, bool>("resolve-destination", false)', 'create<bool, bool>("resolve-destination", true)'),
        ('defaultValueFunction: (ref) => ref.read(region) == Region.cn ? "223.5.5.5" : "1.1.1.1",',
         'defaultValueFunction: (ref) => ref.read(region) == Region.cn ? "223.5.5.5" : (ref.read(region) == Region.ru ? "77.88.8.8" : "1.1.1.1"),'),
    ]:
        assert s.count(a) == 1, a[:40]
        s = s.replace(a, b)
    return s
edit("lib/features/settings/data/config_option_repository.dart", defaults)
def rules(s):
    assert s.count("systemDirect(enabledByDefault: false)") == 1, "systemDirect"
    return s.replace("systemDirect(enabledByDefault: false)", "systemDirect(enabledByDefault: true)")
edit("lib/features/route_rules/notifier/rules_notifier.dart", rules)

# 10. Цвета (вариант 3): тёмная кнопка, голубой туннель, зелёный при подключении
def recolor(path, pairs):
    def fn(s):
        for a, b, n in pairs:
            assert s.count(a) == n, f"{path}: {a[:50]} ({s.count(a)})"
            s = s.replace(a, b)
        return s
    edit(path, fn)
recolor("lib/core/theme/theme_extensions.dart", [
    ("idleColor: Color(0xFF4a4d8b)", "idleColor: Color(0xFF22D3EE)", 1),
    ("connectedColor: Color(0xFF44a334)", "connectedColor: Color(0xFF34D399)", 1),
])
recolor("lib/core/theme/app_theme.dart", [
    ("seedColor: const Color(0xFF293CA0)", "seedColor: const Color(0xFF22D3EE)", 2),
])
recolor("lib/features/home/widget/connection_button.dart", [
    ("const Color(0xFF455FE9)", "const Color(0xFF22D3EE)", 2),
])
recolor("lib/features/home/widget/eclipse_button_painter.dart", [
    ("canvas.drawCircle(center, r, Paint()..color = Colors.white);", "canvas.drawCircle(center, r, Paint()..color = const Color(0xFF1E293B));", 1),
    ("..color = Colors.white.withValues(alpha: .8)\n      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5)",
     "..color = Colors.white.withValues(alpha: .12)\n      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5)", 1),
    ("x.logoSpace((c) => c.drawPaint(Paint()..color = Colors.white))", "x.logoSpace((c) => c.drawPaint(Paint()..color = const Color(0xFF1E293B)))", 1),
    ("final downColor = x.p.dark ? const Color(0xFFFFB020) : const Color(0xFFF59E0B);", "final downColor = x.p.dark ? const Color(0xFF34D399) : const Color(0xFF10B981);", 1),
    ("final upColor = x.p.dark ? const Color(0xFF3F7BFF) : const Color(0xFF2563EB);", "final upColor = x.p.dark ? const Color(0xFF22D3EE) : const Color(0xFF06B6D4);", 1),
])

# 11. Интервал проверки серверов: 30 минут по умолчанию и надпись по-русски
def interval_default(s):
    a = '"url-test-interval",\n    const Duration(minutes: 10),'
    assert s.count(a) == 1, "url-test-interval"
    return s.replace(a, '"url-test-interval",\n    const Duration(minutes: 30),')
edit("lib/features/settings/data/config_option_repository.dart", interval_default)
RU_MIN = """

// MyVPN: «30 минут» вместо английского «30 minutes»
String _ruMinutes(Duration d) {
  final m = d.inMinutes;
  final a = m % 10, b = m % 100;
  final w = (a == 1 && b != 11) ? 'минута' : (a >= 2 && a <= 4 && (b < 12 || b > 14)) ? 'минуты' : 'минут';
  return '$m $w';
}
"""
def interval_text(s):
    s, n1 = re.subn(r"ref\.watch\(ConfigOptions\.urlTestInterval\)\.toApproximateTime\(isRelativeToNow: false\)",
                    "_ruMinutes(ref.watch(ConfigOptions.urlTestInterval))", s)
    s, n2 = re.subn(r"Duration\(minutes: value\.toInt\(\)\)\.toApproximateTime\(isRelativeToNow: false\)",
                    "_ruMinutes(Duration(minutes: value.toInt()))", s)
    assert n1 == 1 and n2 == 1, f"interval text {n1} {n2}"
    if "toApproximateTime" not in s:
        s = s.replace("import 'package:humanizer/humanizer.dart';\n", "")
    return s.rstrip("\n") + RU_MIN
edit("lib/features/settings/overview/sections/general_page.dart", interval_text)

# 12. Окно «Добавить профиль»: вместо «Бесплатно» и «Справка» — выбор HWID для новой подписки
def addprofile(s):
    for a, b in [
        ("              const NavBar(),\n", "              const MyHwidNextRow(),\n              const Gap(12),\n"),
        ("AddProfileModalConst.navBarHeight + 32;", "60 + 32;"),
        ("import 'package:hiddify/features/profile/notifier/profile_notifier.dart';\n",
         "import 'package:hiddify/features/profile/notifier/profile_notifier.dart';\nimport 'package:hiddify/features/settings/myvpn_hwid.dart';\n"),
    ]:
        assert s.count(a) == 1, a.strip()
        s = s.replace(a, b)
    return s
edit("lib/features/profile/add/add_profile_modal.dart", addprofile)

# 13. Главный экран: убрать вкладку «Быстрые настройки» (всё это есть в обычных настройках)
def no_quick(s):
    s, n = re.subn(r"\n\s*Material\(\n\s*color: theme\.colorScheme\.primaryContainer,(?:(?!\n\s*Material\().)*?showQuickSettings\(\).*?\n                      \),(?=\n                    \],)",
                   "", s, count=1, flags=re.S)
    assert n == 1, "quickSettings"
    return s
edit("lib/features/home/widget/home_page.dart", no_quick)

# 14. Аналитика (отчёты о сбоях разработчикам Hiddify): выключена всегда, пункт убран
def no_analytics(s):
    for a, b in [
        ("return preferences.getBool(enableAnalyticsPrefKey) ?? false;", "return false; // MyVPN: аналитика выключена всегда"),
        ("Future<void> enableAnalytics() async {\n", "Future<void> enableAnalytics() async {\n    return; // MyVPN: аналитика выключена всегда\n"),
    ]:
        assert s.count(a) == 1, a[:40]
        s = s.replace(a, b)
    return s
edit("lib/core/analytics/analytics_controller.dart", no_analytics)
for f in ["lib/features/settings/overview/sections/general_page.dart", "lib/features/intro/widget/intro_page.dart"]:
    def drop_tile(s):
        s, n = re.subn(r"\n[ \t]*const EnableAnalyticsPrefTile\(\),", "", s)
        assert n == 1, "EnableAnalyticsPrefTile"
        return s
    edit(f, drop_tile)

# 15. Выбор User-Agent для загрузки подписок (Настройки → Общие)
def ua_pref(s):
    a = 'static final lastSeenCrashReport = PreferencesNotifier.create<String, String>("last_seen_crash_report", "");\n'
    assert s.count(a) == 1, "lastSeenCrashReport"
    return s.replace(a, a + '\n  /// MyVPN: User-Agent для загрузки подписок, пусто = стандартный\n'
                     '  static final subscriptionUserAgent = PreferencesNotifier.create<String, String>("myvpn_sub_user_agent", "");\n')
edit("lib/core/preferences/general_preferences.dart", ua_pref)
def ua_client(s):
    for a, b in [
        ("import 'package:hiddify/core/http_client/dio_http_client.dart';\n",
         "import 'package:hiddify/core/http_client/dio_http_client.dart';\nimport 'package:hiddify/core/preferences/general_preferences.dart';\n"),
        ("  ref.listen(ConfigOptions.mixedPort,",
         "  // MyVPN: свой User-Agent для подписок, если выбран в настройках\n"
         "  final defaultUserAgent = client.userAgent;\n"
         "  void setUserAgent() {\n"
         "    final ua = ref.read(Preferences.subscriptionUserAgent);\n"
         "    client.userAgent = ua.trim().isEmpty ? defaultUserAgent : ua;\n"
         "  }\n"
         "  ref.listen(Preferences.subscriptionUserAgent, (_, _) => setUserAgent());\n"
         "  setUserAgent();\n\n"
         "  ref.listen(ConfigOptions.mixedPort,"),
    ]:
        assert s.count(a) == 1, a[:50]
        s = s.replace(a, b)
    return s
edit("lib/core/http_client/http_client_provider.dart", ua_client)
UA_LIST = """

// MyVPN: варианты User-Agent для подписок (значение → подпись)
// Панель подписки по User-Agent решает, в каком формате отдать список серверов.
const _myUserAgents = {
  '': 'Стандартный',
  'Happ/3.5.0': 'Happ',
  'INCY/2.4.0': 'Incy',
  'Shadowrocket/2.2.65 CFNetwork/3826.500.131 Darwin/24.5.0': 'Shadowrocket',
  'Streisand/1.6.40': 'Streisand',
  'v2RayTun/5.10.62': 'v2RayTun',
  'V2Box/1.5.0': 'V2Box',
  'FoXray/1.9.0': 'FoXray',
  'Karing/1.1.2': 'Karing',
  'v2rayNG/1.10.5': 'v2rayNG',
  'sing-box 1.12.0': 'sing-box (JSON)',
  'clash.meta': 'Clash Meta (YAML)',
  'Stash/2.4.0 Clash/1.9.0': 'Stash',
};
"""
def ua_tile(s):
    a = "onChanged: ref.read(Preferences.autoCheckIp.notifier).update,\n          ),\n"
    assert s.count(a) == 1, "autoCheckIp tile"
    s = s.replace(a, a +
        "          ChoicePreferenceWidget<String>(\n"
        "            selected: ref.watch(Preferences.subscriptionUserAgent),\n"
        "            preferences: ref.watch(Preferences.subscriptionUserAgent.notifier),\n"
        "            choices: _myUserAgents.keys.toList(),\n"
        "            title: 'User-Agent подписок',\n"
        "            icon: Icons.badge_rounded,\n"
        "            presentChoice: (value) => _myUserAgents[value] ?? value,\n"
        "          ),\n")
    return s.rstrip("\n") + UA_LIST
edit("lib/features/settings/overview/sections/general_page.dart", ua_tile)

# 16. Независимость от чужих репозиториев
# 16а. Флажки стран — из своей копии third_party/circle_flags
def flags(s):
    a = "  circle_flags:\n    git: https://github.com/hiddify-com/flutter_circle_flags.git\n"
    assert s.count(a) == 1, "circle_flags git"
    return s.replace(a, "  circle_flags:\n    path: third_party/circle_flags\n")
import os
assert os.path.exists("third_party/circle_flags/pubspec.yaml"), "нет third_party/circle_flags"
edit("pubspec.yaml", flags)
# 16б. Правила маршрутизации — из своей ветки rule-set (её обновляет Actions → Sync rule sets)
raw = repo.replace("https://github.com/", "https://raw.githubusercontent.com/") + "/rule-set"
def geo(s):
    for a, b in [
        ("const _geoUrl = 'https://raw.githubusercontent.com/hiddify/hiddify-geo/rule-set';", f"const _geoUrl = '{raw}';"),
        ("const _geositeUrl = 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set';", f"const _geositeUrl = '{raw}/sagernet';"),
    ]:
        assert s.count(a) == 1, a[:40]
        s = s.replace(a, b)
    return s
edit("lib/features/route_rules/notifier/rules_notifier.dart", geo)

# 17. Выпадающие меню поверх всего экрана (раньше нижнее меню прятало последний пункт)
def menus(s):
    a = "    final menu = MenuAnchor(\n"
    assert s.count(a) == 1, "MenuAnchor"
    return s.replace(a, a + "      useRootOverlay: true, // MyVPN: меню не прячется под нижней панелью\n")
edit("lib/core/widget/adaptive_menu.dart", menus)

# 18. Ссылки «Добавить в …» от других приложений (Буфер обмена, QR-код)
MY_LINKS = r"""
  // MyVPN: ссылки других клиентов → адрес подписки
  static const _myPathSchemes = {'happ', 'incy', 'streisand', 'shadowrocket', 'rabbithole', 'v2raytun', 'v2box'};
  static const _myQuerySchemes = {
    'karing', 'v2box', 'foxray', 'sn', 'stash', 'clashx', 'clashmi', 'flclash', 'flclashx',
    'koala-clash', 'clash-verge', 'mihomo', 'nekobox', 'v2rayng', 'v2rayn', 'v2raytun', 'happ', 'incy', 'sing-box',
  };

  static String _myB64(String s) {
    var t = s.trim().replaceAll('-', '+').replaceAll('_', '/');
    while (t.length % 4 != 0) {
      t += '=';
    }
    return safeDecodeBase64(t);
  }

  static ({String scheme, String rest})? _mySplit(String link) {
    final m = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*)://(.*)$', dotAll: true).firstMatch(link.trim());
    if (m == null) return null;
    return (scheme: m.group(1)!.toLowerCase(), rest: m.group(2)!);
  }

  static ProfileLink? _myLink(String url, String name) {
    var u = url.trim();
    if (!u.contains('://') && u.toLowerCase().startsWith('http')) u = Uri.decodeComponent(u);
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(u)) return null;
    return (url: u, name: name.isEmpty ? '' : Uri.decodeComponent(name));
  }

  static ProfileLink? myDeep(String link) {
    final p = _mySplit(link);
    if (p == null) return null;
    final hash = p.rest.indexOf('#');
    final body = hash >= 0 ? p.rest.substring(0, hash) : p.rest;
    final name = hash >= 0 ? p.rest.substring(hash + 1) : '';
    // Shadowrocket: sub://BASE64(адрес)#Имя
    if (p.scheme == 'sub') {
      final decoded = _myB64(body);
      return decoded.contains('://') ? _myLink(decoded, name) : null;
    }
    // happ://add/АДРЕС, incy://import/АДРЕС, streisand://import/АДРЕС#Имя, shadowrocket://add/sub://…
    if (_myPathSchemes.contains(p.scheme)) {
      final m = RegExp(r'^(?:add|import|install-sub|sub/add)/+(.+)$', caseSensitive: false, dotAll: true).firstMatch(p.rest);
      if (m != null) {
        final inner = m.group(1)!;
        if (inner.toLowerCase().startsWith('sub://')) return myDeep(inner);
        final h = inner.indexOf('#');
        final r = _myLink(h >= 0 ? inner.substring(0, h) : inner, h >= 0 ? inner.substring(h + 1) : '');
        if (r != null) return r;
      }
    }
    // karing://install-config?url=…&name=…, v2box://install-sub?url=…, foxray://yiguo.dev/sub/add/?url=…#Имя и т. п.
    if (_myQuerySchemes.contains(p.scheme)) {
      final uri = Uri.tryParse(link.trim());
      final url = uri?.queryParameters['url'];
      if (url != null && url.isNotEmpty) return _myLink(url, uri!.queryParameters['name'] ?? uri.fragment);
    }
    return null;
  }

  /// incy://add/vless://… и подобные: вынуть сам конфиг
  static String myUnwrapConfig(String input) {
    final p = _mySplit(input);
    if (p == null || !_myPathSchemes.contains(p.scheme)) return input;
    final m = RegExp(r'^(?:add|import)/+(.+)$', caseSensitive: false, dotAll: true).firstMatch(p.rest);
    if (m == null) return input;
    final inner = m.group(1)!;
    return inner.contains('://') ? inner : _myB64(inner);
  }
"""
def links(s):
    for a, b in [
        ("    return simple(link) ?? deep(link);\n", "    return simple(link) ?? myDeep(link) ?? deep(link);\n"),
        ("  static ProfileLink? simple(String link) {\n", MY_LINKS.lstrip("\n") + "\n  static ProfileLink? simple(String link) {\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:40]
        s = s.replace(a, b)
    return s
edit("lib/utils/link_parsers.dart", links)
def unwrap(s):
    a = "task = _profilesRepo.addLocal(safeDecodeBase64(rawInput)).map((_) => unit);"
    assert s.count(a) == 1, "addLocal"
    return s.replace(a, "task = _profilesRepo.myAddToMine(safeDecodeBase64(LinkParser.myUnwrapConfig(rawInput.trim())));")
edit("lib/features/profile/notifier/profile_notifier.dart", unwrap)

# 19. Общий профиль «Все подписки»: серверы всех подписок в одном профиле,
#     сам пересобирается при добавлении, обновлении и удалении подписок
MY_ALL = r"""

  // ===== MyVPN: общие профили «Все подписки» и «Избранное» =====
  static const myAllName = 'Все подписки';
  static const myFavName = 'Избранное';
  static const _mySkipTypes = {'selector', 'urltest', 'direct', 'block', 'dns'};
  StreamSubscription<dynamic>? _myAllSub;
  Timer? _myAllTimer;
  String? _myAllSig;
  bool _myAllBusy = false;
  bool _myAllAgain = false;

  bool _myIsNamed(ProfileEntity p, String name) =>
      p is LocalProfileEntity && (p.userOverride?.name == name || p.name == name);
  bool _myIsAll(ProfileEntity p) => _myIsNamed(p, myAllName);
  bool _myIsSpecial(ProfileEntity p) =>
      _myIsNamed(p, myAllName) || _myIsNamed(p, myFavName) || _myIsNamed(p, '☁️ WARP'); // запасной WARP — не в общие

  void _myWatchAll() {
    if (kIsWeb || _myAllSub != null) return;
    _myAllSub = _profileDataSource
        .watchAll(sort: ProfilesSort.lastUpdate, sortMode: SortMode.ascending)
        .listen(
          (entries) {
            final others = [for (final e in entries) ?_readable(e)].where((p) => !_myIsSpecial(p)).toList()
              ..sort((a, b) => a.id.compareTo(b.id));
            final sig = [for (final p in others) '${p.id}@${p.lastUpdate.millisecondsSinceEpoch}'].join('|');
            if (sig == _myAllSig) return;
            _myAllSig = sig;
            _myAllTimer?.cancel();
            _myAllTimer = Timer(const Duration(seconds: 3), () => unawaited(_myRebuildAll()));
          },
          onError: (Object e, StackTrace st) => loggy.warning('MyVPN: слежение за профилями', e, st),
        );
  }

  /// Отметки «избранное» / «исключить» поменялись: применить ко всем профилям и пересобрать общие.
  @override
  Future<void> myMarksChanged() async {
    try {
      await MyMarks.load();
      final dir = _profilePathResolver.directory;
      if (await dir.exists()) {
        await for (final f in dir.list()) {
          if (f is File && f.path.endsWith('.json') && !f.path.endsWith('.tmp.json') && !f.path.endsWith('.orig.json')) {
            await myApplyToFile(f.path);
          }
        }
      }
    } catch (e, st) {
      loggy.warning('MyVPN: отметки не применены', e, st);
    }
    // общие профили пересобираются в фоне, файлы подписок уже обновлены
    unawaited(_myRebuildAll());
  }

  /// Создать, обновить или удалить (если серверов нет) общий профиль [name].
  Future<void> _myUpsert(
    String name,
    List<ProfileEntity> existing,
    List<Map<String, dynamic>> outbounds,
    List<Map<String, dynamic>> endpoints,
  ) async {
    if (outbounds.isEmpty && endpoints.isEmpty) {
      for (final p in existing) {
        await deleteById(p.id, p.active).run();
      }
      return;
    }
    final content = jsonEncode({'outbounds': outbounds, if (endpoints.isNotEmpty) 'endpoints': endpoints});
    final override = UserOverride(name: name);
    final count = outbounds.length + endpoints.length;
    if (existing.isEmpty) {
      final res = await addLocal(content, userOverride: override).run();
      await res.match(
        (l) async => loggy.warning('MyVPN: «$name» не создан: $l'),
        (id) async {
          await setPinned(id, true).run();
          loggy.info('MyVPN: «$name» создан, серверов: $count');
        },
      );
    } else {
      final cur = existing.first;
      final res = await offlineUpdate(cur.copyWith(userOverride: cur.userOverride ?? override), content).run();
      res.match(
        (l) => loggy.warning('MyVPN: «$name» не обновлён: $l'),
        (_) => loggy.info('MyVPN: «$name» обновлён, серверов: $count'),
      );
      for (final extra in existing.skip(1)) {
        await deleteById(extra.id, extra.active).run();
      }
    }
  }

  Future<void> _myRebuildAll() async {
    if (_myAllBusy) {
      _myAllAgain = true;
      return;
    }
    _myAllBusy = true;
    try {
      await MyMarks.load();
      final entries = await _profileDataSource
          .watchAll(sort: ProfilesSort.lastUpdate, sortMode: SortMode.ascending)
          .first;
      final profiles = [for (final e in entries) ?_readable(e)];
      final others = profiles.where((p) => !_myIsSpecial(p)).toList();
      final texts = <String>[];
      for (final p in others) {
        // исходные серверы подписки (без её личных фильтров), общие фильтры применятся к самому профилю
        final file = _profilePathResolver.file(p.id);
        final orig = File(myOrigPath(file.path));
        if (await orig.exists()) {
          texts.add(await orig.readAsString());
        } else if (await file.exists()) {
          texts.add(await file.readAsString());
        }
      }
      // «Все подписки» — когда подписок хотя бы две
      final all = (outbounds: <Map<String, dynamic>>[], endpoints: <Map<String, dynamic>>[]);
      if (others.length >= 2) {
        final seen = <String>{}, tags = <String>{};
        for (final t in texts) {
          _myCollect(t, all.outbounds, all.endpoints, seen, tags);
        }
      }
      await _myUpsert(myAllName, profiles.where((p) => _myIsNamed(p, myAllName)).toList(), all.outbounds, all.endpoints);
      // «Избранное» — серверы, отмеченные звёздочкой, из всех подписок
      final fav = (outbounds: <Map<String, dynamic>>[], endpoints: <Map<String, dynamic>>[]);
      if (MyMarks.fav.isNotEmpty) {
        final seen = <String>{}, tags = <String>{};
        for (final t in texts) {
          _myCollect(t, fav.outbounds, fav.endpoints, seen, tags, where: (o) => myHasKey(MyMarks.fav, o));
        }
      }
      await _myUpsert(myFavName, profiles.where((p) => _myIsNamed(p, myFavName)).toList(), fav.outbounds, fav.endpoints);
    } catch (e, st) {
      loggy.warning('MyVPN: общие профили не собраны', e, st);
    } finally {
      _myAllBusy = false;
      if (_myAllAgain) {
        _myAllAgain = false;
        unawaited(_myRebuildAll());
      }
    }
  }
  /// Добавляет серверы из сохранённого JSON профиля, без дублей и с уникальными именами.
  void _myCollect(
    String text,
    List<Map<String, dynamic>> outbounds,
    List<Map<String, dynamic>> endpoints,
    Set<String> seen,
    Set<String> tags, {
    bool Function(Map<String, dynamic> server)? where,
  }) {
    Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (json is! Map<String, dynamic>) return;
    for (final key in const ['outbounds', 'endpoints']) {
      final list = json[key];
      if (list is! List) continue;
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        if (_mySkipTypes.contains(item['type'])) continue;
        if (where != null && !where(item)) continue;
        final copy = Map<String, dynamic>.of(item);
        final tag = (copy.remove('tag') ?? '').toString();
        // один и тот же сервер — только один раз
        if (!seen.add('$key ${jsonEncode(copy)}')) continue;
        final base = tag.isEmpty ? 'proxy' : tag;
        var t = base;
        for (var n = 2; !tags.add(t); n++) {
          t = '$base ($n)';
        }
        copy['tag'] = t;
        (key == 'outbounds' ? outbounds : endpoints).add(copy);
      }
    }
  }

  // ----- «Мои серверы»: всё, что добавлено не ссылкой на подписку, собирается в одну строку -----
  static const myMineName = 'Мои серверы';

  bool _myIsMine(ProfileEntity p) =>
      p is LocalProfileEntity && (p.userOverride?.name == myMineName || p.name == myMineName);

  @override
  TaskEither<ProfileFailure, Unit> myAddToMine(String content) => TaskEither.tryCatch(
    () async {
      const tmpId = 'myvpn-mine-new';
      final inFile = _profilePathResolver.tempFile(tmpId);
      final outFile = _profilePathResolver.file(tmpId);
      try {
        await inFile.writeAsString(content);
        (await validateConfig(outFile.path, inFile.path, null, false).run()).getOrElse((l) => throw l);
        final outbounds = <Map<String, dynamic>>[];
        final endpoints = <Map<String, dynamic>>[];
        final seen = <String>{};
        final tags = <String>{};
        final entries = await _profileDataSource
            .watchAll(sort: ProfilesSort.lastUpdate, sortMode: SortMode.ascending)
            .first;
        final mine = [for (final e in entries) ?_readable(e)].where(_myIsMine).firstOrNull;
        if (mine != null) {
          final old = _profilePathResolver.file(mine.id);
          final oldOrig = File(myOrigPath(old.path));
          if (await oldOrig.exists()) {
            _myCollect(await oldOrig.readAsString(), outbounds, endpoints, seen, tags);
          } else if (await old.exists()) {
            _myCollect(await old.readAsString(), outbounds, endpoints, seen, tags);
          }
        }
        final before = outbounds.length + endpoints.length;
        final beforeOut = outbounds.length, beforeEnd = endpoints.length;
        final newOrig = File(myOrigPath(outFile.path));
        _myCollect(await (await newOrig.exists() ? newOrig : outFile).readAsString(), outbounds, endpoints, seen, tags);
        if (outbounds.isEmpty && endpoints.isEmpty) throw const ProfileFailure.invalidConfig();
        final merged = jsonEncode({'outbounds': outbounds, if (endpoints.isNotEmpty) 'endpoints': endpoints});
        const override = UserOverride(name: myMineName);
        if (mine == null) {
          (await addLocal(merged, userOverride: override).run()).getOrElse((l) => throw l);
        } else {
          (await offlineUpdate(mine.copyWith(userOverride: mine.userOverride ?? override), merged).run())
              .getOrElse((l) => throw l);
          await setAsActive(mine.id).run();
        }
        loggy.info('MyVPN: в «Мои серверы» добавлено: ${outbounds.length + endpoints.length - before}');
        myOnServersAdded?.call([...outbounds.skip(beforeOut), ...endpoints.skip(beforeEnd)]);
        return unit;
      } finally {
        if (inFile.existsSync()) inFile.deleteSync();
        if (outFile.existsSync()) outFile.deleteSync();
        final tmpOrig = File(myOrigPath(outFile.path));
        if (tmpOrig.existsSync()) tmpOrig.deleteSync();
      }
    },
    (e, st) => e is ProfileFailure ? e : ProfileFailure.unexpected(e, st),
  );
  // ===== конец MyVPN =====

"""
def all_profile(s):
    for a, b in [
        ("import 'package:dio/dio.dart';\n", "import 'dart:async';\nimport 'dart:convert';\nimport 'dart:io';\n\nimport 'package:dio/dio.dart';\n"),
        ("import 'package:hiddify/features/profile/data/profile_parser.dart';\n",
         "import 'package:hiddify/features/profile/data/myvpn_marks.dart';\nimport 'package:hiddify/features/profile/data/profile_parser.dart';\n"),
        ("      await _profilePathResolver.file(id).delete();\n",
         "      await _profilePathResolver.file(id).delete();\n"
         "      final myOrig = File(myOrigPath(_profilePathResolver.file(id).path)); // MyVPN\n"
         "      if (await myOrig.exists()) await myOrig.delete();\n"),
        ("                  (_) => _singbox.validateConfigByPath(path, tempPath, debug).mapLeft(ProfileFailure.invalidConfig),\n",
         "                  (_) => _singbox.validateConfigByPath(path, tempPath, debug).mapLeft(ProfileFailure.invalidConfig),\n"
         "                )\n"
         "                // MyVPN: исключённые серверы остаются исключёнными после обновления подписки\n"
         "                .flatMap(\n"
         "                  (_) => TaskEither.tryCatch(() async {\n"
         "                    await myAfterProfileWritten(path);\n"
         "                    return unit;\n"
         "                  }, ProfileFailure.unexpected),\n"),
        ("      }\n\n      return right(unit);\n    }, ProfileUnexpectedFailure.new);\n  }\n",
         "      }\n      _myWatchAll(); // MyVPN\n\n      return right(unit);\n    }, ProfileUnexpectedFailure.new);\n  }\n" + MY_ALL),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
def mine_iface(s):
    a = "  TaskEither<ProfileFailure, String> addLocal(String content, {UserOverride? userOverride});\n"
    assert s.count(a) == 1, "addLocal interface"
    return s.replace(a, a + "  /// MyVPN: добавить серверы в профиль «Мои серверы»\n  TaskEither<ProfileFailure, Unit> myAddToMine(String content);\n"
                     "  /// MyVPN: применить отметки «избранное» и «исключить»\n  Future<void> myMarksChanged();\n")
edit("lib/features/profile/data/profile_repository.dart", lambda s: mine_iface(all_profile(s)))

# 20. Профили: справа число серверов и время обновления; серверы — стрелкой во вкладке «Серверы»
assert os.path.exists("lib/features/profile/widget/myvpn_profile_extras.dart"), "нет myvpn_profile_extras.dart"
def tile(s):
    for a, b in [
        ("import 'package:hiddify/features/profile/model/profile_entity.dart';\n",
         "import 'package:hiddify/features/profile/model/profile_entity.dart';\n"
         "import 'package:hiddify/features/profile/widget/myvpn_profile_extras.dart';\n"
         "import 'package:hiddify/features/settings/myvpn_hwid.dart';\n"
         "import 'package:hiddify/features/settings/myvpn_update_check.dart';\n"
         "import 'package:hiddify/features/stats/myvpn_counters.dart';\n"),
        ("    final nameText = Text(\n      profile.name,\n",
         "    final nameText = MyNameRow(\n      profile: profile,\n      text: Text(\n      profile.name,\n"),
        ("\n    );\n\n    final Widget? trailing = isMain",
         "\n    ),\n    );\n\n    final Widget? trailing = isMain"),
        ("      if (profile case RemoteProfileEntity())\n        AdaptiveMenuItem(\n          title: t.common.update,",
         "      AdaptiveMenuItem(\n        title: 'Трафик и лимит',\n        leadingIcon: const Icon(Icons.data_usage_rounded),\n"
         "        onTap: () => showMyCounter(context, profile.name),\n      ),\n"
         "      if (profile case RemoteProfileEntity())\n        AdaptiveMenuItem(\n          title: 'HWID для этой подписки',\n"
         "          leadingIcon: const Icon(Icons.badge_outlined),\n          onTap: () => showMySubHwid(context, profile),\n        ),\n"
         "      if (profile case RemoteProfileEntity())\n        AdaptiveMenuItem(\n          title: 'Откатить последнее обновление',\n"
         "          leadingIcon: const Icon(Icons.history_rounded),\n"
         "          onTap: () async {\n            final ok = await myRollback(ref, profile);\n"
         "            if (context.mounted) mySnack(context, ok ? 'Вернул прошлую версию подписки' : 'Прошлой версии нет');\n          },\n        ),\n"
         "      if (profile case RemoteProfileEntity())\n        AdaptiveMenuItem(\n          title: t.common.update,"),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
def tile_edit(s):
    # MyVPN: подписки во вкладке, а не в выдвижном окне — закрывать нечего, иначе «Изменить» не открывается
    a = "          if (Breakpoint(context).isMobile()) context.pop();\n          context.goNamed('profileDetails'"
    assert s.count(a) == 1, "edit pop"
    return s.replace(a, "          if (Breakpoint(context).isMobile() && context.canPop()) context.pop();\n          context.goNamed('profileDetails'")
edit("lib/features/profile/widget/profile_tile.dart", lambda s: tile_edit(tile(s)))

# 21. HWID устройства при загрузке подписок (x-hwid и др.), как у Happ / v2RayTun / Incy.
#     Платные панели (Remnawave и др.) без него отдают пустую подписку или заглушку.
MY_HWID = r"""
  // MyVPN: заголовки устройства для панелей подписок (HWID-лимит устройств)
  static bool myHwidEnabled = true;
  static Future<String>? _myIdF;
  static Future<String> myHwid() => _myIdF ??= _myHwidHeaders().then((h) => h['x-hwid'] ?? '');
  static Future<Map<String, String>>? _myHw;
  /// Сбросить запомненный HWID (после смены в настройках).
  static void myHwidReset() {
    _myHw = null;
    _myIdF = null;
  }

  /// Ключ подписки для своего HWID: адрес без параметров.
  static String myHwidKey(String url) {
    final u = Uri.tryParse(url.trim());
    return u == null || u.host.isEmpty ? url.trim() : '${u.host}${u.path}';
  }

  /// Заголовки для конкретной подписки: свой HWID у подписки → он; «не отправлять» → ничего; иначе общий.
  static Future<Map<String, String>> myHwidHeadersFor(String url, bool enabled) async {
    final base = await _myHwidHeaders();
    Object? v;
    try {
      final by = jsonDecode((await SharedPreferences.getInstance()).getString('myvpn_hwid_by_sub') ?? '{}');
      if (by is Map) v = by[myHwidKey(url)];
    } catch (_) {}
    if (v == null) return enabled ? base : const {};
    if (v == '') return const {};
    if (v == 'device') return base;
    return {...base, 'x-hwid': v.toString()};
  }

  static Future<Map<String, String>> _myHwidHeaders() => _myHw ??= () async {
    var id = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      final custom = prefs.getString('myvpn_hwid_custom') ?? '';
      id = custom.isNotEmpty ? custom : prefs.getString('myvpn_hwid') ?? '';
      if (custom.isEmpty && !RegExp(r'^[a-zA-Z0-9=-]{10,64}$').hasMatch(id)) {
        id = const Uuid().v4().replaceAll('-', '');
        await prefs.setString('myvpn_hwid', id);
      }
    } catch (_) {
      id = const Uuid().v4().replaceAll('-', '');
    }
    final os = Platform.isIOS ? 'iOS' : (Platform.isAndroid ? 'Android' : Platform.operatingSystem);
    final ver = RegExp(r'\d+(\.\d+)*').firstMatch(Platform.operatingSystemVersion)?.group(0) ?? '';
    return {
      'x-hwid': id,
      'x-device-os': os,
      if (ver.isNotEmpty) 'x-ver-os': ver,
      'x-device-model': Platform.isIOS ? 'iPhone' : os,
    };
  }();

"""
def hwid(s):
    for a, b in [
        ("import 'package:hiddify/utils/custom_loggers.dart';\n",
         "import 'package:hiddify/utils/custom_loggers.dart';\nimport 'package:shared_preferences/shared_preferences.dart';\nimport 'package:uuid/uuid.dart';\n"),
        ("  Future<Response> download(\n", MY_HWID.lstrip("\n") + "  Future<Response> download(\n"),
        ("      options: _options(url, userAgent: userAgent, credentials: credentials),\n    );\n  }\n",
         "      options: _options(url, userAgent: userAgent, credentials: credentials)\n        ..headers?.addAll({\n          // MyVPN: названия серверов и описания на русском, если панель их переводит\n          'Accept-Language': 'ru-RU,ru;q=0.9,en;q=0.8',\n          ...await myHwidHeadersFor(url, myHwidEnabled),\n        }),\n    );\n  }\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
edit("lib/core/http_client/dio_http_client.dart", hwid)

# 22. Настройки → Общие: «Отправлять HWID» (вкл/выкл) и «HWID устройства» (нажать — скопировать)
def hwid_pref(s):
    a = '  static final subscriptionUserAgent = PreferencesNotifier.create<String, String>("myvpn_sub_user_agent", "");\n'
    assert s.count(a) == 1, "subscriptionUserAgent"
    return s.replace(a, a + '  /// MyVPN: отправлять HWID устройства при загрузке подписок\n'
                     '  static final myHwidEnabled = PreferencesNotifier.create<bool, bool>("myvpn_hwid_enabled", true);\n')
edit("lib/core/preferences/general_preferences.dart", hwid_pref)
def hwid_client(s):
    a = "  setUserAgent();\n"
    assert s.count(a) == 1, "setUserAgent"
    return s.replace(a, a + "  DioHttpClient.myHwidEnabled = ref.read(Preferences.myHwidEnabled);\n"
                     "  ref.listen(Preferences.myHwidEnabled, (_, next) => DioHttpClient.myHwidEnabled = next);\n")
edit("lib/core/http_client/http_client_provider.dart", hwid_client)
HWID_TILES = """          SwitchListTile.adaptive(
            title: const Text('Отправлять HWID'),
            subtitle: const Text('Номер устройства для подписок с лимитом устройств'),
            secondary: const Icon(Icons.fingerprint_rounded),
            value: ref.watch(Preferences.myHwidEnabled),
            onChanged: ref.read(Preferences.myHwidEnabled.notifier).update,
          ),
          FutureBuilder<String>(
            future: DioHttpClient.myHwid(),
            builder: (context, snap) => ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('HWID устройства'),
              subtitle: Text(snap.data ?? '…', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              trailing: const Icon(Icons.edit_rounded, size: 20),
              onTap: () => showMyHwidDialog(context),
            ),
          ),
"""
def hwid_tiles(s):
    for a, b in [
        ("import 'package:flutter/material.dart';\n",
         "import 'package:flutter/material.dart';\nimport 'package:flutter/services.dart';\nimport 'package:hiddify/core/http_client/dio_http_client.dart';\nimport 'package:hiddify/features/settings/myvpn_hwid.dart';\n"),
        ("            presentChoice: (value) => _myUserAgents[value] ?? value,\n          ),\n",
         "            presentChoice: (value) => _myUserAgents[value] ?? value,\n          ),\n" + HWID_TILES),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
edit("lib/features/settings/overview/sections/general_page.dart", hwid_tiles)

# 23. Подписки в формате Xray JSON (Happ/Incy): понятные имена серверов из "remarks" вместо «proxy-1 § 0»
assert os.path.exists("lib/utils/myvpn_xray_names.dart"), "нет myvpn_xray_names.dart"
def xray_names(s):
    for a, b in [
        ("import 'package:hiddify/utils/utils.dart';\n",
         "import 'package:hiddify/utils/myvpn_xray_names.dart';\nimport 'package:hiddify/utils/utils.dart';\n"),
        ("        final expanded = await expandLinks(text, cancelToken ?? CancelToken());\n",
         "        final expanded = await expandLinks(myNameXrayJson(text), cancelToken ?? CancelToken());\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
edit("lib/features/profile/data/profile_parser.dart", xray_names)

# 24. Статистика трафика и резервная копия (Настройки → Общие)
for f in ["lib/features/stats/myvpn_traffic.dart", "lib/features/settings/myvpn_backup.dart", "lib/features/profile/data/myvpn_marks.dart"]:
    assert os.path.exists(f), "нет " + f
def traffic_feed(s):
    for a, b in [
        ("import 'package:hiddify/features/stats/data/stats_data_providers.dart';\n",
         "import 'package:hiddify/features/stats/data/stats_data_providers.dart';\nimport 'package:hiddify/features/stats/myvpn_traffic.dart';\n"),
        ("          .map((event) => event.getOrElse((_) => SystemInfo.create()));\n",
         "          .map((event) {\n"
         "            final info = event.getOrElse((_) => SystemInfo.create());\n"
         "            MyTraffic.feed(info.uplinkTotal.toInt(), info.downlinkTotal.toInt(), info.currentProfile); // MyVPN\n"
         "            return info;\n"
         "          });\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
edit("lib/features/stats/notifier/stats_notifier.dart", traffic_feed)
MORE_TILES = """          ListTile(
            leading: const Icon(Icons.data_usage_rounded),
            title: const Text('Статистика трафика'),
            subtitle: const Text('Сегодня, за месяц и по подпискам'),
            onTap: () => showMyTraffic(context),
          ),
          ListTile(
            leading: const Icon(Icons.save_alt_rounded),
            title: const Text('Сохранить резервную копию'),
            subtitle: const Text('Подписки, «Мои серверы», избранное — в файл'),
            onTap: () => myExportBackup(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.restore_rounded),
            title: const Text('Восстановить из копии'),
            subtitle: const Text('Добавит недостающие подписки и серверы'),
            onTap: () => myImportBackup(context, ref),
          ),
"""
def more_tiles(s):
    for a, b in [
        ("import 'package:hiddify/core/http_client/dio_http_client.dart';\n",
         "import 'package:hiddify/core/http_client/dio_http_client.dart';\n"
         "import 'package:hiddify/features/settings/myvpn_backup.dart';\n"
         "import 'package:hiddify/features/stats/myvpn_traffic.dart';\n"),
        ("              onTap: () => showMyHwidDialog(context),\n            ),\n          ),\n",
         "              onTap: () => showMyHwidDialog(context),\n            ),\n          ),\n" + MORE_TILES),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
edit("lib/features/settings/overview/sections/general_page.dart", more_tiles)

# 25. Сервисы Apple: каждый можно пустить через VPN (по умолчанию все сервисы Apple напрямую)
APPLE_RULES = {
    "applePushVpn": ("Через VPN: уведомления Apple (пуши)",
                     "domainSuffixes: ['push.apple.com', 'push-apple.com.akadns.net']"),
    "appleICloudVpn": ("Через VPN: iCloud",
                       "domainSuffixes: ['icloud.com', 'icloud-content.com', 'apple-cloudkit.com', 'icloud.apple.com']"),
    "appleStoreVpn": ("Через VPN: App Store и обновления iOS",
                      "domainSuffixes: ['apps.apple.com', 'itunes.apple.com', 'mzstatic.com', 'itunes.com', "
                      "'appldnld.apple.com', 'updates.cdn-apple.com', 'swcdn.apple.com', 'swdist.apple.com', "
                      "'mesu.apple.com', 'gdmf.apple.com']"),
    "appleMediaVpn": ("Через VPN: Apple Music, TV и подкасты",
                      "domainSuffixes: ['music.apple.com', 'tv.apple.com', 'podcasts.apple.com', 'aod.itunes.apple.com', "
                      "'audio-ssl.itunes.apple.com', 'hls.itunes.apple.com', 'play.itunes.apple.com']"),
}
def apple_rules(s):
    a = "  bypassLan(enabledByDefault: true),\n"
    assert s.count(a) == 1, "bypassLan enum"
    s = s.replace(a, "".join(f"  {k}(enabledByDefault: false),\n" for k in APPLE_RULES) + a)
    a = "    bypassLan => t.pages.settings.routing.builtinRules.bypassLan,\n"
    assert s.count(a) == 1, "bypassLan present"
    s = s.replace(a, "".join(f"    {k} => '{v[0]}',\n" for k, v in APPLE_RULES.items()) + a)
    a = "  Rule get rule => switch (this) {\n"
    assert s.count(a) == 1, "Rule get rule"
    s = s.replace(a, a + "".join(f"    {k} => Rule(outbound: Outbound.proxy, {v[1]}),\n" for k, v in APPLE_RULES.items()))
    return s
edit("lib/features/route_rules/notifier/rules_notifier.dart", apple_rules)
def malware_rule(s):
    for a, b in [
        ("  blockAds(enabledByDefault: false),\n", "  blockMalware(enabledByDefault: false),\n  blockAds(enabledByDefault: false),\n"),
        ("    blockAds => t.pages.settings.routing.builtinRules.blockAds,\n",
         "    blockMalware => 'Блокировать вирусные и фишинговые сайты',\n    blockAds => t.pages.settings.routing.builtinRules.blockAds,\n"),
        ("    blockAds => Rule(\n",
         "    blockMalware => Rule(\n      outbound: Outbound.block,\n      ruleSets: [\n"
         "        '$_geoUrl/block/geosite-malware.srs',\n        '$_geoUrl/block/geosite-phishing.srs',\n"
         "        '$_geoUrl/block/geosite-cryptominers.srs',\n      ],\n    ),\n    blockAds => Rule(\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:40]
        s = s.replace(a, b)
    return s
edit("lib/features/route_rules/notifier/rules_notifier.dart", malware_rule)
def torrent_quic_rules(s):
    for a, b in [
        ("  blockMalware(enabledByDefault: false),\n",
         "  torrentsDirect(enabledByDefault: false),\n  blockQuic(enabledByDefault: false),\n  blockMalware(enabledByDefault: false),\n"),
        ("    blockMalware => 'Блокировать вирусные и фишинговые сайты',\n",
         "    torrentsDirect => 'Торренты напрямую',\n    blockQuic => 'Блокировать QUIC (UDP 443) — всё пойдёт по TCP',\n"
         "    blockMalware => 'Блокировать вирусные и фишинговые сайты',\n"),
        ("    blockMalware => Rule(\n",
         "    torrentsDirect => Rule(outbound: Outbound.direct, protocols: [Protocol.bittorrent]),\n"
         "    blockQuic => Rule(outbound: Outbound.block, network: Network.udp, portRanges: ['443']),\n"
         "    blockMalware => Rule(\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:40]
        s = s.replace(a, b)
    return s
edit("lib/features/route_rules/notifier/rules_notifier.dart", torrent_quic_rules)

# 26. Главный экран: панель под кнопкой (время сессии, график, сервер, белые списки, скорость)
for f in ["lib/features/home/widget/myvpn_home_panel.dart", "lib/features/settings/myvpn_tools.dart", "lib/utils/myvpn_telegram.dart"]:
    assert os.path.exists(f), "нет " + f
def home_panel(s):
    for a, b in [
        ("import 'package:hiddify/features/home/widget/connection_button.dart';\n",
         "import 'package:hiddify/features/home/widget/connection_button.dart';\nimport 'package:hiddify/features/home/widget/myvpn_home_panel.dart';\n"),
        ("children: [ConnectionButton(), ActiveProxyDelayIndicator()],",
         "children: [ConnectionButton(), ActiveProxyDelayIndicator(), MyHomePanel()],"),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
edit("lib/features/home/widget/home_page.dart", home_panel)
def session_feed(s):
    for a, b in [
        ("import 'package:hiddify/features/stats/myvpn_traffic.dart';\n",
         "import 'package:hiddify/features/home/widget/myvpn_home_panel.dart';\nimport 'package:hiddify/features/stats/myvpn_counters.dart';\nimport 'package:hiddify/features/stats/myvpn_traffic.dart';\n"),
        ("            MyTraffic.feed(info.uplinkTotal.toInt(), info.downlinkTotal.toInt(), info.currentProfile); // MyVPN\n",
         "            MyTraffic.feed(info.uplinkTotal.toInt(), info.downlinkTotal.toInt(), info.currentProfile); // MyVPN\n"
         "            MySession.feedStats(info.uplink.toInt(), info.downlink.toInt()); // MyVPN\n"
         "            MyCounters.feed(info.uplinkTotal.toInt(), info.downlinkTotal.toInt(), info.currentProfile, info.currentOutbound); // MyVPN\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
edit("lib/features/stats/notifier/stats_notifier.dart", session_feed)

# 27. Telegram-канал как подписка
def tg_url(s):
    a = "    ProgressCallback? onReceiveProgress,\n  }) async {\n    final mode = proxyOnly\n"
    assert s.count(a) == 1, "download start"
    s = s.replace(a, "    ProgressCallback? onReceiveProgress,\n  }) async {\n"
                     "    url = myTelegramUrl(url); // MyVPN: t.me/канал → страница с постами\n    final mode = proxyOnly\n")
    a = "import 'package:hiddify/utils/custom_loggers.dart';\n"
    assert s.count(a) == 1, "dio imports"
    return s.replace(a, a + "import 'package:hiddify/utils/myvpn_telegram.dart';\n")
edit("lib/core/http_client/dio_http_client.dart", tg_url)
def tg_parse(s):
    for a, b in [
        ("import 'package:hiddify/utils/myvpn_xray_names.dart';\n",
         "import 'package:hiddify/utils/myvpn_telegram.dart';\nimport 'package:hiddify/utils/myvpn_xray_names.dart';\n"),
        ("        final expanded = await expandLinks(myNameXrayJson(text), cancelToken ?? CancelToken());\n",
         "        final expanded = await expandLinks(myNameXrayJson(myTelegramLinks(text) ?? text), cancelToken ?? CancelToken());\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
edit("lib/features/profile/data/profile_parser.dart", tg_parse)

# 28. Сводка после добавления подписки (число серверов, страны, срок, совпадения с другими)
def add_summary(s):
    for a, b in [
        ("import 'package:hiddify/features/connection/notifier/connection_notifier.dart';\n",
         "import 'package:hiddify/features/connection/notifier/connection_notifier.dart';\nimport 'package:hiddify/features/home/widget/myvpn_home_panel.dart';\nimport 'package:hiddify/features/settings/myvpn_hwid.dart';\n"),
        ("          cancelToken: _cancelToken = CancelToken(),\n        );\n      } else {",
         "          cancelToken: _cancelToken = CancelToken(),\n        );\n        MyAddSummary.prepare(rs.url); // MyVPN\n        await MyHwidNext.apply(rs.url); // MyVPN: HWID новой подписки\n      } else {"),
        ("      final task = _profilesRepo.upsertRemote(url, userOverride: userOverride);\n",
         "      await MyHwidNext.apply(url); // MyVPN: HWID новой подписки\n      final task = _profilesRepo.upsertRemote(url, userOverride: userOverride);\n"),
        ('              loggy.info("successfully added profile");\n',
         '              loggy.info("successfully added profile");\n              MyAddSummary.commit(); // MyVPN\n'),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
edit("lib/features/profile/notifier/profile_notifier.dart", add_summary)

# 29. DNS: готовые варианты одним нажатием
def dns_presets(s):
    for a, b in [
        ("import 'package:hiddify/features/settings/data/config_option_repository.dart';\n",
         "import 'package:hiddify/features/settings/data/config_option_repository.dart';\nimport 'package:hiddify/features/settings/myvpn_tools.dart';\n"),
        ("      body: ListView(\n        children: [\n",
         "      body: ListView(\n        children: [\n          const MyDnsPresetsTile(),\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
edit("lib/features/settings/overview/sections/dns_options_page.dart", dns_presets)

# 30. Настройки → Общие: страны, небезопасные, отпечаток TLS, таймер, белые списки, проверка сети
def tools_tiles(s):
    for a, b in [
        ("import 'package:hiddify/features/settings/myvpn_backup.dart';\n",
         "import 'package:hiddify/features/settings/myvpn_backup.dart';\nimport 'package:hiddify/features/settings/myvpn_tools.dart';\n"),
        ("          ListTile(\n            leading: const Icon(Icons.data_usage_rounded),\n",
         "          const MyToolsTiles(),\n          ListTile(\n            leading: const Icon(Icons.data_usage_rounded),\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
edit("lib/features/settings/overview/sections/general_page.dart", tools_tiles)

# 31. Таймер VPN: расширение само отключается по файлам myvpn_stop_at / myvpn_daily_off в общей папке
SWIFT_TIMER = """
    // MyVPN: таймер «выключить через…» и «выключать каждый день в…» (файлы пишет приложение)
    private var myStopTimer: DispatchSourceTimer?
    private var myStartedAt = Date()

    private func myStartStopTimer() {
        myStartedAt = Date()
        myStopTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.myCheckStop() }
        timer.resume()
        myStopTimer = timer
    }

    private func myCheckStop() {
        let dir = FilePath.sharedDirectory
        let now = Date()
        var stop = false
        let stopAtURL = dir.appendingPathComponent("myvpn_stop_at")
        if let text = try? String(contentsOf: stopAtURL, encoding: .utf8),
           let at = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let when = Date(timeIntervalSince1970: at)
            if when <= myStartedAt {
                // таймер остался от прошлого подключения
                try? FileManager.default.removeItem(at: stopAtURL)
            } else if now >= when {
                try? FileManager.default.removeItem(at: stopAtURL)
                stop = true
            }
        }
        let dailyURL = dir.appendingPathComponent("myvpn_daily_off")
        if !stop, let text = try? String(contentsOf: dailyURL, encoding: .utf8) {
            let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
            if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
               let off = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: now),
               now >= off, now.timeIntervalSince(off) < 120, myStartedAt < off {
                stop = true
            }
        }
        if stop {
            myStopTimer?.cancel()
            myStopTimer = nil
            cancelTunnelWithError(nil)
        }
    }
"""
def swift_timer(s):
    for a, b in [
        ("        try await super.startTunnel(options: options)\n",
         "        try await super.startTunnel(options: options)\n        myStartStopTimer() // MyVPN\n"),
        ("    override func handleAppMessage(_ messageData: Data) async -> Data? {\n",
         SWIFT_TIMER.lstrip("\n") + "\n    override func handleAppMessage(_ messageData: Data) async -> Data? {\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
edit("ios/HiddifyPacketTunnel/PacketTunnelProvider.swift", swift_timer)

# 32. Скрыть значок VPN: расширение включает excludeDefaultRoute, если приложение оставило файл myvpn_hide_icon
def hide_icon(s):
    a = '            excludeAPNsRoute: flag("excludeAPNsRoute", defaults.excludeAPNsRoute)\n        )\n'
    assert s.count(a) == 1, "applyStartOptions"
    return s.replace(a, a + '        // MyVPN: «Скрыть значок VPN» — iOS не рисует значок, если исключён маршрут 0.0.0.0/31 и ::/127\n'
        '        if FileManager.default.fileExists(atPath: FilePath.sharedDirectory.appendingPathComponent("myvpn_hide_icon").path) {\n'
        '            overridePreferences?.excludeDefaultRoute = true\n'
        '        }\n')
edit("ios/HiddifyPacketTunnel/SingBox/ExtensionProvider.swift", hide_icon)

# 33. Соединения и режимы: пароль Clash API передаётся в ядро, правила зависят от режима
def web_secret_field(s):
    a = "    required int clashApiPort,\n"
    assert s.count(a) == 1, "clashApiPort field"
    return s.replace(a, a + "    @Default('') String webSecret, // MyVPN: пароль Clash API (вкладка «Соединения»)\n")
edit("lib/singbox/model/singbox_config_option.dart", web_secret_field)
def modes(s):
    for a, b in [
        ("      clashApiPort: ref.watch(clashApiPort),\n",
         "      clashApiPort: ref.watch(clashApiPort),\n      webSecret: ref.watch(myWebSecretProvider), // MyVPN\n"),
        ("      routeRule: RouteRule(rules: ref.watch(rulesNotifierProvider)).toProto3Json()! as Map<String, dynamic>,\n",
         "      routeRule: RouteRule(rules: myRulesForConfig(ref, ref.watch(rulesNotifierProvider), ref.watch(myRouteModeProvider)))\n"
         "          .toProto3Json()! as Map<String, dynamic>, // MyVPN: режимы\n"),
        ("import 'package:hiddify/features/log/model/log_level.dart';\n",
         "import 'package:hiddify/features/connections/myvpn_connections.dart';\nimport 'package:hiddify/features/log/model/log_level.dart';\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
edit("lib/features/settings/data/config_option_repository.dart", modes)

# 34. Маршрутизация: импорт правил из других приложений, наборы, источники списков
def routing_extras(s):
    for a, b in [
        ("            const _PinnedOptions(),\n", "            const _PinnedOptions(),\n            const MyRoutingExtras(), // MyVPN\n"),
        ("import 'package:hiddify/features/route_rules/notifier/rules_notifier.dart';\n",
         "import 'package:hiddify/features/route_rules/myvpn_routing_extras.dart';\nimport 'package:hiddify/features/route_rules/notifier/rules_notifier.dart';\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:40]
        s = s.replace(a, b)
    return s
edit("lib/features/settings/overview/sections/routing_options_page.dart", routing_extras)

# 35. Список прокси: «lowest» → «⚡ Автовыбор» / «⚡ <группа подписки>», «balance» → «⚖️ Балансировка»
def proxy_titles(s):
    for a, b in [
        ("      title: Text(\n        proxy.nameWithDetour,\n",
         "      title: Text(\n        myGroupTitle(proxy.tag, proxy.nameWithDetour), // MyVPN\n"),
        ("import 'package:flutter/material.dart';\n",
         "import 'package:flutter/material.dart';\nimport 'package:hiddify/features/profile/data/myvpn_marks.dart';\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:40]
        s = s.replace(a, b)
    return s
edit("lib/features/proxy/widget/proxy_tile.dart", proxy_titles)
def card_group_title(s):
    for a, b in [
        ("                  Text(group, style: theme.textTheme.labelMedium?.copyWith(color: s.primary, letterSpacing: .3)),\n",
         "                  Flexible(\n                    child: Text(\n                      myGroupTitle(group, group).replaceFirst(RegExp(r'^[⚡⚖️]+\\s*'), ''), // MyVPN\n"
         "                      maxLines: 1,\n                      overflow: TextOverflow.ellipsis,\n"
         "                      style: theme.textTheme.labelMedium?.copyWith(color: s.primary, letterSpacing: .3),\n                    ),\n                  ),\n"),
        ("import 'package:flutter/material.dart';\n",
         "import 'package:flutter/material.dart';\nimport 'package:hiddify/features/profile/data/myvpn_marks.dart';\n"),
        # MyVPN: круглая кнопка замера скорости у сервера убрана — замер есть на главном (⚡), он точнее
        ("      end: connected\n          ? UploadSpeedChip(\n", "      end: false\n          ? UploadSpeedChip(\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:40]
        s = s.replace(a, b)
    return s
edit("lib/features/proxy/active/active_proxy_card.dart", card_group_title)

# 36. Вкладка «Серверы» внизу (как в Incy): Главная · Серверы · Настройки
def tab_routes(s):
    for a, b in [
        ("String getNameOfBranch(bool isMobileBreakpoint, bool showProfilesAction, int index) => isMobileBreakpoint\n    ? ['home', 'settings'][index]\n",
         "String getNameOfBranch(bool isMobileBreakpoint, bool showProfilesAction, int index) => isMobileBreakpoint\n    ? ['home', if (showProfilesAction) 'profiles', 'settings'][index]\n"),
        ("int getIndexOfBranch(bool isMobileBreakpoint, bool showProfilesAction, String name) => isMobileBreakpoint\n    ? ['home', 'settings'].indexOf(name)\n",
         "int getIndexOfBranch(bool isMobileBreakpoint, bool showProfilesAction, String name) => isMobileBreakpoint\n    ? ['home', if (showProfilesAction) 'profiles', 'settings'].indexOf(name)\n"),
        ("    if (isMobileBreakpoint == true) {\n      showProfilesAction = false;\n",
         "    if (isMobileBreakpoint == true) {\n      showProfilesAction = ref.watch(hasAnyProfileProvider).value ?? false; // MyVPN: вкладка «Серверы»\n"),
        ("                    if (isMobileBreakpoint)\n                      GoRoute(\n                        name: 'profileDetails',\n",
         "                    if (isMobileBreakpoint && !showProfilesAction)\n                      GoRoute(\n                        name: 'profileDetails',\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
edit("lib/core/router/go_router/routing_config_notifier.dart", tab_routes)
def tab_nav(s):
    for a, b in [
        ("    if (showProfilesAction && !isMobileBreakpoint) ShellRouteAction(Icons.view_list_rounded, t.pages.profiles.title),\n",
         "    if (showProfilesAction)\n      ShellRouteAction(Icons.dns_rounded, isMobileBreakpoint ? 'Серверы' : t.pages.profiles.title), // MyVPN\n"),
        ("                      selectedIndex: navigationShell.currentIndex <= 1 ? navigationShell.currentIndex : 0,\n",
         "                      selectedIndex: navigationShell.currentIndex < (showProfilesAction ? 3 : 2) ? navigationShell.currentIndex : 0,\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
edit("lib/core/router/adaptive_layout/my_adaptive_layout.dart", tab_nav)
def tab_page(s):
    for a, b in [
        ("        title: Text(t.pages.profiles.title),\n", "        title: const Text('Серверы'), // MyVPN\n"),
        # MyVPN: «Добавить» — плюсом вверху, а не большой кнопкой внизу
        ("      floatingActionButton: FloatingActionButton.extended(\n        onPressed: () async => await ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile(),\n        label: Text(t.pages.profiles.add),\n        icon: const Icon(Icons.add_rounded),\n      ),\n", ""),
        ("        actions: [\n          IconButton(\n            onPressed: () => ref.read(foregroundProfilesUpdateNotifierProvider.notifier).trigger(),\n",
         "        actions: [\n          IconButton(\n            onPressed: () async => await ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile(),\n"
         "            icon: const Icon(Icons.add_rounded),\n            tooltip: t.pages.profiles.add,\n          ),\n"
         "          IconButton(\n            onPressed: () => ref.read(foregroundProfilesUpdateNotifierProvider.notifier).trigger(),\n"),
        ("          itemBuilder: (context, index) => ProfileTile(key: ValueKey(data[index].id), profile: data[index]),\n",
         "          itemBuilder: (context, index) => MyTabProfile(key: ValueKey(data[index].id), profile: data[index]),\n"),
        ("          padding: const EdgeInsets.all(12).copyWith(bottom: 84),\n", "          padding: const EdgeInsets.all(12).copyWith(bottom: 24),\n"),
        ("import 'package:flutter/material.dart';\n",
         "import 'package:flutter/material.dart';\nimport 'package:hiddify/features/profile/widget/myvpn_profile_extras.dart';\n"),
    ]:
        assert s.count(a) == 1, a.strip()[:50]
        s = s.replace(a, b)
    return s
edit("lib/features/profile/overview/profiles_page.dart", tab_page)

# 8. Экран запуска: туннель на тёмном фоне
import zlib, struct
def png(path, w, h, px):
    raw = b"".join(b"\x00" + b"".join(px(x, y) for x in range(w)) for y in range(h))
    def ch(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                           + ch(b"IDAT", zlib.compress(raw, 9)) + ch(b"IEND", b""))
def inside(x, y):  # единицы 0..64
    if y > 62 or y < 0: return False
    d1 = ((x - 32) ** 2 + (y - 34) ** 2) ** .5
    outer = (y >= 34 and (0 <= x <= 12 or 52 <= x <= 64)) or (y < 34 and 20 <= d1 <= 32)
    d2 = ((x - 32) ** 2 + (y - 36) ** 2) ** .5
    d3 = ((x - 32) ** 2 + (y - 37) ** 2) ** .5
    inner = (y <= 36 and d2 <= 12 and d3 >= 4) or (y > 36 and (20 <= x <= 28 or 36 <= x <= 44))
    return outer or inner
def launch(size, path):
    g = size * 0.5; off = (size - g) / 2; ss = 3
    def px(x, y):
        hit = sum(inside((x + (a + .5) / ss - off) * 64 / g, (y + (b + .5) / ss - off) * 64 / g + 1) for a in range(ss) for b in range(ss))
        return bytes((0x22, 0xD3, 0xEE, round(255 * hit / ss / ss)))
    png(path, size, size, px)
    print("✅", path)
d = "ios/Runner/Assets.xcassets/LaunchImage.imageset/"
for sz, f in [(256, "LaunchImage.png"), (512, "LaunchImage@2x.png"), (768, "LaunchImage@3x.png")]:
    launch(sz, d + f)
png("ios/Runner/Assets.xcassets/LaunchBackground.imageset/background.png", 1, 1, lambda x, y: bytes((0x0F, 0x17, 0x2A, 255)))

print("✅ экран запуска")

# Проверка: в текстах интерфейса не осталось «Hiddify»
left = [f for f in glob.glob("assets/translations/*.i18n.json") if "Hiddify" in open(f, encoding="utf-8").read()]
assert not left, f"остался Hiddify: {left}"
print("✅ ребрендинг применён:", app)
PY
