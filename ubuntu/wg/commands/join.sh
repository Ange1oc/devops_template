# shellcheck shell=bash

CMD_SUMMARY='подключить сервер к hub по токену из invite'
CMD_GROUP=setup
CMD_MUTATES=1

cmd_usage() {
    cat <<'EOF'
Использование: wg-network [-i IFACE] join [TOKEN | - | --token-file FILE] [--json] [--force]

Без аргумента токен запрашивается (ввод скрыт) или читается из stdin, если он не терминал:
  sudo wg-network join                         вставить токен по запросу
  printf '%s\n' "$TOKEN" | sudo wg-network join -
Токен в командной строке виден другим пользователям сервера через ps — так тоже можно,
но не рекомендуется. Токен содержит preshared key: это секрет.

  --json   итог в stdout в JSON (public_key, approve_command) — для автоматизации

После join выполни на hub напечатанную команду peer add (или используй wg-network deploy).
EOF
}

cmd_run() {
    local arg='' file='' json=0 token
    local -A T=() INIT=()
    while (($#)); do
        case $1 in
            --force) OPT_FORCE=1; shift ;;
            --json) json=1; shift ;;
            --token-file) require_arg "$@"; file=$2; shift 2 ;;
            - | wgn1.*) arg=$1; shift ;;
            *) die_unknown_arg "$1" ;;
        esac
    done
    token="$(read_token "$arg" "$file")"
    token_decode "$token" T

    if st_exists && ! ((OPT_FORCE)); then
        die_code "$E_REFUSED" "$IFACE уже управляется wg-network. Переинициализировать: --force"
    fi
    INIT=([NAME]="${T[NAME]-}" [ADDRESS]="${T[ADDRESS]-}" [ADDRESS6]="${T[ADDRESS6]-}" [HUB_KEY]="${T[HUB_KEY]-}"
        [HUB_ENDPOINT]="${T[HUB_ENDPOINT]-}" [ROUTES]="${T[ROUTES]-}" [PSK]="${T[PSK]-}"
        [KEEPALIVE]="${T[KEEPALIVE]:-$DEFAULT_KEEPALIVE}" [MTU]="${T[MTU]-}" [TABLE]=auto [FORCE]=$OPT_FORCE)

    node_init_peer INIT
    # The key printed for peer add would belong to the sandbox, not to this server.
    ((OPT_DRY_RUN)) && return 0
    audit "join name=${INIT[NAME]} address=${INIT[ADDRESS]} hub=${INIT[HUB_ENDPOINT]} result=$(apply_outcome)"
    log_ok "Узел ${INIT[NAME]} (${INIT[ADDRESS]}): $(outcome_text)"
    print_hub_approval "${INIT[NAME]}" "${INIT[ADDRESS]}" 0 "$json"
    ((json)) || log_plain "Связь установится в течение ~5 с после peer add на hub. Проверка: wg-network status"
}
