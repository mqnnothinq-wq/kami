#!/usr/bin/env bash
# restic ile yedek alma, budama, listeleme ve geri yükleme.
#
# Kullanım (mc aracılığıyla):
#   backup.sh [all|<sunucu>]            yedek al (all: tüm sunucular + MariaDB dökümü + artifacts/)
#   backup.sh list [<sunucu>]           anlık görüntüleri listele
#   backup.sh prune                     BACKUP_KEEP_* ile eski yedekleri, LOG_RETENTION_DAYS ile eski günlükleri sil
#   backup.sh restore <sunucu> <id>     geri yükle ("EVET" onayı ister; sunucuyu durdurur)
#
# Depo ayarları: /etc/minecraft/backup.env (RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE, BACKUP_HOST, bulut kimlikleri).
set -Eeuo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

RESTIC="${RESTIC:-restic}"
RCON_RETRIES="${RCON_RETRIES:-5}"
RCON_RETRY_SLEEP="${RCON_RETRY_SLEEP:-15}"
DB_TAG="_mariadb"        # sunucu adları "_" ile başlayamaz: çakışmaz
ARTIFACTS_TAG="_artifacts" # $MC_ROOT/artifacts: yerelde derlenen eklentiler (LibreLogin)
# LibreLogin'in SQLite veritabanı (Velocity) ve yedek öncesi alınan tutarlı kopyası
LL_DB_REL="plugins/librelogin/user-data.db"
LL_SNAP_SUFFIX=".yedek"

declare -a SAVE_OFF=() # save-off verilmiş sunucular ("ad:port"); çıkışta save-on geri verilir

usage() {
    cat <<'EOF'
Kullanım:
  mc backup [sunucu|all]           yedek al (all: tüm sunucular + MariaDB dökümü + artifacts/)
  mc backup list [sunucu]          anlık görüntüleri (snapshot) listele
  mc backup prune                  eski yedekleri (BACKUP_KEEP_*) ve eski günlükleri (LOG_RETENTION_DAYS) sil
  mc restore <sunucu> <snapshot>   geri yükle: sunucu durdurulur, mevcut dizin
                                   <dizin>.onceki-<tarih> olarak saklanır ("EVET" onayı gerekir)

Çalışan Paper sunucularında yedek öncesi RCON ile "save-off" + "save-all flush" verilir,
yedek bitince (hata olsa bile) "save-on" geri verilir.
Velocity'de LibreLogin veritabanının (plugins/librelogin/user-data.db) tutarlı kopyası
user-data.db.yedek olarak alınıp yedeğe girer; mc restore bu kopyayı user-data.db yapar.
Elle (restic restore ile) geri yüklüyorsanız aynısını yapın ve user-data.db-wal/-shm'yi silin.
limbo (PicoLimbo) yalnızca ayar dosyaları için yedeklenir; ikili yedekte yoktur (mc download core limbo).

Veritabanını geri yüklemek (elle):
  set -a; . /etc/minecraft/backup.env; set +a
  restic snapshots --tag _mariadb
  restic dump <snapshot> /mariadb.sql | mariadb

Derlenmiş LibreLogin jar'ını (/opt/minecraft/artifacts) geri yüklemek (elle; yeniden derlemek
aynı jar'ı vermeyebilir ve derleme depoları kapanmış olabilir):
  restic restore latest --tag _artifacts --target /
EOF
}

# --- Ortak ------------------------------------------------------------------
load_backup_env() {
    [[ -r $BACKUP_ENV_FILE ]] || die "Okunamadı: $BACKUP_ENV_FILE — scripts/install.sh çalıştırıldı mı? (root gerekir)"
    set -a
    # shellcheck disable=SC1090
    . "$BACKUP_ENV_FILE"
    set +a
    [[ -n ${RESTIC_REPOSITORY:-} ]] || die "$BACKUP_ENV_FILE: RESTIC_REPOSITORY tanımsız."
    if [[ -z ${RESTIC_PASSWORD:-} && ! -r ${RESTIC_PASSWORD_FILE:-} ]]; then
        die "restic parolası yok: RESTIC_PASSWORD_FILE (${RESTIC_PASSWORD_FILE:-tanımsız}) okunamadı."
    fi
    BACKUP_HOST="${BACKUP_HOST:-mc01}"
    require_cmd "$RESTIC"
}

# as_mc, server_running, backup_lock: lib.sh. Sunucu dizinlerine yazan/oradan silen işlemler
# as_mc ile (minecraft kimliğiyle) yapılır: root yetkisiyle sembolik bağ izlenmesin diye.

repo_is_local() { [[ ! $RESTIC_REPOSITORY =~ ^(s3|b2|sftp|rest|azure|gs|swift|rclone): ]]; }

warn_local_repo() {
    repo_is_local || return 0
    log_warn "=================================================================="
    log_warn " YEDEK DEPOSU YEREL: ${RESTIC_REPOSITORY#local:}"
    log_warn " Disk arızası, silinen VDS ya da ele geçirilen makinede yedekler de gider!"
    log_warn " $BACKUP_ENV_FILE içinde uzak bir depo (S3/B2/SFTP/rest-server) tanımlayın"
    log_warn " ve restic parolasının (${RESTIC_PASSWORD_FILE:-RESTIC_PASSWORD}) bir kopyasını makine DIŞINDA saklayın."
    log_warn "=================================================================="
}

# Depo yoksa oluşturur. Parola/erişim hatasında ASLA yeni depo açmaz.
ensure_repo() {
    local path err rc
    if repo_is_local; then
        path=${RESTIC_REPOSITORY#local:}
        [[ -f $path/config ]] && return 0
        log_info "Yerel restic deposu oluşturuluyor: $path"
        install -d -m 0700 -- "$path" || die "Oluşturulamadı: $path"
        "$RESTIC" init || die "restic init başarısız."
        return 0
    fi
    err=$(mktemp)
    rc=0
    "$RESTIC" cat config >/dev/null 2>"$err" || rc=$?
    if ((rc == 0)); then
        rm -f -- "$err"
        return 0
    fi
    if ((rc == 10)) || grep -qiE 'Is there a repository|repository does not exist' "$err"; then
        rm -f -- "$err"
        log_info "Uzak restic deposu oluşturuluyor: $RESTIC_REPOSITORY"
        "$RESTIC" init || die "restic init başarısız."
        return 0
    fi
    cat -- "$err" >&2
    rm -f -- "$err"
    die "restic deposuna erişilemedi (parola, kimlik bilgisi ya da ağ?). Yeni depo AÇILMADI."
}

# Depo var mı? (list/restore depo oluşturmaz)
require_repo() {
    if repo_is_local; then
        [[ -f ${RESTIC_REPOSITORY#local:}/config ]] || die "restic deposu yok: $RESTIC_REPOSITORY (önce bir yedek alın: mc backup all)"
    fi
}

# Yedek/budama/geri yükleme ve mc countdown-restart aynı kilidi paylaşır (lib.sh backup_lock).
take_lock() {
    backup_lock 3600 "Başka bir yedek/budama/geri yükleme işlemi sürüyor ($MC_ROOT/.backup.lock, 1 saat beklendi)."
}

# --- RCON -------------------------------------------------------------------
rcon_cmd() { # <port> <komut...>
    local port=$1
    shift
    RCON_PASSWORD="$RCON_PASSWORD" python3 "$SCRIPTS_DIR/rcon.py" -p "$port" -t 300 "$@"
}

# save-off + save-all flush. Sunucu yeni açılıyorsa RCON gelene kadar birkaç kez dener.
rcon_prepare() { # <sunucu>
    local srv=$1 port i
    port=$(server_get "$srv" RCON_PORT)
    if [[ ! $port =~ ^[0-9]+$ ]]; then
        log_error "$srv: server.env içinde RCON_PORT yok; tutarlı yedek için RCON gerekli."
        return 1
    fi
    if [[ -z ${RCON_PASSWORD:-} ]]; then
        load_secrets
        [[ -n ${RCON_PASSWORD:-} ]] || { log_error "secrets.env: RCON_PASSWORD yok."; return 1; }
    fi
    for ((i = 1; i <= RCON_RETRIES; i++)); do
        if rcon_cmd "$port" save-off >/dev/null; then
            SAVE_OFF+=("$srv:$port")
            if rcon_cmd "$port" "save-all flush" >/dev/null; then
                return 0
            fi
            log_error "$srv: 'save-all flush' başarısız."
            return 1
        fi
        if ((i < RCON_RETRIES)); then
            log_warn "$srv: RCON yanıt vermiyor (deneme $i/$RCON_RETRIES; sunucu açılıyor olabilir)."
            sleep "$RCON_RETRY_SLEEP"
        fi
    done
    log_error "$srv: RCON'a ulaşılamadı; tutarsız dünya kopyası almamak için bu sunucu atlandı."
    return 1
}

# Bekleyen tüm save-off'ları geri alır (çıkış/sinyal tuzağından da çağrılır).
save_on_pending() {
    local item
    for item in "${SAVE_OFF[@]}"; do
        if rcon_cmd "${item##*:}" save-on >/dev/null 2>&1; then
            log_info "${item%%:*}: save-on"
        else
            log_error "${item%%:*}: save-on GERİ VERİLEMEDİ — elle çalıştırın: mc rcon ${item%%:*} save-on"
        fi
    done
    SAVE_OFF=()
}

# --- Yedek ------------------------------------------------------------------
# Not: '||' ile çağrıldığı için set -e burada etkisizdir; adımlar açıkça denetlenir.
# LibreLogin SQLite veritabanının tutarlı kopyası (sqlite3 çevrimiçi yedek API'si; yazma sürerken de güvenli).
# minecraft kimliğiyle çalışır; kopya önce .tmp'ye yazılır, quick_check geçerse yerine konur.
SQLITE_SNAPSHOT_PY='
import os, sqlite3, sys
src, dst = sys.argv[1], sys.argv[2]
tmp = dst + ".tmp"
if os.path.lexists(tmp):
    os.unlink(tmp)
s = sqlite3.connect(src, timeout=60)
try:
    d = sqlite3.connect(tmp)
    s.backup(d)
    ok = d.execute("PRAGMA quick_check").fetchone()[0]
    d.close()
finally:
    s.close()
if ok != "ok":
    os.unlink(tmp)
    sys.exit("quick_check: %s" % ok)
os.replace(tmp, dst)
'

snapshot_librelogin_db() { # <sunucu-dizini>
    local db=$1/$LL_DB_REL
    [[ -e $db || -L $db ]] || return 0
    if [[ -L $db || ! -f $db ]]; then
        log_error "$db düzenli dosya değil (sembolik bağ?); tutarlı kopya alınmadı."
        return 1
    fi
    if ! as_mc python3 -I -c "$SQLITE_SNAPSHOT_PY" "$db" "$db$LL_SNAP_SUFFIX"; then
        log_error "LibreLogin veritabanının tutarlı kopyası alınamadı ($db)."
        return 1
    fi
    log_info "LibreLogin veritabanı kopyalandı: ${LL_DB_REL}${LL_SNAP_SUFFIX}"
}

backup_server() { # <sunucu>
    local srv=$1 dir type rc=0 prep=0
    local -a excl=()
    dir=$SERVERS_DIR/$srv
    if [[ ! -d $dir ]]; then
        log_warn "$srv: $dir yok, atlanıyor (henüz kurulmamış)."
        return 0
    fi
    type=$(server_get "$srv" TYPE)
    case $type in
        paper)
            # Yeniden üretilebilen/büyük içerik hariç; dünya (world/ altında tüm boyutlar), config'ler ve eklentiler dahil.
            excl=(--exclude "$dir/cache" --exclude "$dir/libraries" --exclude "$dir/versions"
                --exclude "$dir/logs" --exclude "$dir/plugins/.paper-remapped" --exclude '*.jar.old')
            if server_running "$srv"; then
                rcon_prepare "$srv" || return 1
            fi
            ;;
        velocity)
            # Proxy'de dünya yok: velocity.toml, eklenti config'leri, anahtarlar (floodgate key.pem) ve
            # LibreLogin hesap veritabanı (tutarlı kopyasıyla birlikte) yedeklenir.
            excl=(--exclude "$dir/logs" --exclude '*.jar' --exclude '*.jar.old' --exclude '*.jar.new'
                --exclude "$dir/plugins/*/cache" --exclude "$dir/$LL_DB_REL$LL_SNAP_SUFFIX.tmp")
            snapshot_librelogin_db "$dir" || prep=1
            ;;
        limbo)
            # PicoLimbo durumsuzdur: yalnız server.toml vb. küçük dosyalar. İkili yeniden indirilebilir.
            excl=(--exclude "$dir/logs" --exclude "$dir/pico_limbo" --exclude "$dir/pico_limbo.*")
            ;;
        *)
            log_error "$srv: bilinmeyen TYPE '$type' (paper | velocity | limbo)"
            return 1
            ;;
    esac
    log_info "$srv: yedekleniyor ($dir)..."
    "$RESTIC" backup "$dir" --host "$BACKUP_HOST" --tag "$srv" "${excl[@]}" || rc=$?
    case $rc in
        0) log_ok "$srv: yedek tamam." ;;
        3) log_warn "$srv: yedek alındı ama bazı dosyalar okunamadı (restic çıkış 3)." ;;
        *)
            log_error "$srv: restic backup başarısız (çıkış $rc)."
            return 1
            ;;
    esac
    return "$prep"
}

backup_mariadb() {
    local dump dir rc=0 db
    local -a want=() have=() dbs=()
    if ! command -v mariadb-dump >/dev/null 2>&1 || ! command -v mariadb >/dev/null 2>&1; then
        log_warn "mariadb-dump bulunamadı; veritabanı yedeği atlandı."
        return 0
    fi
    db=${DB_DATABASES:-luckperms}
    read -r -a want <<<"${db//,/ }"
    mapfile -t have < <(mariadb --protocol=socket -N -B -e 'SHOW DATABASES' 2>/dev/null)
    for db in "${want[@]}"; do
        if printf '%s\n' "${have[@]}" | grep -qxF -- "$db"; then dbs+=("$db"); fi
    done
    if ((${#dbs[@]} == 0)); then
        log_warn "Yedeklenecek veritabanı yok (${want[*]} bulunamadı ya da MariaDB kapalı)."
        return 0
    fi
    dir=$(mktemp -d) || return 1
    dump=$dir/mariadb.sql
    log_info "MariaDB yedekleniyor (${dbs[*]})..."
    if ! (umask 077 && mariadb-dump --protocol=socket --single-transaction --quick --routines --events --triggers \
        --default-character-set=utf8mb4 --databases "${dbs[@]}" >"$dump"); then
        rm -rf -- "$dir"
        log_error "mariadb-dump başarısız."
        return 1
    fi
    "$RESTIC" backup --stdin --stdin-filename mariadb.sql --host "$BACKUP_HOST" --tag "$DB_TAG" <"$dump" || rc=$?
    rm -rf -- "$dir"
    if ((rc != 0)); then
        log_error "MariaDB dökümü depoya yazılamadı (restic çıkış $rc)."
        return 1
    fi
    log_ok "MariaDB yedeği tamam."
}

# $MC_ROOT/artifacts (root'a ait, küçük): yerelde derlenen eklenti jar'ları. Aynı commit'ten yeniden
# derlemek bire bir aynı jar'ı vermeyebilir ve derleme depoları kapanabilir; bu yüzden saklanır.
backup_artifacts() {
    local dir=$MC_ROOT/artifacts rc=0
    [[ -d $dir && ! -L $dir ]] || return 0
    [[ -n $(find "$dir" -mindepth 1 -maxdepth 1 -print -quit) ]] || return 0
    log_info "artifacts/ yedekleniyor ($dir)..."
    "$RESTIC" backup "$dir" --host "$BACKUP_HOST" --tag "$ARTIFACTS_TAG" || rc=$?
    if ((rc != 0 && rc != 3)); then
        log_error "artifacts/ yedeklenemedi (restic çıkış $rc)."
        return 1
    fi
    log_ok "artifacts/ yedeği tamam."
}

cmd_backup() {
    local target=${1:-all} out s fails=0
    local -a targets=()
    out=$(resolve_targets "$target")
    mapfile -t targets <<<"$out"
    load_network_env
    load_backup_env
    warn_local_repo
    take_lock
    ensure_repo
    trap save_on_pending EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for s in "${targets[@]}"; do
        backup_server "$s" || fails=$((fails + 1))
        save_on_pending
    done
    if [[ $target == all ]]; then
        backup_mariadb || fails=$((fails + 1))
        backup_artifacts || fails=$((fails + 1))
    fi
    if ((fails > 0)); then
        log_error "Yedekleme $fails hatayla bitti."
        return 1
    fi
    log_ok "Yedekleme bitti."
}

# --- Budama -----------------------------------------------------------------
num_or() { # <değer> <varsayılan> — yalnız rakamsa değeri, değilse varsayılanı yazar
    if [[ $1 =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

# Paper/Velocity günlükleri asla kendiliğinden silmez (KVKK: yazılı saklama süresi).
# Silme minecraft kimliğiyle yapılır (logs/ dizini sembolik bağa çevrilse bile root dosyası silinmez).
prune_logs() {
    local days d n=0 out
    days=$(num_or "${LOG_RETENTION_DAYS:-90}" 90)
    for d in "$SERVERS_DIR"/*/logs; do
        [[ -d $d && ! -L $d ]] || continue
        out=$(as_mc find "$d" -type f -name '*.log.gz' -mtime +"$days" -print -delete) ||
            log_warn "$d: bazı günlükler silinemedi."
        if [[ -n $out ]]; then n=$((n + $(grep -c . <<<"$out"))); fi
    done
    log_ok "Günlük budama: $days günden eski $n dosya silindi."
}

cmd_prune() {
    local rc=0
    load_network_env
    load_backup_env
    warn_local_repo
    take_lock
    prune_logs
    ensure_repo
    log_info "Eski anlık görüntüler siliniyor (saatlik ${BACKUP_KEEP_HOURLY:-24}, günlük ${BACKUP_KEEP_DAILY:-7}, haftalık ${BACKUP_KEEP_WEEKLY:-4}, aylık ${BACKUP_KEEP_MONTHLY:-6})..."
    "$RESTIC" forget --prune --host "$BACKUP_HOST" --group-by host,tags \
        --keep-hourly "$(num_or "${BACKUP_KEEP_HOURLY:-}" 24)" \
        --keep-daily "$(num_or "${BACKUP_KEEP_DAILY:-}" 7)" \
        --keep-weekly "$(num_or "${BACKUP_KEEP_WEEKLY:-}" 4)" \
        --keep-monthly "$(num_or "${BACKUP_KEEP_MONTHLY:-}" 6)" || rc=$?
    if ((rc != 0)); then
        log_error "restic forget/prune başarısız (çıkış $rc)."
        return 1
    fi
    log_ok "Budama tamam."
}

# --- Listeleme --------------------------------------------------------------
cmd_list() {
    local srv=${1:-}
    local -a filt=()
    load_backup_env
    filt=(--host "$BACKUP_HOST")
    if [[ -n $srv && $srv != all ]]; then
        server_exists "$srv" || [[ $srv == "$DB_TAG" || $srv == "$ARTIFACTS_TAG" ]] || die "Tanımsız sunucu: $srv"
        filt+=(--tag "$srv")
    fi
    require_repo
    "$RESTIC" snapshots --compact "${filt[@]}"
}

# --- Geri yükleme -----------------------------------------------------------
# Yedekte olmayan (yeniden üretilebilir) içeriği eski dizinden geri koyar; yoksa ilk açılışta yeniden iner.
carry_over() { # <tür> <eski-dizin> <yeni-dizin>
    local type=$1 old=$2 new=$3 p f
    [[ -d $old ]] || return 0
    case $type in
        paper)
            for p in cache libraries versions; do
                if [[ -d $old/$p && ! -e $new/$p ]]; then cp -a -- "$old/$p" "$new/$p"; fi
            done
            ;;
        velocity)
            for f in "$old"/*.jar "$old"/plugins/*.jar; do
                [[ -f $f ]] || continue
                p=${f#"$old"/}
                if [[ ! -e $new/$p && -d $(dirname -- "$new/$p") ]]; then cp -a -- "$f" "$new/$p"; fi
            done
            ;;
        limbo)
            f=$old/pico_limbo
            if [[ -f $f && ! -L $f && ! -e $new/pico_limbo ]]; then cp -a -- "$f" "$new/pico_limbo"; fi
            ;;
    esac
}

# Geri yüklenen Velocity dizininde LibreLogin'in tutarlı kopyasını canlı veritabanı yapar
# (bayat -wal/-shm, başka bir dosyanın üzerine uygulanmasın diye silinir). minecraft kimliğiyle.
promote_librelogin_db() { # <sunucu-dizini>
    local db=$1/$LL_DB_REL
    [[ -f $db$LL_SNAP_SUFFIX && ! -L $db$LL_SNAP_SUFFIX ]] || return 0
    if as_mc mv -fT -- "$db$LL_SNAP_SUFFIX" "$db" && as_mc rm -f -- "$db-wal" "$db-shm" "$db-journal"; then
        log_ok "LibreLogin veritabanı tutarlı kopyadan geri yüklendi ($LL_DB_REL)."
    else
        log_error "LibreLogin kopyası yerine konamadı: elle '$db$LL_SNAP_SUFFIX' → '$db' yapın."
    fi
}

cmd_restore() {
    local srv=${1:-} snap=${2:-} dir type json id time src stage aside answer
    [[ -n $srv && -n $snap ]] || die "Kullanım: mc restore <sunucu> <snapshot>  (listelemek için: mc backup list <sunucu>)"
    server_exists "$srv" || die "Tanımsız sunucu: $srv"
    [[ $snap =~ ^([0-9a-f]{8,64}|latest)$ ]] || die "Geçersiz snapshot kimliği: $snap"
    require_cmd jq
    load_network_env
    load_backup_env
    require_repo
    take_lock
    type=$(server_get "$srv" TYPE)
    dir=$SERVERS_DIR/$srv

    json=$("$RESTIC" snapshots --json --host "$BACKUP_HOST" --tag "$srv" "$snap") ||
        die "Snapshot bulunamadı: $snap (sunucu etiketi: $srv)"
    [[ $(jq 'length' <<<"$json") == 1 ]] || die "Snapshot '$snap' bulunamadı ya da belirsiz."
    # restic, açık kimlik verilince --tag/--host süzgecini yok sayar: etiketi burada denetle.
    jq -e --arg s "$srv" '.[0].tags // [] | index($s) != null' <<<"$json" >/dev/null ||
        die "Snapshot '$snap' bu sunucuya ($srv) ait değil (etiketleri: $(jq -r '.[0].tags // [] | join(",")' <<<"$json"))."
    if [[ $(jq -r '.[0].hostname' <<<"$json") != "$BACKUP_HOST" ]]; then
        log_warn "Snapshot başka bir BACKUP_HOST'a ait: $(jq -r '.[0].hostname' <<<"$json")"
    fi
    [[ $(jq '.[0].paths | length' <<<"$json") == 1 ]] || die "Snapshot birden çok yol içeriyor; elle geri yükleyin."
    id=$(jq -r '.[0].id' <<<"$json")
    time=$(jq -r '.[0].time' <<<"$json")
    src=$(jq -r '.[0].paths[0]' <<<"$json")

    printf '\n  Sunucu      : %s (%s)\n  Snapshot    : %s  (%s)\n  Yedeklenen  : %s\n  Hedef       : %s\n\n' \
        "$srv" "$type" "${id:0:8}" "$time" "$src" "$dir" >&2
    log_warn "Sunucu DURDURULACAK; mevcut dizin '$dir.onceki-<tarih>' olarak kenara alınacak."
    [[ $type == velocity ]] && log_warn "Velocity durunca TÜM oyuncuların bağlantısı kopar."
    printf 'Onaylamak için büyük harflerle EVET yazın: ' >&2
    IFS= read -r answer || answer=""
    [[ $answer == EVET ]] || die "İptal edildi (onay verilmedi)."

    # Önce geçici dizine aç (aynı dosya sistemi): başarısız olursa canlı dizine dokunulmamış olur.
    stage=$(mktemp -d "$SERVERS_DIR/.restore-$srv.XXXXXX") || die "Geçici dizin oluşturulamadı."
    log_info "Snapshot açılıyor..."
    if ! "$RESTIC" restore "$id" --target "$stage"; then
        rm -rf -- "$stage"
        die "restic restore başarısız; mevcut sunucu dizinine dokunulmadı."
    fi
    [[ -d $stage$src ]] || { rm -rf -- "$stage"; die "Snapshot içeriği beklenen yolda değil: $src"; }

    if server_running "$srv"; then
        log_info "mc@$srv durduruluyor..."
        systemctl stop "$(unit_of "$srv")" || { rm -rf -- "$stage"; die "Sunucu durdurulamadı."; }
    fi
    if [[ -e $dir ]]; then
        aside="$dir.onceki-$(date +%Y%m%d-%H%M%S)"
        mv -- "$dir" "$aside" || { rm -rf -- "$stage"; die "Mevcut dizin kenara alınamadı."; }
        log_info "Mevcut dizin saklandı: $aside"
    fi
    mv -T -- "$stage$src" "$dir" || die "Geri yüklenen dizin yerine taşınamadı (eski dizin: ${aside:-yok}; açılan: $stage$src)."
    rm -rf -- "$stage"
    carry_over "$type" "${aside:-}" "$dir"
    if [[ ${EUID:-$(id -u)} -eq 0 ]] && id -u "$MC_USER" >/dev/null 2>&1; then
        chown -R -- "$MC_USER:" "$dir" # "kullanıcı:" = kullanıcının birincil grubu
    fi
    chmod 0750 -- "$dir"
    if [[ $type == velocity ]]; then promote_librelogin_db "$dir"; fi

    log_ok "$srv geri yüklendi (snapshot ${id:0:8}, $time)."
    printf '\nBaşlatmak için:  sudo mc start %s\n' "$srv"
    [[ -n ${aside:-} ]] && printf 'Eski dizin     :  %s  (kontrol ettikten sonra silebilirsiniz)\n' "$aside"
    if [[ $type == velocity ]] && [[ ! -f $dir/server.jar ]]; then
        printf 'Not: jar dosyaları yedekte yok → önce: sudo mc download all %s\n' "$srv"
        printf '     LibreLogin, %s/artifacts/ içinden kopyalanır; orada yoksa önce:\n' "$MC_ROOT"
        printf '     restic restore latest --tag %s --target /   (ya da: sudo mc build-librelogin)\n' "$ARTIFACTS_TAG"
    fi
    if [[ $type == limbo ]] && [[ ! -f $dir/pico_limbo ]]; then
        printf 'Not: pico_limbo ikilisi yedekte yok → önce: sudo mc download core %s\n' "$srv"
    fi
    return 0
}

main() {
    local cmd=${1:-all}
    case $cmd in
        -h | --help | help)
            usage
            return 0
            ;;
    esac
    require_root
    # Sunucu dizinlerine dokunan işlemler minecraft kimliğiyle yapılır (as_mc); listeleme dokunmaz.
    [[ $cmd == list ]] || require_mc_user
    case $cmd in
        prune) cmd_prune ;;
        list) cmd_list "${2:-}" ;;
        restore) cmd_restore "${2:-}" "${3:-}" ;;
        backup) cmd_backup "${2:-all}" ;;
        *) cmd_backup "$cmd" ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
