#!/usr/bin/env bash
# Sunucu çekirdeklerini ve config/plugins.list'teki eklentileri indirir:
#   paper/velocity → PaperMC Fill v3 jar'ı;  limbo → PicoLimbo yerel ikilisi (GitHub sürümü).
#
# Kullanım: download.sh [--dry-run] [all|core|plugins] [sunucu|all]
#
# Çalışan sunucunun dosyalarına dokunulmaz: yenileri bir sonraki başlatmada devreye girer
# (mc@.service ExecStartPre: server.jar.new / pico_limbo.new → yerine, plugins/update/*.jar → plugins/).
#
# Güvenlik: sunucu dizinleri minecraft kullanıcısınca yazılabilir; ele geçirilmiş bir sunucu oraya
# sembolik bağ koyabilir. Bu yüzden root iken sunucu dizinlerindeki TÜM okuma/yazma/silme işlemleri
# minecraft kimliğiyle yapılır (as_mc); indirme ve doğrulama root'a ait geçici dizinde olur.
set -Eeuo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

FILL_API="${FILL_API:-https://fill.papermc.io/v3}"
GEYSER_API="${GEYSER_API:-https://download.geysermc.org/v2}"
LUCKPERMS_META="${LUCKPERMS_META:-https://metadata.luckperms.net/data/all}"
MODRINTH_API="${MODRINTH_API:-https://api.modrinth.com/v2}"
HANGAR_API="${HANGAR_API:-https://hangar.papermc.io/api/v1}"
GITHUB_API="${GITHUB_API:-https://api.github.com}"
GITHUB_DL="${GITHUB_DL:-https://github.com}"
PICOLIMBO_REPO="${PICOLIMBO_REPO:-Quozul/PicoLimbo}"
PICOLIMBO_ASSET="${PICOLIMBO_ASSET:-pico_limbo_linux-x86_64-musl.tar.gz}"
PICOLIMBO_DEFAULT_VERSION="v1.14.1+mc26.3"

# jq satır çıktılarında alan ayırıcı (boş alanlar korunur; sekme gibi birleşmez)
SEP=$'\x1f'

DRY_RUN=0
FAILS=0
WORK_DIR=""
API_FILE=""
PAYLOAD=""
CORE_ROW=""
LIMBO_ROW=""
P_URL="" P_ALGO="" P_HASH="" P_VER=""
declare -a TMP_PATHS=() REPORT=()
declare -a PL_LINE=() PL_SERVERS=() PL_NAME=() PL_SOURCE=() PL_ID=() PL_SHA=()
declare -A HTTP_CACHE=() CORE_CACHE=() DL_CACHE=()
# GitHub API başlıkları. Jeton (GITHUB_TOKEN) argv'de görünmesin diye main() 0600 dosyadan ekler (-H @dosya).
declare -a GH_HDR=(-H 'Accept: application/vnd.github+json')

usage() {
    cat <<'EOF'
Kullanım: mc download [--dry-run] [all|core|plugins] [sunucu|all]

  core      paper/velocity: sunucu jar'ı (PaperMC Fill v3, SHA-256 doğrulamalı)
              -> servers/<srv>/server.jar  (zaten varsa server.jar.new; sonraki başlatmada geçer)
            limbo: PicoLimbo ikilisi (network.env PICOLIMBO_VERSION; GitHub digest varsa doğrulanır)
              -> servers/<srv>/pico_limbo  (zaten varsa pico_limbo.new)
  plugins   config/plugins.list'teki eklentiler (hash varsa doğrulanır; yalnız paper/velocity)
              -> servers/<srv>/plugins/update/<ad>.jar  (sunucu hiç başlamadıysa plugins/<ad>.jar)
  all       ikisi de (varsayılan)

  --dry-run   hiçbir şey indirmeden/yazmadan ne yapılacağını gösterir

Aynı build/dosya zaten kuruluysa atlanır. Bir kaynak başarısız olursa diğerlerine devam edilir;
sonda özet basılır ve hata varsa çıkış kodu 1 olur.
EOF
}

cleanup() {
    local p
    for p in "${TMP_PATHS[@]}"; do
        [[ -n $p ]] && rm -rf -- "$p"
    done
}

# --- Yetki ayrımı (as_mc: lib.sh) -----------------------------------------------
# place_file <kaynak> <hedef> <mod> — hedefin dizininde geçici dosyaya yazar, sonra mv -T ile değiştirir.
# rename, hedefteki sembolik bağın KENDİSİNİ değiştirir; bağın gösterdiği dosyaya yazılmaz.
# shellcheck disable=SC2016  # betik minecraft kimliğiyle çalışan sh'de genişler
PLACE_SH='set -eu
t=$(mktemp "${1%/*}/.${1##*/}.XXXXXX")
trap "rm -f -- \"\$t\"" EXIT
cat >"$t"
chmod "$2" -- "$t"
mv -fT -- "$t" "$1"'
place_file() {
    as_mc sh -c "$PLACE_SH" sh "$2" "$3" <"$1"
}

# write_meta <hedef> <içerik> — tek satırlık meta dosyasını güvenle yazar (0640)
write_meta() {
    local tmp
    tmp=$(mktemp "$WORK_DIR/meta.XXXXXX") || return 1
    printf '%s\n' "$2" >"$tmp" || return 1
    place_file "$tmp" "$1" 0640
}

# mc_read <dosya> — sembolik bağ ya da düzenli olmayan dosyayı okumaz; okumayı minecraft yapar
mc_read() {
    [[ -f $1 && ! -L $1 ]] || return 1
    as_mc cat -- "$1"
}

mc_rm() { as_mc rm -f -- "$@"; }

ensure_dir() { # <dizin> — yoksa minecraft olarak 0750 oluşturur (üst dizin var olmalı)
    if [[ -L $1 ]]; then
        log_error "Güvenlik: $1 sembolik bağ; kullanılmadı."
        return 1
    fi
    [[ -d $1 ]] && return 0
    as_mc mkdir -m 0750 -- "$1"
}

# check_server_dir <sunucu> <öğe> — sunucu dizini sembolik bağsa reddeder
check_server_dir() {
    if [[ -L $SERVERS_DIR/$1 ]]; then
        log_error "Güvenlik: $SERVERS_DIR/$1 sembolik bağ; dokunulmadı."
        report "$1" "$2" "HATA" "sunucu dizini sembolik bağ"
        return 1
    fi
}

# --- Ağ ---------------------------------------------------------------------
CURL_OPTS=(-fsSL --show-error --retry 3 --connect-timeout 15 --proto "=https" --proto-redir "=https")

# http_get <url> [ek curl seçenekleri...] — gövdeyi stdout'a yazar
http_get() {
    local url=$1
    shift
    curl "${CURL_OPTS[@]}" --max-time 120 -A "$DOWNLOAD_USER_AGENT" "$@" "$url"
}

# http_fetch <url> <hedef-dosya>
http_fetch() {
    curl "${CURL_OPTS[@]}" -A "$DOWNLOAD_USER_AGENT" -o "$2" "$1"
}

# api_get <url> [ek curl seçenekleri...] — yanıtı dosyaya alır, yolunu API_FILE'a koyar.
# Aynı çalıştırmada aynı URL bir kez istenir (ör. lobby ve survival aynı Paper build'ini paylaşır).
api_get() {
    local url=$1 f
    if [[ -n ${HTTP_CACHE[$url]:-} ]]; then
        API_FILE=${HTTP_CACHE[$url]}
        return 0
    fi
    f=$(mktemp "$WORK_DIR/api.XXXXXX") || return 1
    if ! http_get "$@" >"$f"; then
        log_error "İstek başarısız: $url"
        return 1
    fi
    HTTP_CACHE[$url]=$f
    API_FILE=$f
}

# fetch_payload <url> — dosyayı root'a ait WORK_DIR'e indirir (aynı URL bir kez), yolu PAYLOAD'a koyar.
# "local:<yol>" ise yerel dosyanın kendisi kullanılır (kopyalanmaz).
fetch_payload() {
    local url=$1 f
    if [[ $url == local:* ]]; then
        PAYLOAD=${url#local:}
        [[ -f $PAYLOAD ]]
        return
    fi
    if [[ -n ${DL_CACHE[$url]:-} && -f ${DL_CACHE[$url]} ]]; then
        PAYLOAD=${DL_CACHE[$url]}
        return 0
    fi
    f=$(mktemp "$WORK_DIR/dl.XXXXXX") || return 1
    if ! http_fetch "$url" "$f"; then
        rm -f -- "$f"
        return 1
    fi
    DL_CACHE[$url]=$f
    PAYLOAD=$f
}

# drop_payload <url> — doğrulanamayan indirmeyi atar (bir sonraki kullanımda yeniden indirilir)
drop_payload() {
    [[ $1 == local:* ]] && return 0
    if [[ -n ${DL_CACHE[$1]:-} ]]; then rm -f -- "${DL_CACHE[$1]}"; fi
    DL_CACHE[$1]=""
}

urlencode() { jq -rn --arg s "$1" '$s | @uri'; }

# --- jq seçicileri (stdin: API yanıtı; çıktı: SEP ile ayrılmış tek satır) -----
# Hata durumunda stderr'e Türkçe açıklama yazar ve 0 dışı kodla çıkar.
JQ_LIB='
def fail(m): ("  " + m + "\n") | halt_error(5);
def row: map(if . == null then "" else tostring end | gsub("[\u0000-\u001f]"; "")) | join("\u001f");
'

# Fill v3 /versions/<v>/builds (en yeni önce). $1 = kanal ("STABLE").
# $1 boşsa: STABLE olan ilk build, yoksa listedeki ilk build (Velocity).
# Çıktı: build SEP dosya-adı SEP url SEP sha256
jq_fill_build() {
    jq -r --arg ch "$1" "$JQ_LIB"'
      if type != "array" then fail("Fill: beklenmeyen yanıt (build dizisi değil)") else . end
      | (if $ch == "" then ([.[] | select(.channel == "STABLE")][0] // .[0])
         else [.[] | select(.channel == $ch)][0] end) as $b
      | if $b == null then fail("Fill: uygun build yok (kanal: \(if $ch == "" then "herhangi" else $ch end))") else $b end
      | .downloads["server:default"] as $d
      | if $d == null then fail("Fill: build \(.id) için \"server:default\" indirmesi yok (mevcut: \(.downloads // {} | keys | join(", ")))") else . end
      | if (($d.checksums.sha256 // "") | test("^[0-9a-fA-F]{64}$")) then . else fail("Fill: build \(.id) sha256 içermiyor") end
      | if (($d.url // "") | startswith("https://")) then . else fail("Fill: build \(.id) indirme adresi geçersiz") end
      | [.id, $d.name, $d.url, ($d.checksums.sha256 | ascii_downcase)] | row'
}

# Fill v3 /projects/<p>: "SNAPSHOT" içermeyen en yeni sürüm.
# Sürümler sayısal olarak büyükten küçüğe sıralanır (API sırasına bel bağlanmaz).
jq_fill_latest_version() {
    jq -r "$JQ_LIB"'
      def vkey: [splits("[.+-]") | (tonumber? // -1)];
      [ (.versions // {}) | to_entries[] | .value[] | select(test("SNAPSHOT"; "i") | not) ]
      | sort_by(vkey) | reverse | .[0]
      | if . == null then fail("Fill: SNAPSHOT olmayan sürüm bulunamadı") else . end'
}

# GeyserMC /v2/projects/<p>/versions/latest/builds/latest. $1 = platform (velocity, spigot...)
# Çıktı: sürüm SEP build SEP dosya-adı SEP sha256
jq_geyser_pick() {
    jq -r --arg p "$1" "$JQ_LIB"'
      .downloads[$p] as $d
      | if $d == null then fail("GeyserMC: \"\($p)\" platformu yok (mevcut: \(.downloads // {} | keys | join(", ")))") else . end
      | if (($d.sha256 // "") | test("^[0-9a-fA-F]{64}$")) then . else fail("GeyserMC: sha256 yok") end
      | if ((.version // "") == "" or .build == null) then fail("GeyserMC: sürüm/build bilgisi yok") else . end
      | [.version, .build, $d.name, ($d.sha256 | ascii_downcase)] | row'
}

# LuckPerms metadata (/data/all). $1 = platform (bukkit, velocity...). Hash verilmez.
# Çıktı: sürüm SEP url
jq_luckperms_pick() {
    jq -r --arg p "$1" "$JQ_LIB"'
      (.downloads[$p] // "") as $u
      | if ($u | startswith("https://")) then . else fail("LuckPerms: \"\($p)\" indirmesi yok") end
      | [.version, $u] | row'
}

# Modrinth /v2/project/<slug>/version (en yeni önce). İlk "release" (yoksa ilk sürüm),
# onun birincil dosyası (yoksa ilk dosya).
# Çıktı: sürüm SEP dosya-adı SEP url SEP sha512
jq_modrinth_pick() {
    jq -r "$JQ_LIB"'
      if type != "array" or length == 0 then fail("Modrinth: bu yükleyici/oyun sürümü için uyumlu sürüm yok") else . end
      | ([.[] | select(.version_type == "release")][0] // .[0]) as $v
      | ([($v.files // [])[] | select(.primary == true)][0] // ($v.files // [])[0]) as $f
      | if $f == null then fail("Modrinth: \($v.version_number) sürümünde dosya yok") else . end
      | [$v.version_number, $f.filename, $f.url, ($f.hashes.sha512 // "" | ascii_downcase)] | row'
}

# Hangar /api/v1/projects/<slug>/versions/<ad>. $1 = PAPER | VELOCITY
# Çıktı: dosya-adı SEP url SEP sha256 (harici bağlantıda hash olmayabilir)
jq_hangar_pick() {
    jq -r --arg p "$1" "$JQ_LIB"'
      .downloads[$p] as $d
      | if $d == null then fail("Hangar: \"\($p)\" platformu için indirme yok") else . end
      | ($d.downloadUrl // $d.externalUrl // "") as $u
      | if ($u | startswith("https://")) then . else fail("Hangar: indirme adresi yok") end
      | [($d.fileInfo.name // ""), $u, ($d.fileInfo.sha256Hash // "" | ascii_downcase)] | row'
}

# GitHub /repos/<sahip>/<depo>/releases/{latest|tags/<etiket>}. $1 = dosya adı (ya da "*" içeren kalıp).
# Çıktı: etiket SEP dosya-adı SEP url SEP sha256 ("digest": "sha256:..." varsa; yoksa boş)
jq_github_pick() {
    jq -r --arg n "$1" "$JQ_LIB"'
      def glob2re: split("*") | map(gsub("(?<c>[\\\\^$.|?+()\\[\\]{}])"; "\\\(.c)")) | join(".*") | "^" + . + "$";
      (if ($n | contains("*")) then ($n | glob2re) else null end) as $re
      | [ (.assets // [])[] | select(if $re != null then (.name | test($re)) else .name == $n end) ][0] as $a
      | if $a == null then fail("GitHub: sürümde \"\($n)\" dosyası yok (mevcut: \([(.assets // [])[].name] | join(", ")))") else . end
      | (($a.digest // "") | if startswith("sha256:") then ltrimstr("sha256:") | ascii_downcase else "" end) as $h
      | [.tag_name, $a.name, $a.browser_download_url, $h] | row'
}

# Hangar /latestrelease düz metin sürüm adı döner.
hangar_version_name() {
    local v
    v=$(tr -d '\r\n')
    v=${v#\"}
    v=${v%\"}
    if [[ -z $v || $v == */* || ${#v} -gt 100 ]]; then
        printf '  Hangar: geçersiz sürüm adı\n' >&2
        return 1
    fi
    printf '%s\n' "$v"
}

# Modrinth sorgu dizesi: loaders=["<l>"] [&game_versions=["<g>"]] (URL kodlu)
modrinth_query() {
    jq -rn --arg l "$1" --arg g "$2" \
        '"loaders=" + ([$l] | tojson | @uri) + (if $g == "" then "" else "&game_versions=" + ([$g] | tojson | @uri) end)'
}

# --- plugins.list -----------------------------------------------------------
# Biçim (boşlukla ayrılmış; # sonrası yorum):  sunucular  ad  kaynak  kimlik  [sha256]
# sunucular: virgüllü ad listesi, "backends" (tüm paper) ya da "all" (tüm paper + velocity).

# local kaynağının kimliği: $MC_ROOT/artifacts/... (ya da mutlak yol), .jar, ".." yok
# shellcheck disable=SC2016  # '$MC_ROOT' kimlikte birebir yazılır; betik kendisi açar (local_expand)
LOCAL_ID_RE='^(\$MC_ROOT|\$\{MC_ROOT\})?/[A-Za-z0-9._/+-]+\.jar$'

# plugin_line_check <konum> <alanlar...> — geçerliyse 0; değilse hatayı yazar
plugin_line_check() {
    local ctx=$1
    shift
    local servers=${1:-} name=${2:-} source=${3:-} id=${4:-} sha=${5:-}
    if (($# < 4 || $# > 5)); then
        log_error "$ctx: 4 ya da 5 sütun beklenir (sunucular ad kaynak kimlik [sha256]), $# bulundu"
        return 1
    fi
    if [[ ! $servers =~ ^[a-z][a-z0-9-]*(,[a-z][a-z0-9-]*)*$ ]]; then
        log_error "$ctx: geçersiz sunucu listesi '$servers'"
        return 1
    fi
    if [[ ! $name =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$ ]]; then
        log_error "$ctx: geçersiz eklenti adı '$name' (harf, rakam, . _ + -)"
        return 1
    fi
    if [[ -n $sha && ! $sha =~ ^[0-9a-fA-F]{64}$ ]]; then
        log_error "$ctx: 5. sütun 64 haneli onaltılık sha256 olmalı"
        return 1
    fi
    local ok=1
    case $source in
        geysermc) [[ $id =~ ^[a-z0-9-]+/[a-z0-9-]+$ ]] || ok=0 ;;
        luckperms) [[ $id =~ ^[a-z0-9-]+$ ]] || ok=0 ;;
        modrinth | hangar) [[ $id =~ ^[A-Za-z0-9._-]+$ ]] || ok=0 ;;
        github) [[ $id =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+:[^/[:space:]]+$ ]] || ok=0 ;;
        url)
            [[ $id =~ ^https://[^[:space:]]+$ ]] || ok=0
            if [[ -z $sha ]]; then
                log_error "$ctx: 'url' kaynağında 5. sütun (sha256) ZORUNLU"
                return 1
            fi
            ;;
        local) [[ $id =~ $LOCAL_ID_RE && $id != *..* ]] || ok=0 ;;
        *)
            log_error "$ctx: bilinmeyen kaynak '$source' (geysermc luckperms modrinth hangar github url local)"
            return 1
            ;;
    esac
    if ((ok == 0)); then
        log_error "$ctx: '$source' kaynağı için geçersiz kimlik '$id'"
        return 1
    fi
}

# load_plugins_list <dosya> — satırları doğrulayıp PL_* dizilerine yükler.
# Hatalı satırlar atlanır; hata sayısı PL_ERRORS'a yazılır (0 değilse dönüş 1).
PL_ERRORS=0
load_plugins_list() {
    local file=$1 raw n=0 w
    local -a words=() fields=()
    PL_LINE=() PL_SERVERS=() PL_NAME=() PL_SOURCE=() PL_ID=() PL_SHA=()
    PL_ERRORS=0
    if [[ ! -f $file ]]; then
        log_warn "Eklenti listesi yok: $file (eklenti indirilmeyecek)"
        return 0
    fi
    while IFS= read -r raw || [[ -n $raw ]]; do
        n=$((n + 1))
        raw=${raw%$'\r'}
        read -r -a words <<<"$raw" || true
        fields=()
        for w in "${words[@]}"; do
            [[ $w == '#'* ]] && break
            fields+=("$w")
        done
        ((${#fields[@]} > 0)) || continue
        if ! plugin_line_check "${file##*/}:$n" "${fields[@]}"; then
            PL_ERRORS=$((PL_ERRORS + 1))
            continue
        fi
        PL_LINE+=("$n")
        PL_SERVERS+=("${fields[0]}")
        PL_NAME+=("${fields[1]}")
        PL_SOURCE+=("${fields[2]}")
        PL_ID+=("${fields[3]}")
        PL_SHA+=("$(printf '%s' "${fields[4]:-}" | tr 'A-F' 'a-f')")
    done <"$file"
    ((PL_ERRORS == 0))
}

is_java_type() { [[ $1 == paper || $1 == velocity ]]; }

# plugins_for <sunucu> <tür> — o sunucuya düşen girdiler: ad SEP kaynak SEP kimlik SEP sha256 SEP satır
# "all" yalnız Java sunucularına (paper, velocity) düşer; limbo gibi yerel ikililere değil.
plugins_for() {
    local srv=$1 type=$2 i tok match
    local -a toks=()
    for i in "${!PL_NAME[@]}"; do
        match=0
        IFS=, read -r -a toks <<<"${PL_SERVERS[$i]}"
        for tok in "${toks[@]}"; do
            if [[ $tok == "$srv" ]]; then
                match=1
            elif [[ $tok == all ]] && is_java_type "$type"; then
                match=1
            elif [[ $tok == backends && $type == paper ]]; then
                match=1
            fi
        done
        if ((match)); then
            printf '%s\n' "${PL_NAME[$i]}$SEP${PL_SOURCE[$i]}$SEP${PL_ID[$i]}$SEP${PL_SHA[$i]}$SEP${PL_LINE[$i]}"
        fi
    done
}

# Sunucular sütununda tanımsız ad varsa uyarır (yazım hatası olabilir).
check_plugin_servers() {
    local i tok
    local -a toks=()
    for i in "${!PL_NAME[@]}"; do
        IFS=, read -r -a toks <<<"${PL_SERVERS[$i]}"
        for tok in "${toks[@]}"; do
            [[ $tok == all || $tok == backends ]] && continue
            if ! server_exists "$tok"; then
                log_warn "plugins.list:${PL_LINE[$i]}: tanımsız sunucu '$tok' (${PL_NAME[$i]})"
            elif ! is_java_type "$(server_get "$tok" TYPE)"; then
                log_warn "plugins.list:${PL_LINE[$i]}: '$tok' Java sunucusu değil; ${PL_NAME[$i]} ona kurulmaz."
            fi
        done
    done
}

# --- Dosya yardımcıları -----------------------------------------------------
file_hash() { # <sha256|sha512> <dosya> — root'a ait geçici dosyalar için
    local out
    out=$("${1}sum" -- "$2") || return 1
    printf '%s' "${out%% *}"
}

hash_is() { # <sha256|sha512> <beklenen> <dosya> — root'a ait geçici dosyalar için
    local want=${2,,} got
    [[ -n $want && -f $3 ]] || return 1
    got=$(file_hash "$1" "$3") || return 1
    [[ $got == "$want" ]]
}

# mc_hash_is <sha256|sha512> <beklenen> <dosya> — sunucu dizinindeki dosya için: sembolik bağ ya da
# düzenli olmayan dosya hiç eşleşmez; okumayı minecraft yapar.
mc_hash_is() {
    local want=${2,,} out
    [[ -n $want && -f $3 && ! -L $3 ]] || return 1
    out=$(as_mc "${1}sum" -- "$3") || return 1
    [[ ${out%% *} == "$want" ]]
}

looks_like_jar() { [[ -s $1 && $(head -c 2 -- "$1") == PK ]]; }
looks_like_elf() { [[ -s $1 && $(head -c 4 -- "$1" | od -An -tx1 | tr -d ' \n') == 7f454c46 ]]; }

# Sunucu en az bir kez çalıştı mı? (logs/latest.log ilk açılışta oluşur)
server_started_before() { [[ -e $SERVERS_DIR/$1/logs/latest.log ]] || server_running "$1"; }

report() { REPORT+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"); }

print_report() {
    ((${#REPORT[@]} > 0)) || return 0
    printf '\n'
    {
        printf 'SUNUCU\tÖĞE\tDURUM\tAYRINTI\n'
        printf '%s\n' "${REPORT[@]}"
    } | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
}

# --- Çekirdek (Paper / Velocity) -------------------------------------------
version_ge() { [[ $(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1) == "$2" ]]; }

# resolve_core <paper|velocity> → CORE_ROW = sürüm SEP build SEP ad SEP url SEP sha256
resolve_core() {
    local project=$1 version row
    if [[ -n ${CORE_CACHE[$project]:-} ]]; then
        CORE_ROW=${CORE_CACHE[$project]}
        return 0
    fi
    case $project in
        paper)
            version=${PAPER_MC_VERSION:-}
            [[ $version =~ ^[0-9A-Za-z._-]+$ ]] || { log_error "network.env: PAPER_MC_VERSION geçersiz/boş"; return 1; }
            api_get "$FILL_API/projects/paper/versions/$version/builds" || return 1
            row=$(jq_fill_build "${PAPER_CHANNEL:-STABLE}" <"$API_FILE") || { log_error "Paper $version: build seçilemedi"; return 1; }
            ;;
        velocity)
            version=${VELOCITY_VERSION:-latest}
            if [[ $version == latest ]]; then
                api_get "$FILL_API/projects/velocity" || return 1
                version=$(jq_fill_latest_version <"$API_FILE") || { log_error "Velocity: sürüm seçilemedi"; return 1; }
            fi
            [[ $version =~ ^[0-9A-Za-z._-]+$ ]] || { log_error "Velocity: geçersiz sürüm '$version'"; return 1; }
            if ! version_ge "$version" 4.2.0; then
                log_warn "Velocity $version < 4.2.0: 26.3 istemcileri proxy'den geçemez (en az 4.2.0 önerilir)."
            fi
            api_get "$FILL_API/projects/velocity/versions/$version/builds" || return 1
            row=$(jq_fill_build "" <"$API_FILE") || { log_error "Velocity $version: build seçilemedi"; return 1; }
            ;;
        *)
            log_error "Bilinmeyen proje: $project"
            return 1
            ;;
    esac
    CORE_ROW=$version$SEP$row
    CORE_CACHE[$project]=$CORE_ROW
}

# download_core <sunucu> — TYPE'a göre Paper/Velocity jar'ı ya da PicoLimbo ikilisi.
# Not: '||' ile çağrıldığı için set -e burada etkisizdir; her adım açıkça denetlenir.
download_core() {
    local srv=$1 type
    type=$(server_get "$srv" TYPE)
    check_server_dir "$srv" "çekirdek" || return 1
    case $type in
        paper | velocity) core_jar "$srv" "$type" ;;
        limbo) core_limbo "$srv" ;;
        *)
            log_error "$srv: bilinmeyen TYPE '$type' (paper | velocity | limbo)"
            report "$srv" "çekirdek" "HATA" "TYPE geçersiz"
            return 1
            ;;
    esac
}

# core_jar <sunucu> <paper|velocity>
core_jar() {
    local srv=$1 project=$2 version build name url sha dir meta want dest cur
    if ! resolve_core "$project"; then
        report "$srv" "çekirdek" "HATA" "$project sürüm/build çözülemedi"
        return 1
    fi
    IFS=$SEP read -r version build name url sha <<<"$CORE_ROW"
    dir=$SERVERS_DIR/$srv
    meta=$dir/.server.jar.meta
    want="$project $version $build $sha"

    # Aynı build zaten kurulu ya da başlatmayı bekliyorsa atla (SHA-256 ile doğrulanır).
    if mc_hash_is sha256 "$sha" "$dir/server.jar.new" || mc_hash_is sha256 "$sha" "$dir/server.jar"; then
        if ((DRY_RUN == 0)); then
            if [[ -e $dir/server.jar.new || -L $dir/server.jar.new ]] && ! mc_hash_is sha256 "$sha" "$dir/server.jar.new"; then
                mc_rm "$dir/server.jar.new" # kurulu olanla aynı sürüme dönülüyor: eski bekleyen güncellemeyi at
            fi
            cur=$(mc_read "$meta") || cur=""
            if [[ $cur != "$want" ]]; then
                write_meta "$meta" "$want" || log_warn "$srv: $meta güncellenemedi"
            fi
        fi
        report "$srv" "çekirdek" "güncel" "$project $version #$build"
        return 0
    fi

    if [[ -e $dir/server.jar || -L $dir/server.jar ]]; then dest=server.jar.new; else dest=server.jar; fi
    if ((DRY_RUN)); then
        log_info "[kuru] $srv: $project $version #$build ($name) → $dir/$dest"
        report "$srv" "çekirdek" "indirilecek" "$project $version #$build → $dest"
        return 0
    fi

    if [[ ! -d $SERVERS_DIR ]]; then
        log_error "$SERVERS_DIR yok — önce scripts/install.sh çalıştırın."
        report "$srv" "çekirdek" "HATA" "sunucular dizini yok"
        return 1
    fi
    ensure_dir "$dir" || { report "$srv" "çekirdek" "HATA" "dizin oluşturulamadı"; return 1; }
    log_info "$srv: $project $version #$build indiriliyor..."
    if ! fetch_payload "$url"; then
        log_error "$srv: indirme başarısız: $url"
        report "$srv" "çekirdek" "HATA" "indirme başarısız"
        return 1
    fi
    if ! hash_is sha256 "$sha" "$PAYLOAD"; then
        drop_payload "$url"
        log_error "$srv: SHA-256 uyuşmuyor ($name) — dosya atıldı."
        report "$srv" "çekirdek" "HATA" "SHA-256 uyuşmuyor"
        return 1
    fi
    if ! looks_like_jar "$PAYLOAD"; then
        log_error "$srv: indirilen dosya jar değil ($name)."
        report "$srv" "çekirdek" "HATA" "jar değil"
        return 1
    fi
    if ! place_file "$PAYLOAD" "$dir/$dest" 0640; then
        report "$srv" "çekirdek" "HATA" "yerleştirilemedi"
        return 1
    fi
    write_meta "$meta" "$want" || log_warn "$srv: $meta güncellenemedi"
    if [[ $dest == server.jar.new ]]; then
        log_ok "$srv: $project $version #$build hazır → server.jar.new (sonraki başlatmada geçerli)"
    else
        log_ok "$srv: $project $version #$build → server.jar"
    fi
    report "$srv" "çekirdek" "indirildi" "$project $version #$build → $dest"
}

# --- Çekirdek (PicoLimbo, TYPE=limbo) ------------------------------------------
# resolve_limbo → LIMBO_ROW = sürüm SEP url SEP beklenen-arşiv-sha256 (boş: doğrulanamıyor)
# Özet GitHub API'nin "digest" alanından gelir; network.env PICOLIMBO_SHA256 ile sabitlenebilir.
resolve_limbo() {
    local version tag api f row u digest="" pin
    [[ -n $LIMBO_ROW ]] && return 0
    version=${PICOLIMBO_VERSION:-$PICOLIMBO_DEFAULT_VERSION}
    if [[ ! $version =~ ^[0-9A-Za-z._+-]+$ ]]; then
        log_error "network.env: PICOLIMBO_VERSION geçersiz: '$version'"
        return 1
    fi
    tag=$(urlencode "$version") # "+" → "%2B"
    u="$GITHUB_DL/$PICOLIMBO_REPO/releases/download/$tag/$PICOLIMBO_ASSET"
    api="$GITHUB_API/repos/$PICOLIMBO_REPO/releases/tags/$tag"
    f=$(mktemp "$WORK_DIR/api.XXXXXX") || return 1
    if http_get "$api" "${GH_HDR[@]}" >"$f" 2>"$f.err" && row=$(jq_github_pick "$PICOLIMBO_ASSET" <"$f" 2>>"$f.err"); then
        IFS=$SEP read -r _ _ u digest <<<"$row"
        [[ -n $digest ]] || log_warn "PicoLimbo $version: GitHub sürümünde digest yok."
    else
        log_warn "PicoLimbo $version: GitHub API yanıtı alınamadı ($(tr '\n' ' ' <"$f.err" | cut -c1-200))."
    fi
    pin=${PICOLIMBO_SHA256:-}
    pin=${pin,,}
    if [[ -n $pin ]]; then
        if [[ ! $pin =~ ^[0-9a-f]{64}$ ]]; then
            log_error "network.env: PICOLIMBO_SHA256 64 haneli onaltılık olmalı."
            return 1
        fi
        if [[ -n $digest && $digest != "$pin" ]]; then
            log_error "PicoLimbo $version: PICOLIMBO_SHA256, GitHub digest'iyle uyuşmuyor."
            return 1
        fi
        digest=$pin
    fi
    if [[ ! $u =~ ^https://[^[:space:]]+$ ]]; then
        log_error "PicoLimbo: güvensiz indirme adresi: '$u'"
        return 1
    fi
    LIMBO_ROW=$version$SEP$u$SEP$digest
}

# extract_limbo <arşiv> → yolu yazar. Yalnız "pico_limbo" üyesi, boş bir root dizinine açılır.
extract_limbo() {
    local x m
    x=$(mktemp -d "$WORK_DIR/limbo.XXXXXX") || return 1
    for m in pico_limbo ./pico_limbo; do
        if tar -xzf "$1" -C "$x" --no-same-owner --no-same-permissions -- "$m" 2>/dev/null; then
            break
        fi
    done
    if [[ ! -f $x/pico_limbo || -L $x/pico_limbo || $(stat -c %h -- "$x/pico_limbo") != 1 ]]; then
        log_error "PicoLimbo arşivinde düzenli 'pico_limbo' dosyası yok (içerik: $(tar -tzf "$1" 2>/dev/null | head -n5 | paste -sd' '))."
        return 1
    fi
    if ! looks_like_elf "$x/pico_limbo"; then
        log_error "PicoLimbo: 'pico_limbo' bir ELF ikilisi değil."
        return 1
    fi
    printf '%s\n' "$x/pico_limbo"
}

# core_limbo <sunucu>
# .pico_limbo.meta: "picolimbo <sürüm> <arşiv-sha256> <ikili-sha256>"
core_limbo() {
    local srv=$1 dir meta version url digest rec m_ver="" m_tar="" m_bin="" dest bin tarsha binsha
    if ! resolve_limbo; then
        report "$srv" "çekirdek" "HATA" "PicoLimbo sürümü çözülemedi"
        return 1
    fi
    IFS=$SEP read -r version url digest <<<"$LIMBO_ROW"
    dir=$SERVERS_DIR/$srv
    meta=$dir/.pico_limbo.meta
    rec=$(mc_read "$meta") || rec=""
    read -r _ m_ver m_tar m_bin _ <<<"$rec" || true

    # Aynı sürüm kurulu ya da bekliyorsa atla (digest bilinmiyorsa sürüm + ikili özeti yeter).
    if [[ -n $m_bin && $m_ver == "$version" && (-z $digest || $m_tar == "$digest") ]] &&
        { mc_hash_is sha256 "$m_bin" "$dir/pico_limbo.new" || mc_hash_is sha256 "$m_bin" "$dir/pico_limbo"; }; then
        if ((DRY_RUN == 0)) && [[ -e $dir/pico_limbo.new || -L $dir/pico_limbo.new ]] &&
            ! mc_hash_is sha256 "$m_bin" "$dir/pico_limbo.new"; then
            mc_rm "$dir/pico_limbo.new"
        fi
        report "$srv" "çekirdek" "güncel" "PicoLimbo $version"
        return 0
    fi

    if [[ -e $dir/pico_limbo || -L $dir/pico_limbo ]]; then dest=pico_limbo.new; else dest=pico_limbo; fi
    if ((DRY_RUN)); then
        log_info "[kuru] $srv: PicoLimbo $version ← $url → $dir/$dest"
        report "$srv" "çekirdek" "indirilecek" "PicoLimbo $version → $dest"
        return 0
    fi
    if [[ ! -d $SERVERS_DIR ]]; then
        log_error "$SERVERS_DIR yok — önce scripts/install.sh çalıştırın."
        report "$srv" "çekirdek" "HATA" "sunucular dizini yok"
        return 1
    fi
    ensure_dir "$dir" || { report "$srv" "çekirdek" "HATA" "dizin oluşturulamadı"; return 1; }
    log_info "$srv: PicoLimbo $version indiriliyor..."
    if ! fetch_payload "$url"; then
        log_error "$srv: indirme başarısız: $url"
        report "$srv" "çekirdek" "HATA" "indirme başarısız"
        return 1
    fi
    tarsha=$(file_hash sha256 "$PAYLOAD") || { report "$srv" "çekirdek" "HATA" "özet hesaplanamadı"; return 1; }
    if [[ -n $digest && $tarsha != "$digest" ]]; then
        drop_payload "$url"
        log_error "$srv: PicoLimbo arşivi SHA-256 uyuşmuyor — dosya atıldı."
        report "$srv" "çekirdek" "HATA" "SHA-256 uyuşmuyor"
        return 1
    fi
    if [[ -z $digest ]]; then
        log_warn "$srv: PicoLimbo arşivi doğrulanamadı; yalnızca HTTPS'e güveniliyor (network.env PICOLIMBO_SHA256 ile sabitleyebilirsiniz)."
    fi
    if ! bin=$(extract_limbo "$PAYLOAD"); then
        report "$srv" "çekirdek" "HATA" "arşiv geçersiz"
        return 1
    fi
    binsha=$(file_hash sha256 "$bin") || { report "$srv" "çekirdek" "HATA" "özet hesaplanamadı"; return 1; }
    if ! place_file "$bin" "$dir/$dest" 0750; then
        report "$srv" "çekirdek" "HATA" "yerleştirilemedi"
        return 1
    fi
    write_meta "$meta" "picolimbo $version $tarsha $binsha" || log_warn "$srv: $meta güncellenemedi"
    if [[ $dest == pico_limbo.new ]]; then
        log_ok "$srv: PicoLimbo $version hazır → pico_limbo.new (sonraki başlatmada geçerli)"
    else
        log_ok "$srv: PicoLimbo $version → pico_limbo"
    fi
    report "$srv" "çekirdek" "indirildi" "PicoLimbo $version → $dest"
}

# --- Eklentiler -------------------------------------------------------------
# local_path <yol> — gerçek yolu yazar; $MC_ROOT/artifacts/ altında düzenli dosya olmalı
local_path() {
    local p=$1 base real
    base=$(readlink -f -- "$MC_ROOT/artifacts" 2>/dev/null) || base=""
    real=$(readlink -f -- "$p" 2>/dev/null) || real=""
    if [[ -z $base || -z $real || $real != "$base"/* ]]; then
        log_error "local: '$p' $MC_ROOT/artifacts/ altında değil."
        return 1
    fi
    if [[ ! -f $real ]]; then
        log_error "local: dosya yok: $p (LibreLogin için önce: sudo mc build-librelogin)."
        return 1
    fi
    printf '%s\n' "$real"
}

# resolve_plugin <kaynak> <kimlik> <sunucu-türü>
# Sonuç (global): P_URL, P_ALGO (sha256|sha512|boş), P_HASH, P_VER
resolve_plugin() {
    local source=$1 id=$2 type=$3 row proj plat ver build hash query platform repo asset path side f
    P_URL="" P_ALGO="" P_HASH="" P_VER=""
    case $source in
        geysermc)
            proj=${id%%/*} plat=${id#*/}
            api_get "$GEYSER_API/projects/$proj/versions/latest/builds/latest" || return 1
            row=$(jq_geyser_pick "$plat" <"$API_FILE") || return 1
            IFS=$SEP read -r ver build _ hash <<<"$row"
            # "latest" yerine çözülmüş sürüm/build: meta ile indirme arasında yeni build çıkarsa hash tutarlı kalır
            P_URL="$GEYSER_API/projects/$proj/versions/$(urlencode "$ver")/builds/$build/downloads/$plat"
            P_ALGO=sha256 P_HASH=$hash P_VER="$ver #$build"
            ;;
        luckperms)
            api_get "$LUCKPERMS_META" || return 1
            row=$(jq_luckperms_pick "$id" <"$API_FILE") || return 1
            IFS=$SEP read -r P_VER P_URL <<<"$row"
            ;;
        modrinth)
            if [[ $type == velocity ]]; then
                query=$(modrinth_query velocity "")
            else
                query=$(modrinth_query paper "${PAPER_MC_VERSION:-}")
            fi
            api_get "$MODRINTH_API/project/$id/version?$query" || return 1
            row=$(jq_modrinth_pick <"$API_FILE") || return 1
            IFS=$SEP read -r P_VER _ P_URL hash <<<"$row"
            if [[ -n $hash ]]; then P_ALGO=sha512 P_HASH=$hash; fi
            ;;
        hangar)
            if [[ $type == velocity ]]; then platform=VELOCITY; else platform=PAPER; fi
            api_get "$HANGAR_API/projects/$id/latestrelease" || return 1
            ver=$(hangar_version_name <"$API_FILE") || return 1
            api_get "$HANGAR_API/projects/$id/versions/$(urlencode "$ver")" || return 1
            row=$(jq_hangar_pick "$platform" <"$API_FILE") || return 1
            IFS=$SEP read -r _ P_URL hash <<<"$row"
            P_VER=$ver
            if [[ -n $hash ]]; then P_ALGO=sha256 P_HASH=$hash; fi
            ;;
        github)
            repo=${id%%:*} asset=${id#*:}
            api_get "$GITHUB_API/repos/$repo/releases/latest" "${GH_HDR[@]}" || return 1
            row=$(jq_github_pick "$asset" <"$API_FILE") || return 1
            IFS=$SEP read -r P_VER _ P_URL hash <<<"$row"
            if [[ -n $hash ]]; then P_ALGO=sha256 P_HASH=$hash; fi
            ;;
        url)
            P_URL=$id P_VER="(sabit URL)"
            ;;
        local)
            ver=$(local_expand "$id")
            path=$(local_path "$ver") || return 1
            P_ALGO=sha256
            P_HASH=$(file_hash sha256 "$path") || return 1
            # Derleme betiği yanına <jar>.sha256 yazdıysa onunla da karşılaştır (bozulma/yanlış dosya)
            for f in "$ver.sha256" "$path.sha256"; do
                [[ -f $f ]] || continue
                side=$(awk 'NR == 1 { print tolower($1) }' "$f")
                if [[ $side != "$P_HASH" ]]; then
                    log_error "local: $path özeti $f ile uyuşmuyor."
                    return 1
                fi
            done
            P_URL="local:$path" P_VER="yerel ${path##*/}"
            return 0
            ;;
        *)
            log_error "Bilinmeyen kaynak: $source"
            return 1
            ;;
    esac
    if [[ ! $P_URL =~ ^https:// ]]; then
        log_error "Güvensiz ya da boş indirme adresi: '$P_URL'"
        return 1
    fi
}

# .plugins.meta: her eklenti için "ad<TAB>url<TAB>sha256" (hash vermeyen kaynaklarda güncellik denetimi)
meta_get() { # <meta-dosyası> <ad> → "url<TAB>sha256"
    local content
    content=$(mc_read "$1") || return 1
    awk -F'\t' -v n="$2" '$1 == n { print $2 "\t" $3; found = 1 } END { exit !found }' <<<"$content"
}

meta_set() { # <meta-dosyası> <ad> <url> <sha256>
    local tmp old
    tmp=$(mktemp "$WORK_DIR/meta.XXXXXX") || return 1
    old=$(mc_read "$1") || old=""
    {
        [[ -z $old ]] || awk -F'\t' -v n="$2" 'NF && $1 != n' <<<"$old"
        printf '%s\t%s\t%s\n' "$2" "$3" "$4"
    } >"$tmp" || return 1
    place_file "$tmp" "$1" 0640
}

# plugin_matches <dosya> <ad> <meta> <pin> — sunucudaki dosya çözülen sürümle aynı mı?
plugin_matches() {
    local f=$1 name=$2 meta=$3 pin=$4 rec
    [[ -f $f && ! -L $f ]] || return 1
    if [[ -n $pin ]] && ! mc_hash_is sha256 "$pin" "$f"; then return 1; fi
    if [[ -n $P_HASH ]]; then
        mc_hash_is "$P_ALGO" "$P_HASH" "$f"
        return
    fi
    [[ -n $pin ]] && return 0
    # Kaynak hash vermiyor: aynı URL'den indirilmiş ve dosya o günden beri değişmemiş olmalı
    rec=$(meta_get "$meta" "$name") || return 1
    [[ ${rec%%$'\t'*} == "$P_URL" ]] && mc_hash_is sha256 "${rec#*$'\t'}" "$f"
}

# download_plugins <sunucu>
download_plugins() {
    local srv=$1 type dir meta live staged dest destdir name source id pin line rc=0 entries=0
    local -A seen=()
    local -a list=()
    type=$(server_get "$srv" TYPE)
    if ! is_java_type "$type"; then
        log_info "$srv: TYPE=$type Java sunucusu değil; eklenti adımı atlandı."
        return 0
    fi
    check_server_dir "$srv" "eklentiler" || return 1
    dir=$SERVERS_DIR/$srv
    meta=$dir/.plugins.meta
    if server_started_before "$srv"; then destdir=$dir/plugins/update; else destdir=$dir/plugins; fi
    mapfile -t list < <(plugins_for "$srv" "$type")

    for line in "${list[@]}"; do
        [[ -n $line ]] || continue
        IFS=$SEP read -r name source id pin _ <<<"$line"
        entries=$((entries + 1))
        if [[ -n ${seen[$name]:-} ]]; then
            log_error "$srv: '$name' plugins.list'te bu sunucu için birden çok kez tanımlı — ikincisi atlandı."
            report "$srv" "$name" "HATA" "çift tanım"
            rc=1
            continue
        fi
        seen[$name]=1

        if ! resolve_plugin "$source" "$id" "$type"; then
            log_error "$srv: $name ($source $id) çözülemedi."
            report "$srv" "$name" "HATA" "$source: sürüm bulunamadı"
            rc=1
            continue
        fi
        if [[ $source == url ]]; then P_ALGO=sha256 P_HASH=$pin; fi
        if [[ -n $pin && $P_ALGO == sha256 && $P_HASH != "$pin" ]]; then
            log_error "$srv: $name için sabitlenen sha256, kaynağın bildirdiğiyle uyuşmuyor (yeni sürüm çıkmış olabilir: $P_VER)."
            report "$srv" "$name" "HATA" "sabit sha256 uyuşmuyor"
            rc=1
            continue
        fi

        live=$dir/plugins/$name.jar
        staged=$dir/plugins/update/$name.jar
        if plugin_matches "$staged" "$name" "$meta" "$pin"; then
            report "$srv" "$name" "güncel" "$P_VER (güncelleme başlatmayı bekliyor)"
            continue
        fi
        # Bekleyen ama artık eskimiş bir güncelleme, başlatmada doğru dosyanın üzerine yazmasın.
        if plugin_matches "$live" "$name" "$meta" "$pin"; then
            if [[ -e $staged || -L $staged ]] && ((DRY_RUN == 0)); then mc_rm "$staged"; fi
            report "$srv" "$name" "güncel" "$P_VER"
            continue
        fi
        if [[ (-e $staged || -L $staged) && $destdir == "$dir/plugins" ]] && ((DRY_RUN == 0)); then mc_rm "$staged"; fi

        dest=$destdir/$name.jar
        if ((DRY_RUN)); then
            log_info "[kuru] $srv: $name $P_VER ← $P_URL → $dest"
            report "$srv" "$name" "indirilecek" "$P_VER → ${dest#"$dir"/}"
            continue
        fi

        if [[ ! -d $SERVERS_DIR ]]; then
            log_error "$SERVERS_DIR yok — önce scripts/install.sh çalıştırın."
            report "$srv" "$name" "HATA" "sunucular dizini yok"
            rc=1
            continue
        fi
        if ! { ensure_dir "$dir" && ensure_dir "$dir/plugins" && ensure_dir "$destdir"; }; then
            report "$srv" "$name" "HATA" "dizin oluşturulamadı"
            rc=1
            continue
        fi
        log_info "$srv: $name $P_VER indiriliyor..."
        if ! fetch_payload "$P_URL"; then
            log_error "$srv: $name indirilemedi: $P_URL"
            report "$srv" "$name" "HATA" "indirme başarısız"
            rc=1
            continue
        fi
        if [[ -n $P_HASH ]] && ! hash_is "$P_ALGO" "$P_HASH" "$PAYLOAD"; then
            drop_payload "$P_URL"
            log_error "$srv: $name ${P_ALGO^^} uyuşmuyor — dosya atıldı."
            report "$srv" "$name" "HATA" "${P_ALGO^^} uyuşmuyor"
            rc=1
            continue
        fi
        if [[ -n $pin ]] && ! hash_is sha256 "$pin" "$PAYLOAD"; then
            drop_payload "$P_URL"
            log_error "$srv: $name sabitlenen SHA-256 ile uyuşmuyor — dosya atıldı."
            report "$srv" "$name" "HATA" "SHA-256 uyuşmuyor"
            rc=1
            continue
        fi
        if [[ -z $P_HASH && -z $pin ]]; then
            log_warn "$srv: $name için kaynak hash vermiyor; yalnızca HTTPS'e güveniliyor (5. sütuna sha256 yazarak sabitleyebilirsiniz)."
        fi
        if ! looks_like_jar "$PAYLOAD"; then
            log_error "$srv: $name indirilen dosya jar değil."
            report "$srv" "$name" "HATA" "jar değil"
            rc=1
            continue
        fi
        if ! place_file "$PAYLOAD" "$dest" 0640; then
            report "$srv" "$name" "HATA" "yerleştirilemedi"
            rc=1
            continue
        fi
        meta_set "$meta" "$name" "$P_URL" "$(file_hash sha256 "$PAYLOAD")" || log_warn "$srv: $meta güncellenemedi"
        warn_duplicate_jars "$dir/plugins" "$name"
        log_ok "$srv: $name $P_VER → ${dest#"$dir"/}"
        report "$srv" "$name" "indirildi" "$P_VER → ${dest#"$dir"/}"
    done

    if ((entries == 0)); then
        log_info "$srv: plugins.list'te bu sunucuya eklenti yok."
    fi
    return "$rc"
}

# Elle konmuş, aynı eklentinin farklı adlı bir kopyası varsa uyarır (sunucu çift eklentide açılmaz).
warn_duplicate_jars() {
    local pdir=$1 name=$2 f base
    for f in "$pdir"/*.jar; do
        [[ -f $f ]] || continue
        base=${f##*/}
        [[ $base == "$name.jar" ]] && continue
        if [[ ${base,,} == "${name,,}"[-_.]* ]]; then
            log_warn "$pdir/$base, $name.jar ile aynı eklenti olabilir — çift eklentiyi elle kaldırın."
        fi
    done
}

# GITHUB_TOKEN varsa yetki başlığı 0600 dosyaya yazılır ve curl'e "-H @dosya" ile verilir
# (komut satırına girmez: /proc/*/cmdline'dan okunamaz).
setup_github_auth() {
    local f
    [[ -n ${GITHUB_TOKEN:-} ]] || return 0
    f=$(umask 077 && mktemp "$WORK_DIR/gh-auth.XXXXXX") || return 1
    printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" >"$f"
    GH_HDR+=(-H "@$f")
}

# --- Ana akış ---------------------------------------------------------------
main() {
    local mode=all target=all arg targets_out s lockfd
    local -a pos=() targets=()
    for arg in "$@"; do
        case $arg in
            --dry-run | -n) DRY_RUN=1 ;;
            -h | --help | help)
                usage
                return 0
                ;;
            -*) die "Bilinmeyen seçenek: $arg (yardım: mc download --help)" ;;
            *) pos+=("$arg") ;;
        esac
    done
    case ${pos[0]:-all} in
        all | core | plugins)
            mode=${pos[0]:-all}
            target=${pos[1]:-all}
            ((${#pos[@]} <= 2)) || die "Fazla argüman: ${pos[*]}"
            ;;
        *)
            target=${pos[0]}
            ((${#pos[@]} <= 1)) || die "Fazla argüman: ${pos[*]} (sıra: [all|core|plugins] [sunucu])"
            ;;
    esac

    load_network_env
    [[ -n ${DOWNLOAD_USER_AGENT:-} ]] ||
        die "network.env: DOWNLOAD_USER_AGENT tanımsız (PaperMC tanımlayıcı User-Agent zorunlu tutar)."
    require_cmd curl jq sha256sum sha512sum tar od
    # Root iken sunucu dizinlerindeki okuma/yazma minecraft kimliğiyle yapılır (as_mc).
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then require_mc_user; fi
    targets_out=$(resolve_targets "$target")
    mapfile -t targets <<<"$targets_out"

    WORK_DIR=$(mktemp -d)
    TMP_PATHS+=("$WORK_DIR")
    trap cleanup EXIT
    setup_github_auth || die "Geçici dosya oluşturulamadı."

    if ((DRY_RUN)); then
        log_info "Kuru çalıştırma: hiçbir dosya indirilmeyecek ya da yazılmayacak."
    elif [[ -d $MC_ROOT ]]; then
        exec {lockfd}>"$MC_ROOT/.download.lock"
        flock -n "$lockfd" || die "Başka bir indirme sürüyor ($MC_ROOT/.download.lock)."
    fi

    if [[ $mode == all || $mode == core ]]; then
        for s in "${targets[@]}"; do
            download_core "$s" || FAILS=$((FAILS + 1))
        done
    fi
    if [[ $mode == all || $mode == plugins ]]; then
        if ! load_plugins_list "$(plugins_list_file)"; then
            FAILS=$((FAILS + PL_ERRORS))
            report "-" "plugins.list" "HATA" "$PL_ERRORS geçersiz satır atlandı"
        fi
        check_plugin_servers
        for s in "${targets[@]}"; do
            download_plugins "$s" || FAILS=$((FAILS + 1))
        done
    fi

    print_report
    if ((FAILS > 0)); then
        log_error "İndirme $FAILS hatayla bitti (yukarıdaki özet)."
        return 1
    fi
    if ((DRY_RUN == 0)); then
        log_ok "İndirme tamam. Çalışan sunucularda yeni sürümler yeniden başlatınca geçerli olur."
    fi
}

# Testler bu dosyayı "source" edip seçici fonksiyonları doğrudan çağırabilir.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
