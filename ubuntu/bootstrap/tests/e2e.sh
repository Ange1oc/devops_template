#!/usr/bin/env bash
# E2E scenarios in Ubuntu containers with systemd as PID 1 and real sshd, ufw, fail2ban and apt.
#
#   tests/e2e.sh [--version 24.04] [--only NAME[,NAME]] [--keep] [--coverage]
#
# Containers are privileged (ufw/iptables, docker-in-docker); the host is never modified.
# Real behaviour is exercised: ssh logins from the host, fail2ban bans, container restart as "reboot".

# shellcheck disable=SC2016  # container commands and expected strings are passed literally
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(dirname "$HERE")"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

VERSIONS=${UBUNTU_VERSIONS:-24.04}
ONLY=''
KEEP=0
COVERAGE=0
while (($#)); do
    case $1 in
        --version) VERSIONS=$2; shift 2 ;;
        --only) ONLY=$2; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --coverage) COVERAGE=1; shift ;;
        *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
    esac
done
command -v docker >/dev/null || { echo 'нужен docker' >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ubb-e2e.XXXXXX")"
# Outside the source tree: /src is mounted read-only into containers and must not change during a run.
COV_DIR=${UBB_COV_DIR:-${TMPDIR:-/tmp}/ubuntu-bootstrap-coverage}
RUN_TAG="ubb$$"
declare -a BOXES=()
cleanup() {
    local b
    if ((KEEP == 0)); then
        for b in "${BOXES[@]}"; do docker rm -fv "$b" >/dev/null 2>&1; done
        docker network rm "net-$RUN_TAG" >/dev/null 2>&1
    else
        echo "контейнеры оставлены: ${BOXES[*]}"
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$WORK/key" -C e2e@host
PUBKEY="$(cat "$WORK/key.pub")"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/badkey" -C bad@host
HOST_UID=$(id -u)

# ---- containers -------------------------------------------------------------------------------

img_build() {
    local v=$1
    docker image inspect "ubb-test:$v" >/dev/null 2>&1 && [[ -z ${UBB_REBUILD-} ]] && return 0
    echo "==> сборка образа ubb-test:$v"
    docker build -q --build-arg "UBUNTU_VERSION=$v" -t "ubb-test:$v" -f "$HERE/docker/Dockerfile" "$HERE/docker" >/dev/null || { echo 'сборка образа не удалась' >&2; exit 2; }
}

# box_start NAME VERSION: a systemd container with the sources at /src (ro) and ports 22/2222/2200
# published on 127.0.0.1. The name is returned in BOX, not via $(...), so BOXES survives for cleanup.
box_start() {
    local name="$1-$RUN_TAG" v=$2 i
    docker rm -fv "$name" >/dev/null 2>&1
    # Docker Desktop occasionally fails to bind-mount on the first attempt.
    for i in 1 2 3; do
        docker run -d --name "$name" --hostname "$1" --privileged --cgroupns=private \
            --network "net-$RUN_TAG" \
            --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
            --mount type=volume,dst=/var/lib/docker --mount type=volume,dst=/var/lib/containerd \
            -v "$SRC:/src:ro" -v "$WORK:/e2e:ro" ${COVERAGE:+-v "$COV_DIR:/cov"} \
            -p 127.0.0.1::22 -p 127.0.0.1::2222 -p 127.0.0.1::2200 \
            "ubb-test:$v" >/dev/null 2>"$WORK/run.err" && break
        docker rm -fv "$name" >/dev/null 2>&1
        ((i == 3)) && { cat "$WORK/run.err" >&2; echo "не удалось запустить $name" >&2; exit 2; }
        sleep 3
    done
    BOXES+=("$name")
    for i in $(seq 1 40); do
        [[ $(docker exec "$name" systemctl is-system-running 2>/dev/null) =~ ^(running|degraded)$ ]] && break
        sleep 1
    done
    docker exec "$name" bash -c 'ssh-keygen -A >/dev/null 2>&1; systemctl restart ssh.socket 2>/dev/null || systemctl restart ssh; ufw --force reset >/dev/null 2>&1; true'
    BOX=$name
}

box() { docker exec "$@"; }
boxq() { docker exec "$1" bash -c "$2" 2>&1; }
box_port() { docker port "$1" "$2/tcp" | head -1 | awk -F: '{ print $NF }'; }
box_ip() { docker inspect -f "{{(index .NetworkSettings.Networks \"net-$RUN_TAG\").IPAddress}}" "$1"; }

# ubb BOX ARGS: ubuntu-bootstrap inside the container (under kcov with --coverage).
UBB_N=0
ubb() {
    local b=$1
    shift
    if ((COVERAGE)) && docker exec "$b" test -x /usr/bin/kcov; then
        # One directory per call: ubb often runs in subshells where a counter would not persist.
        docker exec "$b" kcov --include-path=/opt/ubuntu-bootstrap --exclude-pattern=/tests/,/.install \
            "/cov/e2e-$b-$(date +%s%N)" /opt/ubuntu-bootstrap/ubuntu-bootstrap --no-color "$@" 2>&1
    else
        docker exec "$b" ubuntu-bootstrap --no-color "$@" 2>&1
    fi
}

# ssh calls are wrapped in `timeout`: a fail2ban REJECT on an established connection is a soft error
# for TCP and the client would otherwise wait indefinitely during the handshake.
ssh_box() {
    local b=$1 port=$2 user=$3
    shift 3
    timeout 40 ssh -i "$WORK/key" -p "$(box_port "$b" "$port")" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR "$user@127.0.0.1" "$@" 2>&1
}

# Authentication methods sshd offers after a rejected key: "publickey" or "publickey,password".
ssh_auth_methods() {
    local b=$1 port=$2 user=$3 out
    out="$(timeout 20 ssh -i "$WORK/badkey" -p "$(box_port "$b" "$port")" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes "$user@127.0.0.1" true 2>&1)"
    grep -oE 'denied \([a-z,-]+\)' <<< "$out" | tr -d '()' | sed 's/denied //'
}

install_tool() {
    local b=$1 out
    out="$(boxq "$b" 'bash /src/install.sh --local /src')"
    assert_rc "[$b] install.sh --local" 0 $? "$out"
    assert_contains "[$b] установка сообщает версию" "$out" 'ubuntu-bootstrap 1.0.0'
}

minimal_config() {
    local b=$1
    shift
    ubb "$b" config init --profile minimal --force >/dev/null
    ubb "$b" config set ADMIN_USER=deploy "ADMIN_SSH_KEYS=$PUBKEY" ADMIN_SUDO_MODE=nopasswd BASE_UPGRADE=no \
        F2B_MAXRETRY=3 F2B_FINDTIME=2m F2B_IGNORE_CURRENT=no "$@" >/dev/null
}

# ---- scenarios --------------------------------------------------------------------------------

scn_install() {
    local b=$1 out
    t_section "[$b] установка и обслуживание инструмента"
    install_tool "$b"
    assert_true "[$b] ссылка в /usr/local/bin" box "$b" test -L /usr/local/bin/ubuntu-bootstrap
    assert_eq "[$b] recover-сервис включён" "$(boxq "$b" 'systemctl is-enabled ubuntu-bootstrap-recover.service')" enabled
    out="$(ubb "$b" version)"
    assert_contains "[$b] version видит .install" "$out" 'local-'
    out="$(ubb "$b" doctor)"; assert_true "[$b] doctor проходит (код $?)" test $? -le 1
    assert_contains "[$b] doctor: синтаксис" "$out" 'синтаксис'
    out="$(boxq "$b" 'bash /src/install.sh --local /src')"
    assert_true "[$b] повторная установка сохраняет .old" box "$b" test -d /opt/ubuntu-bootstrap.old
    out="$(boxq "$b" '/opt/ubuntu-bootstrap/install.sh --rollback')"
    assert_rc "[$b] install.sh --rollback" 0 $? "$out"
    assert_true "[$b] после отката инструмент работает" box "$b" ubuntu-bootstrap version
    out="$(boxq "$b" 'bash /src/install.sh --ref "bad..ref"')"
    assert_rc "[$b] install.sh отклоняет плохой --ref" 1 $? "$out"
    out="$(boxq "$b" 'bash /src/install.sh --sha256 zzz')"
    assert_rc "[$b] install.sh отклоняет плохой --sha256" 1 $? "$out"
    out="$(boxq "$b" 'mkdir -p /tmp/badsrc && cp -r /src/. /tmp/badsrc/ && echo "if then" >> /tmp/badsrc/lib/core.sh && bash /src/install.sh --local /tmp/badsrc')"
    assert_rc "[$b] install.sh отказывается ставить дерево с синтаксической ошибкой" 1 $? "$out"
    assert_contains "[$b] причина: синтаксис" "$out" 'синтаксическая ошибка'
    assert_true "[$b] рабочая копия не повреждена" box "$b" ubuntu-bootstrap version
    out="$(ubb "$b" modules)"
    assert_contains "[$b] modules перечисляет ssh" "$out" 'SSH hardening'
    out="$(ubb "$b" audit)"; assert_true "[$b] audit на свежей системе выполняется (код $?)" test $? -le 2
}

scn_fresh_minimal() {
    local b=$1 out port
    t_section "[$b] чистый сервер -> профиль minimal (неинтерактивно)"
    minimal_config "$b"
    out="$(ubb "$b" plan)"
    assert_rc "[$b] plan" 0 $? "$out"
    assert_contains "[$b] plan показывает запись sshd-конфига" "$out" '[dry-run] запись /etc/ssh/sshd_config.d/00-ubuntu-bootstrap.conf'
    assert_contains "[$b] plan показывает diff" "$out" '+PasswordAuthentication no'
    assert_true "[$b] plan ничего не записал" box "$b" test ! -e /etc/ssh/sshd_config.d/00-ubuntu-bootstrap.conf
    assert_eq "[$b] plan не создаёт пользователя" "$(boxq "$b" 'id -u deploy 2>/dev/null || echo none')" none
    out="$(ubb "$b" status)"; assert_rc "[$b] status до применения -> 1" 1 $? "$out"

    out="$(ubb "$b" apply --yes)"
    assert_rc "[$b] apply minimal" 0 $? "$out"
    assert_contains "[$b] все модули применены" "$out" 'применено:   preflight base time users ssh firewall fail2ban updates journald'
    assert_eq "[$b] deploy создан" "$(boxq "$b" 'id -nG deploy')" 'deploy sudo'
    assert_eq "[$b] authorized_keys установлен" "$(boxq "$b" 'cat /home/deploy/.ssh/authorized_keys')" "$PUBKEY"
    assert_eq "[$b] права authorized_keys" "$(boxq "$b" 'stat -c %a:%U /home/deploy/.ssh/authorized_keys')" '600:deploy'
    assert_true "[$b] visudo принимает NOPASSWD-файл" box "$b" visudo -cf /etc/sudoers.d/90-ubuntu-bootstrap-deploy
    assert_eq "[$b] sshd: пароли запрещены" "$(boxq "$b" 'sshd -T | grep -E "^passwordauthentication "')" 'passwordauthentication no'
    assert_eq "[$b] sshd: root запрещён (есть админ с ключом и sudo)" "$(boxq "$b" 'sshd -T | grep -E "^permitrootlogin "')" 'permitrootlogin no'
    assert_eq "[$b] реальный вход по ключу deploy@22" "$(ssh_box "$b" 22 deploy 'sudo -n id -u')" 0
    assert_eq "[$b] пароль не предлагается" "$(ssh_auth_methods "$b" 22 root)" publickey
    assert_contains "[$b] ufw активен, SSH limit" "$(boxq "$b" 'ufw status')" '22/tcp                     LIMIT       Anywhere'
    assert_contains "[$b] ufw deny incoming" "$(boxq "$b" 'ufw status verbose')" 'Default: deny (incoming)'
    assert_eq "[$b] fail2ban активен" "$(boxq "$b" 'systemctl is-active fail2ban')" active
    assert_contains "[$b] jail sshd на порту 22" "$(boxq "$b" 'fail2ban-client get sshd actions >/dev/null; grep ^port /etc/fail2ban/jail.d/ubuntu-bootstrap.local')" 'port = 22'
    assert_eq "[$b] unattended: periodic" "$(boxq "$b" 'apt-config dump | grep -c "APT::Periodic::Unattended-Upgrade \"1\""')" 1
    assert_true "[$b] journald persistent" box "$b" test -d /var/log/journal
    out="$(ubb "$b" status)"; assert_rc "[$b] status после применения -> 0" 0 $? "$out"
    out="$(ubb "$b" audit)"; assert_true "[$b] audit без критичных проблем (код $?)" test $? -le 1
    assert_contains "[$b] audit: вход по паролю запрещён" "$out" 'вход по паролю запрещён'
    assert_contains "[$b] history содержит запуск" "$(ubb "$b" history)" 'done'
    assert_eq "[$b] без ожидающих подтверждения" "$(boxq "$b" 'test -f /var/lib/ubuntu-bootstrap/pending.env && echo pending || echo none')" none
    assert_true "[$b] бэкапы созданы" bash -c "[[ -n \$(docker exec '$b' ls /var/backups/ubuntu-bootstrap/) ]]"
}

scn_fail2ban_real() {
    local b=$1 i st
    t_section "[$b] fail2ban банит реальные неудачные входы"
    sleep 30 # ufw limit: at most 6 new connections per 30 s from one IP
    for i in 1 2 3 4; do ssh_auth_methods "$b" 22 nouser >/dev/null; done
    for i in $(seq 1 15); do
        st="$(boxq "$b" 'fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | tr -dc 0-9')"
        st=${st//[^0-9]/}
        [[ ${st:-0} -ge 1 ]] && break
        sleep 1
    done
    assert_true "[$b] IP хоста забанен после 3 попыток (банов: $st)" test "${st:-0}" -ge 1
    assert_contains "[$b] journalmatch видит sshd" "$(boxq "$b" 'fail2ban-client get sshd journalmatch')" 'ssh.service'
    boxq "$b" 'fail2ban-client unban --all' >/dev/null
    # ufw limit window is 30 s; wait until it lets us in again.
    local got=''
    for i in 1 2 3 4; do
        sleep 20
        got="$(ssh_box "$b" 22 deploy 'echo back')"
        [[ $got == back ]] && break
    done
    assert_eq "[$b] после unban вход снова работает" "$got" back
}

scn_idempotent() {
    local b=$1 out
    t_section "[$b] повторный запуск: идемпотентность"
    out="$(ubb "$b" apply --yes)"
    assert_rc "[$b] второй apply" 0 $? "$out"
    assert_contains "[$b] заново выполняется только preflight" "$out" 'применено:   preflight'$'\n'
    assert_contains "[$b] модули пропущены как актуальные" "$out" 'пропущено:   base time users ssh firewall fail2ban updates journald'
    out="$(ubb "$b" apply --reapply --yes)"
    assert_rc "[$b] --reapply" 0 $? "$out"
    assert_not_contains "[$b] --reapply не меняет файлы" "$out" 'файлы ('
    assert_eq "[$b] reapply не дублирует ключи" "$(boxq "$b" 'grep -c . /home/deploy/.ssh/authorized_keys')" 1
    out="$(ubb "$b" plan)"
    assert_not_contains "[$b] plan без изменений" "$out" '[dry-run] запись'
    assert_eq "[$b] один файл sshd_config.d" "$(boxq "$b" 'ls /etc/ssh/sshd_config.d/ | grep -c ubuntu-bootstrap')" 1
}

scn_ssh_port_change() {
    local b=$1 out
    t_section "[$b] смена SSH-порта 22 -> 2222 с автоподтверждением"
    ubb "$b" config set SSH_PORT=2222 >/dev/null
    out="$(ubb "$b" apply --yes)"
    assert_rc "[$b] apply со сменой порта" 0 $? "$out"
    assert_contains "[$b] самопроверка подтвердила" "$out" 'самопроверка пройдена'
    assert_contains "[$b] fail2ban переприменён (порт изменился)" "$out" 'fail2ban'
    assert_eq "[$b] sshd слушает 2222" "$(boxq "$b" 'sshd -T | awk "/^port /{print \$2}"')" 2222
    assert_eq "[$b] вход по ssh на 2222" "$(ssh_box "$b" 2222 deploy 'echo ok')" ok
    assert_eq "[$b] порт 22 закрыт в ufw" "$(boxq "$b" 'ufw status | grep -c "^22/tcp "')" 0
    assert_contains "[$b] 2222 открыт в ufw" "$(boxq "$b" 'ufw status')" '2222/tcp'
    assert_contains "[$b] fail2ban jail на 2222" "$(boxq "$b" 'grep ^port /etc/fail2ban/jail.d/ubuntu-bootstrap.local')" 'port = 2222'
    [[ $(boxq "$b" 'systemctl is-enabled ssh.socket 2>/dev/null') == enabled ]] &&
        assert_eq "[$b] ssh.socket перечитан (socket-активация)" "$(boxq "$b" 'ss -Hltn sport = :2222 | wc -l')" 2
    assert_eq "[$b] pending отсутствует" "$(boxq "$b" 'test -f /var/lib/ubuntu-bootstrap/pending.env && echo pending || echo none')" none
}

scn_ssh_pending_rollback() {
    local b=$1 out
    t_section "[$b] таймер отката без подтверждения (SSH_CONFIRM=wait)"
    out="$(ubb "$b" apply --only ssh --set SSH_PORT=2200 --set SSH_CONFIRM=wait --set SSH_CONFIRM_TIMEOUT=8 --yes)"
    assert_rc "[$b] apply wait" 0 $? "$out"
    assert_contains "[$b] сообщение про confirm" "$out" 'ubuntu-bootstrap confirm'
    assert_eq "[$b] pending создан" "$(boxq "$b" 'test -f /var/lib/ubuntu-bootstrap/pending.env && echo pending')" pending
    assert_eq "[$b] sshd временно на 2200" "$(boxq "$b" 'sshd -T | awk "/^port /{print \$2}"')" 2200
    assert_contains "[$b] старый порт 2222 открыт до подтверждения" "$(boxq "$b" 'ufw status')" '2222/tcp'
    assert_contains "[$b] таймер systemd взведён" "$(boxq "$b" 'systemctl list-timers --all --no-legend')" 'ubuntu-bootstrap-rollback-ssh'
    out="$(ubb "$b" apply --yes)"; assert_rc "[$b] apply при pending -> 5 (занято)" 5 $? "$out"
    sleep 14
    assert_eq "[$b] pending снят таймером" "$(boxq "$b" 'test -f /var/lib/ubuntu-bootstrap/pending.env && echo pending || echo none')" none
    assert_eq "[$b] sshd вернулся на 2222" "$(boxq "$b" 'sshd -T | awk "/^port /{print \$2}"')" 2222
    assert_eq "[$b] вход на 2222 после отката" "$(ssh_box "$b" 2222 deploy 'echo ok')" ok
    assert_eq "[$b] 2200 убран из ufw (undo)" "$(boxq "$b" 'ufw status | grep -c "^2200/tcp "')" 0
    assert_eq "[$b] состояние модуля rolled_back" "$(boxq "$b" 'grep ^STATUS= /var/lib/ubuntu-bootstrap/modules/ssh.env')" 'STATUS=rolled_back'
    assert_contains "[$b] journald получил событие" "$(boxq "$b" 'journalctl -t ubuntu-bootstrap --no-pager | tail -5')" 'rolled back'

    t_section "[$b] подтверждение командой confirm из «другой сессии»"
    out="$(ubb "$b" apply --only ssh --set SSH_PORT=2200 --set SSH_CONFIRM=wait --set SSH_CONFIRM_TIMEOUT=120 --yes)"
    assert_rc "[$b] apply wait (2200)" 0 $? "$out"
    out="$(ssh_box "$b" 2200 deploy 'sudo -n ubuntu-bootstrap --no-color confirm')"
    assert_contains "[$b] confirm по ssh через новый порт" "$out" 'подтверждены'
    assert_eq "[$b] pending снят" "$(boxq "$b" 'test -f /var/lib/ubuntu-bootstrap/pending.env && echo pending || echo none')" none
    assert_eq "[$b] таймер остановлен" "$(boxq "$b" 'systemctl list-timers --all --no-legend | grep -c ubuntu-bootstrap-rollback')" 0
    assert_eq "[$b] sshd остался на 2200" "$(boxq "$b" 'sshd -T | awk "/^port /{print \$2}"')" 2200
    assert_eq "[$b] старый порт 2222 закрыт после confirm" "$(boxq "$b" 'ufw status | grep -c "^2222/tcp "')" 0
    out="$(ubb "$b" apply --only ssh --yes)"
    assert_rc "[$b] возврат на 2222 по конфигу" 0 $? "$out"
    assert_eq "[$b] снова 2222" "$(ssh_box "$b" 2222 deploy 'echo ok')" ok
}

scn_reboot() {
    local b=$1 out i
    t_section "[$b] перезагрузка: pending откатывается при загрузке, сервисы живы"
    out="$(ubb "$b" apply --only ssh --set SSH_PORT=2200 --set SSH_CONFIRM=wait --set SSH_CONFIRM_TIMEOUT=900 --yes)"
    assert_rc "[$b] pending перед перезагрузкой" 0 $? "$out"
    docker restart "$b" >/dev/null
    for i in $(seq 1 40); do
        [[ $(docker exec "$b" systemctl is-system-running 2>/dev/null) =~ ^(running|degraded)$ ]] && break
        sleep 1
    done
    assert_eq "[$b] recover-сервис отработал" "$(boxq "$b" 'systemctl show ubuntu-bootstrap-recover.service -p Result --value')" success
    assert_eq "[$b] pending снят при загрузке" "$(boxq "$b" 'test -f /var/lib/ubuntu-bootstrap/pending.env && echo pending || echo none')" none
    assert_eq "[$b] sshd на 2222 после перезагрузки" "$(boxq "$b" 'sshd -T | awk "/^port /{print \$2}"')" 2222
    assert_eq "[$b] вход после перезагрузки" "$(ssh_box "$b" 2222 deploy 'echo ok')" ok
    assert_eq "[$b] ufw активен после перезагрузки" "$(boxq "$b" 'ufw status | head -1')" 'Status: active'
    assert_eq "[$b] fail2ban активен после перезагрузки" "$(boxq "$b" 'systemctl is-active fail2ban')" active
    assert_contains "[$b] причина отката в журнале" "$(boxq "$b" 'journalctl -t ubuntu-bootstrap --no-pager -b | tail -3')" 'rolled back reason=перезагрузка'
    out="$(ubb "$b" status)"; assert_rc "[$b] status после перезагрузки" 0 $? "$out"
}

scn_rollback_run() {
    local b=$1 out run
    t_section "[$b] откат запуска по RUN_ID"
    out="$(ubb "$b" apply --only sysctl,limits --yes)"
    assert_rc "[$b] apply sysctl+limits" 0 $? "$out"
    assert_true "[$b] sysctl-файл создан" box "$b" test -f /etc/sysctl.d/90-ubuntu-bootstrap-hardening.conf
    assert_true "[$b] limits-файл создан" box "$b" test -f /etc/security/limits.d/90-ubuntu-bootstrap.conf
    run="$(boxq "$b" 'ls /var/lib/ubuntu-bootstrap/runs | sort | tail -1')"
    out="$(ubb "$b" history "$run")"
    assert_contains "[$b] history показывает журнал" "$out" 'записан  /etc/sysctl.d/90-ubuntu-bootstrap-hardening.conf (новый)'
    out="$(ubb "$b" rollback "$run" --module sysctl --yes)"
    assert_rc "[$b] rollback --module sysctl" 0 $? "$out"
    assert_true "[$b] sysctl-файлы удалены" box "$b" test ! -e /etc/sysctl.d/90-ubuntu-bootstrap-hardening.conf
    assert_true "[$b] limits не тронут" box "$b" test -f /etc/security/limits.d/90-ubuntu-bootstrap.conf
    out="$(ubb "$b" rollback)"; assert_rc "[$b] rollback без аргументов -> 2" 2 $? "$out"
    out="$(ubb "$b" rollback 19700101-000000-1 --yes)"; assert_rc "[$b] rollback неизвестного запуска -> 1" 1 $? "$out"
    out="$(ubb "$b" status --all)"
    assert_contains "[$b] status: sysctl снова pending" "$out" 'sysctl       pending'
}

scn_failures() {
    local b=$1 out
    t_section "[$b] ошибки модулей: откат изменений, --keep-going, ошибка пакета"
    boxq "$b" 'mkdir -p /etc/ubuntu-bootstrap/modules.d && cat > /etc/ubuntu-bootstrap/modules.d/failing.sh <<"EOT"
MOD_SUMMARY="тест: падает после записи"
mod_options() { opt FAILING_MODE enum:fail,ok fail "режим"; }
mod_check() { [[ -f /etc/failing.conf ]]; }
mod_apply() {
    undo touch /etc/failing.undo-ran
    printf "x\n" | file_write /etc/failing.conf 644
    [[ $(cfg FAILING_MODE) == ok ]] && return 0
    log_error "искусственная ошибка"
    return 1
}
EOT
cat > /etc/ubuntu-bootstrap/modules.d/okmod.sh <<"EOT"
MOD_SUMMARY="тест: успешный"
MOD_AFTER=(failing)
mod_check() { [[ -f /etc/okmod.conf ]]; }
mod_apply() { printf "y\n" | file_write /etc/okmod.conf 644; }
EOT' >/dev/null
    out="$(ubb "$b" apply --only failing --yes)"
    assert_rc "[$b] падающий модуль -> 1" 1 $? "$out"
    assert_contains "[$b] сообщение об откате" "$out" 'откатываю изменения модуля'
    assert_true "[$b] файл модуля откачен" box "$b" test ! -e /etc/failing.conf
    assert_true "[$b] undo выполнен" box "$b" test -f /etc/failing.undo-ran
    assert_eq "[$b] состояние failed" "$(boxq "$b" 'grep ^STATUS= /var/lib/ubuntu-bootstrap/modules/failing.env')" 'STATUS=failed'
    out="$(ubb "$b" apply --only failing,okmod --yes)"
    assert_rc "[$b] без --keep-going остановка" 1 $? "$out"
    assert_true "[$b] okmod не выполнялся" box "$b" test ! -e /etc/okmod.conf
    out="$(ubb "$b" apply --only failing,okmod --keep-going --yes)"
    assert_rc "[$b] --keep-going возвращает 1" 1 $? "$out"
    assert_true "[$b] okmod выполнен при --keep-going" box "$b" test -f /etc/okmod.conf
    out="$(ubb "$b" apply --only failing --set FAILING_MODE=ok --yes)"
    assert_rc "[$b] исправленный модуль применяется (продолжение после ошибки)" 0 $? "$out"
    assert_eq "[$b] состояние applied" "$(boxq "$b" 'grep ^STATUS= /var/lib/ubuntu-bootstrap/modules/failing.env')" 'STATUS=applied'
    out="$(ubb "$b" apply --only base --set BASE_EXTRA_PACKAGES=ubb-no-such-package-xyz --yes)"
    assert_rc "[$b] несуществующий пакет -> ошибка модуля" 1 $? "$out"
    assert_contains "[$b] apt сообщил причину" "$out" 'ubb-no-such-package-xyz'
    out="$(ubb "$b" apply --only base --yes)"
    assert_rc "[$b] base снова применяется" 0 $? "$out"
    boxq "$b" 'rm -f /etc/ubuntu-bootstrap/modules.d/*.sh /etc/failing.* /etc/okmod.conf' >/dev/null
}

scn_interrupt() {
    local b=$1 out run
    t_section "[$b] обрыв процесса (SIGTERM, SIGKILL): блокировка не залипает, статус отмечен"
    boxq "$b" 'mkdir -p /etc/ubuntu-bootstrap/modules.d && cat > /etc/ubuntu-bootstrap/modules.d/slow.sh <<"EOT"
MOD_SUMMARY="тест: долгий модуль"
mod_apply() { printf "s\n" | file_write /etc/slow.conf 644; local i; for i in $(seq 1 120); do sleep 1; done; }
EOT' >/dev/null
    boxq "$b" 'nohup ubuntu-bootstrap --no-color apply --only slow --yes >/tmp/bg.log 2>&1 &' >/dev/null
    sleep 5
    boxq "$b" 'pkill -TERM -f "[u]buntu-bootstrap --no-color apply"; sleep 3' >/dev/null
    run="$(boxq "$b" 'ls /var/lib/ubuntu-bootstrap/runs | sort | tail -1')"
    assert_eq "[$b] запуск помечен interrupted" "$(boxq "$b" "grep ^STATUS= /var/lib/ubuntu-bootstrap/runs/$run/run.env")" 'STATUS=interrupted'
    out="$(ubb "$b" apply --only journald --yes)"
    assert_rc "[$b] следующий запуск не заблокирован" 0 $? "$out"
    out="$(ubb "$b" rollback "$run" --yes)"
    assert_rc "[$b] прерванный запуск откатывается вручную" 0 $? "$out"
    assert_true "[$b] файл прерванного модуля убран" box "$b" test ! -e /etc/slow.conf
    boxq "$b" 'nohup ubuntu-bootstrap --no-color apply --only slow --yes >/tmp/bg.log 2>&1 &' >/dev/null
    sleep 5
    boxq "$b" 'pkill -KILL -f "[u]buntu-bootstrap --no-color apply"; sleep 1' >/dev/null
    out="$(ubb "$b" doctor)"
    assert_contains "[$b] doctor видит зависший статус running" "$out" 'помечен running'
    out="$(ubb "$b" apply --only journald --yes)"
    assert_rc "[$b] после SIGKILL блокировка свободна" 0 $? "$out"
    boxq "$b" 'rm -f /etc/ubuntu-bootstrap/modules.d/slow.sh /etc/slow.conf' >/dev/null
}

scn_uninstall() {
    local b=$1 out
    t_section "[$b] удаление инструмента не трогает настроенные сервисы"
    out="$(boxq "$b" '/opt/ubuntu-bootstrap/install.sh --uninstall')"
    assert_rc "[$b] --uninstall" 0 $? "$out"
    assert_true "[$b] бинарник удалён" box "$b" test ! -e /usr/local/bin/ubuntu-bootstrap
    assert_true "[$b] конфигурация сохранена" box "$b" test -f /etc/ubuntu-bootstrap/bootstrap.conf
    assert_eq "[$b] sshd продолжает работать" "$(ssh_box "$b" 2222 deploy 'echo ok')" ok
    assert_eq "[$b] ufw активен" "$(boxq "$b" 'ufw status | head -1')" 'Status: active'
}

scn_guards() {
    local b=$1 out
    t_section "[$b] предохранители на сервере без ключей"
    install_tool "$b"
    out="$(ubb "$b" apply --only ssh --yes)"
    assert_rc "[$b] запрет паролей без ключей -> 3" 3 $? "$out"
    assert_contains "[$b] причина: нет authorized_keys" "$out" 'нет authorized_keys'
    assert_true "[$b] конфиг sshd не создан" box "$b" test ! -e /etc/ssh/sshd_config.d/00-ubuntu-bootstrap.conf
    assert_eq "[$b] пароли всё ещё работают" "$(boxq "$b" 'sshd -T | grep -E "^passwordauthentication "')" 'passwordauthentication yes'
    boxq "$b" "mkdir -p /root/.ssh && echo '$PUBKEY' > /root/.ssh/authorized_keys && chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys" >/dev/null
    out="$(ubb "$b" apply --only ssh --set SSH_PERMIT_ROOT=no --yes)"
    assert_rc "[$b] PermitRootLogin no без администратора -> 3" 3 $? "$out"
    assert_contains "[$b] остановлено предохранителем" "$out" 'предохранителем'
    out="$(ubb "$b" apply --only ssh --yes)"
    assert_rc "[$b] auto: root по ключу разрешён, пароли нет" 0 $? "$out"
    assert_contains "[$b] prohibit-password" "$(boxq "$b" 'sshd -T | grep -E "^permitrootlogin " | sed s/without-password/prohibit-password/')" 'permitrootlogin prohibit-password'
    assert_eq "[$b] root входит по ключу" "$(ssh_box "$b" 22 root 'echo root-ok')" root-ok
    out="$(ubb "$b" apply --only ssh --set SSH_PORT=22 --set SSH_ALLOW_USERS=ghost --yes)"
    assert_rc "[$b] AllowUsers без ключей у ghost -> 3" 3 $? "$out"
    out="$(ubb "$b" apply --only users --set ADMIN_USER=deploy --set ADMIN_SUDO_MODE=password --yes)"
    assert_rc "[$b] users без пароля и хэша: применяется с предупреждением" 0 $? "$out"
    assert_contains "[$b] предупреждение про sudo" "$out" 'sudo не заработает'
    assert_eq "[$b] ключи root скопированы deploy (auto)" "$(boxq "$b" 'cat /home/deploy/.ssh/authorized_keys')" "$PUBKEY"
    out="$(ubb "$b" apply --only ssh --set SSH_PERMIT_ROOT=no --yes)"
    assert_rc "[$b] PermitRootLogin no при неработающем sudo -> 3" 3 $? "$out"
    out="$(ubb "$b" apply --only users --set ADMIN_USER=deploy --set ADMIN_SUDO_MODE=password --set 'ADMIN_PASSWORD_HASH=$6$abc$5mO0FvSm1Xm8qBhR0Z5gLq9i6oY4PjQ0kK7ZkqgDj7WZbVhC7a1jRkT1xkqKZtXk5Ckm6V2QY1yq4zEhbVnQ8/' --yes)"
    assert_rc "[$b] пароль из хэша" 0 $? "$out"
    assert_eq "[$b] пароль задан" "$(boxq "$b" 'passwd -S deploy | awk "{print \$2}"')" P
    out="$(ubb "$b" apply --only ssh --set SSH_PERMIT_ROOT=no --yes)"
    assert_rc "[$b] теперь PermitRootLogin no разрешён" 0 $? "$out"
    assert_eq "[$b] root больше не входит" "$(ssh_box "$b" 22 root 'echo root-ok' | grep -c root-ok)" 0
    assert_eq "[$b] deploy входит" "$(ssh_box "$b" 22 deploy 'echo ok')" ok
}

scn_corrupt_config() {
    local b=$1 out
    t_section "[$b] повреждённый и неверный конфиг"
    boxq "$b" 'mkdir -p /etc/ubuntu-bootstrap && printf "garbage without equals\n" > /etc/ubuntu-bootstrap/bootstrap.conf' >/dev/null
    out="$(ubb "$b" config validate)"; assert_rc "[$b] validate -> 1" 1 $? "$out"
    assert_contains "[$b] понятное сообщение" "$out" 'KEY=VALUE'
    out="$(ubb "$b" apply --yes)"; assert_rc "[$b] apply с битым конфигом -> 1" 1 $? "$out"
    boxq "$b" 'printf "SSH_PORT=99999\n" > /etc/ubuntu-bootstrap/bootstrap.conf' >/dev/null
    out="$(ubb "$b" config validate)"; assert_rc "[$b] невалидное значение -> 1" 1 $? "$out"
    assert_contains "[$b] указан источник" "$out" 'file:/etc/ubuntu-bootstrap/bootstrap.conf'
    boxq "$b" 'printf "PROFILE=minimal\nSSH_PROT=22\n" > /etc/ubuntu-bootstrap/bootstrap.conf' >/dev/null
    out="$(ubb "$b" config validate)"; assert_rc "[$b] опечатка в имени -> 1" 1 $? "$out"
    assert_contains "[$b] имя неизвестной опции" "$out" 'SSH_PROT'
    boxq "$b" 'printf "PROFILE=minimal\n" > /etc/ubuntu-bootstrap/bootstrap.conf' >/dev/null
    out="$(ubb "$b" config validate)"; assert_rc "[$b] исправленный конфиг валиден" 0 $? "$out"
    out="$(ubb "$b" config get SSH_PORT)"; assert_eq "[$b] config get" "$out" keep
    out="$(ubb "$b" config show)"; assert_contains "[$b] config show показывает профиль" "$out" 'профиль: minimal'
}

scn_preconfigured() {
    local b=$1 out
    t_section "[$b] уже настроенный сервер: cloud-init, ufw с правилами, существующий пользователь"
    install_tool "$b"
    boxq "$b" "printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/50-cloud-init.conf
useradd -m -s /bin/bash ops && mkdir -p /home/ops/.ssh && echo '$PUBKEY' > /home/ops/.ssh/authorized_keys && chown -R ops:ops /home/ops/.ssh && chmod 700 /home/ops/.ssh && chmod 600 /home/ops/.ssh/authorized_keys
echo 'ops ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ops && chmod 440 /etc/sudoers.d/ops && usermod -aG sudo ops
ufw allow 9000/tcp >/dev/null && ufw allow 22/tcp >/dev/null && ufw --force enable >/dev/null
printf '{\"data-root\": \"/var/lib/docker\"}\n' > /tmp/unused" >/dev/null
    out="$(ubb "$b" apply --profile minimal --set ADMIN_USER=ops --set BASE_UPGRADE=no --yes)"
    assert_rc "[$b] apply на преднастроенном сервере" 0 $? "$out"
    assert_contains "[$b] ufw дополнен, не сброшен" "$out" 'UFW уже активен'
    assert_contains "[$b] правило 9000 сохранено" "$(boxq "$b" 'ufw status')" '9000/tcp'
    assert_eq "[$b] 00- побеждает 50-cloud-init" "$(boxq "$b" 'sshd -T | grep -E "^passwordauthentication "')" 'passwordauthentication no'
    assert_eq "[$b] root запрещён: ops имеет ключ и sudo" "$(boxq "$b" 'sshd -T | grep -E "^permitrootlogin "')" 'permitrootlogin no'
    assert_eq "[$b] ключи ops не тронуты" "$(boxq "$b" 'cat /home/ops/.ssh/authorized_keys')" "$PUBKEY"
    assert_eq "[$b] ops входит и имеет sudo" "$(ssh_box "$b" 22 ops 'sudo -n id -u')" 0
    assert_contains "[$b] бэкап after.rules сделан" "$(boxq "$b" 'ls -R /var/backups/ubuntu-bootstrap/ | grep -c after.rules')" 1
}

scn_network_failure() {
    local b=$1 out
    t_section "[$b] сетевой сбой при добавлении репозитория"
    boxq "$b" 'iptables -I OUTPUT -p tcp --dport 443 -j REJECT; iptables -I OUTPUT -p tcp --dport 80 -j REJECT' >/dev/null
    out="$(ubb "$b" apply --only nginx --set NGINX_SOURCE=stable --yes)"
    assert_rc "[$b] без сети модуль падает, не зависает" 1 $? "$out"
    assert_contains "[$b] причина: ключ не скачан" "$out" 'не удалось скачать ключ'
    assert_true "[$b] источник nginx не оставлен" box "$b" test ! -e /etc/apt/sources.list.d/nginx.sources
    assert_true "[$b] keyring не оставлен" box "$b" test ! -e /etc/apt/keyrings/nginx.asc
    boxq "$b" 'iptables -D OUTPUT -p tcp --dport 443 -j REJECT; iptables -D OUTPUT -p tcp --dport 80 -j REJECT' >/dev/null
    out="$(ubb "$b" doctor)"
    assert_contains "[$b] doctor: HTTPS восстановлен" "$out" 'HTTPS до archive.ubuntu.com'
}

scn_services() {
    local b=$1 out ip probe
    t_section "[$b] docker + nginx + certbot (профиль full без git/wg-network)"
    install_tool "$b"
    ubb "$b" config init --profile full --force >/dev/null
    ubb "$b" config set MODULES_SKIP=git,wg-network,swap ADMIN_USER=deploy "ADMIN_SSH_KEYS=$PUBKEY" ADMIN_SUDO_MODE=nopasswd BASE_UPGRADE=no CERTBOT_METHOD=apt >/dev/null
    out="$(ubb "$b" apply --yes)"
    assert_rc "[$b] apply full" 0 $? "$out"
    assert_eq "[$b] docker работает" "$(boxq "$b" 'docker info --format "{{.ServerVersion}}" | cut -d. -f1 | grep -cE "^[0-9]+$"')" 1
    assert_true "[$b] docker из официального репозитория (deb822)" box "$b" test -f /etc/apt/sources.list.d/docker.sources
    assert_contains "[$b] ключ Docker проверен по отпечатку" "$(boxq "$b" 'gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc | awk -F: "/^fpr/{print \$10}"')" 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
    assert_eq "[$b] daemon.json валиден" "$(boxq "$b" 'jq -r .\"live-restore\" /etc/docker/daemon.json')" true
    assert_true "[$b] docker compose plugin" box "$b" docker compose version
    assert_contains "[$b] DOCKER-USER в after.rules" "$(boxq "$b" 'cat /etc/ufw/after.rules')" 'BEGIN ubuntu-bootstrap docker'
    assert_contains "[$b] DOCKER-USER загружен в iptables" "$(boxq "$b" 'iptables -S DOCKER-USER')" '--ctstate NEW -j DROP'
    assert_eq "[$b] nginx активен" "$(boxq "$b" 'systemctl is-active nginx')" active
    assert_true "[$b] nginx из nginx.org" box "$b" test -f /etc/apt/sources.list.d/nginx.sources
    assert_eq "[$b] server_tokens off" "$(boxq "$b" 'curl -sI http://127.0.0.1/ | grep -i ^server: | tr -d "\r"')" 'Server: nginx'
    assert_eq "[$b] nginx LimitNOFILE" "$(boxq "$b" 'systemctl show nginx -p LimitNOFILESoft --value')" 65535
    assert_eq "[$b] 80/443 открыты" "$(boxq "$b" 'ufw status | grep -cE "^(80|443)/tcp +ALLOW"')" 2
    assert_true "[$b] certbot установлен (apt)" box "$b" certbot --version
    out="$(ubb "$b" apply --only certbot --set CERTBOT_METHOD=apt --set CERTBOT_DOMAINS=nonexistent.invalid --yes)"
    assert_rc "[$b] certbot: DNS не готов -> 3" 3 $? "$out"
    assert_contains "[$b] причина DNS" "$out" 'DNS не готов'
    out="$(ubb "$b" audit)"; assert_true "[$b] audit профиля full (код $?)" test $? -le 1
    assert_contains "[$b] audit: Docker" "$out" 'работает'

    t_section "[$b] защита DOCKER-USER: контейнер с портом на 0.0.0.0 недоступен снаружи"
    boxq "$b" 'docker run -d --name web -p 0.0.0.0:8080:80 nginx:alpine >/dev/null 2>&1; for i in $(seq 1 60); do curl -fs -o /dev/null http://127.0.0.1:8080/ && break; sleep 2; done' >/dev/null
    assert_eq "[$b] контейнер слушает 8080 изнутри" "$(boxq "$b" 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/')" 200
    ip="$(box_ip "$b")"
    probe="$(docker run --rm --network "net-$RUN_TAG" busybox:latest sh -c "wget -q -T 4 -O /dev/null http://$ip:8080/ && echo open || echo blocked" 2>/dev/null)"
    assert_eq "[$b] снаружи 8080 заблокирован DOCKER-USER" "$probe" blocked
    out="$(ubb "$b" audit)"
    assert_contains "[$b] audit предупреждает о 0.0.0.0" "$out" 'портами на всех интерфейсах'
    out="$(ubb "$b" apply --only firewall --set FW_DOCKER_ALLOW_PORTS=8080/tcp --yes)"
    assert_rc "[$b] исключение для 8080" 0 $? "$out"
    probe="$(docker run --rm --network "net-$RUN_TAG" busybox:latest sh -c "wget -q -T 4 -O /dev/null http://$ip:8080/ && echo open || echo blocked" 2>/dev/null)"
    assert_eq "[$b] 8080 доступен после FW_DOCKER_ALLOW_PORTS" "$probe" open
    probe="$(docker run --rm --network "net-$RUN_TAG" busybox:latest sh -c "wget -q -T 4 -O /dev/null http://$ip:80/ && echo open || echo blocked" 2>/dev/null)"
    assert_eq "[$b] nginx хоста доступен снаружи (ufw 80)" "$probe" open
    boxq "$b" 'docker rm -f web >/dev/null 2>&1' >/dev/null
}

scn_wg_network() {
    local b=$1 out
    t_section "[$b] модуль wg-network (только установка инструмента)"
    if ! curl -fsI --max-time 10 https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/wg/install.sh >/dev/null 2>&1; then
        t_skip "[$b] ubuntu/wg/install.sh недоступен в GitHub (ветка main) — пропуск"
        return 0
    fi
    out="$(ubb "$b" apply --only wg-network --set BASE_UPGRADE=no --yes)"
    assert_rc "[$b] установка wg-network" 0 $? "$out"
    assert_true "[$b] wg-network установлен" box "$b" test -x /opt/wg-network/wg-network
    assert_eq "[$b] сеть не настроена (это задача wg-network)" "$(boxq "$b" 'test -f /etc/wireguard/wg0.conf && echo yes || echo no')" no
}

run_version() {
    local v=$1 A B C
    img_build "$v"
    docker network inspect "net-$RUN_TAG" >/dev/null 2>&1 || docker network create "net-$RUN_TAG" >/dev/null
    want() { [[ -z $ONLY || ",$ONLY," == *",$1,"* ]]; }
    if want install || want fresh || want fail2ban || want idempotent || want port || want pending || want reboot || want rollback || want failures || want interrupt || want uninstall; then
        box_start "a-$v" "$v"; A=$BOX
        want install && scn_install "$A"
        [[ -z $ONLY ]] || install_tool "$A" >/dev/null
        want fresh && scn_fresh_minimal "$A"
        want fail2ban && scn_fail2ban_real "$A"
        want idempotent && scn_idempotent "$A"
        want port && scn_ssh_port_change "$A"
        want pending && scn_ssh_pending_rollback "$A"
        want reboot && scn_reboot "$A"
        want rollback && scn_rollback_run "$A"
        want failures && scn_failures "$A"
        want interrupt && scn_interrupt "$A"
        want uninstall && scn_uninstall "$A"
    fi
    if want guards || want corrupt || want wg; then
        box_start "b-$v" "$v"; B=$BOX
        want guards && scn_guards "$B"
        [[ -z $ONLY ]] || install_tool "$B" >/dev/null
        want corrupt && scn_corrupt_config "$B"
        want wg && scn_wg_network "$B"
    fi
    if want preconfigured || want network || want services; then
        box_start "c-$v" "$v"; C=$BOX
        if want preconfigured; then scn_preconfigured "$C"; else install_tool "$C" >/dev/null; fi
        want network && scn_network_failure "$C"
        want services && scn_services "$C"
    fi
}

coverage_report() {
    ((COVERAGE)) || return 0
    local v=${VERSIONS%% *} box
    box_start "cov-$v" "$v"; box=$BOX
    docker exec "$box" test -x /usr/bin/kcov || { echo 'kcov недоступен в образе — отчёт покрытия пропущен'; return 0; }
    echo '==> unit-тесты под kcov'
    docker exec "$box" kcov --include-path=/src --exclude-pattern=/tests/ /cov/unit bash /src/tests/unit.sh >/dev/null 2>&1 || echo 'unit под kcov завершились с ошибкой'
    # Reports are created by root inside the container; python on the host merges them.
    printf '\n\033[1mПокрытие (kcov, объединение всех запусков):\033[0m\n'
    python3 "$HERE/coverage-merge.py" "$COV_DIR" | tee "$HERE/.coverage-summary.txt" 2>/dev/null || true
    echo "сводка: $HERE/.coverage-summary.txt; подробные отчёты kcov: $COV_DIR/<запуск>/index.html"
}

if ((COVERAGE)); then
    # Previous reports belong to root (created inside a container), so a container removes them.
    [[ -d $COV_DIR ]] && docker run --rm -v "$(dirname "$COV_DIR"):/w" busybox:latest rm -rf "/w/$(basename "$COV_DIR")" >/dev/null 2>&1
    mkdir -p "$COV_DIR" && chmod 777 "$COV_DIR"
fi
for v in $VERSIONS; do
    printf '\n\033[1m######## Ubuntu %s ########\033[0m\n' "$v"
    run_version "$v"
done
coverage_report
t_summary
