# shellcheck shell=bash
# Minimal test framework: no dependencies, readable output, non-zero exit on failure.

T_PASS=0
T_FAIL=0
T_FAILED=()

t_section() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

t_ok() {
    T_PASS=$((T_PASS + 1))
    printf '  \033[32mok\033[0m   %s\n' "$1"
}

t_fail() {
    T_FAIL=$((T_FAIL + 1))
    T_FAILED+=("$1")
    printf '  \033[31mFAIL\033[0m %s\n' "$1"
    [[ -n ${2-} ]] && printf '%s\n' "$2" | sed 's/^/       /' | tail -60
    return 0
}

t_skip() { printf '  \033[33mskip\033[0m %s\n' "$1"; }

assert_eq() { if [[ $2 == "$3" ]]; then t_ok "$1"; else t_fail "$1" "ожидалось: '$3'"$'\n'"получено:  '$2'"; fi; }
assert_true() { local d=$1; shift; if "$@"; then t_ok "$d"; else t_fail "$d" "команда вернула ошибку: $*"; fi; }
assert_false() { local d=$1; shift; if "$@"; then t_fail "$d" "команда должна была вернуть ошибку: $*"; else t_ok "$d"; fi; }
assert_contains() { if [[ $2 == *"$3"* ]]; then t_ok "$1"; else t_fail "$1" "нет подстроки '$3' в:"$'\n'"$2"; fi; }
assert_not_contains() { if [[ $2 != *"$3"* ]]; then t_ok "$1"; else t_fail "$1" "подстрока '$3' не должна встречаться в:"$'\n'"$2"; fi; }
assert_rc() { if [[ $2 == "$3" ]]; then t_ok "$1"; else t_fail "$1" "код выхода $3, ожидался $2"$'\n'"${4-}"; fi; }
assert_file() { if [[ -f $2 ]]; then t_ok "$1"; else t_fail "$1" "нет файла $2"; fi; }
assert_no_file() { if [[ ! -e $2 ]]; then t_ok "$1"; else t_fail "$1" "файл $2 не должен существовать"; fi; }

t_summary() {
    local name
    printf '\n\033[1mИтог: %d ok, %d fail\033[0m\n' "$T_PASS" "$T_FAIL"
    for name in "${T_FAILED[@]}"; do printf '  FAIL: %s\n' "$name"; done
    ((T_FAIL == 0))
}
