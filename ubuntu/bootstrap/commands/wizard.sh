# shellcheck shell=bash

CMD_SUMMARY='интерактивный мастер: профиль, модули, опции, план, применение'
CMD_GROUP=setup

cmd_usage() {
    cat <<'EOT'
Использование: ubuntu-bootstrap wizard [--advanced]

Пошагово: обзор сервера → профиль → набор модулей → опции каждого модуля → сохранение конфигурации
в /etc/ubuntu-bootstrap/bootstrap.conf → план (dry-run) → применение. Все ответы сохраняются,
повторный запуск предлагает их как значения по умолчанию. --advanced — спрашивать все опции.
EOT
}

wiz_ask_option() {
    local name=$1 cur hint answer idx
    local -a items=()
    cur="$(cfg "$name")"
    hint="$(opt_type_hint "$name")"
    case ${OPT_TYPE[$name]} in
        bool)
            if ask_yn "  ${OPT_HELP[$name]}?" "$([[ $(to_bool "${cur:-no}") == 1 ]] && echo y || echo n)"; then answer=yes; else answer=no; fi
            ;;
        enum:*)
            IFS=, read -r -a items <<< "${OPT_TYPE[$name]#enum:}"
            idx=1
            local i
            for i in "${!items[@]}"; do [[ ${items[i]} == "$cur" ]] && idx=$((i + 1)); done
            ask_choice idx "  ${OPT_HELP[$name]}" "$idx" "${items[@]}"
            answer=${items[idx - 1]}
            ;;
        *)
            # shellcheck disable=SC2329
            _wiz_validator() { opt_validate "$name" "$1"; }
            ask_input answer "  ${OPT_HELP[$name]} ($hint)" "$cur" _wiz_validator
            ;;
    esac
    [[ $answer == "${OPT_DEFAULT[$name]}" && -z ${CONF[$name]+x} ]] && return 0
    CONF["$name"]=$answer CONF_SOURCE["$name"]=wizard
}

wiz_reset_run_state() {
    RUN_APPLIED=() RUN_SKIPPED=() RUN_FAILED=() RUN_REFUSED=() RUN_ROLLED_BACK=() CHANGED_FILES=() WARNINGS=()
}

cmd_run() {
    local advanced=0 choice p m name def=1 i
    local -a profiles=() mods=() enabled=() labels=()
    [[ ${1-} == --advanced ]] && advanced=1
    interactive || die 'мастеру нужен терминал. Для автоматизации: ubuntu-bootstrap apply --profile NAME --set KEY=VALUE --yes'
    config_load

    log_title "ubuntu-bootstrap $(ubb_version) — мастер настройки сервера"
    facts_summary
    hr
    log_plain 'Мастер ничего не меняет до последнего шага: сначала сохраняется конфигурация и показывается план.'
    [[ -f $CONF_FILE ]] && log_info "найден $CONF_FILE — его значения предлагаются по умолчанию"

    mapfile -t profiles < <(profiles_list)
    for i in "${!profiles[@]}"; do [[ ${profiles[i]} == "${CONF[PROFILE]-}" ]] && def=$((i + 1)); done
    for p in "${profiles[@]}"; do labels+=("$p — $(grep -m1 '^# ' "$(profile_file "$p")" | sed 's/^# //')"); done
    labels+=('свой набор модулей (без профиля)')
    ask_choice choice 'Профиль сервера:' "$def" "${labels[@]}"
    if ((choice <= ${#profiles[@]})); then
        # Reload so the chosen profile supplies defaults while the saved file still wins over it.
        OPT_PROFILE=${profiles[choice - 1]}
        config_load
    else
        unset 'CONF[PROFILE]'
    fi
    config_modules mods

    log_title 'Модули'
    log_plain '  Зависимости включаются автоматически; preflight выполняется всегда.'
    for m in "${MOD_ALL[@]}"; do
        [[ $m == preflight ]] && continue
        if ((F_CONTAINER)) && [[ ${MOD_CONTAINER_OF[$m]} == 0 ]]; then
            log_plain "  $m: в контейнере не применяется — пропущен"
            continue
        fi
        if ask_yn "  $m — ${MOD_SUMMARY_OF[$m]}" "$(in_list "$m" "${mods[@]}" && echo y || echo n)"; then
            enabled+=("$m")
        fi
    done
    ((${#enabled[@]})) || die 'не выбрано ни одного модуля'
    modules_resolve mods "${enabled[@]}"
    CONF[MODULES]="$(join_by , "${mods[@]}")"
    unset 'CONF[MODULES_ADD]' 'CONF[MODULES_SKIP]'
    SELECTED_MODULES=("${mods[@]}")
    log_info "будут выполнены: ${mods[*]}"

    for m in "${mods[@]}"; do
        module_load "$m"
        CUR_MODULE_LOAD=$m
        local -a names=() adv_names=()
        for name in "${OPT_ORDER[@]}"; do
            [[ ${OPT_MODULE[$name]} == "$m" ]] || continue
            if [[ ${OPT_ADV[$name]} == 1 ]] && ((advanced == 0)); then adv_names+=("$name"); else names+=("$name"); fi
        done
        ((${#names[@]} + ${#adv_names[@]})) || continue
        log_title "[$m] $MOD_SUMMARY"
        mod_wizard
        for name in "${names[@]}"; do wiz_ask_option "$name"; done
        if ((${#adv_names[@]})) && ask_yn "  Настроить дополнительные опции ($(join_by ', ' "${adv_names[@]}"))?" n; then
            for name in "${adv_names[@]}"; do wiz_ask_option "$name"; done
        fi
    done
    unset CUR_MODULE_LOAD
    config_validate

    log_title 'Конфигурация'
    tx_begin wizard
    tx_module_begin wizard
    config_save "$CONF_FILE" "${mods[@]}"
    tx_set_status "done"
    log_ok "сохранено: $CONF_FILE (повторить без вопросов: sudo ubuntu-bootstrap apply --yes)"

    if ask_yn 'Показать план изменений (dry-run)?' y; then
        (
            DRY_RUN=1
            OPT_QUIET=0
            wiz_reset_run_state
            flock -u "$LOCK_FD"
            runner_apply
        ) || log_warn 'план завершился с замечаниями — смотри вывод выше'
    fi
    ask_yn 'Применить изменения сейчас?' y || { log_info 'применить позже: sudo ubuntu-bootstrap apply'; return 0; }
    flock -u "$LOCK_FD"
    exec {LOCK_FD}>&-
    wiz_reset_run_state
    EXIT_HOOKS=()
    UBB_CMD=apply
    runner_apply
}
