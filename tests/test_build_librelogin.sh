#!/usr/bin/env bash
# scripts/build-librelogin.sh testleri — ağ KULLANMAZ.
#  1) argümanlar ve commit doğrulaması (7-40 onaltılık hane)
#  2) jar adı: config/network.env LIBRELOGIN_COMMIT ↔ config/plugins.list LibreLogin satırı (birlikte değişir)
#  3) --dry-run: hiçbir şey kurulmaz/yazılmaz; plan yazdırılır
#  4) Gradle asla root olarak çalıştırılmaz
#  5) Uçtan uca (root + nobody): gerçek LibreLogin deposu yerine yerel git deposu (sahte gradlew),
#     JDK 25 ve apt/dpkg-query/update-alternatives PATH'e konan sahte komutlarla taklit edilir.
# Çalıştırma: bash tests/test_build_librelogin.sh
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(dirname "$HERE")"

PASS=0 FAIL=0
T=$(mktemp -d "${TMPDIR:-/tmp}/kami-bl-test.XXXXXX")
trap 'rm -rf -- "$T"' EXIT
chmod 0755 "$T" # derleme kullanıcısı (nobody) yerel depoya ve geçici dizine erişebilsin

ok() {
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
}
nok() {
    FAIL=$((FAIL + 1))
    printf '  HATA  %s\n' "$1"
    if [[ -n ${2:-} ]]; then printf '%s\n' "$2" | sed 's/^/        | /'; fi
}
check() {
    local d=$1
    shift
    if "$@"; then ok "$d"; else nok "$d" "${OUT:-}"; fi
}
eq() {
    if [[ $1 == "$2" ]]; then return 0; fi
    printf '        beklenen: %q\n        gelen:    %q\n' "$2" "$1"
    return 1
}
out_has() { grep -qF -- "$1" <<<"$OUT"; }
out_lacks() { ! grep -qF -- "$1" <<<"$OUT"; }
empty_dir() { [[ -z $(find "$1" -mindepth 1 -print -quit 2>/dev/null) ]]; }

# --- Sandbox -------------------------------------------------------------------
REPO="$T/repo"
mkdir -p "$REPO/scripts" "$T/root" "$T/tmp" "$T/bin" "$T/state" "$T/jvm"
cp "$ROOT/scripts/lib.sh" "$ROOT/scripts/build-librelogin.sh" "$ROOT/scripts/download.sh" "$REPO/scripts/"
cp -R "$ROOT/config" "$REPO/config"
chmod -R a+rX "$T"
export MC_ROOT="$T/root" MC_ETC="$T/etc" MC_RUN_DIR="$T/run" MC_NO_SYSTEMD=1
export TMPDIR="$T/tmp" MC_JVM_DIR="$T/jvm" ADOPTIUM_SOURCES="$T/adoptium.sources"
export PATH="$T/bin:$PATH" FAKE="$T/state"
unset LIBRELOGIN_REPO LIBRELOGIN_BRANCH LIBRELOGIN_BUILD_USER

# mkjdk <dizin> <javac sürümü> — sahte JDK (bin/javac -version, bin/java)
mkjdk() {
    mkdir -p "$1/bin"
    printf '#!/bin/sh\necho "javac %s"\n' "$2" >"$1/bin/javac"
    printf '#!/bin/sh\necho "java %s"\n' "$2" >"$1/bin/java"
    chmod 0755 "$1/bin/javac" "$1/bin/java"
}
mkjdk "$T/jvm/jdk-25" 25.0.1

# Sahte apt-get/dpkg-query/update-alternatives: çağrıları $FAKE/apt.log'a yazar; "install
# temurin-25-jdk" $MC_JVM_DIR/temurin-25-jdk-amd64 altına sahte JDK koyar, "remove" siler.
cat >"$T/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >>"$FAKE/apt.log"
for a in "$@"; do
    case $a in install) op=install ;; remove) op=remove ;; update) op=update ;; esac
done
# apt-fail: kurulum (ağ/depo hatası gibi) başarısız olur
[[ ! -e $FAKE/apt-fail || ${op:-} != install ]] || exit 100
if [[ " $* " == *" temurin-25-jdk "* || " $* " == *" temurin-25-jdk" ]]; then
    d=$MC_JVM_DIR/temurin-25-jdk-amd64
    case ${op:-} in
        install)
            mkdir -p "$d/bin"
            printf '#!/bin/sh\necho "javac 25.0.2"\n' >"$d/bin/javac"
            printf '#!/bin/sh\necho "java 25.0.2"\n' >"$d/bin/java"
            chmod 0755 "$d/bin/javac" "$d/bin/java"
            : >"$FAKE/jdk-installed" ;;
        remove) rm -rf -- "$d" "$FAKE/jdk-installed" ;;
    esac
fi
exit 0
EOF
cat >"$T/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
[[ -e $FAKE/jdk-installed ]] || exit 1
printf 'install ok installed'
EOF
cat >"$T/bin/update-alternatives" <<'EOF'
#!/usr/bin/env bash
printf 'update-alternatives %s\n' "$*" >>"$FAKE/apt.log"
if [[ $1 == --query ]]; then printf 'Name: java\nValue: /usr/lib/jvm/temurin-25-jre-amd64/bin/java\n'; fi
exit 0
EOF
chmod 0755 "$T/bin/apt-get" "$T/bin/dpkg-query" "$T/bin/update-alternatives"
: >"$FAKE/apt.log"

bl() { # çıktı: $OUT, dönüş: $RC
    RC=0
    OUT=$(bash "$REPO/scripts/build-librelogin.sh" "$@" 2>&1) || RC=$?
}
apt_calls() { grep '^apt-get' "$FAKE/apt.log" | sed 's/ -y -q -o DPkg::Lock::Timeout=300//' | paste -sd'|' - || true; }

C7_CFG=$(bash -c '. "$1"; printf "%s" "${LIBRELOGIN_COMMIT:0:7}"' _ "$ROOT/config/network.env")

# -----------------------------------------------------------------------------
echo "# yardım ve argüman/commit doğrulaması"
bl --help
check "--help çıkış 0" eq "$RC" 0
check "--help Türkçe kullanım" out_has "Kullanım: sudo mc build-librelogin [--commit <sha>] [--keep-jdk] [--dry-run]"
bad_cases=("--commit" "--commit=" "--commit xyz" "--commit 123456" "--commit 39397c4g"
    "--commit $(printf 'a%.0s' {1..41})" "--commit 39397c4 fazla" "--bilinmeyen")
for args in "${bad_cases[@]}"; do
    read -ra argv <<<"$args"
    bl --dry-run "${argv[@]}"
    if ((RC != 0)); then ok "reddedildi: $args"; else nok "reddedilmeliydi: $args" "$OUT"; fi
done
bl --dry-run --commit 123456
check "kısa commit mesajı (7-40 hane)" out_has "7-40 haneli onaltılık"
bl --dry-run --commit
check "--commit değersiz mesajı" out_has "--commit bir değer ister"
bl --dry-run --commit 39397C47
check "büyük harfli commit küçültülür (dosya adı küçük harf)" out_has "LibreLogin-39397c4.jar"
bl --dry-run --commit "$(printf 'b%.0s' {1..40})"
check "40 haneli commit kabul edilir" eq "$RC" 0
check "jar adı commit'in ilk 7 hanesi" out_has "$T/root/artifacts/LibreLogin-bbbbbbb.jar"
cp "$REPO/config/network.env" "$T/network.env.bak"
sed -i 's/^LIBRELOGIN_COMMIT=.*/LIBRELOGIN_COMMIT="zzz"/' "$REPO/config/network.env"
bl --dry-run
check "network.env'de geçersiz commit reddedilir" test "$RC" -ne 0
check "hata network.env'i gösterir" out_has "config/network.env LIBRELOGIN_COMMIT"
sed -i '/^LIBRELOGIN_COMMIT=/d' "$REPO/config/network.env"
bl --dry-run
check "LIBRELOGIN_COMMIT yoksa anlaşılır hata" out_has "LIBRELOGIN_COMMIT tanımsız"
cp "$T/network.env.bak" "$REPO/config/network.env"

# -----------------------------------------------------------------------------
echo "# jar adı: network.env LIBRELOGIN_COMMIT ↔ plugins.list (depodaki gerçek config)"
check "LIBRELOGIN_COMMIT 40 haneli onaltılık" grep -qE '^LIBRELOGIN_COMMIT="[0-9a-f]{40}"$' "$ROOT/config/network.env"
PL_ID=$(awk '$1 !~ /^#/ && $2 == "LibreLogin" { print $3 " " $4 }' "$ROOT/config/plugins.list")
# shellcheck disable=SC2016  # plugins.list'te '$MC_ROOT' birebir yazılır
check "plugins.list LibreLogin satırı: local \$MC_ROOT/artifacts/LibreLogin-<commit7>.jar" \
    eq "$PL_ID" "local \$MC_ROOT/artifacts/LibreLogin-$C7_CFG.jar"
bl --dry-run
check "kuru çalıştırma (varsayılan commit) çıkış 0" eq "$RC" 0
check "betiğin ürettiği yol = plugins.list yolu (\$MC_ROOT açılmış)" out_has "→ $T/root/artifacts/LibreLogin-$C7_CFG.jar"
check "tutarlı config'de uyumsuzluk uyarısı yok" out_lacks "BİRLİKTE güncelleyin"

# -----------------------------------------------------------------------------
echo "# --dry-run"
check "commit network.env'den" out_has "(config/network.env LIBRELOGIN_COMMIT)"
check "plan: klon (dev dalı, nobody)" out_has "git clone --branch dev --single-branch https://github.com/kyngs/LibreLogin"
check "plan: gradlew --no-daemon build (nobody)" out_has "./gradlew --no-daemon build   (kullanıcı: nobody"
check "plan: mevcut JDK 25 kullanılır" out_has "JDK 25 mevcut: $T/jvm/jdk-25"
check "plan: sonraki adım" out_has "sonraki adım: sudo mc download plugins velocity"
check "plan: .sha256" out_has "LibreLogin-$C7_CFG.jar.sha256"
check "kuru çalıştırma artifacts/ oluşturmadı" test ! -e "$T/root/artifacts"
check "kuru çalıştırma geçici dizin bırakmadı" empty_dir "$T/tmp"
check "kuru çalıştırma apt çağırmadı" eq "$(apt_calls)" ""
bl --dry-run --commit 1234567
check "farklı commit: plugins.list uyumsuzluk uyarısı" out_has "LibreLogin-1234567.jar üretir"
mkdir -p "$T/jvm-yok"
mkjdk "$T/jvm-yok/jdk-21" 21.0.4
mkjdk "$T/jvm-yok/jdk-25-ea" 25-ea
MC_JVM_DIR="$T/jvm-yok" bl --dry-run
check "JDK 21 ve 25-ea sayılmaz: kurulum planlanır" out_has "[kuru] apt-get install temurin-25-jdk"
check "kurulan JDK derlemeden sonra kaldırılır" out_has "derlemeden sonra kaldırılır"
MC_JVM_DIR="$T/jvm-yok" bl --dry-run --keep-jdk
check "--keep-jdk: JDK kalır" out_has "--keep-jdk: derlemeden sonra kalır"
check "kuru çalıştırmada yine apt çağrılmadı" eq "$(apt_calls)" ""
MC_JVM_DIR="$T/jvm-yok" ADOPTIUM_SOURCES="$T/yok.sources" bl --dry-run
check "Adoptium deposu yoksa kuru çalıştırma uyarır" out_has "Adoptium deposu yok"

# -----------------------------------------------------------------------------
echo "# Gradle asla root olarak çalıştırılmaz"
LIBRELOGIN_BUILD_USER=root bl --dry-run
check "LIBRELOGIN_BUILD_USER=root (kuru) reddedilir" test "$RC" -ne 0
check "root reddi mesajı" out_has "Gradle root olarak ÇALIŞTIRILMAZ"
LIBRELOGIN_BUILD_USER=root LIBRELOGIN_REPO="$T/upstream" bl
check "LIBRELOGIN_BUILD_USER=root (gerçek) reddedilir" test "$RC" -ne 0
check "reddedilince klon/geçici dizin yok" empty_dir "$T/tmp"
check "reddedilince apt çağrılmadı" eq "$(apt_calls)" ""
LIBRELOGIN_BUILD_USER=olmayan-kullanici-xyz bl --dry-run
check "olmayan derleme kullanıcısı reddedilir" out_has "Derleme kullanıcısı yok"
if [[ ${EUID:-$(id -u)} -eq 0 ]] && id nobody >/dev/null 2>&1 && command -v setpriv >/dev/null 2>&1; then
    RC=0
    OUT=$(setpriv --reuid=nobody --regid="$(id -g nobody)" --clear-groups -- \
        env HOME=/ bash "$REPO/scripts/build-librelogin.sh" 2>&1) || RC=$?
    check "root olmayan kullanıcı (kuru olmayan) reddedilir" test "$RC" -ne 0
    check "root gerekir mesajı" out_has "root olarak çalıştırılmalı"
fi

# -----------------------------------------------------------------------------
echo "# uçtan uca derleme (yerel depo, sahte gradlew)"
if [[ ${EUID:-$(id -u)} -ne 0 ]] || ! id nobody >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    echo "  (atlandı: root, 'nobody' kullanıcısı ve git gerekir)"
else
    UP="$T/upstream"
    # Root'a ait, nobody'nin okuyamadığı "gizli" dosya: derleme çıktısı ona bağlanırsa sızmamalı.
    mkdir -m 0700 "$T/gizli"
    printf 'PK\003\004GIZLI-ROOT-VERISI\n' >"$T/gizli/LibreLogin.jar"
    git init -q -b dev "$UP"
    git -C "$UP" config user.email test@example.org
    git -C "$UP" config user.name test
    # shellcheck disable=SC2016  # sahte gradlew'in değişkenleri o betik çalışınca genişler
    gradlew() { # <tür> — sahte gradlew içeriği
        printf '#!/bin/sh\n# sahte Gradle\n'
        printf 'echo "sahte-gradle kullanici=$(id -un) uid=$(id -u) JAVA_HOME=$JAVA_HOME HOME=$HOME GRADLE_USER_HOME=$GRADLE_USER_HOME args=$*"\n'
        printf '[ "$(id -u)" != 0 ] || { echo "ROOT ILE CALISTI" >&2; exit 99; }\n'
        printf 'mkdir -p Plugin/build\n'
        case $1 in
            iyi) printf 'mkdir -p Plugin/build/libs\nprintf "PK\\003\\004LibreLogin %%s\\n" "$(cat surum.txt)" >Plugin/build/libs/LibreLogin.jar\n' ;;
            hata) printf 'echo "BUILD FAILED" >&2\nexit 1\n' ;;
            bag) printf 'mkdir -p Plugin/build/libs\nln -s /etc/shadow Plugin/build/libs/LibreLogin.jar\n' ;;
            dizinbag) printf 'ln -s %s Plugin/build/libs\n' "$T/gizli" ;;
            jaryok) printf 'mkdir -p Plugin/build/libs\n' ;;
        esac
    }
    commit_as() { # <tür> <sürüm> — commit kimliğini yazar
        gradlew "$1" >"$UP/gradlew"
        chmod 0755 "$UP/gradlew"
        printf '%s\n' "$2" >"$UP/surum.txt"
        git -C "$UP" add -A
        git -C "$UP" commit -q -m "$1 $2"
        git -C "$UP" rev-parse HEAD
    }
    C1=$(commit_as iyi v1)
    C2=$(commit_as iyi v2)
    C_HATA=$(commit_as hata v3)
    C_BAG=$(commit_as bag v4)
    C_DBAG=$(commit_as dizinbag v5)
    C_YOK=$(commit_as jaryok v6)
    C_SON=$(commit_as iyi v7)
    chown -R nobody "$UP" # derleme kullanıcısı klonlar (git güvenli dizin denetimi)
    export LIBRELOGIN_REPO="$UP"
    A="$T/root/artifacts"

    bl --commit "$C1"
    check "derleme (tam commit) çıkış 0" eq "$RC" 0
    J1="$A/LibreLogin-${C1:0:7}.jar"
    check "jar adı LibreLogin-<ilk 7>.jar" test -f "$J1"
    check "jar içeriği doğru commit'ten" eq "$(cat "$J1" 2>/dev/null)" "$(printf 'PK\003\004LibreLogin v1')"
    check "jar 0644 root:root" eq "$(stat -c '%a %U:%G' "$J1")" "644 root:root"
    check "artifacts/ 0755 root" eq "$(stat -c '%a %U' "$A")" "755 root"
    check ".sha256 sha256sum biçiminde" eq "$(cat "$J1.sha256")" "$(sha256sum "$J1" | cut -d' ' -f1)  LibreLogin-${C1:0:7}.jar"
    # shellcheck disable=SC2016  # $1/$2 iç kabukta genişler
    check "sha256sum -c geçer" bash -c 'cd "$1" && sha256sum -c --quiet "$2"' _ "$A" "LibreLogin-${C1:0:7}.jar.sha256"
    check "SHA-256 basıldı" out_has "SHA-256: $(sha256sum "$J1" | cut -d' ' -f1)"
    check "sonraki adım basıldı" out_has "Sonraki adım: sudo mc download plugins velocity"
    check "gradle nobody ile çalıştı" out_has "sahte-gradle kullanici=nobody"
    check "gradle root ile çalışmadı" out_lacks "ROOT ILE CALISTI"
    check "gradlew --no-daemon build argümanları" out_has "args=--no-daemon build"
    check "JAVA_HOME = JDK 25" out_has "JAVA_HOME=$T/jvm/jdk-25 "
    check "geçici HOME/GRADLE_USER_HOME" grep -qE "HOME=$T/tmp/kami-librelogin\.[^ ]+/home GRADLE_USER_HOME=$T/tmp/kami-librelogin\.[^ ]+/home/\.gradle " <<<"$OUT"
    check "geçici dizin silindi" empty_dir "$T/tmp"
    check "JDK varken apt çağrılmadı" eq "$(apt_calls)" ""
    check "farklı commit: plugins.list uyarısı" out_has "BİRLİKTE güncelleyin"

    bl --commit "${C2:0:7}"
    check "kısa commit (7 hane) çıkış 0" eq "$RC" 0
    check "kısa commit: doğru içerik" eq "$(cat "$A/LibreLogin-${C2:0:7}.jar" 2>/dev/null)" "$(printf 'PK\003\004LibreLogin v2')"
    check "kısa commit tam kimliğe çözüldü" out_has "Commit: $C2"

    # download.sh ile uyum: yan .sha256 dosyası ve "local" kaynağı birlikte çalışır.
    mkdir -p "$T/root/servers"
    # shellcheck disable=SC2016  # plugins.list'te '$MC_ROOT' birebir yazılır
    printf 'velocity LibreLogin local $MC_ROOT/artifacts/LibreLogin-%s.jar\n' "${C1:0:7}" >"$T/pl.list"
    RC=0
    OUT=$(PLUGINS_LIST="$T/pl.list" MC_USER=root bash "$REPO/scripts/download.sh" --dry-run plugins velocity 2>&1) || RC=$?
    check "download.sh local kaynağı derlenen jar'ı + .sha256'yı kabul eder" eq "$RC" 0
    check "download.sh planı LibreLogin'i içerir" grep -qE 'velocity[[:space:]]+LibreLogin[[:space:]]+indirilecek' <<<"$OUT"

    J_SON="$A/LibreLogin-${C_SON:0:7}.jar"
    bl --commit "$C_HATA"
    check "gradle hatası: çıkış ≠ 0" test "$RC" -ne 0
    check "gradle hatası: Türkçe mesaj" out_has "Gradle derlemesi başarısız (çıkış 1)"
    check "gradle hatası: jar yok" test ! -e "$A/LibreLogin-${C_HATA:0:7}.jar"
    check "gradle hatası: geçici dizin silindi" empty_dir "$T/tmp"
    bl --commit "$C_BAG"
    check "çıktı sembolik bağ: reddedilir" out_has "düzenli dosya değil"
    check "çıktı sembolik bağ: jar yok" test ! -e "$A/LibreLogin-${C_BAG:0:7}.jar"
    bl --commit "$C_DBAG"
    check "libs/ root dizinine bağ: okunamaz (nobody kimliğiyle okunur)" out_has "Derleme çıktısı okunamadı"
    check "gizli root dosyası sızmadı" test ! -e "$A/LibreLogin-${C_DBAG:0:7}.jar"
    check "hiçbir artifact gizli veriyi içermez" test -z "$(grep -rl GIZLI-ROOT "$A" 2>/dev/null)"
    bl --commit "$C_YOK"
    check "jar üretilmezse anlaşılır hata" out_has "Derleme çıktısı yok"
    bl --commit deadbeef
    check "olmayan kısa commit: hata" out_has "Commit bulunamadı: deadbeef"
    bl --commit "$(printf 'dead%.0s' {1..10})"
    check "olmayan tam commit: hata" out_has "Commit bulunamadı"
    check "hatalardan sonra geçici dizin kalmadı" empty_dir "$T/tmp"
    LIBRELOGIN_REPO="$T/olmayan-depo" bl --commit "$C1"
    check "klonlanamazsa (ağ/depo): Türkçe hata" out_has "LibreLogin deposu klonlanamadı"
    check "önceki artifact'lar bozulmadı" eq "$(cat "$J1")" "$(printf 'PK\003\004LibreLogin v1')"

    echo "# JDK 25 yoksa: temurin-25-jdk kurulur, sonra kaldırılır"
    rm -rf "${T:?}/jvm-bos" && mkdir -p "$T/jvm-bos"
    mkjdk "$T/jvm-bos/jdk-21" 21.0.4
    : >"$ADOPTIUM_SOURCES"
    : >"$FAKE/apt.log"
    MC_JVM_DIR="$T/jvm-bos" bl --commit "$C_SON"
    check "JDK kurularak derleme çıkış 0" eq "$RC" 0
    check "temurin-25-jdk kuruldu ve sonra kaldırıldı" eq "$(apt_calls)" \
        "apt-get install --no-install-recommends temurin-25-jdk|apt-get remove temurin-25-jdk"
    check "derleme kurulan JDK ile" out_has "JAVA_HOME=$T/jvm-bos/temurin-25-jdk-amd64 "
    check "JDK kaldırıldı" test ! -e "$T/jvm-bos/temurin-25-jdk-amd64"
    check "/usr/bin/java seçimi değişmedi (--set yok)" test "$(grep -c -- '--set' "$FAKE/apt.log")" -eq 0
    check "jar üretildi" test -f "$J_SON"
    : >"$FAKE/apt.log"
    MC_JVM_DIR="$T/jvm-bos" bl --commit "$C_HATA"
    check "derleme başarısızken de kurulan JDK kaldırılır" eq "$(apt_calls)" \
        "apt-get install --no-install-recommends temurin-25-jdk|apt-get remove temurin-25-jdk"
    : >"$FAKE/apt.log"
    MC_JVM_DIR="$T/jvm-bos" bl --commit "$C_SON" --keep-jdk
    check "--keep-jdk: çıkış 0" eq "$RC" 0
    check "--keep-jdk: yalnız kurulum, kaldırma yok" eq "$(apt_calls)" "apt-get install --no-install-recommends temurin-25-jdk"
    check "--keep-jdk: JDK yerinde" test -x "$T/jvm-bos/temurin-25-jdk-amd64/bin/javac"
    : >"$FAKE/apt.log"
    MC_JVM_DIR="$T/jvm-bos" bl --commit "$C_SON"
    check "önceden kurulu JDK kullanılır, kaldırılmaz" eq "$(apt_calls)" ""
    check "önceden kurulu JDK mesajı" out_has "JDK 25 mevcut: $T/jvm-bos/temurin-25-jdk-amd64 (dokunulmaz)"
    rm -rf "$T/jvm-bos/temurin-25-jdk-amd64" "$FAKE/jdk-installed"
    : >"$FAKE/apt-fail"
    : >"$FAKE/apt.log"
    MC_JVM_DIR="$T/jvm-bos" bl --commit "$C_SON"
    check "JDK kurulamazsa (ağ): Türkçe hata" out_has "temurin-25-jdk kurulamadı"
    check "JDK kurulamazsa: kurulu olmayan paket kaldırılmaya çalışılmaz" out_lacks "kaldırılıyor"
    check "JDK kurulamazsa: kurulum bir kez yenilenip yeniden denendi" eq "$(apt_calls)" \
        "apt-get install --no-install-recommends temurin-25-jdk|apt-get update -q|apt-get install --no-install-recommends temurin-25-jdk"
    rm -f "$FAKE/apt-fail"
    : >"$FAKE/apt.log"
    MC_JVM_DIR="$T/jvm-bos" ADOPTIUM_SOURCES="$T/yok.sources" bl --commit "$C_SON"
    check "Adoptium deposu yoksa: hata" test "$RC" -ne 0
    check "Adoptium yok mesajı install.sh ve openjdk'yi önerir" out_has "openjdk-25-jdk-headless"
    check "Adoptium yokken apt çağrılmadı" eq "$(apt_calls)" ""
    unset LIBRELOGIN_REPO
fi

printf '\ntest_build_librelogin: %d geçti, %d başarısız\n' "$PASS" "$FAIL"
((FAIL == 0))
