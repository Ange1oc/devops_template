# shellcheck shell=bash

CMD_SUMMARY='показать, проверить, изменить конфигурацию'
CMD_GROUP=setup

cmd_usage() {
    cat <<'EOT'
Использование: ubuntu-bootstrap config <show|validate|set KEY=VALUE...|get KEY|init [--profile NAME]|path>

  show       действующая конфигурация выбранных модулей и источник каждого значения
  validate   проверить файл конфигурации (и профиль)
  set        записать значения в /etc/ubuntu-bootstrap/bootstrap.conf
  get        напечатать значение опции
  init       создать файл конфигурации из профиля со всеми опциями и описаниями
  path       путь к файлу конфигурации
EOT
}

cmd_run() {
    local action=${1-} kv key name m src
    shift || true
    case $action in
        show)
            config_load
            runner_select
            printf '# конфиг: %s; профиль: %s\n# модули: %s\n' "${OPT_CONFIG_FILE:-$CONF_FILE}" "${CONF[PROFILE]:-—}" "${SELECTED_MODULES[*]}"
            for m in "${SELECTED_MODULES[@]}"; do
                for name in "${OPT_ORDER[@]}"; do
                    [[ ${OPT_MODULE[$name]} == "$m" ]] || continue
                    src=${CONF_SOURCE[$name]:-default}
                    printf '%-28s= %-30s # %s\n' "$name" "$(cfg "$name")" "$src"
                done
            done
            ;;
        validate)
            config_load
            runner_select
            log_ok "конфигурация корректна: ${#SELECTED_MODULES[@]} модулей (${SELECTED_MODULES[*]})"
            ;;
        get)
            [[ -n ${1-} ]] || die_usage 'config get KEY'
            config_load
            [[ -n ${OPT_TYPE[$1]-} ]] || die "неизвестная опция $1"
            cfg "$1"
            printf '\n'
            ;;
        set)
            (($#)) || die_usage 'config set KEY=VALUE...'
            require_root
            config_load
            for kv in "$@"; do
                [[ $kv == *=* ]] || die_usage "ожидается KEY=VALUE: $kv"
                key=${kv%%=*}
                [[ -n ${OPT_TYPE[$key]-} ]] || in_list "$key" "${CORE_KEYS[@]}" || die "неизвестная опция $key"
                CONF["$key"]=${kv#*=}
            done
            config_validate
            tx_begin config
            tx_module_begin config
            config_save_explicit "$CONF_FILE"
            tx_set_status "done"
            log_ok "записано в $CONF_FILE"
            ;;
        init)
            require_root
            [[ ${1-} == --profile && -n ${2-} ]] && OPT_PROFILE=$2
            config_load
            runner_select
            [[ -f $CONF_FILE ]] && ! ((OPT_FORCE)) && die "$CONF_FILE уже существует (перезаписать: --force)"
            tx_begin config
            tx_module_begin config
            config_save "$CONF_FILE" "${SELECTED_MODULES[@]}"
            tx_set_status "done"
            log_ok "создан $CONF_FILE — отредактируй и запусти: sudo ubuntu-bootstrap plan"
            ;;
        path) printf '%s\n' "${OPT_CONFIG_FILE:-$CONF_FILE}" ;;
        *) die_usage 'ожидается show | validate | get | set | init | path' ;;
    esac
}
