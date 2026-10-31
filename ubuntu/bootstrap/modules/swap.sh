# shellcheck shell=bash
MOD_SUMMARY='swap-файл как страховка от OOM, swappiness для сервера'
MOD_GROUP=system
MOD_DEFAULT=1
MOD_DEPS=(preflight)
MOD_CONTAINER=0

mod_options() {
    opt SWAP_SIZE size auto 'Размер swap-файла: auto (2G при RAM ≤ 2G, иначе 4G), 0 — не создавать, или напр. 8G'
    opt SWAP_FILE path /swapfile 'Путь к swap-файлу' adv
    opt SWAP_SWAPPINESS int 10 'vm.swappiness' adv
}

swap_size_mb() {
    local s
    s="$(cfg SWAP_SIZE)"
    case $s in
        auto) ((F_MEM_MB <= 2048)) && printf 2048 || printf 4096 ;;
        0 | '') printf 0 ;;
        *) size_to_mb "$s" ;;
    esac
}

swap_file_active() {
    swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$(cfg SWAP_FILE)"
}

mod_check() {
    local want
    want="$(swap_size_mb)"
    ((want == 0)) && return 0
    ((F_SWAP_MB > 0)) || return 1
    [[ $(sysctl -n vm.swappiness 2>/dev/null) == "$(cfg SWAP_SWAPPINESS)" ]]
}

mod_apply() {
    local want file mb
    want="$(swap_size_mb)"
    file="$(cfg SWAP_FILE)"
    ((want == 0)) && { log_info 'SWAP_SIZE=0 — swap не создаётся'; return 0; }
    if ((F_SWAP_MB > 0)) && ! swap_file_active; then
        log_ok "swap уже есть (${F_SWAP_MB} MiB, не наш файл) — оставляю"
    elif ! swap_file_active; then
        [[ -e $file ]] && { log_error "$file существует, но не активен как swap — разберись вручную"; return 1; }
        case $F_ROOT_FS in
            zfs) log_warn 'ZFS: swap-файл не поддерживается, нужен zvol — пропускаю'; return 0 ;;
            btrfs) log_warn 'btrfs: swap-файл требует chattr +C и работает только на ядрах ≥ 5.0' ;;
        esac
        mb=$want
        ((${F_DISK_FREE_GB:-0} * 1024 > mb + 2048)) || { log_error "недостаточно места: свободно ${F_DISK_FREE_GB} GiB, нужно $((mb / 1024)) GiB + запас"; return 1; }
        log_info "создаю swap $file ($((mb / 1024)) GiB)"
        undo rm -f "$file"
        undo swapoff "$file"
        if ((DRY_RUN == 0)); then
            if [[ $F_ROOT_FS == btrfs ]]; then
                truncate -s 0 "$file" && chattr +C "$file" 2>/dev/null
                run dd if=/dev/zero of="$file" bs=1M count="$mb" status=none || return 1
            else
                run fallocate -l "${mb}M" "$file" || run dd if=/dev/zero of="$file" bs=1M count="$mb" status=none || return 1
            fi
            chmod 600 "$file"
        fi
        run mkswap "$file" || return 1
        run swapon "$file" || return 1
        log_ok "swap активирован: $(swapon --show --noheadings 2>/dev/null | grep "$file")"
    else
        log_ok "swap-файл $file уже активен"
    fi
    file_set_block /etc/fstab 'ubuntu-bootstrap swap' <<< "$file none swap sw 0 0"
    undo sysctl --system
    printf 'vm.swappiness = %s\nvm.vfs_cache_pressure = 50\n' "$(cfg SWAP_SWAPPINESS)" | file_write /etc/sysctl.d/92-ubuntu-bootstrap-swap.conf 644
    ((DRY_RUN)) || run sysctl -q -p /etc/sysctl.d/92-ubuntu-bootstrap-swap.conf || true
    return 0
}

mod_verify() {
    ((DRY_RUN)) && return 0
    (($(swap_size_mb) == 0)) || [[ $F_ROOT_FS == zfs ]] || [[ $(awk '/^SwapTotal/ { print $2 }' /proc/meminfo) -gt 0 ]]
}

mod_audit() {
    local total
    total="$(awk '/^SwapTotal/ { print int($2 / 1024) }' /proc/meminfo)"
    if ((total > 0)); then check_ok "swap ${total} MiB, swappiness $(sysctl -n vm.swappiness 2>/dev/null)"; else check_warn 'swap отсутствует: внезапный OOM убьёт сервис'; fi
    grep -q '^[^#].* swap ' /etc/fstab 2>/dev/null && check_ok 'swap прописан в fstab' || { ((total > 0)) && check_warn 'swap не прописан в fstab — исчезнет после перезагрузки'; }
    return 0
}
