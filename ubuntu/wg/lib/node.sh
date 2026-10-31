# shellcheck shell=bash
# Shared command logic: invitation tokens, client configs, peer routes.

readonly TOKEN_PREFIX='wgn1.'
readonly TOKEN_KEYS=(NAME ADDRESS ADDRESS6 HUB_KEY HUB_ENDPOINT ROUTES PSK KEEPALIVE MTU)

# Invitation token: base64url of KEY=VALUE lines. It carries the PSK, so it is a secret.
token_encode() {
    local -n _te_src=$1
    local key
    for key in "${TOKEN_KEYS[@]}"; do
        if [[ -n ${_te_src[$key]-} ]]; then printf '%s=%s\n' "$key" "${_te_src[$key]}"; fi
    done | base64 -w0 | tr '+/' '-_' | tr -d '='
}

token_decode() {
    local token=$1 payload line key
    local -n _td_out=$2
    _td_out=()
    [[ $token == "$TOKEN_PREFIX"* ]] || die_usage 'это не токен wg-network (ожидается wgn1....)'
    payload=${token#"$TOKEN_PREFIX"}
    [[ ${#payload} -le 4096 && $payload =~ ^[A-Za-z0-9_-]+$ ]] || die_usage 'токен повреждён'
    while ((${#payload} % 4)); do
        payload+='='
    done
    payload="$(tr -- '-_' '+/' <<< "$payload" | base64 -d 2>/dev/null)" || die_usage 'токен повреждён'
    while IFS= read -r line; do
        key=${line%%=*}
        [[ " ${TOKEN_KEYS[*]} " == *" $key "* ]] || die_usage "токен содержит неизвестное поле: $key"
        _td_out["$key"]=${line#*=}
    done <<< "$payload"
}

# Token from a file, stdin, a hidden prompt or an argument. An argument is visible to other
# users in ps and /proc/*/cmdline, so the prompt or stdin is preferred.
read_token() {
    local arg=$1 file=$2 token=''
    if [[ -n $file ]]; then
        [[ -r $file ]] || die_usage "не читается $file"
        token="$(tr -d '[:space:]' < "$file")"
    elif [[ $arg == - ]] || { [[ -z $arg ]] && [[ ! -t 0 ]]; }; then
        IFS= read -r token || true
    elif [[ -z $arg ]]; then
        read -rs -p 'Вставь токен из wg-network invite (ввод скрыт): ' token || true
        echo >&2
    else
        log_warn 'токен в командной строке виден другим пользователям сервера (ps); безопаснее: wg-network join — и вставить по запросу'
        token=$arg
    fi
    token=${token//[[:space:]]/}
    [[ -n $token ]] || die_usage 'токен не получен'
    printf '%s' "$token"
}

# What a peer sends through the hub: everything (full tunnel), the whole network (hub
# forwards) or only the hub itself.
peer_side_routes() {
    local full=$1
    if ((full)); then
        printf '0.0.0.0/0'
        [[ -n ${NODE[ADDRESS6]-} ]] && printf ',::/0'
    elif [[ ${NODE[FORWARD]} == 1 ]]; then
        node_networks
    else
        printf '%s/32' "${NODE[ADDRESS]%/*}"
        [[ -n ${NODE[ADDRESS6]-} ]] && printf ',%s/128' "${NODE[ADDRESS6]%/*}"
    fi
    return 0
}

# Canonical notation, duplicates removed.
routes_normalize() {
    local -a list=() out=()
    local c n
    split_csv "$1" list
    for c in "${list[@]}"; do
        check_route "$c"
        n="$(cidr_normalize_text "$c")"
        [[ " ${out[*]} " == *" $n "* ]] || out+=("$n")
    done
    join_by , "${out[@]}"
}

# A bare network (fd00::/64) becomes its ::1 address.
hub_address6() {
    local value=$1 net hex text
    [[ $value == auto ]] && value="$(ip6_random_ula64)"
    is_cidr "$value" && is_ipv6 "${value%/*}" || die_usage "некорректный --address6: $value"
    is_iface_cidr6 "$value" || die_usage '--address6: длина префикса должна быть 48..96'
    cidr_network "$value" net
    if [[ $net == "$(cidr_normalize_text "$value")" ]]; then
        ip6_expand "${net%/*}" hex
        hex_to_ip 6 "${hex:0:31}1" text
        value="$text/${value##*/}"
    fi
    cidr_normalize_text "$value"
}

# Client config for a device whose keys were generated on the hub (laptop, phone).
client_conf() {
    local private=$1 addr=$2 addr6=$3 psk=$4 routes=$5 dns=$6 keepalive=$7
    local -a addrs=("$addr/32")
    [[ -n $addr6 ]] && addrs+=("$addr6/128")
    printf '[Interface]\nPrivateKey = %s\nAddress = %s\n' "$private" "$(join_by ', ' "${addrs[@]}")"
    [[ -n $dns ]] && printf 'DNS = %s\n' "$dns"
    [[ -n ${NODE[MTU]-} ]] && printf 'MTU = %s\n' "${NODE[MTU]}"
    printf '\n[Peer]\nPublicKey = %s\n' "$(node_public_key)"
    [[ -n $psk ]] && printf 'PresharedKey = %s\n' "$psk"
    printf 'Endpoint = %s\nAllowedIPs = %s\n' "${NODE[ENDPOINT]}" "${routes//,/, }"
    [[ $keepalive != 0 ]] && printf 'PersistentKeepalive = %s\n' "$keepalive"
    return 0
}

install_url() {
    local repo ref
    repo="$(install_meta REPO)"
    ref="$(install_meta REF)"
    printf 'https://raw.githubusercontent.com/%s/%s/ubuntu/wg/install.sh' "${repo:-Ange1oc/devops_template}" "${ref:-main}"
}

install_one_liner() {
    local ref
    ref="$(install_meta REF)"
    printf 'curl -fsSL %s | sudo bash -s -- --ref %q' "$(install_url)" "${ref:-main}"
}

# Append the default port unless the endpoint already has one.
endpoint_with_port() {
    local ep=$1 port=$2
    if [[ $ep == \[*\] ]] || { is_ipv6 "$ep" && ep="[$ep]"; }; then
        printf '%s:%s' "$ep" "$port"
    elif [[ $ep == *:* ]]; then
        printf '%s' "$ep"
    else
        printf '%s:%s' "$ep" "$port"
    fi
}

# Shared by init-peer and join; arguments come in an associative array.
node_init_peer() {
    local -n I=$1
    local hub_key=${I[HUB_KEY]} own

    is_name "${I[NAME]}" || die_usage 'имя: до 32 символов a-z, A-Z, 0-9, ., _, -; начинается с буквы или цифры'
    is_ipv4 "${I[ADDRESS]}" || die_usage "некорректный адрес: ${I[ADDRESS]}"
    [[ -z ${I[ADDRESS6]-} ]] || is_ipv6 "${I[ADDRESS6]}" || die_usage "некорректный IPv6-адрес: ${I[ADDRESS6]}"
    is_wg_key "$hub_key" || die_usage 'некорректный ключ hub (44 символа base64)'
    is_endpoint "${I[HUB_ENDPOINT]}" || die_usage "некорректный endpoint hub: ${I[HUB_ENDPOINT]} (HOST:PORT)"
    [[ -z ${I[PSK]-} ]] || is_wg_key "${I[PSK]}" || die_usage 'некорректный PSK'
    is_keepalive "${I[KEEPALIVE]}" || die_usage 'keepalive: 0..65535'
    [[ -z ${I[MTU]-} ]] || is_mtu "${I[MTU]}" || die_usage 'MTU: 1280..9000'
    is_table "${I[TABLE]:-auto}" || die_usage 'table: auto, off или номер таблицы'
    I[ROUTES]="$(routes_normalize "${I[ROUTES]}")"
    [[ -n ${I[ROUTES]} ]] || die_usage 'не заданы маршруты через hub (--routes)'

    guard_init_target "${I[FORCE]:-0}"
    guard_route_conflicts "${I[FORCE]:-0}" "$(tr ',' '\n' <<< "${I[ROUTES]}" | grep -v '/32$\|/128$' | paste -sd, -)"
    sys_install_wireguard

    tx_begin init-peer
    sys_ensure_key
    own="$(node_public_key)"
    [[ $hub_key != "$own" ]] || die_usage 'ключ hub совпадает с ключом этого сервера — команда запущена на hub?'

    st_node_load
    local created=${NODE[CREATED_AT]:-$(now_iso)}
    rm -f -- "$ST_PEERS"/*.env
    NODE=([ROLE]=peer [NAME]="${I[NAME]}" [ADDRESS]="${I[ADDRESS]}/32" [MTU]="${I[MTU]-}"
        [TABLE]="${I[TABLE]:-auto}" [FORWARD]=0 [CREATED_AT]="$created")
    [[ -n ${I[ADDRESS6]-} ]] && NODE[ADDRESS6]="$(ip_normalize "${I[ADDRESS6]}")/128"
    st_node_save
    PEER=([PUBLIC_KEY]="$hub_key" [PSK]="${I[PSK]-}" [ENDPOINT]="${I[HUB_ENDPOINT]}"
        [ROUTES]="${I[ROUTES]}" [KEEPALIVE]="${I[KEEPALIVE]}" [ENABLED]=1 [PENDING]=0 [COMMENT]='hub')
    st_peer_save hub

    OPT_START=1
    apply_changes
    tx_commit
}

# The command to run on the hub after init-peer/join; with --json a summary on stdout.
print_hub_approval() {
    local name=$1 addr=$2 with_address=$3 json=${4:-0} cmd
    if ((with_address)); then
        printf -v cmd 'sudo wg-network peer add %q --key %q --address %q' "$name" "$(node_public_key)" "$addr"
    else
        printf -v cmd 'sudo wg-network peer add %q --key %q' "$name" "$(node_public_key)"
    fi
    if ((json)); then
        printf '{"name":%s,"address":%s,"public_key":%s,"interface":%s,"result":%s,"approve_command":%s}\n' \
            "$(json_str "$name")" "$(json_str "$addr")" "$(json_str "$(node_public_key)")" \
            "$(json_str "$IFACE")" "$(json_str "$(apply_outcome)")" "$(json_str "$cmd")"
        return 0
    fi
    log_title 'Теперь выполни на hub:'
    printf '  %s\n' "$cmd"
}

# peer enable / peer disable.
peer_toggle() {
    local name=${2-} value=$1
    (($# == 2)) || die_usage 'укажи одно имя peer'
    is_name "$name" || die_usage "некорректное имя: $name"
    require_managed
    st_node_load
    tx_begin "peer-$([[ $value == 1 ]] && echo enable || echo disable)"
    st_peer_load "$name"
    [[ ${PEER[PENDING]} == 0 ]] || die_code "$E_REFUSED" "peer '$name' ещё не подтверждён (peer add)"
    if [[ ${PEER[ENABLED]} == "$value" ]]; then
        tx_commit
        log_ok "peer '$name' уже $([[ $value == 1 ]] && echo включён || echo отключён)"
        return 0
    fi
    PEER[ENABLED]=$value
    st_peer_save "$name"
    audit "peer-enabled name=$name value=$value"
    apply_changes
    tx_commit
    log_ok "peer '$name' $([[ $value == 1 ]] && echo включён || echo отключён): $(outcome_text)"
}
