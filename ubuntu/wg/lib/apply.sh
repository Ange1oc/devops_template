# shellcheck shell=bash
# Planning and applying changes.
#
# Commands change the desired state; a plan (live config vs. rendered candidate) is built from
# it, and only after approval is the candidate applied in one of these ways:
#   hot      only peers change: wg syncconf plus route sync, other tunnels are not interrupted
#   restart  [Interface] or a /0 route changes: the interface restarts under a rollback timer
#   start    the interface is down and gets started (init, apply --start)
#   offline  the interface was stopped by the administrator: the file is written, nothing starts
#   rewrite  the meaning is unchanged (e.g. a new header): the file is rewritten only

plan_build() {
    st_node_load
    st_require_valid
    make_tmp_dir PLAN_DIR "$ST_DIR"
    PLAN_CANDIDATE="$PLAN_DIR/candidate.conf"
    PLAN_OLD="$PLAN_DIR/old.canon"
    PLAN_NEW="$PLAN_DIR/new.canon"
    (umask 077 && render_conf > "$PLAN_CANDIDATE")
    PLAN_NAMES="$PLAN_DIR/names"
    conf_canon "$LIVE_CONF" > "$PLAN_OLD"
    conf_canon "$PLAN_CANDIDATE" > "$PLAN_NEW"
    { conf_canon "$LIVE_CONF" names; conf_canon "$PLAN_CANDIDATE" names; } | grep "^N$FS" > "$PLAN_NAMES" || true

    PLAN_RESYNC=0
    if cmp -s "$PLAN_OLD" "$PLAN_NEW"; then
        if [[ -f $LIVE_CONF ]] && ! cmp -s "$LIVE_CONF" "$PLAN_CANDIDATE"; then
            PLAN_CLASS=rewrite
        else
            PLAN_CLASS=none
        fi
        if [[ ${OPT_START:-0} == 1 ]] && ! iface_running; then
            PLAN_CLASS=start
        elif iface_running && ! runtime_matches "$PLAN_NEW"; then
            # Peers were changed behind the config's back (wg set): resync them hot.
            PLAN_CLASS=hot
            PLAN_RESYNC=1
        fi
        return 0
    fi

    if ! iface_running; then
        if [[ ${OPT_START:-0} == 1 || ! -f $LIVE_CONF ]]; then
            PLAN_CLASS=start
        else
            PLAN_CLASS=offline
        fi
    elif ! cmp -s <(grep "^I$FS" "$PLAN_OLD") <(grep "^I$FS" "$PLAN_NEW") || plan_touches_default_route; then
        PLAN_CLASS=restart
    else
        PLAN_CLASS=hot
    fi
}

plan_touches_default_route() {
    [[ ${NODE[TABLE]} == auto ]] || return 1
    cmp -s <(canon_allowed_ips "$PLAN_OLD" | grep '/0$' || true) <(canon_allowed_ips "$PLAN_NEW" | grep '/0$' || true) && return 1
    return 0
}

# Human-readable list of changes. Secrets are never printed.
plan_summary() {
    local t a b c key name
    local -A oi=() ni=() op=() np=() okeys=() nkeys=() names=()
    while IFS=$FS read -r t a b c; do
        case $t in
            I) oi[$a]=$b ;;
            P) op["$a|$b"]=$c; okeys[$a]=1 ;;
        esac
    done < "$PLAN_OLD"
    while IFS=$FS read -r t a b c; do
        case $t in
            I) ni[$a]=$b ;;
            P) np["$a|$b"]=$c; nkeys[$a]=1 ;;
        esac
    done < "$PLAN_NEW"
    while IFS=$FS read -r t a b; do
        names[$a]=$b
    done < "$PLAN_NAMES"

    for key in $(printf '%s\n' "${!oi[@]}" "${!ni[@]}" | sort -u); do
        [[ ${oi[$key]-} == "${ni[$key]-}" ]] && continue
        case $key in
            privatekey) printf '  ~ interface  PrivateKey: изменён\n' ;;
            postup | postdown) printf '  ~ interface  %s: правила маршрутизации/NAT изменены\n' "$key" ;;
            *) printf '  ~ interface  %s: %s → %s\n' "$key" "${oi[$key]:-—}" "${ni[$key]:-—}" ;;
        esac
    done
    for key in $(printf '%s\n' "${!nkeys[@]}" | sort); do
        name=${names[$key]:-${key:0:8}…}
        if [[ -z ${okeys[$key]-} ]]; then
            printf '  + peer %-20s %s\n' "$name" "${np["$key|allowedips"]-}"
            continue
        fi
        for c in allowedips endpoint persistentkeepalive presharedkey; do
            [[ ${op["$key|$c"]-} == "${np["$key|$c"]-}" ]] && continue
            if [[ $c == presharedkey ]]; then
                printf '  ~ peer %-20s PresharedKey: изменён\n' "$name"
            else
                printf '  ~ peer %-20s %s: %s → %s\n' "$name" "$c" "${op["$key|$c"]:-—}" "${np["$key|$c"]:-—}"
            fi
        done
    done
    for key in $(printf '%s\n' "${!okeys[@]}" | sort); do
        [[ -n ${nkeys[$key]-} ]] || printf '  - peer %-20s %s\n' "${names[$key]:-${key:0:8}…}" "${op["$key|allowedips"]-}"
    done
}

plan_print() {
    local how
    case $PLAN_CLASS in
        none) log_ok "$IFACE: изменений нет, конфиг соответствует состоянию"; return 0 ;;
        rewrite) how='перезапись файла без изменения смысла (интерфейс не трогается)' ;;
        hot) how='горячо: wg syncconf, остальные туннели не прерываются' ;;
        restart) how="перезапуск $IFACE: туннели интерфейса прервутся на время перезапуска (hub сразу инициирует handshake с известными peer); включается таймер отката" ;;
        start) how="запуск $IFACE" ;;
        offline) how="$IFACE остановлен: конфиг будет записан, интерфейс не запускается (apply --start — запустить)" ;;
    esac
    log_title "План для $IFACE (${NODE[ROLE]})"
    if ((${PLAN_RESYNC:-0})); then
        log_plain '  ~ ядро: peer в ядре расходятся с конфигом (изменены через wg set?) — будут синхронизированы'
    elif [[ $PLAN_CLASS != rewrite ]]; then
        plan_summary >&2
    fi
    log_plain "  Способ применения: $how"
}

# Diff of the live and the candidate config with secrets masked.
plan_diff() {
    local redact='s/^((PrivateKey|PresharedKey)[[:space:]]*=[[:space:]]*).*/\1(скрыто)/'
    diff -u --label "$LIVE_CONF (действующий)" --label "$LIVE_CONF (новый)" \
        <([[ -f $LIVE_CONF ]] && sed -E "$redact" "$LIVE_CONF") <(sed -E "$redact" "$PLAN_CANDIDATE") || true
}

# Was the live config edited by hand? Overwriting it would destroy that work.
drift_detected() {
    [[ -f $LIVE_CONF ]] || return 1
    [[ $(sha256_of "$LIVE_CONF") != "$(cat "$ST_RENDERED" 2>/dev/null)" ]]
}

drift_guard() {
    drift_detected || return 0
    # Same meaning as the candidate: nothing is lost by overwriting it.
    cmp -s "$PLAN_OLD" "$PLAN_NEW" && return 0
    if ((OPT_FORCE)); then
        install -d -m 700 "$WGN_BACKUP_ROOT"
        cp -p "$LIVE_CONF" "$WGN_BACKUP_ROOT/$IFACE.conf.manual.$(date +%Y%m%d-%H%M%S)"
        log_warn "$LIVE_CONF изменён вручную — перезаписываю (--force), копия в $WGN_BACKUP_ROOT"
        return 0
    fi
    die_code "$E_REFUSED" "$LIVE_CONF изменён вручную, ручные правки будут потеряны. Посмотри: wg-network -i $IFACE plan --diff. Перезаписать: --force (копия сохранится)"
}

live_write() {
    write_atomic "$LIVE_CONF" 600 < "$PLAN_CANDIDATE"
    sha256_of "$LIVE_CONF" | write_atomic "$ST_RENDERED" 600
}

# Status 0 when the plan may be applied.
apply_approved() {
    if ((GUARD_LEVEL >= 2)) && ! ((OPT_FORCE)); then
        guard_report
        die_code "$E_REFUSED" 'операция заблокирована предохранителем. Если уверен — повтори с --force (останется подтверждение и таймер отката)'
    fi
    guard_report
    ((OPT_NO_APPLY)) && return 1
    if ((GUARD_LEVEL >= 1)); then
        confirm_typed "$IFACE" 'Операция может затронуть доступ к серверу.' && return 0
        return 1
    fi
    ((OPT_APPLY || OPT_YES)) && return 0
    [[ $PLAN_CLASS == rewrite ]] && return 0
    [[ $PLAN_CLASS == hot && $AUTO_APPLY == hot ]] && return 0
    [[ $AUTO_APPLY == never ]] && return 1
    confirm "Применить изменения к $IFACE?"
}

# The full cycle after a state change: plan, guards, approval, apply.
apply_changes() {
    plan_build
    plan_print
    ((${OPT_SHOW_DIFF:-0})) && plan_diff >&2
    [[ $PLAN_CLASS == none ]] && return 0
    guard_check "$PLAN_OLD" "$PLAN_NEW" "$PLAN_CLASS"

    if ((OPT_DRY_RUN)); then
        guard_report
        log_info 'dry-run: ничего не изменено'
        return 0
    fi
    if ! apply_approved; then
        log_info "Изменения сохранены, но не применены. Применить: wg-network -i $IFACE apply"
        return 0
    fi
    drift_guard
    # Independent syntax check by the same parser that will bring the interface up.
    wg-quick strip "$PLAN_CANDIDATE" >/dev/null 2>&1 || die 'сгенерированный конфиг не прошёл проверку wg-quick — ничего не применено'
    if [[ $PLAN_CLASS == restart || $PLAN_CLASS == start ]] && ! wgn_home_trusted; then
        log_warn "$WGN_HOME доступен на запись не-root пользователям: таймер отката выполнит код оттуда от root"
    fi
    if [[ -z ${TX_SNAPSHOT-} ]]; then
        TX_SNAPSHOT="$(snap_create apply)"
        snap_prune
    fi

    case $PLAN_CLASS in
        rewrite)
            live_write
            sys_dropin_install
            log_ok "Конфиг $LIVE_CONF записан"
            ;;
        offline)
            live_write
            sys_dropin_install
            APPLIED=offline
            log_ok "Конфиг $LIVE_CONF записан; $IFACE остановлен и не запускался (wg-network apply --start)"
            ;;
        hot) apply_hot ;;
        restart | start) apply_restart ;;
    esac
    [[ ${APPLIED:-0} == pending || ${APPLIED:-0} == offline ]] || APPLIED=1
    audit "apply class=$PLAN_CLASS snapshot=$TX_SNAPSHOT result=$APPLIED"
}

# An unconfirmed apply. While pending.env exists no other change is allowed, and the timer
# (when armed) brings the previous config back.
pending_create() {
    local class=$1 deadman=$2 txid mech='' running=0 absent=0 enabled=0
    txid="$(date +%Y%m%d%H%M%S)$$"
    if [[ -f $LIVE_CONF ]]; then
        write_atomic "$ST_PENDING_CONF" 600 < "$LIVE_CONF"
    else
        absent=1
    fi
    if iface_running; then
        running=1
        # Peer endpoints, so that a rollback (also from the timer) reconnects at once.
        wg show "$IFACE" endpoints 2>/dev/null | write_atomic "$ST_DIR/pending.endpoints" 600 || true
    fi
    unit_enabled && enabled=1
    if ((deadman)); then
        # A change that can cut connectivity is never applied without a rollback timer.
        mech="$(deadman_arm "$txid" "$CONFIRM_TIMEOUT")" || die 'не удалось запустить таймер отката — изменения не применены'
    fi
    {
        printf 'TXID=%s\nCLASS=%s\nPREV_ABSENT=%s\nPREV_RUNNING=%s\nPREV_ENABLED=%s\n' "$txid" "$class" "$absent" "$running" "$enabled"
        printf 'DEADLINE=%s\nBOOT_ID=%s\nCREATED_AT=%s\nSNAPSHOT=%s\n' "$(($(now_epoch) + CONFIRM_TIMEOUT))" "$(boot_id)" "$(now_iso)" "${TX_SNAPSHOT-}"
        if [[ -n $mech ]]; then printf '%s\n' "$mech"; fi
    } | write_atomic "$ST_PENDING" 600
    PENDING_TXID=$txid
    PENDING_OWNED=1
    [[ " ${EXIT_HOOKS[*]} " == *' pending_exit_hook '* ]] || EXIT_HOOKS+=(pending_exit_hook)
}

# The applying process died (error, Ctrl+C, SSH dropped while waiting for confirmation): bring
# the previous config back at once instead of waiting for the timer.
pending_exit_hook() {
    local rc=$1
    ((${PENDING_OWNED:-0})) || return 0
    PENDING_OWNED=0
    ((rc == 0)) && return 0
    [[ -f $ST_PENDING && $(kv_get "$ST_PENDING" TXID) == "$PENDING_TXID" ]] || return 0
    lock_acquire
    log_warn 'применение прервано — возвращаю предыдущую конфигурацию'
    rollback_pending manual || true
}

pending_clear() {
    rm -f -- "$ST_PENDING" "$ST_PENDING_CONF" "$ST_DIR/pending.endpoints"
    PENDING_OWNED=0
}

sort_csv() {
    tr -s ', ' '\n' <<< "$1" | sed '/^$/d' | LC_ALL=C sort | paste -sd, -
}

# Peers a canonical config expects in the kernel: "key|allowed-ips|psk|keepalive".
canon_runtime_view() {
    local t pk k v key
    local -A keys=() allowed=() psk=() ka=()
    while IFS=$FS read -r t pk k v; do
        [[ $t == P ]] || continue
        keys[$pk]=1
        case $k in
            allowedips) allowed[$pk]=$v ;;
            presharedkey) psk[$pk]=$v ;;
            persistentkeepalive) [[ $v == 0 || $v == off ]] || ka[$pk]=$v ;;
        esac
    done < "$1"
    for key in "${!keys[@]}"; do
        printf '%s|%s|%s|%s\n' "$key" "$(sort_csv "${allowed[$key]-}")" "${psk[$key]-}" "${ka[$key]-}"
    done | LC_ALL=C sort
}

# The same from the kernel (wg show dump).
kernel_runtime_view() {
    local pk psk ep ips hs rx tx ka
    { wg show "$IFACE" dump 2>/dev/null || true; } | tail -n +2 | while IFS=$'\t' read -r pk psk ep ips hs rx tx ka; do
        [[ $ips == '(none)' ]] && ips=''
        [[ $psk == '(none)' ]] && psk=''
        [[ $ka == off ]] && ka=''
        printf '%s|%s|%s|%s\n' "$pk" "$(sort_csv "$ips")" "$psk" "$ka"
    done | LC_ALL=C sort
}

# Does the kernel match the canonical config (keys, AllowedIPs, PSK, keepalive)?
runtime_matches() {
    [[ "$(canon_runtime_view "${1:-$PLAN_NEW}")" == "$(kernel_runtime_view)" ]]
}

apply_hot() {
    local deadman=0 pk ep
    local -A before=()
    ((GUARD_LEVEL >= 1 && CONFIRM_TIMEOUT > 0)) && deadman=1
    endpoints_cache_update
    while read -r pk; do before[$pk]=1; done < <(wg show "$IFACE" peers 2>/dev/null || true)
    pending_create hot "$deadman"
    live_write
    if ! sys_syncconf || ! sys_sync_routes "$PLAN_OLD" "$PLAN_NEW" || ! runtime_matches; then
        log_error 'горячее применение не удалось — возвращаю предыдущий конфиг'
        rollback_or_die
    fi
    # Returning peers (enable, restored removal): handshake with the last known endpoint.
    while read -r pk ep; do
        [[ -z ${before[$pk]-} ]] && printf '%s\t%s\n' "$pk" "$ep"
    done < "$ST_DIR/endpoints.cache" > "$PLAN_DIR/returning" 2>/dev/null || true
    sys_kick_handshakes "$PLAN_DIR/returning" "$PLAN_NEW"
    log_ok "Применено горячо: $IFACE"
    if ((deadman)); then
        deadman_wait
    else
        pending_clear
    fi
}

apply_restart() {
    local deadman=0
    ((CONFIRM_TIMEOUT > 0)) && deadman=1
    pending_create "$PLAN_CLASS" "$deadman"
    cp -p "$ST_DIR/pending.endpoints" "$PLAN_DIR/endpoints" 2>/dev/null || true
    local ok=1
    # Stop with the OLD config so that its PostDown removes the old firewall rules. A restart
    # after writing the new file would run the new PostDown and leak the old FORWARD/MASQUERADE
    # rules forever.
    if iface_running; then
        sys_iface_stop || ok=0
    fi
    if ((ok)); then
        live_write
        sys_dropin_install
        sys_iface_start || ok=0
    fi
    if ((ok)) && ! apply_postcheck; then
        ok=0
    fi
    if ! ((ok)); then
        log_error "интерфейс $IFACE не поднялся с новым конфигом — откатываю"
        rollback_or_die "подробности: journalctl -u $UNIT -n 50"
    fi
    sys_kick_handshakes "$PLAN_DIR/endpoints" "$PLAN_NEW"
    log_ok "Применено: $IFACE перезапущен"
    if ((deadman)); then
        deadman_wait
    else
        pending_clear
    fi
}

apply_postcheck() {
    local addr port
    iface_running || { log_error "интерфейс $IFACE отсутствует"; return 1; }
    for addr in "${NODE[ADDRESS]%/*}" "${NODE[ADDRESS6]%/*}"; do
        [[ -n $addr ]] || continue
        grep -qxF -- "$addr" <<< "$(iface_addresses "$IFACE")" || { log_error "на $IFACE нет адреса $addr"; return 1; }
    done
    if [[ -n ${NODE[LISTEN_PORT]-} ]]; then
        port="$(wg show "$IFACE" listen-port 2>/dev/null)"
        [[ $port == "${NODE[LISTEN_PORT]}" ]] || { log_error "$IFACE слушает порт '$port' вместо ${NODE[LISTEN_PORT]}"; return 1; }
    fi
    runtime_matches || { log_error 'peer в ядре не совпадают с конфигом'; return 1; }
}

# Wait for confirmation. Only someone who still has access after the change can confirm: if
# SSH drops, this process dies and the timer rolls back.
deadman_wait() {
    local deadline remaining answer txid=$PENDING_TXID confirmed=0
    deadline="$(kv_get "$ST_PENDING" DEADLINE)"
    lock_release

    if ((OPT_YES && !OPT_WAIT_CONFIRM && GUARD_LEVEL == 0)); then
        log_info 'подтверждено автоматически (--yes): проверки после применения пройдены'
        confirmed=1
    elif [[ -t 0 ]] && ! ((OPT_WAIT_CONFIRM)); then
        log_title "Проверь доступ к серверу (например, новым SSH-подключением)."
        log_plain "Без подтверждения через ${CONFIRM_TIMEOUT}s конфигурация будет откачена автоматически."
        log_plain "Подтвердить можно и из другой сессии: wg-network -i $IFACE confirm"
        while :; do
            remaining=$((deadline - $(now_epoch)))
            ((remaining > 0)) || break
            [[ $(kv_get "$ST_PENDING" TXID) == "$txid" ]] || break
            answer=''
            if read -r -t "$((remaining < 5 ? remaining : 5))" -p "Оставить новую конфигурацию? Введи 'yes' (осталось ${remaining}s): " answer; then
                [[ $answer == yes ]] && { confirmed=1; break; }
            else
                # Status > 128 is the poll timeout; otherwise stdin is closed (session gone).
                (($? > 128)) || break
                echo >&2
            fi
        done
    else
        ((OPT_YES && GUARD_LEVEL >= 1)) &&
            log_warn 'изменение затрагивает SSH-доступ: --yes не подтверждает его автоматически'
        log_warn "Конфигурация применена и ждёт подтверждения до $(date -d "@$deadline" +%T)."
        log_plain "  Подтвердить (лучше из НОВОГО подключения): wg-network -i $IFACE confirm   — иначе автоматический откат"
        PENDING_OWNED=0
        APPLIED=pending
        return 0
    fi

    lock_acquire
    if [[ $(kv_get "$ST_PENDING" TXID) != "$txid" ]]; then
        case "$(kv_get "$ST_DIR/last-tx.env" "$txid")" in
            confirmed) log_ok 'конфигурация подтверждена из другой сессии'; return 0 ;;
            rolled-back) die_code "$E_ROLLED_BACK" 'время подтверждения истекло — выполнен откат' ;;
            *) die_code "$E_BUSY" 'состояние подтверждения изменилось другим процессом' ;;
        esac
    fi
    if ((confirmed)); then
        pending_confirm
    else
        log_warn 'новая конфигурация не подтверждена'
        rollback_or_die
    fi
}

# Roll back a failed or unconfirmed apply and exit with the honest outcome.
rollback_or_die() {
    if rollback_pending manual; then
        die_code "$E_ROLLED_BACK" "изменения не применены, прежняя конфигурация восстановлена${1:+ ($1)}"
    fi
    die_code "$E_ERROR" "изменения не применены, и прежнюю конфигурацию восстановить не удалось — нужна ручная проверка (wg-network doctor${1:+; $1})"
}

# Outcome of unconfirmed applies, so a waiting process learns what happened without it.
tx_outcome() {
    printf '%s=%s\n' "$1" "$2" >> "$ST_DIR/last-tx.env"
    tail -n 20 "$ST_DIR/last-tx.env" | write_atomic "$ST_DIR/last-tx.env" 600
}

pending_confirm() {
    deadman_disarm
    tx_outcome "$(kv_get "$ST_PENDING" TXID)" confirmed
    pending_clear
    audit 'confirmed'
    log_ok "Конфигурация $IFACE подтверждена"
}

# Bring back the live config from before an unconfirmed apply.
# mode: manual (now), auto (timer), boot (ExecStartPre at boot: files only).
# Status 0 means the previous configuration is really running again.
rollback_pending() {
    local mode=$1 want_txid=${2-} class absent running enabled ok=1 tmp
    local -A P=()
    if [[ ! -f $ST_PENDING ]]; then
        [[ $mode == boot || $mode == auto ]] && return 0
        die 'нет неподтверждённой конфигурации'
    fi
    kv_load "$ST_PENDING" P
    [[ $mode == auto && -n $want_txid && ${P[TXID]} != "$want_txid" ]] && return 0
    [[ $mode == boot && ${P[BOOT_ID]} == "$(boot_id)" ]] && return 0

    class=${P[CLASS]}
    absent=${P[PREV_ABSENT]:-0}
    running=${P[PREV_RUNNING]:-0}
    enabled=${P[PREV_ENABLED]:-1}
    make_tmp_dir tmp "$ST_DIR"
    conf_canon "$LIVE_CONF" > "$tmp/failed.canon"

    if [[ $mode == boot ]]; then
        # The unit starts by itself after ExecStartPre: restoring the file is enough.
        if ((absent)); then
            rm -f -- "$LIVE_CONF" "$ST_RENDERED"
        else
            rollback_restore_file
        fi
    elif [[ $class == hot ]] && ((!absent)) && iface_running; then
        rollback_restore_file
        conf_canon "$LIVE_CONF" > "$tmp/prev.canon"
        sys_syncconf || ok=0
        sys_sync_routes "$tmp/failed.canon" "$tmp/prev.canon" || ok=0
        runtime_matches "$tmp/prev.canon" || ok=0
    else
        # Stop with the current (failed) config so that its PostDown removes its own rules.
        if iface_running; then
            sys_iface_stop || ok=0
        fi
        if ((absent)); then
            sys_iface_disable
            rm -f -- "$LIVE_CONF" "$ST_RENDERED"
            iface_running && ok=0
        else
            rollback_restore_file
            conf_canon "$LIVE_CONF" > "$tmp/prev.canon"
            if ((running)); then
                if sys_iface_start && iface_running && runtime_matches "$tmp/prev.canon"; then
                    sys_kick_handshakes "$ST_DIR/pending.endpoints" "$tmp/prev.canon"
                else
                    ok=0
                fi
            fi
            if ((!enabled)) && has_systemd; then
                systemctl disable --quiet "$UNIT" 2>/dev/null || true
            fi
        fi
    fi

    [[ $mode == auto ]] || deadman_disarm
    tx_outcome "${P[TXID]}" rolled-back
    rollback_state "${P[SNAPSHOT]-}"
    pending_clear
    if ((ok)); then
        audit "rollback mode=$mode class=$class txid=${P[TXID]}"
        log_warn "$IFACE: возвращена предыдущая конфигурация ($mode)"
        return 0
    fi
    audit "rollback-failed mode=$mode class=$class txid=${P[TXID]}"
    log_error "$IFACE: прежний конфиг записан, но интерфейс с ним не работает — проверь: wg-network doctor, journalctl -u $UNIT"
    return 1
}

# An unconfirmed or failed change is undone completely: the desired state returns to the
# snapshot taken before it, so a later unrelated command cannot re-apply it unnoticed. The
# rejected state is kept as a snapshot for "wg-network rollback ID". A snapshot without state
# (a first init) is never restored: that would delete the key.
rollback_state() {
    local snap=$1 tmp item rejected differs=0
    [[ -n $snap && -f $ST_SNAPSHOTS/$snap.tar ]] || return 0
    tmp="$(mktemp -d "$ST_DIR/.cmp.XXXXXX")" || return 0
    if tar -C "$tmp" -xf "$ST_SNAPSHOTS/$snap.tar" 2>/dev/null && [[ $(kv_get "$tmp/meta.env" HAD_STATE) == 1 ]]; then
        for item in node.env private.key peers.d; do
            diff -rq -- "$tmp/$item" "$ST_DIR/$item" >/dev/null 2>&1 || differs=1
        done
    fi
    rm -rf -- "$tmp"
    ((differs)) || return 0
    rejected="$(snap_create rejected 2>/dev/null)" || rejected=''
    if (snap_restore_state "$snap"); then
        log_warn "желаемое состояние возвращено к снимку $snap${rejected:+; повторить отклонённое изменение: wg-network -i $IFACE rollback $rejected}"
        audit "state-restored snapshot=$snap rejected=${rejected:-none}"
    else
        log_error "желаемое состояние не удалось вернуть из снимка $snap: wg-network -i $IFACE plan покажет расхождение"
    fi
}

rollback_restore_file() {
    write_atomic "$LIVE_CONF" 600 < "$ST_PENDING_CONF"
    sha256_of "$LIVE_CONF" | write_atomic "$ST_RENDERED" 600
}
