# shellcheck shell=bash

CMD_SUMMARY='показать, что изменит apply (dry-run)'
CMD_GROUP=run

cmd_usage() {
    cat <<'EOT'
Использование: ubuntu-bootstrap plan [--profile NAME] [--set KEY=VALUE] [--only M] [--skip M]

Эквивалент apply --dry-run: модули проходят свои проверки и печатают diff файлов и команды,
не меняя систему. Предохранители работают как при реальном применении.
EOT
}

cmd_run() {
    (($#)) && die_usage "лишние аргументы: $*"
    DRY_RUN=1
    config_load
    runner_select
    runner_apply
}
