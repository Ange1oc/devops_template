#!/usr/bin/env bash
# Integration tests with a REAL systemd (PID 1 in docker containers) and real OpenSSH.
# Run: tests/run.sh systemd   (needs docker; WGN_SYSTEMD_BASES="ubuntu:22.04 ubuntu:24.04").
#
# Covers what e2e replaces with stubs: wg-quick@.service, the transient rollback timer
# (systemd-run), the ExecStartPre drop-in across a real container restart, journald, the
# hardened wg-network-reresolve.service, deploy over ssh, install/uninstall with units.
# Containers are privileged (systemd does not start otherwise) but have their own network,
# mount and cgroup namespaces; the sources are mounted read-only.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${WGN_SRC:-$(dirname "$HERE")}"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

command -v docker >/dev/null || { echo 'docker не найден — systemd-тесты пропущены'; exit 0; }
read -ra BASES <<< "${WGN_SYSTEMD_BASES:-ubuntu:24.04}"
PREFIX="wgn-sd-$$"
COV_ARGS=()
if [[ -n ${WGN_COV_DIR-} ]]; then
    COV_ARGS=(-v "$WGN_COV_DIR:/cov" -v "$HERE/coverage/bash_env.sh:/cov-env.sh:ro")
fi

cleanup() {
    docker ps -aq --filter "name=$PREFIX" | xargs -r docker rm -f >/dev/null 2>&1
    docker network ls -q --filter "name=$PREFIX" | xargs -r docker network rm >/dev/null 2>&1
    return 0
}
trap cleanup EXIT

dexec() {
    local c=$1
    shift
    docker exec -i -e NO_COLOR=1 "${COV_ENV[@]}" "$c" "$@"
}

# drun CONTAINER ARGS...: run wg-network in a container; sets OUT and RC.
drun() {
    local c=$1
    shift
    OUT="$(dexec "$c" wg-network "$@" 2>&1 < /dev/null)"
    RC=$?
}

wait_systemd() {
    local i state
    for i in $(seq 1 60); do
        state="$(docker exec "$1" systemctl is-system-running 2>/dev/null)"
        [[ $state == running || $state == degraded ]] && return 0
        sleep 0.5
    done
    echo "systemd в $1 не запустился: $state"
    return 1
}

dping() {
    local deadline=$((SECONDS + ${3:-10}))
    while ((SECONDS < deadline)); do
        docker exec "$1" ping -c 1 -W 1 "$2" >/dev/null 2>&1 && return 0
        sleep 0.3
    done
    return 1
}

start_node() { # start_node NAME IP IMAGE NET
    docker run -d --name "$1" --hostname "${1##*-}" --privileged --cgroupns=private \
        --tmpfs /run --tmpfs /run/lock --network "$4" --ip "$2" \
        -v "$SRC:/src:ro" "${COV_ARGS[@]}" "$3" >/dev/null || return 1
    wait_systemd "$1"
    if [[ -n ${WGN_COV_DIR-} ]]; then
        # Processes started by systemd itself (ExecStartPre, timers) are traced too.
        docker exec "$1" bash -c 'mkdir -p /etc/systemd/system.conf.d &&
            printf "[Manager]\nDefaultEnvironment=BASH_ENV=/cov-env.sh WGN_COV_DIR=/cov\n" > /etc/systemd/system.conf.d/cov.conf &&
            systemctl daemon-reexec'
    fi
}

run_suite() {
    local base=$1 ver=${1#*:} net hub peer img
    img="wgn-systemd:$ver"
    net="$PREFIX-$ver"
    hub="$PREFIX-$ver-hub"
    peer="$PREFIX-$ver-peer"
    COV_ENV=()
    [[ -n ${WGN_COV_DIR-} ]] && COV_ENV=(-e BASH_ENV=/cov-env.sh -e WGN_COV_DIR=/cov)

    t_section "[$base] подготовка: образ, сеть, два узла с systemd"
    if ! docker image inspect "$img" >/dev/null 2>&1; then
        docker build -q --build-arg "BASE=$base" -t "$img" "$HERE/docker" >/dev/null || { t_fail "сборка $img"; return; }
    fi
    docker network create --subnet 172.31.250.0/24 "$net" >/dev/null
    start_node "$hub" 172.31.250.10 "$img" "$net" && start_node "$peer" 172.31.250.20 "$img" "$net"
    assert_rc 'systemd запущен в обоих контейнерах' 0 $?

    OUT="$(dexec "$hub" bash /src/install.sh --local /src 2>&1)"
    assert_rc 'install.sh на hub' 0 $? "$OUT"
    OUT="$(dexec "$peer" bash /src/install.sh --local /src 2>&1)"
    assert_rc 'install.sh на peer' 0 $? "$OUT"
    assert_true 'таймер reresolve включён' dexec "$hub" systemctl is-enabled --quiet wg-network-reresolve.timer

    t_section "[$base] hub под управлением systemd"
    drun "$hub" init hub --endpoint 172.31.250.10 --yes
    assert_rc 'init hub' 0 "$RC" "$OUT"
    assert_true 'wg-quick@wg0 активен' dexec "$hub" systemctl is-active --quiet wg-quick@wg0
    assert_true 'wg-quick@wg0 в автозагрузке' dexec "$hub" systemctl is-enabled --quiet wg-quick@wg0
    assert_contains 'drop-in подключён к юниту' "$(dexec "$hub" systemctl cat wg-quick@wg0)" 'rollback --pending --boot'
    assert_contains 'аудит в journald' "$(dexec "$hub" journalctl -t wg-network --no-pager -q)" 'init-hub'

    t_section "[$base] deploy через настоящий OpenSSH"
    dexec "$hub" bash -c 'ssh-keygen -q -t ed25519 -N "" -f /root/.ssh/id_ed25519 <<< y >/dev/null 2>&1; cat /root/.ssh/id_ed25519.pub' |
        dexec "$peer" bash -c 'install -d -m 700 /root/.ssh && cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'
    dexec "$peer" bash -c 'mkdir -p /run/sshd; systemctl start ssh 2>/dev/null || systemctl start sshd'
    drun "$hub" deploy peer root@172.31.250.20 --ssh-option StrictHostKeyChecking=accept-new --wait 20 --yes
    assert_rc 'deploy по SSH' 0 "$RC" "$OUT"
    assert_true 'peer → hub через туннель' dping "$peer" 10.50.0.1
    assert_true 'wg-quick@wg0 на peer активен' dexec "$peer" systemctl is-active --quiet wg-quick@wg0
    assert_false 'токен не попал в журнал peer' bash -c "docker exec $peer journalctl --no-pager -q | grep -q wgn1"

    t_section "[$base] настоящий таймер отката (systemd-run)"
    drun "$hub" set --mtu 1400 --yes --wait-confirm --confirm-timeout 5
    assert_rc 'применено, ждёт подтверждения' 0 "$RC" "$OUT"
    assert_contains 'transient-таймер создан' "$(dexec "$hub" systemctl list-timers --all --no-pager)" 'wg-network-rollback-wg0'
    assert_contains 'новый MTU' "$(dexec "$hub" ip link show wg0)" 'mtu 1400'
    sleep 9
    assert_contains 'таймер откатил конфигурацию' "$(dexec "$hub" ip link show wg0)" 'mtu 1420'
    assert_contains 'откат в journald' "$(dexec "$hub" journalctl -t wg-network --no-pager -q)" 'rollback mode=auto'
    assert_not_contains 'таймер удалён' "$(dexec "$hub" systemctl list-timers --all --no-pager)" 'wg-network-rollback'
    assert_true 'туннель работает после отката' dping "$peer" 10.50.0.1 20
    drun "$hub" set --mtu auto --yes

    drun "$hub" set --mtu 1400 --yes --wait-confirm --confirm-timeout 30
    drun "$hub" confirm
    assert_rc 'confirm' 0 "$RC" "$OUT"
    assert_not_contains 'confirm остановил таймер' "$(dexec "$hub" systemctl list-timers --all --no-pager)" 'wg-network-rollback'
    drun "$hub" set --mtu auto --yes

    t_section "[$base] настоящая перезагрузка до подтверждения"
    drun "$hub" set --mtu 1360 --yes --wait-confirm --confirm-timeout 600
    assert_contains 'новый MTU применён' "$(dexec "$hub" ip link show wg0)" 'mtu 1360'
    # Containers share boot_id with the host kernel, so a new boot is marked explicitly.
    # shellcheck disable=SC2016  # expanded by the container shell
    dexec "$hub" bash -c 'mkdir -p /etc/systemd/system.conf.d && printf "[Manager]\nDefaultEnvironment=WGN_BOOT_ID=boot-2%s\n" "${BASH_ENV:+ BASH_ENV=/cov-env.sh WGN_COV_DIR=/cov}" > /etc/systemd/system.conf.d/zz-boot.conf'
    docker restart "$hub" >/dev/null
    wait_systemd "$hub"
    local i
    for i in $(seq 1 20); do dexec "$hub" systemctl is-active --quiet wg-quick@wg0 && break; sleep 0.5; done
    assert_true 'после перезагрузки wg-quick@wg0 поднялся' dexec "$hub" systemctl is-active --quiet wg-quick@wg0
    assert_contains 'при загрузке поднят прежний конфиг' "$(dexec "$hub" ip link show wg0)" 'mtu 1420'
    assert_contains 'откат при загрузке в journald' "$(dexec "$hub" journalctl -t wg-network --no-pager -q)" 'rollback mode=boot'
    assert_false 'неподтверждённое применение снято' dexec "$hub" test -f /etc/wireguard/wg-network/wg0/pending.env
    assert_true 'peer снова на связи' dping "$peer" 10.50.0.1 30

    t_section "[$base] захардненный wg-network-reresolve.service"
    dexec "$hub" systemctl start wg-network-reresolve.service
    assert_eq 'сервис отработал под ProtectSystem=strict' "$(dexec "$hub" systemctl show -p Result --value wg-network-reresolve.service)" success
    drun "$hub" doctor
    assert_true "doctor без ошибок (код $RC)" test "$RC" -lt 2

    t_section "[$base] uninstall оставляет туннели"
    OUT="$(dexec "$hub" bash /opt/wg-network/install.sh --uninstall 2>&1)"
    assert_rc 'uninstall' 0 $? "$OUT"
    assert_false 'drop-in удалён' dexec "$hub" test -e /etc/systemd/system/wg-quick@wg0.service.d/wg-network.conf
    assert_false 'таймер reresolve удалён' dexec "$hub" systemctl is-enabled --quiet wg-network-reresolve.timer
    assert_true 'wg-quick@wg0 работает без wg-network' dexec "$hub" systemctl is-active --quiet wg-quick@wg0
    assert_true 'туннель работает' dping "$peer" 10.50.0.1 10
    docker rm -f "$hub" "$peer" >/dev/null 2>&1
    docker network rm "$net" >/dev/null 2>&1
}

for base in "${BASES[@]}"; do
    run_suite "$base"
done
t_summary
