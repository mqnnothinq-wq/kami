#!/usr/bin/env bash
# scripts/apply-config.sh testleri (SPEC §7).
# Her senaryo geçici bir "depo kopyası" kurar: scripts/ (gerçek betikler) +
# tests/fixtures/apply/config (fikstür). lib.sh config yolunu kendi konumundan bulduğu
# için betikler kopyalanır (sembolik bağ gerçek depoya çözülürdü).
# Gereken: YQ=<mikefarah yq yolu> (tests/run.sh ayarlar), python3.
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(dirname "$HERE")"
FIX="$HERE/fixtures/apply"
: "${YQ:?YQ=<mikefarah yq yolu> gerekli}"
export YQ

PASS=0 FAIL=0
TMPS=()
cleanup() { ((${#TMPS[@]} == 0)) || rm -rf "${TMPS[@]}"; }
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
check() { # <açıklama> <komut...>
    local d=$1
    shift
    if "$@"; then ok "$d"; else nok "$d"; fi
}
has() { grep -qF -- "$2" "$1"; }                    # <dosya> <metin>
hasnt() { ! grep -qF -- "$2" "$1"; }
line_is() { grep -qxF -- "$2" "$1"; }               # <dosya> <tam satır>
yq_is() { [[ $("$YQ" "$2" "$1") == "$3" ]]; }       # <dosya> <ifade> <beklenen>
mode_is() { [[ $(stat -c '%a' "$1") == "$2" ]]; }

# Yeni sandbox: $T, $REPO, $SRV (lobby hedefi), ortam değişkenleri.
setup() {
    T=$(mktemp -d "${TMPDIR:-/tmp}/kami-test.XXXXXX")
    TMPS+=("$T")
    REPO="$T/repo"
    mkdir -p "$REPO/scripts" "$T/root/servers" "$T/etc" "$T/systemd" "$T/run"
    cp "$ROOT/scripts/lib.sh" "$ROOT/scripts/rcon.py" "$ROOT/scripts/apply-config.sh" "$REPO/scripts/"
    cp -R "$FIX/config" "$REPO/config"
    printf "RCON_PASSWORD='test-rcon'\nDB_PASSWORD='test-db'\nVELOCITY_FORWARDING_SECRET='abc'\n" >"$T/etc/secrets.env"
    chmod 600 "$T/etc/secrets.env"
    export MC_ROOT="$T/root" MC_ETC="$T/etc" MC_RUN_DIR="$T/run" MC_USER
    MC_USER=$(id -un)
    export MC_NO_SYSTEMD=1 MC_SYSTEMD_DIR="$T/systemd"
    SRV="$T/root/servers/lobby"
}

seed_existing() { # sunucunun daha önce ürettiği dosyalar
    mkdir -p "$SRV"
    cp -R "$FIX/existing/lobby/." "$SRV/"
}

apply() { # çıktı: $OUT (stdout+stderr), dönüş: $RC
    RC=0
    OUT=$(bash "$REPO/scripts/apply-config.sh" "$@" 2>&1) || RC=$?
}

snapshot() { # dizin(ler)in içerik+izin özeti
    find "$@" -exec stat -c '%n %a %s %Y' {} + 2>/dev/null | LC_ALL=C sort
    find "$@" -type f -exec md5sum {} + 2>/dev/null | LC_ALL=C sort
}

echo "# properties anahtar birleştirme"
setup
seed_existing
apply lobby
check "apply lobby başarılı" test "$RC" -eq 0
if diff -u "$FIX/expected/lobby/server.properties" "$SRV/server.properties" >/dev/null; then
    ok "server.properties beklenen içerik (değiştir + sona ekle + yorumlar + noktalı anahtarlar)"
else
    nok "server.properties beklenen içerik" "$(diff -u "$FIX/expected/lobby/server.properties" "$SRV/server.properties" || true)"
fi
check "yorum satırı korundu" line_is "$SRV/server.properties" "# yönetici yorumu korunmalı"
check "noktalı anahtar değiştirildi (rcon.port)" line_is "$SRV/server.properties" "rcon.port=31066"
check "regex benzeri anahtar dokunulmadı (rconXport)" line_is "$SRV/server.properties" "rconXport=aynen-kalmali"
check "yeni noktalı anahtar sona eklendi" test "$(tail -n1 "$SRV/server.properties")" = "new.key.with.dots=evet"
check "yer tutucu + UTF-8 (§) işlendi" line_is "$SRV/server.properties" "motd=Kami Lobi §elobby"
check "yazılan dosya modu 0640" mode_is "$SRV/server.properties" 640
check "override'ın kendi yorumu hedefe taşınmadı" hasnt "$SRV/server.properties" "yönetilen anahtarlar"

echo "# yml: hedef yoksa kopyala, varsa birleştir"
check "bukkit.yml hedef yokken olduğu gibi kopyalandı" cmp -s "$REPO/config/servers/lobby/files/bukkit.yml" "$SRV/bukkit.yml"
PG="$SRV/config/paper-global.yml"
check "yml birleştirme: değer değişti" yq_is "$PG" '.chunk-system.worker-threads' 1
check "yml birleştirme: iç içe değer" yq_is "$PG" '.proxies.velocity.enabled' true
check "yml birleştirme: hedefteki diğer anahtar korundu" yq_is "$PG" '.misc.compression-level' default
check "yml birleştirme: _version korundu" yq_is "$PG" '._version' 31
check "yml birleştirme: başlık yorumu korundu" has "$PG" "# This is the global configuration file for Paper."
check "yml birleştirme: iç yorum korundu" has "$PG" "# G/Ç iş parçacıkları"
check "yml birleştirme: override yorumu taşınmadı" hasnt "$PG" "override'ı (test)"
PW="$SRV/config/paper-world-defaults.yml"
check "yml dizi bütünüyle değiştirildi" yq_is "$PW" '.anticheat.anti-xray.hidden-blocks | join(",")' "diamond_ore,deepslate_diamond_ore"
check "yml dizinin kardeş anahtarı korundu" yq_is "$PW" '.anticheat.anti-xray.lava-obscures' false
check "yml yorum korundu (dizi dosyası)" has "$PW" "# Paper dünya varsayılanları"

echo "# bilinmeyen anahtar uyarısı"
check "bilinmeyen yaprak yol uyarıldı" grep -qF "'eski-ayar.alt-anahtar' hedefte yok" <<<"$OUT"
check "bilinen yollar uyarılmadı" bash -c '! grep -F "hedefte yok" <<<"$1" | grep -vqF "eski-ayar.alt-anahtar"' _ "$OUT"
check "bilinmeyen anahtar yine de yazıldı" yq_is "$PG" '.eski-ayar.alt-anahtar' true

echo "# plugins/ kuralları"
check "plugins/*.yml hedefte varken birleştirildi" yq_is "$SRV/plugins/LuckPerms/config.yml" '.data.password' test-db
check "plugins/*.yml yer tutucu (SERVER_NAME)" yq_is "$SRV/plugins/LuckPerms/config.yml" '.server' lobby
check "plugins/*.yml hedefteki fazladan anahtar korundu" yq_is "$SRV/plugins/LuckPerms/config.yml" '.data.pool-settings.maximum-pool-size' 10

echo "# jvm.env ve drop-in"
J="$SRV/jvm.env"
check "jvm.env JAVA_MEM" line_is "$J" 'JAVA_MEM="-Xms1536M -Xmx1536M"'
check "jvm.env JAVA_OPTS (bayraklar + GC iş parçacıkları)" line_is "$J" 'JAVA_OPTS="-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -Duser.language=en -Duser.country=US -XX:ParallelGCThreads=3 -XX:ConcGCThreads=1"'
check "jvm.env SERVER_ARGS (paper)" line_is "$J" 'SERVER_ARGS="--nogui"'
check "jvm.env modu 0640" mode_is "$J" 640
D="$T/systemd/mc@lobby.service.d/20-resources.conf"
check "20-resources.conf [Service]" line_is "$D" "[Service]"
check "20-resources.conf CPUWeight" line_is "$D" "CPUWeight=100"
check "20-resources.conf OOMScoreAdjust" line_is "$D" "OOMScoreAdjust=200"
check "drop-in modu 0644" mode_is "$D" 644
check "yalnız istenen sunucu uygulandı" test ! -e "$T/root/servers/survival"

echo "# idempotent: ikinci çalıştırma hiçbir şeyi değiştirmez"
before=$(snapshot "$T/root" "$T/systemd")
apply lobby
after=$(snapshot "$T/root" "$T/systemd")
check "ikinci apply başarılı" test "$RC" -eq 0
check "ikinci apply içerik/izin değiştirmedi" test "$before" = "$after"
check "ikinci apply 0 dosya yazdı" grep -qF "0 dosya yazıldı" <<<"$OUT"

echo "# all: plugins/*.yml hedef yokken atlanır, plugins/*.properties kopyalanır"
setup
apply all
V="$T/root/servers/velocity"
check "apply all başarılı" test "$RC" -eq 0
check "plugins/geyser/config.yml atlandı (dosya yok)" test ! -e "$V/plugins/geyser/config.yml"
check "atlama uyarısı gösterildi" grep -qF "plugins/geyser/config.yml atlandı" <<<"$OUT"
check "plugins/LuckPerms (lobby) hedef yokken atlandı" test ! -e "$SRV/plugins/LuckPerms/config.yml"
check "plugins/sonar/language.properties hedef yokken kopyalandı" line_is "$V/plugins/sonar/language.properties" "language=tr"
check "velocity.toml tam kopya + yer tutucu" line_is "$V/velocity.toml" 'bind = "0.0.0.0:25565"'
check "server.properties hedef yokken kopyalandı (survival)" line_is "$T/root/servers/survival/server.properties" "rcon.port=31067"
check "velocity jvm.env SERVER_ARGS boş" line_is "$V/jvm.env" 'SERVER_ARGS=""'
check "velocity jvm.env GC=1 → ConcGCThreads=1 + EXTRA sonda" line_is "$V/jvm.env" 'JAVA_OPTS="-XX:+UseG1GC -XX:G1HeapRegionSize=4M -XX:ParallelGCThreads=1 -XX:ConcGCThreads=1 -XX:+ExitOnOutOfMemoryError"'
check "survival jvm.env GC_THREADS boş → GC bayrağı yok" line_is "$T/root/servers/survival/jvm.env" 'JAVA_OPTS="-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -Duser.language=en -Duser.country=US -XX:+UseCompactObjectHeaders"'
check "survival jvm.env JAVA_MEM" line_is "$T/root/servers/survival/jvm.env" 'JAVA_MEM="-Xms7G -Xmx7G"'
check "velocity 10-order.conf tüm backend'ler" line_is "$T/systemd/mc@velocity.service.d/10-order.conf" "After=mc@lobby.service mc@survival.service"
check "velocity 20-resources.conf negatif OOM" line_is "$T/systemd/mc@velocity.service.d/20-resources.conf" "OOMScoreAdjust=-200"
check "yeni dizinler 0750" mode_is "$V/plugins/sonar" 750

echo "# dry-run hiçbir şey yazmaz"
setup
seed_existing
before=$(snapshot "$T/root" "$T/systemd")
apply --dry-run all
after=$(snapshot "$T/root" "$T/systemd")
check "dry-run başarılı" test "$RC" -eq 0
check "dry-run MC_ROOT ve systemd dizinini değiştirmedi" test "$before" = "$after"
check "dry-run yeni dosyayı listeledi" grep -qF "[yeni]" <<<"$OUT"
check "dry-run değişecek dosyayı ve farkı gösterdi" grep -qF "+rcon.port=31066" <<<"$OUT"
check "dry-run kipini bildirdi" grep -qF "hiçbir dosya yazılmadı" <<<"$OUT"

echo "# tanımsız yer tutucu: hiçbir dosya yazılmaz"
setup
seed_existing
printf 'deger = "@@TANIMSIZ_DEGER@@"\n' >"$REPO/config/servers/survival/files/zz-bozuk.toml"
before=$(snapshot "$T/root" "$T/systemd")
apply all
after=$(snapshot "$T/root" "$T/systemd")
check "yer tutucu hatasında çıkış kodu ≠ 0" test "$RC" -ne 0
check "hata mesajı eksik değişkeni adlandırdı" grep -qF "TANIMSIZ_DEGER" <<<"$OUT"
check "hata mesajı 'HİÇBİR dosya yazılmadı' diyor" grep -qF "HİÇBİR dosya yazılmadı" <<<"$OUT"
check "diğer sunucuların dosyaları da yazılmadı (kısmi yazma yok)" test "$before" = "$after"
check "lobby server.properties dokunulmadı" cmp -s "$FIX/existing/lobby/server.properties" "$SRV/server.properties"

echo "# yq doğrulaması"
setup
seed_existing
printf '#!/bin/sh\necho "yq 3.4.3"\n' >"$T/sahte-yq"
chmod +x "$T/sahte-yq"
before=$(snapshot "$T/root")
YQ="$T/sahte-yq" apply lobby
check "mikefarah olmayan yq reddedildi" test "$RC" -ne 0
check "yq hata mesajı" grep -qF "mikefarah yq değil" <<<"$OUT"
check "yq hatasında dosya yazılmadı" test "$before" = "$(snapshot "$T/root")"

echo "# geçersiz girdiler"
setup
apply yok-boyle-sunucu
check "tanımsız sunucu reddedildi" test "$RC" -ne 0
apply --bilinmeyen
check "bilinmeyen seçenek reddedildi" test "$RC" -ne 0
sed -i 's/^HEAP=.*/HEAP="yedi"/' "$REPO/config/servers/lobby/server.env"
apply lobby
check "geçersiz HEAP reddedildi" test "$RC" -ne 0
check "geçersiz HEAP'te hiçbir şey yazılmadı" test -z "$(ls -A "$T/root/servers")"
apply --help
check "--help çalışır" test "$RC" -eq 0
check "--help Türkçe kullanım" grep -qF "Kullanım: mc apply" <<<"$OUT"

printf '\ntest_apply_config: %d geçti, %d başarısız\n' "$PASS" "$FAIL"
((FAIL == 0))
