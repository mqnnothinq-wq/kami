#!/usr/bin/env bash
# config/servers/<sunucu>/files/ ağacını $MC_ROOT/servers/<sunucu>/ altına uygular (SPEC §7, §17);
# ayrıca jvm.env ve systemd drop-in dosyalarını üretir.
#
# İki aşamalı çalışır: önce her şey geçici bir alanda hazırlanır (yer tutucular, birleştirmeler),
# ancak hepsi başarılıysa hedefe yazılır. Böylece tanımsız bir yer tutucu ya da bozuk bir YAML
# yarım uygulanmış bir yapılandırma bırakmaz.
#
# Güvenlik: sunucu dizinleri minecraft kullanıcısınındır; orada çalışan (ya da ele geçirilmiş) bir
# sunucu sembolik bağ bırakabilir. Bu yüzden root iken sunucu dizinlerindeki tüm okuma/yazmalar
# minecraft kimliğiyle (lib.sh as_mc: setpriv, yoksa runuser) yapılır ve yolunda sembolik bağ olan
# hedef reddedilir.
#
# Test/ortam değişkenleri: YQ (mikefarah yq yolu), MC_SYSTEMD_DIR (drop-in kökü),
# MC_NO_SYSTEMD=1 (systemctl çağrılmaz) + lib.sh'deki MC_ROOT, MC_ETC, MC_USER.
set -Eeuo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

YQ="${YQ:-yq}"
MC_SYSTEMD_DIR="${MC_SYSTEMD_DIR:-/etc/systemd/system}"
MC_NO_SYSTEMD="${MC_NO_SYSTEMD:-0}"
# systemd birimleri /opt/minecraft yolunu sabit bekler (SPEC §1); drop-in'e bu yazılır.
UNIT_SERVERS_DIR="/opt/minecraft/servers"
GEN_MARK="# mc apply tarafından üretildi"

DRY_RUN=0
IS_ROOT=0
MC_GROUP=""
YQ_OK=0
STAGE=""
PENDING_TMP=""
SERVERS=()
RENDER_ERRORS=()
PATH_ERRORS=()
# Plan: her giriş bir hedef dosya (paralel diziler). CUR = hedefin plan anındaki kopyası (yoksa "").
PLAN_OUT=() PLAN_DST=() PLAN_KIND=() PLAN_HOW=() PLAN_SRV=() PLAN_CUR=()

usage() {
    cat <<EOF
Kullanım: mc apply [--dry-run] [sunucu|all ...]
          scripts/apply-config.sh [--dry-run] [sunucu|all ...]

config/servers/<sunucu>/files/<yol> → $SERVERS_DIR/<sunucu>/<yol>
  *.properties    anahtar birleştirme: override'daki anahtarlar yazılır/eklenir,
                  hedefteki diğer satırlar ve yorumlar korunur
  *.yml, *.yaml   hedef yoksa kopyalanır (plugins/ altındakiler atlanır: önce eklenti
                  config üretmeli); hedef varsa yq ile derin birleştirilir
                  (yorumlar korunur, diziler bütünüyle değiştirilir; içerik aynıysa
                  sunucunun biçimlendirmesi korunur)
  diğerleri       olduğu gibi kopyalanır (dosyanın tamamı depodan gelir)
Ayrıca üretilir:
  $SERVERS_DIR/<sunucu>/jvm.env            (limbo: boş değerlerle)
  $MC_SYSTEMD_DIR/mc@<sunucu>.service.d/20-resources.conf
      + velocity: 10-order.conf (kapanış sırası)  + limbo: 30-exec.conf (PicoLimbo ExecStart)
Yolunda sembolik bağ olan hedefler güvenlik için reddedilir.

Seçenekler:
  -n, --dry-run   hiçbir şey yazmadan yapılacakları ve farkları gösterir (gizli değerler maskelenir)
  -h, --help      bu yardım
Hedef verilmezse 'all' kabul edilir.
EOF
}

cleanup() {
    [[ -z $PENDING_TMP ]] || rm -f "$PENDING_TMP"
    [[ -z $STAGE ]] || rm -rf "$STAGE"
}
trap cleanup EXIT

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
        || die "$label: hedef YAML okunamadı."
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

# İki YAML dosyası aynı veriyi mi taşıyor? (biçim, girinti, tırnak, yorum farkı sayılmaz)
yaml_same_data() {
    local a b
    a=$("$YQ" -o=json -I=0 '.' "$1" 2>/dev/null) || return 1
    b=$("$YQ" -o=json -I=0 '.' "$2" 2>/dev/null) || return 1
    [[ $a == "$b" ]]
}

# check_dest <sunucu> <hedef> — sunucu dizininden hedefe kadar hiçbir bileşen sembolik bağ
# olmamalı; ilk var olan üst dizin sahibinin kimliğiyle yazılabilmeli, dosya varsa okunabilmeli.
# Sorun varsa açıklamayı yazar ve 1 döner.
check_dest() {
    local srv=$1 dst=$2 p=$SERVERS_DIR dir="" i last
    local -a parts
    if [[ -L $SERVERS_DIR ]]; then
        printf '%s sembolik bağ' "$SERVERS_DIR"
        return 1
    fi
    [[ -d $SERVERS_DIR ]] || return 0 # henüz yok: root oluşturur, altı boş
    dir=$SERVERS_DIR
    IFS=/ read -ra parts <<<"$srv/${dst#"$SERVERS_DIR/$srv/"}"
    last=$((${#parts[@]} - 1))
    for ((i = 0; i <= last; i++)); do
        p+="/${parts[i]}"
        if [[ -L $p ]]; then
            printf '%s sembolik bağ' "$p"
            return 1
        fi
        [[ -e $p ]] || break
        if ((i < last)); then
            if [[ ! -d $p ]]; then
                printf '%s dizin değil' "$p"
                return 1
            fi
            dir=$p
        elif [[ ! -f $p ]]; then
            printf '%s normal dosya değil' "$p"
            return 1
        elif ! as_mc test -r "$p"; then
            printf '%s %s tarafından okunamıyor (chown %s:%s)' "$p" "$MC_USER" "$MC_USER" "$MC_USER"
            return 1
        fi
    done
    # shellcheck disable=SC2016  # $1 iç kabukta genişler
    if ! as_mc sh -c 'test -w "$1" && test -x "$1"' _ "$dir"; then
        printf '%s %s tarafından yazılamıyor (chown -R %s:%s %s)' "$dir" "$MC_USER" "$MC_USER" "$MC_USER" "$SERVERS_DIR/$srv"
        return 1
    fi
}

add_plan() { # <hazır dosya> <hedef> <file|unit|unit-rm> <açıklama> <sunucu> <mevcut kopya|"">
    PLAN_OUT+=("$1")
    PLAN_DST+=("$2")
    PLAN_KIND+=("$3")
    PLAN_HOW+=("$4")
    PLAN_SRV+=("$5")
    PLAN_CUR+=("$6")
}

# Sunucu dizinindeki hedefi denetler ve varsa içeriğini (minecraft kimliğiyle) sahneye kopyalar.
# stdout: kopyanın yolu (hedef yoksa boş). Denetim başarısızsa PATH_ERRORS'a ekler, 1 döner.
stage_current() { # <sunucu> <hedef> <kopya yolu>
    local why
    if ! why=$(check_dest "$1" "$2"); then
        PATH_ERRORS+=("$why")
        return 1
    fi
    [[ -f $2 ]] || return 0
    mkdir -p "$(dirname "$3")"
    as_mc cat -- "$2" >"$3" || die "$2 okunamadı."
    printf '%s' "$3"
}

plan_file() {
    local srv=$1 rel=$2 src dst rendered out cur
    src="$CONFIG_DIR/servers/$srv/files/$rel"
    dst="$SERVERS_DIR/$srv/$rel"
    rendered="$STAGE/$srv/rendered/$rel"
    out="$STAGE/$srv/out/$rel"
    mkdir -p "$(dirname "$rendered")" "$(dirname "$out")"

    if ! render_placeholders "$src" "$rendered" "$srv"; then
        RENDER_ERRORS+=("$srv/$rel")
        return 0
    fi
    stage_current "$srv" "$dst" "$STAGE/$srv/cur/$rel" >"$STAGE/cur.path" || return 0
    cur=$(<"$STAGE/cur.path")

    case $rel in
        *.properties)
            if [[ -n $cur ]]; then
                merge_properties "$cur" "$rendered" >"$out"
                add_plan "$out" "$dst" file "anahtar birleştirme" "$srv" "$cur"
            else
                cp "$rendered" "$out"
                add_plan "$out" "$dst" file "kopya (hedef yoktu)" "$srv" ""
            fi
            ;;
        *.yml | *.yaml)
            if [[ -n $cur ]]; then
                need_yq
                warn_unknown_keys "$rendered" "$cur" "$srv/$rel"
                cp "$cur" "$out"
                # Override'ın yorumları taşınmaz: yq onları hedefin başına/anahtarlarına
                # ekler ve her çalıştırmada çoğaltır. Hedefin kendi yorumları korunur.
                O="$rendered" "$YQ" -i '. *= (load(strenv(O)) | ... comments = "")' "$out" \
                    || die "$srv/$rel: yq birleştirmesi başarısız (hedef geçerli YAML mi? $dst)"
                # Sunucu dosyayı her açılışta kendi biçimiyle (girinti, tırnak) yeniden yazar;
                # veri aynıysa dosyaya dokunulmaz, yoksa her apply "değişti" derdi.
                if yaml_same_data "$out" "$cur"; then cp "$cur" "$out"; fi
                add_plan "$out" "$dst" file "yml birleştirme" "$srv" "$cur"
            elif [[ $rel == plugins/* ]]; then
                log_warn "$srv: $rel atlandı — eklenti henüz config üretmedi; sunucuyu bir kez başlatıp 'mc apply $srv' tekrarlayın."
            else
                cp "$rendered" "$out"
                add_plan "$out" "$dst" file "kopya (hedef yoktu; eksik anahtarları sunucu ekler)" "$srv" ""
            fi
            ;;
        *)
            cp "$rendered" "$out"
            add_plan "$out" "$dst" file "tam kopya" "$srv" "$cur"
            ;;
    esac
}

plan_jvm_env() {
    local srv=$1 type heap gc extra flags_file opts="" args="" conc out dst cur
    type=$(server_get "$srv" TYPE)
    heap=$(server_get "$srv" HEAP)
    gc=$(server_get "$srv" GC_THREADS)
    extra=$(server_get "$srv" EXTRA_JAVA_OPTS)
    out="$STAGE/$srv/jvm.env"
    case $type in
        paper) args="--nogui" ;;
        velocity) args="" ;;
        limbo)
            # PicoLimbo Java değil; mc@.service EnvironmentFile'ı dosyayı beklediği için boş üretilir.
            [[ -z $heap$gc$extra ]] || log_warn "$srv: limbo (PicoLimbo) Java değil; HEAP/GC_THREADS/EXTRA_JAVA_OPTS yok sayıldı."
            {
                printf '%s — elle düzenlemeyin.\n' "$GEN_MARK"
                printf '# TYPE=limbo: PicoLimbo yerel ikilidir, JVM ayarı yok (ExecStart: 30-exec.conf).\n'
                printf 'JAVA_MEM=""\nJAVA_OPTS=""\nSERVER_ARGS=""\n'
            } >"$out"
            ;;
        *) die "$srv: geçersiz TYPE='$type' (paper, velocity ya da limbo olmalı)." ;;
    esac
    if [[ $type != limbo ]]; then
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
        {
            printf '%s — elle düzenlemeyin.\n' "$GEN_MARK"
            printf '# Kaynak: config/servers/%s/server.env + config/jvm/%s.flags\n' "$srv" "$type"
            printf 'JAVA_MEM=%s\n' "$(env_quote "-Xms$heap -Xmx$heap")"
            printf 'JAVA_OPTS=%s\n' "$(env_quote "$opts")"
            printf 'SERVER_ARGS=%s\n' "$(env_quote "$args")"
        } >"$out"
    fi
    dst="$SERVERS_DIR/$srv/jvm.env"
    stage_current "$srv" "$dst" "$STAGE/$srv/cur/.jvm.env" >"$STAGE/cur.path" || return 0
    cur=$(<"$STAGE/cur.path")
    add_plan "$out" "$dst" file "üretildi (systemd EnvironmentFile)" "$srv" "$cur"
}

plan_unit() { # <sunucu> <ad> <açıklama> — $STAGE/<sunucu>/<ad> hazırlanmış olmalı
    local dst cur=""
    dst="$MC_SYSTEMD_DIR/$(unit_of "$1").d/$2"
    if [[ -f $dst ]]; then cur=$dst; fi
    add_plan "$STAGE/$1/$2" "$dst" unit "$3" "$1" "$cur"
}

plan_dropins() {
    local srv=$1 cpu oom type dir after f planned=" 20-resources.conf "
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

    {
        printf '%s (config/servers/%s/server.env) — elle düzenlemeyin.\n' "$GEN_MARK" "$srv"
        printf '[Service]\n'
        [[ -z $cpu ]] || printf 'CPUWeight=%s\n' "$cpu"
        [[ -z $oom ]] || printf 'OOMScoreAdjust=%s\n' "$oom"
    } >"$STAGE/$srv/20-resources.conf"
    plan_unit "$srv" 20-resources.conf "CPUWeight/OOMScoreAdjust"

    if [[ $type == velocity ]]; then
        # Kapanışta proxy önce dursun: After= sırası durdururken tersine işler. Limbo dahil.
        after=$(list_nonproxy | sed 's/.*/mc@&.service/' | paste -sd' ' -)
        if [[ -n $after ]]; then
            {
                printf '%s — sunucu listesi config/servers/*/server.env.\n' "$GEN_MARK"
                printf '# Kapanışta önce proxy durur, oyuncular düzgün bir mesajla ayrılır.\n'
                printf '[Unit]\nAfter=%s\n' "$after"
            } >"$STAGE/$srv/10-order.conf"
            plan_unit "$srv" 10-order.conf "kapanış sırası"
            planned+="10-order.conf "
        fi
    elif [[ $type == limbo ]]; then
        {
            printf '%s (TYPE=limbo) — elle düzenlemeyin.\n' "$GEN_MARK"
            printf '# PicoLimbo yerel ikilidir: şablondaki java ExecStart sıfırlanıp değiştirilir.\n'
            printf '[Service]\nExecStart=\nExecStart=%s/%%i/pico_limbo --config server.toml\n' "$UNIT_SERVERS_DIR"
        } >"$STAGE/$srv/30-exec.conf"
        plan_unit "$srv" 30-exec.conf "PicoLimbo ExecStart"
        planned+="30-exec.conf "
    fi

    # Tür değiştiyse eskiden üretilmiş drop-in kalmasın (ör. paper'da pico_limbo ExecStart'ı).
    # Yalnız bizim işaretimizi taşıyan dosyalar silinir; elle yazılanlara dokunulmaz.
    for f in 10-order.conf 30-exec.conf; do
        [[ $planned != *" $f "* ]] || continue
        if [[ -f $dir/$f ]] && head -n1 "$dir/$f" | grep -qF "$GEN_MARK"; then
            add_plan "" "$dir/$f" unit-rm "artık gerekmiyor (TYPE=$type)" "$srv" "$dir/$f"
        fi
    done
}

plan_server() {
    local srv=$1 src_root f
    src_root="$CONFIG_DIR/servers/$srv/files"
    mkdir -p "$STAGE/$srv"
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

# Sunucu dosyasını sahibinin kimliğiyle yazar: aynı dizinde geçici dosya → 0640 → mv.
# Eksik dizinler 0750 oluşur (umask 027).
install_server_file() { # <kaynak> <hedef>
    # shellcheck disable=SC2016  # değişkenler iç kabukta genişler
    as_mc bash -c '
        set -Eeuo pipefail
        umask 027
        dst=$1 dir=${1%/*}
        mkdir -p -- "$dir"
        tmp=$(mktemp "$dir/.kami-apply.XXXXXX")
        trap '\''rm -f -- "$tmp"'\'' EXIT
        cat >"$tmp"
        chmod 0640 "$tmp"
        mv -f -- "$tmp" "$dst"' _ "$2" <"$1" \
        || die "$2 yazılamadı ($MC_USER kimliğiyle). Önceki dosyalar yazılmış olabilir; sorunu giderip yeniden çalıştırın."
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

# Deneme kipi farkında gizli değerleri gizler: secrets.env'deki değerler ve adında
# pass/secret/token geçen anahtarların değerleri '***' olur.
mask_secrets() {
    awk -v sf="$STAGE/secret-values" -v sq="''" '
        BEGIN { while ((getline v < sf) > 0) if (length(v) >= 4) sec[++n] = v }
        {
            line = $0
            for (i = 1; i <= n; i++)
                while ((p = index(line, sec[i])) > 0)
                    line = substr(line, 1, p - 1) "***" substr(line, p + length(sec[i]))
            if (line !~ /^(---|\+\+\+|@@)/ && match(substr(line, 2), /[=:]/)) {
                sep = RSTART + 1
                key = tolower(substr(line, 2, sep - 2))
                rest = substr(line, sep + 1)
                val = rest
                gsub(/^[ \t]+|[ \t\r]+$/, "", val)
                if (key ~ /pass|secret|token/ && val != "" && val != "\"\"" && val != sq && val != "***") {
                    match(rest, /^[ \t]*/)
                    line = substr(line, 1, sep) substr(rest, 1, RLENGTH) "***"
                }
            }
            print line
        }'
}

collect_secret_values() {
    : >"$STAGE/secret-values"
    [[ -r $SECRETS_FILE ]] || return 0
    (
        # shellcheck disable=SC1090
        . "$SECRETS_FILE"
        while IFS= read -r k; do
            printf '%s\n' "${!k-}"
        done < <(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)=.*/\2/p' "$SECRETS_FILE")
    ) >"$STAGE/secret-values" 2>/dev/null || true
}

# Sunucu dosyası doğru sahip/izinde mi? (içerik aynı olsa da düzeltilmesi gerekebilir)
perms_ok() {
    if ((IS_ROOT)); then
        [[ $(stat -c '%U:%G %a' -- "$1" 2>/dev/null) == "$MC_USER:$MC_GROUP 640" ]]
    else
        [[ $(stat -c '%a' -- "$1" 2>/dev/null) == 640 ]]
    fi
}

execute_plan() {
    local i out dst kind srv cur status units_changed=0 units_writable=1 s
    local -A changed=()
    local -a written=() same=()

    if ((!DRY_RUN)); then
        if ! { mkdir -p "$MC_SYSTEMD_DIR" 2>/dev/null && [[ -w $MC_SYSTEMD_DIR ]]; }; then
            units_writable=0
            log_warn "$MC_SYSTEMD_DIR yazılamıyor: systemd drop-in'leri atlanacak (root gerekir)."
        fi
        # $MC_ROOT root'undur; servers/ yoksa root oluşturur, altını minecraft yazar.
        if [[ ! -d $SERVERS_DIR ]]; then
            if ((IS_ROOT)); then
                install -d -m 0750 -o "$MC_USER" -g "$MC_GROUP" "$SERVERS_DIR"
            else
                mkdir -m 0750 "$SERVERS_DIR"
            fi
        fi
    else
        collect_secret_values
    fi

    for i in "${!PLAN_OUT[@]}"; do
        out=${PLAN_OUT[i]} dst=${PLAN_DST[i]} kind=${PLAN_KIND[i]} srv=${PLAN_SRV[i]} cur=${PLAN_CUR[i]}
        if [[ $kind == unit-rm ]]; then
            if ((DRY_RUN)); then
                status="silinecek"
                changed[$srv]=1
            elif ((!units_writable)); then
                status="atlandı"
            else
                rm -f -- "$dst"
                status="silindi"
                units_changed=1
                changed[$srv]=1
            fi
        elif [[ -n $cur ]] && cmp -s "$out" "$cur"; then
            status="aynı"
            if [[ $kind == file ]] && ! perms_ok "$dst"; then
                if ((DRY_RUN)); then
                    status="izin düzeltilecek"
                else
                    status="izin düzeltildi"
                    install_server_file "$out" "$dst"
                fi
            fi
            same+=("$dst")
        elif ((DRY_RUN)); then
            if [[ -n $cur ]]; then status="değişecek"; else status="yeni"; fi
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
            diff -u --label "$dst (şimdiki)" --label "$dst (uygulanınca)" "$cur" "$out" \
                | mask_secrets | sed 's/^/        /' || true
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
    if ((IS_ROOT)); then require_mc_user; fi # MC_GROUP'u da ayarlar
    if ((!DRY_RUN)); then
        [[ -d $MC_ROOT ]] || die "$MC_ROOT yok — önce scripts/install.sh çalıştırın."
        if ((!IS_ROOT)) && [[ -d $SERVERS_DIR && ! -w $SERVERS_DIR ]]; then
            die "$SERVERS_DIR yazılamıyor — root olarak çalıştırın (sudo mc apply)."
        fi
    fi

    STAGE=$(mktemp -d "${TMPDIR:-/tmp}/kami-apply.XXXXXX")
    for s in "${SERVERS[@]}"; do
        plan_server "$s"
    done

    if ((${#PATH_ERRORS[@]})); then
        printf '  %s\n' "${PATH_ERRORS[@]}" >&2
        die "Güvenli olmayan hedef yol(lar) — HİÇBİR dosya yazılmadı. Sunucu dizinindeki sembolik bağları kaldırın (sunucu ele geçirilmiş olabilir) ya da sahipliği düzeltin."
    fi
    if ((${#RENDER_ERRORS[@]})); then
        [[ -r $SECRETS_FILE ]] || log_warn "$SECRETS_FILE okunamadı; gizli değerler için root olarak çalıştırın."
        die "Yer tutucu hatası: ${RENDER_ERRORS[*]} — HİÇBİR dosya yazılmadı. Eksik değeri server.env, secrets.env ya da network.env'de tanımlayın."
    fi
    execute_plan
}

main "$@"
