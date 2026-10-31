# shellcheck shell=bash
MOD_SUMMARY='SSH hardening: вход по ключам, root, порт; таймер отката до подтверждения'
MOD_GROUP=security
MOD_DEFAULT=1
MOD_DEPS=(preflight)
MOD_AFTER=(users)

SSHD_CONF='/etc/ssh/sshd_config.d/00-ubuntu-bootstrap.conf'

mod_options() {
    opt SSH_PORT portkeep keep 'Порт SSH (keep — не менять)'
    opt SSH_PASSWORD_AUTH bool no 'Разрешить вход по паролю'
    opt SSH_PERMIT_ROOT enum:auto,no,prohibit-password,yes auto 'Вход root: auto — запретить, если есть администратор с ключом и рабочим sudo'
    opt SSH_ALLOW_USERS users '' 'AllowUsers: кому разрешён вход (пусто — всем)'
    opt SSH_CONFIRM enum:auto,wait,none auto 'Подтверждение доступа: auto — спросить/самопроверка, wait — ждать команду confirm, none — без таймера (только с --force)'
    opt SSH_CONFIRM_TIMEOUT int 180 'Секунд до автоматического отката без подтверждения'
    opt SSH_MAX_AUTH_TRIES int 4 'MaxAuthTries' adv
    opt SSH_LOGIN_GRACE int 30 'LoginGraceTime, с' adv
    opt SSH_CLIENT_ALIVE_INTERVAL int 300 'ClientAliveInterval, с (0 — выключить)' adv
    opt SSH_X11_FORWARDING bool no 'X11Forwarding' adv
    opt SSH_AGENT_FORWARDING bool no 'AllowAgentForwarding' adv
    opt SSH_TCP_FORWARDING bool yes 'AllowTcpForwarding (туннели, VS Code Remote)' adv
    opt SSH_LOG_LEVEL enum:INFO,VERBOSE VERBOSE 'LogLevel (VERBOSE пишет отпечатки ключей — полезно для аудита и fail2ban)' adv
    opt SSH_CLOSE_OLD_PORT bool yes 'После смены порта закрыть старый в UFW' adv
}

mod_wizard() {
    local admin
    admin="$(cfg ADMIN_USER)"
    log_plain "  Сейчас sshd слушает: ${F_SSHD_PORTS}; PasswordAuthentication=$(sshd_effective passwordauthentication), PermitRootLogin=$(sshd_effective permitrootlogin)"
    log_plain '  Смена порта убирает фоновый шум ботов, но забытый порт = потеря доступа; таймер отката страхует.'
    [[ -n $admin ]] && wiz_default SSH_ALLOW_USERS "$admin"
}

ssh_target_port() {
    local p
    p="$(cfg SSH_PORT)"
    [[ $p == keep ]] && p=${F_SSHD_PORTS%% *}
    printf '%s' "$p"
}

# Users allowed to log in after apply.
ssh_allowed_users() {
    local -a list=()
    cfg_list SSH_ALLOW_USERS list
    ((${#list[@]})) && { printf '%s\n' "${list[@]}"; return; }
    human_users
    printf 'root\n'
}

# A non-root user who can log in with a key and administer: prints the name or nothing.
ssh_admin_with_keys() {
    local u
    while read -r u; do
        [[ $u == root ]] && continue
        user_exists "$u" && user_has_keys "$u" && user_sudo_usable "$u" && { printf '%s' "$u"; return 0; }
    done < <(ssh_allowed_users)
    return 1
}

ssh_permit_root() {
    local v
    v="$(cfg SSH_PERMIT_ROOT)"
    if [[ $v == auto ]]; then
        if ssh_admin_with_keys >/dev/null; then v=no; else v=prohibit-password; fi
    fi
    printf '%s' "$v"
}

ssh_render() {
    local port permit_root pw
    port="$(ssh_target_port)"
    permit_root="$(ssh_permit_root)"
    cfg_bool SSH_PASSWORD_AUTH && pw=yes || pw=no
    printf '# ubuntu-bootstrap: included first (00-), so these values take precedence over other files.\n'
    [[ $(cfg SSH_PORT) != keep ]] && printf 'Port %s\n' "$port"
    printf 'PubkeyAuthentication yes\nPasswordAuthentication %s\n' "$pw"
    [[ $pw == no ]] && printf 'KbdInteractiveAuthentication no\n'
    printf 'PermitEmptyPasswords no\nPermitRootLogin %s\n' "$permit_root"
    printf 'MaxAuthTries %s\nLoginGraceTime %s\n' "$(cfg SSH_MAX_AUTH_TRIES)" "$(cfg SSH_LOGIN_GRACE)"
    printf 'ClientAliveInterval %s\nClientAliveCountMax 3\n' "$(cfg SSH_CLIENT_ALIVE_INTERVAL)"
    printf 'X11Forwarding %s\nAllowAgentForwarding %s\nAllowTcpForwarding %s\n' \
        "$(cfg_bool SSH_X11_FORWARDING && echo yes || echo no)" "$(cfg_bool SSH_AGENT_FORWARDING && echo yes || echo no)" "$(cfg_bool SSH_TCP_FORWARDING && echo yes || echo no)"
    printf 'LogLevel %s\nUseDNS no\n' "$(cfg SSH_LOG_LEVEL)"
    local -a users=()
    cfg_list SSH_ALLOW_USERS users
    ((${#users[@]})) && printf 'AllowUsers %s\n' "${users[*]}"
    return 0
}

ssh_effective_matches() {
    local pw
    cfg_bool SSH_PASSWORD_AUTH && pw=yes || pw=no
    [[ $(sshd_effective passwordauthentication) == "$pw" ]] || return 1
    [[ $(sshd_effective permitrootlogin) == "$(ssh_permit_root)" ]] || return 1
    [[ " $(sshd_effective_ports) " == *" $(ssh_target_port) "* ]] || return 1
    [[ $(sshd_effective maxauthtries) == "$(cfg SSH_MAX_AUTH_TRIES)" ]]
}

mod_check() {
    [[ -f $SSHD_CONF ]] && [[ $(cat "$SSHD_CONF") == "$(ssh_render)" ]] && ssh_effective_matches
}

# Guards: no change may leave the server without an administrator. All run before any change.
ssh_guards() {
    local port permit_root admin u
    port="$(ssh_target_port)"
    permit_root="$(ssh_permit_root)"
    [[ -d /etc/ssh/sshd_config.d ]] || { log_error 'нет /etc/ssh/sshd_config.d — слишком старая Ubuntu'; return 1; }
    grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null ||
        { guard_refuse 'sshd_config не включает sshd_config.d/*.conf — наш файл не будет прочитан' || return; }
    [[ $(cfg SSH_CONFIRM) != none ]] || { guard_refuse 'SSH_CONFIRM=none: конфиг sshd применится без таймера отката' || return; }

    if ! cfg_bool SSH_PASSWORD_AUTH; then
        local has_key=0
        while read -r u; do
            [[ $u == root && $permit_root == no ]] && continue
            user_exists "$u" && user_has_keys "$u" && { has_key=1; break; }
        done < <(ssh_allowed_users)
        ((has_key)) || { guard_refuse 'запрет паролей: ни у одного разрешённого пользователя нет authorized_keys — это гарантированная потеря доступа' || return; }
    fi
    if [[ $permit_root == no ]]; then
        admin="$(ssh_admin_with_keys)" || { guard_refuse 'PermitRootLogin no: нет пользователя с SSH-ключом и работающим sudo — сервер останется без администратора' || return; }
        log_ok "администратор с ключом и sudo: $admin"
    elif [[ $permit_root == yes ]]; then
        confirm_danger 'PermitRootLogin yes разрешает вход root по паролю — основная цель брутфорса' || return "$E_REFUSED"
    fi
    if [[ -n $F_SSH_CLIENT_IP && -n $(cfg SSH_ALLOW_USERS) ]] && ! ssh_allowed_users | grep -qx "$F_SSH_USER"; then
        if [[ $F_SSH_USER == root && $permit_root == no ]]; then
            log_warn 'текущая сессия root: новые входы root будут запрещены, эта сессия продолжит работать'
        else
            guard_refuse "текущий пользователь $F_SSH_USER не входит в AllowUsers — следующий вход будет невозможен" || return
        fi
    fi
    if [[ " $F_SSHD_PORTS " != *" $port "* ]]; then
        port_listening "$port" && { guard_refuse "порт $port уже занят другим сервисом" || return; }
        ((port >= 1024)) || log_warn "порт $port ниже 1024"
    fi
    return 0
}

# Local self-check for non-interactive confirmation: sshd answers on the new port and UFW allows it.
ssh_selfcheck() {
    local port banner=''
    port="$(ssh_target_port)"
    port_listening "$port" || return 1
    { exec 3<>"/dev/tcp/127.0.0.1/$port"; } 2>/dev/null || return 1
    read -r -t 5 banner <&3 || true
    exec 3>&-
    [[ $banner == SSH-2.0-* ]] || return 1
    if ufw_active; then
        ufw status 2>/dev/null | grep -Eq "^$port(/tcp)?[[:space:]]" || return 1
    fi
    return 0
}

mod_apply() {
    local port old_ports
    ssh_guards || return
    port="$(ssh_target_port)"
    old_ports=$F_SSHD_PORTS

    # Open the new port in UFW before sshd moves there, with the same action the firewall module uses.
    if [[ " $old_ports " != *" $port "* ]] && ufw_active; then
        local action=allow
        { module_enabled firewall || module_applied firewall; } && cfg_bool FW_SSH_LIMIT && action=limit
        log_info "UFW активен: открываю новый порт $port ($action) до перезапуска sshd"
        undo ufw --force delete "$action" "$port/tcp"
        run ufw "$action" "$port/tcp" comment 'SSH (ubuntu-bootstrap)' || return 1
    fi

    log_plain "  Планируемый $SSHD_CONF:"
    ssh_render | sed 's/^/    /' >&2
    undo sshd_apply "$port"
    ssh_render | file_write "$SSHD_CONF" 600
    if [[ ${FILE_CHANGED:-0} == 0 ]] && ssh_effective_matches; then
        log_ok 'конфиг sshd уже соответствует желаемому'
        return 0
    fi
    ((DRY_RUN)) && return 0
    sshd_apply "$old_ports" || return 1
    ssh_effective_matches || { log_error "sshd -T не отражает ожидаемые значения: $(sshd -T 2>/dev/null | grep -E '^(port|passwordauthentication|permitrootlogin) ' | tr '\n' ' ')"; return 1; }
    log_ok "sshd применён: порт $port, PasswordAuthentication=$(sshd_effective passwordauthentication), PermitRootLogin=$(sshd_effective permitrootlogin)"

    hr
    log_plain "${C_BOLD}  ПРОВЕРКА ДОСТУПА: не закрывай эту сессию. В новом терминале:${C_RESET}"
    log_plain "    ssh -p $port $(ssh_admin_with_keys || echo root)@${F_PRIMARY_IP:-<IP>}"
    hr
    confirm_or_rollback ssh "$(cfg SSH_CONFIRM_TIMEOUT)" "$(cfg SSH_CONFIRM)" 'Вход в новой сессии успешен?' ssh_selfcheck || return
    # In wait mode the confirmation arrives later via `confirm`, which closes the old port (mod_confirmed).
    pending_exists || ssh_close_stale_ports
    F_SSHD_PORTS="$(sshd_effective_ports)"
    return 0
}

# Remove our own UFW rules (comment 'SSH (ubuntu-bootstrap)') for ports sshd no longer listens on.
ssh_close_stale_ports() {
    local ports port action comment
    cfg_bool SSH_CLOSE_OLD_PORT && ufw_active || return 0
    ports=" $(sshd_effective_ports) "
    while read -r port action comment; do
        [[ $port == */tcp && $comment == 'SSH (ubuntu-bootstrap)' ]] || continue
        port=${port%/tcp}
        [[ $ports == *" $port "* ]] && continue
        [[ -n ${JOURNAL-} ]] && undo ufw "${action,,}" "$port/tcp"
        run ufw --force delete "${action,,}" "$port/tcp" && log_ok "старый SSH-порт $port закрыт в UFW"
    done < <(ufw status 2>/dev/null | awk -F'#' 'NF > 1 && $1 !~ /\(v6\)/ { split($1, a, " "); gsub(/^ /, "", $2); print a[1], a[2], $2 }')
    for port in $(ufw status 2>/dev/null | awk '$1 ~ /^[0-9]+\/tcp$/ && $3 == "Anywhere" && !/#/ { sub(/\/tcp/, "", $1); print $1 }'); do
        [[ $ports == *" $port "* ]] || log_warn "в UFW открыт порт $port без пометки ubuntu-bootstrap — если это старый SSH-порт, закрой его вручную"
    done
    return 0
}

mod_confirmed() { ssh_close_stale_ports; }

mod_verify() { ((DRY_RUN)) || ssh_effective_matches; }

mod_audit() {
    local v f
    v="$(sshd_effective passwordauthentication)"
    [[ $v == no ]] && check_ok 'вход по паролю запрещён' || check_fail "PasswordAuthentication $v"
    v="$(sshd_effective permitrootlogin)"
    case $v in
        no) check_ok 'вход root запрещён' ;;
        prohibit-password | without-password) check_warn 'root может входить по ключу' 'PermitRootLogin no после настройки администратора' ;;
        *) check_fail "PermitRootLogin $v" ;;
    esac
    v="$(sshd_effective maxauthtries)"
    ((v <= 4)) && check_ok "MaxAuthTries $v" || check_warn "MaxAuthTries $v (рекомендуется ≤ 4)"
    [[ $(sshd_effective x11forwarding) == no ]] && check_ok 'X11Forwarding выключен' || check_warn 'X11Forwarding включён'
    [[ $(sshd_effective permitemptypasswords) == no ]] && check_ok 'пустые пароли запрещены' || check_fail 'PermitEmptyPasswords yes'
    check_info "sshd слушает порты: $(sshd_effective_ports); LogLevel $(sshd_effective loglevel)"
    for f in /etc/ssh/ssh_host_*_key; do
        [[ -f $f && $(stat -c %a "$f") != 600 ]] && check_warn "права $f: $(stat -c %a "$f")"
    done
    [[ -f /etc/ssh/ssh_host_dsa_key ]] && check_warn 'есть DSA host key (устарел)'
    return 0
}
