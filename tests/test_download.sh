#!/usr/bin/env bash
# scripts/download.sh testleri — ağ KULLANMAZ.
#  1) jq seçicileri örnek API yanıtlarıyla (tests/fixtures/download/api/)
#  2) plugins.list ayrıştırma (yorumlar, backends, all, url için zorunlu sha256)
#  3) Uçtan uca: http_get/http_fetch taklit edilir (urls.tsv: URL -> yerel dosya), geçici MC_ROOT'a kurulur
# Çalıştırma: bash tests/test_download.sh
set -Eeuo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
FIX="$REPO/tests/fixtures/download"
API="$FIX/api"
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT

export MC_ROOT="$T/root" MC_ETC="$T/etc" MC_RUN_DIR="$T/run" MC_NO_SYSTEMD=1
MC_USER="$(id -un)"
export MC_USER

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/download.sh
. "$REPO/scripts/download.sh"
set +e # testler hatayı kendisi sayar

PASS=0 FAILN=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAILN=$((FAILN + 1)); printf '  HATA %s\n' "$1"; [[ -n ${2:-} ]] && printf '       %s\n' "$2"; }
eq() { # <ad> <beklenen> <gerçek>
    if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "beklenen: [$2] gerçek: [$3]"; fi
}
has() { # <ad> <alt-dizge> <metin>
    if [[ $3 == *"$2"* ]]; then ok "$1"; else bad "$1" "[$2] bulunamadı: [$3]"; fi
}
fails() { # <ad> <komut...> — komut başarısız olmalı
    local n=$1
    shift
    if "$@" >/dev/null 2>&1; then bad "$n (başarısız olmalıydı)"; else ok "$n"; fi
}
row() { tr '\037' '|'; }

echo "== 1. jq seçicileri"
out=$(jq_fill_build STABLE <"$API/paper-26.2-builds.json" | row)
eq "paper: ALPHA/BETA atlanır, ilk STABLE (16) seçilir" \
    "16|paper-26.2-16.jar|https://fill-data.papermc.io/v1/objects/0d75641f69139cbe4f86941a88b47704189440bebe91218c56571f034fc647f3/paper-26.2-16.jar|0d75641f69139cbe4f86941a88b47704189440bebe91218c56571f034fc647f3" "$out"
out=$(jq_fill_build STABLE <"$API/paper-real-builds.json" | row)
has "paper (gerçek Fill v3 nesneleri): ALPHA 49 atlanır, STABLE 60" "60|paper-1.21.8-60.jar|" "$out"
has "paper (gerçek): sha256 alınır" "|8de7c52c3b02403503d16fac58003f1efef7dd7a0256786843927fa92ee57f1e" "$out"
fails "paper: STABLE yoksa hata" jq_fill_build STABLE <"$API/paper-no-stable.json"
err=$(jq_fill_build STABLE <"$API/paper-no-server-default.json" 2>&1 >/dev/null)
has "paper: server:default yoksa anlaşılır hata" 'server:default" indirmesi yok (mevcut: server:mojmap)' "$err"
fails "paper: hata yanıtı (dizi değil) reddedilir" jq_fill_build STABLE <"$API/paper-error.json"

eq "velocity: SNAPSHOT olmayan en yeni sürüm" "4.2.0" "$(jq_fill_latest_version <"$API/velocity-project.json")"
fails "velocity: yalnız SNAPSHOT varsa hata" jq_fill_latest_version <"$API/velocity-project-snapshots-only.json"
out=$(jq_fill_build "" <"$API/velocity-4.2.0-builds.json" | row)
has "velocity: builds listesinin ilki (520)" "520|velocity-4.2.0-520.jar|" "$out"

out=$(jq_geyser_pick velocity <"$API/geyser-latest.json" | row)
eq "geysermc: sürüm, build, ad, sha256 (downloads.velocity.sha256)" \
    "2.11.2|1003|Geyser-Velocity.jar|$(sha256sum "$FIX/payload/geyser-velocity.bin" | cut -d' ' -f1)" "$out"
fails "geysermc: olmayan platform hata" jq_geyser_pick bungeecord <"$API/geyser-latest.json"

eq "luckperms: .downloads.velocity" "5.5.17|https://download.luckperms.net/1600/velocity/LuckPerms-Velocity-5.5.17.jar" \
    "$(jq_luckperms_pick velocity <"$API/luckperms-all.json" | row)"
eq "luckperms: .downloads.bukkit" "5.5.17|https://download.luckperms.net/1600/bukkit/loader/LuckPerms-Bukkit-5.5.17.jar" \
    "$(jq_luckperms_pick bukkit <"$API/luckperms-all.json" | row)"
fails "luckperms: olmayan platform hata" jq_luckperms_pick sponge <"$API/luckperms-all.json"

out=$(jq_modrinth_pick <"$API/modrinth-viaversion-real.json" | row)
eq "modrinth (gerçek ViaVersion yanıtı): beta'lar atlanır, ilk release + birincil dosya + sha512" \
    "5.7.1|ViaVersion-5.7.1.jar|https://cdn.modrinth.com/data/P1OZGk5p/versions/UU6hYsGX/ViaVersion-5.7.1.jar|4571c710b59253ab05dd30beb9949ea7d7d058fc30185a030b45e141a74b83dafd264fdba30d597d24809f83d9bf3fc5c054c4c6c9da834db1e8e2accbec8273" "$out"
out=$(jq_modrinth_pick <"$API/modrinth-chunky-paper.json" | row)
has "modrinth: primary==true olan dosya (ikinci sırada) seçilir" "|Chunky-Bukkit-1.4.40.jar|https://cdn.modrinth.com/data/test/versions/x/Chunky-Bukkit-1.4.40.jar|" "$out"
out=$(jq_modrinth_pick <"$API/modrinth-only-beta.json" | row)
has "modrinth: release yoksa ilk sürüm" "4.3.13-pre.3|multiverse-core-4.3.13-pre.3.jar|" "$out"
fails "modrinth: boş yanıt hata" jq_modrinth_pick <"$API/modrinth-empty.json"
eq "modrinth: paper sorgusu (URL kodlu)" 'loaders=%5B%22paper%22%5D&game_versions=%5B%2226.2%22%5D' "$(modrinth_query paper 26.2)"
eq "modrinth: velocity sorgusu (sürüm filtresi yok)" 'loaders=%5B%22velocity%22%5D' "$(modrinth_query velocity "")"

eq "hangar: latestrelease düz metin" "5.5.1" "$(hangar_version_name <"$API/hangar-viabackwards-latestrelease.txt")"
eq "hangar: tırnaklı latestrelease" "5.5.1" "$(printf '"5.5.1"\n' | hangar_version_name)"
out=$(jq_hangar_pick PAPER <"$API/hangar-viabackwards-5.5.1.json" | row)
eq "hangar: downloads.PAPER.downloadUrl + fileInfo.sha256Hash" \
    "ViaBackwards-5.5.1.jar|https://hangarcdn.papermc.io/plugins/ViaVersion/ViaBackwards/versions/5.5.1/PAPER/ViaBackwards-5.5.1.jar|$(sha256sum "$FIX/payload/viabackwards.bin" | cut -d' ' -f1)" "$out"
eq "hangar: downloadUrl yoksa externalUrl (hash boş)" "|https://example.org/Plugin-2.0.0.jar|" \
    "$(jq_hangar_pick VELOCITY <"$API/hangar-external.json" | row)"
fails "hangar: platform yoksa hata" jq_hangar_pick VELOCITY <"$API/hangar-viabackwards-5.5.1.json"

out=$(jq_github_pick Sonar-Velocity.jar <"$API/github-sonar-latest.json" | row)
eq "github: ada göre dosya + digest sha256" \
    "2.1.52|Sonar-Velocity.jar|https://github.com/jonesdevelopment/sonar/releases/download/2.1.52/Sonar-Velocity.jar|$(sha256sum "$FIX/payload/sonar-velocity.bin" | cut -d' ' -f1)" "$out"
eq "github: digest yoksa hash boş" "v1.3.0|app-1.3.0.jar|https://github.com/example/app/releases/download/v1.3.0/app-1.3.0.jar|" \
    "$(jq_github_pick app-1.3.0.jar <"$API/github-nodigest.json" | row)"
has "github: '*' kalıbı" "|Sonar-Velocity.jar|" "$(jq_github_pick 'Sonar-V*.jar' <"$API/github-sonar-latest.json" | row)"
fails "github: '.' kalıpta joker değildir" jq_github_pick 'Sonar-Velocity-jar' <"$API/github-sonar-latest.json"
fails "github: dosya yoksa hata" jq_github_pick yok.jar <"$API/github-nodigest.json"

echo "== 2. plugins.list ayrıştırma"
load_plugins_list "$FIX/config/plugins.list" 2>"$T/err"
eq "geçerli liste: hatasız" "0" "$PL_ERRORS"
eq "geçerli liste: 10 girdi (yorum/boş satırlar atlanır)" "10" "${#PL_NAME[@]}"
names() { plugins_for "$1" "$2" | cut -d $'\x1f' -f1 | paste -sd' '; }
eq "velocity eklentileri" "Geyser Floodgate LuckPerms Sonar LibreLogin" "$(names velocity velocity)"
eq "lobby eklentileri ('backends' dahil)" "LuckPerms ViaVersion ViaBackwards" "$(names lobby paper)"
eq "survival eklentileri" "LuckPerms ViaVersion Chunky ViaBackwards Example" "$(names survival paper)"
eq "backends, velocity'ye düşmez; yeni paper sunucusuna düşer" "ViaVersion ViaBackwards" "$(names yeni paper)"
eq "satır sonu yorumu ve sekmeler" "Floodgate|geysermc|floodgate/velocity||4" "$(plugins_for velocity velocity | sed -n 2p | row)"
eq "url + sha256 sütunu" "Example|url|https://downloads.example.org/Example-1.0.jar|4c55374f54e763fdff0ac5d4e7e4931defda5d1b06f1930f3e41c53680f280c7|11" \
    "$(plugins_for survival paper | grep '^Example' | row)"

load_plugins_list "$FIX/plugins-invalid.list" 2>"$T/err"
rc=$?
eq "hatalı liste: dönüş kodu 1" "1" "$rc"
eq "hatalı liste: 11 satır reddedilir" "11" "$PL_ERRORS"
eq "hatalı liste: geçerli 2 satır kalır" "Gecerli1 Gecerli2" "${PL_NAME[*]}"
eq "sha256 küçük harfe çevrilir" "4c55374f54e763fdff0ac5d4e7e4931defda5d1b06f1930f3e41c53680f280c7" "${PL_SHA[1]}"
errs=$(<"$T/err")
has "url: sha256 zorunlu" "plugins-invalid.list:3: 'url' kaynağında 5. sütun (sha256) ZORUNLU" "$errs"
has "bilinmeyen kaynak" "plugins-invalid.list:4: bilinmeyen kaynak 'ftp'" "$errs"
has "geçersiz ad (/)" "plugins-invalid.list:5: geçersiz eklenti adı" "$errs"
has "kısa sha256" "plugins-invalid.list:6: 5. sütun 64 haneli" "$errs"
has "büyük harfli sunucu adı" "plugins-invalid.list:7: geçersiz sunucu listesi" "$errs"
has "eksik sütun" "plugins-invalid.list:8: 4 ya da 5 sütun" "$errs"
has "github kimliği sahip/depo:dosya olmalı" "plugins-invalid.list:9: 'github' kaynağı için geçersiz kimlik" "$errs"
has "url https olmalı" "plugins-invalid.list:10: 'url' kaynağı için geçersiz kimlik" "$errs"
has "fazla sütun" "plugins-invalid.list:11: 4 ya da 5 sütun" "$errs"
has "local: '..' reddedilir" "plugins-invalid.list:13: 'local' kaynağı için geçersiz kimlik" "$errs"
has "local: .jar olmalı" "plugins-invalid.list:14: 'local' kaynağı için geçersiz kimlik" "$errs"
eq "local: \$MC_ROOT önekli kimlik kabul edilir" "LibreLogin|local|\$MC_ROOT/artifacts/LibreLogin.jar||12" \
    "$(load_plugins_list "$FIX/config/plugins.list" 2>/dev/null; plugins_for velocity velocity | grep '^LibreLogin' | row)"
printf 'all Hepsi modrinth x\nlimbo Yanlis modrinth y\nbackends Arka modrinth z\n' >"$T/all.list"
load_plugins_list "$T/all.list" 2>/dev/null
eq "'all' paper'a düşer" "Hepsi Arka" "$(names lobby paper)"
eq "'all' velocity'ye düşer" "Hepsi" "$(names velocity velocity)"
eq "'all' ve 'backends' limbo'ya (Java değil) düşmez; yalnız açık ad" "Yanlis" "$(names limbo limbo)"
load_plugins_list "$T/yok.list" 2>/dev/null
eq "liste yoksa: uyarı, hata değil" "0|0" "$?|${#PL_NAME[@]}"

echo "== 3. uçtan uca (taklit ağ)"
# Taklit ağ: urls.tsv'deki URL'leri $FXD altındaki dosyalarla yanıtlar; her çağrıyı kaydeder.
FXD="$T/fx"
cp -r "$FIX" "$FXD"
CALLS="$T/calls" ARGS="$T/args"
: >"$CALLS"
: >"$ARGS"
lookup() { awk -F'\t' -v u="$1" '$1 == u { print $2; exit }' "$FXD/urls.tsv"; }
http_get() {
    local rel
    [[ -n ${DOWNLOAD_USER_AGENT:-} ]] || { echo "MOCK: User-Agent yok" >&2; return 99; }
    [[ $1 != *api.papermc.io/v2* ]] || { echo "MOCK: eski v2 API" >&2; return 98; }
    rel=$(lookup "$1")
    [[ -n $rel ]] || { echo "MOCK: bilinmeyen URL $1" >&2; return 22; }
    printf 'GET %s\n' "$1" >>"$CALLS"
    printf '%s\n' "$*" >>"$ARGS"
    local a
    for a in "$@"; do # -H @dosya: izinleri ve içeriği kaydet (jeton argv'de olmamalı)
        if [[ $a == @* ]]; then printf 'HFILE %s %s\n' "$(stat -c %a "${a#@}")" "$(<"${a#@}")" >>"$ARGS"; fi
    done
    cat -- "$FXD/$rel"
}
http_fetch() {
    local rel
    rel=$(lookup "$1")
    [[ -n $rel ]] || { echo "MOCK: bilinmeyen URL $1" >&2; return 22; }
    printf 'FETCH %s\n' "$1" >>"$CALLS"
    cp -- "$FXD/$rel" "$2"
}
# shellcheck disable=SC2034  # lib.sh/download.sh fonksiyonları okur
CONFIG_DIR="$FXD/config"
SV="$MC_ROOT/servers"
run_main() { (main "$@") >"$T/out" 2>&1; }
fetches() { grep -c '^FETCH' "$CALLS"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
jars() { find "$1" -maxdepth 1 -name '*.jar' -printf '%f\n' | sort | paste -sd' '; }
check() { # <ad> <koşul...>
    local n=$1
    shift
    if "$@"; then ok "$n"; else bad "$n"; fi
}

mkdir -p "$SV" "$MC_ROOT/artifacts"
printf 'PK\003\004librelogin 39397c4 (test)\n' >"$MC_ROOT/artifacts/LibreLogin.jar"
run_main --dry-run all
rc=$?
eq "kuru çalıştırma: başarılı" "0" "$rc"
eq "kuru çalıştırma: hiçbir dosya yazılmaz" "" "$(find "$SV" -mindepth 1 | head -n1)"
eq "kuru çalıştırma: jar indirilmez" "0" "$(fetches)"
has "kuru çalıştırma: plan listelenir" "indirilecek" "$(<"$T/out")"

: >"$CALLS"
run_main all
rc=$?
eq "ilk indirme: başarılı" "0" "$rc"
[[ $rc -eq 0 ]] || cat "$T/out"
eq "lobby server.jar = Paper 26.2 #16" "$(sha "$FIX/payload/paper-26.2-16.bin")" "$(sha "$SV/lobby/server.jar")"
eq "survival server.jar = Paper 26.2 #16" "$(sha "$FIX/payload/paper-26.2-16.bin")" "$(sha "$SV/survival/server.jar")"
eq "velocity server.jar = Velocity 4.2.0 #520" "$(sha "$FIX/payload/velocity-4.2.0-520.bin")" "$(sha "$SV/velocity/server.jar")"
eq ".server.jar.meta içeriği" "paper 26.2 16 $(sha "$FIX/payload/paper-26.2-16.bin")" "$(<"$SV/lobby/.server.jar.meta")"
eq "Paper build'i bir kez sorgulanır (önbellek)" "1" "$(grep -c 'GET https://fill.papermc.io/v3/projects/paper/versions/26.2/builds' "$CALLS")"
eq "jar izinleri 0640" "640" "$(stat -c %a "$SV/lobby/server.jar")"
eq "hiç başlamamış sunucu: eklenti doğrudan plugins/" \
    "Floodgate.jar Geyser.jar LibreLogin.jar LuckPerms.jar Sonar.jar" "$(jars "$SV/velocity/plugins")"
eq "local: LibreLogin artifacts/'tan kopyalanır" "$(sha "$MC_ROOT/artifacts/LibreLogin.jar")" "$(sha "$SV/velocity/plugins/LibreLogin.jar")"
PICO_BIN=$(tar -xzOf "$FIX/payload/picolimbo.tar.gz" pico_limbo | sha256sum | cut -d' ' -f1)
eq "limbo: PicoLimbo ikilisi arşivden çıkarılır" "$PICO_BIN" "$(sha "$SV/limbo/pico_limbo")"
eq "limbo: ikili 0750 (çalıştırılabilir)" "750" "$(stat -c %a "$SV/limbo/pico_limbo")"
eq "limbo: .pico_limbo.meta" "picolimbo v1.14.1+mc26.3 $(sha "$FIX/payload/picolimbo.tar.gz") $PICO_BIN" "$(<"$SV/limbo/.pico_limbo.meta")"
eq "limbo: '+' URL'de %2B" "1" "$(grep -c 'FETCH https://github.com/Quozul/PicoLimbo/releases/download/v1.14.1%2Bmc26.3/pico_limbo_linux-x86_64-musl.tar.gz' "$CALLS")"
check "limbo: jar/eklenti dizini oluşmaz" test ! -e "$SV/limbo/server.jar" -a ! -e "$SV/limbo/plugins"
has "limbo: eklenti adımı atlanır" "limbo: TYPE=limbo Java sunucusu değil" "$(<"$T/out")"
eq "survival eklentileri" "Chunky.jar Example.jar LuckPerms.jar ViaBackwards.jar ViaVersion.jar" \
    "$(jars "$SV/survival/plugins")"
eq "LuckPerms bukkit/velocity doğru dosya" "$(sha "$FIX/payload/luckperms-bukkit.bin")|$(sha "$FIX/payload/luckperms-velocity.bin")" \
    "$(sha "$SV/lobby/plugins/LuckPerms.jar")|$(sha "$SV/velocity/plugins/LuckPerms.jar")"
eq "geyser: çözülmüş sürüm/build adresinden indirilir" "1" \
    "$(grep -c 'FETCH https://download.geysermc.org/v2/projects/geyser/versions/2.11.2/builds/1003/downloads/velocity' "$CALLS")"
has "hash vermeyen kaynak için .plugins.meta" "LuckPerms"$'\t'"https://download.luckperms.net/1600/velocity/" "$(<"$SV/velocity/.plugins.meta")"
check "başlamamış sunucuda plugins/update oluşmaz" test ! -d "$SV/lobby/plugins/update"

: >"$CALLS"
run_main all
rc=$?
eq "ikinci çalıştırma: başarılı" "0" "$rc"
eq "ikinci çalıştırma: hiçbir şey indirilmez (güncel)" "0" "$(fetches)"
has "ikinci çalıştırma: limbo güncel" "PicoLimbo v1.14.1+mc26.3" "$(grep 'güncel' "$T/out")"
has "özet: güncel" "güncel" "$(<"$T/out")"

# Sunucular bir kez çalışmış gibi; Paper'a yeni STABLE build, ViaVersion'a yeni sürüm gelir.
for s in lobby survival velocity; do mkdir -p "$SV/$s/logs" && : >"$SV/$s/logs/latest.log"; done
printf 'PK\003\004yeni paper 17\n' >"$FXD/payload/paper-new.bin"
newsha=$(sha "$FXD/payload/paper-new.bin")
jq --arg s "$newsha" '.[1].channel = "STABLE" | .[1].downloads["server:default"].checksums.sha256 = $s
    | .[1].downloads["server:default"].url = "https://fill-data.papermc.io/v1/objects/\($s)/paper-26.2-17.jar"' \
    "$FIX/api/paper-26.2-builds.json" >"$FXD/api/paper-26.2-builds.json"
printf 'https://fill-data.papermc.io/v1/objects/%s/paper-26.2-17.jar\tpayload/paper-new.bin\n' "$newsha" >>"$FXD/urls.tsv"
printf 'PK\003\004viaversion 5.5.2\n' >"$FXD/payload/viaversion-new.bin"
jq --arg h "$(sha512sum "$FXD/payload/viaversion-new.bin" | cut -d' ' -f1)" \
    '.[1].version_number = "5.5.2" | .[1].files[0].hashes.sha512 = $h | .[1].files[0].url = "https://cdn.modrinth.com/data/test/versions/x/ViaVersion-5.5.2.jar"' \
    "$FIX/api/modrinth-viaversion-paper.json" >"$FXD/api/modrinth-viaversion-paper.json"
printf 'https://cdn.modrinth.com/data/test/versions/x/ViaVersion-5.5.2.jar\tpayload/viaversion-new.bin\n' >>"$FXD/urls.tsv"

: >"$CALLS"
run_main all lobby
rc=$?
eq "güncelleme: başarılı" "0" "$rc"
eq "çalışmış sunucu: yeni build server.jar.new olarak konur" "$newsha" "$(sha "$SV/lobby/server.jar.new")"
eq "çalışan jar'a dokunulmaz" "$(sha "$FIX/payload/paper-26.2-16.bin")" "$(sha "$SV/lobby/server.jar")"
eq "meta yeni build'i gösterir" "paper 26.2 17 $newsha" "$(<"$SV/lobby/.server.jar.meta")"
eq "eklenti güncellemesi plugins/update/ altına" "$(sha "$FXD/payload/viaversion-new.bin")" "$(sha "$SV/lobby/plugins/update/ViaVersion.jar")"
eq "yalnız hedef sunucu işlenir (survival'a dokunulmaz)" "" "$(find "$SV/survival" -name '*.new' -o -name update | head -n1)"
: >"$CALLS"
run_main all lobby
eq "bekleyen güncelleme varken tekrar indirilmez" "0" "$(fetches)"

# ExecStartPre'nin yapacağını taklit et: bekleyen güncellemeler uygulanınca yine "güncel" olmalı
mv -f "$SV/lobby/server.jar" "$SV/lobby/server.jar.old" && mv -f "$SV/lobby/server.jar.new" "$SV/lobby/server.jar"
mv -f "$SV/lobby/plugins/update/ViaVersion.jar" "$SV/lobby/plugins/ViaVersion.jar"
: >"$CALLS"
run_main all lobby
eq "uygulanmış güncelleme sonrası indirme yok" "0|0" "$?|$(fetches)"

# Hash uyuşmazlığı: bozuk dosya reddedilir, diğer eklentilere devam edilir, çıkış kodu 1
printf 'PK\003\004kurcalanmis\n' >"$FXD/payload/chunky.bin"
rm -f "$SV/survival/plugins/Chunky.jar" "$SV/survival/plugins/Example.jar"
: >"$CALLS"
run_main plugins survival
rc=$?
eq "bozuk indirme: çıkış kodu 1" "1" "$rc"
check "bozuk dosya yerleştirilmez" test ! -e "$SV/survival/plugins/Chunky.jar" -a ! -e "$SV/survival/plugins/update/Chunky.jar"
has "SHA-512 uyuşmazlığı raporlanır" "SHA512 uyuşmuyor" "$(<"$T/out")"
check "diğer eklentilere devam edilir (Example indirildi)" test -f "$SV/survival/plugins/update/Example.jar"
eq "geçici dosya kalmaz" "" "$(find "$SV" -name '.*.??????' -o -name '.server.jar.??????' | head -n1)"

# Bilinmeyen/başarısız kaynak: diğerlerine devam
sed -i '/Sonar-Velocity.jar/d' "$FXD/urls.tsv"
rm -f "$SV/velocity/plugins/Sonar.jar"
run_main plugins velocity
rc=$?
eq "indirilemeyen kaynak: çıkış kodu 1" "1" "$rc"
has "özet tablosu HATA satırı" "Sonar" "$(grep HATA "$T/out")"

# User-Agent zorunlu
sed -i 's/^DOWNLOAD_USER_AGENT=.*/DOWNLOAD_USER_AGENT=""/' "$FXD/config/network.env"
run_main core lobby
eq "DOWNLOAD_USER_AGENT boşsa durur" "1" "$?"
has "User-Agent hata mesajı" "DOWNLOAD_USER_AGENT" "$(<"$T/out")"

run_main core olmayan
eq "tanımsız sunucu: hata" "1" "$?"
run_main --bilinmeyen
eq "bilinmeyen seçenek: hata" "1" "$?"
(main --help) >/dev/null 2>&1
eq "--help: 0" "0" "$?"

echo "== 4. limbo (PicoLimbo) güncelleme ve doğrulama"
cp "$FIX/config/network.env" "$FXD/config/network.env"
LAPI="$FXD/api/github-picolimbo-v1.14.1.json"
TGZ="$FXD/payload/picolimbo.tar.gz"
API_LINE=$(grep 'api.github.com/repos/Quozul' "$FIX/urls.tsv")
mkarchive() { # <arşiv> <tür: elf|metin|bag> — tek üyeli "pico_limbo" arşivi
    local d
    d=$(mktemp -d)
    case $2 in
        elf) printf '\177ELF %s\n' "$RANDOM$RANDOM" >"$d/pico_limbo" ;;
        metin) printf '#!/bin/sh\necho merhaba\n' >"$d/pico_limbo" ;;
        bag) ln -s /etc/passwd "$d/pico_limbo" ;;
    esac
    tar -C "$d" -czf "$1" pico_limbo
    rm -rf -- "$d"
}
set_digest() { # <sha256|boş>
    jq --arg h "$1" '(.assets[] | select(.name == "pico_limbo_linux-x86_64-musl.tar.gz") | .digest) = $h' \
        "$FIX/api/github-picolimbo-v1.14.1.json" >"$LAPI"
}
limbo_state() { find "$SV/limbo" -maxdepth 1 -name 'pico_limbo*' -printf '%f\n' | sort | paste -sd' '; }

mkarchive "$TGZ" elf
set_digest "sha256:$(sha "$TGZ")"
NEWBIN=$(tar -xzOf "$TGZ" pico_limbo | sha256sum | cut -d' ' -f1)
: >"$CALLS"
run_main core limbo
eq "yeni arşiv (aynı sürüm, yeni digest): başarılı" "0" "$?"
eq "var olan ikili varken pico_limbo.new olarak konur" "$NEWBIN" "$(sha "$SV/limbo/pico_limbo.new")"
eq "çalışan pico_limbo'ya dokunulmaz" "$PICO_BIN" "$(sha "$SV/limbo/pico_limbo")"
eq "pico_limbo.new 0750" "750" "$(stat -c %a "$SV/limbo/pico_limbo.new")"
: >"$CALLS"
run_main core limbo
eq "bekleyen güncelleme varken tekrar indirilmez" "0|0" "$?|$(fetches)"

# GitHub API'ye ulaşılamıyor: kurulu sürüm güncel sayılır; yeni kurulum yalnız HTTPS'e güvenir
grep -v 'api.github.com/repos/Quozul' "$FXD/urls.tsv" >"$T/u" && cp "$T/u" "$FXD/urls.tsv"
: >"$CALLS"
run_main core limbo
eq "API yokken: kurulu sürüm güncel (indirme yok)" "0|0" "$?|$(fetches)"
has "API yokken: uyarı" "GitHub API yanıtı alınamadı" "$(<"$T/out")"
rm -rf -- "$SV/limbo"
run_main core limbo
eq "API yokken yeni kurulum: başarılı" "0" "$?"
has "API yokken: doğrulanamadı uyarısı" "yalnızca HTTPS'e güveniliyor" "$(<"$T/out")"
eq "API yokken: ikili yerinde" "$NEWBIN" "$(sha "$SV/limbo/pico_limbo")"
rm -rf -- "$SV/limbo"
printf 'PICOLIMBO_SHA256="%s"\n' "$(printf '0%.0s' {1..64})" >>"$FXD/config/network.env"
run_main core limbo
eq "PICOLIMBO_SHA256 sabiti uyuşmazsa: hata" "1|" "$?|$(limbo_state)"
has "sabit uyuşmazlığı raporlanır" "SHA-256 uyuşmuyor" "$(<"$T/out")"
cp "$FIX/config/network.env" "$FXD/config/network.env"
printf '%s\n' "$API_LINE" >>"$FXD/urls.tsv"

set_digest "sha256:$(printf '1%.0s' {1..64})"
run_main core limbo
eq "digest uyuşmazsa: hata, dosya yazılmaz" "1|" "$?|$(limbo_state)"
has "digest uyuşmazlığı raporlanır" "SHA-256 uyuşmuyor" "$(<"$T/out")"
mkarchive "$TGZ" bag
set_digest "sha256:$(sha "$TGZ")"
run_main core limbo
eq "arşivde pico_limbo sembolik bağsa: reddedilir" "1|" "$?|$(limbo_state)"
has "bağ reddi raporlanır" "düzenli 'pico_limbo' dosyası yok" "$(<"$T/out")"
mkarchive "$TGZ" metin
set_digest "sha256:$(sha "$TGZ")"
run_main core limbo
eq "ELF olmayan ikili reddedilir" "1|" "$?|$(limbo_state)"
has "ELF reddi raporlanır" "ELF ikilisi değil" "$(<"$T/out")"

echo "== 5. local kaynak (LibreLogin)"
LL="$MC_ROOT/artifacts/LibreLogin.jar"
# shellcheck disable=SC2016  # plugins.list'te '$MC_ROOT' birebir yazılır; download.sh kendisi açar
MCR='$MC_ROOT'
printf 'velocity LibreLogin local %s/artifacts/LibreLogin.jar\n' "$MCR" >"$T/local.list"
: >"$CALLS"
PLUGINS_LIST="$T/local.list" run_main plugins velocity
eq "değişmeyen yerel jar: güncel, kopyalanmaz" "0|" "$?|$(find "$SV/velocity/plugins" -path '*update*' -name 'LibreLogin.jar')"
printf 'PK\003\004librelogin yeni derleme\n' >"$LL"
PLUGINS_LIST="$T/local.list" run_main plugins velocity
eq "yeni derleme: plugins/update/ altına konur" "0|$(sha "$LL")" "$?|$(sha "$SV/velocity/plugins/update/LibreLogin.jar")"
printf '%s  LibreLogin.jar\n' "$(printf 'a%.0s' {1..64})" >"$LL.sha256"
PLUGINS_LIST="$T/local.list" run_main plugins velocity
eq "yan .sha256 dosyası uyuşmazsa: hata" "1" "$?"
has "yan özet hatası" "LibreLogin.jar.sha256 ile uyuşmuyor" "$(<"$T/out")"
sha256sum "$LL" | sed 's#  .*#  LibreLogin.jar#' >"$LL.sha256"
PLUGINS_LIST="$T/local.list" run_main plugins velocity
eq "yan .sha256 uyuşuyorsa: başarılı" "0" "$?"
printf 'velocity LibreLogin local %s/artifacts/LibreLogin.jar %s\n' "$MCR" "$(printf 'b%.0s' {1..64})" >"$T/local.list"
PLUGINS_LIST="$T/local.list" run_main plugins velocity
eq "5. sütun sabiti uyuşmazsa: hata" "1" "$?"
has "sabit uyuşmazlığı" "sabit sha256 uyuşmuyor" "$(<"$T/out")"
printf 'velocity LibreLogin local %s/artifacts/Yok.jar\n' "$MCR" >"$T/local.list"
PLUGINS_LIST="$T/local.list" run_main plugins velocity
eq "olmayan yerel dosya: hata" "1" "$?"
has "olmayan dosya mesajı" "local: dosya yok" "$(<"$T/out")"
ln -s /etc/passwd "$MC_ROOT/artifacts/Kacak.jar"
printf 'velocity Kacak local %s/artifacts/Kacak.jar\nvelocity Mutlak local /etc/Mutlak.jar\n' "$MCR" >"$T/local.list"
PLUGINS_LIST="$T/local.list" run_main plugins velocity
eq "artifacts dışına çıkan bağ ve mutlak yol: hata" "1|" "$?|$(find "$SV/velocity/plugins" -name 'Kacak.jar' -o -name 'Mutlak.jar')"
eq "ikisi de reddedilir" "2" "$(grep -c 'artifacts/ altında değil' "$T/out")"

echo "== 6. GITHUB_TOKEN komut satırına girmez"
: >"$ARGS"
GITHUB_TOKEN=gizli-jeton-123 run_main --dry-run core limbo
eq "kuru çalıştırma: başarılı" "0" "$?"
eq "jeton argv'de yok" "0" "$(grep -v '^HFILE' "$ARGS" | grep -c 'gizli-jeton-123')"
has "başlık dosyadan (-H @...)" "-H @" "$(<"$ARGS")"
has "başlık dosyası 0600 ve doğru içerik" "HFILE 600 Authorization: Bearer gizli-jeton-123" "$(<"$ARGS")"

echo "== 7. sembolik bağ saldırısı (root + nobody)"
if [[ $(id -u) -eq 0 ]] && NB_UID=$(id -u nobody 2>/dev/null); then
    NB_GID=$(id -g nobody)
    rm -rf -- "$FXD"
    cp -r "$FIX" "$FXD"
    chmod 0755 "$T"
    R2="$T/r2" S2="$T/r2/servers"
    mkdir -p "$S2" "$T/disari1" "$T/disari2"
    for v in 1 2 3 4; do
        printf '%s\n' "root:\$6\$GIZLI$v" >"$T/kurban$v"
        chmod 0600 "$T/kurban$v"
    done
    # lobby: güncel jar + meta bağı; plugins/update başka yere bağ
    mkdir -p "$S2/lobby/plugins" "$S2/lobby/logs"
    : >"$S2/lobby/logs/latest.log"
    cp "$FIX/payload/paper-26.2-16.bin" "$S2/lobby/server.jar"
    ln -s "$T/kurban1" "$S2/lobby/.server.jar.meta"
    ln -s "$T/disari2" "$S2/lobby/plugins/update"
    # velocity: eski jar, server.jar.new ve .plugins.meta bağ
    mkdir -p "$S2/velocity/plugins"
    printf 'PK\003\004eski\n' >"$S2/velocity/server.jar"
    ln -s "$T/kurban2" "$S2/velocity/.plugins.meta"
    ln -s "$T/kurban3" "$S2/velocity/server.jar.new"
    # limbo: meta bağ; survival: dizinin kendisi bağ
    mkdir -p "$S2/limbo"
    ln -s "$T/kurban4" "$S2/limbo/.pico_limbo.meta"
    ln -s "$T/disari1" "$S2/survival"
    chown -R -h "$NB_UID:$NB_GID" "$S2"
    printf 'velocity LuckPerms luckperms velocity\nlobby LuckPerms luckperms bukkit\n' >"$T/sym.list"
    (
        MC_ROOT=$R2 SERVERS_DIR=$S2 MC_USER=nobody PLUGINS_LIST="$T/sym.list"
        main all
    ) >"$T/out" 2>&1
    eq "saldırı senaryosu: hata raporlanır (survival, lobby update)" "1" "$?"
    for v in 1 2 3 4; do
        eq "kurban$v değişmedi (içerik, 0600, root)" "root:\$6\$GIZLI$v|600|root" \
            "$(<"$T/kurban$v")|$(stat -c %a "$T/kurban$v")|$(stat -c %U "$T/kurban$v")"
    done
    check "lobby .server.jar.meta artık düzenli dosya" test -f "$S2/lobby/.server.jar.meta" -a ! -L "$S2/lobby/.server.jar.meta"
    eq "lobby meta içeriği" "paper 26.2 16 $(sha "$FIX/payload/paper-26.2-16.bin")" "$(<"$S2/lobby/.server.jar.meta")"
    eq "yazılan dosyalar minecraft (nobody) sahipli" "nobody nobody nobody nobody" \
        "$(stat -c %U "$S2/lobby/.server.jar.meta" "$S2/velocity/.plugins.meta" "$S2/velocity/server.jar.new" "$S2/limbo/pico_limbo" | paste -sd' ')"
    check "velocity server.jar.new bağın yerine gerçek dosya" test -f "$S2/velocity/server.jar.new" -a ! -L "$S2/velocity/server.jar.new"
    eq "velocity server.jar.new = Velocity 4.2.0" "$(sha "$FIX/payload/velocity-4.2.0-520.bin")" "$(sha "$S2/velocity/server.jar.new")"
    has ".plugins.meta düzenli ve LuckPerms içerir" "LuckPerms"$'\t' "$(<"$S2/velocity/.plugins.meta")"
    check ".plugins.meta kurban içeriğini sızdırmaz" test "$(grep -c GIZLI "$S2/velocity/.plugins.meta")" = 0
    eq "dışarıdaki dizinlere hiçbir şey yazılmaz" "" "$(find "$T/disari1" "$T/disari2" -mindepth 1)"
    has "bağlı sunucu dizini reddedilir" "Güvenlik: $S2/survival sembolik bağ" "$(<"$T/out")"
    has "bağlı plugins/update reddedilir" "Güvenlik: $S2/lobby/plugins/update sembolik bağ" "$(<"$T/out")"
else
    echo "  (atlandı: root ve 'nobody' kullanıcısı gerekir)"
fi

echo
echo "Sonuç: $PASS başarılı, $FAILN başarısız"
((FAILN == 0))
