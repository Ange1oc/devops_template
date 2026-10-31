# shellcheck shell=bash
MOD_SUMMARY='deploy-ключи для GitHub/GitLab/Bitbucket, known_hosts из официальных источников'
MOD_GROUP=access
MOD_DEPS=(preflight base)
MOD_AFTER=(users)

mod_options() {
    opt GIT_HOSTS hostnames '' 'Хосты Git: github.com, gitlab.com, bitbucket.org, свой (пусто — модуль не нужен)'
    opt GIT_USER user '' 'Пользователь, которому создаются ключи (пусто — ADMIN_USER или root)' adv
    opt GIT_CHECK bool no 'Проверить ssh -T после настройки (ключ должен быть уже добавлен в репозиторий)' adv
}

git_user() {
    local u
    u="$(cfg GIT_USER)"
    [[ -z $u ]] && u="$(cfg ADMIN_USER)"
    [[ -z $u ]] && u=root
    printf '%s' "$u"
}

# GitHub host keys come from api.github.com/meta (trust via TLS); other hosts use ssh-keyscan and show fingerprints.
git_known_hosts_lines() {
    local host=$1 tmp
    case $host in
        github.com)
            tmp="$(make_tmp_dir)"
            fetch_url https://api.github.com/meta "$tmp/meta" && jq -r '.ssh_keys[] | "github.com \(.)"' "$tmp/meta" 2>/dev/null && return 0
            ;;
    esac
    log_warn "known_hosts для $host получен через ssh-keyscan: сверь отпечатки с документацией провайдера"
    ssh-keyscan -T 10 -t ed25519,rsa,ecdsa "$host" 2>/dev/null
}

mod_check() {
    local -a hosts=()
    local h u home
    cfg_list GIT_HOSTS hosts
    ((${#hosts[@]})) || return 0
    u="$(git_user)"
    home="$(user_home "$u")"
    for h in "${hosts[@]}"; do
        [[ -f $home/.ssh/deploy_${h%%.*} ]] || return 1
        grep -qs "^$h " "$home/.ssh/known_hosts" || return 1
    done
}

mod_apply() {
    local -a hosts=()
    local h u home key cfgfile out
    cfg_list GIT_HOSTS hosts
    ((${#hosts[@]})) || { log_info 'GIT_HOSTS пуст — модуль ничего не делает'; return 0; }
    u="$(git_user)"
    user_exists "$u" || { log_error "пользователя $u нет"; return 1; }
    home="$(user_home "$u")"
    ((DRY_RUN)) || install -d -m 700 -o "$u" -g "$u" "$home/.ssh"
    for h in "${hosts[@]}"; do
        key="$home/.ssh/deploy_${h%%.*}"
        if [[ -f $key ]]; then
            log_ok "ключ $key уже есть"
        else
            undo rm -f "$key" "$key.pub"
            run sudo -u "$u" ssh-keygen -q -t ed25519 -f "$key" -N '' -C "deploy@$(hostname)-$h" || return 1
            log_ok "создан ключ $key"
        fi
        if ! grep -qs "^$h " "$home/.ssh/known_hosts"; then
            out="$(git_known_hosts_lines "$h")"
            [[ -n $out ]] || { log_error "не удалось получить host keys $h"; return 1; }
            { [[ -f $home/.ssh/known_hosts ]] && cat "$home/.ssh/known_hosts"; printf '%s\n' "$out"; } | file_write "$home/.ssh/known_hosts" 644 "$u:$u"
            log_plain "  отпечатки $h:"
            printf '%s\n' "$out" | ssh-keygen -lf - 2>/dev/null | sed 's/^/    /' >&2
        fi
        cfgfile="$home/.ssh/config"
        if ! grep -qs "^Host $h\$" "$cfgfile"; then
            { [[ -f $cfgfile ]] && cat "$cfgfile" && printf '\n'; printf 'Host %s\n    IdentityFile %s\n    IdentitiesOnly yes\n' "$h" "$key"; } | file_write "$cfgfile" 600 "$u:$u"
        fi
        ((DRY_RUN)) && continue
        log_plain "  Публичный ключ для $h (добавь как Deploy key):"
        sed 's/^/    /' "$key.pub" >&2
        if cfg_bool GIT_CHECK; then
            out="$(sudo -u "$u" ssh -T -o BatchMode=yes -o ConnectTimeout=10 "git@$h" 2>&1 || true)"
            grep -qiE 'successfully authenticated|welcome' <<< "$out" && log_ok "аутентификация в $h работает" || log_warn "аутентификация в $h не подтверждена: $(head -1 <<< "$out")"
        fi
    done
    return 0
}

mod_verify() { ((DRY_RUN)) || mod_check; }

mod_audit() {
    local -a hosts=()
    cfg_list GIT_HOSTS hosts
    ((${#hosts[@]})) || return 0
    mod_check && check_ok "deploy-ключи для ${hosts[*]} настроены" || check_warn 'deploy-ключи не настроены полностью'
}
