#!/usr/bin/env python3
"""BetterModel .bbmodel dosyalarını doğrular (yalnız stdlib).

    python3 paket/araclar/bb_denetle.py [dosya.bbmodel ...]
Dosya verilmezse paket/bettermodel/{models,players}/*.bbmodel denetlenir.

Denetlenenler (BetterModel'in ModelData okuyucusunun beklediği yapı):
  - meta.model_format "free" (Generic Model); zorunlu alanlar: meta, resolution,
    elements, outliner, textures
  - outliner ağacındaki her uuid bir gruba ya da küpe karşılık gelir; her küp bir kez yer alır
  - animasyonlar: loop ∈ {loop, once, hold}; her animator bir gruba bağlı; anahtar kare kanalı,
    ara değerleme türü ve zamanı (0..length) geçerli; değerler sayı
  - dokular: gömülü PNG, yükseklik genişliğin katı (animasyon kareleri); yüzlerin doku indeksi geçerli
Çıkış: 0 sorunsuz, 1 hata var.
"""

import base64
import glob
import json
import os
import struct
import sys

KOK = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
KANAL = {"rotation", "position", "scale"}
ARA = {"linear", "catmullrom", "step", "bezier"}
DONGU = {"loop", "once", "hold"}


def denetle(yol):
    hatalar = []

    def h(m):
        hatalar.append(m)

    try:
        with open(yol, encoding="utf-8") as f:
            m = json.load(f)
    except (OSError, ValueError) as e:
        return [f"okunamadı: {e}"]
    for k in ("meta", "resolution", "elements", "outliner", "textures"):
        if k not in m:
            h(f"zorunlu alan yok: {k}")
    if hatalar:
        return hatalar
    if m["meta"].get("model_format") != "free":
        h(f"model_format 'free' (Generic Model) olmalı: {m['meta'].get('model_format')}")

    gruplar = {g["uuid"]: g for g in m.get("groups", [])}
    kupler = {e["uuid"]: e for e in m["elements"]}
    gorulen = set()

    def gez(dugumler):
        for d in dugumler:
            if isinstance(d, dict):
                if d.get("uuid") not in gruplar:
                    h(f"outliner: tanımsız grup {d.get('uuid')}")
                gez(d.get("children", []))
            else:
                if d not in kupler:
                    h(f"outliner: tanımsız küp {d}")
                elif d in gorulen:
                    h(f"outliner: küp iki kez: {kupler[d].get('name')}")
                gorulen.add(d)
    gez(m["outliner"])

    for i, t in enumerate(m["textures"]):
        src = t.get("source", "")
        if not src.startswith("data:image/png;base64,"):
            h(f"doku {i}: gömülü PNG değil")
            continue
        png = base64.b64decode(src.split(",", 1)[1])
        if png[:8] != b"\x89PNG\r\n\x1a\n":
            h(f"doku {i}: PNG imzası yok")
            continue
        g, y = struct.unpack(">II", png[16:24])
        if (g, y) != (t.get("width"), t.get("height")):
            h(f"doku {i}: boyut uyuşmuyor (PNG {g}x{y}, bildirilen {t.get('width')}x{t.get('height')})")
        if y % g:
            h(f"doku {i}: yükseklik genişliğin katı değil ({g}x{y})")

    for e in m["elements"]:
        for yon, f in e.get("faces", {}).items():
            tx = f.get("texture")
            if tx is not None and not (isinstance(tx, int) and 0 <= tx < len(m["textures"])):
                h(f"küp {e.get('name')}/{yon}: geçersiz doku indeksi {tx}")

    for a in m.get("animations", []):
        ad = a.get("name")
        if a.get("loop") not in DONGU:
            h(f"animasyon {ad}: loop geçersiz ({a.get('loop')})")
        uz = a.get("length", 0)
        for u, an in (a.get("animators") or {}).items():
            if u not in gruplar:
                h(f"animasyon {ad}: animator tanımsız gruba bağlı ({an.get('name')})")
            for k in an.get("keyframes", []):
                if k.get("channel") not in KANAL:
                    h(f"animasyon {ad}/{an.get('name')}: kanal geçersiz {k.get('channel')}")
                if k.get("interpolation") not in ARA:
                    h(f"animasyon {ad}/{an.get('name')}: ara değerleme geçersiz {k.get('interpolation')}")
                if not (0 <= k.get("time", -1) <= uz + 1e-6):
                    h(f"animasyon {ad}/{an.get('name')}: zaman {k.get('time')} 0..{uz} dışında")
                for dp in k.get("data_points", []):
                    for e in "xyz":
                        try:
                            float(dp[e])
                        except (KeyError, ValueError):
                            h(f"animasyon {ad}/{an.get('name')}: sayı olmayan değer {dp.get(e)!r}")
    return hatalar


def main():
    dosyalar = sys.argv[1:] or sorted(glob.glob(os.path.join(KOK, "bettermodel", "*", "*.bbmodel")))
    dosyalar = [d for d in dosyalar if os.sep + "sablon" + os.sep not in d] or dosyalar
    hata_var = False
    for d in dosyalar:
        hatalar = denetle(d)
        ad = os.path.relpath(d, os.path.dirname(KOK))
        if hatalar:
            hata_var = True
            for x in hatalar:
                print(f"[hata] {ad}: {x}", file=sys.stderr)
        else:
            print(f"[tamam] {ad}")
    return 1 if hata_var else 0


if __name__ == "__main__":
    sys.exit(main())
