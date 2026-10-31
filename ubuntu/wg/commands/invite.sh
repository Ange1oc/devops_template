# shellcheck shell=bash

CMD_SUMMARY='зарезервировать адрес и выдать токен для нового сервера'
CMD_GROUP=peers
CMD_MUTATES=1

cmd_usage() {
    cat <<'EOF'
Использование: wg-network [-i IFACE] invite NAME [опции]

  --address IP       адрес нового peer (по умолчанию первый свободный)
  --routes CIDR,...  сети за этим peer (site-to-site): hub будет направлять их в него
  --full-tunnel      peer отправляет через hub весь трафик (нужен --nat на hub)
  --keepalive N      PersistentKeepalive на стороне peer
  --no-psk           без preshared key
  --comment TEXT     комментарий
  --json             итог в stdout в JSON (token, address, команды) — для автоматизации

Резервирует адрес (до peer add он не появляется в конфиге) и печатает команды для нового
сервера. Токен содержит preshared key: передавай его как секрет.
EOF
}

cmd_run() {
    local name='' address='' routes='' full=0 keepalive=$DEFAULT_KEEPALIVE psk=1 comment='' psk_value='' addr6='' json=0 token
    local -A T=()
    while (($#)); do
        case $1 in
            --address | --ip) require_arg "$@"; address=$2; shift 2 ;;
            --routes) require_arg "$@"; routes=$2; shift 2 ;;
            --full-tunnel) full=1; shift ;;
            --keepalive) require_arg "$@"; keepalive=$2; shift 2 ;;
            --no-psk) psk=0; shift ;;
            --comment) require_arg "$@"; comment=$2; shift 2 ;;
            --json) json=1; shift ;;
            -*) die_unknown_arg "$1" ;;
            *) [[ -z $name ]] || die_unknown_arg "$1"; name=$1; shift ;;
        esac
    done
    [[ -n $name ]] || die_usage 'укажи имя нового peer'
    is_name "$name" || die_usage 'имя: до 32 символов a-z, A-Z, 0-9, ., _, -; начинается с буквы или цифры'
    is_keepalive "$keepalive" || die_usage '--keepalive: 0..65535'
    is_comment "$comment" || die_usage '--comment: до 64 печатных символов без кавычек, $ и обратных слэшей'

    require_managed
    st_node_load
    require_role hub
    if st_peer_exists "$name"; then
        st_peer_load "$name"
        [[ ${PEER[PENDING]} == 1 ]] || die_code "$E_REFUSED" "peer '$name' уже существует"
        log_info "Перевыпуск приглашения для '$name' (адрес ${PEER[ADDRESS]})"
        [[ -n $address ]] || address=${PEER[ADDRESS]}
        [[ -n $routes ]] || routes=${PEER[ROUTES]}
        psk_value=${PEER[PSK]}
    fi
    if ((full)) && [[ -z ${NODE[NAT]-} ]]; then
        ((OPT_FORCE)) || die_code "$E_REFUSED" '--full-tunnel без NAT на hub не даст peer выхода в интернет. Включи: wg-network set --nat IFACE (или --force)'
    fi

    tx_begin invite
    [[ -n $address ]] || address="$(st_next_free_ip4)"
    st_check_peer_address "$address" "$name"
    routes="$(routes_normalize "$routes")"
    st_check_peer_routes "$name" "$routes"
    guard_route_conflicts "$OPT_FORCE" "$routes"
    addr6="$(st_derive_ip6 "$address")"
    ((psk)) && [[ -z $psk_value ]] && psk_value="$(wg genpsk)"
    ((psk)) || psk_value=''
    PEER=([ADDRESS]="$address" [ADDRESS6]="$addr6" [ROUTES]="$routes" [PSK]="$psk_value" [ENABLED]=1
        [PENDING]=1 [COMMENT]="$comment" [CREATED_AT]="${PEER[CREATED_AT]-}")
    st_peer_save "$name"
    tx_commit
    audit "invite name=$name address=$address"

    T=([NAME]="$name" [ADDRESS]="$address" [ADDRESS6]="$addr6" [HUB_KEY]="$(node_public_key)"
        [HUB_ENDPOINT]="${NODE[ENDPOINT]}" [ROUTES]="$(peer_side_routes "$full")" [PSK]="$psk_value"
        [KEEPALIVE]="$keepalive" [MTU]="${NODE[MTU]-}")

    token="$TOKEN_PREFIX$(token_encode T)"
    if ((json)); then
        printf '{"name":%s,"address":%s,"address6":%s,"token":%s,"install_command":%s,"join_command":%s}\n' \
            "$(json_str "$name")" "$(json_str "$address")" "$(json_str "$addr6")" "$(json_str "$token")" \
            "$(json_str "$(install_one_liner)")" "$(json_str 'sudo wg-network join')"
        return 0
    fi
    log_ok "Адрес $address зарезервирован за '$name'"
    log_title "На новом сервере '$name':"
    log_plain "  1. $(install_one_liner)"
    log_plain '  2. sudo wg-network join        — и вставь токен по запросу (ввод скрыт):'
    printf '%s\n' "$token"
    log_plain ''
    [[ -n $psk_value ]] && log_warn 'токен содержит preshared key — не публикуй его в чатах и тикетах'
    log_plain "join напечатает команду peer add для hub. Всё сразу по SSH: wg-network deploy $name USER@HOST"
}
