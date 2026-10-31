#!/usr/bin/env bash
# Unit tests of pure logic: IP arithmetic, validation, tokens, rendering and config comparison.
# They need neither root, nor network, nor WireGuard.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WGN_HOME="$(dirname "$HERE")"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
for lib in core validate ip config state render node; do
    # shellcheck source=/dev/null
    source "$WGN_HOME/lib/$lib.sh"
done
OPT_QUIET=1 OPT_DRY_RUN=0 OPT_FORCE=0
setup_colors

# A subshell, because functions that die exit the process.
runs() { (set -e; "$@") >/dev/null 2>&1; }

v6() { local out; ip6_expand "$1" out && printf '%s' "$out"; }
c6() { local hex out; ip6_expand "$1" hex && ip6_compress "$hex" out && printf '%s' "$out"; }
net() { local out; cidr_network "$1" out; printf '%s' "$out"; }

t_section 'IPv4'
for ip in 0.0.0.0 10.50.0.1 255.255.255.255 192.168.1.10; do
    assert_true "валиден $ip" is_ipv4 "$ip"
done
for ip in 010.0.0.1 256.1.1.1 1.2.3 1.2.3.4.5 '' ' 1.2.3.4' 1.2.3.4/24 a.b.c.d; do
    assert_false "невалиден '$ip'" is_ipv4 "$ip"
done
assert_eq 'ip4_to_int' "$(ip4_to_int 10.50.0.7)" $(((10 << 24) | (50 << 16) | 7))
assert_true '10.50.0.7 — хост в /24' ip4_is_host_in 10.50.0.0/24 10.50.0.7
assert_false 'network не хост' ip4_is_host_in 10.50.0.0/24 10.50.0.0
assert_false 'broadcast не хост' ip4_is_host_in 10.50.0.0/24 10.50.0.255
assert_eq 'host index' "$(ip4_host_index 10.50.0.1/24 10.50.0.7)" 7

t_section 'IPv6'
assert_eq 'expand ::' "$(v6 ::)" 00000000000000000000000000000000
assert_eq 'expand fd00::1' "$(v6 fd00::1)" fd000000000000000000000000000001
assert_eq 'expand full' "$(v6 2001:db8:0:0:1:0:0:1)" 20010db8000000000001000000000001
assert_eq 'compress: самая длинная серия' "$(c6 2001:db8:0:0:1:0:0:1)" '2001:db8::1:0:0:1'
assert_eq 'compress: первая из равных' "$(c6 1:0:0:2:0:0:3:4)" '1::2:0:0:3:4'
assert_eq 'compress: одиночный ноль не сжимается' "$(c6 1:0:2:3:4:5:6:7)" '1:0:2:3:4:5:6:7'
assert_eq 'compress: регистр и ведущие нули' "$(c6 FD00:0DB8::0001)" 'fd00:db8::1'
assert_eq 'compress ::1' "$(c6 ::1)" '::1'
assert_eq 'compress ::' "$(c6 ::)" '::'
for ip in ::: 1::2::3 12345::1 g::1 1:2:3:4:5:6:7:8:9 1:2:3:4:5:6:7 :1::2 1::2: ::ffff:1.2.3.4 fe80::1%eth0; do
    assert_false "невалиден '$ip'" is_ipv6 "$ip"
done

t_section 'CIDR'
assert_eq 'network v4' "$(net 10.0.0.5/24)" 10.0.0.0/24
assert_eq 'network /0' "$(net 1.2.3.4/0)" 0.0.0.0/0
assert_eq 'network /31' "$(net 10.0.0.3/31)" 10.0.0.2/31
assert_eq 'network v6' "$(net fd00::1/64)" fd00::/64
assert_eq 'network v6 /52' "$(net 2001:db8:abcd:1234::1/52)" 2001:db8:abcd:1000::/52
assert_true 'v4 contains' cidr_contains 10.0.0.0/8 10.200.1.1
assert_false 'v4 not contains' cidr_contains 10.0.0.0/8 11.0.0.1
assert_true '/0 contains всё' cidr_contains 0.0.0.0/0 203.0.113.9
assert_true 'v6 contains' cidr_contains fd00::/64 fd00::abcd
assert_false 'v6 not contains' cidr_contains fd00::/64 fd01::1
assert_false 'разные семейства' cidr_contains 0.0.0.0/0 ::1
assert_true 'overlap вложенные' cidr_overlap 10.0.0.0/8 10.1.0.0/16
assert_true 'overlap симметричен' cidr_overlap 10.1.0.0/16 10.0.0.0/8
assert_false 'overlap соседние /25' cidr_overlap 10.0.0.0/25 10.0.0.128/25
assert_true 'overlap v6' cidr_overlap fd00::/48 fd00:0:0:1::/64
assert_true 'is_cidr v6' is_cidr fd00::1/128
assert_false 'is_cidr /33' is_cidr 10.0.0.0/33
assert_false 'is_cidr без длины' is_cidr 10.0.0.0
assert_true 'check_route выровненный' runs check_route 192.168.10.0/24
assert_false 'check_route невыровненный' runs check_route 192.168.10.5/24
assert_eq 'ip6_from_index' "$(out=''; ip6_from_index fd00::/64 7 out; echo "$out")" fd00::7
assert_eq 'hub_address6 из сети' "$(hub_address6 fd12:3456:789a::/64)" fd12:3456:789a::1/64
assert_true 'случайный ULA /64' is_iface_cidr6 "$(ip6_random_ula64)"

t_section 'Валидация'
KEY="$(head -c32 /dev/urandom | base64)"
assert_true 'ключ из 32 байт' is_wg_key "$KEY"
assert_false 'ключ с переводом строки (инъекция в конфиг)' is_wg_key $'abc\nEndpoint = 1.2.3.4:1'
assert_false 'ключ 31 байт' is_wg_key "$(head -c31 /dev/urandom | base64)"
for ep in 203.0.113.1:51820 vpn.example.com:51820 '[2001:db8::1]:51820'; do
    assert_true "endpoint $ep" is_endpoint "$ep"
done
for ep in 203.0.113.1 203.0.113.1:0 203.0.113.1:70000 'x;rm:99' 'a b:1' '2001:db8::1:51820' '[fe80::1%eth0]:1' '-oProxy:1'; do
    assert_false "endpoint '$ep'" is_endpoint "$ep"
done
assert_true 'имя worker-1.prod' is_name worker-1.prod
for n in ../x .hidden 'a b' '' "$(printf 'x%.0s' {1..33})" 'a/b'; do
    assert_false "имя '$n'" is_name "$n"
done
assert_true 'table 1234' is_table 1234
assert_false 'table 254 (main)' is_table 254
assert_true 'комментарий кириллицей' is_comment 'сервер в Москве, стойка 4'
# shellcheck disable=SC2016  # the literal text is what is tested
assert_false 'комментарий с $()' is_comment 'x $(reboot)'
assert_false 'комментарий с кавычкой' is_comment 'a"b'
assert_true 'iface /24' is_iface_cidr4 10.50.0.1/24
assert_false 'iface — адрес сети' is_iface_cidr4 10.50.0.0/24
assert_false 'iface /31' is_iface_cidr4 10.50.0.1/31
assert_eq 'endpoint_with_port IPv4' "$(endpoint_with_port 203.0.113.1 51820)" 203.0.113.1:51820
assert_eq 'endpoint_with_port IPv6' "$(endpoint_with_port 2001:db8::1 51820)" '[2001:db8::1]:51820'
assert_eq 'endpoint_with_port с портом' "$(endpoint_with_port vpn.example.com:443 51820)" vpn.example.com:443

t_section 'Доверенное расположение кода'
source "$WGN_HOME/lib/system.sh"
UNTRUSTED="$(mktemp -d)"
touch "$UNTRUSTED/wg-network"
assert_false 'каталог не-root пользователя — недоверенный' bash -c "source '$WGN_HOME/lib/system.sh'; WGN_HOME='$UNTRUSTED' wgn_home_trusted"
chmod 777 "$UNTRUSTED"
assert_false 'каталог с записью для всех — недоверенный' bash -c "source '$WGN_HOME/lib/system.sh'; WGN_HOME='$UNTRUSTED' wgn_home_trusted"
rm -rf "$UNTRUSTED"

t_section 'Валидация: граничные значения'
for v in 0 25 65535; do assert_true "keepalive $v" is_keepalive "$v"; done
for v in -1 65536 x 025; do assert_false "keepalive '$v'" is_keepalive "$v"; done
assert_true 'MTU 1280' is_mtu 1280
assert_true 'MTU 9000' is_mtu 9000
assert_false 'MTU 1279' is_mtu 1279
assert_false 'MTU 9001' is_mtu 9001
assert_true 'port 1' is_port 1
assert_false 'port 65536' is_port 65536
for v in auto off 1 252 256 4294967295; do assert_true "table $v" is_table "$v"; done
for v in 0 253 254 255 4294967296 main; do assert_false "table '$v'" is_table "$v"; done
assert_true 'hostname с дефисом' is_hostname vpn-1.example.com
assert_false 'hostname из цифр — это IP' is_hostname 1.2.3.4
assert_false 'hostname с ведущим дефисом' is_hostname -bad.example.com
assert_true 'endpoint — литерал IP' endpoint_is_literal '[2001:db8::1]:51820'
assert_false 'endpoint — DNS-имя' endpoint_is_literal vpn.example.com:51820
assert_true 'iface wg0' is_iface wg0
assert_false 'iface длиннее 15' is_iface abcdefghijklmnop
assert_false 'iface с пробелом' is_iface 'a b'
declare b_out=''
parse_bool on b_out; assert_eq 'parse_bool on' "$b_out" 1
parse_bool NO b_out; assert_eq 'parse_bool NO' "$b_out" 0
assert_false 'parse_bool maybe' parse_bool maybe b_out
assert_true 'iface6 /64' is_iface_cidr6 fd00::1/64
assert_false 'iface6 /120' is_iface_cidr6 fd00::1/120

t_section 'Файлы'
FT="$(mktemp -d)"
printf 'A=1\nB=x=y\n#C=3\nA=2\n' > "$FT/kv"
assert_eq 'kv_get: последнее значение' "$(kv_get "$FT/kv" A)" 2
assert_eq 'kv_get: значение с =' "$(kv_get "$FT/kv" B)" 'x=y'
assert_eq 'kv_get: нет ключа' "$(kv_get "$FT/kv" Z)" ''
assert_eq 'kv_get: нет файла' "$(kv_get "$FT/none" A)" ''
declare -A KV=([X]=1 [Y]='')
kv_save "$FT/out" KV X Y
assert_eq 'kv_save: порядок и пустые значения' "$(cat "$FT/out")" $'X=1\nY='
assert_eq 'kv_save: права 600' "$(stat -c %a "$FT/out")" 600
printf 'old' > "$FT/target"
ln -s "$FT/target" "$FT/link"
assert_false 'write_secret_file не пишет через симлинк' runs bash -c "source '$WGN_HOME/lib/core.sh'; OPT_FORCE=0; echo secret | write_secret_file '$FT/link'"
assert_eq 'цель симлинка не тронута' "$(cat "$FT/target")" old
assert_false 'write_secret_file не перезаписывает существующий файл' runs bash -c "source '$WGN_HOME/lib/core.sh'; OPT_FORCE=0; echo s | write_secret_file '$FT/target'"
(OPT_FORCE=1; echo secret | write_secret_file "$FT/link")
assert_eq '--force заменяет сам симлинк, а не цель' "$(cat "$FT/target")" old
assert_eq 'новый файл — обычный, 600' "$(stat -c '%F %a' "$FT/link")" 'regular file 600'
echo data | write_atomic "$FT/atomic" 640
assert_eq 'write_atomic: права' "$(stat -c %a "$FT/atomic")" 640
assert_eq 'write_atomic: не оставляет временных файлов' "$(find "$FT" -name '.atomic.*' | wc -l)" 0
rm -rf "$FT"

t_section 'Утилиты'
declare -a parts=()
split_csv ' a, b ,,c ' parts
assert_eq 'split_csv' "${parts[*]}" 'a b c'
assert_eq 'join_by' "$(join_by ', ' x y z)" 'x, y, z'
assert_eq 'human_bytes B' "$(human_bytes 512)" '512 B'
assert_eq 'human_bytes MiB' "$(human_bytes $((5 * 1024 * 1024 + 512 * 1024)))" '5.5 MiB'
assert_eq 'human_bytes GiB' "$(human_bytes $((3 * 1024 * 1024 * 1024)))" '3.0 GiB'
assert_eq 'human_age' "$(human_age 59) $(human_age 61) $(human_age 7200) $(human_age 172800)" '59s 1m 2h 2d'
assert_eq 'ip_normalize' "$(ip_normalize 2001:DB8:0:0::1)" '2001:db8::1'
assert_eq 'cidr_normalize_text' "$(cidr_normalize_text FD00:0::/64)" 'fd00::/64'
assert_eq 'json_str экранирование' "$(json_str 'a"b\c')" '"a\"b\\c"'
assert_eq 'routes_normalize' "$(routes_normalize '10.1.0.0/16, FD00::/64,10.1.0.0/16')" '10.1.0.0/16,fd00::/64'

t_section 'Конвейеры под pipefail'
assert_true 'output_has: совпадение в начале длинного вывода (нет ложного «нет» из-за SIGPIPE)' \
    bash -c "set -o pipefail; source '$WGN_HOME/lib/core.sh'; output_has '^Status: active' bash -c 'echo Status: active; seq 1 300000'"
assert_false 'output_has: нет совпадения' output_has '^nope' printf 'a\nb\n'

t_section 'Токен приглашения'
declare -A T=([NAME]=w1 [ADDRESS]=10.50.0.2 [HUB_KEY]="$KEY" [HUB_ENDPOINT]='[2001:db8::1]:51820' [ROUTES]=10.50.0.0/24 [PSK]="$KEY" [KEEPALIVE]=25)
TOKEN="$TOKEN_PREFIX$(token_encode T)"
declare -A D=()
token_decode "$TOKEN" D
assert_eq 'roundtrip NAME' "${D[NAME]}" w1
assert_eq 'roundtrip endpoint IPv6' "${D[HUB_ENDPOINT]}" '[2001:db8::1]:51820'
assert_eq 'roundtrip PSK' "${D[PSK]}" "$KEY"
assert_true 'токен url-safe' bash -c "[[ '$TOKEN' =~ ^wgn1\.[A-Za-z0-9_-]+$ ]]"
BAD="$TOKEN_PREFIX$(printf 'NAME=x\nEVIL=1\n' | base64 -w0 | tr '+/' '-_' | tr -d '=')"
assert_false 'неизвестное поле отклоняется' runs token_decode "$BAD" D
assert_false 'мусор отклоняется' runs token_decode 'wgn1.!!!' D
assert_false 'чужой префикс' runs token_decode 'abc' D

t_section 'Состояние и рендер'
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
IFACE=wg0
st_paths "$SANDBOX/wg0"
LIVE_CONF="$SANDBOX/wg0.conf"
mkdir -p "$ST_PEERS"
head -c32 /dev/urandom | base64 > "$ST_KEY"
NODE=([ROLE]=hub [NAME]=hub [ADDRESS]=10.50.0.1/24 [ADDRESS6]=fd00::1/64 [LISTEN_PORT]=51820
    [ENDPOINT]=203.0.113.1:51820 [TABLE]=auto [FORWARD]=1 [NAT]=eth0)
st_node_save
st_node_load
K1="$(head -c32 /dev/urandom | base64)"
K2="$(head -c32 /dev/urandom | base64)"
PEER=([PUBLIC_KEY]="$K1" [ADDRESS]=10.50.0.2 [ADDRESS6]=fd00::2 [ROUTES]=192.168.10.0/24 [ENABLED]=1 [PENDING]=0 [COMMENT]='офис')
st_peer_save office
PEER=([PUBLIC_KEY]='' [ADDRESS]=10.50.0.3 [ENABLED]=1 [PENDING]=1)
st_peer_save invited
PEER=([PUBLIC_KEY]="$K2" [ADDRESS]=10.50.0.4 [ENABLED]=0 [PENDING]=0)
st_peer_save off

assert_true 'состояние валидно' runs st_require_valid
assert_eq 'следующий свободный (резервация занята)' "$(st_next_free_ip4)" 10.50.0.5
assert_eq 'владелец маршрута' "$(st_owner_of_cidr 192.168.10.128/25)" 'office (192.168.10.0/24)'
assert_false 'свободный маршрут' st_owner_of_cidr 172.16.0.0/12
assert_eq 'IPv6 выводится из IPv4' "$(st_derive_ip6 10.50.0.9)" fd00::9

CONF="$(render_conf)"
assert_contains 'Address dual-stack' "$CONF" 'Address = 10.50.0.1/24, fd00::1/64'
assert_contains 'AllowedIPs peer' "$CONF" 'AllowedIPs = 10.50.0.2/32, fd00::2/128, 192.168.10.0/24'
assert_not_contains 'приглашённый не попадает в конфиг' "$CONF" 'peer: invited'
assert_not_contains 'отключённый не попадает в конфиг' "$CONF" "$K2"
assert_contains 'форвардинг per-interface, не ip_forward' "$CONF" 'net.ipv4.conf.%i.forwarding=1'
assert_not_contains 'глобальный ip_forward не трогается' "$CONF" 'net.ipv4.ip_forward'
assert_contains 'идемпотентный PostUp (-C || -I)' "$CONF" 'iptables -w -t filter -C FORWARD -i %i -o %i -m comment --comment wg-network -j ACCEPT 2>/dev/null || iptables'
assert_contains 'PostDown удаляет своё' "$CONF" 'PostDown = iptables -w -t nat -D POSTROUTING -s 10.50.0.0/24 -o eth0'
assert_contains 'MSS clamping' "$CONF" 'TCPMSS --clamp-mss-to-pmtu'
assert_contains 'NAT66 при dual-stack' "$CONF" 'ip6tables -w -t nat -C POSTROUTING -s fd00::/64 -o eth0'

printf '%s\n' "$CONF" > "$SANDBOX/a.conf"
# Same meaning, different form: AllowedIPs order, key case, spacing, comments.
sed -e 's/AllowedIPs = 10.50.0.2\/32, fd00::2\/128, 192.168.10.0\/24/allowedips=192.168.10.0\/24,10.50.0.2\/32 ,fd00::2\/128 # x/' \
    -e 's/^ListenPort = /ListenPort=/' -e '/^# /d' "$SANDBOX/a.conf" > "$SANDBOX/b.conf"
assert_eq 'канон не зависит от оформления' "$(conf_canon "$SANDBOX/b.conf" | grep -v "^N")" "$(conf_canon "$SANDBOX/a.conf" | grep -v "^N")"
sed 's/192.168.10.0\/24/192.168.20.0\/24/' "$SANDBOX/a.conf" > "$SANDBOX/c.conf"
assert_false 'канон видит смену маршрута' cmp -s <(conf_canon "$SANDBOX/a.conf") <(conf_canon "$SANDBOX/c.conf")
assert_contains 'имя peer из комментария (с names)' "$(conf_canon "$SANDBOX/a.conf" names)" "N$FS$K1${FS}office"
assert_not_contains 'без names имена не участвуют в сравнении' "$(conf_canon "$SANDBOX/a.conf")" "N$FS"

# A tampered state file must never become a config.
printf 'PUBLIC_KEY=%s\nADDRESS=10.50.0.9\nROUTES=1.2.3.0/24\nENDPOINT=x\nENABLED=1\nPENDING=0\n' "$K2" > "$ST_PEERS/evil.env"
assert_false 'повреждённое состояние отклоняется' runs st_require_valid
rm -f "$ST_PEERS/evil.env"

t_summary
