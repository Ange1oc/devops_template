# shellcheck shell=bash

CMD_SUMMARY='подключить удалённый сервер по SSH одной командой'
CMD_GROUP=peers

cmd_usage() {
    cat <<'EOF'
Использование: wg-network [-i IFACE] deploy NAME [USER@]HOST [опции]

Выполняет на hub весь цикл подключения: invite → (установка) → join на удалённом сервере
по SSH → peer add здесь → ожидание handshake. Токен с preshared key передаётся через stdin
SSH-сессии: он не попадает ни в argv, ни в историю команд.

  --install              сначала установить wg-network на удалённом сервере
  --remote-iface IFACE   интерфейс на удалённом сервере (по умолчанию wg0)
  --ssh-option OPT       опция ssh -o (можно несколько): --ssh-option Port=2222
  --routes CIDR,...      сети за новым peer (site-to-site)
  --full-tunnel          весь трафик peer через hub (нужен --nat на hub)
  --keepalive N, --no-psk, --comment TEXT   как в invite
  --wait N               ждать handshake до N секунд (по умолчанию 20; 0 — не ждать)

Требования к удалённому серверу: вход по ключу (ssh BatchMode) под root или пользователем
с sudo без пароля. Предохранители удалённой стороны (SSH, чужие VPN, сети) продолжают
работать: например, full tunnel, отрезающий SSH-доступ к серверу, будет отклонён.
EOF
}

# Remote command as root: directly, or through sudo -n (never an interactive password prompt).
remote_sudo() {
    # shellcheck disable=SC2016  # $(id -u) is expanded by the remote shell
    printf 'if [ "$(id -u)" = 0 ]; then %s; else sudo -n %s; fi' "$1" "$1"
}

# The remote side has not joined: drop the reservation so the name and address are free again.
deploy_abort() {
    log_error "$1 — снимаю резервацию '$DEPLOY_NAME'"
    "${DEPLOY_SELF[@]}" peer remove "$DEPLOY_NAME" --yes >/dev/null 2>&1 || true
    exit "$E_ERROR"
}

cmd_run() {
    local name='' target='' install=0 riface=wg0 wait=20 json key result token
    local -a ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15) invite_args=() add_args=() self=("$WGN_HOME/wg-network" -i "$IFACE")
    while (($#)); do
        case $1 in
            --install) install=1; shift ;;
            --remote-iface) require_arg "$@"; riface=$2; shift 2 ;;
            --ssh-option) require_arg "$@"; ssh_opts+=(-o "$2"); shift 2 ;;
            --routes | --keepalive | --comment) require_arg "$@"; invite_args+=("$1" "$2"); shift 2 ;;
            --full-tunnel | --no-psk) invite_args+=("$1"); shift ;;
            --wait) require_arg "$@"; wait=$2; shift 2 ;;
            -*) die_unknown_arg "$1" ;;
            *)
                if [[ -z $name ]]; then name=$1; elif [[ -z $target ]]; then target=$1; else die_unknown_arg "$1"; fi
                shift
                ;;
        esac
    done
    [[ -n $name && -n $target ]] || die_usage 'укажи имя peer и [USER@]HOST'
    is_name "$name" || die_usage "некорректное имя: $name"
    is_iface "$riface" || die_usage "некорректный --remote-iface: $riface"
    is_uint "$wait" || die_usage '--wait: число секунд'
    [[ $target =~ ^([A-Za-z0-9._-]+@)?[A-Za-z0-9._:-]+$ && $target != -* ]] || die_usage "некорректный адрес SSH: $target"
    require_cmd ssh
    require_managed
    st_node_load
    require_role hub
    ((OPT_FORCE)) && invite_args+=(--force)
    DEPLOY_NAME=$name
    DEPLOY_SELF=("${self[@]}")
    ((OPT_YES)) && add_args+=(--yes)
    ((OPT_APPLY)) && add_args+=(--apply)

    log_info "1/4 Резервирую адрес для '$name'"
    json="$("${self[@]}" invite "$name" --json "${invite_args[@]}")" || die "invite не удался"
    token="$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' <<< "$json")"
    [[ -n $token ]] || die 'invite не вернул токен'

    if ((install)); then
        log_info "2/4 Устанавливаю wg-network на $target"
        # pipefail: otherwise a failed curl would feed bash an empty script and report success.
        local ref install_cmd
        ref="$(install_meta REF)"
        install_cmd="bash -o pipefail -c $(printf '%q' "curl -fsSL --proto =https --tlsv1.2 $(install_url) | bash -s -- --ref ${ref:-main}")"
        # shellcheck disable=SC2029  # expanded locally on purpose
        ssh "${ssh_opts[@]}" "$target" "$(remote_sudo "$install_cmd")" </dev/null >&2 ||
            deploy_abort "установка на $target не удалась"
    else
        log_info "2/4 Установка пропущена (--install, если wg-network на $target ещё нет)"
    fi

    log_info "3/4 Подключаю $target (join через SSH, токен — через stdin)"
    # shellcheck disable=SC2029
    json="$(printf '%s\n' "$token" | ssh "${ssh_opts[@]}" "$target" "$(remote_sudo "wg-network -i $riface join - --yes --json")")" ||
        deploy_abort "join на $target не удался"
    key="$(sed -n 's/.*"public_key":"\([^"]*\)".*/\1/p' <<< "$json")"
    result="$(sed -n 's/.*"result":"\([^"]*\)".*/\1/p' <<< "$json")"
    is_wg_key "$key" || die "удалённая сторона не вернула ключ: $json"
    [[ $result == applied ]] || die "на $target конфигурация не применена (результат: ${result:-неизвестно}); резервация '$name' оставлена"

    log_info "4/4 Добавляю peer '$name' на hub"
    "${self[@]}" peer add "$name" --key "$key" --wait "$wait" "${add_args[@]}"
}
