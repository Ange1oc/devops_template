# shellcheck shell=bash
# Input validation predicates. They return 0/1; callers produce the error message.
# Everything that reaches a config file or a file name passes one of these checks.

is_uint() {
    [[ $1 =~ ^(0|[1-9][0-9]{0,9})$ ]]
}

is_port() {
    is_uint "$1" && (($1 >= 1 && $1 <= 65535))
}

is_keepalive() {
    is_uint "$1" && (($1 <= 65535))
}

# 1280 is the IPv6 minimum link MTU; tunnel traffic may be IPv6.
is_mtu() {
    is_uint "$1" && (($1 >= 1280 && $1 <= 9000))
}

# Peer and node names become file names: no "/" and no leading dot.
is_name() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]]
}

# Same rules as wg-quick.
is_iface() {
    [[ $1 =~ ^[A-Za-z0-9_=+.-]{1,15}$ ]]
}

# Exactly 32 bytes in base64 (the last character before "=" is restricted).
is_wg_key() {
    [[ $1 =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=$ ]]
}

is_hostname() {
    local label='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    [[ ${#1} -le 253 && $1 =~ ^$label(\.$label)*$ && ! $1 =~ ^[0-9.]+$ ]]
}

# HOST:PORT where HOST is IPv4, a hostname or [IPv6].
is_endpoint() {
    local host port
    endpoint_split "$1" host port || return 1
    is_port "$port" || return 1
    is_ip "$host" || is_hostname "$host"
}

# endpoint_split ENDPOINT HOSTVAR PORTVAR (IPv6 brackets are removed).
endpoint_split() {
    local -n _es_host=$2 _es_port=$3
    if [[ $1 =~ ^\[([0-9A-Fa-f:]+)\]:([0-9]+)$ ]]; then
        _es_host=${BASH_REMATCH[1]}
        _es_port=${BASH_REMATCH[2]}
        is_ipv6 "$_es_host"
    elif [[ $1 =~ ^([^:]+):([0-9]+)$ ]]; then
        _es_host=${BASH_REMATCH[1]}
        _es_port=${BASH_REMATCH[2]}
    else
        return 1
    fi
}

endpoint_is_literal() {
    local host port
    endpoint_split "$1" host port && is_ip "$host"
}

# wg-quick Table=. 253..255 are the system tables (default, main, local).
is_table() {
    [[ $1 == auto || $1 == off ]] && return 0
    is_uint "$1" && (($1 >= 1 && $1 <= 4294967295)) && (($1 < 253 || $1 > 255))
}

# Printable text without characters that need escaping in JSON or shell.
is_comment() {
    ((${#1} <= 64)) && [[ $1 != *[[:cntrl:]\"\\\`\$]* ]]
}

is_bool() {
    [[ $1 == 0 || $1 == 1 ]]
}

# parse_bool VALUE VAR: on/off/yes/no/true/false/1/0 -> 1/0.
parse_bool() {
    local -n _pb_out=$2
    case ${1,,} in
        on | yes | true | 1) _pb_out=1 ;;
        off | no | false | 0) _pb_out=0 ;;
        *) return 1 ;;
    esac
}

# Hub interface address: IP/LEN where IP is a usable host address.
is_iface_cidr4() {
    is_cidr "$1" && is_ipv4 "${1%/*}" && ((${1##*/} >= 8 && ${1##*/} <= 30)) && ip4_is_host_in "$1" "${1%/*}"
}

is_iface_cidr6() {
    is_cidr "$1" && is_ipv6 "${1%/*}" && ((${1##*/} >= 48 && ${1##*/} <= 96))
}

# A route must be a network address: 10.0.0.5/24 is almost always a typo.
check_route() {
    local net
    is_cidr "$1" || die_usage "некорректный CIDR: $1"
    cidr_network "$1" net
    [[ $net == "$(cidr_normalize_text "$1")" ]] || die_usage "$1 — не адрес сети. Имелось в виду $net?"
}
