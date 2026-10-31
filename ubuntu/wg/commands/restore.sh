# shellcheck shell=bash

CMD_SUMMARY='восстановить интерфейс из архива backup (тот же ключ и peer)'
CMD_GROUP=maintenance
CMD_MUTATES=1

cmd_usage() {
    cat <<'EOF'
Использование: wg-network [-i IFACE] restore FILE|- [--force] [--no-firewall]

Для замены упавшего сервера: состояние из архива проверяется так же строго, как при
обычной работе, затем применяется с планом, предохранителями и таймером отката.
Интерфейс, уже управляемый wg-network, заменяется только с --force (текущее состояние
остаётся в снимке: wg-network rollback).
EOF
}

# Only state files are accepted: no absolute paths, "..", symlinks or devices.
restore_check_archive() {
    local file=$1 mode path
    tar -tf "$file" >/dev/null 2>&1 || die 'файл не является tar-архивом'
    while read -r mode _ _ _ _ path; do
        [[ $mode == -* || $mode == d* ]] || die "архив содержит недопустимый объект: $path"
    done < <(tar -tvf "$file")
    while IFS= read -r path; do
        [[ $path =~ ^\./(meta\.env|node\.env|private\.key|peers\.d/?|peers\.d/[A-Za-z0-9][A-Za-z0-9._-]{0,31}\.env)?$ ]] ||
            die "архив содержит недопустимый путь: $path"
    done < <(tar -tf "$file")
}

cmd_run() {
    local file='' firewall=1 tmp archive real_dir
    while (($#)); do
        case $1 in
            --no-firewall) firewall=0; shift ;;
            --force) OPT_FORCE=1; shift ;;
            -*) [[ $1 == - ]] && { file=-; shift; continue; }; die_unknown_arg "$1" ;;
            *) [[ -z $file ]] || die_unknown_arg "$1"; file=$1; shift ;;
        esac
    done
    [[ -n $file ]] || die_usage 'укажи файл архива (или - для stdin)'

    make_tmp_dir tmp
    archive="$tmp/backup.tar"
    if [[ $file == - ]]; then
        (umask 077 && cat > "$archive")
    else
        [[ -r $file ]] || die_usage "не читается $file"
        cp -- "$file" "$archive"
    fi
    restore_check_archive "$archive"
    mkdir -p "$tmp/state"
    tar -C "$tmp/state" --no-same-owner -xf "$archive"
    [[ $(kv_get "$tmp/state/meta.env" FORMAT) == wgn-backup-1 ]] || die 'неизвестный формат архива'

    # Validate the unpacked state with the same rules as the live one.
    real_dir=$ST_DIR
    st_paths "$tmp/state"
    install -d -m 700 "$ST_PEERS"
    st_node_load
    st_require_valid
    st_paths "$real_dir"

    if st_exists && ! ((OPT_FORCE)); then
        die_code "$E_REFUSED" "$IFACE уже управляется wg-network: замена только с --force"
    fi
    if [[ ${NODE[ROLE]} == hub ]]; then
        guard_init_target "$OPT_FORCE" "${NODE[LISTEN_PORT]}" "${NODE[ADDRESS]}"
    else
        guard_init_target "$OPT_FORCE"
    fi
    sys_install_wireguard

    tx_begin restore
    rm -rf -- "${ST_DIR:?}/node.env" "${ST_DIR:?}/private.key" "${ST_DIR:?}/peers.d"
    cp -a "$tmp/state/node.env" "$tmp/state/private.key" "$tmp/state/peers.d" "$ST_DIR/"
    chmod 600 "$ST_KEY" "$ST_NODE"
    OPT_START=1
    apply_changes
    if ((firewall)) && [[ ${NODE[ROLE]} == hub && $(apply_outcome) != prepared ]] && ! ((OPT_DRY_RUN)); then
        sys_firewall_open "${NODE[LISTEN_PORT]}" || true
    fi
    tx_commit
    audit "restore iface=$IFACE result=$(apply_outcome)"
    log_ok "$IFACE восстановлен из архива: $(outcome_text)"
}
