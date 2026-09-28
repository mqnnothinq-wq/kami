#!/usr/bin/env bash
# systemd/ birimlerinin testleri (systemd çalışmasa da olur):
#  1) systemd-analyze verify (geçici kopyada; /usr/bin/java ve /usr/local/bin/mc taslaklarla değiştirilir)
#  2) spec §9'daki anahtar yönergeler birebir
#  3) OnCalendar ifadeleri (systemd-analyze calendar)
#  4) ExecStartPre betiği: systemd'nin '$$' -> '$' dönüşümünden sonra sh ile gerçekten çalıştırılır
# Çalıştırma: bash tests/test_units.sh
set -Eeuo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
U="$REPO/systemd"
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT

PASS=0 FAILN=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAILN=$((FAILN + 1)); printf '  HATA %s\n' "$1"; [[ -n ${2:-} ]] && printf '       %s\n' "$2"; return 0; }
eq() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "beklenen: [$2] gerçek: [$3]"; fi; }

# get <dosya> <bölüm> <anahtar> — değer(ler)i yazar; '\' ile biten satırlar systemd gibi boşlukla birleştirilir.
get() {
    awk -v sec="[$2]" -v key="$3" '
        function flush() { if (buf != "") { handle(buf); buf = "" } }
        function handle(l,   k, v) {
            if (l ~ /^[[:space:]]*[#;]/ || l ~ /^[[:space:]]*$/) return
            if (l ~ /^\[/) { cur = l; sub(/[[:space:]]+$/, "", cur); return }
            if (cur != sec) return
            k = l; sub(/=.*/, "", k); gsub(/[[:space:]]/, "", k)
            if (k != key) return
            v = l; sub(/^[^=]*=[[:space:]]*/, "", v)
            print v
        }
        { line = $0
          if (line ~ /\\$/) { sub(/\\$/, " ", line); buf = buf line; next }
          buf = buf line; flush() }
        END { flush() }' "$1"
}

# expect <dosya> <bölüm> <anahtar> <beklenen> — tek değerli yönerge
expect() {
    local v
    v=$(get "$1" "$2" "$3")
    eq "${1##*/} [$2] $3=$4" "$4" "$v"
}

echo "== 1. systemd-analyze verify"
if ! command -v systemd-analyze >/dev/null 2>&1; then
    bad "systemd-analyze bulunamadı"
else
    mkdir -p "$T/units" "$T/bin"
    cp "$U"/* "$T/units/"
    printf '#!/bin/sh\nexit 0\n' >"$T/bin/java"
    printf '#!/bin/sh\nexit 0\n' >"$T/bin/mc"
    chmod +x "$T/bin/java" "$T/bin/mc"
    sed -i "s#/usr/bin/java#$T/bin/java#g; s#/usr/local/bin/mc#$T/bin/mc#g" "$T/units/"*
    for unit in mc@lobby.service mc@velocity.socket mc-backup.service mc-backup.timer mc-prune.service \
        mc-prune.timer mc-daily-restart.service mc-daily-restart.timer; do
        if out=$(cd "$T/units" && systemd-analyze verify --man=no "$T/units/$unit" 2>&1) && [[ -z $out ]]; then
            ok "verify $unit (uyarısız)"
        else
            bad "verify $unit" "$out"
        fi
    done
    # limbo: mc apply'ın yazdığı biçimde ExecStart'ı sıfırlayıp pico_limbo'ya çeviren drop-in ile geçerli mi?
    printf '#!/bin/sh\nexit 0\n' >"$T/bin/pico_limbo"
    chmod +x "$T/bin/pico_limbo"
    mkdir -p "$T/units/mc@limbo.service.d"
    printf '[Service]\nExecStart=\nExecStart=%s --config server.toml\n' "$T/bin/pico_limbo" \
        >"$T/units/mc@limbo.service.d/30-exec.conf"
    if out=$(cd "$T/units" && systemd-analyze verify --man=no "$T/units/mc@limbo.service" 2>&1) && [[ -z $out ]]; then
        ok "verify mc@limbo.service + 30-exec.conf drop-in (uyarısız)"
    else
        bad "verify mc@limbo.service + drop-in" "$out"
    fi
    # Denetim testin kendisi: bilinmeyen anahtar ve olmayan program yakalanmalı
    cp "$T/units/mc-prune.service" "$T/units/bozuk.service"
    printf 'Bilinmeyen=1\n' >>"$T/units/bozuk.service"
    sed -i "s#^ExecStart=.*#ExecStart=$T/yok/program#" "$T/units/bozuk.service"
    if ! out=$(cd "$T/units" && systemd-analyze verify --man=no "$T/units/bozuk.service" 2>&1) || [[ -n $out ]]; then
        ok "verify hatalı birimi yakalar"
    else
        bad "verify hatalı birimi yakalamadı"
    fi
fi

echo "== 2. Yönergeler (spec §9)"
S="$U/mc@.socket"
expect "$S" Unit PartOf 'mc@%i.service'
expect "$S" Socket ListenFIFO '/run/minecraft/%i.stdin'
expect "$S" Socket SocketUser minecraft
expect "$S" Socket SocketGroup minecraft
expect "$S" Socket SocketMode 0660
expect "$S" Socket DirectoryMode 0750
expect "$S" Socket RemoveOnStop yes

M="$U/mc@.service"
expect "$M" Unit Description 'Minecraft sunucusu (%i)'
expect "$M" Unit Wants network-online.target
expect "$M" Unit After 'network-online.target mariadb.service mc@%i.socket'
expect "$M" Unit Requires 'mc@%i.socket'
expect "$M" Unit StartLimitIntervalSec 600
expect "$M" Unit StartLimitBurst 5
expect "$M" Service Type exec
expect "$M" Service User minecraft
expect "$M" Service Group minecraft
expect "$M" Service WorkingDirectory '/opt/minecraft/servers/%i'
eq "mc@.service EnvironmentFile sırası (secrets, sonra jvm.env)" \
    "/etc/minecraft/secrets.env|/opt/minecraft/servers/%i/jvm.env" "$(get "$M" Service EnvironmentFile | paste -sd'|')"
expect "$M" Service Environment 'LANG=C.UTF-8'
# shellcheck disable=SC2016  # $JAVA_MEM vb. systemd'nin genişlettiği değişkenlerdir; birebir aranır
expect "$M" Service ExecStart '/usr/bin/java $JAVA_MEM $JAVA_OPTS -jar server.jar $SERVER_ARGS'
expect "$M" Service Sockets 'mc@%i.socket'
expect "$M" Service StandardInput socket
expect "$M" Service StandardOutput journal
expect "$M" Service StandardError journal
expect "$M" Service SyslogIdentifier 'mc-%i'
expect "$M" Service KillSignal SIGTERM
expect "$M" Service SuccessExitStatus '0 143'
expect "$M" Service TimeoutStopSec 180
expect "$M" Service Restart always
expect "$M" Service RestartSec 10
expect "$M" Service LimitNOFILE 65536
expect "$M" Service UMask 0027
for k in NoNewPrivileges PrivateTmp PrivateDevices ProtectHome ProtectKernelTunables ProtectKernelModules \
    ProtectKernelLogs ProtectControlGroups ProtectClock ProtectHostname RestrictSUIDSGID RestrictRealtime \
    RestrictNamespaces LockPersonality; do
    expect "$M" Service "$k" yes
done
expect "$M" Service ProtectSystem strict
expect "$M" Service ReadWritePaths '/opt/minecraft/servers/%i'
expect "$M" Service SystemCallArchitectures native
eq "mc@.service CapabilityBoundingSet= boş (tüm yetkiler düşer)" "1|" \
    "$(get "$M" Service CapabilityBoundingSet | wc -l)|$(get "$M" Service CapabilityBoundingSet)"
expect "$M" Service RestrictAddressFamilies 'AF_UNIX AF_INET AF_INET6 AF_NETLINK'
eq "mc@.service MemoryDenyWriteExecute YOK (JIT)" "" "$(get "$M" Service MemoryDenyWriteExecute)"
expect "$M" Install WantedBy multi-user.target

expect "$U/mc-backup.timer" Timer OnCalendar '*-*-* *:07:00'
expect "$U/mc-backup.timer" Timer RandomizedDelaySec 60
expect "$U/mc-backup.timer" Timer Persistent true
expect "$U/mc-backup.timer" Install WantedBy timers.target
expect "$U/mc-backup.service" Service Type oneshot
expect "$U/mc-backup.service" Service User root
expect "$U/mc-backup.service" Service ExecStart '/usr/local/bin/mc backup all'
expect "$U/mc-backup.service" Service Nice 10
expect "$U/mc-backup.service" Service IOSchedulingClass idle
expect "$U/mc-prune.timer" Timer OnCalendar '*-*-* 04:30:00'
expect "$U/mc-prune.timer" Timer Persistent true
expect "$U/mc-prune.timer" Install WantedBy timers.target
expect "$U/mc-prune.service" Service Type oneshot
expect "$U/mc-prune.service" Service ExecStart '/usr/local/bin/mc backup prune'
expect "$U/mc-daily-restart.timer" Timer OnCalendar '*-*-* 05:00:00'
expect "$U/mc-daily-restart.timer" Timer Persistent false
expect "$U/mc-daily-restart.timer" Install WantedBy timers.target
expect "$U/mc-daily-restart.service" Service Type oneshot
expect "$U/mc-daily-restart.service" Service ExecStart '/usr/local/bin/mc countdown-restart 5'

echo "== 3. OnCalendar"
cal() { systemd-analyze calendar --iterations=2 "$1" 2>&1 | awk -F': ' '/Normalized form/ { print $2 }'; }
if command -v systemd-analyze >/dev/null 2>&1; then
    eq "yedek: saatlik :07" '*-*-* *:07:00' "$(cal '*-*-* *:07:00')"
    eq "budama: günlük 04:30" '*-*-* 04:30:00' "$(cal '*-*-* 04:30:00')"
    eq "yeniden başlatma: günlük 05:00 (sistem saat dilimi)" '*-*-* 05:00:00' "$(cal '*-*-* 05:00:00')"
fi

echo "== 4. ExecStartPre (sh ile çalıştırma)"
pre=$(get "$M" Service ExecStartPre)
eq "ExecStartPre tek satır" "1" "$(printf '%s\n' "$pre" | grep -c .)"
if [[ $pre == "/bin/sh -c '"*"'" ]]; then ok "ExecStartPre: /bin/sh -c '...'"; else bad "ExecStartPre biçimi" "$pre"; fi
body=${pre#"/bin/sh -c '"}
body=${body%"'"}
if [[ $body != *"'"* ]]; then ok "betik içinde tek tırnak yok (systemd alıntısı bozulmaz)"; else bad "betikte tek tırnak var"; fi
if [[ $body != *\\* ]]; then ok "betik içinde ters eğik çizgi yok (C kaçışı yok)"; else bad "betikte ters eğik çizgi var"; fi
if [[ ${body//%%/} != *%* ]]; then ok "betik içinde systemd % belirteci yok"; else bad "betikte % var (%% yazılmalı)"; fi
if [[ ${body//\$\$/} != *\$* ]]; then ok "tüm '\$' işaretleri '\$\$' olarak kaçışlı"; else bad "kaçışsız \$ var: systemd kendisi genişletir"; fi
script=${body//\$\$/\$}
printf '%s\n' "$script" >"$T/pre.sh"
if sh -n "$T/pre.sh" 2>"$T/err"; then ok "sh -n sözdizimi"; else bad "sh -n" "$(<"$T/err")"; fi
if command -v shellcheck >/dev/null 2>&1; then
    if out=$(shellcheck -s sh "$T/pre.sh" 2>&1); then ok "shellcheck -s sh"; else bad "shellcheck -s sh" "$out"; fi
fi

runpre() { (cd "$1" && sh -c "$script") >"$T/pre.out" 2>&1; }

d="$T/srvA"
mkdir -p "$d/plugins/update"
echo eski >"$d/server.jar"
echo yeni >"$d/server.jar.new"
echo eskiA >"$d/plugins/A.jar"
echo yeniA >"$d/plugins/update/A.jar"
echo yeniB >"$d/plugins/update/B.jar"
echo not >"$d/plugins/update/oku.txt"
if runpre "$d"; then ok "bekleyen güncellemeler: çıkış 0"; else bad "çıkış kodu" "$(<"$T/pre.out")"; fi
eq "server.jar.new -> server.jar" "yeni" "$(<"$d/server.jar")"
eq "eski jar -> server.jar.old" "eski" "$(<"$d/server.jar.old")"
if [[ ! -e $d/server.jar.new ]]; then ok "server.jar.new kalmaz"; else bad "server.jar.new kaldı"; fi
eq "plugins/update/A.jar aynı adın üzerine yazar" "yeniA" "$(<"$d/plugins/A.jar")"
eq "plugins/update/B.jar taşınır" "yeniB" "$(<"$d/plugins/B.jar")"
eq "jar olmayan dosyaya dokunulmaz" "oku.txt" "$(find "$d/plugins/update" -type f -printf '%f\n' | paste -sd' ')"
eq "günlüğe bilgi yazılır" "3" "$(grep -c . "$T/pre.out")"

d="$T/srvB"
mkdir -p "$d"
echo yeni >"$d/server.jar.new"
if runpre "$d"; then ok "ilk kurulum (server.jar yok): çıkış 0"; else bad "ilk kurulum" "$(<"$T/pre.out")"; fi
eq "yalnız .new varsa server.jar olur" "yeni" "$(<"$d/server.jar")"
if [[ ! -e $d/server.jar.old ]]; then ok "server.jar.old oluşmaz"; else bad "gereksiz server.jar.old"; fi

d="$T/srvC"
mkdir -p "$d/plugins/update"
echo x >"$d/server.jar"
if runpre "$d"; then ok "bekleyen yok (boş update/): çıkış 0, sessiz"; else bad "boş durum" "$(<"$T/pre.out")"; fi
eq "bekleyen yokken hiçbir şey değişmez" "x|" "$(<"$d/server.jar")|$(find "$d" -name '*.old' -o -name '*.new')"
eq "bekleyen yokken çıktı yok" "" "$(<"$T/pre.out")"

d="$T/srvD"
mkdir -p "$d"
if runpre "$d"; then ok "plugins/ hiç yoksa çıkış 0"; else bad "plugins yok" "$(<"$T/pre.out")"; fi

# limbo (PicoLimbo): pico_limbo.new -> pico_limbo, eskisi .old, çalıştırılabilir (0750)
d="$T/srvE"
mkdir -p "$d"
echo eskiP >"$d/pico_limbo"
echo yeniP >"$d/pico_limbo.new"
chmod 0640 "$d/pico_limbo.new"
if runpre "$d"; then ok "limbo güncellemesi: çıkış 0"; else bad "limbo güncellemesi" "$(<"$T/pre.out")"; fi
eq "pico_limbo.new -> pico_limbo" "yeniP" "$(<"$d/pico_limbo")"
eq "eski ikili -> pico_limbo.old" "eskiP" "$(<"$d/pico_limbo.old")"
eq "yeni ikili 0750 (çalıştırılabilir)" "750" "$(stat -c %a "$d/pico_limbo")"
if [[ ! -e $d/pico_limbo.new ]]; then ok "pico_limbo.new kalmaz"; else bad "pico_limbo.new kaldı"; fi
eq "limbo: günlüğe bilgi yazılır" "pico_limbo yeni sürümle değiştirildi" "$(<"$T/pre.out")"
check_nojar="$(find "$d" -name 'server.jar*' | head -n1)"
eq "limbo: server.jar oluşmaz" "" "$check_nojar"

d="$T/srvF"
mkdir -p "$d"
echo yeniP >"$d/pico_limbo.new"
if runpre "$d"; then ok "limbo ilk kurulum (yalnız .new): çıkış 0"; else bad "limbo ilk kurulum" "$(<"$T/pre.out")"; fi
eq "yalnız .new varsa pico_limbo olur, .old oluşmaz" "yeniP|750|" \
    "$(<"$d/pico_limbo")|$(stat -c %a "$d/pico_limbo")|$(find "$d" -name '*.old')"

echo
echo "Sonuç: $PASS başarılı, $FAILN başarısız"
((FAILN == 0))
