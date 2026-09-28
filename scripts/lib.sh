# shellcheck shell=bash
# shellcheck disable=SC2034  # yol değişkenleri bu dosyayı kullanan betikler içindir
# Ortak yardımcılar. Tüm betikler bu dosyayı "source" eder:
#   . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"
#
# Bu dosya kendi başına çalıştırılmaz; seçenek (set -e vb.) değiştirmez,
# onu çağıran betik yapar.
#
# İçindekiler (ayrıntı her fonksiyonun üstünde):
#   Günlük/hata  : log_info log_ok log_warn log_error die require_root require_cmd
#   Yapılandırma : load_network_env load_secrets render_placeholders
#   Sunucular    : list_servers list_backends list_proxies list_nonproxy server_exists server_get
#                  validate_server_name resolve_targets
#   systemd      : unit_of is_running server_running
#   Yetki ayrımı : as_user as_mc require_mc_user ensure_build_user
#   Eklentiler   : plugins_list_file plugin_local_ids local_expand librelogin_jar
#   Kilit        : backup_lock
#   Bellek       : heap_to_mib fmt_mib
# Bir yardımcı birden çok betikte gerekiyorsa buraya taşıyın; betiklerde kopyası olmasın.

# --- Yollar ---------------------------------------------------------------
# Depo kökü: bu dosyanın bir üst dizini (scripts/..).
REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CONFIG_DIR="$REPO_DIR/config"
SCRIPTS_DIR="$REPO_DIR/scripts"

# Çalışma zamanı yolları. Testlerde ortam değişkeniyle değiştirilebilir;
# gerçek kurulumda varsayılanlar kullanılır (systemd birimleri bu yolları sabit bekler).
MC_ROOT="${MC_ROOT:-/opt/minecraft}"
SERVERS_DIR="$MC_ROOT/servers"
MC_ETC="${MC_ETC:-/etc/minecraft}"
SECRETS_FILE="$MC_ETC/secrets.env"
BACKUP_ENV_FILE="$MC_ETC/backup.env"
MC_USER="${MC_USER:-minecraft}"
MC_RUN_DIR="${MC_RUN_DIR:-/run/minecraft}"
# LibreLogin'i derleyen ayrı sistem kullanıcısı (scripts/build-librelogin.sh; install.sh oluşturur).
# Ek grubu, evi ve kabuğu yok; asla root ya da $MC_USER olamaz. 'nobody' gibi paylaşılan bir kimlik
# KULLANILMAZ: aynı kimlikle çalışan başka bir süreç derleme çıktısını değiştirebilir, derlemenin
# ardından o kullanıcının tüm süreçleri öldürülür.
LIBRELOGIN_BUILD_USER="${LIBRELOGIN_BUILD_USER:-kami-build}"

# --- Günlük / hata --------------------------------------------------------
if [[ -t 2 ]]; then
    _C_RED=$'\e[31m' _C_YEL=$'\e[33m' _C_GRN=$'\e[32m' _C_BLU=$'\e[34m' _C_OFF=$'\e[0m'
else
    _C_RED='' _C_YEL='' _C_GRN='' _C_BLU='' _C_OFF=''
fi

log_info()  { printf '%s[bilgi]%s %s\n' "$_C_BLU" "$_C_OFF" "$*" >&2; }
log_ok()    { printf '%s[tamam]%s %s\n' "$_C_GRN" "$_C_OFF" "$*" >&2; }
log_warn()  { printf '%s[uyarı]%s %s\n' "$_C_YEL" "$_C_OFF" "$*" >&2; }
log_error() { printf '%s[hata]%s %s\n'  "$_C_RED" "$_C_OFF" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Bu komut root olarak çalıştırılmalı (sudo ile deneyin)."
}

require_cmd() {
    local c missing=()
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    ((${#missing[@]} == 0)) || die "Eksik komut(lar): ${missing[*]} — önce scripts/install.sh çalıştırın."
}

# --- Yapılandırma ---------------------------------------------------------
# config/network.env dosyasını yükler (genel ayarlar: sürümler, portlar...).
load_network_env() {
    local f="$CONFIG_DIR/network.env"
    [[ -f $f ]] || die "Bulunamadı: $f"
    # shellcheck disable=SC1090,SC1091
    . "$f"
}

# Tanımlı sunucuları listeler (config/servers/<ad>/server.env olanlar).
# Sıra: önce proxy (TYPE=velocity), sonra backend'ler alfabetik.
list_servers() {
    local d name type proxies=() backends=()
    for d in "$CONFIG_DIR"/servers/*/; do
        [[ -f $d/server.env ]] || continue
        name="$(basename "$d")"
        type="$(server_get "$name" TYPE)"
        if [[ $type == velocity ]]; then proxies+=("$name"); else backends+=("$name"); fi
    done
    printf '%s\n' "${proxies[@]}" "${backends[@]}" | sed '/^$/d'
}

# Yalnızca backend (Paper) sunucuları.
list_backends() {
    local s
    while read -r s; do
        [[ $(server_get "$s" TYPE) == paper ]] && printf '%s\n' "$s"
    done < <(list_servers)
}

# Yalnızca proxy (TYPE=velocity) sunucuları.
list_proxies() {
    local s
    while IFS= read -r s; do
        if [[ -n $s && $(server_get "$s" TYPE) == velocity ]]; then printf '%s\n' "$s"; fi
    done < <(list_servers)
}

# Proxy dışındaki tüm sunucular (paper + limbo), alfabetik. list_backends yalnız paper döndürür;
# başlatma/durdurma sırası ve velocity'nin kapanış sırası (10-order.conf) bunu kullanır.
list_nonproxy() {
    local s
    while IFS= read -r s; do
        if [[ -n $s && $(server_get "$s" TYPE) != velocity ]]; then printf '%s\n' "$s"; fi
    done < <(list_servers)
}

server_exists() { [[ -f "$CONFIG_DIR/servers/$1/server.env" ]]; }

# server_get <sunucu> <DEĞİŞKEN> — server.env içindeki değeri yazdırır
# (alt kabukta yüklenir, çağıranın ortamını kirletmez).
server_get() {
    local name=$1 var=$2 f="$CONFIG_DIR/servers/$1/server.env"
    [[ -f $f ]] || die "Tanımsız sunucu: $name ($f yok)"
    (
        # shellcheck disable=SC1090
        . "$f"
        printf '%s' "${!var-}"
    )
}

# Sunucu adı geçerli mi? "all" özel anlamlıdır.
validate_server_name() {
    [[ $1 =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "Geçersiz sunucu adı: '$1' (küçük harf, rakam, tire; 2-31 karakter)"
    [[ $1 != all ]] || die "'all' ayrılmış bir addır."
}

# "all" ya da tek sunucu adını listeye çevirir.
resolve_targets() {
    local arg=${1:-all}
    if [[ $arg == all ]]; then
        list_servers
    else
        server_exists "$arg" || die "Tanımsız sunucu: $arg (mevcut: $(list_servers | paste -sd' '))"
        printf '%s\n' "$arg"
    fi
}

# Gizli değerleri (/etc/minecraft/secrets.env) mevcut kabuğa yükler.
load_secrets() {
    [[ -r $SECRETS_FILE ]] || die "Okunamadı: $SECRETS_FILE — scripts/install.sh çalıştırıldı mı? (root gerekir)"
    # shellcheck disable=SC1090
    . "$SECRETS_FILE"
}

# --- Yer tutucu işleme ----------------------------------------------------
# render_placeholders <kaynak> <hedef> <sunucu>
# Kaynak dosyadaki @@DEĞİŞKEN@@ ifadelerini şu sırayla bulunan değerlerle
# değiştirir: server.env → secrets.env → network.env. SERVER_NAME her zaman
# sunucu adıdır. Tanımsız bir yer tutucu kalırsa hata verir (yarım dosya yazılmaz).
render_placeholders() {
    local src=$1 dst=$2 name=$3
    (
        set -a
        # shellcheck disable=SC1090,SC1091
        . "$CONFIG_DIR/network.env"
        # shellcheck disable=SC1090
        [[ -r $SECRETS_FILE ]] && . "$SECRETS_FILE"
        # shellcheck disable=SC1090
        . "$CONFIG_DIR/servers/$name/server.env"
        SERVER_NAME=$name
        set +a
        python3 - "$src" "$dst" <<'PY'
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
missing = set()
def sub(m):
    key = m.group(1)
    if key not in os.environ:
        missing.add(key)
        return m.group(0)
    return os.environ[key]
out = re.sub(r"@@([A-Z][A-Z0-9_]*)@@", sub, text)
if missing:
    sys.stderr.write("[hata] %s: tanımsız yer tutucu(lar): %s\n" % (src, ", ".join(sorted(missing))))
    sys.exit(3)
tmp = dst + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(out)
os.replace(tmp, dst)
PY
    )
}

# --- systemd --------------------------------------------------------------
unit_of() { printf 'mc@%s.service' "$1"; }

is_running() { systemctl is-active --quiet "$(unit_of "$1")"; }

# server_running <sunucu> — is_running gibi, ama systemd olmayan ortamda (MC_NO_SYSTEMD=1 ya da
# systemctl yok) "çalışmıyor" der; hata vermez.
server_running() {
    [[ ${MC_NO_SYSTEMD:-0} == 1 ]] && return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    is_running "$1"
}

# --- Yetki ayrımı ----------------------------------------------------------
# as_user <kullanıcı> <komut...> — root iken komutu verilen kullanıcının kimliğiyle (birincil grup
# + ek gruplar) ve "/" çalışma dizininde çalıştırır: setpriv, yoksa runuser. Root değilsek ya da
# kullanıcının kendisi root ise (uid 0; ör. testler) komut olduğu gibi çalışır. Kullanıcı yoksa
# root yetkisiyle çalıştırmak yerine hata verir (dönüş 1).
as_user() {
    local user=$1 uid gid
    shift
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        "$@"
        return
    fi
    if ! uid=$(id -u -- "$user" 2>/dev/null) || ! gid=$(id -g -- "$user" 2>/dev/null); then
        log_error "Kullanıcı yok: '$user' — önce scripts/install.sh çalıştırın."
        return 1
    fi
    if ((uid == 0)); then
        "$@"
        return
    fi
    if command -v setpriv >/dev/null 2>&1; then
        (cd / && exec setpriv --reuid="$uid" --regid="$gid" --init-groups -- "$@")
    else
        (cd / && exec runuser -u "$user" -- "$@")
    fi
}

# require_mc_user — root iken çağrılır: sunucu kullanıcısı ($MC_USER) var mı ve kimlik düşürme aracı
# (setpriv ya da runuser) kurulu mu denetler; yoksa çıkar. MC_GROUP'a birincil grubun adını yazar.
require_mc_user() {
    MC_GROUP=$(id -gn -- "$MC_USER" 2>/dev/null) ||
        die "Kullanıcı/grup yok: $MC_USER — önce scripts/install.sh çalıştırın."
    command -v setpriv >/dev/null 2>&1 || require_cmd runuser
}

# as_mc <komut...> — komutu sunucu dosyalarının sahibi ($MC_USER) olarak çalıştırır.
# Sunucu dizinleri minecraft'ça yazılabilir: orada çalışan (ya da ele geçirilmiş) bir sunucu
# sembolik bağ bırakabilir. Bu dizinlerdeki okuma/yazma/silme işlemleri bununla yapılır ki bağ
# izlense bile minecraft'ın zaten erişebildiğinden fazlasına ulaşılamasın.
as_mc() { as_user "$MC_USER" "$@"; }

# ensure_build_user [çalıştırıcı] — $LIBRELOGIN_BUILD_USER yoksa grupsuz (yalnız kendi birincil grubu),
# evsiz, oturum açamayan bir sistem kullanıcısı olarak oluşturur (root gerekir). Varsa dokunmaz.
# İsteğe bağlı çalıştırıcı komutların önüne eklenir (ör. install.sh'in 'run'ı: --dry-run'da yalnız
# yazdırır).
ensure_build_user() {
    local u=$LIBRELOGIN_BUILD_USER
    local -a r=()
    if [[ -n ${1:-} ]]; then r=("$1"); fi
    if id -u -- "$u" >/dev/null 2>&1; then return 0; fi
    getent group "$u" >/dev/null || "${r[@]}" groupadd --system "$u"
    "${r[@]}" useradd --system --gid "$u" --home-dir /nonexistent --no-create-home \
        --shell /usr/sbin/nologin --comment "kami LibreLogin derlemesi" "$u"
}

# --- Eklenti listesi -------------------------------------------------------
# plugins_list_file — config/plugins.list yolu (testlerde PLUGINS_LIST ile değiştirilebilir).
plugins_list_file() { printf '%s\n' "${PLUGINS_LIST:-$CONFIG_DIR/plugins.list}"; }

# plugin_local_ids <ad> — plugins.list'te <ad> eklentisinin "local" kaynaklı satırlarının kimliğini
# (açılmamış; ör. '$MC_ROOT/artifacts/LibreLogin-39397c4.jar') satır satır yazar. Liste yoksa boş.
plugin_local_ids() {
    local f
    f=$(plugins_list_file)
    [[ -f $f ]] || return 0
    awk -v n="$1" '$1 !~ /^#/ && $2 == n && $3 == "local" { print $4 }' "$f"
}

# local_expand <kimlik> — "local" kimliğinin başındaki '$MC_ROOT' / '${MC_ROOT}' önekini açar
# (başka genişletme yapılmaz).
local_expand() {
    # shellcheck disable=SC2016  # '$MC_ROOT' kimlikte birebir yazılır
    case $1 in
        '$MC_ROOT'/*) printf '%s\n' "$MC_ROOT/${1#'$MC_ROOT'/}" ;;
        '${MC_ROOT}'/*) printf '%s\n' "$MC_ROOT/${1#'${MC_ROOT}'/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# librelogin_jar <commit> — derlenen LibreLogin jar'ının adı: LibreLogin-<commit'in ilk 7 hanesi>.jar
# (küçük harf). network.env LIBRELOGIN_COMMIT ile plugins.list'teki LibreLogin satırı bu adla eşleşir.
librelogin_jar() {
    local c=${1,,}
    printf 'LibreLogin-%s.jar\n' "${c:0:7}"
}

# --- Kilit -----------------------------------------------------------------
# backup_lock <bekleme-sn> <hata-mesajı> — $MC_ROOT/.backup.lock kilidini alır; süreç bitene dek
# tutulur. Yedek, budama, geri yükleme ve countdown-restart bu kilidi paylaşır (yedek alınırken
# sunucular yeniden başlatılmaz, iki yedek üst üste binmez). $MC_ROOT yoksa (kurulum yok) atlanır.
backup_lock() {
    local fd
    [[ -d $MC_ROOT ]] || return 0
    require_cmd flock
    exec {fd}>>"$MC_ROOT/.backup.lock"
    flock -w "$1" "$fd" || die "$2"
}

# --- Bellek birimleri -------------------------------------------------------
# heap_to_mib <HEAP> — "1536M", "7G", "512K", "1073741824" → MiB (tamsayı). Geçersizse dönüş 1.
heap_to_mib() {
    local v=${1^^} n
    [[ $v =~ ^([0-9]+)([KMG]?)$ ]] || return 1
    n=${BASH_REMATCH[1]}
    case ${BASH_REMATCH[2]} in
        G) echo $((n * 1024)) ;;
        M) echo "$n" ;;
        K) echo $((n / 1024)) ;;
        *) echo $((n / 1048576)) ;;
    esac
}

# fmt_mib <MiB> — okunur biçim: "900 MiB", "9.5 GiB".
fmt_mib() {
    awk -v m="$1" 'BEGIN { if (m >= 1024) printf "%.1f GiB", m / 1024; else printf "%d MiB", m }'
}
