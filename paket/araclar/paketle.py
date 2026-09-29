#!/usr/bin/env python3
"""Kaynak paketini doğrular ve deterministik bir zip üretir (yalnız stdlib).

Kullanım (depo kökünden):
    python3 paket/araclar/paketle.py            # doğrula + paket/dist/kami-paket.zip
    python3 paket/araclar/paketle.py --denetle  # yalnız doğrula (zip yazmaz)

Doğrulananlar:
  - pack.mcmeta: min_format / max_format var ve 26.2 (88.0) aralıkta
  - items/*.json → işaret ettiği model dosyası pakette var
  - models/**.json → parent ve dokular (minecraft: dışı) pakette var; elemanlar
    -16..32 sınırında; light_emission 0..15; 26.3'te kaldırılan "shade" yok
  - animasyonlu dokular: yükseklik genişliğin katı; .mcmeta geçerli JSON
  - PNG dosyaları gerçekten PNG
Zip: dosyalar sıralı, sabit zaman damgalı → aynı içerik = aynı SHA-1
(sunucunun server.properties'teki resource-pack-sha1 değeri buna göre verilir).
"""

import argparse
import hashlib
import json
import os
import struct
import sys
import zipfile

KOK = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
KAYNAK = os.path.join(KOK, "kaynak")
DIST = os.path.join(KOK, "dist")
ZIP_ADI = "kami-paket.zip"
FORMAT_26_2 = (88, 0)
SABIT_ZAMAN = (2026, 1, 1, 0, 0, 0)

hatalar = []


def hata(yol, mesaj):
    hatalar.append(f"{os.path.relpath(yol, KOK)}: {mesaj}")


def format_coz(deger):
    if isinstance(deger, int):
        return (deger, 0)
    if isinstance(deger, list) and len(deger) in (1, 2) and all(isinstance(v, int) for v in deger):
        return (deger[0], deger[1] if len(deger) == 2 else 0)
    return None


def json_oku(yol):
    try:
        with open(yol, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        hata(yol, f"geçersiz JSON ({e})")
        return None


def kaynak(ref, klasor, uzanti):
    ns, yol = ref.split(":", 1) if ":" in ref else ("minecraft", ref)
    return ns, os.path.join(KAYNAK, "assets", ns, klasor, yol + uzanti)


def png_boyutu(yol):
    with open(yol, "rb") as f:
        bas = f.read(24)
    if bas[:8] != b"\x89PNG\r\n\x1a\n" or bas[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", bas[16:24])


def pack_mcmeta_denetle():
    yol = os.path.join(KAYNAK, "pack.mcmeta")
    veri = json_oku(yol)
    if not veri:
        return
    pack = veri.get("pack", {})
    mn, mx = format_coz(pack.get("min_format")), format_coz(pack.get("max_format"))
    if not mn or not mx:
        hata(yol, "pack.min_format / pack.max_format eksik ya da geçersiz (1.21.9+ zorunlu)")
    elif not (mn <= FORMAT_26_2 <= mx):
        hata(yol, f"26.2 formatı {FORMAT_26_2} aralıkta değil: {mn}..{mx}")


def model_denetle(yol, gorulen):
    if yol in gorulen:
        return
    gorulen.add(yol)
    model = json_oku(yol)
    if not model:
        return
    parent = model.get("parent")
    if parent and not parent.startswith("builtin/"):
        ns, p = kaynak(parent, "models", ".json")
        if ns != "minecraft":
            if os.path.exists(p):
                model_denetle(p, gorulen)
            else:
                hata(yol, f"parent bulunamadı: {parent}")
    for anahtar, ref in model.get("textures", {}).items():
        if ref.startswith("#"):
            continue
        ns, p = kaynak(ref, "textures", ".png")
        if ns != "minecraft" and not os.path.exists(p):
            hata(yol, f"doku bulunamadı ({anahtar}): {ref}")
    for i, el in enumerate(model.get("elements", [])):
        ad = el.get("name", f"#{i}")
        for k in ("from", "to"):
            v = el.get(k)
            if not (isinstance(v, list) and len(v) == 3 and all(-16 <= c <= 32 for c in v)):
                hata(yol, f"eleman {ad}: '{k}' -16..32 dışında ya da hatalı: {v}")
        if "shade" in el:
            hata(yol, f"eleman {ad}: 'shade' 26.3'te kaldırıldı; kullanmayın")
        le = el.get("light_emission", 0)
        if not (isinstance(le, int) and 0 <= le <= 15):
            hata(yol, f"eleman {ad}: light_emission 0..15 tam sayı olmalı: {le}")
        for yon, yuz in el.get("faces", {}).items():
            t = yuz.get("texture", "")
            if not t.startswith("#") or t[1:] not in model.get("textures", {}):
                hata(yol, f"eleman {ad}/{yon}: tanımsız doku değişkeni {t}")


def items_denetle():
    gorulen = set()
    for kok, _, dosyalar in os.walk(os.path.join(KAYNAK, "assets")):
        if os.path.basename(kok) != "items" and "/items/" not in kok + "/":
            continue
        for d in sorted(dosyalar):
            if not d.endswith(".json"):
                continue
            yol = os.path.join(kok, d)
            veri = json_oku(yol)
            if not veri:
                continue
            refs = []

            def topla(n):
                if isinstance(n, dict):
                    if n.get("type") in ("minecraft:model", "model") and "model" in n:
                        refs.append(n["model"])
                    for v in n.values():
                        topla(v)
                elif isinstance(n, list):
                    for v in n:
                        topla(v)
            topla(veri.get("model"))
            if not refs:
                hata(yol, "hiç model referansı yok")
            for ref in refs:
                ns, p = kaynak(ref, "models", ".json")
                if ns == "minecraft":
                    continue
                if os.path.exists(p):
                    model_denetle(p, gorulen)
                else:
                    hata(yol, f"model bulunamadı: {ref}")


def dokular_denetle():
    for kok, _, dosyalar in os.walk(KAYNAK):
        for d in sorted(dosyalar):
            yol = os.path.join(kok, d)
            if d.endswith(".png"):
                boyut = png_boyutu(yol)
                if not boyut:
                    hata(yol, "PNG değil")
                    continue
                if os.path.exists(yol + ".mcmeta"):
                    g, h = boyut
                    if h % g:
                        hata(yol, f"animasyonlu dokuda yükseklik ({h}) genişliğin ({g}) katı değil")
            elif d.endswith(".mcmeta") and d != "pack.mcmeta":
                veri = json_oku(yol)
                if veri is not None and not os.path.exists(yol[:-7]):
                    hata(yol, "ait olduğu PNG yok")


def zip_yaz():
    os.makedirs(DIST, exist_ok=True)
    hedef = os.path.join(DIST, ZIP_ADI)
    dosyalar = []
    for kok, _, adlar in os.walk(KAYNAK):
        for a in adlar:
            tam = os.path.join(kok, a)
            dosyalar.append((os.path.relpath(tam, KAYNAK).replace(os.sep, "/"), tam))
    gecici = hedef + ".tmp"
    with zipfile.ZipFile(gecici, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for ic_yol, tam in sorted(dosyalar):
            bilgi = zipfile.ZipInfo(ic_yol, SABIT_ZAMAN)
            bilgi.compress_type = zipfile.ZIP_DEFLATED
            bilgi.external_attr = 0o644 << 16
            with open(tam, "rb") as f:
                z.writestr(bilgi, f.read())
    os.replace(gecici, hedef)
    with open(hedef, "rb") as f:
        veri = f.read()
    return hedef, hashlib.sha1(veri).hexdigest(), len(veri)


def main():
    ap = argparse.ArgumentParser(description="Kaynak paketini doğrula ve zip'le.")
    ap.add_argument("--denetle", action="store_true", help="yalnız doğrula")
    args = ap.parse_args()

    pack_mcmeta_denetle()
    items_denetle()
    dokular_denetle()
    if hatalar:
        for h in hatalar:
            print(f"[hata] {h}", file=sys.stderr)
        print(f"{len(hatalar)} hata; paket oluşturulmadı.", file=sys.stderr)
        return 1
    print("[tamam] paket doğrulandı")
    if args.denetle:
        return 0
    yol, sha1, boyut = zip_yaz()
    print(f"[tamam] {os.path.relpath(yol, os.path.dirname(KOK))} ({boyut / 1024:.1f} KiB)")
    print(f"resource-pack-sha1={sha1}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
