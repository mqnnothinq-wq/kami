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
check "bilinen yollar uyarılmadı (tek uyarı)" test "$(grep -c "hedefte yok" <<<"$OUT")" -eq 1
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
check "velocity 10-order.conf tüm backend'ler (limbo dahil)" line_is "$T/systemd/mc@velocity.service.d/10-order.conf" "After=mc@limbo.service mc@lobby.service mc@survival.service"
check "velocity 20-resources.conf negatif OOM" line_is "$T/systemd/mc@velocity.service.d/20-resources.conf" "OOMScoreAdjust=-200"
check "yeni dizinler 0750" mode_is "$V/plugins/sonar" 750

echo "# limbo (PicoLimbo, TYPE=limbo — SPEC §17)"
L="$T/root/servers/limbo"
LD="$T/systemd/mc@limbo.service.d"
check "limbo jvm.env üretildi: JAVA_MEM boş" line_is "$L/jvm.env" 'JAVA_MEM=""'
check "limbo jvm.env: JAVA_OPTS boş" line_is "$L/jvm.env" 'JAVA_OPTS=""'
check "limbo jvm.env: SERVER_ARGS boş" line_is "$L/jvm.env" 'SERVER_ARGS=""'
check "limbo 30-exec.conf [Service]" line_is "$LD/30-exec.conf" "[Service]"
check "limbo 30-exec.conf ExecStart sıfırlanır" line_is "$LD/30-exec.conf" "ExecStart="
check "limbo 30-exec.conf pico_limbo ExecStart" line_is "$LD/30-exec.conf" "ExecStart=/opt/minecraft/servers/%i/pico_limbo --config server.toml"
check "limbo 30-exec.conf sırası: sıfırlama önce" test "$(grep '^ExecStart=' "$LD/30-exec.conf" | head -n1)" = "ExecStart="
check "limbo 20-resources.conf CPUWeight=50" line_is "$LD/20-resources.conf" "CPUWeight=50"
check "limbo 20-resources.conf OOMScoreAdjust=300" line_is "$LD/20-resources.conf" "OOMScoreAdjust=300"
check "limbo server.toml @@PORT@@ işlendi" line_is "$L/server.toml" 'bind = "127.0.0.1:30065"'
# shellcheck disable=SC2016  # ${…} bilerek genişletilmez: dosyada birebir durmalı
check "limbo server.toml PicoLimbo'nun kendi \${…} yer tutucusu korundu" line_is "$L/server.toml" 'secret = "${VELOCITY_FORWARDING_SECRET}"'
check "paper'a 30-exec.conf yazılmadı" test ! -e "$T/systemd/mc@lobby.service.d/30-exec.conf"
check "velocity'ye 30-exec.conf yazılmadı" test ! -e "$T/systemd/mc@velocity.service.d/30-exec.conf"
apply limbo
check "limbo ikinci apply değişiklik yok" grep -qF "0 dosya yazıldı" <<<"$OUT"

echo "# eskiden üretilmiş drop-in (tür değişti) silinir; elle yazılana dokunulmaz"
printf '# mc apply tarafından üretildi (TYPE=limbo) — elle düzenlemeyin.\n[Service]\nExecStart=\n' \
    >"$T/systemd/mc@lobby.service.d/30-exec.conf"
printf '# yöneticinin kendi dosyası\n[Unit]\nAfter=x.service\n' >"$T/systemd/mc@survival.service.d/10-order.conf"
apply --dry-run lobby survival
check "dry-run: eski drop-in 'silinecek' listelendi" grep -qF "[silinecek]" <<<"$OUT"
check "dry-run: eski drop-in yerinde" test -e "$T/systemd/mc@lobby.service.d/30-exec.conf"
apply lobby survival
check "tür değişince eski 30-exec.conf silindi" test ! -e "$T/systemd/mc@lobby.service.d/30-exec.conf"
check "silme bildirildi" grep -qF "[silindi]" <<<"$OUT"
check "elle yazılmış drop-in'e dokunulmadı" line_is "$T/systemd/mc@survival.service.d/10-order.conf" "After=x.service"

echo "# dry-run hiçbir şey yazmaz"
setup
seed_existing
printf 'api.token=gizli-deger-123\n' >>"$REPO/config/servers/lobby/files/server.properties"
before=$(snapshot "$T/root" "$T/systemd")
apply --dry-run all
after=$(snapshot "$T/root" "$T/systemd")
check "dry-run başarılı" test "$RC" -eq 0
check "dry-run MC_ROOT ve systemd dizinini değiştirmedi" test "$before" = "$after"
check "dry-run yeni dosyayı listeledi" grep -qF "[yeni]" <<<"$OUT"
check "dry-run değişecek dosyayı ve farkı gösterdi" grep -qF "+rcon.port=31066" <<<"$OUT"
check "dry-run kipini bildirdi" grep -qF "hiçbir dosya yazılmadı" <<<"$OUT"
check "dry-run farkında RCON şifresi maskelendi" grep -qF "+rcon.password=***" <<<"$OUT"
check "dry-run farkında DB şifresi maskelendi (anahtar adına göre)" grep -qE '^ +\+ +password: \*\*\*$' <<<"$OUT"
check "dry-run: secrets.env dışı token anahtarı da maskelendi" grep -qF "+api.token=***" <<<"$OUT"
check "dry-run çıktısında gizli değer yok" test "$(grep -cE 'test-rcon|test-db|gizli-deger-123' <<<"$OUT")" -eq 0

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

echo "# yml: sunucu dosyayı kendi biçimiyle yeniden yazınca apply değişiklik saymaz"
setup
seed_existing
apply lobby
# Paper/SnakeYAML biçimini taklit et: dizi girintisi farklı, dize tırnaklı (veri aynı).
sed -i 's/^      - /    - /' "$SRV/config/paper-world-defaults.yml"
sed -i "s/^  password: test-db\$/  password: 'test-db'/" "$SRV/plugins/LuckPerms/config.yml"
check "(ön koşul) biçim gerçekten değişti" grep -qxF "    - diamond_ore" "$SRV/config/paper-world-defaults.yml"
check "(ön koşul) tırnak gerçekten değişti" grep -qxF "  password: 'test-db'" "$SRV/plugins/LuckPerms/config.yml"
before=$(snapshot "$T/root")
apply lobby
check "yeniden biçimlenmiş yml: 0 dosya yazıldı" grep -qF "0 dosya yazıldı" <<<"$OUT"
check "yeniden biçimlenmiş yml: sunucunun biçimi korundu" test "$before" = "$(snapshot "$T/root")"
sed -i 's/engine-mode: 2/engine-mode: 1/' "$SRV/config/paper-world-defaults.yml"
apply lobby
check "gerçek veri farkı yine uygulanır" yq_is "$SRV/config/paper-world-defaults.yml" '.anticheat.anti-xray.engine-mode' 2
check "gerçek veri farkı 1 dosya yazdı" grep -qF "1 dosya yazıldı" <<<"$OUT"

echo "# izin/sahiplik düzeltme (içerik aynı)"
chmod 0644 "$SRV/jvm.env"
apply lobby
check "yanlış mod düzeltildi (0640)" mode_is "$SRV/jvm.env" 640
check "izin düzeltmesi bildirildi" grep -qF "[izin düzeltildi]" <<<"$OUT"

echo "# güvenlik: sunucu dizinindeki sembolik bağlar izlenmez"
setup
seed_existing
mkdir -p "$T/kurban/LuckPerms"
printf 'dokunulmamali: evet\n' >"$T/kurban/LuckPerms/config.yml"
printf 'kurban=1\n' >"$T/kurban/dosya"
rm -rf "$SRV/plugins"
ln -s "$T/kurban" "$SRV/plugins"
before=$(snapshot "$T/root" "$T/systemd" "$T/kurban")
apply lobby
check "sembolik bağlı üst dizin reddedildi" test "$RC" -ne 0
check "hata mesajı sembolik bağı adlandırdı" grep -qF "$SRV/plugins sembolik bağ" <<<"$OUT"
check "sembolik bağda HİÇBİR dosya yazılmadı (kurban dahil)" test "$before" = "$(snapshot "$T/root" "$T/systemd" "$T/kurban")"
rm "$SRV/plugins"
mv "$SRV/server.properties" "$T/sp"
ln -s "$T/kurban/dosya" "$SRV/server.properties"
apply --dry-run lobby
check "sembolik bağ hedef dosya (dry-run da) reddedildi" grep -qF "$SRV/server.properties sembolik bağ" <<<"$OUT"
check "kurban dosyası okunup basılmadı" test "$(grep -c 'kurban=1' <<<"$OUT")" -eq 0
apply lobby
check "sembolik bağ hedef dosya reddedildi" test "$RC" -ne 0
check "kurban dosyası değişmedi" test "$(cat "$T/kurban/dosya")" = "kurban=1"
rm "$SRV/server.properties"
mv "$SRV" "$T/lobby-gercek"
ln -s "$T/lobby-gercek" "$SRV"
apply lobby
check "sunucu dizininin kendisi sembolik bağsa reddedildi" grep -qF "$SRV sembolik bağ" <<<"$OUT"

if [[ ${EUID:-$(id -u)} -eq 0 ]] && id daemon >/dev/null 2>&1; then
    echo "# root iken yazma sahibinin (MC_USER) kimliğiyle yapılır"
    setup
    seed_existing
    chmod 0755 "$T" "$T/root"
    chown -R daemon:daemon "$T/root/servers"
    MC_USER=daemon apply lobby survival
    check "MC_USER=daemon apply başarılı" test "$RC" -eq 0
    check "yazılan dosya daemon:daemon 0640" test "$(stat -c '%U:%G %a' "$SRV/jvm.env")" = "daemon:daemon 640"
    check "birleştirilen dosya daemon:daemon" test "$(stat -c '%U:%G' "$SRV/server.properties")" = "daemon:daemon"
    check "oluşturulan sunucu dizini daemon:daemon 0750" test "$(stat -c '%U:%G %a' "$T/root/servers/survival")" = "daemon:daemon 750"
    check "oluşturulan alt dizin daemon:daemon 0750" test "$(stat -c '%U:%G %a' "$T/root/servers/survival/config")" = "daemon:daemon 750"
    check "drop-in root'a ait kalır" test "$(stat -c '%U' "$T/systemd/mc@lobby.service.d/20-resources.conf")" = "root"
    chown root:root "$SRV/config"
    chmod 0755 "$SRV/config"
    before=$(snapshot "$T/root")
    MC_USER=daemon apply lobby
    check "daemon'ın yazamadığı dizin: apply reddetti (root yetkisiyle yazmadı)" test "$RC" -ne 0
    check "yazılamayan dizin hata mesajı" grep -qF "$SRV/config daemon tarafından yazılamıyor" <<<"$OUT"
    check "yazılamayan dizinde hiçbir dosya yazılmadı" test "$before" = "$(snapshot "$T/root")"
    chown daemon:daemon "$SRV/config"
    chown root:root "$SRV/config/paper-global.yml"
    chmod 0600 "$SRV/config/paper-global.yml"
    MC_USER=daemon apply --dry-run lobby
    check "daemon'ın okuyamadığı dosya root ile okunmadı" grep -qF "paper-global.yml daemon tarafından okunamıyor" <<<"$OUT"
else
    echo "# (atlandı: root değil ya da 'daemon' kullanıcısı yok — kimlik düşürme testleri)"
fi

printf '\ntest_apply_config: %d geçti, %d başarısız\n' "$PASS" "$FAIL"
((FAIL == 0))
