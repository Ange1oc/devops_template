# shellcheck shell=bash

CMD_SUMMARY='подтвердить рискованные изменения (снять таймер отката)'
CMD_GROUP=run

cmd_usage() {
    cat <<'EOT'
Использование: ubuntu-bootstrap confirm

После смены SSH-порта или включения firewall зайди на сервер НОВОЙ сессией и выполни эту команду:
таймер автоматического отката будет снят. Без подтверждения конфигурация откатится сама.
EOT
}

cmd_run() {
    pending_exists || { log_info 'нет изменений, ожидающих подтверждения'; return 0; }
    pending_confirm
}
