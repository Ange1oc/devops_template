# shellcheck shell=bash

CMD_SUMMARY='применить выбранные модули'
CMD_GROUP=run

cmd_usage() {
    cat <<'EOT'
Использование: ubuntu-bootstrap apply [--profile NAME] [--set KEY=VALUE]... [--only M1,M2] [--skip M] [--yes] [--reapply]

Выполняет модули из конфигурации (или --only) в порядке зависимостей. Каждый модуль идемпотентен;
уже применённый с той же конфигурацией пропускается (--reapply — выполнить заново).
Ошибка модуля откатывает только его изменения и останавливает запуск (--keep-going — продолжать).
Рискованные изменения (SSH, firewall) ставятся на таймер отката до подтверждения.

Коды выхода: 0 — успех, 1 — ошибка, 3 — остановлено предохранителем, 4 — откат по таймеру/отказу, 5 — занято.
EOT
}

cmd_run() {
    while (($#)); do
        case $1 in
            --reapply) OPT_FORCE_REAPPLY=1; shift ;;
            *) die_usage "неизвестный аргумент: $1" ;;
        esac
    done
    config_load
    runner_select
    if pending_exists; then
        die_code "$E_BUSY" "модуль $(kv_get "$PENDING_FILE" MODULE) ждёт подтверждения: sudo ubuntu-bootstrap confirm (или rollback --pending)"
    fi
    runner_apply
}
