# shellcheck shell=bash

CMD_SUMMARY='состояние модулей: применён, устарел, не применён'
CMD_GROUP=inspect

cmd_usage() {
    cat <<'EOT'
Использование: ubuntu-bootstrap status [--all]

Для каждого выбранного модуля: достигнуто ли желаемое состояние (mod_check), когда применялся,
совпадает ли конфигурация. --all — все модули, не только выбранные. Код выхода 0 — всё актуально.
EOT
}

cmd_run() {
    local m st when state hash cur rc=0 first=1
    local -a mods=()
    config_load
    if [[ ${1-} == --all ]]; then mods=("${MOD_ALL[@]}"); else runner_select; mods=("${SELECTED_MODULES[@]}"); fi
    SELECTED_MODULES=("${mods[@]}")
    ((OPT_JSON)) && printf '['
    for m in "${mods[@]}"; do
        module_load "$m"
        CUR_MODULE_LOAD=$m
        st="$(module_state_get "$m" STATUS)"
        when="$(module_state_get "$m" APPLIED_AT)"
        hash="$(module_state_get "$m" CONFIG_HASH)"
        if ((F_CONTAINER)) && ((MOD_CONTAINER == 0)); then
            state=n/a
        elif mod_check 2>/dev/null; then
            state=ok
            [[ -n $hash && $hash != "$(module_config_hash "$m")" ]] && { state=config-changed; rc=1; }
        else
            state=pending
            rc=1
        fi
        if ((OPT_JSON)); then
            ((first)) || printf ','
            first=0
            printf '{"module":%s,"state":%s,"last_status":%s,"applied_at":%s}' "$(json_str "$m")" "$(json_str "$state")" "$(json_str "$st")" "$(json_str "$when")"
        else
            case $state in
                ok) printf '  %s✓%s ' "$C_GREEN" "$C_RESET" ;;
                n/a) printf '  %s·%s ' "$C_DIM" "$C_RESET" ;;
                *) printf '  %s○%s ' "$C_YELLOW" "$C_RESET" ;;
            esac
            printf '%-12s %-15s %-10s %s\n' "$m" "$state" "${st:--}" "${when:+применён $when}"
        fi
    done
    unset CUR_MODULE_LOAD
    ((OPT_JSON)) && printf ']\n'
    if pending_exists; then
        log_warn "модуль $(kv_get "$PENDING_FILE" MODULE) ждёт подтверждения до $(date -d "@$(kv_get "$PENDING_FILE" DEADLINE)" +%T): sudo ubuntu-bootstrap confirm"
        rc=1
    fi
    return "$rc"
}
