#!/usr/bin/env bash
# scripts/backup.sh testleri — restic, mariadb ve mariadb-dump PATH'e konan sahte komutlarla
# taklit edilir (çağrılar $FAKE/restic.log'a yazılır). systemd yok (MC_NO_SYSTEMD=1): çalışan
# sunucu yok sayılır, RCON kullanılmaz.
#  1) mc backup all: her sunucu kendi etiketiyle + MariaDB dökümü (_mariadb) + artifacts/ (_artifacts)
#  2) LibreLogin SQLite veritabanının tutarlı kopyası (python3 sqlite3; ayrı sqlite3 paketi gerekmez)
#  3) mc backup list / prune (günlük budama, saklama politikası)
# Çalıştırma: bash tests/test_backup.sh (root gerekir: backup.sh require_root çağırır)
set -Eeuo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(dirname "$HERE")"
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    printf '[hata] test_backup.sh root gerektirir (backup.sh require_root): sudo -E tests/run.sh\n' >&2
    exit 1
fi

PASS=0 FAIL=0
T=$(mktemp -d "${TMPDIR:-/tmp}/kami-backup-test.XXXXXX")
trap 'rm -rf -- "$T"' EXIT

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
rlog_has() { grep -qF -- "$1" "$FAKE/restic.log"; }

REPO="$T/repo"
mkdir -p "$REPO/scripts" "$T/bin" "$T/fake" "$T/etc" "$T/root/servers" "$T/root/artifacts"
cp "$ROOT/scripts/lib.sh" "$ROOT/scripts/rcon.py" "$ROOT/scripts/backup.sh" "$REPO/scripts/"
cp -R "$ROOT/config" "$REPO/config"
export MC_ROOT="$T/root" MC_ETC="$T/etc" MC_RUN_DIR="$T/run" MC_NO_SYSTEMD=1 MC_USER
MC_USER=$(id -un)
export FAKE="$T/fake" PATH="$T/bin:$PATH"
printf 'RESTIC_REPOSITORY=%s\nRESTIC_PASSWORD_FILE=%s\nBACKUP_HOST=mc01\n' "$T/restic" "$T/etc/restic.pass" >"$T/etc/backup.env"
printf 'parola\n' >"$T/etc/restic.pass"
chmod 600 "$T/etc/backup.env" "$T/etc/restic.pass"
printf "RCON_PASSWORD='x'\n" >"$T/etc/secrets.env"

cat >"$T/bin/restic" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE/restic.log"
case $1 in
    init) mkdir -p "$RESTIC_REPOSITORY" && : >"$RESTIC_REPOSITORY/config" ;;
    backup) if [[ " $* " == *" --stdin "* ]]; then cat >"$FAKE/stdin.sql"; fi ;;
    snapshots) printf '[]\n' ;;
esac
exit 0
EOF
cat >"$T/bin/mariadb" <<'EOF'
#!/bin/sh
printf 'information_schema\nluckperms\n'
EOF
cat >"$T/bin/mariadb-dump" <<'EOF'
#!/bin/sh
printf -- '-- sahte döküm: %s\n' "$*"
EOF
chmod 0755 "$T/bin/restic" "$T/bin/mariadb" "$T/bin/mariadb-dump"

bk() { # çıktı: $OUT, dönüş: $RC
    RC=0
    OUT=$(bash "$REPO/scripts/backup.sh" "$@" 2>&1) || RC=$?
}

# Sunucu dizinleri: velocity (LibreLogin SQLite), limbo, lobby; survival yok (henüz kurulmamış).
SV="$T/root/servers"
mkdir -p "$SV/velocity/plugins/librelogin" "$SV/limbo" "$SV/lobby/world"
python3 - "$SV/velocity/plugins/librelogin/user-data.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("PRAGMA journal_mode=WAL")
c.execute("CREATE TABLE u (ad TEXT)")
c.execute("INSERT INTO u VALUES ('oyuncu1'), ('oyuncu2')")
c.commit()
c.close()
PY

echo "# yardım (root gerekmez)"
bk --help
check "--help çıkış 0" eq "$RC" 0
check "yardım artifacts/ yedeğini ve geri yüklemeyi anlatır" out_has "restic restore latest --tag _artifacts --target /"

echo "# mc backup all"
: >"$FAKE/restic.log"
bk all
check "backup all çıkış 0" eq "$RC" 0
check "depo yoksa oluşturuldu (restic init)" rlog_has "init"
check "velocity kendi etiketiyle, jar'lar hariç" rlog_has "backup $SV/velocity --host mc01 --tag velocity --exclude $SV/velocity/logs --exclude *.jar"
check "limbo yedeklendi, ikili hariç" rlog_has "backup $SV/limbo --host mc01 --tag limbo --exclude $SV/limbo/logs --exclude $SV/limbo/pico_limbo"
check "lobby yedeklendi" rlog_has "backup $SV/lobby --host mc01 --tag lobby"
check "kurulmamış survival atlandı (uyarı)" out_has "survival: $SV/survival yok, atlanıyor"
check "MariaDB dökümü stdin ile _mariadb etiketiyle" rlog_has "backup --stdin --stdin-filename mariadb.sql --host mc01 --tag _mariadb"
check "döküm yalnız var olan veritabanlarını içerir" grep -qF -- "--databases luckperms" "$FAKE/stdin.sql"
check "artifacts/ boşken yedeklenmez" test -z "$(grep -F -- '--tag _artifacts' "$FAKE/restic.log" || true)"
DBC="$SV/velocity/plugins/librelogin/user-data.db.yedek"
check "LibreLogin veritabanının tutarlı kopyası alındı" test -f "$DBC"
check "kopya sağlam ve verileri içeriyor (python3 sqlite3)" eq \
    "$(python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute("PRAGMA integrity_check").fetchone()[0], c.execute("select count(*) from u").fetchone()[0])' "$DBC")" "ok 2"
check "yedek kilidi \$MC_ROOT/.backup.lock" test -f "$T/root/.backup.lock"

printf 'PK\003\004jar\n' >"$T/root/artifacts/LibreLogin-39397c4.jar"
: >"$FAKE/restic.log"
bk all
check "artifacts/ doluyken _artifacts etiketiyle yedeklenir" rlog_has "backup $T/root/artifacts --host mc01 --tag _artifacts"
: >"$FAKE/restic.log"
bk lobby
check "tek sunucu yedeğinde MariaDB ve artifacts yok" test -z "$(grep -E -- '--tag _(mariadb|artifacts)' "$FAKE/restic.log" || true)"

echo "# mc backup list"
: >"$FAKE/restic.log"
bk list _artifacts
check "list _artifacts kabul edilir" eq "$RC" 0
check "list süzgeci" rlog_has "snapshots --compact --host mc01 --tag _artifacts"
bk list _mariadb
check "list _mariadb kabul edilir" eq "$RC" 0
bk list yok
check "list tanımsız sunucu reddedilir" out_has "Tanımsız sunucu: yok"

echo "# mc backup prune"
mkdir -p "$SV/lobby/logs"
: >"$SV/lobby/logs/2026-01-01-1.log.gz"
touch -d '120 days ago' "$SV/lobby/logs/2026-01-01-1.log.gz"
: >"$SV/lobby/logs/yeni.log.gz"
: >"$FAKE/restic.log"
bk prune
check "prune çıkış 0" eq "$RC" 0
check "LOG_RETENTION_DAYS'ten eski günlük silindi" test ! -e "$SV/lobby/logs/2026-01-01-1.log.gz"
check "yeni günlük korundu" test -e "$SV/lobby/logs/yeni.log.gz"
check "restic forget saklama politikası (network.env)" \
    rlog_has "forget --prune --host mc01 --group-by host,tags --keep-hourly 24 --keep-daily 7 --keep-weekly 4 --keep-monthly 6"

printf '\ntest_backup: %d geçti, %d başarısız\n' "$PASS" "$FAIL"
((FAIL == 0))
