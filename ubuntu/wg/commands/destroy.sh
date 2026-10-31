# shellcheck shell=bash

CMD_SUMMARY='остановить интерфейс и убрать его из-под управления (с бэкапом)'
CMD_GROUP=maintenance

cmd_usage() {
    cat <<'EOF'
Использование: wg-network -i IFACE destroy

Останавливает и отключает интерфейс, сохраняет архив состояния и конфига в
/var/backups/wg-network/ (права 600) и удаляет их. Требует ввода имени интерфейса (или --yes).
EOF
}

cmd_run() {
    local archive
    (($# == 0)) || die_unknown_arg "$1"
    require_managed
    st_node_load
    [[ -n $OPT_IFACE ]] || die_usage 'для destroy интерфейс указывается явно: -i IFACE'
    lock_acquire
    log_warn "$IFACE будет остановлен: все его туннели прервутся, ключ и peer уйдут в архив"
    guard_check /dev/null /dev/null restart
    guard_report
    confirm_typed "$IFACE" 'Удаление интерфейса.' || die_code "$E_REFUSED" 'отменено'

    if pending_exists; then
        deadman_disarm
        pending_clear
    fi
    install -d -m 700 "$WGN_BACKUP_ROOT"
    archive="$WGN_BACKUP_ROOT/$IFACE-$(date +%Y%m%d-%H%M%S).tar"
    local -a items=("${ST_DIR#/}")
    [[ -f $LIVE_CONF ]] && items+=("${LIVE_CONF#/}")
    (umask 077 && tar -C / -cf "$archive" "${items[@]}")
    sys_iface_disable
    sys_dropin_remove
    rm -f -- "$LIVE_CONF"
    rm -rf -- "${ST_DIR:?}"
    rm -f -- "$ST_LOCK"
    audit "destroy archive=$archive"
    log_ok "$IFACE удалён. Архив: $archive"
    [[ -n ${NODE[FIREWALL_PORT]-} ]] && log_info "правило UFW для UDP ${NODE[FIREWALL_PORT]} оставлено: ufw delete allow ${NODE[FIREWALL_PORT]}/udp"
    return 0
}
