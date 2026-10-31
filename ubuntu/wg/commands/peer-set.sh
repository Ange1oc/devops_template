# shellcheck shell=bash

CMD_SUMMARY='изменить параметры peer'
CMD_GROUP=peers
CMD_MUTATES=1

cmd_usage() {
    cat <<'EOF'
Использование: wg-network [-i IFACE] peer set NAME [опции]

  --key KEY            новый публичный ключ (переустановленный сервер)
  --routes CIDR,...    сети за peer; none — убрать
  --endpoint H:P|none  адрес peer (на узле-peer: новый адрес hub, peer называется "hub")
  --keepalive N        PersistentKeepalive, 0 — выключить
  --comment TEXT       комментарий
  --rotate-psk         новый preshared key (печатается в stdout, его нужно задать на самом peer)
  --psk-file FILE|-    задать preshared key из файла или stdin (например, после --rotate-psk на hub)

На узле-peer запись hub называется "hub": например, если у hub сменился IP:
  wg-network peer set hub --endpoint 198.51.100.20:51820
Ротация PSK без переинициализации (ключ идёт через pipe, не через файл или argv):
  ssh hub sudo wg-network peer set worker1 --rotate-psk --yes | ssh worker1 sudo wg-network peer set hub --psk-file - --yes
EOF
}

cmd_run() {
    local name='' key='' routes='' routes_set=0 endpoint='' endpoint_set=0 keepalive='' comment='' comment_set=0 rotate=0 owner
    local psk_file='' psk=''
    while (($#)); do
        case $1 in
            --key) require_arg "$@"; key=$2; shift 2 ;;
            --routes) require_arg "$@"; routes=$2; routes_set=1; shift 2 ;;
            --endpoint) require_arg "$@"; endpoint=$2; endpoint_set=1; shift 2 ;;
            --keepalive) require_arg "$@"; keepalive=$2; shift 2 ;;
            --comment) require_arg "$@"; comment=$2; comment_set=1; shift 2 ;;
            --rotate-psk) rotate=1; shift ;;
            --psk-file) require_arg "$@"; psk_file=$2; shift 2 ;;
            -*) die_unknown_arg "$1" ;;
            *) [[ -z $name ]] || die_unknown_arg "$1"; name=$1; shift ;;
        esac
    done
    [[ -n $name ]] || die_usage 'укажи имя peer'
    is_name "$name" || die_usage "некорректное имя: $name"
    [[ -z $key ]] || is_wg_key "$key" || die_usage 'некорректный --key'
    [[ $endpoint == none || -z $endpoint ]] || is_endpoint "$endpoint" || die_usage "некорректный --endpoint: $endpoint"
    [[ -z $keepalive ]] || is_keepalive "$keepalive" || die_usage '--keepalive: 0..65535'
    is_comment "$comment" || die_usage '--comment: до 64 печатных символов без кавычек, $ и обратных слэшей'
    if [[ -n $psk_file ]]; then
        ((!rotate)) || die_usage '--rotate-psk и --psk-file взаимоисключающие'
        if [[ $psk_file == - ]]; then
            IFS= read -r psk || true
        else
            [[ -r $psk_file ]] || die_usage "не читается $psk_file"
            psk="$(head -n 1 -- "$psk_file")"
        fi
        psk=${psk//[[:space:]]/}
        is_wg_key "$psk" || die_usage '--psk-file: нужен preshared key (44 символа base64, как выдаёт wg genpsk)'
    fi
    [[ -n $key || -n $keepalive || -n $psk ]] || ((routes_set || endpoint_set || comment_set || rotate)) || die_usage 'не указано, что менять'

    require_managed
    st_node_load
    st_peer_exists "$name" || die "peer '$name' не найден"

    tx_begin peer-set
    st_peer_load "$name"
    if [[ -n $key ]]; then
        [[ $key != "$(node_public_key)" ]] || die_usage 'это публичный ключ самого узла'
        if owner="$(st_owner_of_key "$key" "$name")"; then
            die_code "$E_REFUSED" "этот ключ уже принадлежит peer '$owner'"
        fi
        PEER[PUBLIC_KEY]=$key
        PEER[PENDING]=0
    fi
    if ((routes_set)); then
        [[ $routes == none ]] && routes=''
        routes="$(routes_normalize "$routes")"
        st_check_peer_routes "$name" "$routes"
        [[ ${NODE[ROLE]} == hub ]] && guard_route_conflicts "$OPT_FORCE" "$routes"
        [[ ${NODE[ROLE]} == peer && -z $routes ]] && die_usage 'у hub должен остаться хотя бы один маршрут'
        PEER[ROUTES]=$routes
    fi
    ((endpoint_set)) && PEER[ENDPOINT]=${endpoint/#none/}
    [[ -n $keepalive ]] && PEER[KEEPALIVE]=$keepalive
    ((comment_set)) && PEER[COMMENT]=$comment
    if ((rotate)); then
        PEER[PSK]="$(wg genpsk)"
    fi
    [[ -n $psk ]] && PEER[PSK]=$psk
    st_peer_save "$name"
    audit "peer-set name=$name"

    apply_changes
    tx_commit
    log_ok "Peer '$name' изменён: $(outcome_text)"
    if ((rotate)) && ! ((OPT_DRY_RUN)); then
        log_warn "новый preshared key нужно задать на самом peer, иначе он не подключится:"
        printf '%s\n' "${PEER[PSK]}"
    fi
}
