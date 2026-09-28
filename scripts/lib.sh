# shellcheck shell=bash
# shellcheck disable=SC2034  # yol değişkenleri bu dosyayı kullanan betikler içindir
# Ortak yardımcılar. Tüm betikler bu dosyayı "source" eder:
#   . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"
#
# Bu dosya kendi başına çalıştırılmaz; seçenek (set -e vb.) değiştirmez,
# onu çağıran betik yapar.

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
