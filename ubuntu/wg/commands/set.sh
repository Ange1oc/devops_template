# shellcheck shell=bash

CMD_SUMMARY='изменить параметры узла (endpoint, порт, MTU, маршрутизация, NAT)'
CMD_GROUP=setup
CMD_MUTATES=1

cmd_usage() {
    cat <<'EOF'
Использование: wg-network [-i IFACE] set [опции]

  --endpoint HOST:PORT  публичный адрес hub для новых приглашений (на работающие peer не влияет)
  --port N              UDP-порт hub (peer потребуется peer set hub --endpoint)
  --forward on|off      маршрутизация между peer через hub
  --nat IFACE|off       выход peer в интернет через IFACE (masquerade)
  --mtu N|auto          MTU туннеля
  --table auto|off|N    куда ставить маршруты (wg-quick Table=)
  --no-firewall         не открывать новый порт в UFW

Почти все параметры меняют [Interface] — применение перезапустит интерфейс под таймером отката.
EOF
}

cmd_run() {
    local endpoint='' port='' forward='' nat='' mtu='' table='' firewall=1
    while (($#)); do
        case $1 in
            --endpoint) require_arg "$@"; endpoint=$2; shift 2 ;;
            --port) require_arg "$@"; port=$2; shift 2 ;;
            --forward) require_arg "$@"; parse_bool "$2" forward || die_usage '--forward on|off'; shift 2 ;;
            --nat) require_arg "$@"; nat=$2; shift 2 ;;
            --mtu) require_arg "$@"; mtu=$2; shift 2 ;;
            --table) require_arg "$@"; table=$2; shift 2 ;;
            --no-firewall) firewall=0; shift ;;
            *) die_unknown_arg "$1" ;;
        esac
    done
    [[ -n $endpoint$port$forward$nat$mtu$table ]] || die_usage 'не указано, что менять'
    [[ -z $port ]] || is_port "$port" || die_usage '--port: 1..65535'
    [[ -z $mtu || $mtu == auto ]] || is_mtu "$mtu" || die_usage '--mtu: 1280..9000 или auto'
    [[ -z $table ]] || is_table "$table" || die_usage '--table: auto, off или номер'
    if [[ -n $nat && $nat != off ]]; then
        is_iface "$nat" && iface_exists "$nat" || die_usage "--nat: интерфейс $nat не найден"
    fi

    require_managed
    st_node_load
    if [[ -n $endpoint$port$forward$nat ]]; then
        require_role hub
    fi
    if [[ $forward == 1 || ( -n $nat && $nat != off ) ]]; then
        has_cmd iptables || die '--forward/--nat требуют iptables'
    fi
    if [[ -n $port && $port != "${NODE[LISTEN_PORT]-}" ]]; then
        guard_init_target 1 "$port"
        if [[ -n $(st_peer_names) ]] && ! ((OPT_DRY_RUN)); then
            log_warn "peer подключаются к порту ${NODE[LISTEN_PORT]}: после смены они потеряют связь, пока на каждом не выполнят peer set hub --endpoint HOST:$port"
            confirm_typed "$IFACE" 'Смена порта hub.' || die_code "$E_REFUSED" 'отменено'
        fi
    fi

    tx_begin set
    if [[ -n $port ]]; then
        NODE[LISTEN_PORT]=$port
        [[ -z $endpoint && ${NODE[ENDPOINT]##*:} != "$port" ]] && log_warn "endpoint ${NODE[ENDPOINT]} всё ещё указывает старый порт — поменяй --endpoint, если это не проброс"
    fi
    if [[ -n $endpoint ]]; then
        endpoint="$(endpoint_with_port "$endpoint" "${NODE[LISTEN_PORT]}")"
        is_endpoint "$endpoint" || die_usage "некорректный --endpoint: $endpoint"
        NODE[ENDPOINT]=$endpoint
    fi
    [[ -n $forward ]] && NODE[FORWARD]=$forward
    [[ -n $nat ]] && NODE[NAT]=${nat/#off/}
    [[ -n $mtu ]] && NODE[MTU]=${mtu/#auto/}
    [[ -n $table ]] && NODE[TABLE]=$table
    st_node_save
    audit "set endpoint=${endpoint:--} port=${port:--} forward=${forward:--} nat=${nat:--} mtu=${mtu:--} table=${table:--}"

    apply_changes
    tx_commit
    if [[ -n $port ]] && ((firewall)) && ! ((OPT_DRY_RUN)) && [[ ${APPLIED:-0} == 1 ]] && sys_firewall_open "$port"; then
        NODE[FIREWALL_PORT]=$port
        st_node_save
        log_warn 'старое правило UFW не удаляется автоматически: убери его вручную, когда peer переедут'
    fi
    if [[ -n $forward ]] && ! ((OPT_DRY_RUN)); then
        log_info 'peer, приглашённые ранее, получили маршруты по старым правилам; при необходимости: на peer — wg-network peer set hub --routes ...'
    fi
    log_ok "$IFACE: $(outcome_text)"
}
