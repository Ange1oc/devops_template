# shellcheck shell=bash
# IPv4/IPv6 arithmetic without external tools.
#
# Addresses of both families are converted to fixed-width hex strings (8 digits for IPv4,
# 32 for IPv6), so prefix comparison, containment and overlap share one implementation.
#
# Functions that return through a nameref use locals with a unique prefix: bash scoping is
# dynamic, and a local named like the caller's variable would capture the result.

# No leading zeros: "010" is octal in bash arithmetic.
is_ipv4() {
    local o='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    [[ $1 =~ ^$o\.$o\.$o\.$o$ ]]
}

# ip6_expand ADDR VAR: 32 hex digits, status 1 for an invalid address.
# Embedded IPv4 (::ffff:1.2.3.4) and zone ids (%eth0) are deliberately rejected.
ip6_expand() {
    local _x6_a=${1,,} _x6_head _x6_tail _x6_g _x6_out='' _x6_compress=0
    local -a _x6_H=() _x6_T=()
    local -n _x6_res=$2

    [[ $_x6_a =~ ^[0-9a-f:]{2,39}$ && $_x6_a != *:::* && $_x6_a != *::*::* ]] || return 1
    if [[ $_x6_a == *::* ]]; then
        _x6_compress=1
        _x6_head=${_x6_a%%::*}
        _x6_tail=${_x6_a#*::}
    else
        _x6_head=$_x6_a
        _x6_tail=''
    fi
    [[ $_x6_head != :* && $_x6_head != *: && $_x6_tail != :* && $_x6_tail != *: ]] || return 1
    [[ -n $_x6_head ]] && IFS=: read -ra _x6_H <<< "$_x6_head"
    [[ -n $_x6_tail ]] && IFS=: read -ra _x6_T <<< "$_x6_tail"

    if ((_x6_compress)); then
        ((${#_x6_H[@]} + ${#_x6_T[@]} <= 7)) || return 1
    else
        ((${#_x6_H[@]} == 8)) || return 1
    fi
    for _x6_g in "${_x6_H[@]}" "${_x6_T[@]}"; do
        [[ $_x6_g =~ ^[0-9a-f]{1,4}$ ]] || return 1
    done

    for _x6_g in "${_x6_H[@]}"; do
        printf -v _x6_g '%04x' "0x$_x6_g"
        _x6_out+=$_x6_g
    done
    for ((_x6_g = ${#_x6_H[@]} + ${#_x6_T[@]}; _x6_g < 8; _x6_g++)); do
        _x6_out+="0000"
    done
    for _x6_g in "${_x6_T[@]}"; do
        printf -v _x6_g '%04x' "0x$_x6_g"
        _x6_out+=$_x6_g
    done
    _x6_res=$_x6_out
}

is_ipv6() {
    local _iv6
    ip6_expand "$1" _iv6
}

is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}

ip_family() {
    if [[ $1 == *:* ]]; then echo 6; else echo 4; fi
}

# ip6_compress HEX VAR: RFC 5952 text form, the longest run of zero groups becomes "::".
ip6_compress() {
    local _c6_hex=$1 _c6_i _c6_best=-1 _c6_blen=0 _c6_run=-1 _c6_rlen=0 _c6_out=''
    local -a _c6_g=()
    local -n _c6_res=$2

    for ((_c6_i = 0; _c6_i < 8; _c6_i++)); do
        printf -v '_c6_g[_c6_i]' '%x' "0x${_c6_hex:_c6_i*4:4}"
    done
    for ((_c6_i = 0; _c6_i < 8; _c6_i++)); do
        if [[ ${_c6_g[_c6_i]} == 0 ]]; then
            ((_c6_run < 0)) && _c6_run=$_c6_i _c6_rlen=0
            _c6_rlen=$((_c6_rlen + 1))
            ((_c6_rlen > _c6_blen)) && _c6_best=$_c6_run _c6_blen=$_c6_rlen
        else
            _c6_run=-1
        fi
    done
    ((_c6_blen < 2)) && _c6_best=-1

    for ((_c6_i = 0; _c6_i < 8; _c6_i++)); do
        if ((_c6_i == _c6_best)); then
            _c6_out+='::'
            _c6_i=$((_c6_i + _c6_blen - 1))
            continue
        fi
        [[ -n $_c6_out && $_c6_out != *:: ]] && _c6_out+=':'
        _c6_out+=${_c6_g[_c6_i]}
    done
    _c6_res=$_c6_out
}

# ip_to_hex IP VAR
ip_to_hex() {
    local -n _th_res=$2
    local _th_a _th_b _th_c _th_d
    if [[ $1 == *:* ]]; then
        ip6_expand "$1" _th_res
    else
        IFS=. read -r _th_a _th_b _th_c _th_d <<< "$1"
        printf -v _th_res '%02x%02x%02x%02x' "$_th_a" "$_th_b" "$_th_c" "$_th_d"
    fi
}

# hex_to_ip FAMILY HEX VAR
hex_to_ip() {
    local -n _hi_res=$3
    if [[ $1 == 6 ]]; then
        ip6_compress "$2" _hi_res
    else
        printf -v _hi_res '%d.%d.%d.%d' "0x${2:0:2}" "0x${2:2:2}" "0x${2:4:2}" "0x${2:6:2}"
    fi
}

# hex_prefix_eq HEX1 HEX2 BITS: are the first BITS bits equal?
hex_prefix_eq() {
    local n=$(($3 / 4)) r=$(($3 % 4))
    [[ ${1:0:n} == "${2:0:n}" ]] || return 1
    ((r == 0)) && return 0
    ((((0x${1:n:1} ^ 0x${2:n:1}) >> (4 - r)) == 0))
}

# hex_mask HEX BITS VAR: clear the bits after BITS.
hex_mask() {
    local _hm_hex=$1 _hm_bits=$2 _hm_n _hm_r _hm_out _hm_nib
    local -n _hm_res=$3
    _hm_n=$((_hm_bits / 4))
    _hm_r=$((_hm_bits % 4))
    _hm_out=${_hm_hex:0:_hm_n}
    if ((_hm_r)); then
        printf -v _hm_nib '%x' $((0x${_hm_hex:_hm_n:1} & (0xF << (4 - _hm_r)) & 0xF))
        _hm_out+=$_hm_nib
    fi
    while ((${#_hm_out} < ${#_hm_hex})); do
        _hm_out+="0"
    done
    _hm_res=$_hm_out
}

# IP/LEN of either family; the address does not have to be a network address.
is_cidr() {
    local addr=${1%/*} len=${1##*/}
    [[ $1 == */* && $len =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
    if is_ipv4 "$addr"; then
        ((len <= 32))
    elif is_ipv6 "$addr"; then
        ((len <= 128))
    else
        return 1
    fi
}

# cidr_network CIDR VAR: 10.0.0.5/24 -> 10.0.0.0/24, FD00::1/64 -> fd00::/64.
cidr_network() {
    local _cn_addr=${1%/*} _cn_len=${1##*/} _cn_fam _cn_hex _cn_masked _cn_text
    local -n _cn_res=$2
    _cn_fam="$(ip_family "$_cn_addr")"
    ip_to_hex "$_cn_addr" _cn_hex
    hex_mask "$_cn_hex" "$_cn_len" _cn_masked
    hex_to_ip "$_cn_fam" "$_cn_masked" _cn_text
    _cn_res="$_cn_text/$_cn_len"
}

# Canonical CIDR text without masking (only the IPv6 notation is normalized).
cidr_normalize_text() {
    printf '%s/%s' "$(ip_normalize "${1%/*}")" "${1##*/}"
}

ip_normalize() {
    local hex text
    if [[ $1 == *:* ]]; then
        ip6_expand "$1" hex
        ip6_compress "$hex" text
        printf '%s' "$text"
    else
        printf '%s' "$1"
    fi
}

# cidr_contains CIDR IP. Different families never match.
cidr_contains() {
    local net=${1%/*} len=${1##*/} ha hb
    [[ $(ip_family "$net") == "$(ip_family "$2")" ]] || return 1
    ip_to_hex "$net" ha
    ip_to_hex "$2" hb
    hex_prefix_eq "$ha" "$hb" "$len"
}

# Two networks overlap when one contains the other.
cidr_overlap() {
    local a=${1%/*} la=${1##*/} b=${2%/*} lb=${2##*/} ha hb
    [[ $(ip_family "$a") == "$(ip_family "$b")" ]] || return 1
    ip_to_hex "$a" ha
    ip_to_hex "$b" hb
    hex_prefix_eq "$ha" "$hb" $((la < lb ? la : lb))
}

ip4_to_int() {
    local IFS=. a b c d
    read -r a b c d <<< "$1"
    echo $(((a << 24) | (b << 16) | (c << 8) | d))
}

# ip4_from_int INT VAR: no subshell, fast in loops.
ip4_from_int() {
    printf -v "$2" '%d.%d.%d.%d' $((($1 >> 24) & 255)) $((($1 >> 16) & 255)) $((($1 >> 8) & 255)) $(($1 & 255))
}

# Prints "network broadcast" of an IPv4 network as integers.
ip4_bounds() {
    local addr mask
    addr="$(ip4_to_int "${1%/*}")"
    mask=$(((0xFFFFFFFF << (32 - ${1##*/})) & 0xFFFFFFFF))
    echo "$((addr & mask)) $(((addr & mask) | (~mask & 0xFFFFFFFF)))"
}

# ip4_is_host_in CIDR IP: inside the network and neither its network nor broadcast address.
ip4_is_host_in() {
    local addr net bcast
    is_ipv4 "$2" || return 1
    addr="$(ip4_to_int "$2")"
    read -r net bcast <<< "$(ip4_bounds "$1")"
    ((addr > net && addr < bcast))
}

# 10.50.0.7 in 10.50.0.0/24 -> 7.
ip4_host_index() {
    local net bcast
    read -r net bcast <<< "$(ip4_bounds "$1")"
    echo $(($(ip4_to_int "$2") - net))
}

# fd00::/64 + 7 -> fd00::7: a peer's IPv6 address is derived from its IPv4 host index.
ip6_from_index() {
    local _fi_prefix=${1%/*} _fi_len=${1##*/} _fi_index=$2 _fi_hex _fi_masked _fi_suffix
    local -n _fi_res=$3
    ((_fi_len <= 96)) || return 1
    ip6_expand "$_fi_prefix" _fi_hex
    hex_mask "$_fi_hex" "$_fi_len" _fi_masked
    printf -v _fi_suffix '%08x' "$_fi_index"
    hex_to_ip 6 "${_fi_masked:0:24}$_fi_suffix" _fi_res
}

# Random RFC 4193 ULA /64 (fdXX:XXXX:XXXX::/64).
ip6_random_ula64() {
    local hex text
    hex="fd$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n')"
    while ((${#hex} < 32)); do
        hex+="0"
    done
    hex_to_ip 6 "$hex" text
    printf '%s/64' "$text"
}
