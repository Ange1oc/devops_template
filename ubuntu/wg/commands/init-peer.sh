# shellcheck shell=bash

CMD_SUMMARY='подключить сервер к hub вручную (обычно удобнее join)'
CMD_GROUP=setup
CMD_MUTATES=1

cmd_usage() {
    cat <<EOF
Использование: wg-network [-i IFACE] init peer --name NAME --address IP --hub-key KEY --endpoint HOST:PORT [опции]

  --name NAME          имя этого сервера в сети
  --address IP         адрес этого сервера в сети (IPv4)
  --address6 IP        адрес IPv6 (если в сети включён dual-stack)
  --hub-key KEY        публичный ключ hub
  --endpoint HOST:PORT публичный адрес hub
  --routes CIDR,...    что отправлять через hub (по умолчанию адрес hub из $DEFAULT_HUB_ADDRESS)
  --psk-file FILE      файл с preshared key (если он задан на hub)
  --keepalive N        PersistentKeepalive, 0 — выключить (по умолчанию $DEFAULT_KEEPALIVE)
  --mtu N, --table T   как в init hub
  --force              переинициализировать узел

Проще: на hub выполнить "wg-network invite NAME", здесь — напечатанную команду join.
EOF
}

cmd_run() {
    local -A INIT=([KEEPALIVE]=$DEFAULT_KEEPALIVE [TABLE]=auto [FORCE]=$OPT_FORCE)
    local psk_file='' manual_routes=0

    while (($#)); do
        case $1 in
            --name) require_arg "$@"; INIT[NAME]=$2; shift 2 ;;
            --address | --ip) require_arg "$@"; INIT[ADDRESS]=$2; shift 2 ;;
            --address6) require_arg "$@"; INIT[ADDRESS6]=$2; shift 2 ;;
            --hub-key) require_arg "$@"; INIT[HUB_KEY]=$2; shift 2 ;;
            --endpoint) require_arg "$@"; INIT[HUB_ENDPOINT]=$2; shift 2 ;;
            --routes) require_arg "$@"; INIT[ROUTES]=$2; manual_routes=1; shift 2 ;;
            --hub-ip) require_arg "$@"; INIT[ROUTES]="$2/32"; shift 2 ;;
            --psk-file) require_arg "$@"; psk_file=$2; shift 2 ;;
            --keepalive) require_arg "$@"; INIT[KEEPALIVE]=$2; shift 2 ;;
            --mtu) require_arg "$@"; INIT[MTU]=$2; shift 2 ;;
            --table) require_arg "$@"; INIT[TABLE]=$2; shift 2 ;;
            --force) INIT[FORCE]=1; shift ;;
            *) die_unknown_arg "$1" ;;
        esac
    done

    [[ -n ${INIT[NAME]-} && -n ${INIT[ADDRESS]-} && -n ${INIT[HUB_KEY]-} && -n ${INIT[HUB_ENDPOINT]-} ]] ||
        die_usage 'обязательны --name, --address, --hub-key и --endpoint'
    ((manual_routes)) || : "${INIT[ROUTES]:=${DEFAULT_HUB_ADDRESS%/*}/32}"
    if [[ -n $psk_file ]]; then
        [[ -r $psk_file ]] || die_usage "не читается $psk_file"
        INIT[PSK]="$(tr -d '[:space:]' < "$psk_file")"
    fi
    if st_exists && ! ((INIT[FORCE])); then
        die_code "$E_REFUSED" "$IFACE уже управляется wg-network. Переинициализировать: --force"
    fi

    node_init_peer INIT
    ((OPT_DRY_RUN)) && return 0
    audit "init-peer name=${INIT[NAME]} address=${INIT[ADDRESS]} hub=${INIT[HUB_ENDPOINT]} result=$(apply_outcome)"
    log_ok "Peer ${INIT[NAME]}: $(outcome_text)"
    print_hub_approval "${INIT[NAME]}" "${INIT[ADDRESS]}" 1
}
