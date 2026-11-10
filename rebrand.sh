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

# 3. Тексты интерфейса на всех языках
for f in sorted(glob.glob("assets/translations/*.i18n.json")):
    edit(f, lambda s: s.replace("Hiddify", app))

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
