# shellcheck shell=bash

CMD_SUMMARY='диагностика самого инструмента и окружения'
CMD_GROUP=inspect
CMD_ROOT=0

cmd_usage() {
    cat <<'EOT'
Использование: ubuntu-bootstrap doctor

Проверяет окружение (ОС, systemd, сеть, apt), целостность установки, состояние запусков,
незавершённые транзакции и ожидающие подтверждения. Код выхода: 0, 1 — предупреждения, 2 — ошибки.
EOT
}

cmd_run() {
    local f d st
    CUR_MODULE_LOAD=doctor
    log_title 'Окружение'
    [[ $F_OS_ID == ubuntu ]] && check_ok "$F_PRETTY ($F_ARCH)" || check_fail "ОС не Ubuntu: ${F_OS_ID:-?}"
    in_list "$F_OS_VERSION" 22.04 24.04 26.04 && check_ok "версия $F_OS_VERSION поддерживается" || check_warn "версия $F_OS_VERSION не тестировалась"
    in_list "$F_ARCH" amd64 arm64 && check_ok "архитектура $F_ARCH" || check_warn "архитектура $F_ARCH не тестировалась"
    ((F_HAS_SYSTEMD)) && check_ok 'systemd' || check_fail 'нет systemd: сервисы и таймеры отката недоступны'
    ((F_CONTAINER)) && check_warn "контейнер ($F_VIRT): swap, sysctl, snap, часть firewall недоступны" || check_ok "виртуализация: $F_VIRT"
    for f in curl gpg ss ip flock sshd; do has_cmd "$f" && check_ok "команда $f" || check_warn "нет команды $f"; done
    if is_root; then
        apt_locked && check_warn 'apt/dpkg сейчас занят' || check_ok 'apt свободен'
    fi
    if curl -fsS --max-time 5 --proto '=https' -o /dev/null https://archive.ubuntu.com/ 2>/dev/null; then check_ok 'HTTPS до archive.ubuntu.com'; else check_warn 'нет доступа к archive.ubuntu.com по HTTPS'; fi

    log_title 'Установка'
    for f in "$UBB_HOME"/ubuntu-bootstrap "$UBB_HOME"/lib/*.sh "$UBB_HOME"/commands/*.sh "$UBB_HOME"/modules/*.sh; do
        bash -n "$f" 2>/dev/null || check_fail "синтаксическая ошибка: $f"
    done
    check_ok "синтаксис ${#MOD_ALL[@]} модулей и команд"
    [[ -f $UBB_HOME/.install ]] && check_ok "установлен из $(install_meta REPO)@$(install_meta REF) ($(install_meta COMMIT))" || check_info 'локальная копия (без install.sh)'
    [[ -L /usr/local/bin/ubuntu-bootstrap ]] && check_ok 'ссылка /usr/local/bin/ubuntu-bootstrap' || check_info 'нет ссылки в /usr/local/bin'
    # The rollback timer and the recover unit execute code from UBB_HOME as root.
    if [[ $(stat -c %u "$UBB_HOME") == 0 ]] && [[ -z $(find "$UBB_HOME" -perm /o+w -print -quit 2>/dev/null) ]]; then
        check_ok "$UBB_HOME принадлежит root и не доступен на запись остальным"
    else
        check_warn "$UBB_HOME доступен на запись не-root: таймер отката выполнит код оттуда от root" 'переустанови через install.sh'
    fi
    if ((F_HAS_SYSTEMD)); then
        svc_enabled "$RECOVER_UNIT" && check_ok "$RECOVER_UNIT включён (откат неподтверждённых изменений после перезагрузки)" || check_warn "$RECOVER_UNIT не включён" 'переустанови: install.sh'
    fi
    [[ -d $USER_MODULES_DIR ]] && check_info "свои модули: $(find "$USER_MODULES_DIR" -name '*.sh' -printf '%f ' 2>/dev/null)"

    log_title 'Состояние'
    if [[ -f $CONF_FILE ]]; then
        if (config_load) 2>/dev/null; then check_ok "конфиг $CONF_FILE корректен"; else check_fail "конфиг $CONF_FILE содержит ошибки" 'ubuntu-bootstrap config validate'; fi
    else
        check_info 'конфиг не создан (wizard или config init)'
    fi
    for d in "$RUNS_DIR"/*/; do
        [[ -f $d/run.env ]] || continue
        st="$(kv_get "$d/run.env" STATUS)"
        case $st in
            running) check_warn "запуск ${d%/} помечен running: процесс жив? (ps aux | grep ubuntu-bootstrap)" ;;
            interrupted) check_warn "запуск $(basename "$d") прерван; откат при необходимости: ubuntu-bootstrap rollback $(basename "$d")" ;;
        esac
    done
    if pending_exists; then
        check_warn "модуль $(kv_get "$PENDING_FILE" MODULE) ждёт подтверждения до $(date -d "@$(kv_get "$PENDING_FILE" DEADLINE)" +%T)" 'ubuntu-bootstrap confirm'
    else
        check_ok 'нет изменений, ожидающих подтверждения'
    fi
    unset CUR_MODULE_LOAD
    if ((OPT_JSON)); then audit_json; else audit_print; fi
    audit_exit_code
}
