#!/usr/bin/env python3
"""Bağımlılıksız Minecraft RCON istemcisi (yalnızca Python 3 standart kütüphanesi).

Kullanım:
    rcon.py [-H HOST] [-p PORT] [-P ŞİFRE | ortam: RCON_PASSWORD] KOMUT [KOMUT ...]

Her KOMUT ayrı bir RCON isteği olarak sırayla gönderilir ve yanıtı stdout'a
yazılır. Şifre verilmezse ortam değişkeni RCON_PASSWORD kullanılır.

Çıkış kodları: 0 başarılı, 1 bağlantı/protokol hatası, 2 kimlik doğrulama hatası.

Protokol (https://minecraft.wiki/w/RCON):
    int32le uzunluk | int32le istek-id | int32le tip | gövde (UTF-8) | 0x00 0x00
    tip 3 = giriş, tip 2 = komut, tip 0 = yanıt. Giriş reddedilirse id = -1 döner.
    Sunucu uzun yanıtları 4096 karakterlik parçalara böler ve her read()'de tek
    paket okur. Yanıtın bittiğini anlamak için ilk parça geldikten sonra geçersiz
    tipte bir işaret paketi gönderilir; sunucu paketleri sırayla işlediğinden
    işaretin yanıtı ("Unknown request c8") komut yanıtının sonunu gösterir.
"""

import argparse
import os
import socket
import struct
import sys

TYPE_RESPONSE = 0
TYPE_COMMAND = 2
TYPE_LOGIN = 3
TYPE_MARKER = 200           # geçersiz tip: yanıt sonu işareti
MAX_PACKET = 4096 * 4 + 10  # 4096 karakter, UTF-8'de karakter başına en çok 4 bayt
MAX_COMMAND_BYTES = 1446    # sunucunun kabul ettiği en uzun komut gövdesi


class RconError(Exception):
    pass


class AuthError(RconError):
    pass


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise RconError("bağlantı sunucu tarafından kapatıldı")
        buf += chunk
    return buf


def _send(sock, req_id, ptype, body):
    data = body.encode("utf-8")
    packet = struct.pack("<ii", req_id, ptype) + data + b"\x00\x00"
    sock.sendall(struct.pack("<i", len(packet)) + packet)


def _recv(sock):
    (length,) = struct.unpack("<i", _recv_exact(sock, 4))
    if length < 10 or length > MAX_PACKET:
        raise RconError(f"geçersiz paket uzunluğu: {length}")
    payload = _recv_exact(sock, length)
    req_id, ptype = struct.unpack("<ii", payload[:8])
    body = payload[8:-2].decode("utf-8", errors="replace")
    return req_id, ptype, body


class Rcon:
    def __init__(self, host, port, password, timeout=10.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self._next_id = 1
        req_id = self._id()
        _send(self.sock, req_id, TYPE_LOGIN, password)
        resp_id, _, _ = _recv(self.sock)
        if resp_id == -1 or resp_id != req_id:
            self.close()
            raise AuthError("RCON şifresi reddedildi")

    def _id(self):
        self._next_id += 1
        return self._next_id

    def command(self, cmd):
        if len(cmd.encode("utf-8")) > MAX_COMMAND_BYTES:
            raise RconError(f"komut çok uzun (en fazla {MAX_COMMAND_BYTES} bayt)")
        req_id = self._id()
        _send(self.sock, req_id, TYPE_COMMAND, cmd)
        resp_id, _, body = _recv(self.sock)
        if resp_id != req_id:
            raise RconError(f"beklenmeyen yanıt id'si: {resp_id}")
        parts = [body]
        # İşaret ancak ilk parça geldikten sonra gönderilir: sunucu komutu
        # çalıştırıp tüm parçaları yazdıktan sonra bir sonraki paketi okur.
        marker_id = self._id()
        _send(self.sock, marker_id, TYPE_MARKER, "")
        while True:
            resp_id, _, body = _recv(self.sock)
            if resp_id == marker_id:
                break
            if resp_id != req_id:
                raise RconError(f"beklenmeyen yanıt id'si: {resp_id}")
            parts.append(body)
        return "".join(parts)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def main(argv=None):
    ap = argparse.ArgumentParser(description="Minecraft RCON istemcisi")
    ap.add_argument("-H", "--host", default="127.0.0.1")
    ap.add_argument("-p", "--port", type=int, default=25575)
    ap.add_argument("-P", "--password", default=os.environ.get("RCON_PASSWORD"))
    ap.add_argument("-t", "--timeout", type=float, default=10.0)
    ap.add_argument("commands", nargs="+", metavar="KOMUT")
    args = ap.parse_args(argv)

    if not args.password:
        print("hata: RCON şifresi yok (-P veya RCON_PASSWORD)", file=sys.stderr)
        return 2

    try:
        rcon = Rcon(args.host, args.port, args.password, args.timeout)
    except AuthError as e:
        print(f"hata: {e}", file=sys.stderr)
        return 2
    except (OSError, RconError) as e:
        print(f"hata: {args.host}:{args.port} bağlanılamadı: {e}", file=sys.stderr)
        return 1

    try:
        for cmd in args.commands:
            out = rcon.command(cmd)
            if out:
                print(out)
    except (OSError, RconError) as e:
        print(f"hata: {e}", file=sys.stderr)
        return 1
    finally:
        rcon.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
