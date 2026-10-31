# shellcheck shell=bash

CMD_SUMMARY='состояние узла, интерфейса и peer'
CMD_GROUP=diag
CMD_READONLY=1

cmd_usage() {
    echo 'Использование: wg-network [-i IFACE] status [--json]'
}

status_json() {
    local pending=false drift=false changes=false valid=true
    pending_exists && pending=true
    drift_detected && drift=true
    if st_validate >/dev/null; then
        plan_build
        [[ $PLAN_CLASS == none || $PLAN_CLASS == rewrite ]] || changes=true
    else
        valid=false
    fi
    printf '{"interface":%s,"role":%s,"name":%s,"public_key":%s,"address":%s,"address6":%s,' \
        "$(json_str "$IFACE")" "$(json_str "${NODE[ROLE]}")" "$(json_str "${NODE[NAME]}")" \
        "$(json_str "$(node_public_key)")" "$(json_str "${NODE[ADDRESS]}")" "$(json_str "${NODE[ADDRESS6]-}")"
    printf '"listen_port":%s,"endpoint":%s,"forward":%s,"nat":%s,"unit":%s,"up":%s,' \
        "$(is_port "${NODE[LISTEN_PORT]-}" && echo "${NODE[LISTEN_PORT]}" || echo null)" "$(json_str "${NODE[ENDPOINT]-}")" "$([[ ${NODE[FORWARD]} == 1 ]] && echo true || echo false)" \
        "$(json_str "${NODE[NAT]-}")" "$(json_str "$(unit_state)")" "$(iface_running && echo true || echo false)"
    printf '"state_valid":%s,"pending_confirmation":%s,"manual_edits":%s,"unapplied_changes":%s,"peers":%s}\n' \
        "$valid" "$pending" "$drift" "$changes" "$(peers_json)"
}

cmd_run() {
    local json=0
    while (($#)); do
        case $1 in
            --json) json=1; shift ;;
            *) die_unknown_arg "$1" ;;
        esac
    done
    require_managed
    st_node_load
    if ((json)); then
        status_json
        return 0
    fi

    printf 'Интерфейс:  %s (%s)\n' "$IFACE" "$(unit_state)"
    printf 'Роль:       %s, имя %s\n' "${NODE[ROLE]}" "${NODE[NAME]}"
    printf 'PublicKey:  %s\n' "$(node_public_key)"
    printf 'Адрес:      %s%s\n' "${NODE[ADDRESS]}" "${NODE[ADDRESS6]:+, ${NODE[ADDRESS6]}}"
    if [[ ${NODE[ROLE]} == hub ]]; then
        printf 'Endpoint:   %s (порт %s)\n' "${NODE[ENDPOINT]}" "${NODE[LISTEN_PORT]}"
        printf 'Режим:      %s%s\n' "$([[ ${NODE[FORWARD]} == 1 ]] && echo 'маршрутизация между peer' || echo 'peer видят только hub')" \
            "${NODE[NAT]:+, NAT через ${NODE[NAT]}}"
    fi
    [[ -n ${NODE[MTU]-} ]] && printf 'MTU:        %s\n' "${NODE[MTU]}"
    [[ ${NODE[TABLE]} != auto ]] && printf 'Table:      %s\n' "${NODE[TABLE]}"

    pending_exists && log_warn "конфигурация ждёт подтверждения до $(date -d "@$(kv_get "$ST_PENDING" DEADLINE)" +%T): wg-network -i $IFACE confirm"
    drift_detected && log_warn "$LIVE_CONF изменён вручную (wg-network plan --diff)"
    if st_validate >/dev/null; then
        plan_build
        [[ $PLAN_CLASS == none || $PLAN_CLASS == rewrite ]] || log_warn "есть неприменённые изменения: wg-network -i $IFACE plan"
    else
        log_error "состояние повреждено: wg-network -i $IFACE doctor"
    fi

    echo
    peers_table
}
