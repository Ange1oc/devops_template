# shellcheck shell=bash

CMD_SUMMARY='версия и источник установки'
CMD_GROUP=maintenance
CMD_READONLY=1
CMD_ROOT=0
CMD_IFACE=0

cmd_usage() {
    echo 'Использование: wg-network version'
}

cmd_run() {
    printf 'wg-network %s\n' "$(wgn_version)"
    printf '  путь:        %s\n' "$WGN_HOME"
    printf '  репозиторий: %s\n' "$(install_meta REPO)"
    printf '  ref:         %s\n' "$(install_meta REF)"
    printf '  commit:      %s\n' "$(install_meta COMMIT)"
    printf '  установлен:  %s\n' "$(install_meta INSTALLED_AT)"
    has_cmd wg && printf '  %s\n' "$(wg --version 2>/dev/null)"
    return 0
}
