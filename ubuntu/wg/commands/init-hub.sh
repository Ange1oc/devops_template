# shellcheck shell=bash

CMD_SUMMARY='сделать этот сервер hub (центром сети)'
CMD_GROUP=setup
CMD_MUTATES=1

cmd_usage() {
    cat <<EOF
Использование: wg-network [-i IFACE] init hub --endpoint HOST[:PORT] [опции]

  --endpoint HOST[:PORT]  публичный адрес, по которому peer подключаются к hub
  --address IP/LEN        адрес hub и размер сети (по умолчанию $DEFAULT_HUB_ADDRESS)
  --address6 CIDR|auto    включить IPv6 (dual-stack); auto — случайный ULA /64 (RFC 4193)
  --port N                UDP-порт (по умолчанию $DEFAULT_PORT)
  --forward               маршрутизировать трафик между peer (иначе peer видят только hub)
  --nat IFACE             выпускать peer в интернет через IFACE (masquerade, exit node)
  --mtu N                 MTU туннеля (по умолчанию wg-quick вычисляет сам)
  --table auto|off|N      куда ставить маршруты (wg-quick Table=)
  --name NAME             имя узла (по умолчанию hub)
  --no-firewall           не открывать порт в UFW
  --force                 переинициализировать (ключ и peer сохраняются) или заменить чужой конфиг

Повторный init hub --force меняет параметры сети, сохраняя ключ и peer.
Пример:
  wg-network init hub --endpoint 203.0.113.10
EOF
}

cmd_run() {
    local endpoint='' address=$DEFAULT_HUB_ADDRESS address6='' port=$DEFAULT_PORT forward=0 nat='' mtu='' table=auto
    local name=hub firewall=1 force=$OPT_FORCE

    while (($#)); do
        case $1 in
            --endpoint) require_arg "$@"; endpoint=$2; shift 2 ;;
            --address) require_arg "$@"; address=$2; shift 2 ;;
            --address6) require_arg "$@"; address6=$2; shift 2 ;;
            --port) require_arg "$@"; port=$2; shift 2 ;;
            --forward) forward=1; shift ;;
            --nat) require_arg "$@"; nat=$2; shift 2 ;;
            --mtu) require_arg "$@"; mtu=$2; shift 2 ;;
            --table) require_arg "$@"; table=$2; shift 2 ;;
            --name) require_arg "$@"; name=$2; shift 2 ;;
            --no-firewall) firewall=0; shift ;;
            --force) force=1; shift ;;
            *) die_unknown_arg "$1" ;;
        esac
    done

    is_port "$port" || die_usage '--port: 1..65535'
    [[ -n $endpoint ]] || die_usage 'укажи --endpoint (публичный IP или DNS-имя сервера)'
    endpoint="$(endpoint_with_port "$endpoint" "$port")"
    is_endpoint "$endpoint" || die_usage "некорректный --endpoint: $endpoint (HOST:PORT, IPv6 — [ADDR]:PORT)"
    is_iface_cidr4 "$address" || die_usage "--address: нужен адрес хоста с префиксом 8..30, например 10.50.0.1/24"
    [[ -n $address6 ]] && address6="$(hub_address6 "$address6")"
    [[ -z $mtu ]] || is_mtu "$mtu" || die_usage '--mtu: 1280..9000'
    is_table "$table" || die_usage '--table: auto, off или номер таблицы'
    is_name "$name" || die_usage "некорректное --name: $name"
    if [[ -n $nat ]]; then
        is_iface "$nat" && iface_exists "$nat" || die_usage "--nat: интерфейс $nat не найден"
    fi
    if ((forward)) || [[ -n $nat ]]; then
        has_cmd iptables || die '--forward/--nat требуют iptables'
    fi
    [[ ${endpoint##*:} == "$port" ]] ||
        log_warn "порт в endpoint (${endpoint##*:}) отличается от --port ($port) — это верно только за пробросом портов/NAT"

    if st_exists; then
        ((force)) || die_code "$E_REFUSED" "$IFACE уже управляется wg-network. Изменить параметры: wg-network set ...; переинициализировать: --force"
    fi
    guard_init_target "$force" "$port" "$address"
    sys_install_wireguard

    tx_begin init-hub
    sys_ensure_key
    st_node_load
    local created=${NODE[CREATED_AT]:-$(now_iso)} fw=${NODE[FIREWALL_PORT]-}
    [[ ${NODE[ROLE]-} == peer ]] && rm -f -- "$ST_PEERS"/*.env
    NODE=([ROLE]=hub [NAME]="$name" [ADDRESS]="$address" [ADDRESS6]="$address6" [LISTEN_PORT]="$port"
        [ENDPOINT]="$endpoint" [MTU]="$mtu" [TABLE]="$table" [FORWARD]="$forward" [NAT]="$nat"
        [FIREWALL_PORT]="$fw" [CREATED_AT]="$created")
    st_node_save

    OPT_START=1
    apply_changes
    if ((OPT_DRY_RUN)); then
        tx_commit
        return 0
    fi
    if ((firewall)) && [[ ${APPLIED:-0} == 1 ]] && sys_firewall_open "$port"; then
        NODE[FIREWALL_PORT]=$port
        st_node_save
    fi
    tx_commit
    audit "init-hub address=$address port=$port endpoint=$endpoint forward=$forward nat=${nat:-none} result=$(apply_outcome)"
    log_ok "Hub $IFACE: $(outcome_text)"
    printf '  Адрес:      %s%s\n  Endpoint:   %s\n  PublicKey:  %s\n' "$address" "${address6:+, $address6}" "$endpoint" "$(node_public_key)" >&2
    log_plain ''
    log_plain "Подключить сервер: wg-network -i $IFACE invite NAME"
}
