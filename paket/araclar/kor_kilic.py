#!/usr/bin/env python3
"""Kor Kılıç — dokuları, Minecraft modelini ve Blockbench kaynağını üretir.

Yalnız Python 3 standart kütüphanesi kullanılır; çıktı deterministiktir (aynı
kod → bire bir aynı dosyalar). Çalıştırma (depo kökünden):

    python3 paket/araclar/kor_kilic.py [--cikti DİZİN]

--cikti verilirse dosyalar paket/ yerine DİZİN/kaynak ve DİZİN/modeller altına
yazılır (testler, depodaki dosyaların üreticiyle aynı olduğunu böyle denetler).

Üretilenler:
    paket/kaynak/assets/kami/textures/item/kor_kilic_govde.png   (16×16, sabit)
    paket/kaynak/assets/kami/textures/item/kor_kilic_alev.png    (16×128, 8 kare animasyon)
    paket/kaynak/assets/kami/textures/item/kor_kilic_alev.png.mcmeta
    paket/kaynak/assets/kami/models/item/kor_kilic.json          (3B model, parlayan parçalar)
    paket/kaynak/assets/kami/items/kor_kilic.json                (eşya tanımı, 1.21.4+ biçimi)
    paket/modeller/kor_kilic.bbmodel                             (Blockbench'te açılır, dokular gömülü)

Model dikey kurulur (bıçak +Y yönünde) ve eldeki duruşu vanilla kılıç gibi
olsun diye görüntü (display) açıları vanilla "handheld" değerlerinden türetilir:
vanilla sprite'ın bıçağı 45° çapraz olduğundan her Z açısından 45 çıkarılır
(Minecraft dönüşü X·Y·Z sırasıyla uygular; Rz en içte olduğu için bu yeterlidir).
"""

import base64
import json
import math
import os
import struct
import uuid
import zlib

KOK = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
NS = "kami"
AD = "kor_kilic"

KARE_SAYISI = 8          # alev animasyonu kare sayısı
KARE_SURESI = 3          # tick (1 tick = 1/20 sn); interpolate ile yumuşak geçiş


# --------------------------------------------------------------------------
# PNG yazıcı (stdlib)
# --------------------------------------------------------------------------
def png_bytes(genislik, yukseklik, pikseller):
    """pikseller: satır satır (r,g,b,a) listesi."""
    ham = bytearray()
    for y in range(yukseklik):
        ham.append(0)  # filtre: yok
        for x in range(genislik):
            ham.extend(pikseller[y * genislik + x])

    def parca(tip, veri):
        return (struct.pack(">I", len(veri)) + tip + veri
                + struct.pack(">I", zlib.crc32(tip + veri) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", genislik, yukseklik, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + parca(b"IHDR", ihdr)
            + parca(b"IDAT", zlib.compress(bytes(ham), 9)) + parca(b"IEND", b""))


def hex_rgb(h, a=255):
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)


def karistir(r1, r2, t):
    return tuple(round(a + (b - a) * t) for a, b in zip(r1, r2))


def rampa(renkler, t):
    """t∈[0,1] → renk rampasında doğrusal ara renk."""
    t = max(0.0, min(1.0, t))
    konum = t * (len(renkler) - 1)
    i = min(int(konum), len(renkler) - 2)
    return karistir(renkler[i], renkler[i + 1], konum - i)


# --------------------------------------------------------------------------
# Dokular
# --------------------------------------------------------------------------
MAGMA = [hex_rgb(c) for c in ("#2a0a05", "#5c1106", "#9e2508", "#e0520c", "#ff9a1f", "#ffe6a1")]
NETHERIT = [hex_rgb(c) for c in ("#1c1719", "#2b2327", "#3b3036")]


def akis(x, y, kare):
    """Yukarı akan, dikeyde 16 piksel periyotlu magma yoğunluğu (0..1).

    Her kare deseni 16/KARE_SAYISI piksel yukarı kaydırır → döngü dikişsizdir.
    """
    kayma = kare * 16 / KARE_SAYISI
    v = (y + kayma) / 16.0 * 2 * math.pi
    d = (0.50
         + 0.28 * math.sin(v)
         + 0.16 * math.sin(2 * v + 1.7 + x * 0.9)
         + 0.10 * math.sin(3 * v + x * 2.3 + 0.4))
    return max(0.0, min(1.0, d))


def alev_dokusu():
    """16×(16·KARE) animasyonlu bıçak dokusu.

    Sütun 6 ve 8: netherit kenar (sıcak yerlerde çatlaktan sızan kor),
    sütun 7: akan magma çekirdeği, sütun 11: bıçağın yan yüzü (orta parlaklık).
    Diğer pikseller de magma ile doldurulur (uç parçalar oradan örnekler).
    """
    g, h = 16, 16 * KARE_SAYISI
    pik = []
    for yy in range(h):
        kare, y = divmod(yy, 16)
        for x in range(g):
            d = akis(x, y, kare)
            if x in (6, 8):
                if d > 0.78:
                    renk = rampa(MAGMA, 0.45 + (d - 0.78) * 1.6)   # çatlaktan sızan kor
                else:
                    renk = rampa(NETHERIT, (y % 5) / 6 + d * 0.3)
            elif x == 7:
                renk = rampa(MAGMA, 0.35 + d * 0.65)
            elif x == 11:
                renk = rampa(MAGMA, 0.20 + d * 0.55)
            else:
                renk = rampa(MAGMA, 0.25 + d * 0.70)
            pik.append(renk)
    return g, h, pik


def govde_dokusu():
    """16×16 sabit doku; bölgeler:
    x0-8 y0-4  : obsidyen kabza koruması + kor süsleme
    x0-4 y4-8  : kabza topuzu (koyu metal)
    x4-8 y4-8  : kor taşı (parlak)
    x0-2 y8-16 : deri sap (sarım bantlı)
    x8-16      : yedek/boş (koyu metal)
    """
    obsidyen = [hex_rgb(c) for c in ("#1b1325", "#261a33", "#33224a")]
    susleme = [hex_rgb(c) for c in ("#8a3a10", "#c8651b", "#f0a030")]
    metal = [hex_rgb(c) for c in ("#2e2c33", "#3c3a40", "#56535c", "#6e6a75")]
    deri = [hex_rgb(c) for c in ("#2a1a11", "#3a2418", "#4a2e1f", "#6b4430")]
    tas = [hex_rgb(c) for c in ("#b3380a", "#ff7a18", "#ffb347", "#ffe08a")]
    pik = []
    for y in range(16):
        for x in range(16):
            if y < 4 and x < 8:
                if y in (0, 3):
                    renk = susleme[1 + (x % 2)]            # üst/alt kor şeridi
                else:
                    renk = obsidyen[(x * 3 + y * 5) % 3]
            elif 4 <= y < 8 and x < 4:
                kenar = x in (0, 3) or y in (4, 7)
                renk = metal[1] if kenar else metal[2 + ((x + y) % 2)]
            elif 4 <= y < 8 and x < 8:
                cx, cy = x - 5.5, y - 5.5
                r = math.hypot(cx, cy)
                renk = tas[3] if r < 0.8 else tas[2] if r < 1.5 else tas[1] if r < 2.1 else tas[0]
            elif y >= 8 and x < 2:
                renk = deri[3] if (y + x) % 3 == 0 else deri[1 + (y % 2)]   # çapraz sarım
            else:
                renk = metal[1]                          # kullanılmayan alan
            pik.append(renk)
    return 16, 16, pik


# --------------------------------------------------------------------------
# Model
# --------------------------------------------------------------------------
# Bölgeler: doku adı + (u0, v0, u1, v1) içinden, yüz boyutu kadar parça alınır.
GOVDE, ALEV = "govde", "alev"
BOLGE = {
    "susleme": (GOVDE, (0, 0, 8, 4)),
    "topuz": (GOVDE, (0, 4, 4, 8)),
    "tas": (GOVDE, (4, 4, 8, 8)),
    "sap": (GOVDE, (0, 8, 2, 16)),
    "bicak_on": (ALEV, (6, 1, 9, 15)),     # 3 sütun: kenar/çekirdek/kenar
    "bicak_yan": (ALEV, (11, 1, 12, 15)),
    "magma": (ALEV, (0, 0, 16, 16)),
}

# Kabzanın vanilla kılıç sprite'ındaki tutma noktasına (≈ merkezden 7.07 birim
# aşağı) denk gelmesi için model Y ekseninde kaydırılır.
KAYDIR = -2.5

# (ad, from, to, bölge-ön/arka, bölge-yan, bölge-üst/alt, ışık)
PARCALAR = [
    ("topuz_tasi", [7.5, -0.5, 7.5], [8.5, 0, 8.5], "tas", "tas", "tas", 10),
    ("topuz", [6.5, 0, 6.5], [9.5, 1.5, 9.5], "topuz", "topuz", "topuz", 0),
    ("sap", [7.25, 1.5, 7.25], [8.75, 5.5, 8.75], "sap", "sap", "topuz", 0),
    ("koruma", [4, 5.5, 7], [12, 7, 9], "susleme", "susleme", "susleme", 0),
    ("koruma_tasi_on", [7, 5.75, 6.75], [9, 6.75, 7], "tas", "tas", "tas", 12),
    ("koruma_tasi_arka", [7, 5.75, 9], [9, 6.75, 9.25], "tas", "tas", "tas", 12),
    ("koruma_ucu_sol", [3.5, 5.25, 7.25], [4.5, 7.25, 8.75], "susleme", "susleme", "susleme", 6),
    ("koruma_ucu_sag", [11.5, 5.25, 7.25], [12.5, 7.25, 8.75], "susleme", "susleme", "susleme", 6),
    ("bicak", [6.5, 7, 7.5], [9.5, 21, 8.5], "bicak_on", "bicak_yan", "magma", 15),
    ("bicak_ucu_1", [7, 21, 7.625], [9, 22.25, 8.375], "magma", "magma", "magma", 15),
    ("bicak_ucu_2", [7.5, 22.25, 7.75], [8.5, 23.25, 8.25], "magma", "magma", "magma", 15),
]


def uv_al(bolge, gen, yuk):
    """Bölgenin sol üstünden yüz boyutunda (gerekirse bölgeye sığdırılmış) UV."""
    _, (u0, v0, u1, v1) = BOLGE[bolge]
    gen = min(gen, u1 - u0)
    yuk = min(yuk, v1 - v0)
    return [u0, v0, round(u0 + gen, 4), round(v0 + yuk, 4)]


def parcalar():
    """Kaydırılmış koordinatlarla eleman listesi (yüz UV'leri dahil)."""
    liste = []
    for ad, fr, to, on, yan, ust, isik in PARCALAR:
        fr = [fr[0], round(fr[1] + KAYDIR, 4), fr[2]]
        to = [to[0], round(to[1] + KAYDIR, 4), to[2]]
        dx, dy, dz = (to[i] - fr[i] for i in range(3))
        yuzler = {
            "north": (on, dx, dy), "south": (on, dx, dy),
            "east": (yan, dz, dy), "west": (yan, dz, dy),
            "up": (ust, dx, dz), "down": (ust, dx, dz),
        }
        liste.append((ad, fr, to, yuzler, isik))
    return liste


def goruntu_ayarlari():
    """Vanilla handheld değerleri, Z açıları -45° düzeltilmiş."""
    return {
        "thirdperson_righthand": {"rotation": [0, -90, 10], "translation": [0, 4, 0.5], "scale": [0.85, 0.85, 0.85]},
        "thirdperson_lefthand": {"rotation": [0, 90, -100], "translation": [0, 4, 0.5], "scale": [0.85, 0.85, 0.85]},
        "firstperson_righthand": {"rotation": [0, -90, -20], "translation": [1.13, 3.2, 1.13], "scale": [0.68, 0.68, 0.68]},
        "firstperson_lefthand": {"rotation": [0, 90, -70], "translation": [1.13, 3.2, 1.13], "scale": [0.68, 0.68, 0.68]},
        # Kılıç 16 birimden uzun: simge yuvaya sığsın diye küçültülür, uca doğru kayık merkez düzeltilir.
        "gui": {"rotation": [0, 0, -45], "translation": [-0.5, -0.5, 0], "scale": [0.78, 0.78, 0.78]},
        "ground": {"rotation": [0, 0, -45], "translation": [0, 2, 0], "scale": [0.5, 0.5, 0.5]},
        "fixed": {"rotation": [0, 180, -45], "translation": [0, 0, 0], "scale": [0.9, 0.9, 0.9]},
        "head": {"rotation": [0, 180, -45], "translation": [0, 13, 7], "scale": [1, 1, 1]},
    }


def minecraft_modeli():
    elemanlar = []
    for ad, fr, to, yuzler, isik in parcalar():
        faces = {}
        for yon, (bolge, gen, yuk) in yuzler.items():
            doku = BOLGE[bolge][0]
            faces[yon] = {"uv": uv_al(bolge, gen, yuk), "texture": "#" + doku}
        el = {"name": ad, "from": fr, "to": to, "faces": faces}
        if isik:
            el["light_emission"] = isik
        elemanlar.append(el)
    return {
        "textures": {
            "particle": f"{NS}:item/{AD}_govde",
            GOVDE: f"{NS}:item/{AD}_govde",
            ALEV: f"{NS}:item/{AD}_alev",
        },
        "elements": elemanlar,
        "display": goruntu_ayarlari(),
    }


def esya_tanimi():
    return {"model": {"type": "minecraft:model", "model": f"{NS}:item/{AD}"}}


def bb_uuid(ad):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"kami/{AD}/{ad}"))


def blockbench_modeli(govde_png, alev_png):
    doku_sira = [GOVDE, ALEV]
    elemanlar, outliner = [], []
    for ad, fr, to, yuzler, isik in parcalar():
        faces = {}
        for yon, (bolge, gen, yuk) in yuzler.items():
            faces[yon] = {"uv": uv_al(bolge, gen, yuk), "texture": doku_sira.index(BOLGE[bolge][0])}
        u = bb_uuid(ad)
        el = {
            "name": ad, "box_uv": False, "render_order": "default", "rescale": False,
            "locked": False, "light_emission": isik,
            "from": fr, "to": to, "autouv": 0, "color": PARCALAR.index(next(p for p in PARCALAR if p[0] == ad)) % 8,
            "origin": [8, 8, 8], "faces": faces, "type": "cube", "uuid": u,
        }
        elemanlar.append(el)
        outliner.append(u)

    def doku(ad, png, yukseklik, animasyon):
        d = {
            "path": "", "name": f"{AD}_{ad}.png", "folder": "item", "namespace": NS,
            "id": str(doku_sira.index(ad)), "width": 16, "height": yukseklik,
            "uv_width": 16, "uv_height": 16, "particle": ad == GOVDE,
            "use_as_default": False, "layers_enabled": False, "sync_to_project": "",
            "render_mode": "default", "render_sides": "auto",
            "frame_time": KARE_SURESI if animasyon else 1, "frame_order_type": "loop",
            "frame_order": "", "frame_interpolate": animasyon,
            "visible": True, "internal": True, "saved": True, "uuid": bb_uuid("doku_" + ad),
            "source": "data:image/png;base64," + base64.b64encode(png).decode(),
        }
        return d

    return {
        "meta": {"format_version": "5.0", "model_format": "java_block", "box_uv": False},
        "name": AD,
        "parent": "",
        "ambientocclusion": True,
        "front_gui_light": False,
        "visible_box": [1, 1, 0],
        "resolution": {"width": 16, "height": 16},
        "elements": elemanlar,
        "outliner": outliner,
        "textures": [doku(GOVDE, govde_png, 16, False), doku(ALEV, alev_png, 16 * KARE_SAYISI, True)],
        "display": goruntu_ayarlari(),
    }


# --------------------------------------------------------------------------
def yaz(yol, veri):
    os.makedirs(os.path.dirname(yol), exist_ok=True)
    kip = "wb" if isinstance(veri, bytes) else "w"
    with open(yol, kip, **({} if kip == "wb" else {"encoding": "utf-8", "newline": "\n"})) as f:
        f.write(veri)


def json_metni(nesne):
    return json.dumps(nesne, ensure_ascii=False, indent=2) + "\n"


def main():
    import argparse
    ap = argparse.ArgumentParser(description="Kor Kılıç varlıklarını üretir.")
    ap.add_argument("--cikti", default=KOK, help="çıktı kökü (varsayılan: paket/)")
    kok = ap.parse_args().cikti
    tex_dir = os.path.join(kok, "kaynak", "assets", NS, "textures", "item")
    model_dir = os.path.join(kok, "kaynak", "assets", NS, "models", "item")
    items_dir = os.path.join(kok, "kaynak", "assets", NS, "items")
    bb_dir = os.path.join(kok, "modeller")

    g, h, pik = govde_dokusu()
    govde_png = png_bytes(g, h, pik)
    g, h, pik = alev_dokusu()
    alev_png = png_bytes(g, h, pik)

    yaz(os.path.join(tex_dir, f"{AD}_govde.png"), govde_png)
    yaz(os.path.join(tex_dir, f"{AD}_alev.png"), alev_png)
    yaz(os.path.join(tex_dir, f"{AD}_alev.png.mcmeta"),
        json_metni({"animation": {"frametime": KARE_SURESI, "interpolate": True}}))
    yaz(os.path.join(model_dir, f"{AD}.json"), json_metni(minecraft_modeli()))
    yaz(os.path.join(items_dir, f"{AD}.json"), json_metni(esya_tanimi()))
    yaz(os.path.join(bb_dir, f"{AD}.bbmodel"), json_metni(blockbench_modeli(govde_png, alev_png)))
    print(f"{AD}: dokular, model, eşya tanımı ve Blockbench dosyası üretildi.")


if __name__ == "__main__":
    main()
