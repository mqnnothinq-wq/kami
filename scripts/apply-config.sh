#!/usr/bin/env bash
# config/servers/<sunucu>/files/ ağacını $MC_ROOT/servers/<sunucu>/ altına uygular (SPEC §7);
# ayrıca jvm.env ve systemd drop-in dosyalarını üretir.
#
# İki aşamalı çalışır: önce her şey geçici bir alanda hazırlanır (yer tutucular, birleştirmeler),
# ancak hepsi başarılıysa hedefe yazılır. Böylece tanımsız bir yer tutucu ya da bozuk bir YAML
# yarım uygulanmış bir yapılandırma bırakmaz.
#
# Test/ortam değişkenleri: YQ (mikefarah yq yolu), MC_SYSTEMD_DIR (drop-in kökü),
# MC_NO_SYSTEMD=1 (systemctl çağrılmaz) + lib.sh'deki MC_ROOT, MC_ETC, MC_USER.
set -Eeuo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

YQ="${YQ:-yq}"
MC_SYSTEMD_DIR="${MC_SYSTEMD_DIR:-/etc/systemd/system}"
MC_NO_SYSTEMD="${MC_NO_SYSTEMD:-0}"

DRY_RUN=0
IS_ROOT=0
YQ_OK=0
STAGE=""
PENDING_TMP=""
SERVERS=()
RENDER_ERRORS=()
# Plan: her giriş bir hedef dosya (paralel diziler).
PLAN_OUT=() PLAN_DST=() PLAN_KIND=() PLAN_HOW=() PLAN_SRV=()

usage() {
    cat <<EOF
Kullanım: mc apply [--dry-run] [sunucu|all ...]
          scripts/apply-config.sh [--dry-run] [sunucu|all ...]

config/servers/<sunucu>/files/<yol> → $SERVERS_DIR/<sunucu>/<yol>
  *.properties    anahtar birleştirme: override'daki anahtarlar yazılır/eklenir,
                  hedefteki diğer satırlar ve yorumlar korunur
  *.yml, *.yaml   hedef yoksa kopyalanır (plugins/ altındakiler atlanır: önce eklenti
                  config üretmeli); hedef varsa yq ile derin birleştirilir
                  (yorumlar korunur, diziler bütünüyle değiştirilir)
  diğerleri       olduğu gibi kopyalanır (dosyanın tamamı depodan gelir)
Ayrıca üretilir:
  $SERVERS_DIR/<sunucu>/jvm.env
  $MC_SYSTEMD_DIR/mc@<sunucu>.service.d/20-resources.conf  (+ velocity: 10-order.conf)

Seçenekler:
  -n, --dry-run   hiçbir şey yazmadan yapılacakları ve farkları gösterir
  -h, --help      bu yardım
Hedef verilmezse 'all' kabul edilir.
EOF
}

cleanup() {
    [[ -z $PENDING_TMP ]] || rm -f "$PENDING_TMP"
    [[ -z $STAGE ]] || rm -rf "$STAGE"
}
trap cleanup EXIT

own() {
    if ((IS_ROOT)); then chown "$MC_USER:$MC_USER" "$@"; fi
}

need_yq() {
    local v
    ((YQ_OK)) && return 0
    v=$("$YQ" --version 2>&1) || die "yq çalıştırılamadı ('$YQ'). mikefarah yq v4 gerekli (scripts/install.sh kurar)."
    [[ $v == *mikefarah* ]] || die "'$YQ' mikefarah yq değil ($v). Debian/Ubuntu'daki python 'yq' paketi uyumsuzdur; YQ=/yol/yq ile belirtin."
    YQ_OK=1
}

# systemd EnvironmentFile için çift tırnaklı değer (\ " $ ` kaçışlanır).
env_quote() {
    local v=$1
    v=${v//\\/\\\\}
    v=${v//\"/\\\"}
    v=${v//\$/\\\$}
    v=${v//\`/\\\`}
    printf '"%s"' "$v"
}

# Bayrak dosyasını tek satıra indirir: '#' ile başlayan ve boş satırlar yok sayılır.
read_flags() {
    awk '{ sub(/^[ \t]+/, ""); sub(/[ \t\r]+$/, "") }
         $0 == "" || substr($0, 1, 1) == "#" { next }
         { printf "%s%s", sep, $0; sep = " " }' "$1"
}

# merge_properties <hedef> <override> — birleşik içeriği stdout'a yazar.
# Anahtar = ilk '=' öncesi (boşluklar kırpılır); karşılaştırma tam dize eşleşmesidir
# (regex değil), bu yüzden '.'/'-' içeren anahtarlar güvenlidir. Hedefte aynı anahtar
# birden çok kez varsa ilki değiştirilir, diğerleri atılır (Java'da son değer kazanırdı).
merge_properties() {
    awk -v ovr="$2" '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
        function keyof(line,   t, i) {
            t = trim(line)
            if (t == "" || substr(t, 1, 1) == "#" || substr(t, 1, 1) == "!") return ""
            i = index(t, "=")
            if (i == 0) return ""
            return trim(substr(t, 1, i - 1))
        }
        FILENAME == ovr {
            k = keyof($0)
            if (k != "") { if (!(k in val)) order[++n] = k; val[k] = trim($0) }
            next
        }
        {
            k = keyof($0)
            if (k != "" && (k in val)) {
                if (!(k in done)) { print val[k]; done[k] = 1 }
                next
            }
            sub(/\r$/, "")
            print
        }
        END { for (i = 1; i <= n; i++) if (!(order[i] in done)) print val[order[i]] }
    ' "$2" "$1"
}

# Override'ın yaprak yollarından hedefte olmayanları uyarır. Diziler yaprak sayılır
# (birleştirmede bütünüyle değiştirilirler), içlerine inilmez.
warn_unknown_keys() {
    local override=$1 target=$2 label=$3 p
    local sel='.. | select((path | length) > 0 and ((path | map(select(tag == "!!int")) | length) == 0))'
    "$YQ" -o=json -I=0 "[$sel | path] | .[]" "$target" >"$STAGE/paths.target" \
        || die "$label: hedef YAML okunamadı: $target"
    "$YQ" -o=json -I=0 "[$sel | select(tag != \"!!map\" or length == 0) | path] | .[]" "$override" \
        >"$STAGE/paths.override" || die "$label: override YAML okunamadı."
    while IFS= read -r p; do
        p=${p#[}
        p=${p%]}
        p=${p//\",\"/.}
        p=${p#\"}
        p=${p%\"}
        log_warn "$label: '$p' hedefte yok — bilinmeyen/yeniden adlandırılmış olabilir (yine de yazılacak)."
    done < <(grep -Fxv -f "$STAGE/paths.target" "$STAGE/paths.override" || true)
}

add_plan() { # <hazır dosya> <hedef> <file|unit> <açıklama> <sunucu>
    PLAN_OUT+=("$1")
    PLAN_DST+=("$2")
    PLAN_KIND+=("$3")
    PLAN_HOW+=("$4")
    PLAN_SRV+=("$5")
}

plan_file() {
    local srv=$1 rel=$2 src dst rendered out
    src="$CONFIG_DIR/servers/$srv/files/$rel"
    dst="$SERVERS_DIR/$srv/$rel"
    rendered="$STAGE/$srv/rendered/$rel"
    out="$STAGE/$srv/out/$rel"
    mkdir -p "$(dirname "$rendered")" "$(dirname "$out")"

    if ! render_placeholders "$src" "$rendered" "$srv"; then
        RENDER_ERRORS+=("$srv/$rel")
        return 0
    fi

    case $rel in
        *.properties)
            if [[ -f $dst ]]; then
                merge_properties "$dst" "$rendered" >"$out"
                add_plan "$out" "$dst" file "anahtar birleştirme" "$srv"
            else
                cp "$rendered" "$out"
                add_plan "$out" "$dst" file "kopya (hedef yoktu)" "$srv"
            fi
            ;;
        *.yml | *.yaml)
            if [[ -f $dst ]]; then
                need_yq
                warn_unknown_keys "$rendered" "$dst" "$srv/$rel"
                cp "$dst" "$out"
                # Override'ın yorumları taşınmaz: yq onları hedefin başına/anahtarlarına
                # ekler ve her çalıştırmada çoğaltır. Hedefin kendi yorumları korunur.
                O="$rendered" "$YQ" -i '. *= (load(strenv(O)) | ... comments = "")' "$out" \
                    || die "$srv/$rel: yq birleştirmesi başarısız (hedef geçerli YAML mi? $dst)"
                add_plan "$out" "$dst" file "yml birleştirme" "$srv"
            elif [[ $rel == plugins/* ]]; then
                log_warn "$srv: $rel atlandı — eklenti henüz config üretmedi; sunucuyu bir kez başlatıp 'mc apply $srv' tekrarlayın."
            else
                cp "$rendered" "$out"
                add_plan "$out" "$dst" file "kopya (hedef yoktu; eksik anahtarları sunucu ekler)" "$srv"
            fi
            ;;
        *)
            cp "$rendered" "$out"
            add_plan "$out" "$dst" file "tam kopya" "$srv"
            ;;
    esac
}

plan_jvm_env() {
    local srv=$1 type heap gc extra flags_file opts args conc out
    type=$(server_get "$srv" TYPE)
    heap=$(server_get "$srv" HEAP)
    gc=$(server_get "$srv" GC_THREADS)
    extra=$(server_get "$srv" EXTRA_JAVA_OPTS)
    case $type in
        paper) args="--nogui" ;;
        velocity) args="" ;;
        *) die "$srv: geçersiz TYPE='$type' (paper ya da velocity olmalı)." ;;
    esac
    [[ $heap =~ ^[1-9][0-9]*[KkMmGg]?$ ]] || die "$srv: geçersiz HEAP='$heap' (ör. 1536M, 7G)."
    flags_file="$CONFIG_DIR/jvm/$type.flags"
    [[ -f $flags_file ]] || die "Bulunamadı: $flags_file"
    opts=$(read_flags "$flags_file")
    if [[ -n $gc ]]; then
        [[ $gc =~ ^[1-9][0-9]*$ ]] || die "$srv: geçersiz GC_THREADS='$gc' (pozitif tamsayı ya da boş)."
        conc=$((gc / 2))
        ((conc >= 1)) || conc=1
        opts+=" -XX:ParallelGCThreads=$gc -XX:ConcGCThreads=$conc"
    fi
    [[ -z $extra ]] || opts+=" $extra"
    opts=${opts# }

    out="$STAGE/$srv/jvm.env"
    {
        printf '# mc apply tarafından üretildi — elle düzenlemeyin.\n'
        printf '# Kaynak: config/servers/%s/server.env + config/jvm/%s.flags\n' "$srv" "$type"
        printf 'JAVA_MEM=%s\n' "$(env_quote "-Xms$heap -Xmx$heap")"
        printf 'JAVA_OPTS=%s\n' "$(env_quote "$opts")"
        printf 'SERVER_ARGS=%s\n' "$(env_quote "$args")"
    } >"$out"
    add_plan "$out" "$SERVERS_DIR/$srv/jvm.env" file "üretildi (systemd EnvironmentFile)" "$srv"
}

plan_dropins() {
    local srv=$1 cpu oom type dir out backends
    type=$(server_get "$srv" TYPE)
    cpu=$(server_get "$srv" CPU_WEIGHT)
    oom=$(server_get "$srv" OOM_SCORE_ADJUST)
    if [[ -n $cpu ]] && ! { [[ $cpu =~ ^[0-9]+$ ]] && ((cpu >= 1 && cpu <= 10000)); }; then
        die "$srv: geçersiz CPU_WEIGHT='$cpu' (1-10000)."
    fi
    if [[ -n $oom ]] && ! { [[ $oom =~ ^-?[0-9]+$ ]] && ((oom >= -1000 && oom <= 1000)); }; then
        die "$srv: geçersiz OOM_SCORE_ADJUST='$oom' (-1000..1000)."
    fi
    dir="$MC_SYSTEMD_DIR/$(unit_of "$srv").d"

    out="$STAGE/$srv/20-resources.conf"
    {
        printf '# mc apply tarafından üretildi (config/servers/%s/server.env) — elle düzenlemeyin.\n' "$srv"
        printf '[Service]\n'
        [[ -z $cpu ]] || printf 'CPUWeight=%s\n' "$cpu"
        [[ -z $oom ]] || printf 'OOMScoreAdjust=%s\n' "$oom"
    } >"$out"
    add_plan "$out" "$dir/20-resources.conf" unit "CPUWeight/OOMScoreAdjust" "$srv"

    if [[ $type == velocity ]]; then
        # Kapanışta proxy önce dursun: After= sırası durdururken tersine işler.
        backends=$({ list_backends || true; } | sed 's/.*/mc@&.service/' | paste -sd' ' -)
        if [[ -n $backends ]]; then
            out="$STAGE/$srv/10-order.conf"
            {
                printf '# mc apply tarafından üretildi — backend listesi config/servers/*/server.env.\n'
                printf '# Kapanışta önce proxy durur, oyuncular düzgün bir mesajla ayrılır.\n'
                printf '[Unit]\nAfter=%s\n' "$backends"
            } >"$out"
            add_plan "$out" "$dir/10-order.conf" unit "kapanış sırası" "$srv"
        fi
    fi
}

plan_server() {
    local srv=$1 src_root f
    src_root="$CONFIG_DIR/servers/$srv/files"
    if [[ -d $src_root ]]; then
        while IFS= read -r -d '' f; do
            plan_file "$srv" "${f#"$src_root"/}"
        done < <(find "$src_root" -type f ! -name '.gitkeep' -print0 | LC_ALL=C sort -z)
    else
        log_warn "$srv: $src_root yok; yalnız jvm.env ve drop-in üretilecek."
    fi
    plan_jvm_env "$srv"
    plan_dropins "$srv"
}

# Eksik dizin bileşenlerini minecraft sahipliğinde 0750 oluşturur.
ensure_dir() {
    local d=$1 todo=()
    while [[ ! -d $d ]]; do
        todo=("$d" "${todo[@]}")
        d=$(dirname "$d")
    done
    for d in "${todo[@]}"; do
        mkdir -m 0750 "$d"
        own "$d"
    done
}

install_server_file() { # <kaynak> <hedef>
    local dir
    dir=$(dirname "$2")
    ensure_dir "$dir"
    PENDING_TMP=$(mktemp "$dir/.kami-apply.XXXXXX")
    cat "$1" >"$PENDING_TMP"
    chmod 0640 "$PENDING_TMP"
    own "$PENDING_TMP"
    mv -f "$PENDING_TMP" "$2"
    PENDING_TMP=""
}

install_unit_file() { # <kaynak> <hedef>
    local dir
    dir=$(dirname "$2")
    mkdir -p "$dir"
    PENDING_TMP=$(mktemp "$dir/.kami-apply.XXXXXX")
    cat "$1" >"$PENDING_TMP"
    chmod 0644 "$PENDING_TMP"
    mv -f "$PENDING_TMP" "$2"
    PENDING_TMP=""
}

execute_plan() {
    local i out dst kind srv status units_changed=0 units_writable=1 s
    local -A changed=()
    local -a written=() same=()

    if ((!DRY_RUN)); then
        if ! { mkdir -p "$MC_SYSTEMD_DIR" 2>/dev/null && [[ -w $MC_SYSTEMD_DIR ]]; }; then
            units_writable=0
            log_warn "$MC_SYSTEMD_DIR yazılamıyor: systemd drop-in'leri atlanacak (root gerekir)."
        fi
    fi

    for i in "${!PLAN_OUT[@]}"; do
        out=${PLAN_OUT[i]} dst=${PLAN_DST[i]} kind=${PLAN_KIND[i]} srv=${PLAN_SRV[i]}
        if [[ -f $dst ]] && cmp -s "$out" "$dst"; then
            status="aynı"
            if ((!DRY_RUN)) && [[ $kind == file ]]; then
                chmod 0640 "$dst"
                own "$dst"
            fi
            same+=("$dst")
        elif ((DRY_RUN)); then
            if [[ -e $dst ]]; then status="değişecek"; else status="yeni"; fi
            changed[$srv]=1
        elif [[ $kind == unit ]] && ((!units_writable)); then
            status="atlandı"
        else
            if [[ -e $dst ]]; then status="güncellendi"; else status="yeni"; fi
            if [[ $kind == unit ]]; then
                install_unit_file "$out" "$dst"
                units_changed=1
            else
                install_server_file "$out" "$dst"
            fi
            changed[$srv]=1
            written+=("$dst")
        fi
        printf '  %-14s %s  (%s)\n' "[$status]" "$dst" "${PLAN_HOW[i]}"
        if ((DRY_RUN)) && [[ $status == "değişecek" ]]; then
            diff -u --label "$dst (şimdiki)" --label "$dst (uygulanınca)" "$dst" "$out" \
                | sed 's/^/        /' || true
        fi
    done

    if ((DRY_RUN)); then
        log_info "Deneme kipi (--dry-run): hiçbir dosya yazılmadı."
        return 0
    fi

    if ((units_changed)); then
        if [[ $MC_NO_SYSTEMD == 1 ]]; then
            log_info "MC_NO_SYSTEMD=1: systemctl daemon-reload atlandı."
        elif command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload
            log_ok "systemd yeniden yüklendi (daemon-reload)."
        else
            log_warn "systemctl bulunamadı; daemon-reload atlandı."
        fi
    fi

    for s in "${SERVERS[@]}"; do
        [[ -n ${changed[$s]:-} ]] || continue
        if [[ $MC_NO_SYSTEMD != 1 ]] && is_running "$s" 2>/dev/null; then
            log_warn "$s çalışıyor: değişiklikler yeniden başlatınca geçerli olur (mc restart $s)."
        fi
    done
    log_ok "Uygulandı: ${#written[@]} dosya yazıldı, ${#same[@]} dosya zaten güncel."
}

main() {
    local targets=() t s list
    while (($#)); do
        case $1 in
            -n | --dry-run) DRY_RUN=1 ;;
            -h | --help)
                usage
                exit 0
                ;;
            -*) die "Bilinmeyen seçenek: $1 ('mc apply --help')" ;;
            *) targets+=("$1") ;;
        esac
        shift
    done
    ((${#targets[@]})) || targets=(all)
    [[ -f $CONFIG_DIR/network.env ]] || die "Bulunamadı: $CONFIG_DIR/network.env"

    for t in "${targets[@]}"; do
        list=$(resolve_targets "$t")
        while IFS= read -r s; do
            [[ -n $s ]] || continue
            [[ " ${SERVERS[*]} " == *" $s "* ]] || SERVERS+=("$s")
        done <<<"$list"
    done
    ((${#SERVERS[@]})) || die "Tanımlı sunucu yok ($CONFIG_DIR/servers/*/server.env)."

    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then IS_ROOT=1; fi
    if ((!DRY_RUN)); then
        [[ -d $MC_ROOT ]] || die "$MC_ROOT yok — önce scripts/install.sh çalıştırın."
        if ((IS_ROOT)); then
            { id -u "$MC_USER" && getent group "$MC_USER"; } >/dev/null 2>&1 \
                || die "Kullanıcı/grup yok: $MC_USER — önce scripts/install.sh çalıştırın."
        elif [[ -d $SERVERS_DIR && ! -w $SERVERS_DIR ]]; then
            die "$SERVERS_DIR yazılamıyor — root olarak çalıştırın (sudo mc apply)."
        fi
    fi

    STAGE=$(mktemp -d "${TMPDIR:-/tmp}/kami-apply.XXXXXX")
    for s in "${SERVERS[@]}"; do
        plan_server "$s"
    done

    if ((${#RENDER_ERRORS[@]})); then
        [[ -r $SECRETS_FILE ]] || log_warn "$SECRETS_FILE okunamadı; gizli değerler için root olarak çalıştırın."
        die "Yer tutucu hatası: ${RENDER_ERRORS[*]} — HİÇBİR dosya yazılmadı. Eksik değeri server.env, secrets.env ya da network.env'de tanımlayın."
    fi
    execute_plan
}

main "$@"
