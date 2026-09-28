#!/usr/bin/env bash
# LibreLogin'i (Velocity'deki karma giriş eklentisi) sabit bir commit'ten kaynaktan derler (SPEC §17).
# Yayınlanmış bir 26.x / Velocity 4 sürümü yok; jar'ı biz derleyip saklarız:
#   $MC_ROOT/artifacts/LibreLogin-<commit'in ilk 7 hanesi>.jar   (0644 root)
#   $MC_ROOT/artifacts/LibreLogin-<commit7>.jar.sha256            (sha256sum biçimi)
# config/plugins.list'teki "local" satırı bu dosyayı gösterir; ardından
#   sudo mc download plugins velocity
# jar'ı Velocity'nin plugins/ (çalışmış sunucuda plugins/update/) dizinine koyar.
#
# Kullanım: sudo mc build-librelogin [--commit <sha>] [--keep-jdk] [--dry-run]
#           sudo scripts/build-librelogin.sh [aynı seçenekler]
#
# Adımlar:
#   1) Commit: --commit ya da config/network.env LIBRELOGIN_COMMIT (7-40 onaltılık hane).
#   2) JDK 25: /usr/lib/jvm altında JDK 25 javac'ı varsa o kullanılır (dokunulmaz). Yoksa
#      install.sh'in kurduğu Adoptium deposundan temurin-25-jdk kurulur ve derlemeden sonra
#      (başarısız olsa da) kaldırılır; --keep-jdk ile kalır.
#   3) https://github.com/kyngs/LibreLogin (dal: dev) root'a ait geçici bir dizinin içine klonlanır,
#      commit'e geçilir ve './gradlew --no-daemon build' çalıştırılır.
#   4) Plugin/build/libs/LibreLogin.jar → artifacts/ (+ .sha256); SHA-256 ve sonraki adım basılır.
#
# Güvenlik: Gradle derlemesi depodaki kodu ve indirdiği Gradle eklentilerini ÇALIŞTIRIR. Bu yüzden
# klonlama ve derleme ayrı, yetkisiz bir sistem kullanıcısıyla (varsayılan 'kami-build'; install.sh
# oluşturur, yoksa bu betik oluşturur; geçici HOME/GRADLE_USER_HOME ile) yapılır — asla root ile değil:
#   - Derleme kullanıcısı root, $MC_USER ya da ek gruplu bir kullanıcı olamaz; başlarken o kullanıcının
#     çalışan bir süreci varsa derleme reddedilir (paylaşılan kimlik çıktıyı değiştirebilir).
#   - Derleme komutları yeni bir oturumda (setsid: denetim uçbirimi yok), stdin /dev/null ile çalışır;
#     çıktıları denetim karakterlerinden arındırılarak basılır. Derleme root'un uçbirimine girdi
#     enjekte edemez (TIOCSTI, /dev/tty ya da uçbirim yanıt dizileri).
#   - Gradle bitince derleme kullanıcısının TÜM süreçleri (daemon, Kotlin derleyicisi...) öldürülür;
#     çıktı ancak ondan sonra, derleme kullanıcısının kimliğiyle (sembolik bağ root yetkisiyle
#     izlenmez) okunur ve artifacts/ altına konur.
# Root yalnız JDK paketini kurar/kaldırır, kullanıcıyı oluşturur ve sonucu yerine koyar.
#
# Ortam değişkenleri (çoğu yalnız test içindir):
#   LIBRELOGIN_REPO        (https://github.com/kyngs/LibreLogin)   LIBRELOGIN_BRANCH (dev)
#   LIBRELOGIN_BUILD_USER  (kami-build; lib.sh) — root/$MC_USER olamaz, ek grubu olmamalı
#   MC_JVM_DIR             (/usr/lib/jvm)      ADOPTIUM_SOURCES (/etc/apt/sources.list.d/adoptium.sources)
#   TMPDIR                 (/var/tmp; derleme birkaç yüz MB ister; noexec bağlı OLMAMALI)
set -Eeuo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

REPO_URL="${LIBRELOGIN_REPO:-https://github.com/kyngs/LibreLogin}"
BRANCH="${LIBRELOGIN_BRANCH:-dev}"
BUILD_USER="$LIBRELOGIN_BUILD_USER" # varsayılanı lib.sh'te (kami-build)
DEFAULT_BUILD_USER=kami-build
JVM_DIR="${MC_JVM_DIR:-/usr/lib/jvm}"
ADOPTIUM_SOURCES="${ADOPTIUM_SOURCES:-/etc/apt/sources.list.d/adoptium.sources}"
JDK_PKG="temurin-25-jdk"
JAR_REL="Plugin/build/libs/LibreLogin.jar"
ARTIFACTS_DIR="$MC_ROOT/artifacts"
APT_ENV=(env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l)
APT_OPTS=(-y -q -o DPkg::Lock::Timeout=300)
# Derleme kullanıcısına aktarılan ortam (env -i ile geri kalanı temizlenir): vekil sunucu ve CA ayarları.
PASS_ENV=(http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY JAVA_TOOL_OPTIONS GRADLE_OPTS
    SSL_CERT_FILE GIT_SSL_CAINFO)

DRY_RUN=0
KEEP_JDK=0
COMMIT=""
COMMIT_FROM=""
JAVA_HOME_25=""
JDK_INSTALLED_BY_US=0
JAVA_ALT_BEFORE=""
WORK=""
BUILD_UID=""
PL_MATCH=1 # plugins.list'in LibreLogin "local" satırı bu derlemenin jar'ını gösteriyor mu

usage() {
    cat <<EOF
Kullanım: sudo mc build-librelogin [--commit <sha>] [--keep-jdk] [--dry-run]

LibreLogin'i $REPO_URL (dal: $BRANCH) deposundan, sabit bir commit'ten derler ve
$ARTIFACTS_DIR/LibreLogin-<commit'in ilk 7 hanesi>.jar (+ .sha256) olarak saklar.

  --commit <sha>   derlenecek commit (7-40 onaltılık hane). Verilmezse config/network.env
                   LIBRELOGIN_COMMIT. Farklı bir commit kullanacaksanız network.env'i ve
                   config/plugins.list'teki LibreLogin satırını BİRLİKTE güncelleyin.
  --keep-jdk       derleme için kurulan $JDK_PKG paketini sonra kaldırma
  -n, --dry-run    hiçbir şey kurmadan/indirmeden yapılacakları yazdırır
  -h, --help       bu yardım

JDK 25 javac zaten kuruluysa ($JVM_DIR) o kullanılır ve kaldırılmaz. Derleme '$BUILD_USER'
kullanıcısıyla (asla root değil; yoksa oluşturulur) geçici bir dizinde yapılır; dizin sonunda
silinir. Geçici dizin kökü TMPDIR (varsayılan /var/tmp) noexec bağlı olmamalı.
Sonraki adım: sudo mc download plugins velocity
EOF
}

# --- Temizlik -------------------------------------------------------------------
# EXIT tuzağı. errexit tuzak içinde de geçerli olduğundan kapatılır: bir adımın hatası (ör. rm) sonraki
# adımları (JDK kaldırma, /usr/bin/java seçimi) atlatmasın ve çıkış kodunu değiştirmesin. Sıra:
# derleme süreçleri → JDK → java seçimi → geçici dizin.
cleanup() {
    local rc=$?
    set +e
    if [[ -n $BUILD_UID && -n $WORK ]]; then # derleme kullanıcısıyla bir şey çalıştırıldıysa
        kill_build_procs || log_warn "Derleme kullanıcısının ($BUILD_USER) bazı süreçleri durdurulamadı: pgrep -U $BUILD_UID -a"
    fi
    if ((JDK_INSTALLED_BY_US && !KEEP_JDK)) && pkg_installed "$JDK_PKG"; then
        log_info "Derleme için kurulan $JDK_PKG kaldırılıyor (tutmak için: --keep-jdk)..."
        "${APT_ENV[@]}" apt-get remove "${APT_OPTS[@]}" "$JDK_PKG" >/dev/null ||
            log_warn "$JDK_PKG kaldırılamadı; elle kaldırın: sudo apt-get remove $JDK_PKG"
    fi
    if ((JDK_INSTALLED_BY_US)); then restore_java_alternative; fi
    if [[ -n $WORK && -d $WORK ]]; then
        rm -rf -- "$WORK" || log_warn "Geçici dizin silinemedi; elle silin: sudo rm -rf -- $WORK"
    fi
    return "$rc"
}

# /usr/bin/java seçimi (systemd birimleri bunu kullanır) JDK kurulumu/kaldırılmasıyla değiştiyse geri al.
java_alternative() {
    command -v update-alternatives >/dev/null 2>&1 || return 0
    { update-alternatives --query java 2>/dev/null || true; } | awk '$1 == "Value:" { print $2; exit }'
}
restore_java_alternative() {
    local now
    [[ -n $JAVA_ALT_BEFORE ]] || return 0
    now=$(java_alternative)
    if [[ $now != "$JAVA_ALT_BEFORE" && -x $JAVA_ALT_BEFORE ]]; then
        if update-alternatives --set java "$JAVA_ALT_BEFORE" >/dev/null; then
            log_info "/usr/bin/java yeniden $JAVA_ALT_BEFORE yapıldı."
        else
            log_warn "/usr/bin/java seçimi geri alınamadı; denetleyin: update-alternatives --config java"
        fi
    fi
}

# --- Argümanlar -----------------------------------------------------------------
parse_args() {
    while (($#)); do
        case $1 in
            --commit)
                (($# >= 2)) || die "--commit bir değer ister (ör. --commit 39397c4)."
                COMMIT=$2
                COMMIT_FROM="--commit"
                shift
                ;;
            --commit=*)
                COMMIT=${1#--commit=}
                COMMIT_FROM="--commit"
                ;;
            --keep-jdk) KEEP_JDK=1 ;;
            -n | --dry-run) DRY_RUN=1 ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) die "Bilinmeyen argüman: $1 (yardım: mc build-librelogin --help)" ;;
        esac
        shift
    done
}

resolve_commit() {
    if [[ $COMMIT_FROM == --commit && -z $COMMIT ]]; then
        die "--commit boş olamaz (ör. --commit 39397c4)."
    fi
    if [[ -z $COMMIT ]]; then
        load_network_env
        COMMIT=${LIBRELOGIN_COMMIT:-}
        COMMIT_FROM="config/network.env LIBRELOGIN_COMMIT"
        [[ -n $COMMIT ]] || die "config/network.env: LIBRELOGIN_COMMIT tanımsız; --commit <sha> verin."
    fi
    COMMIT=${COMMIT,,}
    [[ $COMMIT =~ ^[0-9a-f]{7,40}$ ]] ||
        die "Geçersiz commit: '$COMMIT' ($COMMIT_FROM) — 7-40 haneli onaltılık git commit kimliği olmalı."
}

# Derleme kullanıcısını denetler (yoksa ve varsayılansa oluşturur): root, $MC_USER ya da ek gruplu
# olamaz; çalışan süreci olamaz. BUILD_UID'i yazar (kuru çalıştırmada kullanıcı yoksa boş kalır).
check_build_user() {
    local uid mc_uid groups
    if ! uid=$(id -u -- "$BUILD_USER" 2>/dev/null); then
        [[ $BUILD_USER == "$DEFAULT_BUILD_USER" ]] ||
            die "Derleme kullanıcısı yok: '$BUILD_USER' (LIBRELOGIN_BUILD_USER). Varsayılanı ($DEFAULT_BUILD_USER) kullanın ya da kullanıcıyı oluşturun."
        if ((DRY_RUN)); then
            printf '[kuru] derleme kullanıcısı oluşturulur: %s (sistem kullanıcısı; ek grup, ev ve kabuk yok)\n' "$BUILD_USER" >&2
            return 0
        fi
        log_info "Derleme kullanıcısı oluşturuluyor: $BUILD_USER"
        ensure_build_user ""
        uid=$(id -u -- "$BUILD_USER" 2>/dev/null) || die "Derleme kullanıcısı oluşturulamadı: $BUILD_USER"
    fi
    if ((uid == 0)); then
        die "Gradle root olarak ÇALIŞTIRILMAZ: LIBRELOGIN_BUILD_USER='$BUILD_USER' (uid 0). Derleme depodaki kodu çalıştırır; yetkisiz bir kullanıcı verin (varsayılan: $DEFAULT_BUILD_USER)."
    fi
    mc_uid=$(id -u -- "$MC_USER" 2>/dev/null) || mc_uid=""
    [[ $uid != "$mc_uid" ]] ||
        die "Derleme kullanıcısı sunucu kullanıcısı ($MC_USER) olamaz: derleme kodu sunucu dosyalarına erişirdi. Varsayılanı ($DEFAULT_BUILD_USER) kullanın."
    groups=$(id -G -- "$BUILD_USER") || die "Derleme kullanıcısının grupları okunamadı: $BUILD_USER"
    [[ $groups != *' '* ]] ||
        die "Derleme kullanıcısının ek grupları var ('$BUILD_USER': $(id -Gn -- "$BUILD_USER")); derleme bu grupların dosyalarına erişirdi. Grupsuz bir kullanıcı kullanın (varsayılan: $DEFAULT_BUILD_USER)."
    if command -v pgrep >/dev/null 2>&1 && pgrep -U "$uid" >/dev/null 2>&1; then
        local msg="'$BUILD_USER' kullanıcısının çalışan süreçleri var (pgrep -U $uid -a): aynı kimlikle çalışan bir süreç derleme çıktısını değiştirebilir. Derleme kullanıcısını başka işe kullanmayın; artık süreçleri durdurun (sudo pkill -KILL -U $uid) ve tekrar deneyin."
        if ((DRY_RUN)); then log_warn "$msg"; else die "$msg"; fi
    fi
    BUILD_UID=$uid
}

# config/plugins.list'teki LibreLogin "local" satırı bu derlemenin jar'ını mı gösteriyor? Commit
# network.env'den geliyorsa uyuşmazlık HATADIR (ikisi birlikte değişir; yoksa 'mc download' eski jar'ı
# kurar). --commit ile verilmişse yalnız uyarılır ve PL_MATCH=0 olur (sonraki adım metni buna göre).
check_plugins_list() {
    local want=$1 id
    local -a ids=()
    mapfile -t ids < <(plugin_local_ids LibreLogin)
    if ((${#ids[@]} == 0)); then
        PL_MATCH=0
        log_warn "$(plugins_list_file): LibreLogin 'local' satırı yok — jar derlenir ama 'mc download' onu kurmaz."
        return 0
    fi
    for id in "${ids[@]}"; do
        [[ ${id##*/} != "$want" ]] || return 0
    done
    PL_MATCH=0
    if [[ $COMMIT_FROM != --commit ]]; then
        die "Uyuşmazlık: network.env LIBRELOGIN_COMMIT ($COMMIT) $want gerektiriyor ama config/plugins.list'teki LibreLogin satırı '${ids[0]}' gösteriyor. İkisini BİRLİKTE aynı commit'e güncelleyin (plugins.list: \$MC_ROOT/artifacts/$want) ve tekrar çalıştırın."
    fi
    log_warn "config/plugins.list'teki LibreLogin satırı '${ids[0]}' gösteriyor; bu derleme $want üretir ('mc download' onu KURMAZ)."
    log_warn "  Bu commit'i kullanacaksanız network.env LIBRELOGIN_COMMIT ve plugins.list satırını BİRLİKTE güncelleyin."
}

# --- JDK 25 -----------------------------------------------------------------------
# JVM_DIR altında JDK 25 (javac 25.x; erken erişim '-ea' değil) arar; bulursa yolunu yazar.
find_jdk25() {
    local d out
    for d in "$JVM_DIR"/*/; do
        d=${d%/}
        [[ -x $d/bin/javac && -x $d/bin/java ]] || continue
        out=$("$d/bin/javac" -version 2>&1) || continue
        if grep -qE '^javac 25([.+]|$)' <<<"$out"; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    return 1
}

pkg_installed() {
    [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true) == "install ok installed" ]]
}

ensure_jdk() {
    if JAVA_HOME_25=$(find_jdk25); then
        log_ok "JDK 25 mevcut: $JAVA_HOME_25 (dokunulmaz)."
        return 0
    fi
    if ((DRY_RUN)); then
        [[ -f $ADOPTIUM_SOURCES ]] ||
            log_warn "Adoptium deposu yok ($ADOPTIUM_SOURCES): gerçek çalıştırmada hata verir (bkz. aşağıdaki kurulum adımı)."
        if ((KEEP_JDK)); then
            printf '[kuru] apt-get install %s   (JDK 25 yok; --keep-jdk: derlemeden sonra kalır)\n' "$JDK_PKG" >&2
        else
            printf '[kuru] apt-get install %s   (JDK 25 yok; derlemeden sonra kaldırılır)\n' "$JDK_PKG" >&2
        fi
        JAVA_HOME_25="$JVM_DIR/<temurin-25-jdk>"
        return 0
    fi
    [[ -f $ADOPTIUM_SOURCES ]] ||
        die "JDK 25 yok ve Adoptium deposu kurulmamış ($ADOPTIUM_SOURCES). 'sudo scripts/install.sh' (varsayılan --java=temurin) çalıştırın ya da JDK 25'i elle kurun (ör. sudo apt-get install openjdk-25-jdk-headless) ve tekrar deneyin."
    require_cmd apt-get dpkg-query
    if pkg_installed "$JDK_PKG"; then
        die "$JDK_PKG kurulu görünüyor ama $JVM_DIR altında JDK 25 javac bulunamadı; paketi denetleyin (sudo apt-get install --reinstall $JDK_PKG)."
    fi
    JAVA_ALT_BEFORE=$(java_alternative)
    log_info "JDK 25 yok: $JDK_PKG kuruluyor (Adoptium deposu)..."
    # Bundan sonra (yarım kalsa bile) çıkışta kaldırılır.
    JDK_INSTALLED_BY_US=1
    if ! "${APT_ENV[@]}" apt-get install "${APT_OPTS[@]}" --no-install-recommends "$JDK_PKG"; then
        log_warn "Kurulum başarısız; paket listesi yenilenip bir kez daha deneniyor..."
        "${APT_ENV[@]}" apt-get update -q || die "apt-get update başarısız (ağ bağlantısı?)."
        "${APT_ENV[@]}" apt-get install "${APT_OPTS[@]}" --no-install-recommends "$JDK_PKG" ||
            die "$JDK_PKG kurulamadı (ağ bağlantısı ya da Adoptium deposu?)."
    fi
    restore_java_alternative
    JAVA_HOME_25=$(find_jdk25) || die "$JDK_PKG kuruldu ama $JVM_DIR altında JDK 25 javac bulunamadı."
    log_ok "JDK 25 kuruldu: $JAVA_HOME_25"
}

# --- Derleme (yetkisiz kullanıcı) -----------------------------------------------------
# build_env — derleme kullanıcısının temiz ortamı (env -i ile kullanılır)
BUILD_ENV=()
build_env() {
    local v
    BUILD_ENV=("HOME=$WORK/home" "GRADLE_USER_HOME=$WORK/home/.gradle" "LANG=C.UTF-8"
        "PATH=$JAVA_HOME_25/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        "JAVA_HOME=$JAVA_HOME_25" "GIT_TERMINAL_PROMPT=0")
    for v in "${PASS_ENV[@]}"; do
        if [[ -n ${!v:-} ]]; then BUILD_ENV+=("$v=${!v}"); fi
    done
}

# strip_ctl — satır satır (tamponsuz) geçirir; denetim karakterlerini (ESC, CR, BEL, NUL...; sekme ve
# satır sonu hariç) ve UTF-8 C1 denetimlerini siler: derleme çıktısı uçbirime kaçış dizisi gönderemez.
strip_ctl() {
    LC_ALL=C sed -u -e 's/[\x00-\x08\x0b-\x1f\x7f]//g' -e 's/\xc2[\x80-\x9f]//g'
}

# as_builder [-C <dizin>] <komut...> — derleme kullanıcısı olarak, temiz ortamla (env -i) çalıştırır.
# Komut yeni bir oturumdadır (setsid: denetim uçbirimi yok, /dev/tty açılamaz), stdin /dev/null'dur;
# stdout ve stderr root'un uçbirimine doğrudan değil, strip_ctl borularından geçer. Böylece komutun
# elinde hiçbir uçbirim tanıtıcısı olmaz: TIOCSTI ile root'un kabuğuna girdi enjekte edemez.
# Dönüş kodu komutunkidir (pipefail).
as_builder() {
    local -a opts=(-i)
    if [[ ${1:-} == -C ]]; then
        opts+=(-C "$2")
        shift 2
    fi
    { as_user "$BUILD_USER" setsid -w env "${opts[@]}" "${BUILD_ENV[@]}" "$@" </dev/null 2>&1 1>&3 3>&- |
        strip_ctl >&2; } 3>&1 | strip_ctl
}

# kill_build_procs — derleme kullanıcısının TÜM süreçlerini (Gradle/Kotlin daemon'ları, arka plana
# atılmış çocuklar) SIGKILL ile durdurur ve bitmelerini bekler (en çok ~5 sn; kalırsa dönüş 1).
# kill(-1) o kullanıcının kimliğiyle gönderilir: çekirdek, yalnız o kullanıcının süreçlerini ve
# fork'larla yarışmadan tek adımda öldürür. Yalnız root iken ve uid 0 olmayan bir kullanıcı için.
kill_build_procs() {
    local i
    [[ -n $BUILD_UID && $BUILD_UID != 0 && ${EUID:-$(id -u)} -eq 0 ]] || return 0
    as_user "$BUILD_USER" "$BASH" -c 'kill -KILL -1' </dev/null >/dev/null 2>&1 || true
    for ((i = 0; i < 50; i++)); do
        pgrep -U "$BUILD_UID" >/dev/null 2>&1 || return 0
        sleep 0.1
    done
    return 1
}

# check_exec_mount <dizin> — dizin noexec bağlı bir dosya sistemindeyse anlaşılır bir hatayla çıkar
# (gradlew ve Gradle'ın yerel kütüphaneleri orada çalıştırılamaz; CIS sıkılaştırmasında /var/tmp
# çoğu zaman noexec'tir).
check_exec_mount() {
    local o
    command -v findmnt >/dev/null 2>&1 || return 0
    o=$(findmnt -no OPTIONS --target "$1" 2>/dev/null) || return 0
    if [[ ,$o, == *,noexec,* ]]; then
        die "Geçici dizin noexec bağlı bir dosya sisteminde (${TMPDIR:-/var/tmp}): gradlew orada çalıştırılamaz. Çalıştırılabilir bir dizin verin, ör.: sudo install -d -m 0755 /opt/kami-tmp && sudo env TMPDIR=/opt/kami-tmp mc build-librelogin"
    fi
}

prepare_workdir() {
    local gid
    gid=$(id -g -- "$BUILD_USER")
    WORK=$(mktemp -d "${TMPDIR:-/var/tmp}/kami-librelogin.XXXXXX") || die "Geçici dizin oluşturulamadı (${TMPDIR:-/var/tmp})."
    # Kök root'a ait (0755: derleme kullanıcısı geçebilsin); src/ ve home/ yalnız derleme kullanıcısının.
    chmod 0755 -- "$WORK"
    check_exec_mount "$WORK"
    install -d -m 0700 -o "$BUILD_USER" -g "$gid" -- "$WORK/src" "$WORK/home"
    build_env
    as_builder test -w "$WORK/src" -a -w "$WORK/home" ||
        die "Derleme kullanıcısı ($BUILD_USER) geçici dizine erişemiyor ($WORK): TMPDIR'in üst dizinleri herkesçe geçilebilir (o+x) olmalı."
}

clone_and_checkout() {
    local full
    log_info "Klonlanıyor: $REPO_URL (dal $BRANCH) — kullanıcı: $BUILD_USER"
    as_builder git clone --quiet --branch "$BRANCH" --single-branch -- "$REPO_URL" "$WORK/src" ||
        die "LibreLogin deposu klonlanamadı ($REPO_URL, dal $BRANCH) — ağ bağlantısını ve GitHub erişimini denetleyin."
    if ! full=$(as_builder git -C "$WORK/src" rev-parse --verify --quiet "$COMMIT^{commit}"); then
        # Dalda olmayan tam commit: GitHub doğrudan commit ile getirmeye izin verir.
        if ((${#COMMIT} == 40)) && as_builder git -C "$WORK/src" fetch --quiet origin "$COMMIT"; then
            full=$(as_builder git -C "$WORK/src" rev-parse --verify --quiet "$COMMIT^{commit}") || full=""
        fi
        [[ -n $full ]] ||
            die "Commit bulunamadı: $COMMIT ($REPO_URL, dal $BRANCH). Kimliği denetleyin; kısa kimlik belirsizse daha uzun verin."
    fi
    [[ $full == "$COMMIT"* ]] || die "Commit çözümlemesi tutarsız: $COMMIT → $full"
    as_builder git -C "$WORK/src" -c advice.detachedHead=false checkout --quiet --detach "$full" ||
        die "Commit'e geçilemedi: $full"
    log_ok "Commit: $full"
}

run_gradle() {
    local who rc=0
    [[ -f $WORK/src/gradlew ]] || die "Depoda gradlew yok ($REPO_URL @ $COMMIT); derleme yapılamaz."
    # Son güvence: derleme kullanıcısı gerçekten root değil.
    who=$(as_builder id -u) || die "Derleme kullanıcısına ($BUILD_USER) geçilemedi."
    [[ $who != 0 ]] || die "Gradle root olarak ÇALIŞTIRILMAZ (derleme kullanıcısı uid 0)."
    log_info "Derleniyor: ./gradlew --no-daemon build  (kullanıcı: $BUILD_USER, JAVA_HOME=$JAVA_HOME_25; birkaç dakika sürebilir)"
    as_builder -C "$WORK/src" ./gradlew --no-daemon build || rc=$?
    # Gradle'ın geride bıraktığı süreçler çıktıyı okumadan ÖNCE durdurulur (değiştiremesinler).
    kill_build_procs ||
        die "Derleme kullanıcısının ($BUILD_USER) süreçleri durdurulamadı (pgrep -U $BUILD_UID -a); çıktıya güvenilemez."
    case $rc in
        0) ;;
        126 | 127)
            die "gradlew çalıştırılamadı (çıkış $rc: izin yok ya da yorumlayıcı bulunamadı). Geçici dizin (${TMPDIR:-/var/tmp}) noexec bağlı olmamalı ve depo bozulmamış olmalı."
            ;;
        *)
            die "Gradle derlemesi başarısız (çıkış $rc). Yukarıdaki çıktıya bakın; bağımlılık depolarına (Maven Central, repo.papermc.io, repo.kyngs.xyz, services.gradle.org) erişim olmalı."
            ;;
    esac
}

install_artifact() { # <hedef jar>
    local dst=$1 out=$WORK/src/$JAR_REL got sha name old=""
    name=${dst##*/}
    if [[ -L $out || ! -f $out ]]; then
        die "Derleme çıktısı yok ya da düzenli dosya değil: $JAR_REL (derleme betiği değişmiş olabilir)."
    fi
    got=$WORK/LibreLogin.jar
    # Çıktı derleme kullanıcısının dizininde: onun kimliğiyle oku (bağ root yetkisiyle izlenmez).
    # (Bu noktada derleme kullanıcısının hiçbir süreci yok: kill_build_procs.)
    as_user "$BUILD_USER" cat -- "$out" </dev/null >"$got" || die "Derleme çıktısı okunamadı: $JAR_REL"
    [[ -s $got && $(head -c 2 -- "$got") == PK ]] || die "Derleme çıktısı geçerli bir jar değil: $JAR_REL"
    sha=$(sha256sum -- "$got") || die "SHA-256 hesaplanamadı."
    sha=${sha%% *}

    [[ ! -L $ARTIFACTS_DIR ]] || die "$ARTIFACTS_DIR sembolik bağ — güvenlik için reddedildi."
    install -d -m 0755 -o root -g root -- "$ARTIFACTS_DIR"
    if [[ -f $dst ]]; then
        old=$(sha256sum -- "$dst") && old=${old%% *}
    fi
    install -m 0644 -o root -g root -- "$got" "$dst.tmp"
    mv -f -- "$dst.tmp" "$dst"
    printf '%s  %s\n' "$sha" "$name" >"$dst.sha256.tmp"
    chmod 0644 -- "$dst.sha256.tmp"
    mv -f -- "$dst.sha256.tmp" "$dst.sha256"
    if [[ -n $old && $old != "$sha" ]]; then
        log_warn "Önceki $name farklıydı (${old:0:12}…): derleme bire bir tekrarlanabilir değil; üzerine yazıldı."
    fi
    log_ok "LibreLogin derlendi: $dst"
    printf 'SHA-256: %s  %s\n' "$sha" "$name"
}

next_step() { # <önek> — sonraki adım metni (plugins.list bu jar'ı göstermiyorsa farklı)
    if ((PL_MATCH)); then
        printf '%ssudo mc download plugins velocity\n' "$1"
    else
        printf "%s(plugins.list bu jar'ı göstermiyor) network.env LIBRELOGIN_COMMIT ile plugins.list'teki\n" "$1"
        printf "  LibreLogin satırını BİRLİKTE %s yapın; ardından: sudo mc download plugins velocity\n" "${COMMIT:0:7}"
    fi
}

main() {
    local jar
    parse_args "$@"
    resolve_commit
    jar="$ARTIFACTS_DIR/$(librelogin_jar "$COMMIT")"
    ((DRY_RUN)) || require_root
    log_info "LibreLogin: $REPO_URL @ $COMMIT ($COMMIT_FROM) → $jar"
    check_plugins_list "${jar##*/}"

    if ((DRY_RUN)); then
        log_info "Kuru çalıştırma: hiçbir şey kurulmayacak, indirilmeyecek ya da yazılmayacak."
        check_build_user
        command -v git >/dev/null 2>&1 || log_warn "git kurulu değil (gerçek çalıştırmada gerekir: sudo apt-get install git)."
        ensure_jdk
        cat >&2 <<EOF
[kuru] geçici dizin: ${TMPDIR:-/var/tmp}/kami-librelogin.XXXXXX (root; src/ ve home/ $BUILD_USER kullanıcısının; noexec olmamalı)
[kuru] git clone --branch $BRANCH --single-branch $REPO_URL <geçici>/src   (kullanıcı: $BUILD_USER, setsid, stdin /dev/null)
[kuru] git checkout --detach $COMMIT
[kuru] ./gradlew --no-daemon build   (kullanıcı: $BUILD_USER, JAVA_HOME=$JAVA_HOME_25, HOME=<geçici>/home)
[kuru] $BUILD_USER kullanıcısının tüm süreçleri durdurulur (kill -KILL -1)
[kuru] $JAR_REL → $jar (0644 root) + ${jar##*/}.sha256
[kuru] geçici dizin silinir
$(next_step '[kuru] sonraki adım: ')
EOF
        return 0
    fi

    require_cmd git sha256sum install env setsid sed pgrep flock
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ -d $MC_ROOT ]]; then
        local lockfd
        exec {lockfd}>>"$MC_ROOT/.build-librelogin.lock"
        flock -n "$lockfd" || die "Başka bir LibreLogin derlemesi sürüyor ($MC_ROOT/.build-librelogin.lock)."
    fi
    check_build_user
    ensure_jdk
    prepare_workdir
    clone_and_checkout
    run_gradle
    install_artifact "$jar"
    echo
    next_step 'Sonraki adım: '
    cat <<EOF
  (Velocity çalışıyorsa jar plugins/update/ altına iner; 'sudo mc restart velocity' ile devreye girer.)
Not: Bu bir geliştirme (SNAPSHOT) sürümüdür ve açılışta "DO NOT USE THIS IN PRODUCTION" yazar.
     Canlıya almadan önce giriş duman testini yapın (docs/08-giris-sistemi.md).
EOF
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
