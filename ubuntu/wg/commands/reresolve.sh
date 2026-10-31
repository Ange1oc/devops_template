# shellcheck shell=bash

CMD_SUMMARY='обновить DNS-адреса peer без свежего handshake (запускается таймером)'
CMD_GROUP=maintenance
CMD_IFACE=0
# Runs from a timer under ProtectSystem=strict: it only reads the state.
CMD_MIGRATE=0

cmd_usage() {
    cat <<'EOF'
Использование: wg-network reresolve

WireGuard резолвит DNS-имя endpoint один раз. Если IP hub сменился, связь не восстановится
сама. Для peer с DNS-именем и handshake старше 135 с (как в contrib/reresolve-dns из
wireguard-tools) адрес резолвится заново. Устанавливается таймером wg-network-reresolve.timer.
EOF
}

cmd_run() {
    local iface name key addr addr6 routes endpoint keepalive enabled pending psk comment hs now
    (($# == 0)) || die_unknown_arg "$1"
    now="$(now_epoch)"
    while IFS= read -r iface; do
        iface_use "$iface"
        iface_running || continue
        runtime_load
        while IFS=$FS read -r name key addr addr6 routes endpoint keepalive enabled pending psk comment; do
            [[ -n $endpoint && $enabled == 1 && $pending == 0 ]] || continue
            endpoint_is_literal "$endpoint" && continue
            hs=${RT_HANDSHAKE[$key]-}
            [[ -n $hs ]] || continue
            ((now - hs > RERESOLVE_AFTER)) || continue
            if wg set "$IFACE" peer "$key" endpoint "$endpoint" 2>/dev/null; then
                log_info "$IFACE/$name: endpoint $endpoint резолвится заново"
            else
                log_warn "$IFACE/$name: не удалось разрешить $endpoint"
            fi
        done < <(st_peers_tsv)
    done < <(managed_ifaces)
}
