# shellcheck shell=bash
MOD_SUMMARY='установить wg-network (WireGuard hub/peer из этого репозитория); сеть настраивается им отдельно'
MOD_GROUP=services
MOD_DEPS=(preflight base)

mod_options() {
    opt WG_REPO string '' 'Репозиторий owner/repo (пусто — тот же, из которого установлен ubuntu-bootstrap)' adv
    opt WG_REF string '' 'Ветка/тег/commit (пусто — тот же ref)' adv
}

wg_repo() { local r; r="$(cfg WG_REPO)"; [[ -z $r ]] && r="$(install_meta REPO)"; printf '%s' "${r:-Ange1oc/devops_template}"; }
wg_ref()  { local r; r="$(cfg WG_REF)";  [[ -z $r ]] && r="$(install_meta REF)";  printf '%s' "${r:-main}"; }

mod_check() { [[ -x /opt/wg-network/wg-network ]]; }

mod_apply() {
    local repo ref tmp
    repo="$(wg_repo)" ref="$(wg_ref)"
    is_github_repo "$repo" || { log_error "некорректный WG_REPO: $repo"; return 1; }
    is_git_ref "$ref" || { log_error "некорректный WG_REF: $ref"; return 1; }
    if mod_check; then
        log_ok "wg-network уже установлен: $(/opt/wg-network/wg-network --version 2>/dev/null | head -1)"
        return 0
    fi
    ((DRY_RUN)) && { log_plain "[dry-run] скачать и выполнить $repo@$ref:ubuntu/wg/install.sh"; return 0; }
    tmp="$(make_tmp_dir)"
    # The wg-network installer fetches its archive over TLS, checks syntax and installs atomically.
    fetch_url "https://raw.githubusercontent.com/$repo/$ref/ubuntu/wg/install.sh" "$tmp/install.sh" || { log_error 'не удалось скачать ubuntu/wg/install.sh'; return 1; }
    bash -n "$tmp/install.sh" || { log_error 'install.sh wg-network: синтаксическая ошибка'; return 1; }
    undo /opt/wg-network/install.sh --uninstall
    run bash "$tmp/install.sh" --repo "$repo" --ref "$ref" || return 1
    log_ok "wg-network установлен; дальше: sudo wg-network help (init-hub / init-peer)"
    return 0
}

mod_verify() { ((DRY_RUN)) || mod_check; }

mod_audit() {
    mod_check || { check_info 'wg-network не установлен'; return 0; }
    check_ok "wg-network $(/opt/wg-network/wg-network --version 2>/dev/null | head -1 | awk '{ print $2 }')"
    [[ -f /etc/wireguard/wg-network/role.env || -d /etc/wireguard/wg-network ]] && check_info 'узел WireGuard настроен: sudo wg-network doctor' || check_info 'сеть ещё не инициализирована'
}
