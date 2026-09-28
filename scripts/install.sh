#!/usr/bin/env bash
# Sunucu makinesini hazırlar (root): paketler, Java 25, yq, minecraft kullanıcısı ve dizinleri,
# saat dilimi, çekirdek/journald/THP ayarları, swap, UFW, fail2ban, otomatik güncelleme ayarları,
# MariaDB, gizli değerler, systemd birimleri ve `mc` komutu.
# Tekrar tekrar çalıştırılabilir: var olan gizli değerlere ve yedek parolasına ASLA dokunmaz.
#
# Kullanım: sudo scripts/install.sh [--dry-run] [--java=temurin|openjdk] [--no-swap] [--harden-ssh]
set -Eeuo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

YQ_VERSION="v4.53.6"
YQ_SHA256="c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385" # yq_linux_amd64, sürüm sayfasındaki checksums ile doğrulandı
YQ_URL="https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_amd64"
ADOPTIUM_KEY_URL="https://packages.adoptium.net/artifactory/api/gpg/key/public"
ADOPTIUM_REPO_URL="https://packages.adoptium.net/artifactory/deb"
ADOPTIUM_KEYRING="/etc/apt/keyrings/adoptium.gpg"
ADOPTIUM_FPR="3B04D753C9050D9A5D343F39843C48A565F8F04B" # beklenen parmak izi (kaynağı doğrulanamadı: uyuşmazsa uyarı)
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
UNIT_DIR="/etc/systemd/system"
SWAPFILE="/swapfile"
# git: build-librelogin.sh (LibreLogin kaynaktan derlenir). backup.sh'in LibreLogin SQLite kopyası
# python3'ün standart sqlite3 modülüyle alınır (ayrı sqlite3 paketi gerekmez); mariadb-dump,
# mariadb-server'ın bağımlılığı mariadb-client'tan gelir; flock/setpriv/runuser util-linux'tadır.
APT_PACKAGES=(curl ca-certificates gnupg git jq ufw fail2ban python3 python3-systemd restic zstd
    mariadb-server sysstat unattended-upgrades)

DRY_RUN=0
JAVA_FLAVOR=temurin
NO_SWAP=0
HARDEN_SSH=0
FILE_CHANGED=0
OS_ID="" OS_VERSION="" OS_CODENAME=""

usage() {
    cat <<'EOF'
Kullanım: sudo scripts/install.sh [seçenekler]

  --dry-run          hiçbir şeyi değiştirmeden yapılacak her işlemi yazdırır
  --java=temurin     Java 25: Adoptium temurin-25-jre (varsayılan)
  --java=openjdk     Java 25: dağıtımın openjdk-25-jre paketi (Ubuntu 24.04)
  --no-swap          swap yoksa bile 2G swap dosyası oluşturma
  --harden-ssh       SSH'ta parola girişini kapat (yalnız sizin authorized_keys'inizde anahtar varsa)
  -h, --help         bu yardım

Desteklenen: Ubuntu 24.04, Debian 12/13 (x86_64). Tekrar çalıştırmak güvenlidir.
EOF
}

# --- Yardımcılar ------------------------------------------------------------
quote_cmd() {
    local a out=""
    for a in "$@"; do out+=" $(printf '%q' "$a")"; done
    printf '%s' "${out# }"
}

# run <komut...> — çalıştırır; --dry-run'da yalnızca yazdırır.
run() {
    if ((DRY_RUN)); then
        printf '[kuru] %s\n' "$(quote_cmd "$@")" >&2
        return 0
    fi
    "$@"
}

# sysd <systemctl argümanları...> — systemd yoksa (MC_NO_SYSTEMD=1) atlar.
sysd() {
    if [[ ${MC_NO_SYSTEMD:-0} == 1 ]]; then
        log_info "[atlandı: MC_NO_SYSTEMD] systemctl $*"
        return 0
    fi
    run systemctl "$@"
}

# install_file <kaynak> <hedef> [mod] — içerik farklıysa kurar. FILE_CHANGED=1/0.
install_file() {
    local src=$1 dst=$2 mode=${3:-0644}
    FILE_CHANGED=0
    [[ -f $src ]] || die "Depoda bulunamadı: $src"
    if [[ -f $dst ]] && cmp -s -- "$src" "$dst"; then
        return 0
    fi
    FILE_CHANGED=1
    run install -D -m "$mode" -o root -g root -- "$src" "$dst"
    ((DRY_RUN)) || log_ok "Kuruldu: $dst"
}

# write_file <hedef> <mod> — içerik stdin'den; farklıysa yazar. FILE_CHANGED=1/0.
write_file() {
    local dst=$1 mode=$2 tmp
    FILE_CHANGED=0
    tmp=$(mktemp)
    cat >"$tmp"
    if [[ -f $dst ]] && cmp -s -- "$tmp" "$dst"; then
        rm -f -- "$tmp"
        return 0
    fi
    FILE_CHANGED=1
    if ((DRY_RUN)); then
        printf '[kuru] yaz %s (%s):\n' "$dst" "$mode" >&2
        sed 's/^/[kuru]   | /' "$tmp" >&2
        rm -f -- "$tmp"
        return 0
    fi
    install -D -m "$mode" -o root -g root -- "$tmp" "$dst"
    rm -f -- "$tmp"
    log_ok "Yazıldı: $dst"
}

gen_hex() { # <bayt>
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$1"
    else
        python3 -c 'import secrets, sys; print(secrets.token_hex(int(sys.argv[1])))' "$1"
    fi
}

step() { printf '\n%s== %s ==%s\n' "$_C_BLU" "$*" "$_C_OFF" >&2; }

# --- Ön denetimler ----------------------------------------------------------
parse_args() {
    local a
    for a in "$@"; do
        case $a in
            --dry-run | -n) DRY_RUN=1 ;;
            --java=temurin) JAVA_FLAVOR=temurin ;;
            --java=openjdk) JAVA_FLAVOR=openjdk ;;
            --java=*) die "Geçersiz --java değeri: ${a#--java=} (temurin | openjdk)" ;;
            --no-swap) NO_SWAP=1 ;;
            --harden-ssh) HARDEN_SSH=1 ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) die "Bilinmeyen seçenek: $a (yardım: --help)" ;;
        esac
    done
}

os_field() { # <DEĞİŞKEN> — os-release'ten alt kabukta okur
    (
        # shellcheck disable=SC1090
        . "$OS_RELEASE_FILE"
        printf '%s' "${!1:-}"
    )
}

detect_os() {
    local arch
    [[ -r $OS_RELEASE_FILE ]] || die "Okunamadı: $OS_RELEASE_FILE"
    OS_ID=$(os_field ID)
    OS_VERSION=$(os_field VERSION_ID)
    OS_CODENAME=$(os_field VERSION_CODENAME)
    case "$OS_ID:$OS_VERSION" in
        ubuntu:24.04 | debian:12 | debian:13) ;;
        *) die "Desteklenmeyen sistem: $OS_ID $OS_VERSION (desteklenen: Ubuntu 24.04, Debian 12/13)" ;;
    esac
    [[ -n $OS_CODENAME ]] || die "$OS_RELEASE_FILE: VERSION_CODENAME yok."
    arch=$(uname -m)
    [[ $arch == x86_64 ]] || die "Desteklenmeyen mimari: $arch (yalnızca x86_64)"
    log_ok "Sistem: $OS_ID $OS_VERSION ($OS_CODENAME), $arch"
}

preflight() {
    if ((DRY_RUN)); then
        [[ ${EUID:-$(id -u)} -eq 0 ]] || log_warn "root değil: kuru çalıştırmada bazı denetimler eksik kalabilir."
        log_info "KURU ÇALIŞTIRMA: hiçbir şey değiştirilmeyecek, yapılacak işlemler [kuru] ile yazdırılır."
    else
        require_root
    fi
    detect_os
    if [[ $JAVA_FLAVOR == openjdk && $OS_ID:$OS_VERSION == debian:12 ]]; then
        die "Debian 12'de openjdk-25 paketi yok: --java=temurin kullanın."
    fi
    case $REPO_DIR in
        /root/* | /home/*)
            log_warn "Depo $REPO_DIR altında: systemd (ProtectHome) ve izinler nedeniyle önerilmez."
            log_warn "Önerilen konum: /opt/minecraft/kami (root sahibi, herkes okuyabilir)."
            ;;
    esac
    # Zamanlayıcılar depodaki betikleri root olarak çalıştırır: başkası yazabiliyorsa root'a yükselme yoludur.
    if [[ -n $(find "$REPO_DIR" "$REPO_DIR/scripts" -maxdepth 1 \( ! -user root -o -perm /022 \) -print -quit 2>/dev/null) ]]; then
        log_warn "Depo dizini/betikleri root dışındaki kullanıcılarca yazılabilir ya da root'a ait değil."
        log_warn "  Düzeltme: chown -R root:root $REPO_DIR && chmod -R go-w $REPO_DIR"
    fi
    if [[ $MC_ROOT != /opt/minecraft ]]; then
        log_warn "MC_ROOT=$MC_ROOT: systemd birimleri /opt/minecraft bekler (yalnızca test için değiştirin)."
    fi
    # Paper, çalışma dizini yolunda '!' ya da '+' varsa açılmaz (§16).
    if [[ $SERVERS_DIR == *['!+']* ]]; then
        die "Sunucu dizini yolu '!' ya da '+' içeriyor: $SERVERS_DIR (Paper bu yolda açılmaz; MC_ROOT'u değiştirin)."
    fi
    [[ -d $REPO_DIR/systemd && -d $REPO_DIR/host ]] || die "Depo eksik: $REPO_DIR/systemd ve $REPO_DIR/host gerekli."
    if ((HARDEN_SSH)); then check_ssh_keys; fi # kurulumun sonunda değil, başta reddet
}

# --- Paketler ---------------------------------------------------------------
APT_ENV=(env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l)
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

install_packages() {
    step "Paketler"
    run "${APT_ENV[@]}" apt-get update -q
    run "${APT_ENV[@]}" apt-get install "${APT_OPTS[@]}" "${APT_PACKAGES[@]}"
    # sysstat geçmişi (sar): steal/CPU sorunlarını sonradan incelemek için
    if [[ -f /etc/default/sysstat ]] && grep -q '^ENABLED="false"' /etc/default/sysstat; then
        run sed -i 's/^ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
    fi
    sysd enable --now sysstat || log_warn "sysstat etkinleştirilemedi."
}

# --- Java 25 ----------------------------------------------------------------
# java_version_ok <java.version> — ≥25 ve ön sürüm (içinde '-') değil
java_version_ok() {
    local v=$1 major
    [[ -n $v && $v != *-* ]] || return 1
    major=${v%%.*}
    [[ $major =~ ^[0-9]+$ ]] && ((major >= 25))
}

java_version_of() { # <java yolu>
    "$1" -XshowSettings:properties -version 2>&1 | awk '$1 == "java.version" && $2 == "=" { print $3; exit }'
}

install_adoptium_repo() {
    local tmpd fpr
    run install -d -m 0755 /etc/apt/keyrings
    if [[ ! -s $ADOPTIUM_KEYRING ]]; then
        if ((DRY_RUN)); then
            printf '[kuru] curl %s | gpg --dearmor > %s\n' "$ADOPTIUM_KEY_URL" "$ADOPTIUM_KEYRING" >&2
        else
            tmpd=$(mktemp -d)
            curl -fsSL --retry 3 --connect-timeout 15 -o "$tmpd/key.asc" "$ADOPTIUM_KEY_URL" ||
                { rm -rf -- "$tmpd"; die "Adoptium anahtarı indirilemedi."; }
            gpg --batch --dearmor <"$tmpd/key.asc" >"$tmpd/adoptium.gpg"
            fpr=$(GNUPGHOME="$tmpd" gpg --batch --show-keys --with-colons "$tmpd/adoptium.gpg" 2>/dev/null |
                awk -F: '$1 == "fpr" { print $10; exit }')
            if [[ $fpr != "$ADOPTIUM_FPR" ]]; then
                log_warn "Adoptium anahtar parmak izi beklenenden farklı: '${fpr:-okunamadı}' (beklenen $ADOPTIUM_FPR)."
                log_warn "  https://adoptium.net/installation/linux/ adresinden doğrulayın."
            fi
            install -m 0644 -o root -g root -- "$tmpd/adoptium.gpg" "$ADOPTIUM_KEYRING"
            rm -rf -- "$tmpd"
            log_ok "Adoptium anahtarı kuruldu: $ADOPTIUM_KEYRING"
        fi
    fi
    write_file /etc/apt/sources.list.d/adoptium.sources 0644 <<EOF
Types: deb
URIs: $ADOPTIUM_REPO_URL
Suites: $OS_CODENAME
Components: main
Signed-By: $ADOPTIUM_KEYRING
EOF
    if ((FILE_CHANGED)) || [[ ! -f /var/lib/apt/lists/packages.adoptium.net_artifactory_deb_dists_${OS_CODENAME}_InRelease ]]; then
        run "${APT_ENV[@]}" apt-get update -q
    fi
}

install_java() {
    local pkg pattern cand ver
    step "Java 25 ($JAVA_FLAVOR)"
    if [[ $JAVA_FLAVOR == temurin ]]; then
        install_adoptium_repo
        pkg=temurin-25-jre
        pattern='/temurin-25[^/]*/bin/java$'
    else
        [[ $OS_ID == ubuntu ]] || log_warn "openjdk-25-jre yalnız Ubuntu 24.04'te denendi; $OS_ID $OS_VERSION için doğrulanmadı."
        pkg=openjdk-25-jre # headless DEĞİL (PaperMC önerisi)
        pattern='/java-25-openjdk[^/]*/bin/java$'
    fi
    run "${APT_ENV[@]}" apt-get install "${APT_OPTS[@]}" "$pkg"

    # /usr/bin/java → Java 25 (systemd birimi ExecStart=/usr/bin/java)
    cand=$(update-alternatives --list java 2>/dev/null | grep -E "$pattern" | head -n1 || true)
    if [[ -z $cand ]]; then
        # Paket alternatif kaydetmediyse JVM dizininden bul ve kaydet
        cand=$(compgen -G '/usr/lib/jvm/*/bin/java' | grep -E "$pattern" | head -n1 || true)
        if [[ -n $cand ]]; then
            run update-alternatives --install /usr/bin/java java "$cand" 2500
        fi
    fi
    if [[ -z $cand ]]; then
        ((DRY_RUN)) || die "update-alternatives'te Java 25 bulunamadı ($pkg kuruldu mu?)."
        printf '[kuru] update-alternatives --set java <%s java yolu>\n' "$pkg" >&2
    elif [[ $(readlink -f /usr/bin/java 2>/dev/null) != "$(readlink -f "$cand")" ]]; then
        run update-alternatives --set java "$cand"
    fi

    if [[ -x /usr/bin/java ]]; then
        ver=$(java_version_of /usr/bin/java)
        if java_version_ok "$ver"; then
            log_ok "/usr/bin/java → java.version = $ver"
            [[ ${ver%%.*} == 25 ]] || log_warn "Java $ver: önerilen sürüm 25 (LTS)."
        elif ((DRY_RUN)); then
            log_warn "/usr/bin/java şu an '$ver' (kurulumdan sonra 25 olmalı)."
        else
            die "/usr/bin/java uygun değil: java.version='$ver' (≥25 ve '-' içermemeli; Paper EA sürümlerde açılmaz)."
        fi
    elif ((DRY_RUN == 0)); then
        die "/usr/bin/java yok."
    fi
}

# --- yq (mikefarah) ---------------------------------------------------------
install_yq() {
    local tmp
    step "yq $YQ_VERSION"
    if [[ -x /usr/local/bin/yq ]] && /usr/local/bin/yq --version 2>/dev/null | grep -q "mikefarah.*version $YQ_VERSION\$"; then
        log_ok "yq $YQ_VERSION zaten kurulu."
    elif ((DRY_RUN)); then
        printf '[kuru] curl %s → sha256 %s → /usr/local/bin/yq\n' "$YQ_URL" "$YQ_SHA256" >&2
    else
        tmp=$(mktemp)
        curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp" "$YQ_URL" || { rm -f -- "$tmp"; die "yq indirilemedi."; }
        if ! printf '%s  %s\n' "$YQ_SHA256" "$tmp" | sha256sum -c --quiet -; then
            rm -f -- "$tmp"
            die "yq SHA-256 uyuşmuyor — kurulmadı."
        fi
        install -m 0755 -o root -g root -- "$tmp" /usr/local/bin/yq
        rm -f -- "$tmp"
        log_ok "yq kuruldu: /usr/local/bin/yq"
    fi
    if [[ $(command -v yq 2>/dev/null) != /usr/local/bin/yq ]]; then
        log_warn "PATH'te önce başka bir yq var ($(command -v yq 2>/dev/null)); betikler YQ=/usr/local/bin/yq ile çalıştırılmalı."
    fi
}

# --- Kullanıcı, dizinler, saat ---------------------------------------------
setup_user_dirs() {
    step "Kullanıcı ve dizinler"
    getent group "$MC_USER" >/dev/null || run groupadd --system "$MC_USER"
    if ! id -u "$MC_USER" >/dev/null 2>&1; then
        run useradd --system --gid "$MC_USER" --home-dir "$MC_ROOT" --no-create-home \
            --shell /usr/sbin/nologin --comment "Minecraft sunuculari" "$MC_USER"
    fi
    run install -d -m 0755 -o root -g root "$MC_ROOT"
    run install -d -m 0750 -o "$MC_USER" -g "$MC_USER" "$SERVERS_DIR"
    # Yerelde derlenen eklentiler (plugins.list "local" kaynağı, ör. LibreLogin): yalnız root yazar.
    run install -d -m 0755 -o root -g root "$MC_ROOT/artifacts"
}

setup_timezone() {
    local tz current
    tz=${TIMEZONE:-Europe/Istanbul}
    step "Saat dilimi ($tz)"
    [[ -f /usr/share/zoneinfo/$tz ]] || die "Bilinmeyen saat dilimi: $tz"
    current=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    [[ -n $current ]] || current=$(cat /etc/timezone 2>/dev/null || true)
    if [[ $current == "$tz" ]]; then
        log_ok "Saat dilimi zaten $tz."
    elif [[ ${MC_NO_SYSTEMD:-0} != 1 ]] && run timedatectl set-timezone "$tz"; then
        ((DRY_RUN)) || log_ok "Saat dilimi: $tz"
    else
        run ln -sfn "/usr/share/zoneinfo/$tz" /etc/localtime
        printf '%s\n' "$tz" | write_file /etc/timezone 0644
    fi
    if [[ ${MC_NO_SYSTEMD:-0} != 1 && $(timedatectl show -p NTP --value 2>/dev/null || true) == no ]]; then
        run timedatectl set-ntp true || log_warn "Saat eşitleme (NTP) açılamadı; zaman kayması yedek/zamanlayıcıları etkiler."
    fi
}

# --- Host ayarları ----------------------------------------------------------
setup_host_files() {
    local h=$REPO_DIR/host
    step "Çekirdek, journald, THP, otomatik güncelleme"
    install_file "$h/sysctl-99-minecraft.conf" /etc/sysctl.d/99-minecraft.conf
    if ((FILE_CHANGED)); then
        run sysctl --system >/dev/null || log_warn "Bazı sysctl ayarları uygulanamadı (ör. bbr modülü yok); diğerleri geçerli."
    fi
    install_file "$h/journald-minecraft.conf" /etc/systemd/journald.conf.d/minecraft.conf
    if ((FILE_CHANGED)); then sysd restart systemd-journald || log_warn "journald yeniden başlatılamadı."; fi
    install_file "$h/thp-tmpfiles.conf" /etc/tmpfiles.d/minecraft-thp.conf
    if ((FILE_CHANGED)); then
        run systemd-tmpfiles --create /etc/tmpfiles.d/minecraft-thp.conf || log_warn "THP ayarı şimdi uygulanamadı (açılışta uygulanır)."
    fi
    install_file "$h/needrestart-minecraft.conf" /etc/needrestart/conf.d/minecraft.conf
    install_file "$h/unattended-upgrades-minecraft" /etc/apt/apt.conf.d/52unattended-upgrades-minecraft
}

setup_swap() {
    local fstype avail_mb
    step "Swap"
    if ((NO_SWAP)); then
        log_info "--no-swap: atlandı."
        return 0
    fi
    if [[ -n $(swapon --show --noheadings 2>/dev/null) ]]; then
        log_ok "Swap zaten var: $(swapon --show --noheadings | awk '{print $1 " " $3}' | paste -sd' ')"
        return 0
    fi
    if [[ ! -f $SWAPFILE ]]; then
        fstype=$(stat -f -c %T / 2>/dev/null || true)
        [[ $fstype != btrfs ]] || { log_warn "Kök dosya sistemi btrfs: swap dosyası elle kurulmalı; atlandı."; return 0; }
        avail_mb=$(df --output=avail -BM / | tail -n1 | tr -dc '0-9')
        if ((avail_mb < 4096)); then
            log_warn "Diskte yeterli yer yok (${avail_mb} MB); swap oluşturulmadı."
            return 0
        fi
        run fallocate -l 2G "$SWAPFILE" || run dd if=/dev/zero of="$SWAPFILE" bs=1M count=2048 status=none
        run chmod 0600 "$SWAPFILE"
        run mkswap "$SWAPFILE" >/dev/null
    fi
    run swapon "$SWAPFILE" || { log_warn "swapon başarısız ($SWAPFILE)."; return 0; }
    if ! grep -qE "^[[:space:]]*${SWAPFILE}[[:space:]]" /etc/fstab; then
        if ((DRY_RUN)); then
            printf '[kuru] /etc/fstab sonuna: %s none swap sw 0 0\n' "$SWAPFILE" >&2
        else
            printf '%s none swap sw 0 0\n' "$SWAPFILE" >>/etc/fstab
        fi
    fi
    ((DRY_RUN)) || log_ok "2G swap etkin (vm.swappiness=1: yalnız OOM'a karşı emniyet)."
}

# SSH portları: sshd -T + ssh.socket dinleme adresleri + mevcut oturum. Hiçbiri yoksa 22.
detect_ssh_ports() {
    local -a ports=()
    local p out
    if command -v sshd >/dev/null 2>&1; then
        out=$(sshd -T 2>/dev/null || true)
        if [[ -z $out && ! -d /run/sshd && $DRY_RUN == 0 ]]; then
            install -d -m 0755 /run/sshd # Ubuntu'da soket etkinleştirmede sshd -T bu dizini ister
            out=$(sshd -T 2>/dev/null || true)
        fi
        mapfile -t -O "${#ports[@]}" ports < <(awk '$1 == "port" { print $2 }' <<<"$out")
    fi
    if [[ ${MC_NO_SYSTEMD:-0} != 1 ]] && command -v systemctl >/dev/null 2>&1; then
        out=$(systemctl show -p Listen --value ssh.socket 2>/dev/null || true)
        mapfile -t -O "${#ports[@]}" ports < <(grep -oE ':[0-9]+ ' <<<"$out" | tr -dc '0-9\n')
    fi
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        ports+=("$(awk '{ print $4 }' <<<"$SSH_CONNECTION")")
    fi
    for p in "${ports[@]}"; do
        if [[ $p =~ ^[0-9]+$ ]] && ((p > 0 && p < 65536)); then printf '%s\n' "$p"; fi
    done | sort -un | { grep . || echo 22; }
}

setup_firewall() {
    local -a ssh_ports=()
    local p
    step "Güvenlik duvarı (UFW)"
    mapfile -t ssh_ports < <(detect_ssh_ports)
    log_info "SSH portu/portları: ${ssh_ports[*]}"
    run ufw default deny incoming
    run ufw default allow outgoing
    # Kilitlenmemek için SSH kuralı UFW etkinleştirilmeden ÖNCE eklenir.
    for p in "${ssh_ports[@]}"; do
        run ufw limit "$p/tcp" comment 'SSH'
    done
    run ufw allow "${PUBLIC_JAVA_PORT:-25565}/tcp" comment 'Minecraft Java (Velocity)'
    run ufw allow "${PUBLIC_BEDROCK_PORT:-19132}/udp" comment 'Minecraft Bedrock (Geyser)'
    run ufw --force enable
    ((DRY_RUN)) || log_ok "UFW etkin: SSH (${ssh_ports[*]}), ${PUBLIC_JAVA_PORT:-25565}/tcp, ${PUBLIC_BEDROCK_PORT:-19132}/udp"
}

# Ayarlarımız jail.d/minecraft.conf'a gider: yöneticinin jail.local'ına ve eklediği hapislere dokunulmaz,
# jail.local'daki değerler (ör. ignoreip) bizimkileri geçersiz kılar (fail2ban .conf'tan sonra .local okur).
F2B_CONF=/etc/fail2ban/jail.d/minecraft.conf
setup_fail2ban() {
    step "fail2ban"
    install_file "$REPO_DIR/host/fail2ban-jail.local" "$F2B_CONF"
    if [[ -f /etc/fail2ban/jail.local ]] && grep -q '^# Kurulum yeri: /etc/fail2ban/jail.local' /etc/fail2ban/jail.local; then
        log_warn "/etc/fail2ban/jail.local önceki bir kami kurulumundan kalmış; ayarlar artık $F2B_CONF içinde."
        log_warn "  Kendi değişikliğiniz yoksa silin: rm /etc/fail2ban/jail.local && systemctl restart fail2ban"
    fi
    sysd enable --now fail2ban
    if ((FILE_CHANGED)); then sysd restart fail2ban; fi
}

# --- Gizli değerler (§11) ---------------------------------------------------
# write_secret_file <hedef> — içerik stdin'den; yalnız dosya YOKSA yazar (root:root 0600).
write_secret_file() {
    local dst=$1 tmp
    if [[ -e $dst ]]; then
        cat >/dev/null
        log_ok "Var, dokunulmadı: $dst"
        [[ $(stat -c %a "$dst") == 600 ]] || log_warn "$dst izinleri $(stat -c %a "$dst"); 0600 olmalı (chmod 600 $dst)."
        return 0
    fi
    if ((DRY_RUN)); then
        cat >/dev/null
        printf '[kuru] oluştur %s (root:root 0600; değerler gizli)\n' "$dst" >&2
        return 0
    fi
    tmp=$(umask 077 && mktemp "$dst.XXXXXX")
    cat >"$tmp"
    chown root:root -- "$tmp"
    chmod 0600 -- "$tmp"
    mv -f -- "$tmp" "$dst"
    log_ok "Oluşturuldu: $dst"
}

setup_secrets() {
    local fwd
    step "Gizli değerler ($MC_ETC)"
    run install -d -m 0750 -o root -g root "$MC_ETC"
    fwd=$(gen_hex 32)
    write_secret_file "$SECRETS_FILE" <<EOF
# install.sh tarafından üretildi ($(date +%F)). Git'e EKLEMEYİN.
# Değiştirirseniz: mc apply all + yeniden başlatma. DB_PASSWORD değişirse install.sh'i yeniden
# çalıştırın (MariaDB kullanıcı parolasını eşitler).
VELOCITY_FORWARDING_SECRET='$fwd'
PAPER_VELOCITY_SECRET='$fwd'
RCON_PASSWORD='$(gen_hex 24)'
DB_PASSWORD='$(gen_hex 24)'
EOF
    gen_hex 32 | write_secret_file "$MC_ETC/restic.pass"
    write_secret_file "$BACKUP_ENV_FILE" <<EOF
# restic yedek deposu (backup.sh okur). Git'e EKLEMEYİN.
#
# VARSAYILAN YEREL DEPO makine kaybına karşı KORUMAZ. Uzak depo örnekleri:
#   S3 uyumlu (Backblaze B2 S3, Cloudflare R2, Hetzner, MinIO):
#     RESTIC_REPOSITORY=s3:https://s3.eu-central-003.backblazeb2.com/kova-adi/minecraft
#     AWS_ACCESS_KEY_ID=...
#     AWS_SECRET_ACCESS_KEY=...
#   Backblaze B2 (yerel API):
#     RESTIC_REPOSITORY=b2:kova-adi:minecraft
#     B2_ACCOUNT_ID=...
#     B2_ACCOUNT_KEY=...
#   SFTP:
#     RESTIC_REPOSITORY=sftp:yedek@yedek.example.com:/srv/restic/minecraft
#   rest-server (--append-only önerilir):
#     RESTIC_REPOSITORY=rest:https://kullanici:parola@yedek.example.com:8000/minecraft
#
# restic.pass dosyasının bir kopyasını makine DIŞINDA saklayın: parola yoksa yedek açılamaz.
RESTIC_REPOSITORY=/var/backups/minecraft/restic
RESTIC_PASSWORD_FILE=$MC_ETC/restic.pass
BACKUP_HOST=mc01
EOF
}

# --- MariaDB ----------------------------------------------------------------
sql_str() { # SQL tek tırnak içi kaçış
    local s=${1//\\/\\\\}
    printf '%s' "${s//\'/\'\'}"
}

build_db_sql() { # <kullanıcı> <parola> <veritabanları...>
    local user=$1 pw host db
    pw=$(sql_str "$2")
    shift 2
    for host in localhost 127.0.0.1; do
        printf "CREATE USER IF NOT EXISTS '%s'@'%s' IDENTIFIED BY '%s';\n" "$user" "$host" "$pw"
        printf "ALTER USER '%s'@'%s' IDENTIFIED BY '%s';\n" "$user" "$host" "$pw"
    done
    for db in "$@"; do
        # shellcheck disable=SC2016  # ters tırnaklar SQL tanımlayıcı alıntısıdır, kabuk genişletmesi değil
        printf 'CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' "$db"
        for host in localhost 127.0.0.1; do
            printf "GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%s';\n" "$db" "$user" "$host"
        done
    done
    printf 'FLUSH PRIVILEGES;\n'
}

setup_mariadb() {
    local user db pw list
    local -a dbs=()
    step "MariaDB"
    install_file "$REPO_DIR/host/mariadb-minecraft.cnf" /etc/mysql/mariadb.conf.d/60-minecraft.cnf
    sysd enable --now mariadb
    if ((FILE_CHANGED)); then sysd restart mariadb; fi

    user=${DB_USER:-minecraft}
    [[ $user =~ ^[A-Za-z0-9_]{1,32}$ ]] || die "network.env: geçersiz DB_USER '$user'"
    list=${DB_DATABASES:-luckperms}
    read -r -a dbs <<<"${list//,/ }"
    ((${#dbs[@]} > 0)) || dbs=(luckperms)
    for db in "${dbs[@]}"; do
        [[ $db =~ ^[A-Za-z0-9_]{1,64}$ ]] || die "network.env: geçersiz veritabanı adı '$db'"
    done

    if [[ -r $SECRETS_FILE ]]; then
        # shellcheck disable=SC1090
        pw=$(. "$SECRETS_FILE" && printf '%s' "${DB_PASSWORD:-}")
    else
        pw=""
    fi
    if ((DRY_RUN)); then
        printf '[kuru] mariadb --protocol=socket -u root  (stdin, parola gizli):\n' >&2
        build_db_sql "$user" '********' "${dbs[@]}" | sed 's/^/[kuru]   | /' >&2
        return 0
    fi
    [[ -n $pw ]] || die "$SECRETS_FILE: DB_PASSWORD yok."
    # Parola komut satırında değil stdin'de: ps çıktısında görünmez.
    build_db_sql "$user" "$pw" "${dbs[@]}" | mariadb --protocol=socket -u root ||
        die "MariaDB kullanıcı/veritabanı oluşturulamadı (mariadb çalışıyor mu?)."
    log_ok "MariaDB: '$user'@localhost ve @127.0.0.1, veritabanları: ${dbs[*]}"
}

# --- systemd ve mc komutu --------------------------------------------------
setup_systemd() {
    local f changed=0 s
    local -a servers=()
    step "systemd birimleri"
    for f in "$REPO_DIR"/systemd/*.service "$REPO_DIR"/systemd/*.socket "$REPO_DIR"/systemd/*.timer; do
        [[ -f $f ]] || continue
        install_file "$f" "$UNIT_DIR/${f##*/}" 0644
        if ((FILE_CHANGED)); then changed=1; fi
    done
    if ((changed)); then sysd daemon-reload; fi
    sysd enable --now mc-backup.timer mc-prune.timer mc-daily-restart.timer

    # Sunucular config/servers/*/server.env'den (velocity, limbo, lobby, survival ve mc new-server
    # ile eklenenler). Yalnız etkinleştirilir (açılışta başlar); ilk başlatma `mc init` ile yapılır.
    if [[ -d $CONFIG_DIR/servers ]]; then
        mapfile -t servers < <(list_servers)
    fi
    if ((${#servers[@]} == 0)); then
        log_warn "$CONFIG_DIR/servers/*/server.env bulunamadı: hiçbir mc@ birimi etkinleştirilmedi."
    fi
    for s in "${servers[@]}"; do
        sysd enable "$(unit_of "$s")"
    done
}

setup_mc_command() {
    local f
    step "mc komutu"
    for f in "$SCRIPTS_DIR"/mc "$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/rcon.py; do
        if [[ -f $f && ! -x $f && $f != */lib.sh ]]; then run chmod 0755 "$f"; fi
    done
    [[ -f $SCRIPTS_DIR/mc ]] || log_warn "$SCRIPTS_DIR/mc bulunamadı; bağlantı yine de kuruluyor."
    if [[ $(readlink /usr/local/bin/mc 2>/dev/null) != "$SCRIPTS_DIR/mc" ]]; then
        run ln -sfn "$SCRIPTS_DIR/mc" /usr/local/bin/mc
    fi
    ((DRY_RUN)) || log_ok "/usr/local/bin/mc → $SCRIPTS_DIR/mc"
}

# --- SSH sertleştirme (isteğe bağlı) ---------------------------------------
has_authorized_key() { # <kullanıcı>
    local home
    home=$(getent passwd "$1" | cut -d: -f6)
    [[ -n $home && -r $home/.ssh/authorized_keys ]] &&
        grep -qE '^[^#]*(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp[0-9]+|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) AAAA' \
            "$home/.ssh/authorized_keys"
}

# Parola girişi kapanmadan önce, betiği çalıştıran yöneticinin KENDİ anahtarı olmalı: sudo ile
# çalıştırıldıysa SUDO_USER, değilse root; oturumun giriş kullanıcısı (logname, ör. su ile) da.
# Başka bir hesabın (ör. sağlayıcının root'a koyduğu) anahtarı yetmez.
check_ssh_keys() {
    local u login
    local -a users=() missing=()
    if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then users+=("$SUDO_USER"); else users+=(root); fi
    login=$(logname 2>/dev/null || true)
    if [[ -n $login && $login != root && $login != "${users[0]}" ]]; then users+=("$login"); fi
    for u in "${users[@]}"; do
        if has_authorized_key "$u"; then
            log_ok "SSH anahtarı bulundu: $u"
        else
            missing+=("$u")
        fi
    done
    ((${#missing[@]} == 0)) ||
        die "--harden-ssh reddedildi: ${missing[*]} için authorized_keys'te anahtar yok (parola girişi kapanınca kilitlenirsiniz). Önce anahtarınızı ekleyip anahtarla girebildiğinizi doğrulayın."
}

harden_ssh() {
    local conf=/etc/ssh/sshd_config.d/00-kami-hardening.conf
    step "SSH sertleştirme"
    check_ssh_keys
    grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config ||
        log_warn "/etc/ssh/sshd_config, sshd_config.d/*.conf dosyalarını içermiyor; ayar etkisiz kalabilir."
    # sshd ilk okuduğu değeri kullanır: 00- öneki cloud-init'in 50-cloud-init.conf'unu geçersiz kılar.
    write_file "$conf" 0644 <<'EOF'
# install.sh --harden-ssh (kami)
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
EOF
    ((FILE_CHANGED)) || { log_ok "SSH sertleştirme zaten uygulanmış."; return 0; }
    if ((DRY_RUN == 0)) && ! sshd -t; then
        rm -f -- "$conf"
        die "sshd -t başarısız; sertleştirme geri alındı."
    fi
    sysd reload ssh || sysd reload sshd || log_warn "SSH yeniden yüklenemedi; bir sonraki yeniden başlatmada geçerli olur."
}

final_message() {
    local jdk_note=""
    if [[ $JAVA_FLAVOR == openjdk ]]; then
        jdk_note="
     (--java=openjdk: Adoptium deposu kurulmadı; önce JDK 25 kurun: sudo apt-get install openjdk-25-jdk-headless)"
    fi
    cat >&2 <<EOF

${_C_GRN}Kurulum tamam.${_C_OFF} Sonraki adımlar (sırayla):
  1) (isteğe bağlı) Ayarları gözden geçirin: $CONFIG_DIR/network.env, $CONFIG_DIR/servers/*/server.env,
     $CONFIG_DIR/plugins.list
  2) sudo mc build-librelogin         # LibreLogin jar'ı (giriş eklentisi) kaynaktan derlenir → $MC_ROOT/artifacts/${jdk_note}
  3) sudo mc download all             # Paper/Velocity/PicoLimbo + eklentiler (SHA doğrulamalı)
  4) sudo mc init all --accept-eula   # ilk açılış + config uygulama (Minecraft EULA'yı kabul edersiniz)
  5) sudo mc start all                # ardından: mc status
  6) sudo mc doctor                   # sağlık denetimi (RAM, swap, steal, UFW, yedek...)

Yedek: saatlik yedek ve günlük budama zamanlayıcıları etkin.
  - $BACKUP_ENV_FILE içinde UZAK bir restic deposu tanımlayın (varsayılan yerel depo makine kaybına karşı korumaz).
  - $MC_ETC/restic.pass dosyasını makine DIŞINDA saklayın: parola kaybı = yedek kaybı.
Günlük 05:00 yeniden başlatma etkin; kapatmak için: systemctl disable --now mc-daily-restart.timer
EOF
    ((HARDEN_SSH)) || printf '%s\n' "SSH parola girişini kapatmak için (anahtarınız varsa): sudo $SCRIPTS_DIR/install.sh --harden-ssh" >&2
}

main() {
    parse_args "$@"
    preflight
    if [[ -f $CONFIG_DIR/network.env ]]; then
        load_network_env
    else
        log_warn "$CONFIG_DIR/network.env yok; varsayılanlar kullanılıyor."
    fi
    install_packages
    install_java
    install_yq
    setup_user_dirs
    setup_timezone
    setup_host_files
    setup_swap
    setup_firewall
    setup_fail2ban
    setup_secrets
    setup_mariadb
    setup_systemd
    setup_mc_command
    if ((HARDEN_SSH)); then harden_ssh; fi
    final_message
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
