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
# klonlama ve derleme yetkisiz bir kullanıcıyla (varsayılan 'nobody'; geçici HOME/GRADLE_USER_HOME
# ile) yapılır — asla root ile değil. Root yalnız JDK paketini kurar/kaldırır ve sonucu, derleme
# kullanıcısının kimliğiyle okuyarak (sembolik bağ root yetkisiyle izlenmez) artifacts/ altına koyar.
#
# Ortam değişkenleri (çoğu yalnız test içindir):
#   LIBRELOGIN_REPO        (https://github.com/kyngs/LibreLogin)   LIBRELOGIN_BRANCH (dev)
#   LIBRELOGIN_BUILD_USER  (nobody) — root (uid 0) olamaz
#   MC_JVM_DIR             (/usr/lib/jvm)      ADOPTIUM_SOURCES (/etc/apt/sources.list.d/adoptium.sources)
#   TMPDIR                 (/var/tmp; derleme birkaç yüz MB yer ister)
set -Eeuo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

REPO_URL="${LIBRELOGIN_REPO:-https://github.com/kyngs/LibreLogin}"
BRANCH="${LIBRELOGIN_BRANCH:-dev}"
BUILD_USER="${LIBRELOGIN_BUILD_USER:-nobody}"
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
kullanıcısıyla (asla root değil) geçici bir dizinde yapılır; dizin sonunda silinir.
Sonraki adım: sudo mc download plugins velocity
EOF
}

# --- Temizlik -------------------------------------------------------------------
cleanup() {
    local rc=$?
    if [[ -n $WORK && -d $WORK ]]; then rm -rf -- "$WORK"; fi
    if ((JDK_INSTALLED_BY_US && !KEEP_JDK)) && pkg_installed "$JDK_PKG"; then
        log_info "Derleme için kurulan $JDK_PKG kaldırılıyor (tutmak için: --keep-jdk)..."
        "${APT_ENV[@]}" apt-get remove "${APT_OPTS[@]}" "$JDK_PKG" >/dev/null ||
            log_warn "$JDK_PKG kaldırılamadı; elle kaldırın: sudo apt-get remove $JDK_PKG"
    fi
    if ((JDK_INSTALLED_BY_US)); then restore_java_alternative; fi
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

# Derleme kullanıcısı var mı ve root değil mi? (Gradle asla root olarak çalıştırılmaz.)
check_build_user() {
    local uid
    uid=$(id -u -- "$BUILD_USER" 2>/dev/null) ||
        die "Derleme kullanıcısı yok: '$BUILD_USER' (LIBRELOGIN_BUILD_USER)."
    if ((uid == 0)); then
        die "Gradle root olarak ÇALIŞTIRILMAZ: LIBRELOGIN_BUILD_USER='$BUILD_USER' (uid 0). Derleme depodaki kodu çalıştırır; yetkisiz bir kullanıcı verin (varsayılan: nobody)."
    fi
}

# config/plugins.list'teki LibreLogin "local" satırı bu derlemenin jar'ını mı gösteriyor?
check_plugins_list() {
    local want=$1 list="$CONFIG_DIR/plugins.list" id
    local -a ids=()
    [[ -f $list ]] || return 0
    mapfile -t ids < <(awk '$1 !~ /^#/ && $2 == "LibreLogin" && $3 == "local" { print $4 }' "$list")
    if ((${#ids[@]} == 0)); then
        log_warn "config/plugins.list'te LibreLogin 'local' satırı yok: jar derlenir ama 'mc download' onu kurmaz."
        return 0
    fi
    for id in "${ids[@]}"; do
        [[ ${id##*/} != "$want" ]] || return 0
    done
    log_warn "config/plugins.list'teki LibreLogin satırı '${ids[0]}' gösteriyor; bu derleme $want üretir."
    log_warn "  Commit değişecekse network.env LIBRELOGIN_COMMIT ve plugins.list satırını BİRLİKTE güncelleyin."
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

# as_builder [-C <dizin>] <komut...> — derleme kullanıcısı olarak, temiz ortamla (env -i) çalıştırır.
as_builder() {
    local -a opts=(-i)
    if [[ ${1:-} == -C ]]; then
        opts+=(-C "$2")
        shift 2
    fi
    as_user "$BUILD_USER" env "${opts[@]}" "${BUILD_ENV[@]}" "$@"
}

prepare_workdir() {
    local gid
    gid=$(id -g -- "$BUILD_USER")
    WORK=$(mktemp -d "${TMPDIR:-/var/tmp}/kami-librelogin.XXXXXX") || die "Geçici dizin oluşturulamadı (${TMPDIR:-/var/tmp})."
    # Kök root'a ait (0755: derleme kullanıcısı geçebilsin); src/ ve home/ yalnız derleme kullanıcısının.
    chmod 0755 -- "$WORK"
    install -d -m 0700 -o "$BUILD_USER" -g "$gid" -- "$WORK/src" "$WORK/home"
    build_env
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
    as_builder -C "$WORK/src" ./gradlew --no-daemon build 2>&1 | tee "$WORK/build.log" || rc=$?
    if ((rc != 0)); then
        die "Gradle derlemesi başarısız (çıkış $rc). Yukarıdaki çıktıya bakın; bağımlılık depolarına (Maven Central, repo.papermc.io, repo.kyngs.xyz, services.gradle.org) erişim olmalı."
    fi
}

install_artifact() { # <hedef jar>
    local dst=$1 out=$WORK/src/$JAR_REL got sha name old=""
    name=${dst##*/}
    if [[ -L $out || ! -f $out ]]; then
        die "Derleme çıktısı yok ya da düzenli dosya değil: $JAR_REL (derleme betiği değişmiş olabilir)."
    fi
    got=$WORK/LibreLogin.jar
    # Çıktı derleme kullanıcısının dizininde: onun kimliğiyle oku (bağ root yetkisiyle izlenmez).
    as_user "$BUILD_USER" cat -- "$out" >"$got" || die "Derleme çıktısı okunamadı: $JAR_REL"
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

main() {
    local jar
    parse_args "$@"
    resolve_commit
    jar="$ARTIFACTS_DIR/LibreLogin-${COMMIT:0:7}.jar"
    check_build_user
    ((DRY_RUN)) || require_root
    log_info "LibreLogin: $REPO_URL @ $COMMIT ($COMMIT_FROM) → $jar"
    check_plugins_list "${jar##*/}"

    if ((DRY_RUN)); then
        log_info "Kuru çalıştırma: hiçbir şey kurulmayacak, indirilmeyecek ya da yazılmayacak."
        command -v git >/dev/null 2>&1 || log_warn "git kurulu değil (gerçek çalıştırmada gerekir: sudo apt-get install git)."
        ensure_jdk
        cat >&2 <<EOF
[kuru] geçici dizin: ${TMPDIR:-/var/tmp}/kami-librelogin.XXXXXX (root; src/ ve home/ $BUILD_USER kullanıcısının)
[kuru] git clone --branch $BRANCH --single-branch $REPO_URL <geçici>/src   (kullanıcı: $BUILD_USER)
[kuru] git checkout --detach $COMMIT
[kuru] ./gradlew --no-daemon build   (kullanıcı: $BUILD_USER, JAVA_HOME=$JAVA_HOME_25, HOME=<geçici>/home)
[kuru] $JAR_REL → $jar (0644 root) + ${jar##*/}.sha256
[kuru] geçici dizin silinir
[kuru] sonraki adım: sudo mc download plugins velocity
EOF
        return 0
    fi

    require_cmd git sha256sum install env tee
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ -d $MC_ROOT ]]; then
        local lockfd
        exec {lockfd}>>"$MC_ROOT/.build-librelogin.lock"
        flock -n "$lockfd" || die "Başka bir LibreLogin derlemesi sürüyor ($MC_ROOT/.build-librelogin.lock)."
    fi
    ensure_jdk
    prepare_workdir
    clone_and_checkout
    run_gradle
    install_artifact "$jar"
    cat <<EOF

Sonraki adım: sudo mc download plugins velocity
  (Velocity çalışıyorsa jar plugins/update/ altına iner; 'sudo mc restart velocity' ile devreye girer.)
Not: Bu bir geliştirme (SNAPSHOT) sürümüdür ve açılışta "DO NOT USE THIS IN PRODUCTION" yazar.
     Canlıya almadan önce giriş duman testini yapın (docs/08-giris-sistemi.md).
EOF
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
