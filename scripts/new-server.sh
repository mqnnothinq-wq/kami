#!/usr/bin/env bash
# Yeni bir backend (Paper) sunucusu tanımlar (SPEC §5 'mc new-server'):
#   config/servers/<kaynak>/ → config/servers/<ad>/ kopyalanır, server.env'de PORT, RCON_PORT
#   (port+1000), HEAP, CPU_WEIGHT=100, OOM_SCORE_ADJUST=100 yeniden yazılır ve Velocity
#   config'inin [servers] tablosuna '<ad> = "127.0.0.1:<port>"' eklenir.
# Yalnız depodaki config/ ağacını değiştirir; sunucuyu kurmak için sonraki adımları yazdırır.
set -Eeuo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

MEMINFO_FILE="${MC_MEMINFO:-/proc/meminfo}"
VELOCITY_TOML="$CONFIG_DIR/servers/velocity/files/velocity.toml"
TMP_DIR=""
TOML_TMP=""

usage() {
    cat <<EOF
Kullanım: mc new-server <ad> <port> <heap> [--from <kaynak>]

  <ad>      küçük harf, rakam, tire (2-31 karakter), ör. skyblock
  <port>    oyun portu (1024-64535), yalnız 127.0.0.1'de dinlenir; RCON = port+1000
  <heap>    JVM heap (Xms=Xmx), ör. 2G ya da 1536M
  --from    kopyalanacak mevcut paper sunucusu (varsayılan: survival)

Örnek: mc new-server skyblock 30068 3G
EOF
}

cleanup() {
    [[ -z $TMP_DIR ]] || rm -rf "$TMP_DIR"
    [[ -z $TOML_TMP ]] || rm -f "$TOML_TMP"
}
trap cleanup EXIT

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

fmt_mib() {
    awk -v m="$1" 'BEGIN { if (m >= 1024) printf "%.1f GiB", m / 1024; else printf "%d MiB", m }'
}

# server.env içindeki KEY=... satırını KEY="değer" yapar; yoksa sona ekler.
set_env_var() { # <dosya> <anahtar> <değer>  (değerler önceden doğrulanmış olmalı)
    local f=$1 k=$2 v=$3
    if grep -q "^[[:space:]]*$k=" "$f"; then
        sed -i "s|^[[:space:]]*$k=.*|$k=\"$v\"|" "$f"
    else
        printf '%s="%s"\n' "$k" "$v" >>"$f"
    fi
}

# Velocity config'ine girişi ekler; sonucu stdout'a yazar. Çıkış kodları:
# 2 = [servers] tablosu yok, 3 = tabloda 'try =' yok, 4 = ad zaten var, 5 = adres zaten var.
insert_velocity_entry() { # <toml> <ad> <adres>
    awk -v name="$2" -v addr="$3" '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
        {
            t = trim($0)
            if (substr(t, 1, 1) == "[") {
                hdr = t
                sub(/[ \t]*#.*$/, "", hdr)
                in_servers = (hdr == "[servers]")
                if (in_servers) seen = 1
            } else if (in_servers && substr(t, 1, 1) != "#") {
                i = index(t, "=")
                if (i > 0) {
                    k = trim(substr(t, 1, i - 1))
                    gsub(/"/, "", k)
                    if (k == name) dup = 1
                    if (index(t, "\"" addr "\"")) dupaddr = 1
                    if (k == "try" && !done) {
                        match($0, /^[ \t]*/)
                        printf "%s%s = \"%s\"\n", substr($0, 1, RLENGTH), name, addr
                        done = 1
                    }
                }
            }
            print
        }
        END {
            if (!seen) exit 2
            if (dup) exit 4
            if (dupaddr) exit 5
            if (!done) exit 3
        }' "$1"
}

main() {
    local name="" port="" heap="" from="survival" args=() rcon s v p toml_rel rc reserved reserved_ports=()
    while (($#)); do
        case $1 in
            --from)
                (($# >= 2)) || die "--from bir sunucu adı ister."
                from=$2
                shift
                ;;
            --from=*) from=${1#--from=} ;;
            -h | --help)
                usage
                exit 0
                ;;
            -*) die "Bilinmeyen seçenek: $1" ;;
            *) args+=("$1") ;;
        esac
        shift
    done
    ((${#args[@]} == 3)) || {
        usage >&2
        exit 1
    }
    name=${args[0]} port=${args[1]} heap=${args[2]^^}

    validate_server_name "$name"
    [[ ! -e $CONFIG_DIR/servers/$name ]] || die "Zaten var: config/servers/$name"
    server_exists "$from" || die "Kaynak sunucu tanımsız: $from (mevcut: $(list_servers | paste -sd' ' -))"
    [[ $(server_get "$from" TYPE) == paper ]] || die "Kaynak paper olmalı ('$from' değil); proxy kopyalanamaz."
    if ! [[ $port =~ ^[1-9][0-9]*$ ]] || ((port < 1024 || port > 64535)); then
        die "Geçersiz port: '$port' (1024-64535; RCON portu port+1000 olur)."
    fi
    rcon=$((port + 1000))
    [[ $heap =~ ^[1-9][0-9]*[MG]$ ]] || die "Geçersiz heap: '${args[2]}' (ör. 2G ya da 1536M)."

    # Port çakışmaları: tüm server.env'lerdeki PORT/RCON_PORT + network.env'deki genel portlar.
    while IFS= read -r s; do
        for v in PORT RCON_PORT; do
            p=$(server_get "$s" "$v")
            [[ -n $p ]] || continue
            [[ $p != "$port" ]] || die "Port $port zaten kullanımda: $s ($v)."
            [[ $p != "$rcon" ]] || die "RCON portu $rcon (port+1000) zaten kullanımda: $s ($v). Başka bir port seçin."
        done
    done < <(list_servers)
    reserved=$(load_network_env && printf '%s %s %s' "${PUBLIC_JAVA_PORT:-}" "${PUBLIC_BEDROCK_PORT:-}" "${DB_PORT:-}")
    read -ra reserved_ports <<<"$reserved"
    for p in "${reserved_ports[@]}"; do
        [[ $p != "$port" && $p != "$rcon" ]] || die "Port $p network.env'de ayrılmış (genel/veritabanı portu)."
    done
    if command -v ss >/dev/null 2>&1 && ss -Hltn "( sport = :$port or sport = :$rcon )" 2>/dev/null | grep -q .; then
        log_warn "Port $port ya da $rcon bu makinede şu an dinleniyor; başka bir süreç kullanıyor olabilir."
    fi

    # Velocity girişini önce hazırla: başarısız olursa hiçbir şey değişmemiş olur.
    toml_rel=${VELOCITY_TOML#"$REPO_DIR"/}
    [[ -f $VELOCITY_TOML ]] || die "Bulunamadı: $toml_rel"
    [[ -w $VELOCITY_TOML && -w $CONFIG_DIR/servers ]] || die "config/ yazılamıyor — depo sahibi olarak (ya da sudo ile) çalıştırın."
    TOML_TMP=$(mktemp "$VELOCITY_TOML.XXXXXX")
    rc=0
    insert_velocity_entry "$VELOCITY_TOML" "$name" "127.0.0.1:$port" >"$TOML_TMP" || rc=$?
    case $rc in
        0) ;;
        2) die "$toml_rel içinde [servers] tablosu bulunamadı; girişi elle ekleyin." ;;
        3) die "$toml_rel [servers] tablosunda 'try =' satırı bulunamadı; girişi elle ekleyin." ;;
        4) die "$toml_rel [servers] tablosunda '$name' zaten var." ;;
        5) die "$toml_rel [servers] tablosunda 127.0.0.1:$port zaten kullanılıyor." ;;
        *) die "$toml_rel işlenemedi (awk çıkış kodu $rc)." ;;
    esac

    # Kopyala → düzenle → yerine koy (yarım dizin kalmasın diye gizli geçici dizinde).
    TMP_DIR="$CONFIG_DIR/servers/.$name.yeni.$$"
    mkdir "$TMP_DIR"
    cp -R "$CONFIG_DIR/servers/$from/." "$TMP_DIR/"
    set_env_var "$TMP_DIR/server.env" PORT "$port"
    set_env_var "$TMP_DIR/server.env" RCON_PORT "$rcon"
    set_env_var "$TMP_DIR/server.env" HEAP "$heap"
    set_env_var "$TMP_DIR/server.env" CPU_WEIGHT 100
    set_env_var "$TMP_DIR/server.env" OOM_SCORE_ADJUST 100

    chmod --reference="$VELOCITY_TOML" "$TOML_TMP"
    mv -f "$TOML_TMP" "$VELOCITY_TOML"
    TOML_TMP=""
    mv "$TMP_DIR" "$CONFIG_DIR/servers/$name"
    TMP_DIR=""

    print_next_steps "$name" "$port" "$rcon" "$heap" "$from"
}

print_next_steps() {
    local name=$1 port=$2 rcon=$3 heap=$4 from=$5 old_port old_rcon hits plist lines pats=()
    local total=0 n=0 s h mib need mem_kb mem

    log_ok "Yeni sunucu tanımlandı: $name (port $port, RCON $rcon, heap $heap; kaynak: $from)"
    log_ok "$(basename "$VELOCITY_TOML") [servers] tablosuna eklendi: $name = \"127.0.0.1:$port\""

    # Kaynağın portu dosyalarda sabit yazılmışsa yeni sunucu yanlış portu kullanır.
    old_port=$(server_get "$from" PORT)
    old_rcon=$(server_get "$from" RCON_PORT)
    pats=(-e "$old_port")
    [[ -z $old_rcon ]] || pats+=(-e "$old_rcon")
    hits=$(grep -rnwF "${pats[@]}" "$CONFIG_DIR/servers/$name/files" \
        "$CONFIG_DIR/servers/$name/init-commands.txt" 2>/dev/null || true)
    if [[ -n $hits ]]; then
        log_warn "Kopyalanan dosyalarda $from'un portu sabit yazılmış; @@PORT@@ / @@RCON_PORT@@ kullanın:"
        printf '%s\n' "${hits//"$CONFIG_DIR/"/    config/}" >&2
    fi

    # RAM bütçesi: tüm heap'ler + JVM başına ~%25 ek yük + 1.5 GB OS (SPEC §10 ile aynı hesap).
    while IFS= read -r s; do
        h=$(server_get "$s" HEAP)
        mib=$(heap_to_mib "$h") || continue
        total=$((total + mib))
        n=$((n + 1))
    done < <(list_servers)
    need=$((total * 125 / 100 + 1536))
    mem_kb=$(awk '$1 == "MemTotal:" { print $2 }' "$MEMINFO_FILE" 2>/dev/null || true)

    plist="$CONFIG_DIR/plugins.list"
    lines=""
    if [[ -f $plist ]]; then
        lines=$(awk -v from="$from" '
            /^[ \t]*#/ || NF < 3 { next }
            { c = split($1, a, ","); for (i = 1; i <= c; i++) if (a[i] == from) { print "       " $0; break } }' "$plist")
    fi

    cat <<EOF

Sonraki adımlar:
  1. config/servers/$name/files/ ve init-commands.txt dosyalarını gözden geçirin
     ($from'a özgü ayarlar kopyalandı: görüş mesafesi, worker-threads, oyun kuralları…).
EOF
    if [[ -n $lines ]]; then
        cat <<EOF
  2. config/plugins.list: şu eklentiler yalnız '$from' için tanımlı; '$name' için de
     istiyorsanız sunucular sütununa ',$name' ekleyin ('backends' olanlar zaten dahil):
$lines
EOF
    else
        printf "  2. config/plugins.list: '%s' için gereken eklentileri ekleyin ('backends' olanlar zaten dahil).\n" "$name"
    fi
    cat <<EOF
  3. sudo mc download all $name
  4. sudo mc init $name --accept-eula
  5. sudo mc apply velocity        (velocity.toml [servers] + kapanış sırası drop-in'i)
     sudo mc cmd velocity velocity reload   (ya da: sudo mc restart velocity — oyuncular düşer)
  6. sudo mc start $name
  7. Değişiklikleri depoya işleyin: git add config/ && git commit -m "Yeni sunucu: $name"

EOF
    if [[ $mem_kb =~ ^[0-9]+$ ]]; then
        mem=$((mem_kb / 1024))
        printf 'RAM bütçesi: %d JVM, toplam heap %s → tahmini gereksinim %s (heap + JVM başına %%25 + 1.5 GB OS); MemTotal %s.\n' \
            "$n" "$(fmt_mib "$total")" "$(fmt_mib "$need")" "$(fmt_mib "$mem")"
        if ((need > mem)); then
            log_warn "RAM yetersiz: gereksinim MemTotal'ı $(fmt_mib $((need - mem))) aşıyor. Heap'leri düşürün (config/servers/*/server.env HEAP) ya da sunucuyu büyütün; aksi hâlde OOM öldürücü devreye girer."
        fi
    else
        log_warn "MemTotal okunamadı ($MEMINFO_FILE); RAM bütçesini 'mc doctor' ile denetleyin."
    fi
}

main "$@"
