# shellcheck shell=bash
# Module execution: state check, apply, rollback on failure, confirmation of risky changes.

declare -ga SELECTED_MODULES=() RUN_APPLIED=() RUN_SKIPPED=() RUN_FAILED=() RUN_REFUSED=() RUN_ROLLED_BACK=()

# Guard: refuse unless --force. Modules call it before changing anything.
guard_refuse() {
    if ((OPT_FORCE)); then
        log_warn "предохранитель снят (--force): $*"
        return 0
    fi
    log_error "$*"
    log_error 'операция остановлена предохранителем; --force снимает его, если ты понимаешь последствия'
    return "$E_REFUSED"
}

runner_select() {
    modules_selected SELECTED_MODULES
    ((${#SELECTED_MODULES[@]})) || die 'не выбрано ни одного модуля'
}

module_is_current() {
    local m=$1
    [[ $(module_state_get "$m" STATUS) == applied && $(module_state_get "$m" CONFIG_HASH) == "$(module_config_hash "$m")" ]] || return 1
    mod_check
}

runner_apply() {
    local m rc summary
    tx_begin "${UBB_CMD}"
    log_title "ubuntu-bootstrap $(ubb_version): ${UBB_CMD} (${RUN_ID})"
    ((DRY_RUN)) && log_warn 'DRY-RUN: система не меняется, показываются планируемые изменения'
    log_info "модули: ${SELECTED_MODULES[*]}"
    for m in "${SELECTED_MODULES[@]}"; do
        module_load "$m"
        summary=$MOD_SUMMARY
        if ((F_CONTAINER)) && ((MOD_CONTAINER == 0)); then
            log_warn "[$m] внутри контейнера не применяется — пропущен"
            RUN_SKIPPED+=("$m")
            continue
        fi
        if ((OPT_FORCE_REAPPLY == 0 && MOD_ALWAYS == 0)) && module_is_current "$m"; then
            log_ok "[$m] уже применён, конфигурация не менялась"
            RUN_SKIPPED+=("$m")
            continue
        fi
        log_title "[$m] $summary"
        tx_module_begin "$m"
        CUR_MODULE_LOAD=$m
        rc=0
        mod_apply || rc=$?
        case $rc in
            0)
                if ((DRY_RUN)); then
                    RUN_APPLIED+=("$m")
                elif mod_verify; then
                    runner_mark_applied "$m"
                    RUN_APPLIED+=("$m")
                    log_ok "[$m] готово"
                else
                    log_error "[$m] проверка после применения не прошла — откатываю"
                    runner_fail "$m" || break
                fi
                ;;
            "$E_REFUSED")
                RUN_REFUSED+=("$m")
                ((DRY_RUN)) || tx_rollback_journal "$JOURNAL" "$m" || log_warn "[$m] откат завершился с ошибками; бэкапы: $BACKUP_DIR"
                module_state_set "$m" STATUS refused
                ((OPT_KEEP_GOING)) || { log_error "[$m] остановлен предохранителем; остальные модули не выполнялись"; break; }
                ;;
            "$E_ROLLED_BACK")
                RUN_ROLLED_BACK+=("$m")
                ((OPT_KEEP_GOING)) || break
                ;;
            *)
                log_error "[$m] ошибка (код $rc) — откатываю изменения модуля"
                runner_fail "$m" || break
                ;;
        esac
    done
    unset CUR_MODULE_LOAD
    runner_finish
}

runner_mark_applied() {
    local m=$1
    module_state_set "$m" STATUS applied
    module_state_set "$m" CONFIG_HASH "$(module_config_hash "$m")"
    module_state_set "$m" APPLIED_AT "$(now_iso)"
    module_state_set "$m" RUN_ID "$RUN_ID"
    module_state_set "$m" VERSION "$(ubb_version)"
}

# Roll back a failed module. Returns 1 when the run must stop.
runner_fail() {
    local m=$1
    RUN_FAILED+=("$m")
    if ((DRY_RUN)); then
        ((OPT_KEEP_GOING))
        return
    fi
    pending_exists && [[ $(kv_get "$PENDING_FILE" MODULE) == "$m" ]] && pending_disarm
    tx_rollback_journal "$JOURNAL" "$m" || log_warn "[$m] откат завершился с ошибками, проверь систему вручную; бэкапы: $BACKUP_DIR"
    module_state_set "$m" STATUS failed
    module_state_set "$m" RUN_ID "$RUN_ID"
    audit_log "run=$RUN_ID module=$m failed"
    ((OPT_KEEP_GOING))
}

runner_finish() {
    local status="done" rc=0
    ((${#RUN_FAILED[@]})) && { status=failed; rc=$E_ERROR; }
    ((${#RUN_REFUSED[@]})) && { status=refused; ((rc)) || rc=$E_REFUSED; }
    ((${#RUN_ROLLED_BACK[@]})) && { status=rolled_back; ((rc)) || rc=$E_ROLLED_BACK; }
    tx_set_status "$status"
    audit_log "run=$RUN_ID finish status=$status"
    log_title "Итог ${UBB_CMD} (${RUN_ID})"
    ((${#RUN_APPLIED[@]})) && log_plain "  ${C_GREEN}применено:${C_RESET}   ${RUN_APPLIED[*]}"
    ((${#RUN_SKIPPED[@]})) && log_plain "  пропущено:   ${RUN_SKIPPED[*]}"
    ((${#RUN_ROLLED_BACK[@]})) && log_plain "  ${C_YELLOW}откачено:${C_RESET}    ${RUN_ROLLED_BACK[*]}"
    ((${#RUN_REFUSED[@]})) && log_plain "  ${C_RED}остановлено предохранителем:${C_RESET} ${RUN_REFUSED[*]}"
    ((${#RUN_FAILED[@]})) && log_plain "  ${C_RED}ошибки (откачены):${C_RESET} ${RUN_FAILED[*]}"
    if ((${#CHANGED_FILES[@]})); then
        log_plain "  файлы (${#CHANGED_FILES[@]}): $(printf '%s\n' "${CHANGED_FILES[@]}" | sort -u | head -30 | tr '\n' ' ')"
    fi
    if ((${#WARNINGS[@]})); then
        log_plain "  ${C_YELLOW}предупреждения:${C_RESET}"
        printf '%s\n' "${WARNINGS[@]}" | sort -u | sed 's/^/    ! /' >&2
    fi
    pending_exists && log_plain "  ${C_YELLOW}ожидает подтверждения:${C_RESET} модуль $(kv_get "$PENDING_FILE" MODULE) — в новой сессии: sudo ubuntu-bootstrap confirm"
    ((DRY_RUN)) || log_plain "  бэкапы: $BACKUP_DIR"
    log_plain "  лог:    $LOG_FILE"
    [[ -f /var/run/reboot-required ]] && log_warn 'системе требуется перезагрузка (/var/run/reboot-required)'
    return "$rc"
}

# confirm_or_rollback MODULE TIMEOUT MODE QUESTION SELFCHECK_FN
# A risky change (sshd, firewall) is in place; access must be confirmed or the module rolls back.
# MODE: auto — ask interactively, without a TTY run SELFCHECK_FN; wait — leave the timer armed and
# return, `confirm` from another session cancels it; none — no timer (the module's guards must
# have passed this with --force).
confirm_or_rollback() {
    local module=$1 timeout=$2 mode=$3 question=$4 selfcheck=$5 rc
    ((DRY_RUN)) && { log_info "[dry-run] таймер отката ${timeout}s, режим $mode"; return 0; }
    if [[ $mode == none ]]; then
        log_warn "режим подтверждения none: изменения $module вступили в силу без страховки отката"
        return 0
    fi
    pending_arm "$module" "$timeout" "$question"
    log_warn "если доступ потерян, через ${timeout} с конфигурация $module откатится сама"
    log_plain "  Подтвердить из другой сессии: ${C_BOLD}sudo ubuntu-bootstrap confirm${C_RESET}   Откатить сейчас: sudo ubuntu-bootstrap rollback --pending"
    if interactive; then
        wait_confirmation "$timeout" "$question" && rc=0 || rc=$?
    elif [[ $mode == wait ]]; then
        log_info "неинтерактивный режим: жду подтверждения командой confirm (до ${timeout} с), процесс не блокируется"
        return 0
    else
        sleep 2
        if "$selfcheck"; then
            log_ok "самопроверка пройдена — подтверждаю автоматически"
            rc=0
        else
            log_error 'самопроверка не пройдена'
            rc=1
        fi
    fi
    case $rc in
        0) pending_confirm; return 0 ;;
        2)
            [[ -n $(module_state_get "$module" CONFIRMED_AT) ]] && { log_ok "подтверждено из другой сессии"; return 0; }
            log_warn "изменения $module были откачены таймером"
            return "$E_ROLLED_BACK"
            ;;
        *)
            pending_rollback manual
            return "$E_ROLLED_BACK"
            ;;
    esac
}
