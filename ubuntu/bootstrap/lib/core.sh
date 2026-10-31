# shellcheck shell=bash
# Logging, exit codes, temp files, atomic writes, KEY=VALUE files, list helpers.

readonly E_ERROR=1 E_USAGE=2 E_REFUSED=3 E_ROLLED_BACK=4 E_BUSY=5
# Field separator for internal tables and the transaction journal.
readonly FS=$'\x1f'

declare -ga EXIT_HOOKS=() TMP_PATHS=() WARNINGS=()

on_exit() {
    local rc=$? hook
    trap - EXIT
    for hook in "${EXIT_HOOKS[@]}"; do
        "$hook" "$rc" || true
    done
    ((${#TMP_PATHS[@]})) && rm -rf -- "${TMP_PATHS[@]}"
    exit "$rc"
}

make_tmp_dir() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/.ubb.XXXXXX")" || die 'не удалось создать временный каталог'
    TMP_PATHS+=("$d")
    printf '%s' "$d"
}

setup_colors() {
    if [[ -t 2 && -z ${NO_COLOR-} && ${OPT_COLOR:-1} == 1 ]]; then
        C_RED=$'\033[0;31m' C_GREEN=$'\033[0;32m' C_YELLOW=$'\033[0;33m'
        C_BLUE=$'\033[0;34m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m' C_RESET=$'\033[0m'
    else
        C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_DIM='' C_RESET=''
    fi
}

# Messages go to stderr and, when a run log is open, to the log file.
_log_file() {
    [[ -n ${LOG_FILE-} ]] || return 0
    printf '%(%F %T)T %s %s\n' -1 "$1" "$2" >> "$LOG_FILE" 2>/dev/null || true
}
log_info()  { _log_file INFO "$*"; ((OPT_QUIET)) || printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
log_ok()    { _log_file OK "$*"; ((OPT_QUIET)) || printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
log_warn()  { _log_file WARN "$*"; WARNINGS+=("$*"); printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { _log_file ERROR "$*"; printf '%sERROR:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
log_title() { _log_file TITLE "$*"; ((OPT_QUIET)) || printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET" >&2; }
log_plain() { _log_file TEXT "$*"; ((OPT_QUIET)) || printf '%s\n' "$*" >&2; }
log_debug() { _log_file DEBUG "$*"; ((OPT_VERBOSE)) && printf '%s·%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2; return 0; }

die() {
    log_error "$*"
    exit "$E_ERROR"
}

die_code() {
    local code=$1
    shift
    log_error "$*"
    exit "$code"
}

die_usage() {
    log_error "$*"
    printf 'Справка: ubuntu-bootstrap %s --help\n' "${UBB_CMD:-}" >&2
    exit "$E_USAGE"
}

require_arg() {
    [[ $# -ge 2 && -n $2 && $2 != --* ]] || die_usage "опция $1 требует значение"
}

is_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]]
}

require_root() {
    is_root || die 'нужны права root: запусти через sudo'
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Event for journald (journalctl -t ubuntu-bootstrap).
audit_log() {
    has_cmd logger || return 0
    logger -t ubuntu-bootstrap -p user.notice -- "user=${SUDO_USER:-${USER:-root}} $*" 2>/dev/null || true
}

now_epoch() { printf '%(%s)T' -1; }
now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Replace a file with stdin atomically; mode and owner are set before the file appears at its path.
write_atomic() {
    local dest=$1 mode=${2:-644} owner=${3-} tmp
    tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX")" || die "не удалось создать временный файл рядом с $dest"
    if ! cat > "$tmp" || ! chmod "$mode" "$tmp" || { [[ -n $owner ]] && ! chown "$owner" "$tmp"; } ||
        ! sync -- "$tmp" 2>/dev/null || ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        die "не удалось записать $dest"
    fi
}

sha256_str() {
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

# KEY=VALUE files are parsed, never sourced. Values are single-line and unquoted.
kv_get() {
    local file=$1 want=$2 line value=''
    [[ -r $file ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ ${line%%=*} == "$want" ]] && value=${line#*=}
    done < "$file"
    printf '%s' "$value"
}

# kv_load FILE ARRAY [ORDER_ARRAY]: all pairs into an associative array, keys in file order into ORDER_ARRAY.
kv_load() {
    local file=$1 line key
    local -n _kv_dest=$2
    local -a _kv_keys=()
    [[ -r $file ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line == *=* ]] || return 1
        key=${line%%=*}
        key=${key//[[:space:]]/}
        [[ $key =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
        [[ -n ${_kv_dest[$key]+x} ]] || _kv_keys+=("$key")
        _kv_dest["$key"]=${line#*=}
    done < "$file"
    if [[ -n ${3-} ]]; then
        local -n _kv_order=$3
        _kv_order=("${_kv_keys[@]}")
    fi
    return 0
}

# kv_save FILE MODE ARRAY KEY...: writes the given keys in that order.
kv_save() {
    local file=$1 mode=$2 key
    local -n _kv_src=$3
    shift 3
    for key in "$@"; do
        printf '%s=%s\n' "$key" "${_kv_src[$key]-}"
    done | write_atomic "$file" "$mode"
}

# kv_set FILE KEY VALUE [MODE]: changes or appends one pair, keeping the others and their order.
kv_set() {
    local file=$1 key=$2 value=$3 mode=${4:-600}
    local -A kv=()
    local -a order=()
    kv_load "$file" kv order || die "повреждён файл $file"
    [[ -n ${kv[$key]+x} ]] || order+=("$key")
    kv[$key]=$value
    kv_save "$file" "$mode" kv "${order[@]}"
}

# split_list 'a, b;c' ARRAY: splits on comma, semicolon and whitespace, dropping empty items.
split_list() {
    local -n _sl_out=$2
    local item
    _sl_out=()
    local IFS=$', ;'
    for item in $1; do
        [[ -n $item ]] && _sl_out+=("$item")
    done
}

join_by() {
    local sep=$1 first=${2-}
    shift 2 || return 0
    printf '%s' "$first" "${@/#/$sep}"
}

in_list() {
    local needle=$1
    shift
    local x
    for x in "$@"; do [[ $x == "$needle" ]] && return 0; done
    return 1
}

json_str() {
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\t'/\\t}
    printf '"%s"' "$s"
}

# 2G / 512M / 4096 (bytes) -> megabytes.
size_to_mb() {
    local s=${1^^} n
    case $s in
        *G) n=${s%G}; is_uint "$n" && printf '%d' $((n * 1024)) ;;
        *M) n=${s%M}; is_uint "$n" && printf '%d' "$n" ;;
        *) is_uint "$s" && printf '%d' $((s / 1024 / 1024)) ;;
    esac
}
