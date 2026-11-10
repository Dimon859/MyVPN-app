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

# Проверка: в текстах интерфейса не осталось «Hiddify»
left = [f for f in glob.glob("assets/translations/*.i18n.json") if "Hiddify" in open(f, encoding="utf-8").read()]
assert not left, f"остался Hiddify: {left}"
print("✅ ребрендинг применён:", app)
PY
