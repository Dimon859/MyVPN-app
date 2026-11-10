#!/usr/bin/env bash
# MyVPN: замена всего видимого «Hiddify» при сборке (код форка остаётся как у оригинала)
set -euo pipefail
APPNAME="${APPNAME:-MyVPN}"
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

# 12. Окно «Добавить профиль»: убрать «Бесплатно» и «Справка» (нижняя строка)
def addprofile(s):
    for a, b in [
        ("              const NavBar(),\n", "              const Gap(24),\n"),
        ("AddProfileModalConst.navBarHeight + 32;", "24 + 32;"),
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
const _myUserAgents = {
  '': 'Стандартный',
  'Happ/3.5.0': 'Happ',
  'v2rayNG/1.10.5': 'v2rayNG',
  'Karing/1.1.2': 'Karing',
  'sing-box 1.12.0': 'sing-box',
  'clash.meta': 'Clash Meta',
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
