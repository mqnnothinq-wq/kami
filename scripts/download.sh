#!/usr/bin/env bash
# Paper/Velocity sunucu jar'larını (PaperMC Fill v3) ve config/plugins.list'teki eklentileri indirir.
#
# Kullanım: download.sh [--dry-run] [all|core|plugins] [sunucu|all]
#
# Çalışan sunucunun dosyalarına dokunulmaz: yeni jar'lar bir sonraki başlatmada devreye girer
# (mc@.service ExecStartPre: server.jar.new -> server.jar, plugins/update/*.jar -> plugins/).
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

# jq satır çıktılarında alan ayırıcı (boş alanlar korunur; sekme gibi birleşmez)
SEP=$'\x1f'

DRY_RUN=0
FAILS=0
WORK_DIR=""
API_FILE=""
CORE_ROW=""
P_URL="" P_ALGO="" P_HASH="" P_VER=""
declare -a TMP_PATHS=() REPORT=()
declare -a PL_LINE=() PL_SERVERS=() PL_NAME=() PL_SOURCE=() PL_ID=() PL_SHA=()
declare -A HTTP_CACHE=() CORE_CACHE=()

usage() {
    cat <<'EOF'
Kullanım: mc download [--dry-run] [all|core|plugins] [sunucu|all]

  core      Paper/Velocity jar'ı (PaperMC Fill v3, SHA-256 doğrulamalı)
              -> servers/<srv>/server.jar  (zaten varsa server.jar.new; sonraki başlatmada geçer)
  plugins   config/plugins.list'teki eklentiler (hash varsa doğrulanır)
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

# --- Ağ ---------------------------------------------------------------------
CURL_OPTS=(-fsSL --retry 3 --connect-timeout 15 --proto "=https" --proto-redir "=https")

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

# GitHub /repos/<sahip>/<depo>/releases/latest. $1 = dosya adı (ya da "*" içeren kalıp).
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
# sunucular: virgüllü ad listesi, "backends" (tüm paper) ya da "all".

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
        *)
            log_error "$ctx: bilinmeyen kaynak '$source' (geysermc luckperms modrinth hangar github url)"
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
    local -a words fields
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

# plugins_for <sunucu> <tür> — o sunucuya düşen girdiler: ad SEP kaynak SEP kimlik SEP sha256 SEP satır
plugins_for() {
    local srv=$1 type=$2 i tok match
    local -a toks
    for i in "${!PL_NAME[@]}"; do
        match=0
        IFS=, read -r -a toks <<<"${PL_SERVERS[$i]}"
        for tok in "${toks[@]}"; do
            if [[ $tok == all || $tok == "$srv" ]]; then
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
    local -a toks
    for i in "${!PL_NAME[@]}"; do
        IFS=, read -r -a toks <<<"${PL_SERVERS[$i]}"
        for tok in "${toks[@]}"; do
            [[ $tok == all || $tok == backends ]] && continue
            server_exists "$tok" || log_warn "plugins.list:${PL_LINE[$i]}: tanımsız sunucu '$tok' (${PL_NAME[$i]})"
        done
    done
}

# --- Dosya yardımcıları -----------------------------------------------------
file_hash() { # <sha256|sha512> <dosya>
    local out
    out=$("${1}sum" -- "$2") || return 1
    printf '%s' "${out%% *}"
}

hash_is() { # <sha256|sha512> <beklenen> <dosya>
    local want=${2,,} got
    [[ -n $want && -f $3 ]] || return 1
    got=$(file_hash "$1" "$3") || return 1
    [[ $got == "$want" ]]
}

looks_like_jar() { [[ -s $1 && $(head -c 2 -- "$1") == PK ]]; }

fix_owner() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]] && id -u "$MC_USER" >/dev/null 2>&1; then
        chown "$MC_USER:$MC_USER" -- "$@"
    fi
}

ensure_dir() { # <dizin> — yoksa 0750, minecraft sahipli oluşturur (üst dizin var olmalı)
    [[ -d $1 ]] && return 0
    mkdir -- "$1" && chmod 0750 -- "$1" && fix_owner "$1"
}

server_running() {
    [[ ${MC_NO_SYSTEMD:-0} == 1 ]] && return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    is_running "$1"
}

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

# download_core <sunucu>
# Not: '||' ile çağrıldığı için set -e burada etkisizdir; her adım açıkça denetlenir.
download_core() {
    local srv=$1 type project version build name url sha dir meta want dest tmp
    type=$(server_get "$srv" TYPE)
    case $type in
        paper | velocity) project=$type ;;
        *)
            log_error "$srv: bilinmeyen TYPE '$type'"
            report "$srv" "çekirdek" "HATA" "TYPE geçersiz"
            return 1
            ;;
    esac
    if ! resolve_core "$project"; then
        report "$srv" "çekirdek" "HATA" "$project sürüm/build çözülemedi"
        return 1
    fi
    IFS=$SEP read -r version build name url sha <<<"$CORE_ROW"
    dir=$SERVERS_DIR/$srv
    meta=$dir/.server.jar.meta
    want="$project $version $build $sha"

    # Aynı build zaten kurulu ya da başlatmayı bekliyorsa atla (meta + SHA-256 ile doğrulanır).
    if hash_is sha256 "$sha" "$dir/server.jar.new" || hash_is sha256 "$sha" "$dir/server.jar"; then
        if ((DRY_RUN == 0)); then
            if [[ -f $dir/server.jar.new ]] && ! hash_is sha256 "$sha" "$dir/server.jar.new"; then
                rm -f -- "$dir/server.jar.new" # kurulu olanla aynı sürüme dönülüyor: eski bekleyen güncellemeyi at
            fi
            if [[ ! -f $meta || "$(<"$meta")" != "$want" ]]; then
                printf '%s\n' "$want" >"$meta" && chmod 0640 -- "$meta" && fix_owner "$meta"
            fi
        fi
        report "$srv" "çekirdek" "güncel" "$project $version #$build"
        return 0
    fi

    if [[ -e $dir/server.jar ]]; then dest=server.jar.new; else dest=server.jar; fi
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
    tmp=$(mktemp "$dir/.server.jar.XXXXXX") || { report "$srv" "çekirdek" "HATA" "geçici dosya"; return 1; }
    TMP_PATHS+=("$tmp")
    log_info "$srv: $project $version #$build indiriliyor..."
    if ! http_fetch "$url" "$tmp"; then
        log_error "$srv: indirme başarısız: $url"
        report "$srv" "çekirdek" "HATA" "indirme başarısız"
        return 1
    fi
    if ! hash_is sha256 "$sha" "$tmp"; then
        log_error "$srv: SHA-256 uyuşmuyor ($name) — dosya atıldı."
        report "$srv" "çekirdek" "HATA" "SHA-256 uyuşmuyor"
        return 1
    fi
    if ! looks_like_jar "$tmp"; then
        log_error "$srv: indirilen dosya jar değil ($name)."
        report "$srv" "çekirdek" "HATA" "jar değil"
        return 1
    fi
    if ! { chmod 0640 -- "$tmp" && fix_owner "$tmp" && mv -f -- "$tmp" "$dir/$dest"; }; then
        report "$srv" "çekirdek" "HATA" "yerleştirilemedi"
        return 1
    fi
    printf '%s\n' "$want" >"$meta" && chmod 0640 -- "$meta" && fix_owner "$meta"
    if [[ $dest == server.jar.new ]]; then
        log_ok "$srv: $project $version #$build hazır → server.jar.new (sonraki başlatmada geçerli)"
    else
        log_ok "$srv: $project $version #$build → server.jar"
    fi
    report "$srv" "çekirdek" "indirildi" "$project $version #$build → $dest"
}

# --- Eklentiler -------------------------------------------------------------
# resolve_plugin <kaynak> <kimlik> <sunucu-türü>
# Sonuç (global): P_URL, P_ALGO (sha256|sha512|boş), P_HASH, P_VER
resolve_plugin() {
    local source=$1 id=$2 type=$3 row proj plat ver build hash query platform repo asset
    local -a hdr
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
            hdr=(-H 'Accept: application/vnd.github+json')
            if [[ -n ${GITHUB_TOKEN:-} ]]; then hdr+=(-H "Authorization: Bearer $GITHUB_TOKEN"); fi
            api_get "$GITHUB_API/repos/$repo/releases/latest" "${hdr[@]}" || return 1
            row=$(jq_github_pick "$asset" <"$API_FILE") || return 1
            IFS=$SEP read -r P_VER _ P_URL hash <<<"$row"
            if [[ -n $hash ]]; then P_ALGO=sha256 P_HASH=$hash; fi
            ;;
        url)
            P_URL=$id P_VER="(sabit URL)"
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
    [[ -f $1 ]] || return 1
    awk -F'\t' -v n="$2" '$1 == n { print $2 "\t" $3; found = 1 } END { exit !found }' "$1"
}

meta_set() { # <meta-dosyası> <ad> <url> <sha256>
    local tmp
    tmp=$(mktemp "$1.XXXXXX") || return 1
    { [[ -f $1 ]] && awk -F'\t' -v n="$2" '$1 != n' "$1"; printf '%s\t%s\t%s\n' "$2" "$3" "$4"; } >"$tmp" &&
        chmod 0640 -- "$tmp" && fix_owner "$tmp" && mv -f -- "$tmp" "$1"
}

# plugin_matches <dosya> <ad> <meta> <pin> — dosya çözülen sürümle aynı mı?
plugin_matches() {
    local f=$1 name=$2 meta=$3 pin=$4 rec
    [[ -f $f ]] || return 1
    if [[ -n $pin ]] && ! hash_is sha256 "$pin" "$f"; then return 1; fi
    if [[ -n $P_HASH ]]; then
        hash_is "$P_ALGO" "$P_HASH" "$f"
        return
    fi
    [[ -n $pin ]] && return 0
    # Kaynak hash vermiyor: aynı URL'den indirilmiş ve dosya o günden beri değişmemiş olmalı
    rec=$(meta_get "$meta" "$name") || return 1
    [[ ${rec%%$'\t'*} == "$P_URL" ]] && hash_is sha256 "${rec#*$'\t'}" "$f"
}

# download_plugins <sunucu>
download_plugins() {
    local srv=$1 type dir meta live staged dest destdir name source id pin line tmp rc=0 entries=0
    local -A seen=()
    local -a list
    type=$(server_get "$srv" TYPE)
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
        if [[ -f $staged ]] && plugin_matches "$staged" "$name" "$meta" "$pin"; then
            report "$srv" "$name" "güncel" "$P_VER (güncelleme başlatmayı bekliyor)"
            continue
        fi
        # Bekleyen ama artık eskimiş bir güncelleme, başlatmada doğru dosyanın üzerine yazmasın.
        if plugin_matches "$live" "$name" "$meta" "$pin"; then
            if [[ -f $staged ]] && ((DRY_RUN == 0)); then rm -f -- "$staged"; fi
            report "$srv" "$name" "güncel" "$P_VER"
            continue
        fi
        if [[ -f $staged && $destdir == "$dir/plugins" ]] && ((DRY_RUN == 0)); then rm -f -- "$staged"; fi

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
        tmp=$(mktemp "$dir/plugins/.$name.XXXXXX") || { rc=1; continue; }
        TMP_PATHS+=("$tmp")
        log_info "$srv: $name $P_VER indiriliyor..."
        if ! http_fetch "$P_URL" "$tmp"; then
            log_error "$srv: $name indirilemedi: $P_URL"
            report "$srv" "$name" "HATA" "indirme başarısız"
            rc=1
            continue
        fi
        if [[ -n $P_HASH ]] && ! hash_is "$P_ALGO" "$P_HASH" "$tmp"; then
            log_error "$srv: $name ${P_ALGO^^} uyuşmuyor — dosya atıldı."
            report "$srv" "$name" "HATA" "${P_ALGO^^} uyuşmuyor"
            rc=1
            continue
        fi
        if [[ -n $pin ]] && ! hash_is sha256 "$pin" "$tmp"; then
            log_error "$srv: $name sabitlenen SHA-256 ile uyuşmuyor — dosya atıldı."
            report "$srv" "$name" "HATA" "SHA-256 uyuşmuyor"
            rc=1
            continue
        fi
        if [[ -z $P_HASH && -z $pin ]]; then
            log_warn "$srv: $name için kaynak hash vermiyor; yalnızca HTTPS'e güveniliyor (5. sütuna sha256 yazarak sabitleyebilirsiniz)."
        fi
        if ! looks_like_jar "$tmp"; then
            log_error "$srv: $name indirilen dosya jar değil."
            report "$srv" "$name" "HATA" "jar değil"
            rc=1
            continue
        fi
        if ! { chmod 0640 -- "$tmp" && fix_owner "$tmp" && mv -f -- "$tmp" "$dest"; }; then
            report "$srv" "$name" "HATA" "yerleştirilemedi"
            rc=1
            continue
        fi
        meta_set "$meta" "$name" "$P_URL" "$(file_hash sha256 "$dest")" || log_warn "$srv: $meta güncellenemedi"
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
    require_cmd curl jq sha256sum sha512sum
    targets_out=$(resolve_targets "$target")
    mapfile -t targets <<<"$targets_out"

    WORK_DIR=$(mktemp -d)
    TMP_PATHS+=("$WORK_DIR")
    trap cleanup EXIT

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
        if ! load_plugins_list "${PLUGINS_LIST:-$CONFIG_DIR/plugins.list}"; then
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
