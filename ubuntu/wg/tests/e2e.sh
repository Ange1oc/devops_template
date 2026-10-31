#!/usr/bin/env bash
# E2E tests on the kernel WireGuard module. Run: tests/run.sh e2e (creates user/mount/net namespaces).
#
# Every node is a network namespace with its own /etc/wireguard (ip netns exec bind-mounts
# /etc/netns/<node>/wireguard over it). Nodes share the bridge br0 (192.0.2.0/24, TEST-NET-1).
# /etc, /opt, /usr/local/bin and /var/backups are covered by overlays, so the host is not changed.
# Stubs replace only systemd (systemctl, systemd-run), logger and timedatectl.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(dirname "$HERE")"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

[[ $(id -u) == 0 && -n ${WGN_E2E_INSIDE-} ]] || { echo 'запускай через tests/run.sh e2e' >&2; exit 2; }
WORK=${WGN_E2E_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/wgn-e2e.XXXXXX")}
# Background test processes are killed on exit.
cleanup() {
    local pid comm
    for pid in $(pgrep -f -- 'wgn-e2e-(client|sshd)'); do
        comm="$(cat "/proc/$pid/comm" 2>/dev/null)"
        [[ $comm == python3* || $comm == sshd ]] && kill -KILL "$pid" 2>/dev/null
    done
    # run.sh removes the work directory after leaving the namespace; overlays are mounted here.
}
trap cleanup EXIT
# A private TMPDIR, so leftovers of wg-network can be checked apart from the host's /tmp.
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"

setup_isolation() {
    local d n
    # In a user namespace subdirectories of /etc need their own overlays: copy-up of a
    # directory owned by the real root is not allowed. Under a real root (a container) they
    # are not needed, and the extra level would exceed the overlayfs stacking limit.
    local userns=1
    [[ $(awk '{print $1, $2, $3}' /proc/self/uid_map) == '0 0 4294967295' ]] && userns=0
    for d in /etc /etc/systemd/system /etc/bash_completion.d /etc/default /opt /usr/local/bin /var/backups; do
        [[ -d $d ]] || continue
        [[ $d == /etc/* ]] && ((!userns)) && continue
        n="$WORK/ov${d//\//_}"
        mkdir -p "$n/up" "$n/work"
        mount -t overlay overlay -o "lowerdir=$d,upperdir=$n/up,workdir=$n/work" "$d" || { echo "overlay $d не удался"; exit 2; }
    done
    mount -t tmpfs tmpfs /run
    mkdir -p /run/netns /run/systemd/system /run/lock /etc/wireguard
    rm -f /etc/default/wg-network
}

# Fault injection wrappers: they fail only for a "bad" config, as a real failure would.
setup_fault_wrappers() {
    local real_wg real_quick
    real_wg="$(command -v wg)"
    real_quick="$(command -v wg-quick)"
    mkdir -p "$WORK/fault"
    cat > "$WORK/fault/wg" <<EOF
#!/bin/bash
if [[ \$1 == syncconf ]] && grep -q '^# peer: failsync' "/etc/wireguard/\$2.conf" 2>/dev/null; then
    echo 'fault injection: syncconf' >&2; exit 1
fi
exec "$real_wg" "\$@"
EOF
    cat > "$WORK/fault/wg-quick" <<EOF
#!/bin/bash
if [[ \$1 == up ]] && { grep -q '^MTU = 1380' "/etc/wireguard/\$2.conf" 2>/dev/null || [[ -e /etc/wireguard/.fail-up ]]; }; then
    echo 'fault injection: up' >&2; exit 1
fi
exec "$real_quick" "\$@"
EOF
    chmod +x "$WORK/fault/wg" "$WORK/fault/wg-quick"
    export PATH="$HERE/stubs:$WORK/fault:$PATH"
}

NODES=(hub w1 w2 w3 c1 legacy v1legacy hub6 w6 office full dnsp fsn r1 tk mp big)
declare -A UNDERLAY=([hub]=1 [w1]=11 [w2]=12 [w3]=13 [c1]=21 [legacy]=31 [v1legacy]=33 [hub6]=41 [w6]=42
    [office]=51 [full]=61 [dnsp]=71 [fsn]=81 [r1]=91 [tk]=93 [mp]=95 [big]=97)

# Nodes live in 192.0.2.0/24 (bridge br0); router rt (192.0.2.254) leads to the "internet":
# admin 203.0.113.7 (an administrator with SSH) and web 198.51.100.10 (a site to test NAT).
# officelan 192.168.10.10 is a host in the LAN behind node office (site-to-site).
setup_network() {
    local n
    ip link add br0 type bridge
    ip link set br0 up
    for n in "${NODES[@]}" rt; do
        ip netns add "$n" 2>/dev/null
        mkdir -p "/etc/netns/$n/wireguard"
        echo boot-1 > "$WORK/boot-$n"
        ip link add "v-$n" type veth peer name eth0 netns "$n"
        ip link set "v-$n" master br0 up
        ip -n "$n" link set eth0 up
        ip -n "$n" link set lo up
    done
    for n in "${NODES[@]}"; do
        ip -n "$n" addr add "192.0.2.${UNDERLAY[$n]}/24" dev eth0
        ip -n "$n" route add default via 192.0.2.254
    done
    ip -n rt addr add 192.0.2.254/24 dev eth0
    ip netns exec rt sysctl -q -w net.ipv4.ip_forward=1
    segment admin rt-adm 203.0.113.7 203.0.113.1 24 rt
    segment web rt-web 198.51.100.10 198.51.100.1 24 rt
    segment officelan olan 192.168.10.10 192.168.10.1 24 office
}

# segment NETNS IF_ROUTER HOST_IP ROUTER_IP LEN ROUTER_NETNS: a network behind a router.
segment() {
    ip netns add "$1"
    echo boot-1 > "$WORK/boot-$1"
    mkdir -p "/etc/netns/$1/wireguard"
    ip link add "$2" netns "$6" type veth peer name eth0 netns "$1"
    ip -n "$6" addr add "$4/$5" dev "$2"
    ip -n "$6" link set "$2" up
    ip -n "$1" addr add "$3/$5" dev eth0
    ip -n "$1" link set eth0 up
    ip -n "$1" link set lo up
    ip -n "$1" route add default via "$4"
}

node() {
    local n=$1
    shift
    ip netns exec "$n" env WGN_BOOT_ID="$(cat "$WORK/boot-$n")" WGN_UNSAFE_TRUST_HOME=1 NO_COLOR=1 "$@"
}

# run NODE ARGS...: run wg-network on a node; sets OUT and RC.
run() {
    local n=$1
    shift
    OUT="$(node "$n" wg-network "$@" 2>&1 < /dev/null)"
    RC=$?
}

wg_conf() { cat "/etc/netns/$1/wireguard/${2:-wg0}.conf"; }
state_dir() { echo "/etc/netns/$1/wireguard/wg-network/${2:-wg0}"; }
# Wait up to N seconds for a reply: a handshake is not instant. ping -c 1 also returns at once
# on an ICMP error (WireGuard answers host unreachable while a peer has no endpoint), so it
# is retried until the deadline. On failure the tunnel state of both sides is printed.
pings() {
    local deadline=$((SECONDS + ${3:-5}))
    while ((SECONDS < deadline)); do
        node "$1" ping -c 1 -W 1 "$2" >/dev/null 2>&1 && return 0
        sleep 0.3
    done
    {
        echo "--- $1: wg show / ip route"
        node "$1" wg show 2>&1
        node "$1" ip route 2>&1
        echo "--- hub: wg show"
        node hub wg show 2>&1 | head -60
        echo "--- hub: iptables FORWARD / sysctl"
        node hub iptables -vnL FORWARD 2>&1 | head -8
        node hub sysctl net.ipv4.conf.wg0.forwarding net.ipv4.conf.all.forwarding net.ipv4.conf.wg0.rp_filter net.ipv4.conf.all.rp_filter 2>&1
        echo "--- w2: wg show / ip route"
        node w2 wg show 2>&1
        node w2 ip route 2>&1
    } | sed 's/^/       | /' >&2
    return 1
}
# Kill test processes (python3/sshd) carrying a marker argument, and only them. SIGKILL:
# util-linux 2.37 (Ubuntu 22.04) ignores SIGTERM in unshare --fork and children inherit it.
kill_marked() {
    local pid comm
    for pid in $(pgrep -f -- "$1"); do
        comm="$(cat "/proc/$pid/comm" 2>/dev/null)"
        [[ $comm == python3* || $comm == sshd ]] && kill -KILL "$pid" 2>/dev/null
    done
    return 0
}
token_of() { grep -o 'wgn1\.[A-Za-z0-9_-]*' <<< "$1" | head -n 1; }
key_of() { grep -oP '(?<=--key )\S+' <<< "$1" | head -n 1; }

# Full join cycle: invite on the hub, join on the node, peer add on the hub.
onboard() {
    local hub=$1 name=$2 token key
    run "$hub" invite "$name" "${@:3}"
    token="$(token_of "$OUT")"
    [[ -n $token ]] || { t_fail "invite $name" "$OUT"; return 1; }
    run "$name" join "$token" --yes
    [[ $RC == 0 ]] || { t_fail "join $name" "$OUT"; return 1; }
    key="$(key_of "$OUT")"
    run "$hub" peer add "$name" --key "$key" --yes
    [[ $RC == 0 ]] || { t_fail "peer add $name" "$OUT"; return 1; }
    t_ok "подключение $name (invite → join → peer add)"
}

t_section 'Установка'
setup_isolation
setup_fault_wrappers
setup_network
OUT="$(bash "$SRC/install.sh" --local "$SRC" 2>&1)"
assert_rc 'install.sh --local' 0 $? "$OUT"
assert_true 'команда в /usr/local/bin' test -x /usr/local/bin/wg-network
assert_true 'тесты не устанавливаются' test ! -e /opt/wg-network/tests
run hub help
assert_contains 'help с разделами' "$OUT" 'Применение и откат'
OUT="$(bash "$SRC/install.sh" --ref 'a;b' 2>&1)"; assert_rc 'install.sh: некорректный --ref' 1 $? "$OUT"
OUT="$(bash "$SRC/install.sh" --repo nope 2>&1)"; assert_rc 'install.sh: некорректный --repo' 1 $? "$OUT"
OUT="$(bash "$SRC/install.sh" --bogus 2>&1)"; assert_rc 'install.sh: неизвестный аргумент' 1 $? "$OUT"
OUT="$(bash /opt/wg-network/install.sh --rollback 2>&1)"; assert_rc 'install.sh --rollback без предыдущей версии' 1 $? "$OUT"
(exec 9> /run/lock/wg-network-install.lock; flock 9; sleep 3) &
sleep 0.5
OUT="$(bash "$SRC/install.sh" --local "$SRC" 2>&1)"; assert_rc 'вторая установка параллельно отклонена' 1 $? "$OUT"
wait
OUT="$(bash "$SRC/install.sh" --help 2>&1)"; assert_contains 'install.sh --help' "$OUT" '--rollback'

t_section 'Hub: dry-run и разделение подготовки и применения'
run hub --dry-run init hub --endpoint 192.0.2.1
assert_rc 'dry-run init' 0 "$RC" "$OUT"
assert_contains 'dry-run показывает план' "$OUT" 'План для wg0'
assert_true 'dry-run ничего не создал' test ! -e "$(state_dir hub)" -a ! -e /etc/netns/hub/wireguard/wg0.conf
run hub init hub --endpoint 192.0.2.1
assert_rc 'init без --apply и без TTY' 0 "$RC" "$OUT"
assert_contains 'изменения подготовлены, не применены' "$OUT" 'не применены'
assert_false 'интерфейс не поднят без разрешения' node hub ip link show wg0
run hub plan
assert_rc 'plan: есть неприменённые изменения (код 10)' 10 "$RC" "$OUT"
run hub apply --yes
assert_rc 'apply' 0 "$RC" "$OUT"
assert_true 'wg0 поднят' node hub ip link show wg0
assert_eq 'слушает 51820' "$(node hub wg show wg0 listen-port)" 51820
assert_eq 'права конфига 600' "$(stat -c %a /etc/netns/hub/wireguard/wg0.conf)" 600
assert_eq 'права каталога состояния 700' "$(stat -c %a "$(state_dir hub)")" 700
run hub plan
assert_rc 'plan после apply: изменений нет' 0 "$RC" "$OUT"
assert_true 'drop-in защиты от перезагрузки' test -f /etc/systemd/system/wg-quick@wg0.service.d/wg-network.conf

t_section 'Подключение peer'
run hub invite w1
assert_contains 'invite печатает join без токена в командной строке' "$OUT" 'sudo wg-network join        '
assert_true 'invite печатает токен отдельной строкой' grep -qx 'wgn1\.[A-Za-z0-9_-]*' <<< "$OUT"
assert_not_contains 'приглашённый не в конфиге hub' "$(wg_conf hub)" 'peer: w1'
onboard hub w1
run hub invite w1
assert_rc 'повторный invite существующего peer запрещён' 3 "$RC" "$OUT"
# The peer started its handshake before peer add; it retries after REKEY_TIMEOUT (5 s + jitter).
assert_true 'w1 → hub ping' pings w1 10.50.0.1 10
assert_contains 'w1 в конфиге hub' "$(wg_conf hub)" '# peer: w1'

t_section 'Горячее добавление без разрыва туннелей'
node w1 ping -c 30 -i 0.2 -W 1 10.50.0.1 > "$WORK/ping.log" 2>&1 &
PING_PID=$!
sleep 0.5
onboard hub w2
onboard hub w3
wait "$PING_PID"
assert_contains 'ни одного потерянного пакета w1 во время добавления w2, w3' "$(cat "$WORK/ping.log")" ' 0% packet loss'
assert_true 'w2 → hub' pings w2 10.50.0.1 10
assert_false 'изоляция: w1 не видит w2 без --forward' pings w1 10.50.0.3 2

t_section 'Маршрутизация между peer (перезапуск под таймером отката)'
IPFWD_BEFORE="$(node hub sysctl -n net.ipv4.ip_forward)"
run hub set --forward on --yes
assert_rc 'set --forward on' 0 "$RC" "$OUT"
assert_contains 'план: перезапуск' "$OUT" 'перезапуск wg0'
assert_contains 'set сообщает итог' "$OUT" 'wg0: применено'
assert_eq 'форвардинг только на wg0' "$(node hub sysctl -n net.ipv4.conf.wg0.forwarding)" 1
assert_eq 'глобальный ip_forward не тронут' "$(node hub sysctl -n net.ipv4.ip_forward)" "$IPFWD_BEFORE"
assert_contains 'правило FORWARD' "$(node hub iptables -S FORWARD)" 'wg-network'
assert_contains 'MSS clamping' "$(node hub iptables -t mangle -S FORWARD)" 'TCPMSS'
run w1 peer set hub --routes 10.50.0.0/24 --yes
assert_rc 'w1: маршрут на всю сеть' 0 "$RC" "$OUT"
run w2 peer set hub --routes 10.50.0.0/24 --yes
assert_rc 'w2: маршрут на всю сеть' 0 "$RC" "$OUT"
assert_true 'w1 → w2 через hub сразу после горячих изменений на peer (порт сохранён)' pings w1 10.50.0.3 3
assert_false 'не осталось неподтверждённых применений' test -f "$(state_dir hub)/pending.env"

t_section 'Предохранитель SSH'
SSH='198.51.100.7 50022 192.0.2.1 22'
OUT="$(node hub env SSH_CONNECTION="$SSH" wg-network peer set w1 --routes 198.51.100.0/24 --yes 2>&1)"
RC=$?
assert_rc 'маршрут, перехватывающий SSH-клиента, заблокирован' 3 "$RC" "$OUT"
assert_contains 'объяснение блокировки' "$OUT" 'SSH-клиенту 198.51.100.7'
assert_not_contains 'состояние не изменилось после отказа' "$(cat "$(state_dir hub)/peers.d/w1.env")" '198.51.100'
OUT="$(node hub env SSH_CONNECTION="$SSH" wg-network peer set w1 --routes 198.51.100.0/24 --yes --force 2>&1)"
assert_rc 'с --force применяется' 0 $? "$OUT"
assert_contains '--yes не подтверждает изменение, затрагивающее SSH' "$OUT" 'не подтверждает его автоматически'
assert_true 'таймер отката взведён' test -f "$(state_dir hub)/pending.env"
assert_contains 'маршрут появился' "$(node hub ip route show dev wg0)" '198.51.100.0/24'
run hub confirm
assert_rc 'явное подтверждение' 0 "$RC" "$OUT"
run hub peer set w1 --routes none --yes
assert_not_contains 'маршрут убран горячо' "$(node hub ip route show dev wg0)" '198.51.100.0/24'
OUT="$(node hub env SSH_CONNECTION='10.50.0.2 50000 10.50.0.1 22' wg-network peer disable w1 --yes 2>&1)"
assert_rc 'нельзя отключить peer, через который идёт SSH' 3 $? "$OUT"
run w3 --dry-run peer set hub --routes 0.0.0.0/0
OUT="$(node w3 env SSH_CONNECTION='198.51.100.7 50022 192.0.2.13 22' wg-network peer set hub --routes 0.0.0.0/0 --yes 2>&1)"
assert_rc 'full tunnel на сервере с SSH по маршруту по умолчанию заблокирован' 3 $? "$OUT"

t_section 'Отказ горячего применения → автоматический откат'
BEFORE="$(node hub wg show wg0 peers | sort)"
KEY_FAIL="$(node hub wg genkey | node hub wg pubkey)"
run hub peer add failsync --key "$KEY_FAIL" --yes
assert_rc 'код 4 (откат)' 4 "$RC" "$OUT"
assert_eq 'peer в ядре не изменились' "$(node hub wg show wg0 peers | sort)" "$BEFORE"
assert_not_contains 'конфиг возвращён' "$(wg_conf hub)" 'failsync'
assert_true 'состояние возвращено' test ! -e "$(state_dir hub)/peers.d/failsync.env"
assert_true 'туннели работают' pings w1 10.50.0.1

t_section 'Отказ перезапуска → автоматический откат'
run hub set --mtu 1380 --yes
assert_rc 'интерфейс не поднялся — код 4' 4 "$RC" "$OUT"
assert_true 'wg0 снова работает со старым конфигом' pings w1 10.50.0.1
assert_not_contains 'MTU не изменился' "$(wg_conf hub)" 'MTU = 1380'
assert_not_contains 'состояние возвращено' "$(cat "$(state_dir hub)/node.env")" 'MTU=1380'

t_section 'Dead-man: без подтверждения конфигурация откатывается сама'
run hub set --mtu 1400 --yes --wait-confirm --confirm-timeout 3
assert_rc 'применено, ждёт подтверждения' 0 "$RC" "$OUT"
assert_contains 'MTU применён' "$(node hub ip link show wg0)" 'mtu 1400'
run hub peer remove w3 --yes
assert_rc 'другие изменения заблокированы до подтверждения (код 5)' 5 "$RC" "$OUT"
sleep 6
assert_false 'pending снят таймером' test -f "$(state_dir hub)/pending.env"
assert_contains 'MTU вернулся' "$(node hub ip link show wg0)" 'mtu 1420'
assert_true 'туннели работают после отката' pings w1 10.50.0.1
assert_contains 'откат в аудите' "$(cat /etc/netns/hub/wireguard/.audit.log)" 'rollback mode=auto'
run hub plan
assert_rc 'желаемое состояние тоже возвращено: следующая команда не применит отклонённое' 0 "$RC" "$OUT"
assert_not_contains 'MTU из отклонённого изменения не остался в состоянии' "$(cat "$(state_dir hub)/node.env")" 'MTU=1400'
run hub history
REJECTED="$(grep -o '^[0-9-]*-rejected' <<< "$OUT" | head -n 1)"
assert_true 'отклонённое изменение сохранено снимком rejected' test -n "$REJECTED"
run hub rollback "$REJECTED" --yes --wait-confirm --confirm-timeout 60
assert_contains 'отклонённое изменение можно повторить' "$(node hub ip link show wg0)" 'mtu 1400'
run hub rollback --yes
assert_rc 'повтор отменён' 0 "$RC" "$OUT"
assert_contains 'MTU снова прежний' "$(node hub ip link show wg0)" 'mtu 1420'
run hub plan
assert_rc 'состояние выровнено' 0 "$RC" "$OUT"

t_section 'Подтверждение из другой сессии'
run hub set --mtu 1400 --yes --wait-confirm --confirm-timeout 4
run hub confirm
assert_rc 'confirm' 0 "$RC" "$OUT"
sleep 5
assert_contains 'после таймаута конфигурация осталась' "$(node hub ip link show wg0)" 'mtu 1400'
run hub set --mtu auto --yes

t_section 'Перезагрузка до подтверждения → при загрузке поднимается прежний конфиг'
run hub set --mtu 1360 --yes --wait-confirm --confirm-timeout 120
assert_contains 'новый MTU применён' "$(node hub ip link show wg0)" 'mtu 1360'
kill -KILL "$(cat /etc/netns/hub/wireguard/.systemd/*.timer.pid 2>/dev/null)" 2>/dev/null
node hub wg-quick down wg0 >/dev/null 2>&1
rm -f /etc/netns/hub/wireguard/.systemd/wg-quick@wg0.service.active
echo boot-2 > "$WORK/boot-hub"
node hub systemctl start wg-quick@wg0.service
assert_contains 'после «перезагрузки» MTU прежний' "$(node hub ip link show wg0)" 'mtu 1420'
assert_false 'pending снят при загрузке' test -f "$(state_dir hub)/pending.env"
assert_true 'туннели работают (peer сами восстанавливают сессию после «перезагрузки»)' pings w1 10.50.0.1 25
run hub set --mtu auto --yes

t_section 'Интерактивный режим (псевдотерминал)'
if command -v script >/dev/null; then
    tty_run() { printf '%b' "$1" | node hub script -qec "wg-network $2" /dev/null > "$WORK/tty.log" 2>&1; }
    tty_run 'y\nyes\n' 'set --mtu 1400 --confirm-timeout 20'
    assert_rc 'интерактивно: согласие и подтверждение' 0 $? "$(cat "$WORK/tty.log")"
    assert_contains 'конфигурация осталась' "$(node hub ip link show wg0)" 'mtu 1400'
    tty_run 'n\n' 'set --mtu 1420'
    assert_contains 'отказ: изменения только подготовлены' "$(cat "$WORK/tty.log")" 'не применены'
    assert_contains 'интерфейс не тронут' "$(node hub ip link show wg0)" 'mtu 1400'
    run hub set --mtu auto --no-apply
    tty_run 'y\nno\n' 'apply --confirm-timeout 3'
    assert_rc 'интерактивно: без подтверждения — откат (код 4)' 4 $? "$(cat "$WORK/tty.log")"
    assert_contains 'MTU вернулся к подтверждённому' "$(node hub ip link show wg0)" 'mtu 1400'
    run hub apply --yes
    assert_contains 'применено после повторного apply' "$(node hub ip link show wg0)" 'mtu 1420'
else
    echo '  (script не найден — интерактивные тесты пропущены)'
fi

t_section 'Обрыв сессии во время ожидания подтверждения → немедленный откат'
if command -v script >/dev/null; then
    # stdin stays open (like a live terminal), then the process gets SIGHUP, as on an SSH drop.
    (printf 'y\n'; sleep 40) | node hub script -qec 'wg-network set --mtu 1300 --confirm-timeout 120' /dev/null > "$WORK/hup.log" 2>&1 &
    for i in $(seq 1 40); do grep -q 'mtu 1300' <<< "$(node hub ip link show wg0)" && break; sleep 0.25; done
    assert_contains 'новый MTU применён, идёт ожидание подтверждения' "$(node hub ip link show wg0)" 'mtu 1300'
    sleep 1
    T0=$SECONDS
    # The wg-network process itself: its comm is bash, so match the path in its command line.
    for p in $(pgrep -f '/wg-network set --mtu 1300'); do
        [[ $(cat "/proc/$p/comm" 2>/dev/null) == bash ]] && kill -HUP "$p"
    done
    for i in $(seq 1 40); do grep -q 'mtu 1420' <<< "$(node hub ip link show wg0)" && break; sleep 0.25; done
    assert_contains "откат сразу после обрыва ($((SECONDS - T0)) с), а не через 120 с" "$(node hub ip link show wg0)" 'mtu 1420'
    # pending.env is removed at the end of the rollback, after the re-handshake: wait for it.
    for i in $(seq 1 40); do test -f "$(state_dir hub)/pending.env" || break; sleep 0.25; done
    assert_false 'неподтверждённое применение снято' test -f "$(state_dir hub)/pending.env"
    pkill -f 'sleep 40' 2>/dev/null
    wait 2>/dev/null
    run hub set --mtu auto --no-apply

    (printf 'y\n'; sleep 40) | node hub script -qec 'wg-network set --mtu 1300 --confirm-timeout 120' /dev/null > "$WORK/other.log" 2>&1 &
    WAITER=$!
    for i in $(seq 1 40); do test -f "$(state_dir hub)/pending.env" && break; sleep 0.25; done
    sleep 1
    run hub confirm
    assert_rc 'confirm из другой сессии во время интерактивного ожидания' 0 "$RC" "$OUT"
    for i in $(seq 1 40); do grep -q 'подтверждена из другой сессии' "$WORK/other.log" && break; sleep 0.25; done
    assert_contains 'ожидающая сессия узнала о подтверждении' "$(cat "$WORK/other.log")" 'подтверждена из другой сессии'
    pkill -f 'sleep 40' 2>/dev/null
    wait "$WAITER" 2>/dev/null
    assert_contains 'конфигурация осталась' "$(node hub ip link show wg0)" 'mtu 1300'
    run hub set --mtu auto --yes
fi

t_section 'Ручные правки конфига защищены'
sed -i 's/^ListenPort = 51820/ListenPort = 51821/' /etc/netns/hub/wireguard/wg0.conf
run hub plan --diff
assert_contains 'plan видит ручную правку' "$OUT" 'изменён вручную'
run hub apply --yes
assert_rc 'apply отказывается перезаписать' 3 "$RC" "$OUT"
run hub apply --yes --force
assert_rc 'apply --force' 0 "$RC" "$OUT"
assert_true 'копия ручной версии сохранена' compgen -G '/var/backups/wg-network/wg0.conf.manual.*'
assert_contains 'конфиг восстановлен' "$(wg_conf hub)" 'ListenPort = 51820'
sed -i '1s/^# Generated by/# Edited by hand, generated by/' /etc/netns/hub/wireguard/wg0.conf
run hub plan
assert_rc 'правка только оформления — не изменение (код 0)' 0 "$RC" "$OUT"
assert_contains 'plan сообщает о косметической правке' "$OUT" 'без изменения смысла'
run hub apply --yes
assert_rc 'apply перезаписывает косметическую правку без --force' 0 "$RC" "$OUT"
assert_not_contains 'шапка восстановлена' "$(wg_conf hub)" 'Edited by hand'

t_section 'Параллельные операции'
node hub wg-network peer add p1 --generate --output /etc/wireguard/p1.conf --yes >"$WORK/p1.log" 2>&1 &
node hub wg-network peer add p2 --generate --output /etc/wireguard/p2.conf --yes >"$WORK/p2.log" 2>&1 &
wait
A1="$(sed -n 's/^ADDRESS=//p' "$(state_dir hub)/peers.d/p1.env")"
A2="$(sed -n 's/^ADDRESS=//p' "$(state_dir hub)/peers.d/p2.env")"
assert_true 'оба добавлены' test -n "$A1" -a -n "$A2"
assert_true "адреса различны ($A1, $A2)" test "$A1" != "$A2"
for i in 1 2 3 4 5; do
    node hub wg-network invite "par$i" --json > "$WORK/par$i.json" 2>/dev/null &
done
wait
PAR="$(cat "$WORK"/par*.json | sed -n 's/.*"address":"\([^"]*\)".*/\1/p' | sort -u | wc -l)"
assert_eq '5 параллельных invite получили 5 разных адресов' "$PAR" 5
for i in 1 2 3 4 5; do run hub peer remove "par$i" --yes; done
printf 'LOCK_WAIT=1\n' > /etc/default/wg-network
node hub flock "/etc/wireguard/wg-network/.lock.wg0" sleep 4 &
sleep 0.5
run hub peer remove p2 --yes
assert_rc 'занятая блокировка — код 5' 5 "$RC" "$OUT"
wait
rm -f /etc/default/wg-network

t_section 'Восстановление после kill -9 посреди транзакции'
# Any change creates a snapshot; then simulate kill -9 in the middle of the next change:
# tx.env is left behind and a state file is already damaged.
run hub peer set w3 --comment 'до сбоя' --yes
SNAP="$(find "$(state_dir hub)/snapshots" -name '*.tar' -printf '%f\n' | sort | tail -n 1)"
run hub peer set w3 --comment '' --yes
# The PID of the dead owner was reused by an unrelated live process.
sleep 120 &
REUSED_PID=$!
printf 'SNAPSHOT=%s\nPID=%s\nLABEL=test\n' "${SNAP%.tar}" "$REUSED_PID" > "$(state_dir hub)/tx.env"
rm -f "$(state_dir hub)/peers.d/w3.env"
run hub apply --yes
assert_contains 'обнаружена прерванная транзакция' "$OUT" 'прерванная транзакция'
assert_true 'состояние восстановлено из снимка' test -f "$(state_dir hub)/peers.d/w3.env"
assert_not_contains 'чужой процесс с тем же PID не считается владельцем' "$OUT" 'незавершённая транзакция процесса'
kill "$REUSED_PID" 2>/dev/null
wait "$REUSED_PID" 2>/dev/null

t_section 'Снимки: лимит и отклонённые операции'
printf 'SNAPSHOT_KEEP=5\n' > /etc/default/wg-network
run hub peer set w3 --comment c1 --yes
run hub peer set w3 --comment c2 --yes
assert_eq 'хранится не больше SNAPSHOT_KEEP снимков' "$(find "$(state_dir hub)/snapshots" -name '*.tar' | wc -l)" 5
SNAPS_BEFORE="$(find "$(state_dir hub)/snapshots" -name '*.tar' -printf '%f\n' | sort)"
run hub peer add dupe --key "$(sed -n 's/^PUBLIC_KEY=//p' "$(state_dir hub)/peers.d/w1.env")" --yes
assert_rc 'дубликат ключа отклонён' 3 "$RC" "$OUT"
assert_eq 'отклонённая операция не вытеснила и не добавила снимков' "$(find "$(state_dir hub)/snapshots" -name '*.tar' -printf '%f\n' | sort)" "$SNAPS_BEFORE"
rm -f /etc/default/wg-network
run hub peer set w3 --comment '' --yes
run hub peer set w3 --comment 'на откат' --yes
run hub rollback --yes
assert_rc 'rollback без аргументов — к последнему снимку' 0 "$RC" "$OUT"
assert_not_contains 'изменение отменено' "$(cat "$(state_dir hub)/peers.d/w3.env")" 'на откат'

t_section 'Откат к снимку'
run hub peer remove w3 --yes
assert_rc 'peer remove' 0 "$RC" "$OUT"
run hub history
SNAP="$(grep -o '^[0-9-]*-peer-remove' <<< "$OUT" | head -n 1)"
assert_true 'history показывает снимок peer-remove' test -n "$SNAP"
run hub rollback "$SNAP" --yes
assert_rc 'rollback SNAPSHOT' 0 "$RC" "$OUT"
assert_contains 'w3 вернулся в ядро' "$(node hub wg show wg0 peers)" "$(sed -n 's/^PUBLIC_KEY=//p' "$(state_dir hub)/peers.d/w3.env")"
assert_true 'w3 → hub сразу после отката удаления' pings w3 10.50.0.1 3

t_section 'Отключение и включение peer'
run hub peer disable w2 --yes
assert_not_contains 'w2 убран из ядра' "$(node hub wg show wg0 peers)" "$(sed -n 's/^PUBLIC_KEY=//p' "$(state_dir hub)/peers.d/w2.env")"
run hub peer enable w2 --yes
assert_true 'w2 работает сразу после enable' pings w2 10.50.0.1 3

t_section 'Защита чужих VPN и локальных сетей'
printf '[Interface]\nPrivateKey = %s\n' "$(node w1 wg genkey)" > /etc/netns/w1/wireguard/wg9.conf
run w1 -i wg9 init hub --endpoint 192.0.2.11 --port 51999 --address 10.70.0.1/24 --yes
assert_rc 'чужой wg9.conf не перезаписывается' 3 "$RC" "$OUT"
assert_not_contains 'файл не тронут' "$(cat /etc/netns/w1/wireguard/wg9.conf)" 'wg-network'
node w1 ip link add wg8 type wireguard
run w1 -i wg8 init hub --endpoint 192.0.2.11 --port 51998 --address 10.71.0.1/24 --yes
assert_rc 'чужой интерфейс wg8 не захватывается' 3 "$RC" "$OUT"
run hub invite lan --routes 192.0.2.0/24
assert_rc 'маршрут, перекрывающий LAN сервера, заблокирован' 3 "$RC" "$OUT"
run hub init hub --endpoint 192.0.2.1 --port 51820
assert_rc 'повторный init без --force запрещён' 3 "$RC" "$OUT"

t_section 'Предохранитель SSH: настоящие TCP-сессии (обнаружение через ss, без SSH_CONNECTION)'
# A fake sshd: a copy of python3 named sshd, so ss -p shows "sshd" listening on port 2222.
cp -L "$(command -v python3)" "$WORK/sshd"
SSHD_PY='import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[1]))); s.listen(16); conns=[]
while True:
    c,_=s.accept(); conns.append(c)'
CLIENT_PY='import socket,sys,time
s=socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=10); time.sleep(900)'
# Background processes carry a marker argument: killing $! would only kill the wrapping
# subshell and leave the process (and its TCP session) alive.
node hub "$WORK/sshd" -c "$SSHD_PY" 2222 wgn-e2e-sshd &
sleep 0.5
node admin python3 -c "$CLIENT_PY" 192.0.2.1 2222 wgn-e2e-client &
sleep 0.5
assert_contains 'сессия администратора видна на hub' "$(node hub ss -Htn state established '( sport = :2222 )')" '203.0.113.7'
run hub peer set w1 --routes 203.0.113.0/24 --yes
assert_rc 'маршрут к сети администратора заблокирован (сессия найдена через ss)' 3 "$RC" "$OUT"
assert_contains 'названа реальная сессия' "$OUT" '203.0.113.7'
node w1 python3 -c "$CLIENT_PY" 10.50.0.1 2222 wgn-e2e-client &
sleep 0.5
run hub set --mtu 1300
assert_contains 'перезапуск под SSH-сессией через wg0 без TTY не применяется' "$OUT" 'не применены'
assert_contains 'предупреждение о сессии через туннель' "$OUT" 'идёт через wg0'
run hub set --mtu auto --no-apply
run hub peer disable w1 --yes
assert_rc 'отключение peer с активной SSH-сессией заблокировано' 3 "$RC" "$OUT"
kill_marked wgn-e2e-client
sleep 0.5

t_section 'Site-to-site: локальная сеть офиса за peer'
onboard hub office --routes 192.168.10.0/24
node office sysctl -q -w net.ipv4.ip_forward=1
ip -n hub link add svc0 type dummy
ip -n hub addr add 172.31.255.1/32 dev svc0
ip -n hub link set svc0 up
run office peer set hub --routes 10.50.0.0/24,172.31.255.1/32 --yes
assert_rc 'office: маршрут к сервисному адресу hub' 0 "$RC" "$OUT"
run w1 peer set hub --routes 10.50.0.0/24,192.168.10.0/24 --yes
assert_rc 'w1: маршрут в сеть офиса' 0 "$RC" "$OUT"
assert_true 'w1 → хост в сети офиса (через hub и office)' pings w1 192.168.10.10 10
assert_true 'хост офиса → w1' pings officelan 10.50.0.2 5
# A session to a service address of the hub (not a wg0 address) whose replies leave through
# wg0: removing office would cut it although its local address is unrelated to the tunnel.
node officelan python3 -c "$CLIENT_PY" 172.31.255.1 2222 wgn-e2e-client &
sleep 1
run hub peer remove office --yes
assert_rc 'удаление peer, через который идут ответы SSH-клиенту, заблокировано' 3 "$RC" "$OUT"
kill_marked wgn-e2e-client
kill_marked wgn-e2e-sshd
sleep 0.5

t_section 'Exit node: NAT и full tunnel'
run hub set --nat eth0 --yes
assert_rc 'set --nat eth0' 0 "$RC" "$OUT"
assert_not_contains 'без затронутых SSH-сессий --yes подтверждает сам' "$OUT" 'ждёт подтверждения'
assert_contains 'MASQUERADE установлен' "$(node hub iptables -t nat -S POSTROUTING)" 'MASQUERADE'
onboard hub full --full-tunnel
assert_true 'full → hub' pings full 10.50.0.1 10
assert_contains 'весь трафик full идёт в туннель' "$(node full ip route get 198.51.100.10)" 'dev wg0'
WEB_PY='import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 8080)); s.listen(4); c,a=s.accept(); open(sys.argv[1],"w").write(a[0])'
node web python3 -c "$WEB_PY" "$WORK/web.peer" &
WEB_PID=$!
sleep 0.5
node full python3 -c 'import socket; socket.create_connection(("198.51.100.10", 8080), timeout=10)'
assert_rc 'full открыл соединение в интернет через hub' 0 $?
wait "$WEB_PID" 2>/dev/null
assert_eq 'сайт видит адрес hub (NAT), а не адрес туннеля' "$(cat "$WORK/web.peer" 2>/dev/null)" 192.0.2.1
assert_true 'underlay full не сломан (handshake с hub продолжается)' pings full 10.50.0.1 5
run hub set --nat off --yes
assert_rc 'set --nat off' 0 "$RC" "$OUT"
assert_not_contains 'MASQUERADE снят вместе со старым конфигом' "$(node hub iptables -t nat -S POSTROUTING)" 'wg-network'
assert_not_contains 'FORWARD для NAT снят' "$(node hub iptables -S FORWARD)" '-o eth0'
assert_contains 'FORWARD между peer остался' "$(node hub iptables -S FORWARD)" '-i wg0 -o wg0'

t_section 'DNS-имя endpoint и повторный резолв'
printf '127.0.0.1 localhost\n192.0.2.1 hub.test\n' > /etc/netns/dnsp/hosts
run hub set --endpoint hub.test:51820 --yes
assert_rc 'endpoint hub по DNS-имени' 0 "$RC" "$OUT"
onboard hub dnsp
assert_true 'dnsp → hub по имени' pings dnsp 10.50.0.1 10
ip -n hub addr add 192.0.2.100/24 dev eth0
printf '127.0.0.1 localhost\n192.0.2.100 hub.test\n' > /etc/netns/dnsp/hosts
node dnsp iptables -I OUTPUT -d 192.0.2.1 -p udp --dport 51820 -j DROP
assert_false '«hub сменил IP» — связь пропала' pings dnsp 10.50.0.1 2
printf 'RERESOLVE_AFTER=1\n' > /etc/default/wg-network
sleep 2
run dnsp reresolve
assert_contains 'reresolve перерезолвил endpoint' "$(node dnsp wg show wg0 endpoints)" '192.0.2.100:51820'
assert_true 'связь восстановлена без ручного вмешательства' pings dnsp 10.50.0.1 5
rm -f /etc/default/wg-network
node dnsp iptables -D OUTPUT -d 192.0.2.1 -p udp --dport 51820 -j DROP
run hub set --endpoint 192.0.2.1:51820 --yes

t_section 'Сбои сети: обрыв линка, потери пакетов, смена адреса peer'
ip -n w2 link set eth0 down
assert_false 'линк w2 оборван' pings w2 10.50.0.1 2
ip -n w2 link set eth0 up
ip -n w2 route replace default via 192.0.2.254
assert_true 'после восстановления линка связь вернулась сама' pings w2 10.50.0.1 25
if node w3 tc qdisc add dev eth0 root netem loss 30% 2>/dev/null; then
    RECV="$(node w3 ping -c 20 -i 0.2 -W 1 10.50.0.1 2>/dev/null | sed -n 's/.* \([0-9]*\) received.*/\1/p')"
    assert_true "при потере 30% пакетов туннель работает (получено ${RECV:-0}/20)" test "${RECV:-0}" -gt 5
    node w3 tc qdisc del dev eth0 root
else
    echo '  (netem недоступен — тест потерь пропущен)'
fi
ip -n w3 addr flush dev eth0
ip -n w3 addr add 192.0.2.113/24 dev eth0
ip -n w3 route add default via 192.0.2.254
assert_true 'w3 после смены адреса работает' pings w3 10.50.0.1 10
assert_contains 'hub узнал новый адрес peer (роуминг)' "$(node hub wg show wg0 endpoints)" '192.0.2.113:'

t_section 'Ядро разошлось с конфигом (wg set в обход) → apply выравнивает'
W2KEY="$(sed -n 's/^PUBLIC_KEY=//p' "$(state_dir hub)/peers.d/w2.env")"
node hub wg set wg0 peer "$W2KEY" remove
run hub doctor
assert_contains 'doctor видит расхождение' "$OUT" 'отличаются от конфига'
run hub plan
assert_rc 'plan показывает синхронизацию (код 10)' 10 "$RC" "$OUT"
run hub apply --yes
assert_rc 'apply' 0 "$RC" "$OUT"
assert_contains 'peer вернулся в ядро' "$(node hub wg show wg0 peers)" "$W2KEY"
assert_true 'w2 снова работает' pings w2 10.50.0.1 20

t_section 'Неудачный откат не выдаётся за успех'
touch /etc/netns/hub/wireguard/.fail-up
run hub set --mtu 1360 --yes
assert_rc 'код 1, а не 4: прежнюю конфигурацию поднять не удалось' 1 "$RC" "$OUT"
assert_contains 'честное сообщение' "$OUT" 'восстановить не удалось'
assert_not_contains 'нет ложного «восстановлена»' "$OUT" 'прежняя конфигурация восстановлена'
assert_contains 'в аудите rollback-failed' "$(cat /etc/netns/hub/wireguard/.audit.log)" 'rollback-failed'
assert_not_contains 'желаемое состояние возвращено' "$(cat "$(state_dir hub)/node.env")" 'MTU=1360'
rm -f /etc/netns/hub/wireguard/.fail-up
run hub apply --start --yes
assert_rc 'после устранения причины apply --start поднимает интерфейс' 0 "$RC" "$OUT"
assert_true 'туннели снова работают' pings w1 10.50.0.1 25

t_section 'Ротация preshared key без переинициализации'
NEWPSK="$(node hub wg-network peer set w1 --rotate-psk --yes 2>/dev/null)"
# shellcheck disable=SC2016  # expanded by the inner bash
assert_true 'rotate-psk печатает в stdout только ключ' bash -c '[[ $1 =~ ^[A-Za-z0-9+/]{43}=$ ]]' _ "$NEWPSK"
OUT="$(printf '%s\n' "$NEWPSK" | node w1 wg-network peer set hub --psk-file - --yes 2>&1)"
assert_rc 'peer set hub --psk-file - (ключ через stdin)' 0 $? "$OUT"
assert_eq 'PSK на w1 совпадает с hub' "$(node w1 wg show wg0 preshared-keys | awk '{print $2}')" "$NEWPSK"
node w1 systemctl restart wg-quick@wg0.service
assert_true 'новый handshake с новым PSK' pings w1 10.50.0.1 15
run w1 peer set hub --psk-file /nonexistent --yes
assert_rc '--psk-file: нечитаемый файл — код 2' 2 "$RC" "$OUT"
OUT="$(printf 'not-a-key\n' | node w1 wg-network peer set hub --psk-file - --yes 2>&1)"
assert_rc '--psk-file: не ключ — код 2' 2 $? "$OUT"

t_section 'Ожидание handshake'
GHOST="$(node hub wg genkey | node hub wg pubkey)"
run hub peer add ghost --key "$GHOST" --wait 2 --yes
assert_rc 'нет handshake за отведённое время — код 6' 6 "$RC" "$OUT"
assert_contains 'честное сообщение об отсутствии связи' "$OUT" 'не произошёл'
run hub peer remove ghost --yes

t_section 'deploy: подключение сервера по SSH одной командой'
# The SSH transport is replaced: ssh runs the command in the node's netns (stdin passes
# through); real wg-network runs on both sides. Real OpenSSH is covered by tests/systemd.sh.
mkdir -p "$WORK/sshbin"
cat > "$WORK/sshbin/ssh" <<'EOF'
#!/bin/bash
while [[ $1 == -o ]]; do shift 2; done
host=${1#*@}
shift
exec ip netns exec "$host" env WGN_BOOT_ID=boot-1 WGN_UNSAFE_TRUST_HOME=1 NO_COLOR=1 bash -c "$*"
EOF
chmod +x "$WORK/sshbin/ssh"
OUT="$(node hub env PATH="$WORK/sshbin:$PATH" wg-network deploy r1 root@r1 --wait 20 --yes 2>&1)"
assert_rc 'deploy r1' 0 $? "$OUT"
assert_contains 'deploy дождался handshake' "$OUT" 'соединение с'
assert_true 'r1 → hub' pings r1 10.50.0.1 5
assert_true 'на r1 токен не попал в аудит и argv (он шёл через stdin)' bash -c "! grep -q wgn1 /etc/netns/r1/wireguard/.audit.log"
OUT="$(node hub env PATH="$WORK/sshbin:$PATH" wg-network deploy r2 root@nohost --yes 2>&1)"
assert_rc 'deploy на недоступный узел — ошибка' 1 $? "$OUT"
assert_true 'резервация снята после неудачи' test ! -e "$(state_dir hub)/peers.d/r2.env"
OUT="$(node hub env PATH="$WORK/sshbin:$PATH" wg-network deploy r3 root@r1 --install --yes 2>&1)"
assert_rc 'deploy --install без интернета — честная ошибка' 1 $? "$OUT"
assert_contains 'сообщение о снятой резервации' "$OUT" 'снимаю резервацию'
assert_true 'резервация снята после неудачной установки' test ! -e "$(state_dir hub)/peers.d/r3.env"
run hub self-update
assert_rc 'self-update без доступа к GitHub — ошибка, текущая версия не тронута' 1 "$RC" "$OUT"
assert_true 'установленная версия на месте' test -x /opt/wg-network/wg-network

t_section 'Токен через stdin, JSON для автоматизации'
run hub invite tk --json
assert_true 'invite --json — валидный JSON' python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["token"].startswith("wgn1.")' "$OUT"
TK_TOKEN="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["token"])' "$OUT")"
OUT="$(printf '%s\n' "$TK_TOKEN" | node tk wg-network join - --json --yes 2>/dev/null)"
assert_true 'join - --json: ключ и результат applied' python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["result"]=="applied" and len(d["public_key"])==44' "$OUT"
TK_KEY="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["public_key"])' "$OUT")"
OUT="$(node hub wg-network peer add tk --key "$TK_KEY" --wait 15 --json --yes 2>/dev/null)"
assert_true 'peer add --json --wait: handshake true' python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["handshake"] is True and d["result"]=="applied"' "$OUT"
OUT="$(node tk wg-network join "$TK_TOKEN" --force -n 2>&1)"
assert_contains 'токен в argv — предупреждение' "$OUT" 'виден другим пользователям'
assert_not_contains 'dry-run join не печатает peer add с ключом песочницы' "$OUT" 'peer add'

t_section 'init peer вручную (без токена)'
HUBKEY="$(node hub wg-network public-key)"
run mp init peer --name mp --address 10.50.0.250 --hub-key "$HUBKEY" --endpoint 192.0.2.1:51820 --routes 10.50.0.0/24 --yes
assert_rc 'init peer' 0 "$RC" "$OUT"
MP_CMD="$(grep -o 'sudo wg-network peer add .*' <<< "$OUT")"
assert_contains 'подсказка содержит --address' "$MP_CMD" '--address 10.50.0.250'
# shellcheck disable=SC2086  # the printed hint is a ready command, split into words on purpose
run hub ${MP_CMD#sudo wg-network } --yes
assert_rc 'peer add по подсказке' 0 "$RC" "$OUT"
assert_true 'mp → hub' pings mp 10.50.0.1 10

t_section '--dry-run ничего не меняет (отпечаток файлов, ядра, маршрутов, firewall)'
fingerprint() {
    fingerprint_raw "$1" | sha256sum
}
fingerprint_raw() {
    {
        find "/etc/netns/$1/wireguard" -type f ! -path '*/.systemd/*' ! -name '.audit.log' -exec sha256sum {} + | sort
        stat -c '%a %n' "/etc/netns/$1/wireguard"
        node "$1" wg showconf wg0 | grep -v '^Endpoint'
        node "$1" ip -o route
        node "$1" iptables -S
        node "$1" iptables -t nat -S
        find /etc/systemd/system -name 'wg-network*' | sort
    } 2>&1
}
run hub backup --output /etc/wireguard/hub.backup
assert_rc 'backup' 0 "$RC" "$OUT"
run hub history
DRY_SNAP="$(grep -o '^[0-9]\{8\}-[0-9]\{6\}-[a-z-]*' <<< "$OUT" | sed -n 2p)"
FP="$(fingerprint hub)"
for cmd in "init hub --endpoint 192.0.2.1 --force --mtu 1300" "set --mtu 1300" "set --forward off" "set --nat eth0" \
    "peer add zz --generate" "peer remove w1" "peer set w1 --routes 172.31.0.0/16" "peer disable w2" \
    "invite qq" "apply --start" "rollback $DRY_SNAP" "restore /etc/wireguard/hub.backup --force"; do
    # shellcheck disable=SC2086  # split into words on purpose
    run hub --dry-run $cmd
    assert_eq "dry-run: $cmd" "$(fingerprint hub)" "$FP"
done
run hub invite dryj
printf '%s\n' "$(token_of "$OUT")" > /etc/netns/w1/wireguard/dryj.token
FPW="$(fingerprint w1)"
run w1 --dry-run join --token-file /etc/wireguard/dryj.token --force
assert_eq 'dry-run join на работающем peer' "$(fingerprint w1)" "$FPW"
rm -f /etc/netns/w1/wireguard/dryj.token
run hub peer remove dryj --yes
FP="$(fingerprint hub)"
for cmd in confirm destroy reresolve self-update "backup --output /tmp/x" "deploy x y"; do
    # shellcheck disable=SC2086
    run hub --dry-run $cmd
    assert_rc "команда без поддержки dry-run отклоняет флаг: $cmd" 2 "$RC" "$OUT"
done
assert_eq 'отклонённые команды ничего не изменили' "$(fingerprint hub)" "$FP"

t_section 'Негативные и граничные входы CLI (код выхода и отсутствие изменений)'
touch /etc/netns/hub/wireguard/exists.conf
FPN="$(fingerprint hub)"
fingerprint_raw hub > "$WORK/fp.before"
HUBPUB="$(node hub wg-network public-key)"
W1PUB="$(sed -n 's/^PUBLIC_KEY=//p' "$(state_dir hub)/peers.d/w1.env")"
GOODKEY="$(node hub wg genkey | node hub wg pubkey)"
while IFS='|' read -r expect args; do
    [[ -n $expect && $expect != \#* ]] || continue
    # shellcheck disable=SC2086  # split into words on purpose
    eval "set -- $args"
    run hub "$@"
    assert_rc "[$expect] wg-network $args" "$expect" "$RC" "$OUT"
done <<CASES
2|bogus-command
2|-i 'bad!name' status
2|--confirm-timeout x status
2|init hub --endpoint 192.0.2.1 --port 0 --force
2|init hub --endpoint 'x;y' --force
2|init hub --endpoint
2|init hub --endpoint 192.0.2.1 --address 10.50.0.0/24 --force
2|init hub --endpoint 192.0.2.1 --address6 zz --force
2|init hub --endpoint 192.0.2.1 --mtu 100 --force
2|init hub --endpoint 192.0.2.1 --table 254 --force
2|init hub --endpoint 192.0.2.1 --name ../x --force
2|init hub --endpoint 192.0.2.1 --nat nosuchif --force
2|init hub --endpoint 192.0.2.1 --bogus
3|init hub --endpoint 192.0.2.1
2|invite
2|invite ../x
2|invite x --keepalive x
2|invite x --comment 'a\$b'
2|invite x --address 10.99.0.5
2|invite x --address 10.50.0.1
2|invite x --address 10.50.0.2
2|invite x --routes 10.0.0.5/8
2|invite x --routes 10.50.0.128/25
2|invite x --routes 0.0.0.0/0
3|invite w1
3|invite x --full-tunnel
2|peer add
2|peer add x
2|peer add x --key $GOODKEY --generate
2|peer add x --key bad
2|peer add x --key $GOODKEY --endpoint nope
2|peer add x --key $GOODKEY --keepalive 70000
2|peer add x --key $GOODKEY --dns 1.1.1
2|peer add x --key $GOODKEY --output /tmp/x.conf
2|peer add x --key $GOODKEY --wait x
2|peer add x --key $HUBPUB
3|peer add x --key $W1PUB
2|peer add x --key $GOODKEY --address 10.50.0.2
2|peer add x --generate --output /etc/wireguard/exists.conf
3|peer add w1 --key $GOODKEY
2|peer remove
2|peer remove '../x'
1|peer remove nosuch
2|peer set w1
2|peer set w1 --key bad
2|peer set w1 --endpoint bad
2|peer set w1 --keepalive -1
1|peer set nosuch --keepalive 5
3|peer set w2 --key $W1PUB
1|peer disable nosuch
1|peer show nosuch
2|set
2|set --port 0
2|set --mtu 5
2|set --table 255
2|set --forward maybe
2|set --nat nosuchif
1|confirm
1|rollback 20990101-000000-nope
2|plan --bogus
2|apply --bogus
2|history extra
2|status --bogus
2|show --bogus
2|restore
2|restore /nonexistent
1|restore /etc/wireguard/exists.conf
2|deploy x
2|deploy x -oProxyCommand=touch
2|deploy x 'root@host;id'
2|deploy x root@h --remote-iface 'a b'
2|deploy x root@h --wait x
2|destroy
2|self-update --bogus
2|join 'wgn1.!!!'
2|join abc
2|join --token-file /nonexistent
CASES
fingerprint_raw hub > "$WORK/fp.after"
if cmp -s "$WORK/fp.before" "$WORK/fp.after"; then
    t_ok 'ни один отклонённый вызов ничего не изменил'
else
    t_fail 'ни один отклонённый вызов ничего не изменил' "$(diff "$WORK/fp.before" "$WORK/fp.after")"
fi
rm -f /etc/netns/hub/wireguard/exists.conf
while IFS='|' read -r expect args; do
    [[ -n $expect ]] || continue
    eval "set -- $args"
    run w1 "$@"
    assert_rc "[$expect] на peer: wg-network $args" "$expect" "$RC" "$OUT"
done <<CASES
3|invite x
3|peer add x --key $GOODKEY
3|set --forward on
3|peer remove hub
2|peer set hub --routes none
2|init peer --name x
2|init peer --name x --address 999.1.1.1 --hub-key $HUBPUB --endpoint 192.0.2.1:51820 --force
2|init peer --name x --address 10.50.0.9 --hub-key bad --endpoint 192.0.2.1:51820 --force
2|init peer --name x --address 10.50.0.9 --hub-key $HUBPUB --endpoint bad --force
2|init peer --name x --address 10.50.0.9 --hub-key $HUBPUB --endpoint 192.0.2.1:51820 --keepalive 70000 --force
2|init peer --name x --address 10.50.0.9 --hub-key $HUBPUB --endpoint 192.0.2.1:51820 --routes 10.0.0.5/8 --force
2|init peer --name x --address 10.50.0.9 --hub-key $HUBPUB --endpoint 192.0.2.1:51820 --psk-file /nonexistent --force
3|init peer --name x --address 10.50.0.9 --hub-key $HUBPUB --endpoint 192.0.2.1:51820
CASES
assert_true 'w1 по-прежнему на связи' pings w1 10.50.0.1 5

t_section 'Файловая система: нет места и только чтение'
mount -t tmpfs -o size=1m tmpfs /etc/netns/fsn/wireguard
run fsn init hub --endpoint 192.0.2.81 --address 10.90.0.1/24 --port 51830 --yes
assert_rc 'hub на маленькой ФС' 0 "$RC" "$OUT"
fsfp() {
    { find /etc/netns/fsn/wireguard -type f ! -name filler ! -path '*/.systemd/*' ! -name '.audit.log' -exec sha256sum {} + | sort
      node fsn wg showconf wg0; } 2>&1 | sha256sum
}
leftovers() { find /etc/netns/fsn/wireguard \( -name '.*.??????' -o -name '.snap.*' -o -name '.restore.*' -o -name '.wgn.*' -o -name tx.env -o -name pending.env \) -printf '%P\n'; }
FSK="$(node fsn wg genkey | node fsn wg pubkey)"
B="$(fsfp)"
dd if=/dev/zero of=/etc/netns/fsn/wireguard/filler bs=4k 2>/dev/null
run fsn peer add f1 --key "$FSK" --yes
assert_true "нет места — команда завершилась ошибкой (код $RC)" test "$RC" -ne 0
assert_eq 'состояние, конфиг и ядро не изменились' "$(fsfp)" "$B"
assert_eq 'временных файлов не осталось' "$(leftovers)" ''
rm -f /etc/netns/fsn/wireguard/filler
# A user namespace may not remount a tmpfs read-only, but a bind mount over itself can be.
mount --bind /etc/netns/fsn/wireguard /etc/netns/fsn/wireguard
mount -o remount,bind,ro /etc/netns/fsn/wireguard
run fsn peer add f1 --key "$FSK" --yes
assert_true "ФС только для чтения — ошибка (код $RC)" test "$RC" -ne 0
assert_contains 'понятная причина' "$OUT" 'не удалось'
umount /etc/netns/fsn/wireguard
assert_eq 'после ro ничего не изменилось' "$(fsfp)" "$B"
run fsn peer add f1 --key "$FSK" --routes 172.20.0.0/24 --yes
assert_rc 'после освобождения места команда проходит' 0 "$RC" "$OUT"
assert_contains 'маршрут в main' "$(node fsn ip route show dev wg0)" '172.20.0.0/24'
run fsn set --table 1234 --yes
assert_rc 'set --table 1234' 0 "$RC" "$OUT"
assert_contains 'маршруты в таблице 1234' "$(node fsn ip route show table 1234)" '172.20.0.0/24'
assert_not_contains 'и не в main' "$(node fsn ip route show dev wg0)" '172.20.0.0/24'
run fsn peer set f1 --routes 172.20.0.0/24,172.21.0.0/24 --yes
assert_contains 'горячее изменение маршрутов в своей таблице' "$(node fsn ip route show table 1234)" '172.21.0.0/24'

t_section 'Несколько интерфейсов на одном узле'
run fsn -i wg1 init hub --endpoint 192.0.2.81:51831 --port 51831 --address 10.91.0.1/24 --yes
assert_rc 'второй интерфейс wg1' 0 "$RC" "$OUT"
run fsn interfaces
assert_contains 'interfaces показывает оба' "$OUT" 'wg1'
run fsn status
assert_contains 'без -i выбирается DEFAULT_INTERFACE (wg0)' "$OUT" 'Интерфейс:  wg0'
printf 'DEFAULT_INTERFACE=wg5\n' > /etc/default/wg-network
run fsn status
assert_rc 'несколько интерфейсов без -i и без подходящего по умолчанию — ошибка' 2 "$RC" "$OUT"
rm -f /etc/default/wg-network
run fsn -i wg1 destroy --yes
assert_rc 'destroy wg1 не трогает wg0' 0 "$RC" "$OUT"
assert_true 'wg0 на fsn работает' node fsn ip link show wg0

t_section 'Остановленный администратором интерфейс не запускается сам'
node fsn systemctl disable --now wg-quick@wg0.service
assert_false 'wg0 на fsn остановлен и выключен' node fsn ip link show wg0
run fsn peer set f1 --keepalive 15 --yes
assert_rc 'изменение при остановленном интерфейсе' 0 "$RC" "$OUT"
assert_contains 'план: offline — только запись конфига' "$OUT" 'интерфейс не запускается'
assert_contains 'итог честный: записано, не запущено' "$OUT" 'записано в конфиг, интерфейс остановлен'
assert_false 'интерфейс так и остался остановлен' node fsn ip link show wg0
assert_contains 'конфиг записан' "$(wg_conf fsn)" 'PersistentKeepalive = 15'
run fsn apply --start --yes --wait-confirm --confirm-timeout 3
assert_true 'apply --start запустил интерфейс' node fsn ip link show wg0
sleep 6
assert_false 'без подтверждения — снова остановлен' node fsn ip link show wg0
assert_false 'и снова выключен из автозагрузки, как было до apply --start' node fsn systemctl is-enabled --quiet wg-quick@wg0.service
run fsn apply --start --yes
assert_rc 'запуск с подтверждением' 0 "$RC" "$OUT"
assert_true 'wg0 на fsn работает' node fsn ip link show wg0

t_section 'Неподтверждённый init не оставляет интерфейса'
run mp -i wg2 init hub --endpoint 192.0.2.95:51850 --port 51850 --address 10.92.0.1/24 --yes --wait-confirm --confirm-timeout 3
assert_rc 'init с ожиданием подтверждения' 0 "$RC" "$OUT"
assert_true 'wg2 поднят' node mp ip link show wg2
sleep 6
assert_false 'без подтверждения wg2 удалён' node mp ip link show wg2
assert_false 'конфиг wg2 удалён' test -e /etc/netns/mp/wireguard/wg2.conf
assert_false 'wg2 не в автозагрузке' node mp systemctl is-enabled --quiet wg-quick@wg2.service
run mp -i wg2 destroy --yes

t_section 'Firewall: UFW и firewalld (заглушки команд)'
FWPATH="$HERE/stubs-fw:$PATH"
OUT="$(node fsn env PATH="$FWPATH" wg-network set --port 51832 --yes 2>&1)"
assert_rc 'set --port при активном UFW' 0 $? "$OUT"
assert_contains 'порт открыт в UFW' "$(cat /etc/netns/fsn/wireguard/.ufw.rules)" '51832/udp'
OUT="$(node fsn env PATH="$FWPATH" wg-network doctor 2>&1)"
assert_contains 'doctor видит правило UFW' "$OUT" 'UFW разрешает UDP 51832'
: > /etc/netns/fsn/wireguard/.ufw.rules
OUT="$(node fsn env PATH="$FWPATH" wg-network doctor 2>&1)"
assert_contains 'doctor: UFW активен, порт закрыт — ошибка' "$OUT" 'не разрешён'
touch /etc/netns/fsn/wireguard/.firewalld
OUT="$(node fsn env PATH="$FWPATH" wg-network set --port 51833 --yes 2>&1)"
assert_contains 'при firewalld — подсказка, без изменений чужого firewall' "$OUT" 'firewall-cmd --permanent --add-port=51833/udp'
rm -f /etc/netns/fsn/wireguard/.firewalld /etc/netns/fsn/wireguard/.ufw.rules

t_section 'Ошибки в /etc/default/wg-network'
for bad in DEFAULT_INTERFACE='a b' DEFAULT_HUB_ADDRESS=10.0.0.0/24 DEFAULT_PORT=0 DEFAULT_KEEPALIVE=x CONFIRM_TIMEOUT=-1 \
    AUTO_APPLY=always SNAPSHOT_KEEP=0 LOCK_WAIT=x RERESOLVE_AFTER=x; do
    printf '%s\n' "$bad" > /etc/default/wg-network
    run hub status
    assert_rc "некорректный $bad — понятная ошибка" 1 "$RC" "$OUT"
    assert_contains "в сообщении указан параметр ${bad%%=*}" "$OUT" "${bad%%=*}"
done
printf 'DEFAULT_HUB_IP=10.77.0.1\nDEFAULT_PREFIX=24\nWG_INTERFACE=wg0\n' > /etc/default/wg-network
run hub status
assert_rc 'ключи прежних версий в /etc/default принимаются' 0 "$RC" "$OUT"
rm -f /etc/default/wg-network

t_section 'Токены с испорченными полями'
TK_LINES=(NAME=bt ADDRESS=10.50.0.231 "HUB_KEY=$HUBKEY" HUB_ENDPOINT=192.0.2.1:51820 ROUTES=10.50.0.1/32 KEEPALIVE=25)
for bad in 'NAME=../x' 'ADDRESS=10.50.0.999' 'HUB_KEY=bad' 'HUB_ENDPOINT=nope' 'PSK=bad' 'KEEPALIVE=70000' 'MTU=1' 'ROUTES=10.0.0.5/8' 'ROUTES='; do
    PAYLOAD="$(for l in "${TK_LINES[@]}"; do [[ ${l%%=*} == "${bad%%=*}" ]] || printf '%s\n' "$l"; done; printf '%s\n' "$bad")"
    T="wgn1.$(printf '%s' "$PAYLOAD" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
    OUT="$(printf '%s\n' "$T" | node mp wg-network join - --force -n 2>&1)"
    assert_rc "токен с $bad отклонён" 2 $? "$OUT"
done

t_section 'Масштаб: 250 peer'
run big init hub --endpoint 192.0.2.97 --address 10.100.0.1/16 --port 51840 --yes
assert_rc 'hub /16' 0 "$RC" "$OUT"
for i in $(seq 1 250); do
    printf 'PUBLIC_KEY=%s\nADDRESS=10.100.%d.%d\nENABLED=1\nPENDING=0\n' "$(head -c32 /dev/urandom | base64)" $((i / 200 + 1)) $((i % 200 + 1)) \
        > "$(state_dir big)/peers.d/s$i.env"
done
T0=$(date +%s%N)
run big apply --yes
T1=$(date +%s%N)
assert_rc 'apply 250 peer' 0 "$RC" "$OUT"
assert_eq '250 peer в ядре' "$(node big wg show wg0 peers | wc -l)" 250
assert_true "apply 250 peer за $(((T1 - T0) / 1000000)) мс (< 60 с)" test $(((T1 - T0) / 1000000)) -lt 60000
T0=$(date +%s%N)
run big peer add extra --generate --output /etc/wireguard/extra.conf --yes
T1=$(date +%s%N)
assert_rc 'peer add при 250 peer' 0 "$RC" "$OUT"
assert_true "peer add за $(((T1 - T0) / 1000000)) мс (< 30 с)" test $(((T1 - T0) / 1000000)) -lt 30000
T0=$(date +%s%N)
run big status --json
T1=$(date +%s%N)
assert_true "status --json за $(((T1 - T0) / 1000000)) мс (< 30 с)" python3 -c 'import json,sys; assert len(json.loads(sys.argv[1])["peers"])==251' "$OUT"

t_section 'Команды только для чтения'
run hub peer show w1
assert_contains 'peer show' "$OUT" 'AllowedIPs:'
run hub show
assert_contains 'show скрывает ключи' "$OUT" '(скрыто'
assert_not_contains 'приватный ключ не напечатан' "$OUT" "$(node hub wg show wg0 private-key)"
run hub show --reveal
assert_contains 'show --reveal' "$OUT" "$(node hub wg show wg0 private-key)"
run hub show --candidate
assert_rc 'show --candidate' 0 "$RC" "$OUT"
run hub interfaces
assert_contains 'interfaces' "$OUT" 'wg0'
run hub public-key
assert_eq 'public-key совпадает с ядром' "$OUT" "$(node hub wg show wg0 public-key)"
run hub peer list --json
assert_true 'peer list --json' python3 -c 'import json,sys; json.loads(sys.argv[1])' "$OUT"
run hub version
assert_contains 'version' "$OUT" 'wg-network'

t_section 'Клиент с ключами, сгенерированными на hub'
run hub peer add phone --generate --output /etc/wireguard/phone.conf --dns 1.1.1.1 --yes
assert_rc 'peer add --generate' 0 "$RC" "$OUT"
assert_eq 'клиентский конфиг 600' "$(stat -c %a /etc/netns/hub/wireguard/phone.conf)" 600
assert_not_contains 'приватный ключ клиента не хранится на hub' "$(cat "$(state_dir hub)/peers.d/phone.env")" 'PRIVATE'
sed '/^DNS/d' /etc/netns/hub/wireguard/phone.conf > /etc/netns/c1/wireguard/wg0.conf
chmod 600 /etc/netns/c1/wireguard/wg0.conf
node c1 wg-quick up wg0 >/dev/null 2>&1
assert_true 'клиент по сгенерированному конфигу подключается' pings c1 10.50.0.1

t_section 'Диагностика и JSON'
run hub doctor
assert_true "doctor без ошибок (код $RC)" test "$RC" -lt 2
assert_contains 'doctor проверяет форвардинг' "$OUT" 'форвардинг IPv4 на wg0 включён'
node hub sysctl -q -w net.ipv4.conf.wg0.forwarding=0
run hub doctor
assert_rc 'doctor находит выключенный форвардинг (код 2)' 2 "$RC" "$OUT"
node hub sysctl -q -w net.ipv4.conf.wg0.forwarding=1
run hub status --json
assert_true 'status --json — валидный JSON' python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["role"]=="hub" and d["state_valid"] is True and len(d["peers"])>=3' "$OUT"
cp "$(state_dir hub)/node.env" "$WORK/node.env.saved"
sed -i 's/^LISTEN_PORT=.*/LISTEN_PORT=abc/' "$(state_dir hub)/node.env"
run hub status --json
assert_true 'status --json при повреждённом состоянии: валидный JSON, state_valid=false' \
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state_valid"] is False and d["listen_port"] is None' "$OUT"
cp "$WORK/node.env.saved" "$(state_dir hub)/node.env"
run hub peer list
assert_contains 'peer list показывает online' "$OUT" 'online'

t_section 'Миграция состояния исходного wg-network.sh'
L=/etc/netns/legacy/wireguard
LK="$(node legacy wg genkey)"
PK="$(node legacy wg genkey | node legacy wg pubkey)"
mkdir -p "$L/wg-network/peers.d"
printf '%s\n' "$LK" > "$L/privatekey"
printf 'ROLE=hub\nHUB_IP=10.80.0.1\nPREFIX=24\nPORT=51820\nENDPOINT=192.0.2.31:51820\n' > "$L/wg-network/role.env"
printf '# peer: old1\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.80.0.2/32\n' "$PK" > "$L/wg-network/peers.d/old1.conf"
printf '[Interface]\nAddress = 10.80.0.1/24\nListenPort = 51820\nPrivateKey = %s\n\n# peer: old1\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.80.0.2/32\n' "$LK" "$PK" > "$L/wg0.conf"
chmod 600 "$L/wg0.conf" "$L/privatekey"
node legacy systemctl start wg-quick@wg0.service
IFINDEX="$(node legacy cat /sys/class/net/wg0/ifindex)"
run legacy status
assert_rc 'status запускает миграцию' 0 "$RC" "$OUT"
assert_contains 'миграция выполнена' "$OUT" 'Миграция завершена'
assert_true 'новое состояние' test -f "$(state_dir legacy)/node.env" -a -f "$(state_dir legacy)/peers.d/old1.env"
assert_eq 'интерфейс не перезапускался' "$(node legacy cat /sys/class/net/wg0/ifindex)" "$IFINDEX"
run legacy plan
assert_rc 'после миграции план пуст' 0 "$RC" "$OUT"
assert_eq 'ключ сохранён' "$(node legacy wg show wg0 private-key)" "$LK"

t_section 'Миграция первой модульной версии (peer)'
L=/etc/netns/v1legacy/wireguard
LK="$(node v1legacy wg genkey)"
HK="$(node hub wg-network public-key)"
mkdir -p "$L/wg-network"
printf '%s\n' "$LK" > "$L/privatekey"
printf 'ROLE=peer\nPEER_NAME=v1\nPEER_IP=10.50.0.999\nHUB_IP=10.50.0.1\nHUB_PUBLIC_KEY=%s\nENDPOINT=192.0.2.1:51820\n' "$HK" > "$L/wg-network/role.env"
run v1legacy plan
assert_rc 'некорректные данные прежней версии — отказ' 1 "$RC" "$OUT"
assert_contains 'отказ миграции объяснён' "$OUT" 'прежние файлы не изменены'
assert_false 'неудачная миграция не оставила полусостояния' test -e "$(state_dir v1legacy)"
assert_true 'файлы прежней версии на месте' test -f "$L/wg-network/role.env"
printf 'ROLE=peer\nPEER_NAME=v1\nPEER_IP=10.50.0.240\nHUB_IP=10.50.0.1\nHUB_PUBLIC_KEY=%s\nENDPOINT=192.0.2.1:51820\nKEEPALIVE=25\n' "$HK" > "$L/wg-network/role.env"
printf '[Interface]\nAddress = 10.50.0.240/32\nPrivateKey = %s\n\n[Peer]\nPublicKey = %s\nEndpoint = 192.0.2.1:51820\nAllowedIPs = 10.50.0.1/32\nPersistentKeepalive = 25\n' "$LK" "$HK" > "$L/wg0.conf"
chmod 600 "$L/wg0.conf" "$L/privatekey"
run v1legacy plan
assert_contains 'миграция peer' "$OUT" 'Миграция завершена'
assert_rc 'после миграции изменений нет' 0 "$RC" "$OUT"
assert_contains 'запись hub перенесена' "$(cat "$(state_dir v1legacy)/peers.d/hub.env")" "PUBLIC_KEY=$HK"

t_section 'IPv6 dual-stack'
run hub6 init hub --endpoint 192.0.2.41 --address 10.60.0.1/24 --address6 fd60::/64 --yes
assert_rc 'init hub с IPv6' 0 "$RC" "$OUT"
onboard hub6 w6
assert_true 'w6 → hub6 по IPv6' node w6 ping -6 -c 1 -w 10 fd60::1
assert_contains 'IPv6 peer выведен из IPv4' "$(cat "$(state_dir hub6)/peers.d/w6.env")" 'ADDRESS6=fd60::2'
run hub6 set --forward on --yes
run hub6 doctor
assert_contains 'doctor предупреждает: IPv6-форвардинг не включается автоматически' "$OUT" 'IPv6-форвардинг выключен'

t_section 'Смена порта hub'
run hub6 set --port 51901
assert_rc 'без подтверждения смена порта при подключённых peer отклонена' 3 "$RC" "$OUT"
run hub6 set --port 51901 --yes
assert_rc 'set --port --yes' 0 "$RC" "$OUT"
assert_eq 'hub слушает новый порт' "$(node hub6 wg show wg0 listen-port)" 51901
run w6 peer set hub --endpoint 192.0.2.41:51901 --yes
assert_rc 'peer: новый endpoint hub' 0 "$RC" "$OUT"
assert_true 'w6 снова на связи' node w6 ping -6 -c 1 -w 10 fd60::1

t_section 'backup → destroy → restore: замена сервера с теми же ключами'
run hub6 backup --output /etc/wireguard/hub6.backup
assert_rc 'backup' 0 "$RC" "$OUT"
assert_eq 'архив с правами 600' "$(stat -c %a /etc/netns/hub6/wireguard/hub6.backup)" 600
HUB6KEY="$(node hub6 wg-network public-key)"
run hub6 -i wg0 destroy
assert_rc 'destroy без подтверждения (нет TTY) отменён' 3 "$RC" "$OUT"
run hub6 -i wg0 destroy --yes
assert_rc 'destroy --yes' 0 "$RC" "$OUT"
assert_false 'интерфейс удалён' node hub6 ip link show wg0
assert_true 'архив destroy создан' compgen -G '/var/backups/wg-network/wg0-*.tar'
assert_true 'состояние удалено' test ! -e "$(state_dir hub6)"
assert_false 'w6 потерял связь' node w6 ping -6 -c 1 -w 2 fd60::1
run hub6 restore /etc/wireguard/hub6.backup --yes
assert_rc 'restore' 0 "$RC" "$OUT"
assert_eq 'тот же ключ hub' "$(node hub6 wg-network public-key)" "$HUB6KEY"
assert_true 'w6 переподключился к восстановленному hub без изменений на peer' node w6 ping -6 -c 1 -w 20 fd60::1
EVIL="$WORK/evil"
mkdir -p "$EVIL/x"
printf 'FORMAT=wgn-backup-1\n' > "$EVIL/x/meta.env"
tar -C "$EVIL/x" -cf /etc/netns/hub6/wireguard/evil.tar ./meta.env ../../../etc/passwd 2>/dev/null ||
    tar -C "$EVIL/x" -cf /etc/netns/hub6/wireguard/evil.tar ./meta.env --transform 's|meta.env|../escape|' 2>/dev/null
run hub6 restore /etc/wireguard/evil.tar --force
assert_rc 'архив с выходом за каталог отклонён' 1 "$RC" "$OUT"
ln -sf /etc/shadow "$EVIL/x/node.env"
tar -C "$EVIL/x" -cf /etc/netns/hub6/wireguard/link.tar . 2>/dev/null
run hub6 restore /etc/wireguard/link.tar --force
assert_rc 'архив с симлинком отклонён' 1 "$RC" "$OUT"
assert_contains 'причина названа' "$OUT" 'недопустимый'

t_section 'Отключение маршрутизации снимает правила firewall'
run hub set --forward off --yes
assert_rc 'set --forward off' 0 "$RC" "$OUT"
assert_not_contains 'правил wg-network в FORWARD не осталось' "$(node hub iptables -S FORWARD)" 'wg-network'
assert_not_contains 'MSS clamping снят' "$(node hub iptables -t mangle -S FORWARD)" 'wg-network'

t_section 'Временные файлы не накапливаются'
LEAKS="$(find /etc/netns/*/wireguard "$TMPDIR" -maxdepth 4 -name '.wgn.*' 2>/dev/null)"
assert_eq 'после сотен операций нет ни одного временного каталога (копий ключей)' "$LEAKS" ''

t_section 'Удаление программы не ломает туннели'
OUT="$(bash /opt/wg-network/install.sh --uninstall 2>&1)"
assert_rc 'uninstall' 0 $? "$OUT"
assert_true 'туннель работает без wg-network' pings w1 10.50.0.1
assert_true 'drop-in удалён' test ! -e /etc/systemd/system/wg-quick@wg0.service.d/wg-network.conf

t_summary
