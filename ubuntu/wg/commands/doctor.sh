# shellcheck shell=bash

CMD_SUMMARY='проверить узел: окружение, конфиг, ядро, маршруты, firewall, peer'
CMD_GROUP=diag
CMD_READONLY=1

cmd_usage() {
    cat <<'EOF'
Использование: wg-network [-i IFACE] doctor

Только читает систему. Код выхода: 0 — всё в порядке, 1 — есть предупреждения, 2 — ошибки.
EOF
}

doc_ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
doc_warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; DOC_WARN=$((DOC_WARN + 1)); }
doc_fail() { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*"; DOC_FAIL=$((DOC_FAIL + 1)); }
doc_info() { printf '  %s·%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
doc_section() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

doc_environment() {
    local cmd
    doc_section 'Окружение'
    for cmd in wg wg-quick ip ss flock; do
        has_cmd "$cmd" && doc_ok "$cmd" || doc_fail "не найдена команда $cmd"
    done
    if [[ -d /sys/module/wireguard ]] || modprobe -n -q wireguard 2>/dev/null; then
        doc_ok 'модуль ядра wireguard доступен'
    else
        doc_fail 'нет модуля ядра wireguard (медленный wireguard-go не используется намеренно)'
    fi
    if pgrep -x wireguard-go >/dev/null 2>&1; then
        doc_warn 'запущен wireguard-go (userspace): производительность в разы ниже модуля ядра'
    fi
    if has_systemd; then
        doc_ok 'systemd'
        [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]] && doc_ok 'время синхронизировано (NTP)' ||
            doc_warn 'время не синхронизировано: при скачке часов назад peer не примет handshake до догоняния (TAI64N)'
    else
        doc_info 'systemd не обнаружен: интерфейс управляется через wg-quick напрямую'
    fi
}

doc_state() {
    local problems name key addr addr6 routes endpoint keepalive enabled pending psk comment
    local -a all=() list=()
    local i j c
    doc_section 'Состояние'
    if problems="$(st_validate)"; then
        doc_ok "состояние $ST_DIR корректно"
    else
        while IFS= read -r c; do doc_fail "$c"; done <<< "$problems"
        DOC_STATE_OK=0
        return 0
    fi
    [[ $(stat -c %a "$ST_DIR") == 700 ]] && doc_ok 'права каталога состояния 700' || doc_fail "права $ST_DIR должны быть 700"
    [[ $(stat -c %a "$ST_KEY") == 600 ]] && doc_ok 'права private.key 600' || doc_fail "права $ST_KEY должны быть 600"
    [[ -f $ST_TX ]] && doc_warn 'есть прерванная транзакция (восстановится при следующем изменении)'
    pending_exists && doc_warn "конфигурация ждёт подтверждения до $(date -d "@$(kv_get "$ST_PENDING" DEADLINE)" +%T)"

    # Overlapping AllowedIPs: WireGuard silently gives the address to the last peer.
    while IFS=$FS read -r name key addr addr6 routes endpoint keepalive enabled pending psk comment; do
        [[ $enabled == 1 && $pending == 0 ]] || continue
        split_csv "$(peer_allowed_ips "$addr" "$addr6" "$routes")" list
        for c in "${list[@]}"; do all+=("$name $c"); done
    done < <(st_peers_tsv)
    local conflicts=0
    for ((i = 0; i < ${#all[@]}; i++)); do
        for ((j = i + 1; j < ${#all[@]}; j++)); do
            [[ ${all[i]%% *} == "${all[j]%% *}" ]] && continue
            if cidr_overlap "${all[i]#* }" "${all[j]#* }"; then
                doc_fail "AllowedIPs пересекаются: ${all[i]} и ${all[j]}"
                conflicts=1
            fi
        done
    done
    ((conflicts)) || doc_ok 'AllowedIPs peer не пересекаются'
}

doc_config() {
    doc_section 'Конфиг'
    if [[ ! -f $LIVE_CONF ]]; then
        doc_fail "$LIVE_CONF отсутствует (wg-network apply)"
        return 0
    fi
    [[ $(stat -c %a "$LIVE_CONF") == 600 ]] && doc_ok "права $LIVE_CONF 600" || doc_fail "права $LIVE_CONF должны быть 600"
    drift_detected && doc_warn "$LIVE_CONF изменён вручную (wg-network plan --diff)" || doc_ok 'ручных правок нет'
    case $PLAN_CLASS in
        none | rewrite) doc_ok 'конфиг соответствует состоянию' ;;
        *) doc_warn "есть неприменённые изменения ($PLAN_CLASS): wg-network plan" ;;
    esac
    if has_systemd; then
        systemctl is-enabled --quiet "$UNIT" 2>/dev/null && doc_ok "$UNIT включён в автозагрузку" || doc_warn "$UNIT не включён: после перезагрузки интерфейс не поднимется"
        [[ -f $DROPIN ]] && doc_ok 'защита от перезагрузки во время подтверждения установлена' || doc_warn "нет $DROPIN (wg-network apply установит)"
    fi
}

doc_runtime() {
    local port mtu c fam missing=0
    doc_section 'Интерфейс'
    if ! iface_running; then
        doc_fail "$IFACE не запущен (wg-network apply --start)"
        return 0
    fi
    doc_ok "$IFACE запущен ($(unit_state))"
    if runtime_matches; then
        doc_ok 'peer в ядре совпадают с конфигом'
    else
        doc_warn 'peer в ядре отличаются от конфига (wg set вручную?) — wg-network apply выровняет'
    fi
    if [[ ${NODE[ROLE]} == hub ]]; then
        port="$(wg show "$IFACE" listen-port)"
        [[ $port == "${NODE[LISTEN_PORT]}" ]] && doc_ok "слушает UDP $port" || doc_fail "слушает порт $port вместо ${NODE[LISTEN_PORT]}"
    fi
    if [[ ${NODE[TABLE]} == auto ]]; then
        while IFS= read -r c; do
            [[ ${c##*/} == 0 ]] && continue
            fam="$(ip_family "$c")"
            if [[ -z $(ip -"$fam" route show dev "$IFACE" match "$c" 2>/dev/null) ]]; then
                doc_fail "нет маршрута $c через $IFACE (wg-network apply)"
                missing=1
            fi
        done < <(canon_allowed_ips "$PLAN_NEW")
        ((missing)) || doc_ok 'маршруты AllowedIPs на месте'
    fi
    mtu="$(ip -o link show dev "$IFACE" | sed -n 's/.* mtu \([0-9]*\).*/\1/p')"
    doc_info "MTU $IFACE: $mtu"
    ((mtu > 1420)) && doc_warn "MTU $mtu больше 1420: при пути с MTU 1500 возможна фрагментация (рекомендуется 1420, для PPPoE — 1412)"
    return 0
}

doc_network() {
    local port=${NODE[LISTEN_PORT]-} nat=${NODE[NAT]-} value conntrack max
    doc_section 'Сеть и firewall'
    if [[ ${NODE[ROLE]} == hub ]]; then
        if ufw_active; then
            ufw_has_udp "$port" && doc_ok "UFW разрешает UDP $port" || doc_fail "UFW активен, но UDP $port не разрешён: ufw allow $port/udp"
        elif has_cmd iptables && [[ $(iptables -S INPUT 2>/dev/null | sed -n 1p) == '-P INPUT DROP' ]]; then
            output_has "--dport $port( |$)" iptables -S INPUT && doc_ok "iptables разрешает UDP $port" ||
                doc_warn "политика INPUT DROP и нет правила для UDP $port"
        else
            doc_info 'host firewall не обнаружен (проверь облачный security group)'
        fi
        if [[ ${NODE[FORWARD]} == 1 || -n $nat ]]; then
            value="$(sysctl -n "net.ipv4.conf.$IFACE.forwarding" 2>/dev/null || echo 0)"
            [[ $value == 1 ]] && doc_ok "форвардинг IPv4 на $IFACE включён" || doc_fail "net.ipv4.conf.$IFACE.forwarding=0: маршрутизация не работает"
            output_has 'wg-network' iptables -w -S FORWARD && doc_ok 'правила FORWARD установлены' || doc_fail 'нет правил FORWARD wg-network (wg-network apply --force перезапустит хуки)'
            output_has 'TCPMSS' iptables -w -t mangle -S FORWARD && doc_ok 'MSS clamping включён' || doc_warn 'нет MSS clamping: возможны зависания TCP через туннель'
            if [[ -n ${NODE[ADDRESS6]-} && $(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null) != 1 ]]; then
                doc_warn 'IPv6-форвардинг выключен глобально: IPv6 между peer/в интернет не маршрутизируется. Включение net.ipv6.conf.all.forwarding=1 отключает приём RA (accept_ra=2 на внешнем интерфейсе) — wg-network не меняет это сам'
            fi
        fi
        if [[ -n $nat ]]; then
            [[ $(sysctl -n "net.ipv4.conf.$nat.forwarding" 2>/dev/null) == 1 ]] && doc_ok "форвардинг на $nat включён" || doc_fail "net.ipv4.conf.$nat.forwarding=0: ответный NAT-трафик не вернётся"
            output_has 'wg-network' iptables -w -t nat -S POSTROUTING && doc_ok 'NAT (MASQUERADE) настроен' || doc_fail 'нет правила MASQUERADE'
            if [[ -r /proc/sys/net/netfilter/nf_conntrack_count ]]; then
                conntrack=$(</proc/sys/net/netfilter/nf_conntrack_count)
                max=$(</proc/sys/net/netfilter/nf_conntrack_max)
                ((conntrack * 100 / max > 80)) && doc_warn "conntrack заполнен на $((conntrack * 100 / max))% ($conntrack/$max): увеличь net.netfilter.nf_conntrack_max" ||
                    doc_ok "conntrack: $conntrack/$max"
            fi
        fi
    fi
    local addrs
    addrs="$(iface_addresses "$IFACE")"
    if [[ -n $(ssh_sessions | while read -r client server; do grep -qxF -- "$server" <<< "$addrs" && echo y; done) ]]; then
        doc_info "есть SSH-сессии через $IFACE: изменения [Interface] спросят подтверждение и включат таймер отката"
    fi
    return 0
}

doc_peers() {
    local name key addr addr6 routes endpoint keepalive enabled pending psk comment hs host p
    doc_section 'Peer'
    runtime_load
    while IFS=$FS read -r name key addr addr6 routes endpoint keepalive enabled pending psk comment; do
        if [[ $pending == 1 ]]; then
            doc_info "$name: приглашён, ждёт peer add"
            continue
        fi
        [[ $enabled == 1 ]] || { doc_info "$name: отключён"; continue; }
        hs=${RT_HANDSHAKE[$key]-}
        case "$(peer_state_text "$enabled" "$pending" "$hs")" in
            online) doc_ok "$name: online, handshake $(handshake_text "$hs")" ;;
            stale) doc_warn "$name: последний handshake $(handshake_text "$hs") — peer недоступен или простаивает" ;;
            no-handshake) doc_warn "$name: ни одного handshake (ключ, endpoint, firewall?)" ;;
            down) doc_info "$name: интерфейс не запущен" ;;
        esac
        if [[ -n $endpoint ]] && ! endpoint_is_literal "$endpoint"; then
            endpoint_split "$endpoint" host p
            getent ahosts "$host" >/dev/null 2>&1 && doc_ok "$name: $host резолвится" || doc_fail "$name: DNS-имя $host не резолвится"
        fi
    done < <(st_peers_tsv)
    [[ -n $(st_peer_names) ]] || doc_info 'peer нет'
}

cmd_run() {
    DOC_WARN=0 DOC_FAIL=0
    (($# == 0)) || die_unknown_arg "$1"
    require_managed
    st_node_load
    printf '%swg-network doctor: %s (%s)%s\n' "$C_BOLD" "$IFACE" "${NODE[ROLE]-?}" "$C_RESET"
    DOC_STATE_OK=1
    doc_environment
    doc_state
    if ((DOC_STATE_OK)); then
        plan_build
        doc_config
        doc_runtime
        doc_network
        doc_peers
    fi
    echo
    if ((DOC_FAIL)); then
        printf 'Итог: ошибок %d, предупреждений %d\n' "$DOC_FAIL" "$DOC_WARN"
        exit 2
    elif ((DOC_WARN)); then
        printf 'Итог: предупреждений %d\n' "$DOC_WARN"
        exit 1
    fi
    printf 'Итог: всё в порядке\n'
}
