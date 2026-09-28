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
eq "geçerli liste: 9 girdi (yorum/boş satırlar atlanır)" "9" "${#PL_NAME[@]}"
names() { plugins_for "$1" "$2" | cut -d $'\x1f' -f1 | paste -sd' '; }
eq "velocity eklentileri" "Geyser Floodgate LuckPerms Sonar" "$(names velocity velocity)"
eq "lobby eklentileri ('backends' dahil)" "LuckPerms ViaVersion ViaBackwards" "$(names lobby paper)"
eq "survival eklentileri" "LuckPerms ViaVersion Chunky ViaBackwards Example" "$(names survival paper)"
eq "backends, velocity'ye düşmez; yeni paper sunucusuna düşer" "ViaVersion ViaBackwards" "$(names yeni paper)"
eq "satır sonu yorumu ve sekmeler" "Floodgate|geysermc|floodgate/velocity||4" "$(plugins_for velocity velocity | sed -n 2p | row)"
eq "url + sha256 sütunu" "Example|url|https://downloads.example.org/Example-1.0.jar|4c55374f54e763fdff0ac5d4e7e4931defda5d1b06f1930f3e41c53680f280c7|11" \
    "$(plugins_for survival paper | grep '^Example' | row)"

load_plugins_list "$FIX/plugins-invalid.list" 2>"$T/err"
rc=$?
eq "hatalı liste: dönüş kodu 1" "1" "$rc"
eq "hatalı liste: 9 satır reddedilir" "9" "$PL_ERRORS"
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
load_plugins_list "$T/yok.list" 2>/dev/null
eq "liste yoksa: uyarı, hata değil" "0|0" "$?|${#PL_NAME[@]}"

echo "== 3. uçtan uca (taklit ağ)"
# Taklit ağ: urls.tsv'deki URL'leri $FXD altındaki dosyalarla yanıtlar; her çağrıyı kaydeder.
FXD="$T/fx"
cp -r "$FIX" "$FXD"
CALLS="$T/calls"
: >"$CALLS"
lookup() { awk -F'\t' -v u="$1" '$1 == u { print $2; exit }' "$FXD/urls.tsv"; }
http_get() {
    local rel
    [[ -n ${DOWNLOAD_USER_AGENT:-} ]] || { echo "MOCK: User-Agent yok" >&2; return 99; }
    [[ $1 != *api.papermc.io/v2* ]] || { echo "MOCK: eski v2 API" >&2; return 98; }
    rel=$(lookup "$1")
    [[ -n $rel ]] || { echo "MOCK: bilinmeyen URL $1" >&2; return 22; }
    printf 'GET %s\n' "$1" >>"$CALLS"
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

mkdir -p "$SV"
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
    "Floodgate.jar Geyser.jar LuckPerms.jar Sonar.jar" "$(jars "$SV/velocity/plugins")"
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

echo
echo "Sonuç: $PASS başarılı, $FAILN başarısız"
((FAILN == 0))
