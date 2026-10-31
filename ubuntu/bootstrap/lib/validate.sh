# shellcheck shell=bash
# Validation predicates. Everything that reaches the config or the disk passes one of these.

is_uint()    { [[ $1 =~ ^(0|[1-9][0-9]{0,9})$ ]]; }
is_port()    { is_uint "$1" && (($1 >= 1 && $1 <= 65535)); }
is_bool()    { [[ ${1,,} =~ ^(yes|no|true|false|on|off|1|0)$ ]]; }
is_username(){ [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
is_abs_path(){ [[ $1 == /* && $1 != *$'\n'* ]]; }
is_size()    { [[ ${1^^} =~ ^[1-9][0-9]{0,5}[MG]$ ]]; }
is_email()   { [[ $1 =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }
# fail2ban spans (10m, 1h) and systemd spans (2weeks, 1month).
is_duration(){ [[ $1 =~ ^[1-9][0-9]*(s|sec|m|min|h|hour|hours|d|day|days|w|week|weeks|month|months|y|year|years)?$ ]]; }
is_timezone(){ [[ $1 =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,2}$ ]] && [[ -f /usr/share/zoneinfo/$1 || ! -d /usr/share/zoneinfo ]]; }
is_ipv4()    { [[ $1 =~ ^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$ ]]; }
is_ipv6()    { [[ $1 == *:* && $1 =~ ^[0-9A-Fa-f:.]{2,45}$ && $1 != *:::* ]]; }
is_ip()      { is_ipv4 "$1" || is_ipv6 "$1"; }
is_cidr()    { [[ $1 == */* ]] && is_ip "${1%/*}" && is_uint "${1##*/}" && { is_ipv4 "${1%/*}" && ((${1##*/} <= 32)) || is_ipv6 "${1%/*}" && ((${1##*/} <= 128)); }; }
is_ip_or_cidr() { is_ip "$1" || is_cidr "$1"; }

is_hostname() {
    local label='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    [[ ${#1} -le 253 && $1 =~ ^$label(\.$label)*$ && ! $1 =~ ^[0-9.]+$ ]]
}

# PORT or PORT/tcp|udp.
is_port_spec() {
    local p=${1%/*} proto=${1#*/}
    [[ $1 == */* ]] && { [[ $proto =~ ^(tcp|udp)$ ]] || return 1; }
    is_port "$p"
}

# Public SSH key: type, base64, optional comment, single line.
is_ssh_pubkey() {
    [[ $1 =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/]+={0,3}(\ [^$'\n'$'\r']*)?$ ]]
}

# Module or profile name; it becomes a file name.
is_name() { [[ $1 =~ ^[a-z][a-z0-9-]{0,31}$ ]]; }

is_opt_name() { [[ $1 =~ ^[A-Z][A-Z0-9_]{1,47}$ ]]; }

is_git_ref() { [[ $1 =~ ^[A-Za-z0-9._/-]{1,128}$ && $1 != *..* ]]; }
is_github_repo() { [[ $1 =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; }

# yes/no/true/false/on/off/1/0 -> 1/0.
to_bool() {
    case ${1,,} in
        yes | true | on | 1) printf 1 ;;
        no | false | off | 0) printf 0 ;;
        *) return 1 ;;
    esac
}
