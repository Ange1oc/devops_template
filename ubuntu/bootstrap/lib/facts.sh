# shellcheck shell=bash
# System facts (F_*), collected once and read-only. Modules never probe the system directly.

facts_load() {
    local line
    F_OS_ID='' F_OS_VERSION='' F_OS_CODENAME='' F_PRETTY=''
    if [[ -r ${UBB_OS_RELEASE:-/etc/os-release} ]]; then
        while IFS= read -r line; do
            case $line in
                ID=*) F_OS_ID=${line#ID=} ;;
                VERSION_ID=*) F_OS_VERSION=${line#VERSION_ID=} ;;
                VERSION_CODENAME=*) F_OS_CODENAME=${line#VERSION_CODENAME=} ;;
                PRETTY_NAME=*) F_PRETTY=${line#PRETTY_NAME=} ;;
            esac
        done < "${UBB_OS_RELEASE:-/etc/os-release}"
        F_OS_ID=${F_OS_ID//\"/} F_OS_VERSION=${F_OS_VERSION//\"/} F_OS_CODENAME=${F_OS_CODENAME//\"/} F_PRETTY=${F_PRETTY//\"/}
    fi
    F_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    F_KERNEL="$(uname -r)"
    F_HAS_SYSTEMD=0
    [[ -d /run/systemd/system ]] && has_cmd systemctl && F_HAS_SYSTEMD=1
    F_VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
    F_CONTAINER=0
    if systemd-detect-virt -c -q 2>/dev/null || [[ -f /.dockerenv || -f /run/.containerenv ]]; then
        F_CONTAINER=1
    fi
    F_MEM_MB="$(awk '/^MemTotal/ { print int($2 / 1024) }' /proc/meminfo)"
    F_SWAP_MB="$(awk '/^SwapTotal/ { print int($2 / 1024) }' /proc/meminfo)"
    F_CPUS="$(nproc 2>/dev/null || echo 1)"
    F_DISK_FREE_GB="$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')"
    F_ROOT_FS="$(findmnt -n -o FSTYPE / 2>/dev/null || echo unknown)"
    F_DEFAULT_IFACE="$(ip -4 route show default 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
    F_PRIMARY_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }')"
    F_HOSTNAME="$(hostname 2>/dev/null || echo localhost)"
    F_REBOOT_REQUIRED=0
    [[ -f /var/run/reboot-required ]] && F_REBOOT_REQUIRED=1
    facts_ssh
}

# Current SSH session and sshd ports. sudo drops SSH_CONNECTION (env_reset), so the client address
# falls back to the utmp record of the terminal (who -m).
facts_ssh() {
    local host
    F_SSH_CLIENT_IP='' F_SSH_SERVER_PORT='' F_SSH_USER=${SUDO_USER:-${USER:-root}}
    if [[ -n ${SSH_CONNECTION-} ]]; then
        read -r F_SSH_CLIENT_IP _ _ F_SSH_SERVER_PORT <<< "$SSH_CONNECTION"
    else
        host="$(who -m 2>/dev/null | sed -n 's/.*(\(.*\))$/\1/p')"
        is_ip "${host#::ffff:}" && F_SSH_CLIENT_IP=$host
    fi
    F_SSH_CLIENT_IP=${F_SSH_CLIENT_IP#::ffff:}
    F_SSHD_PORTS="$(sshd_effective_ports)"
}

# sshd -T needs /run/sshd, which socket-activated sshd creates only on the first connection.
sshd_ready() {
    [[ -d /run/sshd ]] || { is_root && install -d -m 755 /run/sshd 2>/dev/null; } || true
}

sshd_effective_ports() {
    local ports
    sshd_ready
    ports="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -un | tr '\n' ' ')"
    ports=${ports% }
    printf '%s' "${ports:-22}"
}

sshd_effective() {
    sshd_ready
    sshd -T 2>/dev/null | awk -v k="${1,,}" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' | sed 's/^without-password$/prohibit-password/'
}

pkg_installed() {
    [[ $(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) == installed ]]
}

port_listening() {
    local proto=${2:-tcp} flag=-lnt
    [[ $proto == udp ]] && flag=-lnu
    [[ -n $(ss -H "$flag" "sport = :$1" 2>/dev/null) ]]
}

listening_summary() {
    ss -Hlntup 2>/dev/null | awk '{
        split($5, a, ":"); port = a[length(a)]
        proc = ""; if (match($0, /users:\(\("[^"]+"/)) { proc = substr($0, RSTART + 9, RLENGTH - 10) }
        key = $1 "/" port
        if (!(key in seen)) { seen[key] = 1; printf "  %-5s %-6s %s\n", $1, port, proc }
    }' | sort -k2 -n
}

# In dry-run, modules record what they would create (plan_mark user:deploy) so that guards of
# later modules see the future state.
declare -gA PLANNED=()
plan_mark() { ((DRY_RUN)) && PLANNED[$1]=1; return 0; }

# Users with UID >= 1000 and a login shell, plus planned ones.
human_users() {
    local k
    awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ { print $1 }' /etc/passwd
    for k in "${!PLANNED[@]}"; do [[ $k == user:* ]] && printf '%s\n' "${k#user:}"; done
    return 0
}

user_home() {
    getent passwd "$1" | cut -d: -f6
}

user_exists() {
    [[ -n ${PLANNED[user:$1]-} ]] || getent passwd "$1" >/dev/null 2>&1
}

user_has_keys() {
    local home
    [[ -n ${PLANNED[keys:$1]-} ]] && return 0
    home="$(user_home "$1")"
    [[ -n $home && -s $home/.ssh/authorized_keys ]] && grep -qE '^(ssh-|ecdsa-|sk-)' "$home/.ssh/authorized_keys" 2>/dev/null
}

user_in_group() {
    id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"
}

# passwd -S field 2: P = password set, L = locked, NP = no password.
user_password_state() {
    passwd -S "$1" 2>/dev/null | awk '{ print $2 }'
}

# sudo actually works: group sudo plus either a password or NOPASSWD in sudoers.
user_sudo_usable() {
    local u=$1
    [[ -n ${PLANNED[sudo:$u]-} ]] && return 0
    user_in_group "$u" sudo || return 1
    [[ $(user_password_state "$u") == P ]] && return 0
    sudo -l -U "$u" 2>/dev/null | grep -q NOPASSWD
}

ufw_active() { has_cmd ufw && ufw status 2>/dev/null | grep -q '^Status: active'; }

sshd_socket_activated() {
    ((F_HAS_SYSTEMD)) || return 1
    [[ $(systemctl is-enabled ssh.socket 2>/dev/null) == enabled ]] || systemctl is-active --quiet ssh.socket 2>/dev/null
}

public_ip() {
    [[ -n ${F_PUBLIC_IP-} ]] && { printf '%s' "$F_PUBLIC_IP"; return; }
    F_PUBLIC_IP="$(curl -fsS --max-time 5 --proto '=https' https://api.ipify.org 2>/dev/null || true)"
    is_ipv4 "$F_PUBLIC_IP" || F_PUBLIC_IP=$F_PRIMARY_IP
    printf '%s' "$F_PUBLIC_IP"
}

facts_summary() {
    log_plain "  ОС:          ${F_PRETTY:-?} (${F_ARCH}, ядро ${F_KERNEL})"
    log_plain "  Виртуализация: ${F_VIRT}$( ((F_CONTAINER)) && printf ' (контейнер)')"
    log_plain "  CPU/RAM/Swap: ${F_CPUS} / ${F_MEM_MB} MiB / ${F_SWAP_MB} MiB; свободно на /: ${F_DISK_FREE_GB:-?} GiB (${F_ROOT_FS})"
    log_plain "  Сеть:        ${F_DEFAULT_IFACE:-?} ${F_PRIMARY_IP:-?}; hostname ${F_HOSTNAME}"
    if [[ -n $F_SSH_CLIENT_IP ]]; then
        log_plain "  SSH-сессия:  ${F_SSH_USER} с ${F_SSH_CLIENT_IP} -> порт ${F_SSH_SERVER_PORT}; sshd слушает: ${F_SSHD_PORTS}"
    else
        log_plain "  SSH-сессия:  не обнаружена (локальная консоль); sshd слушает: ${F_SSHD_PORTS}"
    fi
    ((F_REBOOT_REQUIRED)) && log_plain '  Требуется перезагрузка (/var/run/reboot-required)'
    return 0
}
