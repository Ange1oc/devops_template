# shellcheck shell=bash
MOD_SUMMARY='администратор: пользователь, sudo, SSH-ключи'
MOD_GROUP=access
MOD_DEFAULT=1
MOD_DEPS=(preflight)

mod_options() {
    opt ADMIN_USER user '' 'Имя административного пользователя (пусто — не создавать)'
    opt ADMIN_SSH_KEYS keys '' 'Публичные SSH-ключи администратора (через ";")'
    opt ADMIN_SSH_KEYS_GITHUB list '' 'Логины GitHub, чьи ключи добавить (https://github.com/<логин>.keys)'
    opt ADMIN_COPY_ROOT_KEYS enum:auto,yes,no auto 'Скопировать authorized_keys root администратору (auto — если других ключей нет)'
    opt ADMIN_SUDO bool yes 'Выдать права sudo'
    opt ADMIN_SUDO_MODE enum:password,nopasswd password 'sudo: password — спрашивать пароль (рекомендуется), nopasswd — без пароля'
    opt ADMIN_PASSWORD_HASH string '' 'Хэш пароля (mkpasswd -m sha-512) для неинтерактивной установки; пусто — спросить в терминале' adv
    opt ADMIN_SHELL path /bin/bash 'Оболочка' adv
    opt ADMIN_GROUPS list '' 'Дополнительные группы' adv
}

mod_wizard() {
    wiz_default ADMIN_USER deploy
    if [[ -s /root/.ssh/authorized_keys ]]; then
        log_plain "  У root есть authorized_keys ($(grep -cE '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys) ключей) — их можно скопировать администратору."
    fi
    log_plain '  Без ключа у администратора SSH-hardening откажется запрещать вход по паролю.'
}

# Configured keys, one per line: explicit ones plus those fetched from GitHub.
admin_keys_collect() {
    local -a gh=()
    local k u tmp v
    v="$(cfg ADMIN_SSH_KEYS)"
    while IFS= read -r k; do [[ -n $k ]] && printf '%s\n' "$k"; done <<< "${v//;/$'\n'}"
    cfg_list ADMIN_SSH_KEYS_GITHUB gh
    for u in "${gh[@]}"; do
        [[ $u =~ ^[A-Za-z0-9-]{1,39}$ ]] || { log_error "некорректный логин GitHub: $u"; return 1; }
        tmp="$(make_tmp_dir)"
        fetch_url "https://github.com/$u.keys" "$tmp/keys" || { log_error "не удалось получить ключи github.com/$u"; return 1; }
        while IFS= read -r k; do
            is_ssh_pubkey "$k" || continue
            printf '%s github:%s\n' "$k" "$u"
        done < "$tmp/keys"
    done
    return 0
}

admin_sudoers_file() { printf '/etc/sudoers.d/90-ubuntu-bootstrap-%s' "$1"; }

mod_check() {
    local u
    u="$(cfg ADMIN_USER)"
    [[ -z $u ]] && return 0
    user_exists "$u" || return 1
    ! cfg_bool ADMIN_SUDO || user_sudo_usable "$u" || return 1
    [[ -z $(cfg ADMIN_SSH_KEYS)$(cfg ADMIN_SSH_KEYS_GITHUB) ]] || user_has_keys "$u"
}

mod_apply() {
    local u home ak k mode hash sudoers keys_out
    local -a keys=() groups=()
    u="$(cfg ADMIN_USER)"
    [[ -z $u ]] && { log_info 'ADMIN_USER не задан — модуль ничего не делает'; return 0; }
    mode="$(cfg ADMIN_SUDO_MODE)"
    sudoers="$(admin_sudoers_file "$u")"
    if cfg_bool ADMIN_SUDO && [[ $mode == nopasswd && ! -f $sudoers ]]; then
        confirm_danger "$u получит root без пароля (NOPASSWD): компрометация SSH-ключа = мгновенный root" || return "$E_REFUSED"
    fi
    keys_out="$(admin_keys_collect)" || return 1
    [[ -n $keys_out ]] && mapfile -t keys <<< "$keys_out"

    if ! user_exists "$u"; then
        log_info "создаю пользователя $u"
        undo userdel -r "$u"
        run useradd -m -s "$(cfg ADMIN_SHELL)" -U "$u" || return 1
        plan_mark "user:$u"
        # Password locked: key-only login; sudo is handled below.
        run passwd -l "$u" || true
    else
        log_ok "пользователь $u существует (uid $(id -u "$u" 2>/dev/null))"
        (($(id -u "$u" 2>/dev/null || echo 1000) < 1000)) && log_warn "$u — системный пользователь"
    fi
    home="$(user_home "$u")"
    [[ -n $home ]] || home="/home/$u"
    ak="$home/.ssh/authorized_keys"

    if ((${#keys[@]} == 0)) && [[ -s /root/.ssh/authorized_keys ]]; then
        case $(cfg ADMIN_COPY_ROOT_KEYS) in
            yes) mapfile -t keys < <(grep -E '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys) ;;
            auto) user_has_keys "$u" || mapfile -t keys < <(grep -E '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys) ;;
        esac
        ((${#keys[@]})) && log_info "копирую ${#keys[@]} ключ(ей) root пользователю $u"
    fi
    if ((${#keys[@]})); then
        local current='' merged
        [[ -f $ak ]] && current="$(cat "$ak")"
        merged=$current
        for k in "${keys[@]}"; do
            grep -qF -- "$(printf '%s' "$k" | awk '{ print $2 }')" <<< "$current" && continue
            [[ -n $merged ]] && merged+=$'\n'
            merged+=$k
        done
        ((DRY_RUN)) || install -d -m 700 -o "$u" -g "$u" "$home/.ssh"
        printf '%s\n' "$merged" | file_write "$ak" 600 "$u:$u"
        plan_mark "keys:$u"
        [[ ${FILE_CHANGED:-0} == 1 ]] && log_ok "authorized_keys обновлён ($(grep -cE '^(ssh-|ecdsa-|sk-)' <<< "$merged") ключей)"
    fi
    if [[ -d $home/.ssh ]] && ((DRY_RUN == 0)); then
        chown -R "$u:$u" "$home/.ssh"
        chmod 700 "$home/.ssh"
        [[ -f $ak ]] && chmod 600 "$ak"
    fi
    user_has_keys "$u" || ((DRY_RUN && ${#keys[@]})) || log_warn "у $u нет SSH-ключей: вход по SSH после hardening будет невозможен"

    cfg_list ADMIN_GROUPS groups
    for k in "${groups[@]}"; do
        getent group "$k" >/dev/null || { log_warn "группы $k нет — пропущена"; continue; }
        user_in_group "$u" "$k" || { undo gpasswd -d "$u" "$k"; run usermod -aG "$k" "$u"; }
    done
    cfg_bool ADMIN_SUDO || return 0

    user_in_group "$u" sudo || { undo gpasswd -d "$u" sudo; run usermod -aG sudo "$u" || return 1; }
    if [[ $mode == nopasswd ]]; then
        if [[ ! -f $sudoers ]]; then
            printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$u" | file_write "$sudoers" 440
            plan_mark "sudo:$u"
            if ((DRY_RUN == 0)) && ! visudo -cf "$sudoers" >> "$LOG_FILE" 2>&1; then
                log_error 'visudo забраковал файл sudoers'
                return 1
            fi
        fi
    else
        [[ -f $sudoers ]] && file_remove "$sudoers"
        hash="$(cfg ADMIN_PASSWORD_HASH)"
        if [[ $(user_password_state "$u") != P ]]; then
            if [[ -n $hash ]]; then
                [[ $hash == \$* ]] || { log_error "ADMIN_PASSWORD_HASH должен быть crypt-хэшем вида \$6\$..."; return 1; }
                ((DRY_RUN)) || printf '%s:%s\n' "$u" "$hash" | chpasswd -e || return 1
                plan_mark "sudo:$u"
                log_ok 'пароль установлен из хэша'
            elif interactive && ((DRY_RUN == 0)); then
                log_plain "  Пароль нужен только для sudo; вход по SSH паролем будет закрыт модулем ssh."
                # shellcheck disable=SC2094
                until passwd "$u" < "$UI_TTY" > "$UI_TTY" 2>&1; do
                    ask_yn 'Не удалось задать пароль. Повторить?' y || break
                done
            else
                log_warn "у $u нет пароля: sudo не заработает, пока его не задать (passwd $u) или ADMIN_SUDO_MODE=nopasswd"
                log_warn 'модуль ssh в этом состоянии не запретит вход root по ключу'
            fi
        fi
    fi
    user_sudo_usable "$u" && log_ok "sudo у $u работоспособен ($mode)"
    return 0
}

mod_verify() {
    local u
    u="$(cfg ADMIN_USER)"
    [[ -z $u ]] || user_exists "$u"
}

mod_audit() {
    local u n home
    u="$(cfg ADMIN_USER)"
    n="$(human_users | wc -l)"
    check_info "обычных пользователей: $n ($(human_users | tr '\n' ' '))"
    [[ -z $u ]] && return 0
    user_exists "$u" && check_ok "администратор $u существует" || { check_fail "администратор $u не создан"; return 0; }
    user_has_keys "$u" && check_ok "$u: есть SSH-ключи" || check_warn "$u: нет SSH-ключей"
    if cfg_bool ADMIN_SUDO; then user_sudo_usable "$u" && check_ok "$u: sudo работает" || check_fail "$u: sudo не работает (нет пароля и NOPASSWD)"; fi
    home="$(user_home "$u")"
    [[ -d $home/.ssh && $(stat -c %a "$home/.ssh") == 700 ]] && check_ok "$u: права ~/.ssh 700" || check_warn "$u: права ~/.ssh не 700"
}
