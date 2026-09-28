#!/usr/bin/env bash
# scripts/mc ve scripts/new-server.sh testleri (SPEC §5, §8).
# systemctl ve journalctl, PATH'in başına konan sahte betiklerle taklit edilir (çağrılar
# $FAKE_LOG'a yazılır); RCON için yerel bir sahte sunucu (python3) başlatılır.
# Gereken: YQ=<mikefarah yq yolu> (tests/run.sh ayarlar), python3.
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(dirname "$HERE")"
FIX="$HERE/fixtures/apply"
: "${YQ:?YQ=<mikefarah yq yolu> gerekli}"
export YQ
# start/stop/init/countdown require_root çağırır; bu yollar ancak root ile sınanabilir.
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    printf '[hata] test_mc.sh root gerektirir (require_root yolları sınanıyor): sudo -E tests/run.sh\n' >&2
    exit 1
fi

PASS=0 FAIL=0
TMPS=()
MOCK_PID=""
cleanup() {
    [[ -z $MOCK_PID ]] || kill "$MOCK_PID" 2>/dev/null || true
    ((${#TMPS[@]} == 0)) || rm -rf "${TMPS[@]}"
}
trap cleanup EXIT

ok() {
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
}
nok() {
    FAIL=$((FAIL + 1))
    printf '  HATA  %s\n' "$1"
    if [[ -n ${2:-} ]]; then printf '%s\n' "$2" | sed 's/^/        | /'; fi
}
check() {
    local d=$1
    shift
    if "$@"; then ok "$d"; else nok "$d" "${OUT:-}"; fi
}
has() { grep -qF -- "$2" "$1"; }
line_is() { grep -qxF -- "$2" "$1"; }
out_has() { grep -qF -- "$1" <<<"$OUT"; }
out_lacks() { ! grep -qF -- "$1" <<<"$OUT"; }
eq() {
    if [[ $1 == "$2" ]]; then return 0; fi
    printf '        beklenen: %q\n        gelen:    %q\n' "$2" "$1"
    return 1
}
# Sahte systemctl günlüğündeki start/stop satırları (sırasıyla).
unit_calls() { grep -E '^(start|stop|restart) ' "$FAKE_LOG" 2>/dev/null | paste -sd'|' - || true; }
# Sahte systemctl durumunu sıfırlar (tüm birimler kapalı).
clear_active() { find "${FAKE_STATE:?}" -maxdepth 1 -name '*.active' -delete; }

mc() { # çıktı: $OUT, dönüş: $RC
    RC=0
    OUT=$(bash "$REPO/scripts/mc" "$@" 2>&1) || RC=$?
}

setup() {
    T=$(mktemp -d "${TMPDIR:-/tmp}/kami-test.XXXXXX")
    TMPS+=("$T")
    REPO="$T/repo"
    mkdir -p "$REPO/scripts" "$T/root/servers" "$T/etc" "$T/systemd" "$T/run" "$T/bin" "$T/state"
    cp "$ROOT/scripts/lib.sh" "$ROOT/scripts/rcon.py" "$ROOT/scripts/mc" \
        "$ROOT/scripts/apply-config.sh" "$ROOT/scripts/new-server.sh" "$REPO/scripts/"
    cp -R "$FIX/config" "$REPO/config"
    printf "RCON_PASSWORD='test-rcon'\nDB_PASSWORD='test-db'\n" >"$T/etc/secrets.env"
    chmod 600 "$T/etc/secrets.env"
    printf 'MemTotal:       65000000 kB\nSwapTotal:       2097148 kB\n' >"$T/meminfo"
    MC_USER=$(id -un)
    export MC_ROOT="$T/root" MC_ETC="$T/etc" MC_RUN_DIR="$T/run" MC_USER MC_SYSTEMD_DIR="$T/systemd"
    export MC_NO_SYSTEMD=1 MC_MEMINFO="$T/meminfo" MC_POLL_INTERVAL=0.1 MC_READY_TIMEOUT=5 MC_RCON_WAIT=5
    export FAKE_LOG="$T/systemctl.log" FAKE_JLOG="$T/journalctl.log" FAKE_STATE="$T/state"
    export PATH="$T/bin:$ORIG_PATH"
    write_fakes
}

write_fakes() {
    cat >"$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
# Sahte systemctl: çağrıyı günlüğe yazar; durumu $FAKE_STATE/<birim>.active ile tutar.
printf '%s\n' "$*" >>"$FAKE_LOG"
cmd=$1; shift
case $cmd in
    start|restart)
        for u in "$@"; do
            : >"$FAKE_STATE/$u.active"
            # İsteğe bağlı kanca: sunucunun açılışta yaptıklarını (config üretme) taklit eder.
            [[ ! -x $FAKE_STATE/on-start ]] || "$FAKE_STATE/on-start" "$u"
        done ;;
    stop) for u in "$@"; do rm -f "$FAKE_STATE/$u.active"; done ;;
    is-active)
        for u in "$@"; do [[ $u == -* ]] && continue; [[ -e $FAKE_STATE/$u.active ]] || exit 3; done ;;
    show)
        props=() value=0 unit=""
        while (($#)); do
            case $1 in -p) props+=("$2"); shift ;; --value) value=1 ;; *) unit=$1 ;; esac
            shift
        done
        for p in "${props[@]}"; do
            if [[ -e $FAKE_STATE/$unit.failed ]]; then st=failed sub=failed mem="[not set]"
            elif [[ -e $FAKE_STATE/$unit.active ]]; then st=active sub=running mem=1073741824
            else st=inactive sub=dead mem="[not set]"; fi
            case $p in ActiveState) v=$st ;; SubState) v=$sub ;; MemoryCurrent) v=$mem ;; *) v="" ;; esac
            if ((value)); then printf '%s\n' "$v"; else printf '%s=%s\n' "$p" "$v"; fi
        done ;;
esac
exit 0
EOF
    cat >"$T/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
# Sahte journalctl: argümanları günlüğe yazar; $FAKE_STATE/noready yoksa hazır satırı basar.
# Eklentilerin "Done (" satırları (Sonar, Paper eklentisi) her zaman basılır: hazır sayılmamalı.
printf '%s\n' "$*" >>"$FAKE_JLOG"
[[ " $* " == *" -f "* ]] && exit 0
printf '[12:00:00 INFO]: Starting minecraft server\n'
printf '[12:00:01 INFO] [sonar]: Done (0.52s)!\n'
printf '[12:00:02 INFO]: [Eklenti] Done (1.000s)! For help, type "help"\n'
[[ -e $FAKE_STATE/noready ]] || printf '[12:00:03 INFO]: Done (3.210s)! For help, type "help"\n'
EOF
    cat >"$T/bin/ss" <<'EOF'
#!/usr/bin/env bash
# Sahte ss -ltn: çalışan birimlerin $FAKE_STATE/<birim>.listen satırlarını ve
# $FAKE_STATE/static.listen'i basar.
printf 'State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
for f in "$FAKE_STATE"/*.listen; do
    [[ -e $f ]] || continue
    u=$(basename "$f" .listen)
    if [[ $u == static || -e $FAKE_STATE/$u.active ]]; then cat "$f"; fi
done
exit 0
EOF
    chmod +x "$T/bin/systemctl" "$T/bin/journalctl" "$T/bin/ss"
}

start_mock_rcon() { # tüm backend'lerin RCON_PORT'u sahte sunucuya yönlendirilir
    cat >"$T/mock_rcon.py" <<'EOF'
import os, socket, struct, sys, threading
port_file, log_file, password, reject_file = sys.argv[1:5]
def rejected(body):
    # reject_file: satır başına bir önek; eşleşen komuta Brigadier hata yanıtı döner
    try:
        with open(reject_file, encoding="utf-8") as f:
            return any(p and body.startswith(p) for p in f.read().splitlines())
    except FileNotFoundError:
        return False
lock = threading.Lock()
def rx(c, n):
    b = b""
    while len(b) < n:
        x = c.recv(n - len(b))
        if not x:
            raise EOFError
        b += x
    return b
def send(c, i, t, body):
    d = struct.pack("<ii", i, t) + body.encode("utf-8") + b"\0\0"
    c.sendall(struct.pack("<i", len(d)) + d)
def handle(c):
    try:
        while True:
            (n,) = struct.unpack("<i", rx(c, 4))
            p = rx(c, n)
            i, t = struct.unpack("<ii", p[:8])
            body = p[8:-2].decode("utf-8")
            if t == 3:
                send(c, i if body == password else -1, 2, "")
            elif t == 2:
                with lock, open(log_file, "a", encoding="utf-8") as f:
                    f.write(body + "\n")
                if os.environ.get("FAKE_LOG"):
                    with lock, open(os.environ["FAKE_LOG"], "a", encoding="utf-8") as f:
                        f.write("rcon " + body + "\n")
                if rejected(body):
                    send(c, i, 0, "Unknown or incomplete command, see below for error\n" + body + "<--[HERE]")
                else:
                    send(c, i, 0, "Tamam: " + body)
            else:
                send(c, i, 0, "Unknown request %x" % t)
    except EOFError:
        pass
    finally:
        c.close()
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen()
with open(port_file + ".tmp", "w") as f:
    f.write(str(s.getsockname()[1]))
os.replace(port_file + ".tmp", port_file)
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
EOF
    RCON_LOG="$T/rcon.log" RCON_REJECT="$T/rcon.reject"
    : >"$RCON_LOG"
    : >"$RCON_REJECT"
    python3 "$T/mock_rcon.py" "$T/rcon.port" "$RCON_LOG" test-rcon "$RCON_REJECT" &
    MOCK_PID=$!
    local i
    for ((i = 0; i < 100; i++)); do
        [[ -s $T/rcon.port ]] && break
        sleep 0.05
    done
    MOCK_PORT=$(cat "$T/rcon.port")
    sed -i "s/^RCON_PORT=.*/RCON_PORT=\"$MOCK_PORT\"/" \
        "$REPO/config/servers/lobby/server.env" "$REPO/config/servers/survival/server.env"
}

stop_mock_rcon() {
    [[ -z $MOCK_PID ]] || kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
    MOCK_PID=""
}

ORIG_PATH=$PATH

# -----------------------------------------------------------------------------
echo "# yardım ve argüman denetimi"
setup
mc help
check "mc help çıkış 0" eq "$RC" 0
check "yardım Türkçe başlık" out_has "Kullanım: mc <komut>"
missing=""
for c in download apply init new-server build-librelogin start stop restart status log cmd rcon say countdown-restart backup restore doctor; do
    grep -qE "^  $c( |$)" <<<"$OUT" || missing+=" $c"
done
check "yardım tüm alt komutları listeler" eq "$missing" ""
check "yardım tanımlı sunucuları listeler" out_has "Tanımlı: velocity limbo lobby survival"
mc
check "argümansız mc yardımı basar" out_has "Kullanım: mc <komut>"
mc --help
check "mc --help çıkış 0" eq "$RC" 0

bad_cases=(
    "bilinmeyen-komut" "log" "log yok" "log all" "cmd lobby" "cmd yok say x" "rcon velocity list"
    "rcon lobby" "start yok" "start lobby survival" "stop yok" "restart yok" "status yok"
    "init" "init yok --accept-eula" "init lobby --yanlis" "countdown-restart abc"
    "countdown-restart 0" "say" "doctor fazla"
)
for args in "${bad_cases[@]}"; do
    read -ra argv <<<"$args"
    mc "${argv[@]}"
    if ((RC != 0)); then ok "reddedildi: mc $args"; else nok "reddedilmeliydi: mc $args" "$OUT"; fi
done
mc bilinmeyen-komut
check "bilinmeyen komut mesajı" out_has "Bilinmeyen komut: bilinmeyen-komut"
mc start yok
check "tanımsız sunucu mesajı" out_has "Tanımsız sunucu: yok"
mc rcon velocity list
check "velocity'de RCON yok mesajı" out_has "yalnız paper"
mc init lobby
check "EULA'sız init reddedildi" test "$RC" -ne 0
check "EULA bağlantısı gösterildi" out_has "https://aka.ms/MinecraftEULA"
check "EULA'sız init hiçbir şey oluşturmadı" test ! -e "$T/root/servers/lobby"

# -----------------------------------------------------------------------------
echo "# start/stop/restart sırası (sahte systemctl)"
setup
mc start all
check "start all çıkış 0" eq "$RC" 0
check "start all: önce backend'ler (limbo dahil), sonra velocity" eq "$(unit_calls)" \
    "start mc@limbo.service mc@lobby.service mc@survival.service|start mc@velocity.service"
: >"$FAKE_LOG"
mc stop all
check "stop all: önce velocity, sonra diğerleri (limbo dahil)" eq "$(unit_calls)" \
    "stop mc@velocity.service|stop mc@limbo.service mc@lobby.service mc@survival.service"
: >"$FAKE_LOG"
mc restart all
check "restart all: stop (velocity önce) + start (backend'ler önce)" eq "$(unit_calls)" \
    "stop mc@velocity.service|stop mc@limbo.service mc@lobby.service mc@survival.service|start mc@limbo.service mc@lobby.service mc@survival.service|start mc@velocity.service"
: >"$FAKE_LOG"
mc start
check "hedefsiz start = all" eq "$(unit_calls)" \
    "start mc@limbo.service mc@lobby.service mc@survival.service|start mc@velocity.service"
: >"$FAKE_LOG"
mc start lobby
check "tek sunucu start" eq "$(unit_calls)" "start mc@lobby.service"
: >"$FAKE_LOG"
mc restart survival
check "tek sunucu restart = stop + start" eq "$(unit_calls)" "stop mc@survival.service|start mc@survival.service"

echo "# status ve log"
: >"$FAKE_STATE/mc@lobby.service.active"
rm -f "$FAKE_STATE/mc@survival.service.active"
mc status
check "status çıkış 0" eq "$RC" 0
check "status başlık satırı" out_has "SUNUCU"
check "status lobby satırı (tür, port, durum, RSS, heap)" \
    grep -qE '^lobby +paper +30066 +active \(running\) +1\.0G +1536M$' <<<"$OUT"
check "status survival kapalı, RSS '-'" grep -qE '^survival +paper +30067 +inactive \(dead\) +- +7G$' <<<"$OUT"
check "status sırası velocity önce" eq "$(sed -n '2p' <<<"$OUT" | awk '{print $1}')" velocity
check "status limbo satırı (heap yok)" grep -qE '^limbo +limbo +30065 +[a-z]+ \([a-z-]+\) +[0-9.GM-]+ +-$' <<<"$OUT"
mc status lobby
check "status tek sunucu" eq "$(wc -l <<<"$OUT")" 2
mc log lobby
check "log journalctl'i doğru argümanlarla çağırdı" eq "$(tail -n1 "$FAKE_JLOG")" "-u mc@lobby.service -f -o cat"
mc log survival -n 50
check "log ek argümanları aktarır" eq "$(tail -n1 "$FAKE_JLOG")" "-u mc@survival.service -f -o cat -n 50"

echo "# cmd: konsol FIFO'suna yazma"
mc cmd lobby say merhaba
check "FIFO yokken hata" test "$RC" -ne 0
check "FIFO yok mesajı" out_has "Konsol girişi yok"
: >"$T/run/lobby.stdin"
mc cmd lobby say merhaba dünya
check "cmd çıkış 0" eq "$RC" 0
check "cmd tek satır yazdı" eq "$(cat "$T/run/lobby.stdin")" "say merhaba dünya"
: >"$T/run/velocity.stdin"
mc cmd velocity glist all
check "cmd velocity'ye de yazar" eq "$(cat "$T/run/velocity.stdin")" "glist all"
mc cmd lobby "$(printf 'say a\nop kotu')"
check "satır sonu içeren komut reddedildi" test "$RC" -ne 0

echo "# delegasyon (download/backup/restore/apply/build-librelogin)"
for s in download backup build-librelogin; do
    printf '#!/usr/bin/env bash\necho "%s.sh $*"\n' "$s" >"$REPO/scripts/$s.sh"
done
mc download plugins lobby
check "download → download.sh argümanlarla" eq "$OUT" "download.sh plugins lobby"
mc backup all
check "backup all → backup.sh all" eq "$OUT" "backup.sh all"
mc backup prune
check "backup prune → backup.sh prune" eq "$OUT" "backup.sh prune"
mc backup list
check "backup list → backup.sh list" eq "$OUT" "backup.sh list"
mc restore survival abc123
check "restore → backup.sh restore <srv> <snapshot>" eq "$OUT" "backup.sh restore survival abc123"
mc build-librelogin --commit 39397c4 --keep-jdk --dry-run
check "build-librelogin → build-librelogin.sh argümanlarla" eq "$OUT" "build-librelogin.sh --commit 39397c4 --keep-jdk --dry-run"
mc apply --dry-run lobby
check "apply → apply-config.sh (dry-run)" out_has "hiçbir dosya yazılmadı"
rm -f "$REPO/scripts/download.sh"
mc download
check "eksik alt betik anlaşılır hata" out_has "Bulunamadı:"

# -----------------------------------------------------------------------------
echo "# rcon / say / countdown-restart (sahte RCON sunucusu)"
setup
start_mock_rcon
mc rcon lobby list
check "rcon çıkış 0" eq "$RC" 0
check "rcon yanıtı basıldı" eq "$OUT" "Tamam: list"
mc rcon lobby say merhaba dünya
check "rcon argümanları tek komutta birleştirir" eq "$(tail -n1 "$RCON_LOG")" "say merhaba dünya"
: >"$RCON_LOG"
: >"$FAKE_STATE/mc@lobby.service.active"
mc say Bakım 10 dakika sonra
check "say çıkış 0" eq "$RC" 0
check "say yalnız çalışan backend'e gitti" eq "$(cat "$RCON_LOG")" "say Bakım 10 dakika sonra"

: >"$RCON_LOG"
: >"$FAKE_LOG"
clear_active
mc countdown-restart 2
check "hiçbir şey çalışmıyorken countdown atlanır" out_has "yeniden başlatma atlandı"
check "atlanınca systemctl start/stop yok" eq "$(unit_calls)" ""
for u in velocity lobby survival; do : >"$FAKE_STATE/mc@$u.service.active"; done
MC_NO_SLEEP=1 mc countdown-restart 2
check "countdown çıkış 0" eq "$RC" 0
check "countdown 4 duyuru × 2 backend" eq "$(grep -c '^say ' "$RCON_LOG")" 8
check "countdown duyuru sırası" eq "$(awk '!seen[$0]++' "$RCON_LOG" | paste -sd'|' -)" \
    "say Sunucu 2 dakika içinde yeniden başlatılacak.|say Sunucu 1 dakika içinde yeniden başlatılacak.|say Sunucu 30 saniye içinde yeniden başlatılacak.|say Sunucu 10 saniye içinde yeniden başlatılacak. Görüşmek üzere!"
check "countdown sonunda çalışanlar yeniden başlatıldı (sıra: velocity durur önce, en son başlar)" eq "$(unit_calls)" \
    "stop mc@velocity.service|stop mc@lobby.service mc@survival.service|start mc@lobby.service mc@survival.service|start mc@velocity.service"

echo "# countdown: bilerek durdurulmuş sunucu başlatılmaz"
: >"$RCON_LOG"
: >"$FAKE_LOG"
clear_active
for u in velocity lobby limbo; do : >"$FAKE_STATE/mc@$u.service.active"; done
MC_NO_SLEEP=1 mc countdown-restart 1
check "countdown (survival kapalı) çıkış 0" eq "$RC" 0
check "yalnız çalışanlar yeniden başlatıldı (survival kapalı kaldı, limbo dahil)" eq "$(unit_calls)" \
    "stop mc@velocity.service|stop mc@limbo.service mc@lobby.service|start mc@limbo.service mc@lobby.service|start mc@velocity.service"
check "survival başlatılmadı" test ! -e "$FAKE_STATE/mc@survival.service.active"
check "dakika=1: 3 duyuru, yalnız çalışan paper'a" eq "$(grep -c '^say ' "$RCON_LOG")" 3

echo "# countdown: RCON yapılandırma hatası geri sayımı durdurmaz"
: >"$RCON_LOG"
: >"$FAKE_LOG"
: >"$FAKE_STATE/mc@survival.service.active"
cp "$REPO/config/servers/survival/server.env" "$T/survival.env.bak"
sed -i 's/^RCON_PORT=.*/RCON_PORT=""/' "$REPO/config/servers/survival/server.env"
MC_NO_SLEEP=1 mc countdown-restart 1
check "bozuk RCON_PORT'ta countdown yine çıkış 0" eq "$RC" 0
check "bozuk sunucu için uyarı" out_has "survival: duyuru gönderilemedi"
check "diğer sunucuya duyurular gitti" eq "$(grep -c '^say ' "$RCON_LOG")" 3
check "yeniden başlatma yine yapıldı" eq "$(unit_calls)" \
    "stop mc@velocity.service|stop mc@limbo.service mc@lobby.service mc@survival.service|start mc@limbo.service mc@lobby.service mc@survival.service|start mc@velocity.service"
cp "$T/survival.env.bak" "$REPO/config/servers/survival/server.env"

echo "# countdown: yedek kilidi tutuluyorsa yeniden başlatma yapılmaz"
: >"$RCON_LOG"
: >"$FAKE_LOG"
# Kilidi tutan tek süreç sleep olsun (exec): kill onu ve kilidi birlikte bitirir.
(
    exec 9>>"$T/root/.backup.lock"
    flock 9
    exec sleep 30
) &
LOCK_PID=$!
for ((i = 0; i < 50; i++)); do
    if ! flock -n "$T/root/.backup.lock" true; then break; fi
    sleep 0.05
done
MC_NO_SLEEP=1 MC_LOCK_WAIT=1 mc countdown-restart 1
check "kilit tutulurken countdown hata verir" test "$RC" -ne 0
check "kilit mesajı" out_has "Yedekleme/geri yükleme sürüyor"
check "kilit tutulurken systemctl start/stop yok" eq "$(unit_calls)" ""
check "kilit tutulurken duyuru yapılmadı" eq "$(grep -c '^say ' "$RCON_LOG")" 0
kill "$LOCK_PID" 2>/dev/null || true
wait "$LOCK_PID" 2>/dev/null || true
MC_NO_SLEEP=1 MC_LOCK_WAIT=1 mc countdown-restart 1
check "kilit bırakılınca countdown çalışır" eq "$RC" 0

echo "# mc init"
: >"$FAKE_LOG"
clear_active
mc init lobby --accept-eula
check "server.jar yokken init hata verir" test "$RC" -ne 0
check "server.jar yok mesajı 'mc download' önerir" out_has "mc download"
check "init sunucu dizinini 0750 oluşturdu" eq "$(stat -c '%a' "$T/root/servers/lobby" 2>/dev/null)" 750
: >"$T/root/servers/lobby/server.jar"
MC_NO_SYSTEMD=1 mc init lobby --accept-eula
check "MC_NO_SYSTEMD=1 init çıkış 0" eq "$RC" 0
check "eula.txt eula=true" line_is "$T/root/servers/lobby/eula.txt" "eula=true"
check "eula.txt modu 0640" eq "$(stat -c '%a' "$T/root/servers/lobby/eula.txt")" 640
check "init apply çalıştırdı (server.properties)" line_is "$T/root/servers/lobby/server.properties" "rcon.port=$MOCK_PORT"
check "MC_NO_SYSTEMD=1 iken systemctl çağrılmadı" eq "$(unit_calls)" ""

# Açılış kancası: LuckPerms ilk açılışta varsayılan (H2) config üretir; her açılışta depo türünü günlüğe yazar.
cat >"$FAKE_STATE/on-start" <<'EOF'
#!/usr/bin/env bash
[[ $1 == mc@lobby.service ]] || exit 0
d=$MC_ROOT/servers/lobby/plugins/LuckPerms
if [[ ! -f $d/config.yml ]]; then
    mkdir -p "$d"
    printf 'server: global\nstorage-method: h2\ndata:\n  address: localhost\n  password: ""\n' >"$d/config.yml"
fi
printf 'lp-acilis %s\n' "$(sed -n 's/^storage-method: //p' "$d/config.yml")" >>"$FAKE_LOG"
EOF
chmod +x "$FAKE_STATE/on-start"
: >"$RCON_LOG"
: >"$FAKE_LOG"
: >"$FAKE_JLOG"
mv "$T/systemd/mc@lobby.service.d" "$T/dropin-eski" # drop-in yeniden yazılsın → daemon-reload beklenir
MC_NO_SYSTEMD=0 mc init lobby --accept-eula
check "tam init akışı çıkış 0" eq "$RC" 0
check "init: aç → kapat → apply → aç (init komutları) → kapat" eq "$(unit_calls)" \
    "start mc@lobby.service|stop mc@lobby.service|start mc@lobby.service|stop mc@lobby.service"
check "init: init komutları LuckPerms MariaDB'ye geçtikten SONRA çalıştı" \
    eq "$(grep -E '^(lp-acilis|rcon lp )' "$FAKE_LOG" | paste -sd'|' -)" \
    "lp-acilis h2|lp-acilis MariaDB|rcon lp group default permission set kami.test true"
check "init: ikinci apply LuckPerms override'ını uyguladı" line_is "$T/root/servers/lobby/plugins/LuckPerms/config.yml" "storage-method: MariaDB"
check "init: journalctl --since (mikrosaniyeli) ile günlük okundu" \
    grep -qE -- '^-u mc@lobby\.service --since [0-9-]+ [0-9:]+\.[0-9]{6} -o cat' "$FAKE_JLOG"
check "init: iki açılış için iki ayrı --since" eq "$(grep -oE -- '--since [0-9-]+ [0-9:.]+' "$FAKE_JLOG" | sort -u | wc -l)" 2
check "init: daemon-reload çağrıldı (drop-in yazıldı)" has "$FAKE_LOG" "daemon-reload"
check "init: RCON yoklama + init komutları sırayla (yorum/boş hariç, '/' kırpılır)" \
    eq "$(paste -sd'|' - <"$RCON_LOG")" \
    "list|gamerule minecraft:spawn_mobs false|gamerule minecraft:advance_time false|lp group default permission set kami.test true"
check "init: bitti mesajı + sonraki adım" out_has "sudo mc start lobby"
check "init: eklenti 'Done' satırları varken Paper'ın kendi satırıyla hazır" out_has "lobby hazır."
mv "$FAKE_STATE/on-start" "$T/on-start.kullanildi"

: >"$FAKE_LOG"
mkdir -p "$T/root/servers/survival" && : >"$T/root/servers/survival/server.jar"
: >"$FAKE_STATE/mc@survival.service.failed"
MC_NO_SYSTEMD=0 mc init survival --accept-eula
check "başlatma başarısızsa init hata verir" test "$RC" -ne 0
check "başarısız başlatma mesajı" out_has "başlatılamadı"
check "başarısızlıkta sunucu durduruldu" eq "$(unit_calls)" "start mc@survival.service|stop mc@survival.service"
mv "$FAKE_STATE/mc@survival.service.failed" "$T/failed.kullanildi"

: >"$FAKE_STATE/noready"
: >"$FAKE_LOG"
MC_NO_SYSTEMD=0 MC_READY_TIMEOUT=1 mc init survival --accept-eula
check "yalnız eklenti 'Done' satırları varken zaman aşımı (paper)" test "$RC" -ne 0
check "zaman aşımı mesajı" out_has "zaman aşımı"
clear_active
mkdir -p "$T/root/servers/velocity" && : >"$T/root/servers/velocity/server.jar"
MC_NO_SYSTEMD=0 MC_READY_TIMEOUT=1 mc init velocity --accept-eula
check "Sonar'ın 'Done (…)!' satırı velocity'yi hazır saydırmaz" out_has "velocity: zaman aşımı"
mv "$FAKE_STATE/noready" "$T/noready.kullanildi"
clear_active

: >"$FAKE_STATE/mc@lobby.service.active"
MC_NO_SYSTEMD=0 mc init lobby --accept-eula
check "çalışan sunucuda init reddedilir" out_has "önce 'mc stop lobby'"
clear_active

echo "# mc init limbo (PicoLimbo: EULA/RCON yok, ss ile port denetimi)"
: >"$FAKE_LOG"
: >"$RCON_LOG"
mc init limbo --accept-eula
check "pico_limbo yokken init limbo hata verir" out_has "limbo/pico_limbo yok"
LB="$T/root/servers/limbo"
printf '#!/bin/sh\n' >"$LB/pico_limbo"
chmod 0750 "$LB/pico_limbo"
printf 'LISTEN 0      4096   127.0.0.1:30065      0.0.0.0:*\n' >"$FAKE_STATE/mc@limbo.service.listen"
MC_NO_SYSTEMD=0 mc init limbo --accept-eula
check "init limbo çıkış 0" eq "$RC" 0
check "init limbo: yalnız bir açılış (start → stop)" eq "$(unit_calls)" "start mc@limbo.service|stop mc@limbo.service"
check "init limbo: port denetimi bildirildi" out_has "limbo hazır (127.0.0.1:30065 dinleniyor)"
check "init limbo: eula.txt yazılmadı" test ! -e "$LB/eula.txt"
check "init limbo: RCON kullanılmadı" eq "$(wc -c <"$RCON_LOG")" 0
check "init limbo: apply çalıştı (server.toml)" line_is "$LB/server.toml" 'bind = "127.0.0.1:30065"'
check "init limbo: 30-exec.conf yazıldı" line_is "$T/systemd/mc@limbo.service.d/30-exec.conf" \
    "ExecStart=/opt/minecraft/servers/%i/pico_limbo --config server.toml"
printf 'LISTEN 0      4096   0.0.0.0:30065      0.0.0.0:*\n' >"$FAKE_STATE/mc@limbo.service.listen"
: >"$FAKE_LOG"
MC_NO_SYSTEMD=0 mc init limbo --accept-eula
check "limbo dış arayüzde dinliyorsa init hata verir" test "$RC" -ne 0
check "dış arayüz mesajı" out_has "dış arayüzde dinleniyor"
check "hatada limbo durduruldu" eq "$(unit_calls)" "start mc@limbo.service|stop mc@limbo.service"
mv "$FAKE_STATE/mc@limbo.service.listen" "$T/listen.kullanildi"
clear_active
MC_NO_SYSTEMD=0 MC_READY_TIMEOUT=1 mc init limbo --accept-eula
check "limbo portu hiç açılmazsa zaman aşımı" out_has "30065 dinlenmedi"
clear_active
printf 'LISTEN 0      4096   127.0.0.1:30065      0.0.0.0:*\n' >"$FAKE_STATE/static.listen"
: >"$FAKE_LOG"
MC_NO_SYSTEMD=0 mc init limbo --accept-eula
check "port önceden kullanımdaysa limbo başlatılmaz" out_has "30065 portu zaten dinleniyor"
check "port doluyken systemctl start yok" eq "$(unit_calls)" ""
mv "$FAKE_STATE/static.listen" "$T/static.kullanildi"
chmod 0640 "$LB/pico_limbo"
mc init limbo --accept-eula
check "çalıştırılamaz pico_limbo reddedildi" out_has "çalıştırılabilir değil"
chmod 0750 "$LB/pico_limbo"

echo "# mc init all (limbo dahil)"
printf 'LISTEN 0      4096   127.0.0.1:30065      0.0.0.0:*\n' >"$FAKE_STATE/mc@limbo.service.listen"
: >"$FAKE_LOG"
: >"$RCON_LOG"
MC_NO_SYSTEMD=0 mc init all --accept-eula
check "init all çıkış 0" eq "$RC" 0
check "init all: limbo ve backend'ler önce, velocity en son" eq "$(unit_calls)" \
    "start mc@limbo.service|stop mc@limbo.service|start mc@lobby.service|stop mc@lobby.service|start mc@lobby.service|stop mc@lobby.service|start mc@survival.service|stop mc@survival.service|start mc@survival.service|stop mc@survival.service|start mc@velocity.service|stop mc@velocity.service"
check "init all: velocity'ye eula.txt yazılmadı" test ! -e "$T/root/servers/velocity/eula.txt"
check "init all: survival init komutu çalıştı" grep -qxF "gamerule minecraft:spawn_phantoms false" "$RCON_LOG"

echo "# mc init: 'gamerule minecraft:' reddedilirse öneksiz biçim bir kez denenir"
clear_active
: >"$RCON_LOG"
printf 'gamerule minecraft:\n' >"$RCON_REJECT"
MC_NO_SYSTEMD=0 mc init lobby --accept-eula
check "önekli biçim reddedilince init yine çıkış 0" eq "$RC" 0
check "her kural için önce önekli, sonra (bir kez) öneksiz biçim" eq "$(paste -sd'|' - <"$RCON_LOG")" \
    "list|gamerule minecraft:spawn_mobs false|gamerule spawn_mobs false|gamerule minecraft:advance_time false|gamerule advance_time false|lp group default permission set kami.test true"
check "reddedilen biçim günlükte" out_has "önekli biçim reddedildi: 'gamerule minecraft:spawn_mobs false'"
check "çalışan biçim günlükte" out_has "öneksiz biçim çalıştı: 'gamerule spawn_mobs false'"
check "özet: hangi kurallar öneksiz çalıştı" out_has "2 oyun kuralı yalnız öneksiz biçimle çalıştı: 'gamerule spawn_mobs false', 'gamerule advance_time false'"
check "başarı sayımı" out_has "lobby: 3 init komutu çalıştı, 0 başarısız."

clear_active
: >"$RCON_LOG"
printf 'gamerule \nlp \n' >"$RCON_REJECT"
MC_NO_SYSTEMD=0 mc init lobby --accept-eula
check "iki biçim de reddedilirse init çıkış 1" test "$RC" -ne 0
check "kural başına en çok iki deneme" eq "$(grep -c '^gamerule ' "$RCON_LOG")" 4
check "iki biçimde de başarısız mesajı" out_has "oyun kuralı iki biçimde de başarısız: 'gamerule minecraft:spawn_mobs false' ve 'gamerule spawn_mobs false'"
check "gamerule dışı komut hata yanıtında yeniden denenmez" eq "$(grep -c '^lp ' "$RCON_LOG")" 1
check "hata yanıtı veren komut başarısız sayılır" out_has "komut başarısız: lp group default permission set kami.test true"
check "başarısızlık özeti" out_has "lobby: 0 init komutu çalıştı, 3 başarısız."
check "init başarısız sunucuyu bildirir" out_has "Bazı init komutları başarısız oldu: lobby"
check "başarısızlıkta sunucu yine durduruldu" test ! -e "$FAKE_STATE/mc@lobby.service.active"

clear_active
: >"$RCON_LOG"
printf 'gamerule spawn_mobs\n' >"$RCON_REJECT"
MC_NO_SYSTEMD=0 mc init lobby --accept-eula
check "önekli biçim çalışınca ikinci deneme yok" eq "$(grep -c '^gamerule ' "$RCON_LOG")" 2
check "önekli biçim çalışınca uyarı yok" out_lacks "öneksiz"
: >"$RCON_REJECT"
stop_mock_rcon

echo "# init güvenlik: sunucu dizinindeki sembolik bağ root yetkisiyle izlenmez"
printf 'kurban=1\n' >"$T/kurban"
mv "$T/root/servers/lobby/eula.txt" "$T/eula.eski"
ln -s "$T/kurban" "$T/root/servers/lobby/eula.txt"
MC_NO_SYSTEMD=1 mc init lobby --accept-eula
check "eula.txt sembolik bağsa init reddeder" out_has "eula.txt sembolik bağ"
check "kurban dosyası değişmedi" eq "$(cat "$T/kurban")" "kurban=1"
unlink "$T/root/servers/lobby/eula.txt"
mkdir -p "$T/baska" "$REPO/config/servers/yeni-link"
ln -s "$T/baska" "$T/root/servers/yeni-link"
cp "$REPO/config/servers/lobby/server.env" "$REPO/config/servers/yeni-link/server.env"
MC_NO_SYSTEMD=1 mc init yeni-link --accept-eula
check "sunucu dizini sembolik bağsa init reddeder" out_has "sembolik bağ — güvenlik için reddedildi"
check "sembolik bağın hedefine yazılmadı" eq "$(ls -A "$T/baska")" ""
unlink "$T/root/servers/yeni-link"
mv "$REPO/config/servers/yeni-link" "$T/yeni-link.config"
if id daemon >/dev/null 2>&1; then
    chmod 0755 "$T" "$T/root"
    chown -R daemon:daemon "$T/root/servers"
    MC_USER=daemon MC_NO_SYSTEMD=1 mc init lobby --accept-eula
    check "MC_USER=daemon init çıkış 0" eq "$RC" 0
    check "eula.txt daemon kimliğiyle yazıldı (daemon:daemon 0640)" eq "$(stat -c '%U:%G %a' "$T/root/servers/lobby/eula.txt")" "daemon:daemon 640"
    mv "$T/root/servers/survival" "$T/survival.eski"
    MC_USER=daemon MC_NO_SYSTEMD=1 mc init survival --accept-eula
    check "sunucu dizini daemon kimliğiyle oluşturuldu" eq "$(stat -c '%U:%G %a' "$T/root/servers/survival")" "daemon:daemon 750"
fi

# -----------------------------------------------------------------------------
echo "# new-server uçtan uca"
setup
mc new-server skyblock 30068 4g
check "new-server çıkış 0" eq "$RC" 0
NS="$REPO/config/servers/skyblock"
check "server.env TYPE korundu" line_is "$NS/server.env" 'TYPE="paper"'
check "server.env PORT" line_is "$NS/server.env" 'PORT="30068"'
check "server.env RCON_PORT = port+1000" line_is "$NS/server.env" 'RCON_PORT="31068"'
check "server.env HEAP (büyük harfe çevrildi)" line_is "$NS/server.env" 'HEAP="4G"'
check "server.env CPU_WEIGHT=100" line_is "$NS/server.env" 'CPU_WEIGHT="100"'
check "server.env OOM_SCORE_ADJUST=100" line_is "$NS/server.env" 'OOM_SCORE_ADJUST="100"'
check "server.env EXTRA_JAVA_OPTS kaynaktan korundu" line_is "$NS/server.env" 'EXTRA_JAVA_OPTS="-XX:+UseCompactObjectHeaders"'
check "files/ ağacı kaynakla aynı" diff -r "$REPO/config/servers/survival/files" "$NS/files"
check "init-commands.txt kopyalandı" cmp -s "$REPO/config/servers/survival/init-commands.txt" "$NS/init-commands.txt"
VT="$REPO/config/servers/velocity/files/velocity.toml"
check "velocity.toml girişi 'try =' satırından hemen önce" eq \
    "$(grep -B1 -E '^try =' "$VT" | head -n1)" 'skyblock = "127.0.0.1:30068"'
check "velocity.toml diğer girişler korundu" line_is "$VT" 'survival = "127.0.0.1:30067"'
check "sonraki adımlar yazdırıldı" out_has "Sonraki adımlar:"
check "plugins.list ipucu (yalnız survival'a tanımlı eklenti)" out_has "survival           Chunky"
check "RAM bütçesi yazdırıldı" out_has "RAM bütçesi: 4 JVM"
check "yeterli RAM'de uyarı yok" out_lacks "RAM yetersiz"
check "gizli geçici dizin kalmadı" eq "$(find "$REPO/config/servers" -maxdepth 1 -name '.*' | wc -l)" 0
check "list_servers yeni sunucuyu görür" eq "$(bash -c '. "$1/scripts/lib.sh"; list_backends | paste -sd" " -' _ "$REPO")" "lobby skyblock survival"

printf 'MemTotal:        8000000 kB\n' >"$T/meminfo"
mc new-server minigame 30070 2G --from lobby
check "--from lobby çıkış 0" eq "$RC" 0
check "--from lobby dosyaları" diff -r "$REPO/config/servers/lobby/files" "$REPO/config/servers/minigame/files"
check "RAM yetersizse uyarı" out_has "RAM yetersiz"

toml_before=$(md5sum <"$VT")
new_fail_cases=(
    "skyblock 30090 1G" "yeni 30066 1G" "yeni 30068 1G" "yeni 29067 1G" "Kotu_Ad 30090 1G"
    "all 30090 1G" "yeni 30090 4X" "yeni abc 1G" "yeni 30090 1G --from velocity"
    "yeni 30090 1G --from yok" "yeni 30090" "yeni 25565 1G" "yeni 2306 1G" "yeni 64536 1G"
    "yeni 30065 1G" "yeni 30090 1G --from limbo"
)
for args in "${new_fail_cases[@]}"; do
    read -ra argv <<<"$args"
    mc new-server "${argv[@]}"
    if ((RC != 0)); then ok "new-server reddetti: $args"; else nok "new-server reddetmeliydi: $args" "$OUT"; fi
done
check "başarısız denemeler velocity.toml'u değiştirmedi" eq "$(md5sum <"$VT")" "$toml_before"
check "başarısız denemeler dizin bırakmadı" eq "$(find "$REPO/config/servers" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | paste -sd' ' -)" "limbo lobby minigame skyblock survival velocity"

cp "$VT" "$T/velocity.toml.bak"
sed -i '/^try = \[/,/^\]/d' "$VT"
mc new-server yeni 30090 1G
check "'try =' yoksa net hata" out_has "'try =' satırı bulunamadı"
check "'try =' hatasında sunucu dizini oluşmadı" test ! -e "$REPO/config/servers/yeni"
sed -i 's/^\[servers\]/[sunucular]/' "$VT"
mc new-server yeni 30090 1G
check "[servers] yoksa net hata" out_has "[servers] tablosu bulunamadı"
cp "$T/velocity.toml.bak" "$VT"

echo "# new-server sonrası apply ve başlatma sırası"
mc apply skyblock
check "yeni sunucuya apply çıkış 0" eq "$RC" 0
check "yeni sunucu jvm.env heap" line_is "$T/root/servers/skyblock/jvm.env" 'JAVA_MEM="-Xms4G -Xmx4G"'
check "yeni sunucu drop-in CPUWeight=100" line_is "$T/systemd/mc@skyblock.service.d/20-resources.conf" "CPUWeight=100"
check "yeni sunucu drop-in OOMScoreAdjust=100" line_is "$T/systemd/mc@skyblock.service.d/20-resources.conf" "OOMScoreAdjust=100"
mc apply velocity
check "velocity 10-order yeni backend'i içerir" line_is "$T/systemd/mc@velocity.service.d/10-order.conf" \
    "After=mc@limbo.service mc@lobby.service mc@minigame.service mc@skyblock.service mc@survival.service"
check "velocity.toml yeni girişle uygulandı" line_is "$T/root/servers/velocity/velocity.toml" 'skyblock = "127.0.0.1:30068"'
: >"$FAKE_LOG"
mc start all
check "start all yeni backend'i içerir" eq "$(unit_calls)" \
    "start mc@limbo.service mc@lobby.service mc@minigame.service mc@skyblock.service mc@survival.service|start mc@velocity.service"

# -----------------------------------------------------------------------------
echo "# doctor (duman testi)"
setup
mc doctor
check "doctor 0 ya da 1 ile çıkar" test "$RC" -le 1
bad_lines=$(grep -vE '^(\[TAMAM\]|\[UYARI\]|\[KRİTİK\]|\[bilgi\]) ' <<<"$OUT" || true)
check "doctor her satırı etiketli" eq "$bad_lines" ""
check "doctor eksik jar'ı KRİTİK bildirir" out_has "[KRİTİK] lobby:"
check "doctor limbo için pico_limbo'yu denetler" out_has "[KRİTİK] limbo: $T/root/servers/limbo/pico_limbo yok"
check "doctor limbo'nun boş HEAP'ini sorun saymaz" out_lacks "HEAP=''"
check "doctor RAM denetimi" grep -qE '^\[(TAMAM|UYARI)\] RAM' <<<"$OUT"
check "doctor secrets.env izinleri" out_has "secrets.env izinleri 600"
printf 'MemTotal:        8000000 kB\n' >"$T/meminfo"
mc doctor
check "doctor düşük RAM'de uyarı + öneri" grep -qE '^\[UYARI\] RAM yetersiz.*Öneri: survival' <<<"$OUT"
check "doctor swap yok uyarısı" out_has "[UYARI] Swap yok"

echo "# doctor: sahte java/ufw/ss/restic ile"
cat >"$T/bin/java" <<'EOF'
#!/bin/sh
printf 'Property settings:\n    java.home = /usr/lib/jvm/temurin-25-jre-amd64\n    java.version = %s\n' "${FAKE_JAVA_VERSION:-25.0.1}" >&2
EOF
cat >"$T/bin/ufw" <<'EOF'
#!/bin/sh
printf 'Status: active\n\nTo                         Action      From\n--                         ------      ----\n22/tcp                     LIMIT       Anywhere\n25565/tcp                  ALLOW       Anywhere\n'
EOF
cat >"$T/bin/ss" <<'EOF'
#!/bin/sh
printf 'State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
printf 'LISTEN 0      4096   127.0.0.1:30066      0.0.0.0:*\n'
printf 'LISTEN 0      4096   0.0.0.0:31067        0.0.0.0:*\n'
printf 'LISTEN 0      4096   [::1]:31066          [::]:*\n'
printf 'LISTEN 0      4096   0.0.0.0:30065        0.0.0.0:*\n'
EOF
cat >"$T/bin/restic" <<'EOF'
#!/bin/sh
printf '[{"time":"%s","hostname":"mc01","paths":["/opt/minecraft/servers/survival"]}]\n' \
    "$(date -u -d "${FAKE_BACKUP_AGE:-30 minutes} ago" '+%Y-%m-%dT%H:%M:%S.123456789+00:00')"
EOF
chmod +x "$T/bin/java" "$T/bin/ufw" "$T/bin/ss" "$T/bin/restic"
printf "RESTIC_REPOSITORY='/var/backups/minecraft/restic'\nRESTIC_PASSWORD_FILE=/dev/null\n" >"$T/etc/backup.env"
mkdir -p "$T/root/servers/limbo" && : >"$T/root/servers/limbo/pico_limbo"
MC_JAVA_BIN="$T/bin/java" mc doctor
check "doctor limbo pico_limbo var → TAMAM" out_has "[TAMAM] limbo: pico_limbo var."
check "doctor Java 25 TAMAM" out_has "[TAMAM] Java 25.0.1"
check "doctor UFW etkin" out_has "[TAMAM] UFW etkin."
check "doctor UFW 25565/tcp açık" out_has "[TAMAM] UFW: 25565/tcp açık."
check "doctor UFW 19132/udp kapalı → KRİTİK" out_has "[KRİTİK] UFW: 19132/udp açık değil"
check "doctor loopback port TAMAM" out_has "[TAMAM] lobby: 30066 yalnız 127.0.0.1'de."
check "doctor IPv6 loopback TAMAM" out_has "[TAMAM] lobby: 31066 yalnız 127.0.0.1'de."
check "doctor dışa açık RCON → KRİTİK" out_has "[KRİTİK] survival: 31067 dış arayüzde dinleniyor"
check "doctor dışa açık limbo → KRİTİK + bind ipucu" grep -qE '^\[KRİTİK\] limbo: 30065 dış arayüzde dinleniyor .*bind' <<<"$OUT"
check "doctor yerel yedek deposu uyarısı" out_has "[UYARI] Yedek deposu yerel"
check "doctor son yedek zamanı (restic JSON)" grep -qE '^\[TAMAM\] Son yedek (29|30|31) dakika önce' <<<"$OUT"
FAKE_BACKUP_AGE="30 hours" FAKE_JAVA_VERSION="25-ea" MC_JAVA_BIN="$T/bin/java" mc doctor
check "doctor EA Java → KRİTİK" out_has "[KRİTİK] Java 25-ea bir erken erişim"
check "doctor eski yedek → KRİTİK" out_has "[KRİTİK] Son yedek 30 saat önce"
check "doctor kritik varsa çıkış 1" eq "$RC" 1
FAKE_JAVA_VERSION="21.0.4" MC_JAVA_BIN="$T/bin/java" mc doctor
check "doctor Java 21 → KRİTİK" out_has "en az 25 gerekli"

echo "# doctor: LibreLogin commit ↔ plugins.list ↔ artifacts/"
check "LibreLogin satırı yokken denetim sessiz" out_lacks "LibreLogin:"
# shellcheck disable=SC2016  # plugins.list'te '$MC_ROOT' birebir yazılır
printf 'velocity LibreLogin local $MC_ROOT/artifacts/LibreLogin-39397c4.jar\n' >>"$REPO/config/plugins.list"
printf 'LIBRELOGIN_COMMIT="39397c47585e193d71cc84d3043f4a61df725124"\n' >>"$REPO/config/network.env"
MC_JAVA_BIN="$T/bin/java" mc doctor
check "doctor: derlenmemiş LibreLogin → UYARI + build-librelogin" \
    out_has "[UYARI] LibreLogin: $T/root/artifacts/LibreLogin-39397c4.jar yok — sudo mc build-librelogin"
mkdir -p "$T/root/artifacts" && : >"$T/root/artifacts/LibreLogin-39397c4.jar"
MC_JAVA_BIN="$T/bin/java" mc doctor
check "doctor: derlenmiş LibreLogin → TAMAM" out_has "[TAMAM] LibreLogin: LibreLogin-39397c4.jar derlenmiş."
printf 'LIBRELOGIN_COMMIT="abcdef0123456789abcdef0123456789abcdef01"\n' >>"$REPO/config/network.env"
MC_JAVA_BIN="$T/bin/java" mc doctor
check "doctor: commit ≠ plugins.list → KRİTİK" \
    out_has "[KRİTİK] LibreLogin: plugins.list LibreLogin-39397c4.jar gösteriyor ama network.env LIBRELOGIN_COMMIT LibreLogin-abcdef0.jar gerektiriyor"
check "doctor: uyuşmazlıkta çıkış 1" eq "$RC" 1

printf '\ntest_mc: %d geçti, %d başarısız\n' "$PASS" "$FAIL"
((FAIL == 0))
