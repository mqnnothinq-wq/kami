#!/usr/bin/env python3
"""BetterModel (.bbmodel, Generic Model) animasyon önizleyicisi: PNG ve GIF.

Blockbench'in kurallarını uygular (kaynak koddan): grup konumu = köken − ebeveyn kökeni,
dönüş Euler ZYX (R = Rz·Ry·Rx), animasyon dönüşü/konumu eklenir, ölçek çarpılır;
anahtar kareler arası catmull-rom / doğrusal / basamak. Oyun görüntüsü DEĞİLDİR.

Gereken: Pillow + numpy (geliştirme aracı).
    python3 paket/araclar/bb_onizle.py
Çıktı: paket/onizleme/kor_kristali.{png,gif}, emote_<ad>.gif, emote_onizleme.png
"""

import base64
import io
import json
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

KOK = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
BM = os.path.join(KOK, "bettermodel")
CIKTI = os.path.join(KOK, "onizleme")
ATLA = ("shadow", "tag_", "hitbox", "b_", "ob_")   # BetterModel'in görünmeyen yardımcı kemikleri


# --------------------------------------------------------------------------
# Matematik
# --------------------------------------------------------------------------
def rx(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[1, 0, 0, 0], [0, c, -s, 0], [0, s, c, 0], [0, 0, 0, 1]], float)


def ry(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, 0, s, 0], [0, 1, 0, 0], [-s, 0, c, 0], [0, 0, 0, 1]], float)


def rz(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0, 0], [s, c, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]], float)


def tr(v):
    m = np.eye(4)
    m[:3, 3] = v
    return m


def sc(v):
    return np.diag([v[0], v[1], v[2], 1.0])


def euler_zyx(deg):
    x, y, z = (math.radians(d) for d in deg)
    return rz(z) @ ry(y) @ rx(x)


# --------------------------------------------------------------------------
# Animasyon örnekleme
# --------------------------------------------------------------------------
def kanal_degeri(kareler, t, varsayilan):
    if not kareler:
        return np.array(varsayilan, float)
    kareler = sorted(kareler, key=lambda k: k["time"])
    deg = [np.array([float(k["data_points"][0][e]) for e in "xyz"]) for k in kareler]
    if t <= kareler[0]["time"]:
        return deg[0]
    if t >= kareler[-1]["time"]:
        return deg[-1]
    i = max(j for j in range(len(kareler)) if kareler[j]["time"] <= t)
    t0, t1 = kareler[i]["time"], kareler[i + 1]["time"]
    a = (t - t0) / (t1 - t0) if t1 > t0 else 0
    ara_once, ara_sonra = kareler[i]["interpolation"], kareler[i + 1]["interpolation"]
    if ara_once == "step":
        return deg[i]
    if "catmullrom" in (ara_once, ara_sonra):
        p0 = deg[i - 1] if i > 0 else deg[i]
        p1, p2 = deg[i], deg[i + 1]
        p3 = deg[i + 2] if i + 2 < len(deg) else deg[i + 1]
        a2, a3 = a * a, a * a * a
        return 0.5 * ((2 * p1) + (-p0 + p2) * a + (2 * p0 - 5 * p1 + 4 * p2 - p3) * a2 + (-p0 + 3 * p1 - 3 * p2 + p3) * a3)
    return deg[i] + (deg[i + 1] - deg[i]) * a


class Model:
    def __init__(self, yol, doku_degistir=None):
        with open(yol, encoding="utf-8") as f:
            self.m = json.load(f)
        self.gruplar = {g["uuid"]: g for g in self.m.get("groups", [])}
        self.kupler = {e["uuid"]: e for e in self.m["elements"]}
        self.ebeveyn, self.kup_grubu, self.kokler = {}, {}, []

        def gez(dugumler, ust):
            for d in dugumler:
                if isinstance(d, dict):
                    self.ebeveyn[d["uuid"]] = ust
                    if ust is None:
                        self.kokler.append(d["uuid"])
                    gez(d.get("children", []), d["uuid"])
                else:
                    self.kup_grubu[d] = ust
        gez(self.m["outliner"], None)

        self.dokular = []
        for i, t in enumerate(self.m["textures"]):
            if doku_degistir is not None and i in doku_degistir:
                img = doku_degistir[i]
            else:
                img = Image.open(io.BytesIO(base64.b64decode(t["source"].split(",", 1)[1]))).convert("RGBA")
            dizi = np.asarray(img, np.float32) / 255.0
            g = dizi.shape[1]
            kareler = [dizi[j * g:(j + 1) * g] for j in range(max(1, dizi.shape[0] // g))]
            self.dokular.append({
                "kareler": kareler, "sure": max(1, t.get("frame_time", 1)),
                "interp": t.get("frame_interpolate", False),
                "olcek": g / t.get("uv_width", g),
            })
        self.animasyonlar = {a["name"]: a for a in self.m.get("animations", [])}

    def doku_ani(self, i, t):
        d = self.dokular[i]
        n = len(d["kareler"])
        if n == 1:
            return d["kareler"][0]
        konum = (t * 20 / d["sure"]) % n
        j = int(konum)
        if not d["interp"]:
            return d["kareler"][j]
        w = konum - j
        return d["kareler"][j] * (1 - w) + d["kareler"][(j + 1) % n] * w

    def gorunmez(self, g_uuid):
        while g_uuid:
            if self.gruplar[g_uuid]["name"].startswith(ATLA):
                return True
            g_uuid = self.ebeveyn.get(g_uuid)
        return False

    def parlak(self, g_uuid, kup):
        if kup.get("light_emission", 0) > 0 or kup["name"].startswith("glow_"):
            return True
        while g_uuid:
            g = self.gruplar[g_uuid]
            if g["name"].startswith("glow_") or g.get("light_emission", 0) > 0:
                return True
            g_uuid = self.ebeveyn.get(g_uuid)
        return False

    def kemik_matrisleri(self, anim_adi, t):
        anim = self.animasyonlar.get(anim_adi) if anim_adi else None
        if anim:
            uz = anim["length"]
            t = (t % uz) if anim["loop"] == "loop" else min(t, uz)
        dunya = {}

        def hesapla(u):
            if u in dunya:
                return dunya[u]
            g = self.gruplar[u]
            ust = self.ebeveyn.get(u)
            ust_koken = np.array(self.gruplar[ust]["origin"], float) if ust else np.zeros(3)
            rot = np.array(g.get("rotation") or [0, 0, 0], float)
            poz = np.zeros(3)
            olc = np.ones(3)
            if anim and u in anim["animators"]:
                kf = anim["animators"][u]["keyframes"]
                rot = rot + kanal_degeri([k for k in kf if k["channel"] == "rotation"], t, (0, 0, 0))
                poz = kanal_degeri([k for k in kf if k["channel"] == "position"], t, (0, 0, 0))
                olc = kanal_degeri([k for k in kf if k["channel"] == "scale"], t, (1, 1, 1))
            yerel = tr(np.array(g["origin"], float) - ust_koken + poz) @ euler_zyx(rot) @ sc(olc)
            dunya[u] = (hesapla(ust) if ust else np.eye(4)) @ yerel
            return dunya[u]
        for u in self.gruplar:
            hesapla(u)
        return dunya


KOSE = {  # Java/Blockbench yüz UV düzeni (sol-üst, sağ-üst, sağ-alt, sol-alt)
    "north": lambda a, b: [(b[0], b[1], a[2]), (a[0], b[1], a[2]), (a[0], a[1], a[2]), (b[0], a[1], a[2])],
    "south": lambda a, b: [(a[0], b[1], b[2]), (b[0], b[1], b[2]), (b[0], a[1], b[2]), (a[0], a[1], b[2])],
    "west": lambda a, b: [(a[0], b[1], a[2]), (a[0], b[1], b[2]), (a[0], a[1], b[2]), (a[0], a[1], a[2])],
    "east": lambda a, b: [(b[0], b[1], b[2]), (b[0], b[1], a[2]), (b[0], a[1], a[2]), (b[0], a[1], b[2])],
    "up": lambda a, b: [(a[0], b[1], a[2]), (b[0], b[1], a[2]), (b[0], b[1], b[2]), (a[0], b[1], b[2])],
    "down": lambda a, b: [(a[0], a[1], b[2]), (b[0], a[1], b[2]), (b[0], a[1], a[2]), (a[0], a[1], a[2])],
}
ISIK = np.array([-0.4, 0.8, -0.45])
ISIK = ISIK / np.linalg.norm(ISIK)


def ciz(model, anim, t, G, olcek, merkez, yaw, pitch):
    renk = np.zeros((G, G, 4), np.float32)
    parilti = np.zeros((G, G, 3), np.float32)
    zbuf = np.full((G, G), -1e9, np.float32)
    kemik = model.kemik_matrisleri(anim, t)
    # Model -z'ye bakar; kamerayı önüne almak için 180° çevir.
    kamera = rx(math.radians(pitch)) @ ry(math.radians(180 + yaw)) @ tr(-np.array(merkez, float))
    ys, xs = np.mgrid[0:G, 0:G]
    for u, kup in model.kupler.items():
        g = model.kup_grubu.get(u)
        if kup.get("type", "cube") != "cube" or kup.get("visibility") is False:
            continue
        if g and model.gorunmez(g):
            continue
        parlak = model.parlak(g, kup)
        koken = np.array(kup["origin"], float)
        g_koken = np.array(model.gruplar[g]["origin"], float) if g else np.zeros(3)
        M = (kemik[g] if g else np.eye(4)) @ tr(koken - g_koken) @ euler_zyx(kup.get("rotation") or [0, 0, 0]) @ tr(-koken)
        MV = kamera @ M
        a, b = kup["from"], kup["to"]
        for yon, yuz in kup["faces"].items():
            if yuz.get("texture") is None:
                continue
            k = [MV @ np.array([*p, 1.0]) for p in KOSE[yon](a, b)]
            n = np.cross((k[1] - k[0])[:3], (k[3] - k[0])[:3])
            if np.linalg.norm(n) < 1e-9:
                continue
            n = n / np.linalg.norm(n)
            if n[2] <= 1e-6:
                continue
            ekran = [(p[0] * olcek + G / 2, G * 0.55 - p[1] * olcek, p[2]) for p in k]
            p0, p1, p3 = (np.array(ekran[i][:2]) for i in (0, 1, 3))
            A = np.column_stack([p1 - p0, p3 - p0])
            if abs(np.linalg.det(A)) < 1e-9:
                continue
            Ai = np.linalg.inv(A)
            x0 = max(int(min(e[0] for e in ekran)) - 1, 0)
            x1 = min(int(max(e[0] for e in ekran)) + 2, G)
            y0 = max(int(min(e[1] for e in ekran)) - 1, 0)
            y1 = min(int(max(e[1] for e in ekran)) + 2, G)
            if x0 >= x1 or y0 >= y1:
                continue
            px = xs[y0:y1, x0:x1] + 0.5 - p0[0]
            py = ys[y0:y1, x0:x1] + 0.5 - p0[1]
            s = Ai[0, 0] * px + Ai[0, 1] * py
            tt = Ai[1, 0] * px + Ai[1, 1] * py
            ic = (s >= 0) & (s < 1) & (tt >= 0) & (tt < 1)
            if not ic.any():
                continue
            z = ekran[0][2] + s * (ekran[1][2] - ekran[0][2]) + tt * (ekran[3][2] - ekran[0][2])
            dk = model.doku_ani(yuz["texture"], t)
            ol = model.dokular[yuz["texture"]]["olcek"]
            u0, v0, u1, v1 = yuz["uv"]
            H, W = dk.shape[:2]
            tu = np.clip(((u0 + s * (u1 - u0)) * ol).astype(int), 0, W - 1)
            tv = np.clip(((v0 + tt * (v1 - v0)) * ol).astype(int), 0, H - 1)
            tex = dk[tv, tu]
            gor = ic & (tex[..., 3] > 0.1) & (z > zbuf[y0:y1, x0:x1])
            if not gor.any():
                continue
            dunya_n = (M[:3, :3] @ np.cross((np.array(KOSE[yon](a, b)[1]) - KOSE[yon](a, b)[0]),
                                             (np.array(KOSE[yon](a, b)[3]) - KOSE[yon](a, b)[0])))
            dn = dunya_n / (np.linalg.norm(dunya_n) or 1)
            isik = 1.0 if parlak else 0.5 + 0.5 * max(0.0, float(dn @ ISIK))
            bol = renk[y0:y1, x0:x1]
            bol[gor, :3] = tex[..., :3][gor] * isik
            bol[gor, 3] = 1
            par = parilti[y0:y1, x0:x1]
            par[gor] = tex[..., :3][gor] if parlak else 0
            zbuf[y0:y1, x0:x1][gor] = z[gor]
    return renk, parilti


def birlestir(renk, parilti, arka, bloom=1.0):
    G = renk.shape[0]
    taban = np.asarray(arka, np.float32)[..., :3] / 255.0
    a = renk[..., 3:4]
    img = taban * (1 - a) + renk[..., :3] * a
    if bloom:
        p = Image.fromarray((np.clip(parilti, 0, 1) * 255).astype(np.uint8))
        b = (np.asarray(p.filter(ImageFilter.GaussianBlur(G / 55)), np.float32) / 255 * 0.8
             + np.asarray(p.filter(ImageFilter.GaussianBlur(G / 18)), np.float32) / 255 * 0.7) * bloom
        img = 1 - (1 - img) * (1 - np.clip(b, 0, 1))
    return Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8))


def gece(G):
    img = Image.new("RGB", (G, G))
    d = ImageDraw.Draw(img)
    for y in range(G):
        t = y / G
        d.line([(0, y), (G, y)], fill=(int(12 + 14 * t), int(10 + 8 * t), int(22 + 12 * t)))
    return img


def gunduz(G):
    img = Image.new("RGB", (G, G))
    d = ImageDraw.Draw(img)
    for y in range(G):
        t = y / G
        d.line([(0, y), (G, y)], fill=(int(120 + 60 * t), int(170 + 40 * t), int(230 - 10 * t)))
    d.rectangle([0, int(G * 0.86), G, G], fill=(96, 150, 72))
    d.ellipse([G * 0.3, G * 0.84, G * 0.7, G * 0.9], fill=(70, 110, 55))
    return img


# --------------------------------------------------------------------------
# Önizleme skin'i (yalnız önizleme; oyunda herkes kendi skin'iyle görünür)
# --------------------------------------------------------------------------
def onizleme_skini():
    S = np.zeros((64, 64, 4), np.uint8)

    def kutu(x0, y0, x1, y1, rgb):
        S[y0:y1, x0:x1] = (*rgb, 255)
    TEN, SAC, GOMLEK, SERIT, PANT, AYAK = (222, 170, 130), (60, 38, 25), (200, 30, 40), (240, 240, 240), (40, 55, 95), (30, 30, 30)
    kutu(0, 0, 32, 16, TEN)
    kutu(8, 0, 16, 8, SAC)                                      # üst
    kutu(24, 8, 32, 16, SAC)                                    # arka
    for x0 in (0, 8, 16):                                       # yan + ön: üst 2 satır saç
        kutu(x0, 8, x0 + 8, 10, SAC)
    kutu(0, 10, 2, 16, SAC); kutu(22, 10, 24, 16, SAC)          # favoriler
    kutu(9, 12, 11, 13, (255, 255, 255)); kutu(13, 12, 15, 13, (255, 255, 255))
    kutu(10, 12, 11, 13, (40, 60, 120)); kutu(13, 12, 14, 13, (40, 60, 120))
    kutu(11, 14, 13, 15, (150, 80, 70))
    kutu(16, 16, 40, 32, GOMLEK)                                # gövde
    kutu(20, 23, 28, 25, SERIT); kutu(32, 23, 40, 25, SERIT)
    for (x0, y0) in ((40, 16), (32, 48)):                       # kollar: kol ağzı + ten
        kutu(x0, y0, x0 + 16, y0 + 16, TEN)
        kutu(x0 + 4, y0, x0 + 8, y0 + 4, GOMLEK)
        kutu(x0, y0 + 4, x0 + 16, y0 + 8, GOMLEK)
    for (x0, y0) in ((0, 16), (16, 48)):                        # bacaklar: pantolon + ayakkabı
        kutu(x0, y0, x0 + 16, y0 + 16, PANT)
        kutu(x0, y0 + 13, x0 + 16, y0 + 16, AYAK)
        kutu(x0 + 8, y0, x0 + 12, y0 + 4, AYAK)
    return Image.fromarray(S, "RGBA")


# --------------------------------------------------------------------------
def gif_yaz(yol, kareler, ms):
    p = [k.convert("P", palette=Image.ADAPTIVE, colors=128) for k in kareler]
    p[0].save(yol, save_all=True, append_images=p[1:], duration=ms, loop=0, optimize=True, disposal=2)


def main():
    os.makedirs(CIKTI, exist_ok=True)

    # Kor Kristali
    kristal = Model(os.path.join(BM, "models", "kor_kristali.bbmodel"))
    G = 320
    kareler = []
    for i in range(40):                       # idle 4 sn → 40 kare × 100 ms
        t = i * 0.1
        r, p = ciz(kristal, "idle", t, G, G / 34, (0, 11, 0), 25, 18)
        kareler.append(birlestir(r, p, gece(G)))
    gif_yaz(os.path.join(CIKTI, "kor_kristali.gif"), kareler, 100)
    r, p = ciz(kristal, "idle", 0.6, 512, 512 / 34, (0, 11, 0), 25, 18)
    birlestir(r, p, gece(512)).save(os.path.join(CIKTI, "kor_kristali.png"), optimize=True)

    # Emote'lar
    emote = Model(os.path.join(BM, "players", "kami_emote.bbmodel"), {0: onizleme_skini()})
    G = 260
    serit = []
    for ad, anim in emote.animasyonlar.items():
        uz = anim["length"]
        n = int(uz / 0.06) + 1
        kareler = []
        for i in range(n):
            t = i * 0.06
            r, p = ciz(emote, ad, t, G, G / 44, (0, 16, 0), 25, 8)
            kareler.append(birlestir(r, p, gunduz(G), bloom=0))
        kareler += [kareler[-1]] * (8 if anim["loop"] != "loop" else 0)
        gif_yaz(os.path.join(CIKTI, f"emote_{ad}.gif"), kareler, 60)
        serit.append([kareler[int(len(kareler) * f)] for f in (0.0, 0.25, 0.45, 0.65)])
    tuval = Image.new("RGB", (4 * G + 50, len(serit) * (G + 10) + 10), (20, 20, 28))
    for j, satir in enumerate(serit):
        for i, k in enumerate(satir):
            tuval.paste(k, (10 + i * (G + 10), 10 + j * (G + 10)))
    tuval.save(os.path.join(CIKTI, "emote_onizleme.png"), optimize=True)
    print("Önizlemeler:", ", ".join(sorted(f for f in os.listdir(CIKTI) if f.startswith(("kor_kristali", "emote_")))))


if __name__ == "__main__":
    main()
