# shellcheck shell=bash

CMD_SUMMARY='сохранить состояние интерфейса в архив (ключ, peer, параметры)'
CMD_GROUP=maintenance

cmd_usage() {
    cat <<'EOF'
Использование: wg-network [-i IFACE] backup [--output FILE]

Архив содержит приватный ключ интерфейса и preshared key peer — храни его как секрет
(например, зашифруй: ... | gpg -c > wg0.backup.gpg). Без --output архив пишется в stdout
(только если stdout не терминал). Восстановление: wg-network restore FILE — сервер получает
тот же ключ, и peer переподключаются сами, как только адрес hub (DNS) укажет на новый сервер.
EOF
}

cmd_run() {
    local output='' tmp item
    while (($#)); do
        case $1 in
            --output) require_arg "$@"; output=$2; shift 2 ;;
            *) die_unknown_arg "$1" ;;
        esac
    done
    require_managed
    [[ -n $output || ! -t 1 ]] || die_usage 'архив двоичный: укажи --output FILE или перенаправь stdout в файл'
    lock_acquire
    st_node_load
    st_require_valid

    make_tmp_dir tmp
    for item in node.env private.key peers.d; do
        cp -a "$ST_DIR/$item" "$tmp/"
    done
    printf 'FORMAT=wgn-backup-1\nIFACE=%s\nVERSION=%s\nCREATED_AT=%s\n' "$IFACE" "$(wgn_version)" "$(now_iso)" > "$tmp/meta.env"
    if [[ -n $output ]]; then
        tar -C "$tmp" -cf - . | write_secret_file "$output"
        log_ok "Архив $IFACE: $output (содержит приватный ключ)"
    else
        tar -C "$tmp" -cf - .
    fi
    audit "backup output=${output:-stdout}"
}
