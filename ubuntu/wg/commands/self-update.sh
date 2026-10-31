# shellcheck shell=bash

CMD_SUMMARY='обновить wg-network с GitHub'
CMD_GROUP=maintenance
CMD_IFACE=0

cmd_usage() {
    cat <<'EOF'
Использование: wg-network self-update [--ref REF]

  --ref REF   ветка, тег или commit (по умолчанию тот же, что при установке)

Обновляет только программу: сеть, ключи и конфиги в /etc/wireguard не трогаются,
интерфейсы не перезапускаются. Откат: sudo /opt/wg-network/install.sh --rollback
EOF
}

cmd_run() {
    local repo ref
    repo="$(install_meta REPO)"
    ref="$(install_meta REF)"
    while (($#)); do
        case $1 in
            --ref) require_arg "$@"; ref=$2; shift 2 ;;
            *) die_unknown_arg "$1" ;;
        esac
    done
    [[ -n $repo ]] || die "нет метаданных установки ($WGN_HOME/.install) — переустанови через install.sh"
    exec bash "$WGN_HOME/install.sh" --repo "$repo" --ref "${ref:-main}"
}
