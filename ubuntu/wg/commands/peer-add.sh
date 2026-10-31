# shellcheck shell=bash

CMD_SUMMARY='добавить peer (или подтвердить приглашение)'
CMD_GROUP=peers
CMD_MUTATES=1

cmd_usage() {
    cat <<'EOF'
Использование: wg-network [-i IFACE] peer add NAME (--key KEY | --generate) [опции]

  --key KEY          публичный ключ peer (его печатает join/init peer)
  --generate         сгенерировать ключи здесь и выдать готовый клиентский конфиг
                     (для ноутбуков и телефонов; приватный ключ на hub не хранится)
  --address IP       адрес peer (по умолчанию из приглашения или первый свободный)
  --routes CIDR,...  сети за этим peer (site-to-site)
  --psk / --no-psk   preshared key (по умолчанию: да для --generate, иначе как в приглашении)
  --endpoint H:P     адрес peer, если hub должен сам инициировать соединение
  --keepalive N      PersistentKeepalive со стороны hub
  --comment TEXT     комментарий
  --wait N           дождаться handshake до N секунд (код 6, если соединения нет)
  --json             итог в stdout в JSON

Только для --generate:
  --output FILE      записать клиентский конфиг в файл (права 600), иначе вывести в stdout
  --qr               показать QR-код (нужен qrencode)
  --dns IP[,IP]      DNS для клиента
  --full-tunnel      весь трафик клиента через hub (нужен --nat на hub)

Пример (сервер, приглашённый через invite):  wg-network peer add worker1 --key 'AbC...='
Пример (телефон):  wg-network peer add phone --generate --full-tunnel --dns 1.1.1.1 --qr
EOF
}

cmd_run() {
    local name='' key='' generate=0 address='' routes='' routes_set=0 psk='' endpoint='' keepalive='' comment=''
    local output='' qr=0 dns='' full=0 private='' psk_value='' was_pending=0 owner wait=0 json=0 handshake=null
    while (($#)); do
        case $1 in
            --key) require_arg "$@"; key=$2; shift 2 ;;
            --generate) generate=1; shift ;;
            --address | --ip) require_arg "$@"; address=$2; shift 2 ;;
            --routes) require_arg "$@"; routes=$2; routes_set=1; shift 2 ;;
            --psk) psk=1; shift ;;
            --no-psk) psk=0; shift ;;
            --endpoint) require_arg "$@"; endpoint=$2; shift 2 ;;
            --keepalive) require_arg "$@"; keepalive=$2; shift 2 ;;
            --comment) require_arg "$@"; comment=$2; shift 2 ;;
            --output) require_arg "$@"; output=$2; shift 2 ;;
            --qr) qr=1; shift ;;
            --dns) require_arg "$@"; dns=$2; shift 2 ;;
            --full-tunnel) full=1; shift ;;
            --wait) require_arg "$@"; wait=$2; shift 2 ;;
            --json) json=1; shift ;;
            -*) die_unknown_arg "$1" ;;
            *) [[ -z $name ]] || die_unknown_arg "$1"; name=$1; shift ;;
        esac
    done

    [[ -n $name ]] || die_usage 'укажи имя peer'
    is_name "$name" || die_usage 'имя: до 32 символов a-z, A-Z, 0-9, ., _, -; начинается с буквы или цифры'
    ((generate)) && [[ -n $key ]] && die_usage '--key и --generate взаимоисключающие'
    ((generate)) || [[ -n $key ]] || die_usage 'укажи --key KEY или --generate'
    [[ -z $key ]] || is_wg_key "$key" || die_usage 'некорректный --key (44 символа base64)'
    [[ -z $endpoint ]] || is_endpoint "$endpoint" || die_usage "некорректный --endpoint: $endpoint"
    [[ -z $keepalive ]] || is_keepalive "$keepalive" || die_usage '--keepalive: 0..65535'
    is_comment "$comment" || die_usage '--comment: до 64 печатных символов без кавычек, $ и обратных слэшей'
    if [[ -n $dns ]]; then
        local d
        local -a dns_list=()
        split_csv "$dns" dns_list
        for d in "${dns_list[@]}"; do is_ip "$d" || die_usage "некорректный --dns: $d"; done
        dns="$(join_by ', ' "${dns_list[@]}")"
    fi
    if ((!generate)) && { [[ -n $output || -n $dns ]] || ((qr || full)); }; then
        die_usage '--output, --qr, --dns и --full-tunnel имеют смысл только с --generate'
    fi
    is_uint "$wait" || die_usage '--wait: число секунд'
    if [[ -n $output ]] && { [[ -e $output || -L $output ]]; } && ! ((OPT_FORCE)); then
        die_usage "$output уже существует (--force — заменить)"
    fi

    require_managed
    st_node_load
    require_role hub
    if ((full)) && [[ -z ${NODE[NAT]-} ]] && ! ((OPT_FORCE)); then
        die_code "$E_REFUSED" '--full-tunnel без NAT на hub не даст клиенту выхода в интернет. Включи: wg-network set --nat IFACE (или --force)'
    fi

    tx_begin peer-add
    PEER=()
    if st_peer_exists "$name"; then
        st_peer_load "$name"
        [[ ${PEER[PENDING]} == 1 ]] || die_code "$E_REFUSED" "peer '$name' уже существует (изменить: peer set)"
        was_pending=1
    fi
    if ((generate)); then
        private="$(wg genkey)"
        key="$(wg pubkey <<< "$private")"
    fi
    [[ $key != "$(node_public_key)" ]] || die_usage 'это публичный ключ самого hub'
    if owner="$(st_owner_of_key "$key" "$name")"; then
        die_code "$E_REFUSED" "этот ключ уже принадлежит peer '$owner'"
    fi

    [[ -n $address ]] || address=${PEER[ADDRESS]:-$(st_next_free_ip4)}
    st_check_peer_address "$address" "$name"
    ((routes_set)) || routes=${PEER[ROUTES]-}
    routes="$(routes_normalize "$routes")"
    st_check_peer_routes "$name" "$routes"
    guard_route_conflicts "$OPT_FORCE" "$routes"

    psk_value=${PEER[PSK]-}
    if [[ $psk == 1 || ($psk == '' && $generate == 1 && -z $psk_value) ]]; then
        [[ -n $psk_value ]] || psk_value="$(wg genpsk)"
    elif [[ $psk == 0 ]]; then
        psk_value=''
    fi
    if ((was_pending)) && [[ -z $psk && -n ${PEER[PSK]-} ]]; then
        log_info "preshared key из приглашения сохранён"
    fi

    PEER[PUBLIC_KEY]=$key
    PEER[PSK]=$psk_value
    PEER[ADDRESS]=$address
    PEER[ADDRESS6]="$(st_derive_ip6 "$address")"
    PEER[ROUTES]=$routes
    PEER[ENDPOINT]=$endpoint
    PEER[KEEPALIVE]=$keepalive
    PEER[ENABLED]=1
    PEER[PENDING]=0
    [[ -n $comment ]] && PEER[COMMENT]=$comment
    st_peer_save "$name"
    audit "peer-add name=$name address=$address key=$key routes=${routes:-none}"

    apply_changes
    tx_commit
    log_ok "Peer '$name' ($address): $(outcome_text)"

    if ((wait)) && [[ $(apply_outcome) == applied ]] && iface_running; then
        log_info "Жду handshake от '$name' до ${wait}s"
        if wait_handshake "$key" "$wait"; then
            handshake=true
            log_ok "соединение с '$name' установлено"
        else
            handshake=false
            log_warn "handshake с '$name' за ${wait}s не произошёл (peer не запущен, неверный ключ или firewall)"
        fi
    fi
    if ((json)); then
        printf '{"name":%s,"address":%s,"public_key":%s,"result":%s,"handshake":%s}\n' "$(json_str "$name")" \
            "$(json_str "$address")" "$(json_str "$key")" "$(json_str "$(apply_outcome)")" "$handshake"
    fi

    if ((generate)) && ! ((OPT_DRY_RUN)); then
        local conf
        conf="$(client_conf "$private" "$address" "${PEER[ADDRESS6]}" "$psk_value" "$(peer_side_routes "$full")" "$dns" "$DEFAULT_KEEPALIVE")"
        if [[ -n $output ]]; then
            printf '%s\n' "$conf" | write_secret_file "$output"
            log_ok "Клиентский конфиг: $output (содержит приватный ключ, на hub он не сохранён)"
        elif ((json)); then
            log_warn '--json без --output: клиентский конфиг не выводится, чтобы не смешивать его с JSON'
        else
            log_warn 'клиентский конфиг содержит приватный ключ, на hub он не сохранён — сохрани его сейчас'
            printf '%s\n' "$conf"
        fi
        if ((qr)); then
            if has_cmd qrencode; then
                qrencode -t ansiutf8 <<< "$conf" >&2
            else
                log_warn 'qrencode не установлен (apt install qrencode)'
            fi
        fi
    fi
    [[ $handshake == false ]] && exit "$E_NO_HANDSHAKE"
    return 0
}
