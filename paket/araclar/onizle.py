#!/usr/bin/env python3
"""Paketteki bir eşya modelinin önizlemesini çizer (PNG + animasyonlu GIF).

Oyunun kullanacağı dosyaları okur (models/item/<ad>.json + dokular + .mcmeta),
yani önizleme paketin kendisini doğrular. Bu gerçek oyun görüntüsü değildir:
ortografik çizim, yön gölgelendirmesi ve parlayan (light_emission) parçalar için
basit bir "bloom" efekti uygular.

Gereken: Pillow ve numpy (yalnız geliştirme aracı; sunucuda gerekmez).
    python3 -m pip install Pillow numpy
Kullanım (depo kökünden):
    python3 paket/araclar/onizle.py kor_kilic
Çıktı: paket/onizleme/<ad>.png ve paket/onizleme/<ad>.gif
"""

import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

KOK = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
PAKET = os.path.join(KOK, "kaynak")
CIKTI = os.path.join(KOK, "onizleme")

# Minecraft'ın yön gölgelendirmesi (dünya içi değerler).
GOLGE = {"up": 1.0, "down": 0.5, "north": 0.8, "south": 0.8, "east": 0.6, "west": 0.6}
NORMAL = {"up": (0, 1, 0), "down": (0, -1, 0), "north": (0, 0, -1),
          "south": (0, 0, 1), "east": (1, 0, 0), "west": (-1, 0, 0)}


# --------------------------------------------------------------------------
# Kaynak okuma
# --------------------------------------------------------------------------
def kaynak_yolu(ref, klasor, uzanti):
    ns, yol = ref.split(":", 1) if ":" in ref else ("minecraft", ref)
    return os.path.join(PAKET, "assets", ns, klasor, yol + uzanti)


class Doku:
    """Animasyonlu dokuyu kareleriyle tutar; zamana göre (interpolate dahil) örnekler."""

    def __init__(self, ref):
        yol = kaynak_yolu(ref, "textures", ".png")
        img = np.asarray(Image.open(yol).convert("RGBA"), dtype=np.float32) / 255.0
        g = img.shape[1]
        self.kareler = [img[i * g:(i + 1) * g] for i in range(img.shape[0] // g)]
        self.sure, self.interp = 1, False
        if os.path.exists(yol + ".mcmeta"):
            anim = json.load(open(yol + ".mcmeta", encoding="utf-8")).get("animation", {})
            self.sure = anim.get("frametime", 1)
            self.interp = anim.get("interpolate", False)
        self.boyut = g

    def an(self, tick):
        n = len(self.kareler)
        if n == 1:
            return self.kareler[0]
        konum = (tick / self.sure) % n
        i = int(konum)
        if not self.interp:
            return self.kareler[i]
        w = konum - i
        return self.kareler[i] * (1 - w) + self.kareler[(i + 1) % n] * w


def model_oku(ad):
    model = json.load(open(kaynak_yolu(f"kami:item/{ad}", "models", ".json"), encoding="utf-8"))
    onbellek = {}
    dokular = {}
    for k, v in model["textures"].items():
        if not v.startswith("#"):
            dokular[k] = onbellek.setdefault(v, Doku(v))   # aynı doku bir kez yüklenir
    return model, dokular


# --------------------------------------------------------------------------
# Geometri
# --------------------------------------------------------------------------
def rot_xyz(rx, ry, rz):
    """Minecraft ItemTransform ile aynı: R = Rx·Ry·Rz (derece)."""
    a, b, c = (math.radians(v) for v in (rx, ry, rz))
    Rx = np.array([[1, 0, 0], [0, math.cos(a), -math.sin(a)], [0, math.sin(a), math.cos(a)]])
    Ry = np.array([[math.cos(b), 0, math.sin(b)], [0, 1, 0], [-math.sin(b), 0, math.cos(b)]])
    Rz = np.array([[math.cos(c), -math.sin(c), 0], [math.sin(c), math.cos(c), 0], [0, 0, 1]])
    return Rx @ Ry @ Rz


def yuz_koseleri(fr, to, yon):
    """Yüzün 4 köşesi: (sol-üst, sağ-üst, sağ-alt, sol-alt) — dokunun (u0,v0)…(u1,v1) yönünde.

    Minecraft FaceInfo düzeni: kuzey yüzünde u, x azaldıkça artar; güneyde x arttıkça;
    batıda z arttıkça; doğuda z azaldıkça; üstte u=x, v=z; altta u=x, v=-z.
    """
    x0, y0, z0 = fr
    x1, y1, z1 = to
    return {
        "north": [(x1, y1, z0), (x0, y1, z0), (x0, y0, z0), (x1, y0, z0)],
        "south": [(x0, y1, z1), (x1, y1, z1), (x1, y0, z1), (x0, y0, z1)],
        "west": [(x0, y1, z0), (x0, y1, z1), (x0, y0, z1), (x0, y0, z0)],
        "east": [(x1, y1, z1), (x1, y1, z0), (x1, y0, z0), (x1, y0, z1)],
        "up": [(x0, y1, z0), (x1, y1, z0), (x1, y1, z1), (x0, y1, z1)],
        "down": [(x0, y0, z1), (x1, y0, z1), (x1, y0, z0), (x0, y0, z0)],
    }[yon]


def ciz(model, dokular, tick, goruntu, kamera, olcek, boyut, karanlik=0.45):
    """Modeli çizer. goruntu: display ayarı (dict ya da None), kamera: (rx, ry).

    Dönüş: (renk RGBA float dizisi, parıltı RGB float dizisi).
    """
    G = boyut
    renk = np.zeros((G, G, 4), np.float32)
    parilti = np.zeros((G, G, 3), np.float32)
    zbuf = np.full((G, G), -1e9, np.float32)

    R_disp, T_disp, S_disp = np.eye(3), np.zeros(3), np.ones(3)
    if goruntu:
        R_disp = rot_xyz(*goruntu.get("rotation", [0, 0, 0]))
        T_disp = np.array(goruntu.get("translation", [0, 0, 0]), float)
        S_disp = np.array(goruntu.get("scale", [1, 1, 1]), float)
    R_cam = rot_xyz(kamera[0], kamera[1], 0)

    def donustur(p):
        v = (np.array(p, float) - 8.0) * S_disp
        v = R_disp @ v + T_disp
        return R_cam @ v

    anlik = {k: d.an(tick) for k, d in dokular.items()}
    ys, xs = np.mgrid[0:G, 0:G]
    for el in model["elements"]:
        isik = el.get("light_emission", 0) / 15.0
        for yon, yuz in el["faces"].items():
            n = R_cam @ R_disp @ np.array(NORMAL[yon], float)
            if n[2] <= 1e-6:
                continue  # arkaya bakan yüz
            k = [donustur(p) for p in yuz_koseleri(el["from"], el["to"], yon)]
            ekran = [((c[0] * olcek) + G / 2, (G / 2) - (c[1] * olcek), c[2]) for c in k]
            p0, p1, p3 = (np.array(ekran[i][:2]) for i in (0, 1, 3))
            A = np.column_stack([p1 - p0, p3 - p0])
            if abs(np.linalg.det(A)) < 1e-9:
                continue
            Ainv = np.linalg.inv(A)
            xmin = max(int(min(e[0] for e in ekran)) - 1, 0)
            xmax = min(int(max(e[0] for e in ekran)) + 2, G)
            ymin = max(int(min(e[1] for e in ekran)) - 1, 0)
            ymax = min(int(max(e[1] for e in ekran)) + 2, G)
            if xmin >= xmax or ymin >= ymax:
                continue
            px = xs[ymin:ymax, xmin:xmax] + 0.5 - p0[0]
            py = ys[ymin:ymax, xmin:xmax] + 0.5 - p0[1]
            s = Ainv[0, 0] * px + Ainv[0, 1] * py
            t = Ainv[1, 0] * px + Ainv[1, 1] * py
            icinde = (s >= 0) & (s < 1) & (t >= 0) & (t < 1)
            if not icinde.any():
                continue
            z = ekran[0][2] + s * (ekran[1][2] - ekran[0][2]) + t * (ekran[3][2] - ekran[0][2])
            u0, v0, u1, v1 = yuz["uv"]
            doku = anlik[yuz["texture"].lstrip("#")]
            ds = dokular[yuz["texture"].lstrip("#")].boyut
            tu = np.clip(((u0 + s * (u1 - u0)) / 16 * ds).astype(int), 0, ds - 1)
            tv = np.clip(((v0 + t * (v1 - v0)) / 16 * ds).astype(int), 0, ds - 1)
            texel = doku[tv, tu]
            gorunur = icinde & (texel[..., 3] > 0.1) & (z > zbuf[ymin:ymax, xmin:xmax])
            if not gorunur.any():
                continue
            golge = GOLGE[yon]
            parlaklik = max(golge * karanlik, isik * (0.75 + 0.25 * golge)) if isik else golge * karanlik
            rgb = texel[..., :3] * parlaklik
            bolge_renk = renk[ymin:ymax, xmin:xmax]
            bolge_renk[gorunur, :3] = rgb[gorunur]
            bolge_renk[gorunur, 3] = 1.0
            bolge_par = parilti[ymin:ymax, xmin:xmax]
            bolge_par[gorunur] = texel[..., :3][gorunur] * isik if isik else 0.0
            zbuf[ymin:ymax, xmin:xmax][gorunur] = z[gorunur]
    return renk, parilti


def bitir(renk, parilti, arka):
    """Arka plan + model + bloom → PIL görüntüsü."""
    G = renk.shape[0]
    taban = np.asarray(arka.resize((G, G)), np.float32)[..., :3] / 255.0
    a = renk[..., 3:4]
    goruntu = taban * (1 - a) + renk[..., :3] * a
    par = Image.fromarray((np.clip(parilti, 0, 1) * 255).astype(np.uint8))
    bloom = (np.asarray(par.filter(ImageFilter.GaussianBlur(G / 60)), np.float32) / 255.0 * 0.9
             + np.asarray(par.filter(ImageFilter.GaussianBlur(G / 22)), np.float32) / 255.0 * 0.8)
    goruntu = 1 - (1 - goruntu) * (1 - np.clip(bloom, 0, 1))   # "screen" karışımı
    return Image.fromarray((np.clip(goruntu, 0, 1) * 255).astype(np.uint8))


def gece_arka(G):
    img = Image.new("RGB", (G, G))
    d = ImageDraw.Draw(img)
    for y in range(G):
        t = y / G
        d.line([(0, y), (G, y)], fill=(int(14 + 10 * t), int(12 + 6 * t), int(24 + 8 * t)))
    return img


def slot_arka(G):
    img = Image.new("RGB", (G, G), (139, 139, 139))
    d = ImageDraw.Draw(img)
    k = max(G // 18, 2)
    d.rectangle([0, 0, G, k], fill=(55, 55, 55))
    d.rectangle([0, 0, k, G], fill=(55, 55, 55))
    d.rectangle([0, G - k, G, G], fill=(255, 255, 255))
    d.rectangle([G - k, 0, G, G], fill=(255, 255, 255))
    return img


def doku_seridi(dokular, yukseklik):
    """Tüm dokuların büyütülmüş hali (animasyonlu olanlarda tüm kareler yan yana)."""
    parcalar = []
    for d in {id(d): d for d in dokular.values()}.values():
        for kare in d.kareler:
            img = Image.fromarray((kare * 255).astype(np.uint8), "RGBA")
            parcalar.append(img.resize((yukseklik, yukseklik), Image.NEAREST))
    bosluk = yukseklik // 8
    serit = Image.new("RGB", (len(parcalar) * (yukseklik + bosluk) + bosluk, yukseklik + 2 * bosluk), (24, 22, 30))
    for i, p in enumerate(parcalar):
        serit.paste(p, (bosluk + i * (yukseklik + bosluk), bosluk), p)
    return serit


def main():
    ad = sys.argv[1] if len(sys.argv) > 1 else "kor_kilic"
    model, dokular = model_oku(ad)
    os.makedirs(CIKTI, exist_ok=True)
    G = 512

    # 1) Vitrin: 3/4 açı, karanlık ortam (parlama görünsün)
    vitrin_disp = {"rotation": [0, 0, -45], "translation": [0, 0, 0], "scale": [1, 1, 1]}
    r, p = ciz(model, dokular, 0, vitrin_disp, (22, 35), G / 26, G)
    vitrin = bitir(r, p, gece_arka(G))
    # 2) Envanter simgesi (oyundaki gui ayarı)
    r, p = ciz(model, dokular, 0, model["display"]["gui"], (0, 0), 256 / 16, 256, karanlik=1.0)
    simge = bitir(r, p * 0.35, slot_arka(256))
    # 3) Elde (üçüncü şahıs, sağ el) — duruş kontrolü
    r, p = ciz(model, dokular, 0, model["display"]["thirdperson_righthand"], (0, 90), 256 / 30, 256)
    elde = bitir(r, p, gece_arka(256))

    serit = doku_seridi(dokular, 96)
    genislik = max(G + 256 + 24 * 3, serit.width + 48)
    tuval = Image.new("RGB", (genislik, G + serit.height + 72), (18, 16, 24))
    tuval.paste(vitrin, (24, 24))
    tuval.paste(simge, (G + 48, 24))
    tuval.paste(elde, (G + 48, 24 + 256))
    tuval.paste(serit, (24, G + 48))
    tuval.save(os.path.join(CIKTI, f"{ad}.png"), optimize=True)

    # 4) Animasyon: dönen vitrin + akan doku (1 tick = 50 ms; 40 kare × 60 ms)
    kareler = []
    for i in range(40):
        tick = i * 60 / 50
        r, p = ciz(model, dokular, tick, vitrin_disp, (18, 35 + i * 9), 300 / 26, 300)
        kareler.append(bitir(r, p, gece_arka(300)).convert("P", palette=Image.ADAPTIVE, colors=128))
    kareler[0].save(os.path.join(CIKTI, f"{ad}.gif"), save_all=True, append_images=kareler[1:],
                    duration=60, loop=0, optimize=True, disposal=2)
    print(f"Önizleme: {os.path.join(CIKTI, ad)}.png ve .gif")


if __name__ == "__main__":
    main()
