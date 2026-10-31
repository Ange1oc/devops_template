# shellcheck shell=bash
MOD_SUMMARY='Docker CE + Compose из официального репозитория, daemon.json, доступ пользователей'
MOD_GROUP=services
MOD_DEPS=(preflight base)

DOCKER_KEY_FPR='9DC858229FC7DD38854AE2D88D81803C0EBFCD88'
DOCKER_DAEMON_JSON='/etc/docker/daemon.json'
DOCKER_CONFLICTS=(docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc)

mod_options() {
    opt DOCKER_VERSION string '' 'Версия docker-ce (пусто — последняя; см. apt-cache madison docker-ce)' adv
    opt DOCKER_REMOVE_CONFLICTS bool yes 'Удалить дистрибутивные пакеты docker.io/containerd/runc (рекомендация docs.docker.com)'
    opt DOCKER_USERS users '' 'Пользователи в группе docker (= root-доступ к хосту; альтернатива — sudo docker)'
    opt DOCKER_LOG_MAX_SIZE size 20M 'Ротация логов контейнеров: размер файла' adv
    opt DOCKER_LOG_MAX_FILE int 5 'Ротация логов контейнеров: число файлов' adv
    opt DOCKER_LIVE_RESTORE bool yes 'live-restore: контейнеры переживают перезапуск демона' adv
    opt DOCKER_NO_NEW_PRIVILEGES bool no 'no-new-privileges по умолчанию для контейнеров (ломает образы с setuid)' adv
    opt DOCKER_PRUNE_TIMER bool no 'Еженедельная очистка неиспользуемых образов и build-кэша (systemd timer)' adv
}

mod_wizard() {
    log_plain '  Публикуй порты контейнеров на 127.0.0.1 (nginx проксирует наружу): Docker обходит UFW.'
    log_plain '  Группа docker = root без пароля (docker run -v /:/host). Безопаснее: sudo docker.'
}

docker_daemon_render() {
    local size
    size="$(cfg DOCKER_LOG_MAX_SIZE)"
    size="${size,,}"
    cat <<EOT
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "$size", "max-file": "$(cfg DOCKER_LOG_MAX_FILE)" },
  "live-restore": $(cfg_bool DOCKER_LIVE_RESTORE && echo true || echo false),
  "no-new-privileges": $(cfg_bool DOCKER_NO_NEW_PRIVILEGES && echo true || echo false),
  "default-ulimits": { "nofile": { "Name": "nofile", "Soft": 65535, "Hard": 524288 } }
}
EOT
}

# An existing daemon.json is merged, not replaced: our keys are added only when absent.
docker_daemon_merged() {
    if [[ -s $DOCKER_DAEMON_JSON ]] && has_cmd jq; then
        jq -S -s '.[1] * .[0]' "$DOCKER_DAEMON_JSON" <(docker_daemon_render)
    else
        docker_daemon_render
    fi
}

docker_running() { has_cmd docker && docker version --format '{{.Server.Version}}' >/dev/null 2>&1; }

mod_check() {
    pkg_installed docker-ce && pkg_installed docker-compose-plugin || return 1
    [[ -f /etc/apt/sources.list.d/docker.sources ]] || return 1
    [[ -f $DOCKER_DAEMON_JSON ]] && [[ $(jq -S . "$DOCKER_DAEMON_JSON" 2>/dev/null) == "$(docker_daemon_merged | jq -S . 2>/dev/null)" ]] || return 1
    local u
    local -a users=()
    cfg_list DOCKER_USERS users
    for u in "${users[@]}"; do user_in_group "$u" docker || return 1; done
    svc_active docker
}

mod_apply() {
    local p u ver_arg=''
    local -a users=() conflicts=()
    # Confirmations first, so a refusal leaves the system untouched.
    for p in "${DOCKER_CONFLICTS[@]}"; do pkg_installed "$p" && ! pkg_installed docker-ce && conflicts+=("$p"); done
    if ((${#conflicts[@]})); then
        if cfg_bool DOCKER_REMOVE_CONFLICTS; then
            confirm_danger "будут удалены пакеты ${conflicts[*]} (запущенные контейнеры docker.io остановятся; данные в /var/lib/docker сохраняются)" || return "$E_REFUSED"
        else
            guard_refuse "установлены конфликтующие пакеты: ${conflicts[*]}" || return
        fi
    fi
    cfg_list DOCKER_USERS users
    for u in "${users[@]}"; do
        user_exists "$u" && ! user_in_group "$u" docker || continue
        confirm_danger "$u получит доступ к docker.sock — это эквивалент root на сервере" || return "$E_REFUSED"
    done
    ((${#conflicts[@]})) && cfg_bool DOCKER_REMOVE_CONFLICTS && { apt_remove "${conflicts[@]}" || return 1; }
    apt_install ca-certificates curl gnupg || return 1
    apt_repo_add docker https://download.docker.com/linux/ubuntu "${F_OS_CODENAME}" stable \
        https://download.docker.com/linux/ubuntu/gpg "$DOCKER_KEY_FPR" || return 1
    if [[ -n $(cfg DOCKER_VERSION) ]]; then
        ver_arg="=$(cfg DOCKER_VERSION)"
        apt_update
        apt-cache madison docker-ce 2>/dev/null | grep -qF "$(cfg DOCKER_VERSION)" || { log_error "версия docker-ce $(cfg DOCKER_VERSION) недоступна: apt-cache madison docker-ce"; return 1; }
    fi
    if ! pkg_installed docker-ce; then
        undo systemctl disable --now docker.service containerd.service
        apt_install "docker-ce$ver_arg" "docker-ce-cli$ver_arg" containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    fi

    undo systemctl restart docker
    docker_daemon_merged | file_write "$DOCKER_DAEMON_JSON" 644
    local json_changed=${FILE_CHANGED:-0}
    ((DRY_RUN)) && return 0
    if ! svc_active docker; then
        svc_enable_now docker || return 1
    elif ((json_changed)); then
        log_info 'применяю daemon.json (restart docker; с live-restore контейнеры продолжают работать)'
        run systemctl restart docker || return 1
    fi
    svc_enabled docker || run systemctl enable docker containerd
    docker_running || { log_error 'docker не отвечает после запуска'; return 1; }
    log_ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null), compose $(docker compose version --short 2>/dev/null)"

    for u in "${users[@]}"; do
        user_exists "$u" || { log_warn "пользователя $u нет — пропущен"; continue; }
        user_in_group "$u" docker && continue
        undo gpasswd -d "$u" docker
        run usermod -aG docker "$u" && log_ok "$u добавлен в группу docker (нужен перелогин)"
    done

    if cfg_bool DOCKER_PRUNE_TIMER; then
        printf '[Unit]\nDescription=ubuntu-bootstrap: docker system prune\n[Service]\nType=oneshot\nExecStart=/usr/bin/docker system prune -f --filter until=168h\nExecStart=/usr/bin/docker builder prune -f --filter until=168h\n' |
            file_write /etc/systemd/system/ubuntu-bootstrap-docker-prune.service 644
        printf '[Unit]\nDescription=ubuntu-bootstrap: weekly docker prune\n[Timer]\nOnCalendar=Sun *-*-* 03:30\nRandomizedDelaySec=30m\nPersistent=true\n[Install]\nWantedBy=timers.target\n' |
            file_write /etc/systemd/system/ubuntu-bootstrap-docker-prune.timer 644
        undo systemctl disable --now ubuntu-bootstrap-docker-prune.timer
        svc_daemon_reload && svc_enable_now ubuntu-bootstrap-docker-prune.timer
    fi
    docker_report
    return 0
}

docker_report() {
    docker ps -q 2>/dev/null | grep -q . || return 0
    local priv pub
    priv="$(docker ps -q | xargs -r docker inspect --format '{{.Name}} privileged={{.HostConfig.Privileged}} sock={{range .Mounts}}{{if eq .Source "/var/run/docker.sock"}}yes{{end}}{{end}}' 2>/dev/null | grep -E 'privileged=true|sock=yes' || true)"
    [[ -n $priv ]] && log_warn "контейнеры с privileged или docker.sock: $(tr '\n' ' ' <<< "$priv")"
    pub="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E '0\.0\.0\.0|\[::\]' | awk '{ print $1 }' | tr '\n' ' ')"
    [[ -n $pub ]] && log_warn "порты на 0.0.0.0 (доступны снаружи в обход UFW без DOCKER-USER): $pub"
    return 0
}

mod_verify() { ((DRY_RUN)) || docker_running; }

mod_audit() {
    has_cmd docker || { check_info 'Docker не установлен'; return 0; }
    docker_running && check_ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) работает" || { check_fail 'Docker установлен, но не работает'; return 0; }
    pkg_installed docker-ce && check_ok 'пакет docker-ce (официальный репозиторий)' || check_warn 'Docker не из официального репозитория (docker.io/snap)'
    [[ -f $DOCKER_DAEMON_JSON ]] && jq -e '.["log-opts"]["max-size"]' "$DOCKER_DAEMON_JSON" >/dev/null 2>&1 && check_ok 'ротация логов контейнеров настроена' || check_warn 'нет ротации логов контейнеров (daemon.json log-opts)'
    local pub priv n
    pub="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E '0\.0\.0\.0|\[::\]' | awk '{ print $1 }' | tr '\n' ' ')"
    [[ -n $pub ]] && check_warn "контейнеры с портами на всех интерфейсах: $pub" 'публикуй на 127.0.0.1 или включи FW_DOCKER_PROTECT' || check_ok 'нет контейнеров с портами на 0.0.0.0'
    priv="$(docker ps -q 2>/dev/null | xargs -r docker inspect --format '{{.Name}} {{.HostConfig.Privileged}}' 2>/dev/null | awk '$2 == "true" { print $1 }' | tr '\n' ' ')"
    [[ -n $priv ]] && check_warn "privileged-контейнеры: $priv" || check_ok 'нет privileged-контейнеров'
    n="$(getent group docker 2>/dev/null | cut -d: -f4)"
    [[ -n $n ]] && check_info "в группе docker: $n" || check_ok 'группа docker пуста'
    df -BG --output=avail /var/lib/docker 2>/dev/null | tail -1 | tr -dc '0-9' | { read -r g; ((g < 5)) && check_warn "на /var/lib/docker свободно ${g} GiB" || true; }
    return 0
}
