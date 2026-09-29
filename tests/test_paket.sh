#!/usr/bin/env bash
# Kaynak paketi testleri: doğrulayıcı, üretici çıktısının depoyla aynılığı,
# zip'in deterministik olması ve doğrulayıcının bozuk modeli reddetmesi.
# Yalnız python3 (stdlib) gerekir.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
pass=0 fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
nok()  { printf '  HATA %s\n' "$1"; fail=$((fail + 1)); }
check() { local ad=$1; shift; if "$@" >/dev/null 2>&1; then ok "$ad"; else nok "$ad"; fi; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf '== 1. doğrulayıcı\n'
check "depodaki paket doğrulanır" python3 "$ROOT/paket/araclar/paketle.py" --denetle

printf '== 2. üretici ↔ depo\n'
python3 "$ROOT/paket/araclar/kor_kilic.py" --cikti "$tmp/uret" >/dev/null
check "kor_kilic varlıkları depodakiyle aynı" diff -r "$tmp/uret/kaynak/assets" "$ROOT/paket/kaynak/assets"
check "kor_kilic.bbmodel depodakiyle aynı" cmp "$tmp/uret/modeller/kor_kilic.bbmodel" "$ROOT/paket/modeller/kor_kilic.bbmodel"
check "bbmodel geçerli JSON ve Java blok biçimi" python3 -c '
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m["meta"]["model_format"] == "java_block"
assert all(t["source"].startswith("data:image/png;base64,") for t in m["textures"])
assert len(m["elements"]) == len(m["outliner"])
' "$ROOT/paket/modeller/kor_kilic.bbmodel"

printf '== 3. zip\n'
cp -r "$ROOT/paket" "$tmp/p1" && rm -rf "$tmp/p1/dist"
python3 "$tmp/p1/araclar/paketle.py" >"$tmp/z1.txt"
python3 "$tmp/p1/araclar/paketle.py" >"$tmp/z2.txt"
check "aynı içerik → aynı SHA-1" diff <(grep sha1 "$tmp/z1.txt") <(grep sha1 "$tmp/z2.txt")
check "SHA-1 40 onaltılık hane" grep -Eq '^resource-pack-sha1=[0-9a-f]{40}$' "$tmp/z1.txt"
check "zip içinde pack.mcmeta kökte" python3 -c '
import sys, zipfile
assert "pack.mcmeta" in zipfile.ZipFile(sys.argv[1]).namelist()
' "$tmp/p1/dist/kami-paket.zip"

printf '== 4. bozuk paket reddedilir\n'
cp -r "$ROOT/paket" "$tmp/p2" && rm -rf "$tmp/p2/dist"
python3 - "$tmp/p2/kaynak/assets/kami/models/item/kor_kilic.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m["elements"][0]["shade"] = False
json.dump(m, open(sys.argv[1], "w"))
PY
if python3 "$tmp/p2/araclar/paketle.py" --denetle >/dev/null 2>&1; then nok "shade içeren model reddedilir"; else ok "shade içeren model reddedilir"; fi
if [[ -e $tmp/p2/dist/kami-paket.zip ]]; then nok "hatalı pakette zip yazılmaz"; else ok "hatalı pakette zip yazılmaz"; fi
cp -r "$ROOT/paket" "$tmp/p3" && rm -rf "$tmp/p3/dist"
python3 - "$tmp/p3/kaynak/pack.mcmeta" <<'PY'
import json, sys
json.dump({"pack": {"description": "x", "pack_format": 46}}, open(sys.argv[1], "w"))
PY
if python3 "$tmp/p3/araclar/paketle.py" --denetle >/dev/null 2>&1; then nok "eski pack_format reddedilir"; else ok "eski pack_format reddedilir"; fi
rm -f "$tmp/p3/kaynak/assets/kami/textures/item/kor_kilic_govde.png"
if python3 "$tmp/p3/araclar/paketle.py" --denetle >/dev/null 2>&1; then nok "eksik doku reddedilir"; else ok "eksik doku reddedilir"; fi

printf '\nSonuç: %d başarılı, %d başarısız\n' "$pass" "$fail"
((fail == 0))
