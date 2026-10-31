# shellcheck shell=bash

CMD_SUMMARY='аудит безопасности и готовности к production (только чтение)'
CMD_GROUP=inspect

cmd_usage() {
    cat <<'EOT'
Использование: ubuntu-bootstrap audit [--all] [--json]

Проверки всех модулей (mod_audit) плюс общесистемные: открытые порты, пользователи, sudo, обновления,
сервисы в состоянии failed. Код выхода: 0 — порядок, 1 — есть предупреждения, 2 — есть проблемы.
EOT
}

audit_system() {
    local n failed out
    CUR_MODULE_LOAD=system
    case $F_OS_VERSION in
        22.04 | 24.04 | 26.04) check_ok "Ubuntu $F_OS_VERSION LTS поддерживается" ;;
        *) check_warn "Ubuntu ${F_OS_VERSION:-?} не входит в поддерживаемые LTS (22.04/24.04/26.04)" ;;
    esac
    ((F_REBOOT_REQUIRED)) && check_warn 'требуется перезагрузка (обновлено ядро или libc)' || check_ok 'перезагрузка не требуется'
    n="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ' || true)"
    ((n > 0)) && check_warn "доступно обновлений пакетов: $n" 'apt-get upgrade или модуль base' || check_ok 'все пакеты актуальны (по локальному кэшу apt)'
    if ((F_HAS_SYSTEMD)); then
        failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{ print $1 }' | tr '\n' ' ')"
        [[ -n $failed ]] && check_fail "сервисы в состоянии failed: $failed" || check_ok 'нет сервисов в состоянии failed'
    fi
    out="$(awk -F: '$2 == "" { print $1 }' /etc/shadow 2>/dev/null | tr '\n' ' ')"
    [[ -n $out ]] && check_fail "пользователи с пустым паролем: $out" || check_ok 'нет пользователей с пустым паролем'
    out="$(awk -F: '$3 == 0 && $1 != "root" { print $1 }' /etc/passwd | tr '\n' ' ')"
    [[ -n $out ]] && check_fail "посторонние учётные записи с UID 0: $out" || check_ok 'UID 0 только у root'
    out="$(grep -rhE '^[^#]*NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null | awk '{ print $1 }' | sort -u | tr '\n' ' ')"
    [[ -n $out ]] && check_info "sudo без пароля: $out" || check_ok 'sudo требует пароль у всех'
    out="$(find /root /home /opt /srv -maxdepth 4 \( -name '*.env' -o -name '.env*' -o -name '*.pem' -o -name 'id_*' -o -name '*.sql' \) \
        -type f -perm -o+r 2>/dev/null | grep -v '\.pub$' | head -5 | tr '\n' ' ')"
    [[ -n $out ]] && check_warn "файлы с секретами доступны всем на чтение: $out" 'chmod 600' || check_ok 'нет world-readable секретов в типовых местах'
    out="$(ss -Hlntu 2>/dev/null | awk '$5 !~ /^(127\.|\[::1\]|::1)/ { split($5, a, ":"); print $1 "/" a[length(a)] }' | sort -u | tr '\n' ' ')"
    check_info "порты, слушающие на всех интерфейсах: ${out:-нет}"
    if has_cmd aa-status; then
        aa-status --enabled 2>/dev/null && check_ok 'AppArmor включён' || check_warn 'AppArmor выключен'
    fi
    [[ ${F_DISK_FREE_GB:-0} -lt 2 ]] && check_fail "на / свободно ${F_DISK_FREE_GB} GiB" || check_ok "на / свободно ${F_DISK_FREE_GB:-?} GiB"
    out="$(find /var/log -maxdepth 1 -type f -size +500M 2>/dev/null | head -3 | tr '\n' ' ')"
    [[ -n $out ]] && check_warn "крупные логи (>500M): $out"
    unset CUR_MODULE_LOAD
}

cmd_run() {
    local m
    local -a mods=()
    [[ ${1-} == --all ]] && { shift; mods=("${MOD_ALL[@]}"); }
    config_load
    if ((${#mods[@]} == 0)); then
        runner_select
        mods=("${SELECTED_MODULES[@]}")
    fi
    SELECTED_MODULES=("${mods[@]}")
    audit_system
    for m in "${mods[@]}"; do
        module_load "$m"
        CUR_MODULE_LOAD=$m
        ((F_CONTAINER)) && ((MOD_CONTAINER == 0)) && continue
        mod_audit
    done
    unset CUR_MODULE_LOAD
    if ((OPT_JSON)); then audit_json; else
        log_title "Аудит $(hostname) — $(date '+%F %T')"
        audit_print
    fi
    audit_exit_code
}
