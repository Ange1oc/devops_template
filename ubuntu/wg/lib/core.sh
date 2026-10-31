# shellcheck shell=bash
# Base helpers: output, exit codes, confirmations, files, KEY=VALUE storage.

# Exit codes are a contract for automation (docs/en/commands.md).
readonly E_OK=0 E_ERROR=1 E_USAGE=2 E_REFUSED=3 E_ROLLED_BACK=4 E_BUSY=5 E_NO_HANDSHAKE=6

# Field separator of internal tables: never present in a validated value.
readonly FS=$'\x1f'

# Exit handlers (transaction rollback, temporary files).
declare -ga EXIT_HOOKS=() TMP_PATHS=()

on_exit() {
    local rc=$? hook
    trap - EXIT
    for hook in "${EXIT_HOOKS[@]}"; do
        "$hook" "$rc" || true
    done
    ((${#TMP_PATHS[@]})) && rm -rf -- "${TMP_PATHS[@]}"
    exit "$rc"
}

# make_tmp_dir VAR [PARENT]: a directory removed on exit. The path is stored in VAR instead of
# printed, because registering it inside $(...) would happen in a subshell and be lost.
make_tmp_dir() {
    local -n _mtd_out=$1
    local _mtd_d
    _mtd_d="$(mktemp -d "${2:-${TMPDIR:-/tmp}}/.wgn.XXXXXX")" || die 'не удалось создать временный каталог'
    TMP_PATHS+=("$_mtd_d")
    _mtd_out=$_mtd_d
}

# Option parsing errors can be printed before setup_colors runs.
C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_DIM='' C_RESET=''

setup_colors() {
    if [[ -t 2 && -z ${NO_COLOR-} && ${OPT_COLOR:-1} == 1 ]]; then
        C_RED=$'\033[0;31m' C_GREEN=$'\033[0;32m' C_YELLOW=$'\033[0;33m'
        C_BLUE=$'\033[0;34m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m' C_RESET=$'\033[0m'
    else
        C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_DIM='' C_RESET=''
    fi
}

# All messages go to stderr: stdout carries only data (keys, tokens, JSON).
log_info()  { ((OPT_QUIET)) || printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
log_ok()    { ((OPT_QUIET)) || printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
log_warn()  { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%sERROR:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
log_title() { ((OPT_QUIET)) || printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET" >&2; }
log_plain() { ((OPT_QUIET)) || printf '%s\n' "$*" >&2; }

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
    printf 'Справка: wg-network %s --help\n' "${WGN_CMD:-}" >&2
    exit "$E_USAGE"
}

die_unknown_arg() {
    die_usage "неизвестный аргумент: $1"
}

# In a parser: --name) require_arg "$@"; name=$2; shift 2 ;;
require_arg() {
    [[ $# -ge 2 && -n $2 && $2 != --* ]] || die_usage "опция $1 требует значение"
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'нужны права root: запусти через sudo'
}

require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "не найдена команда: $cmd"
    done
}

# output_has ERE CMD...: does the output of CMD match? Not "cmd | grep -q": grep exits on the
# first match, cmd gets SIGPIPE and, with pipefail, the pipeline reports a false failure.
output_has() {
    local pattern=$1 out
    shift
    out="$("$@" 2>/dev/null)" || true
    grep -Eq -- "$pattern" <<< "$out"
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Audit trail in syslog/journald (journalctl -t wg-network): who changed what.
audit() {
    has_cmd logger || return 0
    logger -t wg-network -p user.notice -- "iface=${IFACE:--} user=${SUDO_USER:-${USER:-root}} $*" 2>/dev/null || true
}

# Without a TTY and without --yes the answer is always "no": the safe default for automation.
confirm() {
    local answer
    ((OPT_YES)) && return 0
    [[ -t 0 ]] || return 1
    read -r -p "$1 [y/N] " answer || return 1
    [[ ${answer,,} =~ ^(y|yes|д|да)$ ]]
}

# For dangerous operations: the whole word must be typed, a stray Enter is not enough.
confirm_typed() {
    local word=$1 prompt=$2 answer
    ((OPT_YES)) && return 0
    [[ -t 0 ]] || return 1
    read -r -p "$prompt Введи '$word' для подтверждения: " answer || return 1
    [[ $answer == "$word" ]]
}

now_epoch() {
    printf '%(%s)T' -1
}

now_iso() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# write_atomic DEST MODE < data: readers never see a partial file, and data reaches the disk
# before the rename. The temporary file is created under umask 077.
write_atomic() {
    local dest=$1 mode=$2 tmp
    tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX")" || die "не удалось создать временный файл рядом с $dest"
    if ! cat > "$tmp" || ! chmod "$mode" "$tmp" || ! sync -- "$tmp" 2>/dev/null || ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        die "не удалось записать $dest"
    fi
}

sha256_of() {
    [[ -f $1 ]] || return 0
    sha256sum -- "$1" | cut -d' ' -f1
}

# KEY=VALUE files are parsed, never sourced; values cannot contain newlines.
kv_get() {
    local file=$1 want=$2 line value=''
    [[ -r $file ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ ${line%%=*} == "$want" ]] && value=${line#*=}
    done < "$file"
    printf '%s' "$value"
}

# kv_load FILE ARRAY: read all pairs into an associative array.
kv_load() {
    local file=$1 line
    local -n _kv_dest=$2
    _kv_dest=()
    [[ -r $file ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *=* && $line != \#* ]] || continue
        _kv_dest[${line%%=*}]=${line#*=}
    done < "$file"
}

# kv_save FILE ARRAY KEY...: write the keys in the given order, empty values included.
kv_save() {
    local file=$1 key
    local -n _kv_src=$2
    shift 2
    for key in "$@"; do
        printf '%s=%s\n' "$key" "${_kv_src[$key]-}"
    done | write_atomic "$file" 600
}

# split_csv "a, b,c" ARRAY: split into non-empty elements.
split_csv() {
    local -n _csv_out=$2
    local item
    _csv_out=()
    local IFS=,
    for item in $1; do
        item=${item//[[:space:]]/}
        [[ -n $item ]] && _csv_out+=("$item")
    done
}

join_by() {
    local sep=$1 first=${2-}
    shift 2 || return 0
    printf '%s' "$first" "${@/#/$sep}"
}

# Create a file with a secret: never through an existing file or a planted symlink, mode 600
# from the first byte (noclobber gives O_EXCL).
write_secret_file() {
    local path=$1
    if [[ -e $path || -L $path ]]; then
        ((OPT_FORCE)) || die "$path уже существует (--force — заменить)"
        rm -f -- "$path"
    fi
    (set -C && umask 077 && cat > "$path") || die "не удалось создать $path"
}

json_str() {
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

human_bytes() {
    local b=$1 unit=B value
    local -a units=(KiB MiB GiB TiB)
    if ((b < 1024)); then
        printf '%d B' "$b"
        return
    fi
    value=$b
    for unit in "${units[@]}"; do
        if ((value < 1024 * 1024)) || [[ $unit == TiB ]]; then
            printf '%d.%d %s' $((value / 1024)) $((value % 1024 * 10 / 1024)) "$unit"
            return
        fi
        value=$((value / 1024))
    done
}

human_age() {
    local s=$1
    if ((s < 60)); then
        printf '%ds' "$s"
    elif ((s < 3600)); then
        printf '%dm' $((s / 60))
    elif ((s < 86400)); then
        printf '%dh' $((s / 3600))
    else
        printf '%dd' $((s / 86400))
    fi
}
