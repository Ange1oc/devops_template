# shellcheck shell=bash
# Module registry: discovery, metadata, dependency resolution.
#
# A module is modules/<name>.sh (or /etc/ubuntu-bootstrap/modules.d/<name>.sh for custom ones):
#   MOD_SUMMARY='what it does'    MOD_GROUP=security|system|services|access
#   MOD_DEPS=(users)              hard dependencies, enabled automatically
#   MOD_AFTER=(docker)            ordering: after these modules when they are enabled
#   MOD_DEFAULT=1                 part of the default set (no profile given)
#   MOD_ALWAYS=1                  runs on every apply even when already applied
#   MOD_CONTAINER=0               skipped inside containers
#   mod_options()                 option declarations (opt ...)
#   mod_check()                   0 when the desired state is already reached
#   mod_apply()                   idempotent apply via file_write/run/undo
#   mod_verify()                  post-apply check
#   mod_audit()                   checks for the audit command (check_* helpers)
#   mod_wizard()                  extra wizard hints and defaults (optional)
#   mod_confirmed()               actions after a risky change is confirmed (optional)

declare -gA MOD_FILE_OF=() MOD_SUMMARY_OF=() MOD_GROUP_OF=() MOD_DEPS_OF=() MOD_AFTER_OF=() MOD_CONTAINER_OF=()
declare -ga MOD_ALL=() MOD_DEFAULT_SET=()
# Canonical order; dependencies refine it, unknown modules go after it alphabetically.
readonly MOD_CANON=(preflight base time users ssh firewall fail2ban updates sysctl limits swap journald docker nginx certbot git wg-network)

# shellcheck disable=SC2329  # the stubs are called indirectly from runner/status/audit
_mod_reset() {
    MOD_SUMMARY='' MOD_GROUP=other MOD_DEPS=() MOD_AFTER=() MOD_DEFAULT=0 MOD_CONTAINER=1 MOD_ALWAYS=0
    mod_options() { :; }
    mod_check() { return 1; }
    mod_apply() { :; }
    mod_verify() { return 0; }
    mod_audit() { :; }
    mod_wizard() { :; }
    mod_confirmed() { :; }
}

# Load a module into the current shell (mod_* functions are replaced).
module_load() {
    local name=$1
    [[ -n ${MOD_FILE_OF[$name]-} ]] || die "неизвестный модуль: $name"
    _mod_reset
    CUR_MODULE_LOAD=$name
    # shellcheck source=/dev/null
    source "${MOD_FILE_OF[$name]}"
}

modules_discover() {
    local dir f name d
    local -a dirs=("$UBB_HOME/modules")
    [[ -n ${UBB_MODULE_PATH-} ]] && dirs+=("$UBB_MODULE_PATH")
    [[ -d $USER_MODULES_DIR ]] && dirs+=("$USER_MODULES_DIR")
    for dir in "${dirs[@]}"; do
        for f in "$dir"/*.sh; do
            [[ -f $f ]] || continue
            name=${f##*/}
            name=${name%.sh}
            is_name "$name" || die "некорректное имя модуля: $f"
            MOD_FILE_OF[$name]=$f
        done
    done
    for name in "${!MOD_FILE_OF[@]}"; do
        module_load "$name"
        MOD_SUMMARY_OF[$name]=$MOD_SUMMARY MOD_GROUP_OF[$name]=$MOD_GROUP MOD_CONTAINER_OF[$name]=$MOD_CONTAINER
        MOD_DEPS_OF[$name]="${MOD_DEPS[*]}" MOD_AFTER_OF[$name]="${MOD_AFTER[*]}"
        mod_options
        ((MOD_DEFAULT)) && MOD_DEFAULT_SET+=("$name")
    done
    unset CUR_MODULE_LOAD
    _mod_reset
    modules_sort MOD_ALL "${!MOD_FILE_OF[@]}"
    modules_sort MOD_DEFAULT_SET "${MOD_DEFAULT_SET[@]}"
    for name in "${MOD_ALL[@]}"; do
        for d in ${MOD_DEPS_OF[$name]} ${MOD_AFTER_OF[$name]}; do
            [[ -n ${MOD_FILE_OF[$d]-} ]] || die "модуль $name ссылается на неизвестный модуль $d"
        done
    done
}

_mod_canon_index() {
    local i
    for i in "${!MOD_CANON[@]}"; do
        [[ ${MOD_CANON[i]} == "$1" ]] && { printf '%d' "$i"; return; }
    done
    printf '%d' "${#MOD_CANON[@]}"
}

# modules_resolve OUT NAME...: adds transitive dependencies and sorts.
modules_resolve() {
    local -n _mr_out=$1
    shift
    local -a queue=("$@") closed=()
    local m d
    while ((${#queue[@]})); do
        m=${queue[0]}
        queue=("${queue[@]:1}")
        [[ -n ${MOD_FILE_OF[$m]-} ]] || die "неизвестный модуль: $m (см. ubuntu-bootstrap modules)"
        in_list "$m" "${closed[@]}" && continue
        closed+=("$m")
        for d in ${MOD_DEPS_OF[$m]}; do
            in_list "$d" "${closed[@]}" || queue+=("$d")
        done
    done
    modules_sort _mr_out "${closed[@]}"
}

# Kahn's topological sort; ties are broken by canonical index, then by name. A cycle is fatal.
modules_sort() {
    local -n _ms_out=$1
    shift
    local -a nodes=("$@")
    local -A indeg=() idx=()
    local m d best best_i cur_i
    _ms_out=()
    ((${#nodes[@]})) || return 0
    for m in "${nodes[@]}"; do
        indeg[$m]=0
        idx[$m]="$(_mod_canon_index "$m")"
    done
    for m in "${nodes[@]}"; do
        for d in ${MOD_DEPS_OF[$m]-} ${MOD_AFTER_OF[$m]-}; do
            [[ -n ${indeg[$d]+x} ]] && indeg[$m]=$((indeg[$m] + 1))
        done
    done
    while ((${#_ms_out[@]} < ${#nodes[@]})); do
        best='' best_i=999999
        for m in "${nodes[@]}"; do
            [[ ${indeg[$m]} == 0 ]] || continue
            cur_i=${idx[$m]}
            if ((cur_i < best_i)) || { ((cur_i == best_i)) && [[ $m < $best ]]; }; then
                best=$m best_i=$cur_i
            fi
        done
        [[ -n $best ]] || die "циклическая зависимость модулей: $(for m in "${nodes[@]}"; do [[ ${indeg[$m]} -gt 0 ]] && printf '%s ' "$m"; done)"
        _ms_out+=("$best")
        indeg[$best]=-1
        for m in "${nodes[@]}"; do
            [[ ${indeg[$m]} -gt 0 ]] || continue
            for d in ${MOD_DEPS_OF[$m]-} ${MOD_AFTER_OF[$m]-}; do
                [[ $d == "$best" ]] && indeg[$m]=$((indeg[$m] - 1))
            done
        done
    done
}

# Modules from the config plus --only/--skip, with dependencies; preflight always goes first.
modules_selected() {
    local -n _sel_out=$1
    local -a wanted=() skip=()
    local m
    if ((${#OPT_ONLY[@]})); then
        wanted=("${OPT_ONLY[@]}")
    else
        config_modules wanted
    fi
    skip=("${OPT_SKIP[@]}")
    modules_resolve _sel_out "${wanted[@]}"
    if ((${#skip[@]})); then
        local -a kept=()
        for m in "${_sel_out[@]}"; do in_list "$m" "${skip[@]}" || kept+=("$m"); done
        _sel_out=("${kept[@]}")
    fi
    if [[ -n ${MOD_FILE_OF[preflight]-} ]] && ! in_list preflight "${skip[@]}" && ! in_list preflight "${_sel_out[@]}"; then
        _sel_out=(preflight "${_sel_out[@]}")
    fi
}

module_enabled() {
    in_list "$1" "${SELECTED_MODULES[@]}"
}

module_applied() {
    [[ $(module_state_get "$1" STATUS) == applied ]]
}
