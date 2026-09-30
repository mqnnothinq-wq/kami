#!/usr/bin/env python3
"""BetterModel için animasyonlu modeller üretir (yalnız Python stdlib, deterministik).

    python3 paket/araclar/bettermodel.py [--cikti DİZİN]

Üretilenler (varsayılan paket/bettermodel/ altına):
    models/kor_kristali.bbmodel   Lobi süsü: kaide + dönüp süzülen, parlayan kristal +
                                  ters yönde dönen parçalar ("idle" döngüsü, "spawn")
    players/kami_emote.bbmodel    Oyuncu emote'ları: selam, zafer, dans
                                  (BetterModel'in steve.bbmodel kalıbı üzerine; MIT)

Sunucuda: models/ → plugins/BetterModel/models/, players/ → plugins/BetterModel/players/,
sonra /bettermodel reload. Deneme: /bettermodel spawn kor_kristali,
/bettermodel play kami_emote selam.

Blockbench kuralları (kaynak koddan doğrulandı):
  - Generic Model ("free") biçimi, Euler sırası ZYX; animasyon dönüşü kemiğin kendi
    dönüşüne derece olarak EKLENİR (işaret çevrilmez), konum ebeveyn uzayında eklenir,
    ölçek kemik pivotunda çarpılır.
  - Steve kalıbı kuzeye (-z) bakar; sağ kol +x tarafındadır. Bu yüzden:
    kol X +θ → öne/yukarı, sağ kol Z +θ → yana/yukarı (sol kol için Z -θ),
    kafa X +θ → yukarı bakar, bacak X +θ → öne, diz (alt bacak) X -θ → geriye bükülür.
BetterModel: adı "glow_" ile başlayan grup/küp tam parlak çizilir; "idle" kendiliğinden oynar.
"""

import argparse
import base64
import copy
import json
import math
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kor_kilic import hex_rgb, karistir, png_bytes, rampa  # noqa: E402  (aynı dizindeki üretici)

KOK = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SABLON = os.path.join(KOK, "bettermodel", "sablon", "steve.bbmodel")


def uid(*parcalar):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "kami/bettermodel/" + "/".join(parcalar)))


def sayi(v):
    """Keyframe değerleri Blockbench'te metin; gereksiz ondalık yazma."""
    v = round(float(v), 4)
    return str(int(v)) if v == int(v) else str(v)


def anahtar_kare(anim, kemik, kanal, i, zaman, xyz, ara="catmullrom"):
    return {
        "channel": kanal,
        "data_points": [{"x": sayi(xyz[0]), "y": sayi(xyz[1]), "z": sayi(xyz[2])}],
        "uuid": uid(anim, kemik, kanal, str(i)),
        "time": round(zaman, 5),
        "color": -1,
        "interpolation": ara,
    }


def animasyon(ad, uzunluk, dongu, kemikler, tanim, ara="catmullrom"):
    """tanim: {kemik_adı: {kanal: [(zaman, (x, y, z)), ...]}}; kemikler: ad → uuid."""
    animators = {}
    for kemik, kanallar in tanim.items():
        kareler = []
        for kanal, liste in kanallar.items():
            kanal_ara = ara
            if isinstance(liste, tuple):          # (liste, "linear") biçimi
                liste, kanal_ara = liste
            for i, (t, xyz) in enumerate(liste):
                kareler.append(anahtar_kare(ad, kemik, kanal, i, t, xyz, kanal_ara))
        animators[kemikler[kemik]] = {
            "name": kemik, "type": "bone", "rotation_global": False,
            "quaternion_interpolation": False, "keyframes": kareler,
        }
    return {
        "uuid": uid(ad), "name": ad, "loop": dongu, "override": False,
        "length": uzunluk, "snapping": 20, "selected": False,
        "anim_time_update": "", "blend_weight": "", "start_delay": "", "loop_delay": "",
        "animators": animators,
    }


# ==========================================================================
# 1) Oyuncu emote'ları (steve kalıbı)
# ==========================================================================
def emotelar():
    """Kemik adları steve.bbmodel'deki gruplardır (etiket önekleriyle)."""
    SAG_KOL, SAG_ON = "pra_right_arm", "prfa_right_forearm"
    SOL_KOL, SOL_ON = "pla_left_arm", "plfa_left_forearm"
    SAG_BACAK, SAG_DIZ = "prl_right_leg", "prfl_right_foreleg"
    SOL_BACAK, SOL_DIZ = "pll_left_leg", "plfl_left_foreleg"
    KOK_K, KAFA, GOGUS = "player_root", "h_ph_head", "pc_chest"
    s = 0.0

    selam = {  # 2 sn: sağ kol kalkar, ön kol sallanır, kafa hafif eğilir
        SAG_KOL: {"rotation": [(0, (0, 0, 0)), (0.25, (0, 0, 150)), (1.75, (0, 0, 150)), (2.0, (0, 0, 0))]},
        SAG_ON: {"rotation": [(0, (0, 0, 0)), (0.25, (0, 0, 15)), (0.45, (0, 0, -25)), (0.65, (0, 0, 25)),
                              (0.85, (0, 0, -25)), (1.05, (0, 0, 25)), (1.25, (0, 0, -25)), (1.45, (0, 0, 20)),
                              (1.75, (0, 0, 0)), (2.0, (0, 0, 0))]},
        SOL_KOL: {"rotation": [(0, (0, 0, 0)), (0.3, (0, 0, -8)), (1.7, (0, 0, -8)), (2.0, (0, 0, 0))]},
        KAFA: {"rotation": [(0, (0, 0, 0)), (0.3, (5, -10, 8)), (1.7, (5, -10, 8)), (2.0, (0, 0, 0))]},
        GOGUS: {"rotation": [(0, (0, 0, 0)), (0.3, (0, -8, 0)), (1.7, (0, -8, 0)), (2.0, (0, 0, 0))]},
    }

    zafer = {  # 1,8 sn: çömel, zıpla, kollar havada iki kez yumruk
        KOK_K: {"position": [(0, (0, 0, 0)), (0.25, (0, -2, 0)), (0.5, (0, 5, 0)), (0.75, (0, 0, 0)),
                             (0.9, (0, -1, 0)), (1.1, (0, 0, 0)), (1.8, (0, 0, 0))]},
        SAG_BACAK: {"rotation": [(0, (0, 0, 0)), (0.25, (30, 0, 0)), (0.5, (0, 0, 0)), (0.75, (15, 0, 0)),
                                 (0.9, (20, 0, 0)), (1.1, (0, 0, 0))]},
        SOL_BACAK: {"rotation": [(0, (0, 0, 0)), (0.25, (30, 0, 0)), (0.5, (-5, 0, 0)), (0.75, (15, 0, 0)),
                                 (0.9, (20, 0, 0)), (1.1, (0, 0, 0))]},
        SAG_DIZ: {"rotation": [(0, (0, 0, 0)), (0.25, (-60, 0, 0)), (0.5, (-10, 0, 0)), (0.75, (-30, 0, 0)),
                               (0.9, (-40, 0, 0)), (1.1, (0, 0, 0))]},
        SOL_DIZ: {"rotation": [(0, (0, 0, 0)), (0.25, (-60, 0, 0)), (0.5, (-20, 0, 0)), (0.75, (-30, 0, 0)),
                               (0.9, (-40, 0, 0)), (1.1, (0, 0, 0))]},
        SAG_KOL: {"rotation": [(0, (0, 0, 0)), (0.25, (0, 0, 20)), (0.5, (0, 0, 165)), (0.75, (0, 0, 160)),
                               (0.95, (0, 0, 140)), (1.15, (0, 0, 165)), (1.45, (0, 0, 165)), (1.8, (0, 0, 0))]},
        SOL_KOL: {"rotation": [(0, (0, 0, 0)), (0.25, (0, 0, -20)), (0.5, (0, 0, -165)), (0.75, (0, 0, -160)),
                               (0.95, (0, 0, -140)), (1.15, (0, 0, -165)), (1.45, (0, 0, -165)), (1.8, (0, 0, 0))]},
        SAG_ON: {"rotation": [(0, (0, 0, 0)), (0.75, (0, 0, 0)), (0.95, (0, 0, -30)), (1.15, (0, 0, 0))]},
        SOL_ON: {"rotation": [(0, (0, 0, 0)), (0.75, (0, 0, 0)), (0.95, (0, 0, 30)), (1.15, (0, 0, 0))]},
        KAFA: {"rotation": [(0, (0, 0, 0)), (0.5, (20, 0, 0)), (1.45, (15, 0, 0)), (1.8, (0, 0, 0))]},
        GOGUS: {"rotation": [(0, (0, 0, 0)), (0.5, (8, 0, 0)), (1.45, (6, 0, 0)), (1.8, (0, 0, 0))]},
    }

    def ritim(degerler, adim=0.5, uzunluk=2.0):
        """Eşit aralıklı döngü kareleri (son kare ilkine eşit → dikişsiz)."""
        return [(round(i * adim, 4), degerler[i % len(degerler)]) for i in range(int(uzunluk / adim) + 1)]

    dans = {  # 2 sn döngü: sağa-sola dönme, zıplama, kollar sırayla havaya, dizler sırayla
        KOK_K: {"position": ritim([(0, 0, 0), (0, -0.8, 0)], 0.25),
                "rotation": [(0, (0, -15, 0)), (1.0, (0, 15, 0)), (2.0, (0, -15, 0))]},
        SAG_KOL: {"rotation": ritim([(0, 0, 20), (0, 0, 150)])},
        SOL_KOL: {"rotation": ritim([(0, 0, -150), (0, 0, -20)])},
        SAG_ON: {"rotation": ritim([(0, 0, 0), (0, 0, 30)])},
        SOL_ON: {"rotation": ritim([(0, 0, -30), (0, 0, 0)])},
        SAG_BACAK: {"rotation": ritim([(0, 0, 0), (25, 0, 0), (0, 0, 0), (0, 0, 0)], 0.25)},
        SAG_DIZ: {"rotation": ritim([(0, 0, 0), (-40, 0, 0), (0, 0, 0), (0, 0, 0)], 0.25)},
        SOL_BACAK: {"rotation": ritim([(0, 0, 0), (0, 0, 0), (0, 0, 0), (25, 0, 0)], 0.25)},
        SOL_DIZ: {"rotation": ritim([(0, 0, 0), (0, 0, 0), (0, 0, 0), (-40, 0, 0)], 0.25)},
        KAFA: {"rotation": [(0, (0, 10, 0)), (0.5, (-6, 0, 0)), (1.0, (0, -10, 0)), (1.5, (-6, 0, 0)), (2.0, (0, 10, 0))]},
    }
    return [("selam", 2.0, "once", selam), ("zafer", 1.8, "once", zafer), ("dans", 2.0, "loop", dans)]


def emote_modeli():
    with open(SABLON, encoding="utf-8") as f:
        m = json.load(f)
    kemikler = {g["name"]: g["uuid"] for g in m["groups"]}
    m = copy.deepcopy(m)
    m["name"] = "kami_emote"
    m["animations"] = [animasyon(ad, uz, dongu, kemikler, tanim) for ad, uz, dongu, tanim in emotelar()]
    return m


# ==========================================================================
# 2) Kor Kristali (lobi süsü)
# ==========================================================================
KARE = 8           # doku animasyonu kare sayısı
KARE_SURESI = 2    # tick


def kristal_dokusu():
    """32×(32·KARE) animasyonlu atlas:
    (0,0)-(16,16)   kristal yüzeyi: amber, üzerinden çapraz bir ışıltı bandı geçer
    (16,0)-(32,16)  obsidyen kaide (sabit)
    (0,16)-(16,32)  kor rün: nabız gibi parlayıp söner
    (16,16)-(32,32) küçük parça: açık kristal, gezen kıvılcım
    """
    amber = [hex_rgb(c) for c in ("#5a1a05", "#a33a0a", "#e0680f", "#ffa52e", "#ffd978", "#fff4cf")]
    obsidyen = [hex_rgb(c) for c in ("#140d1c", "#1f1430", "#2d1f45", "#3d2a5c")]
    g, h = 32, 32 * KARE
    pik = []
    for yy in range(h):
        kare, y = divmod(yy, 32)
        faz = kare / KARE
        for x in range(g):
            if y < 16 and x < 16:                       # kristal yüzeyi
                taban = 0.45 + 0.18 * math.sin((x * 0.7 + y * 1.3)) + 0.1 * ((x * 7 + y * 3) % 5) / 5
                bant = (x + y) / 30.0 - faz              # çapraz ışıltı bandı
                bant -= math.floor(bant)
                parilti = max(0.0, 1 - abs(bant - 0.5) * 8)
                kenar = 0.12 if (x in (0, 15) or y in (0, 15)) else 0
                renk = rampa(amber, taban + parilti * 0.45 + kenar)
            elif y < 16:                                 # obsidyen
                xx = x - 16
                d = ((xx * 5 + y * 3) % 7) / 7
                renk = obsidyen[3] if (xx in (0, 15) or y in (0, 15)) else rampa(obsidyen, d * 0.8)
            elif x < 16:                                 # rün (ateş işareti)
                xx, yy2 = x, y - 16
                nabiz = 0.55 + 0.45 * math.sin(2 * math.pi * faz)
                cx, cy = xx - 7.5, yy2 - 7.5
                r = math.hypot(cx, cy)
                rune = (abs(r - 5) < 0.9) or (abs(cx) < 0.9 and abs(cy) < 4.2) or (abs(cy + 1.5) < 0.9 and abs(cx) < 3)
                renk = rampa(amber, 0.35 + nabiz * 0.6) if rune else obsidyen[1]
            else:                                        # parça
                xx, yy2 = x - 16, y - 16
                kivilcim = (int(faz * 16) + xx - yy2) % 16 == 0
                taban = 0.55 + 0.2 * math.sin(xx * 0.9 + yy2 * 0.6)
                renk = rampa(amber, 1.0 if kivilcim else taban)
            pik.append(renk)
    return g, h, pik


def kup(ad, fr, to, bolge, isik=0, don=(0, 0, 0), merkez=None):
    """Blockbench küpü; bolge: (u0, v0, u1, v1) tüm yüzlere uzatılır."""
    if merkez is None:
        merkez = [(fr[i] + to[i]) / 2 for i in range(3)]
    u0, v0, u1, v1 = bolge
    yuzler = {y: {"uv": [u0, v0, u1, v1], "texture": 0} for y in ("north", "east", "south", "west")}
    yuzler["up"] = {"uv": [u0, v0, u1, v1], "texture": 0}
    yuzler["down"] = {"uv": [u0, v1, u1, v0], "texture": 0}
    el = {
        "name": ad, "box_uv": False, "render_order": "default", "locked": False,
        "allow_mirror_modeling": True, "light_emission": isik,
        "from": [round(v, 4) for v in fr], "to": [round(v, 4) for v in to],
        "autouv": 0, "color": 1, "origin": [round(v, 4) for v in merkez],
        "faces": yuzler, "type": "cube", "uuid": uid("kor_kristali", ad),
    }
    if any(don):
        el["rotation"] = list(don)
    return el


def grup(ad, merkez, isik=0):
    return {
        "uuid": uid("kor_kristali", "grup", ad), "export": True, "locked": False,
        "origin": merkez, "rotation": [0, 0, 0], "color": 0, "name": ad, "children": [],
        "reset": False, "shade": True, "mirror_uv": False, "selected": False,
        "visibility": True, "autouv": 0, "isOpen": True, "light_emission": isik,
    }


def kristal_modeli():
    KRISTAL, OBS, RUN, PARCA = (0, 0, 16, 16), (16, 0, 32, 16), (0, 16, 16, 32), (16, 16, 32, 32)
    M = [0, 13, 0]   # kristalin dönme/süzülme merkezi
    gruplar_ve_kupler = [
        (grup("kaide", [0, 0, 0]), [
            kup("kaide_alt", [-6, 0, -6], [6, 2, 6], OBS),
            kup("kaide_ust", [-4.5, 2, -4.5], [4.5, 3.5, 4.5], OBS),
        ]),
        (grup("glow_runler", [0, 0, 0], 15), [
            kup("run_kuzey", [-1.5, 0.25, -6.1], [1.5, 1.75, -6], RUN, 15),
            kup("run_guney", [-1.5, 0.25, 6], [1.5, 1.75, 6.1], RUN, 15),
            kup("run_dogu", [6, 0.25, -1.5], [6.1, 1.75, 1.5], RUN, 15),
            kup("run_bati", [-6.1, 0.25, -1.5], [-6, 1.75, 1.5], RUN, 15),
        ]),
        (grup("glow_kristal", M, 15), [
            kup("govde", [-2.5, 8, -2.5], [2.5, 18, 2.5], KRISTAL, 15, (0, 45, 0), M),
            kup("ust_1", [-1.75, 18, -1.75], [1.75, 20.5, 1.75], KRISTAL, 15, (0, 45, 0), M),
            kup("ust_2", [-0.9, 20.5, -0.9], [0.9, 22.5, 0.9], KRISTAL, 15, (0, 45, 0), M),
            kup("alt_1", [-1.75, 5.75, -1.75], [1.75, 8, 1.75], KRISTAL, 15, (0, 45, 0), M),
            kup("alt_2", [-0.9, 4.5, -0.9], [0.9, 5.75, 0.9], KRISTAL, 15, (0, 45, 0), M),
        ]),
        (grup("glow_halka", M, 15), [
            kup(f"parca_{i}", [7 * math.cos(a) - 0.6, 12, 7 * math.sin(a) - 0.6],
                [7 * math.cos(a) + 0.6, 14.4, 7 * math.sin(a) + 0.6], PARCA, 15, (0, 45 - i * 90, 20))
            for i, a in enumerate(math.radians(d) for d in (0, 90, 180, 270))
        ]),
    ]
    groups, elements, outliner = [], [], []
    for g, kupler in gruplar_ve_kupler:
        groups.append(g)
        elements.extend(kupler)
        outliner.append({"uuid": g["uuid"], "isOpen": True, "children": [k["uuid"] for k in kupler]})
    kemikler = {g["name"]: g["uuid"] for g in groups}

    g, h, pik = kristal_dokusu()
    png = png_bytes(g, h, pik)
    doku = {
        "path": "", "name": "kor_kristali.png", "folder": "", "namespace": "", "id": "0", "group": "",
        "width": 32, "height": 32 * KARE, "uv_width": 32, "uv_height": 32,
        "particle": False, "use_as_default": False, "layers_enabled": False, "sync_to_project": "",
        "render_mode": "default", "render_sides": "auto", "pbr_channel": "color",
        "frame_time": KARE_SURESI, "frame_order_type": "loop", "frame_order": "", "frame_interpolate": True,
        "visible": True, "internal": True, "saved": True, "uuid": uid("kor_kristali", "doku"),
        "source": "data:image/png;base64," + base64.b64encode(png).decode(),
    }
    tur = [(t, (0, t * 90, 0)) for t in range(5)]
    ters_tur = [(t, (12, -t * 90, 0)) for t in range(5)]
    idle = {
        "glow_kristal": {
            "rotation": (tur, "linear"),
            "position": [(0, (0, 0, 0)), (1, (0, 1, 0)), (2, (0, 0, 0)), (3, (0, 1, 0)), (4, (0, 0, 0))],
            "scale": [(t / 2, (1.06, 1.06, 1.06) if t % 2 else (1, 1, 1)) for t in range(9)],
        },
        "glow_halka": {
            "rotation": (ters_tur, "linear"),
            "position": [(0, (0, 1, 0)), (1, (0, 0, 0)), (2, (0, 1, 0)), (3, (0, 0, 0)), (4, (0, 1, 0))],
        },
    }
    spawn = {
        "glow_kristal": {"scale": [(0, (0, 0, 0)), (0.6, (1.2, 1.2, 1.2)), (0.8, (0.95, 0.95, 0.95)), (1.0, (1, 1, 1))]},
        "glow_halka": {"scale": [(0, (0, 0, 0)), (0.4, (0, 0, 0)), (0.9, (1.1, 1.1, 1.1)), (1.0, (1, 1, 1))]},
    }
    return {
        "meta": {"format_version": "5.0", "model_format": "free", "box_uv": False},
        "name": "kor_kristali",
        "model_identifier": "",
        "visible_box": [1, 1.5, 0],
        "variable_placeholders": "",
        "variable_placeholder_buttons": [],
        "timeline_setups": [],
        "unhandled_root_fields": {},
        "resolution": {"width": 32, "height": 32},
        "elements": elements,
        "groups": groups,
        "outliner": outliner,
        "textures": [doku],
        "animations": [
            animasyon("idle", 4.0, "loop", kemikler, idle),
            animasyon("spawn", 1.0, "once", kemikler, spawn),
        ],
    }


def yaz(yol, nesne):
    os.makedirs(os.path.dirname(yol), exist_ok=True)
    with open(yol, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(nesne, ensure_ascii=False, indent=1) + "\n")


def main():
    ap = argparse.ArgumentParser(description="BetterModel modellerini üretir.")
    ap.add_argument("--cikti", default=os.path.join(KOK, "bettermodel"), help="çıktı kökü")
    kok = ap.parse_args().cikti
    yaz(os.path.join(kok, "models", "kor_kristali.bbmodel"), kristal_modeli())
    yaz(os.path.join(kok, "players", "kami_emote.bbmodel"), emote_modeli())
    print("BetterModel: kor_kristali (idle, spawn) ve kami_emote (selam, zafer, dans) üretildi.")


if __name__ == "__main__":
    main()
