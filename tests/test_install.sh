#!/usr/bin/env bash
# scripts/install.sh testleri — yalnız --dry-run (sistemde hiçbir şey değiştirilmez) + betikler arası
# tutarlılık denetimleri:
#  1) paket listesi (git: build-librelogin; python3: backup.sh sqlite3 kopyası), artifacts/ dizini
#  2) etkinleştirilen mc@ birimleri config/servers/*/server.env'den türetilir (limbo ve yeni sunucular dahil)
#  3) "Sonraki adımlar" doğru sırada: build-librelogin → download all → init all → start all → doctor
#  4) betiklerin önerdiği her "sudo mc <komut>" mc'de gerçekten var
# Çalıştırma: bash tests/test_install.sh
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(dirname "$HERE")"

PASS=0 FAIL=0
T=$(mktemp -d "${TMPDIR:-/tmp}/kami-install-test.XXXXXX")
trap 'rm -rf -- "$T"' EXIT

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
eq() {
    if [[ $1 == "$2" ]]; then return 0; fi
    printf '        beklenen: %q\n        gelen:    %q\n' "$2" "$1"
    return 1
}
out_has() { grep -qF -- "$1" <<<"$OUT"; }

# mc'nin dağıtıcısındaki alt komutlar (main() içindeki case etiketleri)
MC_CMDS=$(awk '/^main\(\)/ { m = 1 } m && /^        [a-z|-][a-z| -]*\) / { sub(/\).*/, ""); gsub(/ /, ""); n = split($0, a, "|"); for (i = 1; i <= n; i++) print a[i] }' \
    "$ROOT/scripts/mc" | sort -u)

echo "# betiklerin önerdiği 'sudo mc <komut>' mc'de var"
check "mc dağıtıcısı okunabildi" test "$(wc -l <<<"$MC_CMDS")" -ge 15
missing=""
while IFS= read -r c; do
    grep -qxF -- "$c" <<<"$MC_CMDS" || missing+=" $c"
done < <(grep -ohE 'sudo mc [a-z][a-z-]*' "$ROOT"/scripts/*.sh "$ROOT/scripts/mc" | awk '{ print $3 }' | sort -u)
check "tüm 'sudo mc …' önerileri geçerli alt komut" eq "$missing" ""

if [[ $(uname -m) != x86_64 || ! -f /usr/share/zoneinfo/Europe/Istanbul ]]; then
    echo "  (install.sh --dry-run atlandı: x86_64 ve tzdata gerekir)"
    printf '\ntest_install: %d geçti, %d başarısız\n' "$PASS" "$FAIL"
    ((FAIL == 0))
    exit
fi

# Depo kopyası: install.sh CONFIG_DIR'i kendi konumundan bulur; yeni sunucu eklemek için kopya gerekir.
REPO="$T/repo"
mkdir -p "$REPO"
cp -R "$ROOT/scripts" "$ROOT/config" "$ROOT/systemd" "$ROOT/host" "$REPO/"
chmod 0644 "$REPO/scripts/build-librelogin.sh"
printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n' >"$T/os-release"
mkdir -p "$T/tmp"
export OS_RELEASE_FILE="$T/os-release" MC_NO_SYSTEMD=1 MC_ROOT="$T/root" MC_ETC="$T/etc" TMPDIR="$T/tmp"

inst() { # çıktı: $OUT, dönüş: $RC
    RC=0
    OUT=$(bash "$REPO/scripts/install.sh" --dry-run "$@" 2>&1) || RC=$?
}

echo "# install.sh --dry-run"
inst
check "kuru kurulum çıkış 0" eq "$RC" 0
check "hiçbir şey yazılmadı (MC_ROOT, MC_ETC yok)" test ! -e "$T/root" -a ! -e "$T/etc"
APT_LINE=$(grep -E '^\[kuru\] .*apt-get install .*mariadb-server' <<<"$OUT" | head -n1)
for p in git python3 jq restic curl mariadb-server ufw fail2ban; do
    check "paket listesinde $p" grep -qE "(^| )$p( |$)" <<<"$APT_LINE"
done
check "artifacts/ root 0755 oluşturulur (build-librelogin çıktısı)" out_has "[kuru] install -d -m 0755 -o root -g root $T/root/artifacts"
check "servers/ minecraft 0750" out_has "[kuru] install -d -m 0750 -o minecraft -g minecraft $T/root/servers"
check "betik izinleri düzeltilir (build-librelogin.sh dahil)" out_has "chmod 0755 $REPO/scripts/build-librelogin.sh"

expected=$(find "$REPO/config/servers" -mindepth 2 -maxdepth 2 -name server.env -printf '%h\n' | xargs -n1 basename | sort)
enabled=$(grep -oE 'systemctl enable mc@[a-z0-9-]+\.service' <<<"$OUT" | sed 's/.*mc@//; s/\.service//' | sort)
check "etkinleştirilen mc@ birimleri = config/servers/* (limbo dahil)" eq "$enabled" "$expected"
check "mc@limbo etkinleştirilir" grep -qxF limbo <<<"$enabled"
check "zamanlayıcılar etkinleştirilir" out_has "systemctl enable --now mc-backup.timer mc-prune.timer mc-daily-restart.timer"

line_of() { grep -nF -- "$1" <<<"$OUT" | head -n1 | cut -d: -f1; }
L_CFG=$(line_of "(isteğe bağlı) Ayarları gözden geçirin")
L_BUILD=$(line_of "sudo mc build-librelogin")
L_DL=$(line_of "sudo mc download all")
L_INIT=$(line_of "sudo mc init all --accept-eula")
L_START=$(line_of "sudo mc start all")
L_DOC=$(line_of "sudo mc doctor")
check "sonraki adımların hepsi yazdırıldı" test -n "$L_CFG" -a -n "$L_BUILD" -a -n "$L_DL" -a -n "$L_INIT" -a -n "$L_START" -a -n "$L_DOC"
check "sıra: config → build-librelogin → download all → init all → start all → doctor" \
    test "${L_CFG:-0}" -lt "${L_BUILD:-0}" -a "${L_BUILD:-0}" -lt "${L_DL:-0}" -a "${L_DL:-0}" -lt "${L_INIT:-0}" \
    -a "${L_INIT:-0}" -lt "${L_START:-0}" -a "${L_START:-0}" -lt "${L_DOC:-0}"
check "temurin kurulumunda openjdk JDK notu yok" test -z "$(grep -F 'openjdk-25-jdk-headless' <<<"$OUT")"

inst --java=openjdk
check "--java=openjdk: build-librelogin için JDK 25 notu" out_has "sudo apt-get install openjdk-25-jdk-headless"

echo "# yeni sunucu: birim listesi config'den türetilir"
cp -R "$REPO/config/servers/survival" "$REPO/config/servers/skyblock"
inst
check "yeni sunucu (skyblock) etkinleştirilir" out_has "systemctl enable mc@skyblock.service"
rm -rf "$REPO/config/servers"/*
inst
check "sunucu yoksa: uyarı, sabit liste yok" out_has "hiçbir mc@ birimi etkinleştirilmedi"
check "sunucu yoksa: hiçbir mc@ birimi etkinleştirilmez" test -z "$(grep -E 'systemctl enable mc@' <<<"$OUT")"

printf '\ntest_install: %d geçti, %d başarısız\n' "$PASS" "$FAIL"
((FAIL == 0))
