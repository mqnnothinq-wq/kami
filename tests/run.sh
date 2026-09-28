#!/usr/bin/env bash
# Tüm testleri çalıştırır: önce betiklerde shellcheck, sonra tests/test_*.sh.
# Herhangi biri başarısızsa sıfırdan farklı çıkar.
#
# YAML testleri mikefarah yq v4 ister: PATH'teki 'yq' mikefarah değilse YQ=/yol/yq verin.
#   YQ=/yol/yq tests/run.sh
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
failed=()

section() { printf '\n== %s ==\n' "$*"; }

# --- yq ---------------------------------------------------------------------
if [[ -z ${YQ:-} ]] && command -v yq >/dev/null 2>&1; then
    YQ=$(command -v yq)
fi
yq_version=$("${YQ:-yq}" --version 2>&1 || true)
if [[ -z ${YQ:-} || $yq_version != *mikefarah* ]]; then
    printf '[hata] mikefarah yq bulunamadı (YQ=%s). YQ=/yol/yq ile çalıştırın.\n' "${YQ:-}" >&2
    exit 1
fi
export YQ

# --- shellcheck --------------------------------------------------------------
section "shellcheck"
scripts=()
while IFS= read -r -d '' f; do
    case $f in
        *.sh) scripts+=("$f") ;;
        *)
            first=""
            IFS= read -r first <"$f" || true
            if [[ $first =~ ^\#!.*(/|[[:space:]])(ba)?sh([[:space:]]|$) ]]; then scripts+=("$f"); fi
            ;;
    esac
done < <(find "$ROOT/scripts" "$ROOT/tests" -maxdepth 1 -type f -print0 | LC_ALL=C sort -z)

if ! command -v shellcheck >/dev/null 2>&1; then
    printf '[hata] shellcheck kurulu değil.\n' >&2
    failed+=(shellcheck)
elif (cd "$ROOT" && shellcheck -x "${scripts[@]#"$ROOT"/}"); then
    printf 'tamam: %d betik temiz (%s)\n' "${#scripts[@]}" "${scripts[*]#"$ROOT"/}"
else
    failed+=(shellcheck)
fi

# --- testler -----------------------------------------------------------------
for t in "$ROOT"/tests/test_*.sh; do
    [[ -f $t ]] || continue
    section "$(basename "$t")"
    if bash "$t"; then
        printf 'GEÇTİ: %s\n' "$(basename "$t")"
    else
        printf 'KALDI: %s\n' "$(basename "$t")"
        failed+=("$(basename "$t")")
    fi
done

section "özet"
if ((${#failed[@]})); then
    printf 'BAŞARISIZ: %s\n' "${failed[*]}"
    exit 1
fi
printf 'Tüm testler geçti.\n'
