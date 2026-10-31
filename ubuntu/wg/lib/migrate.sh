# shellcheck shell=bash
# Migration of legacy state (a single network, files directly in /etc/wireguard/wg-network):
#   v0  the original wg-network.sh: role.env + peers.d/<name>.conf (ready config fragments)
#   v1  the first modular version: role.env + peers.d/<name>.env (IP, PUBLIC_KEY)
# Key, addresses and peers are carried over unchanged; the running tunnel is not restarted.

migrate_legacy() {
    local legacy="$WGN_ROOT/role.env" iface saved_iface=${IFACE-} archive f name ip key tmp final problems
    local -A R=()
    [[ -f $legacy ]] || return 0
    if ((OPT_DRY_RUN)); then
        log_warn 'найдено состояние прежней версии: миграция выполнится при первом запуске без --dry-run'
        return 0
    fi

    iface="$(kv_get "$WGN_CONFIG_FILE" WG_INTERFACE)"
    iface_use "${iface:-wg0}"
    st_exists && die "конфликт: есть и прежнее ($legacy), и новое ($ST_DIR) состояние — разберись вручную"
    lock_acquire
    log_info "Миграция состояния прежней версии в $ST_DIR"
    kv_load "$legacy" R
    is_wg_key "$(cat "$WG_DIR/privatekey" 2>/dev/null)" || die "миграция: не найден $WG_DIR/privatekey"

    # The new state is built aside and moved into place only when complete and valid, so a
    # failed migration leaves the legacy files untouched and can simply be retried.
    final=$ST_DIR
    make_tmp_dir tmp "$WGN_ROOT"
    st_paths "$tmp/state"
    install -d -m 700 "$ST_DIR" "$ST_PEERS" "$ST_SNAPSHOTS"
    install -m 600 "$WG_DIR/privatekey" "$ST_KEY"
    case ${R[ROLE]-} in
        hub)
            NODE=([ROLE]=hub [NAME]=hub [ADDRESS]="${R[HUB_IP]}/${R[PREFIX]}" [LISTEN_PORT]="${R[PORT]}"
                [ENDPOINT]="${R[ENDPOINT]}" [TABLE]=auto [FORWARD]=0 [CREATED_AT]="$(now_iso)")
            st_node_save
            for f in "$WGN_ROOT"/peers.d/*.conf "$WGN_ROOT"/peers.d/*.env; do
                [[ -f $f ]] || continue
                name=${f##*/}
                name=${name%.*}
                if [[ $f == *.conf ]]; then
                    ip="$(sed -n 's|^AllowedIPs = \([0-9.]*\)/32$|\1|p;T;q' "$f")"
                    key="$(sed -n 's|^PublicKey = ||p;T;q' "$f")"
                else
                    ip="$(kv_get "$f" IP)"
                    key="$(kv_get "$f" PUBLIC_KEY)"
                fi
                if is_name "$name" && is_ipv4 "$ip" && is_wg_key "$key" && ! st_peer_exists "$name"; then
                    PEER=([PUBLIC_KEY]="$key" [ADDRESS]="$ip" [ENABLED]=1 [PENDING]=0)
                    st_peer_save "$name"
                else
                    log_warn "миграция: пропущен $f (некорректные данные)"
                fi
            done
            ;;
        peer)
            NODE=([ROLE]=peer [NAME]="${R[PEER_NAME]}" [ADDRESS]="${R[PEER_IP]}/32" [TABLE]=auto [FORWARD]=0 [CREATED_AT]="$(now_iso)")
            st_node_save
            PEER=([PUBLIC_KEY]="${R[HUB_PUBLIC_KEY]}" [ENDPOINT]="${R[ENDPOINT]}" [ROUTES]="${R[HUB_IP]}/32"
                [KEEPALIVE]="${R[KEEPALIVE]:-25}" [ENABLED]=1 [PENDING]=0 [COMMENT]=hub)
            st_peer_save hub
            ;;
        *) die "миграция: неизвестная роль в $legacy" ;;
    esac
    st_node_load
    if ! problems="$(st_validate)"; then
        log_error "миграция невозможна, прежние файлы не изменены ($legacy):"
        printf '  %s\n' "$problems" >&2
        exit "$E_ERROR"
    fi
    render_conf > "$tmp/new.conf"
    mv -- "$ST_DIR" "$final"
    st_paths "$final"

    # A live config with the same meaning is adopted as ours without a restart.
    if [[ -f $LIVE_CONF ]] && cmp -s <(conf_canon "$LIVE_CONF") <(conf_canon "$tmp/new.conf"); then
        write_atomic "$LIVE_CONF" 600 < "$tmp/new.conf"
        sha256_of "$LIVE_CONF" | write_atomic "$ST_RENDERED" 600
    else
        log_warn "действующий $LIVE_CONF отличается от перенесённого состояния: проверь wg-network -i $IFACE plan --diff"
    fi

    archive="$WGN_ROOT/legacy-$(date +%Y%m%d-%H%M%S)"
    install -d -m 700 "$archive"
    for f in role.env peers.d backups .lock; do
        [[ -e $WGN_ROOT/$f ]] && mv -- "$WGN_ROOT/$f" "$archive/"
    done
    audit "migrated legacy state to $ST_DIR"
    log_ok "Миграция завершена (старые файлы: $archive)"
    lock_release
    [[ -n $saved_iface ]] && iface_use "$saved_iface"
    return 0
}
