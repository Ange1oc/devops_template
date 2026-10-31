#!/usr/bin/env bash
# Unit tests: validation, KEY=VALUE, configuration and profiles, module registry and dependencies,
# transactions and rollback in a sandbox, module config rendering. No root, network or system changes.

# shellcheck disable=SC2016  # expected strings are passed literally
set -uo pipefail
shopt -s lastpipe
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UBB_HOME="$(dirname "$HERE")"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ubb-unit.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
export UBB_SYSROOT="$SANDBOX/root"
mkdir -p "$UBB_SYSROOT"

for lib in core validate paths facts pkg svc tx options modules ui audit runner; do
    # shellcheck source=/dev/null
    source "$UBB_HOME/lib/$lib.sh"
done
OPT_YES=1 OPT_QUIET=1 OPT_VERBOSE=0 OPT_COLOR=0 OPT_FORCE=0 OPT_JSON=0 OPT_KEEP_GOING=0 OPT_FORCE_REAPPLY=0
OPT_PROFILE='' OPT_CONFIG_FILE=''
declare -a OPT_ONLY=() OPT_SKIP=()
setup_colors
ui_init
facts_load
modules_discover

# Subshell: functions that die would terminate the test process.
runs() { ( set -e; "$@" ) >/dev/null 2>&1; }
out_of() { ( "$@" ) 2>&1; }

t_section 'Валидация'
for p in 1 22 2222 65535; do assert_true "порт $p" is_port "$p"; done
for p in 0 65536 abc '' -1 '22 '; do assert_false "не порт '$p'" is_port "$p"; done
assert_true 'ed25519 ключ' is_ssh_pubkey 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGq6I7qXmuW7zQ1B6j5gN0mY3bQ8QhB1ZjJ0kR5m7Z9m user@host'
assert_true 'rsa ключ без комментария' is_ssh_pubkey 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7'
assert_true 'sk-ключ' is_ssh_pubkey 'sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAI='
assert_false 'не ключ' is_ssh_pubkey 'hello world'
assert_false 'ключ с переводом строки' is_ssh_pubkey $'ssh-ed25519 AAAA\nssh-ed25519 BBBB'
assert_true 'hostname' is_hostname example.com
assert_true 'hostname однословный' is_hostname srv1
assert_false 'hostname из цифр' is_hostname 1.2.3.4
assert_false 'hostname с пробелом' is_hostname 'a b'
assert_true 'cidr v4' is_cidr 10.0.0.0/8
assert_false 'cidr /33' is_cidr 10.0.0.0/33
assert_true 'ipv6' is_ipv6 'fd00::1'
assert_true 'port spec 443/udp' is_port_spec 443/udp
assert_false 'port spec 443/icmp' is_port_spec 443/icmp
assert_true 'size 2G' is_size 2G
assert_true 'size 512m' is_size 512m
assert_false 'size 2T' is_size 2T
assert_eq 'size_to_mb 2G' "$(size_to_mb 2G)" 2048
assert_eq 'size_to_mb 512M' "$(size_to_mb 512M)" 512
assert_eq 'to_bool yes' "$(to_bool YES)" 1
assert_eq 'to_bool off' "$(to_bool off)" 0
assert_false 'to_bool мусор' to_bool maybe
assert_true 'duration 10m' is_duration 10m
assert_true 'duration 1w' is_duration 1w
assert_false 'duration 10x' is_duration 10x
assert_true 'email' is_email admin@example.com
assert_false 'email без домена' is_email admin@
assert_true 'git ref' is_git_ref ubuntu-bootstrap-v1.0.0
assert_false 'git ref с ..' is_git_ref 'a..b'
assert_true 'username' is_username deploy-01
assert_false 'username с заглавной' is_username Deploy

t_section 'KEY=VALUE и списки'
kvf="$SANDBOX/kv.env"
printf '# comment\nA=1\nB=two words\n\nC=\n' > "$kvf"
declare -A kv=()
assert_true 'kv_load' kv_load "$kvf" kv
assert_eq 'kv_get B' "$(kv_get "$kvf" B)" 'two words'
assert_eq 'kv C пустой' "${kv[C]}" ''
assert_eq 'kv ключей' "${#kv[@]}" 3
kv_set "$kvf" D 'x=y'
assert_eq 'kv_set добавляет' "$(kv_get "$kvf" D)" 'x=y'
assert_eq 'kv_set сохраняет' "$(kv_get "$kvf" A)" 1
kv_set "$kvf" A 2
assert_eq 'kv_set сохраняет порядок ключей' "$(grep -o '^[A-Z]' "$kvf" | tr -d '\n')" ABCD
printf 'garbage line\n' > "$SANDBOX/bad.env"
declare -A kv2=()
assert_false 'kv_load отклоняет мусор' kv_load "$SANDBOX/bad.env" kv2
printf 'lower=1\n' > "$SANDBOX/bad2.env"
assert_false 'kv_load отклоняет ключ в нижнем регистре' kv_load "$SANDBOX/bad2.env" kv2
declare -a lst=()
split_list 'a, b;c  d,,e' lst
assert_eq 'split_list' "${lst[*]}" 'a b c d e'
assert_eq 'join_by' "$(join_by , a b c)" 'a,b,c'
assert_true 'in_list' in_list b a b c
assert_false 'not in_list' in_list z a b c
assert_eq 'json_str' "$(json_str 'a"b\c')" '"a\"b\\c"'

t_section 'Факты'
printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\nPRETTY_NAME="Ubuntu 24.04 LTS"\n' > "$SANDBOX/os-release"
( UBB_OS_RELEASE="$SANDBOX/os-release" facts_load; printf '%s %s %s' "$F_OS_ID" "$F_OS_VERSION" "$F_OS_CODENAME" ) > "$SANDBOX/facts.out"
assert_eq 'os-release разбирается' "$(cat "$SANDBOX/facts.out")" 'ubuntu 24.04 noble'
assert_true 'F_MEM_MB число' is_uint "$F_MEM_MB"

t_section 'Реестр модулей'
assert_eq 'обнаружено модулей' "${#MOD_ALL[@]}" 17
assert_eq 'первый модуль preflight' "${MOD_ALL[0]}" preflight
declare -a r=()
modules_resolve r certbot
assert_eq 'certbot тянет preflight' "${r[*]}" 'preflight certbot'
modules_resolve r firewall docker ssh
assert_eq 'порядок: ssh, docker, firewall (MOD_AFTER)' "${r[*]}" 'preflight base ssh docker firewall'
modules_resolve r fail2ban ssh firewall
assert_eq 'fail2ban после ssh и firewall' "${r[*]}" 'preflight ssh firewall fail2ban'
assert_false 'неизвестный модуль' runs modules_resolve r nosuch
mkdir -p "$SANDBOX/mods"
printf 'MOD_SUMMARY=a\nMOD_DEPS=(cyc-b)\n' > "$SANDBOX/mods/cyc-a.sh"
printf 'MOD_SUMMARY=b\nMOD_DEPS=(cyc-a)\n' > "$SANDBOX/mods/cyc-b.sh"
assert_false 'цикл зависимостей обнаружен' runs bash -c "UBB_MODULE_PATH='$SANDBOX/mods' '$UBB_HOME/ubuntu-bootstrap' modules"
rm -rf "$SANDBOX/mods"
assert_eq 'набор по умолчанию' "${MOD_DEFAULT_SET[*]}" 'preflight base time users ssh firewall fail2ban updates sysctl limits swap journald'
assert_eq 'опции объявлены с модулем' "${OPT_MODULE[SSH_PORT]}" ssh
assert_eq 'adv-флаг' "${OPT_ADV[SSH_MAX_AUTH_TRIES]}${OPT_ADV[SSH_PORT]}" 10

t_section 'Опции и конфигурация'
assert_true 'bool yes' opt_validate SSH_PASSWORD_AUTH yes
assert_false 'bool мусор' opt_validate SSH_PASSWORD_AUTH maybe
assert_true 'enum' opt_validate SSH_PERMIT_ROOT no
assert_false 'enum вне списка' opt_validate SSH_PERMIT_ROOT sometimes
assert_true 'portkeep keep' opt_validate SSH_PORT keep
assert_true 'portkeep 2222' opt_validate SSH_PORT 2222
assert_false 'portkeep 0' opt_validate SSH_PORT 0
assert_true 'keys два ключа' opt_validate ADMIN_SSH_KEYS 'ssh-ed25519 AAAA a;ssh-rsa BBBB b'
assert_false 'keys мусор' opt_validate ADMIN_SSH_KEYS 'nope'
assert_true 'ports' opt_validate FW_ALLOW_PORTS '8080/tcp,53/udp,9000'
assert_false 'ports мусор' opt_validate FW_ALLOW_PORTS '80/x'
assert_true 'cidrs' opt_validate FW_SSH_FROM '10.0.0.0/8,192.168.1.5'
assert_true 'users' opt_validate SSH_ALLOW_USERS 'deploy,ops'
assert_true 'size auto' opt_validate SWAP_SIZE auto
assert_true 'size 0' opt_validate SWAP_SIZE 0
assert_true 'hostnames' opt_validate CERTBOT_DOMAINS 'a.example.com,example.com'
assert_eq 'cfg умолчание' "$(cfg SSH_PORT)" keep

mkdir -p "$CONF_DIR"
printf 'PROFILE=web\nSSH_PORT=2222\nADMIN_USER=deploy\n' > "$CONF_FILE"
SET_OVERRIDES=(ADMIN_USER=ops)
config_load
assert_eq 'профиль из файла' "${CONF[PROFILE]}" web
assert_eq 'файл поверх профиля' "$(cfg SSH_PORT)" 2222
assert_eq '--set поверх файла' "$(cfg ADMIN_USER)" ops
assert_eq 'источник --set' "${CONF_SOURCE[ADMIN_USER]}" cli
assert_eq 'значение профиля' "$(cfg NGINX_SOURCE)" stable
declare -a cm=()
config_modules cm
assert_contains 'модули профиля web' " ${cm[*]} " ' nginx '
SET_OVERRIDES=(MODULES_SKIP=certbot MODULES_ADD=docker)
config_load
config_modules cm
assert_not_contains 'MODULES_SKIP' " ${cm[*]} " ' certbot '
assert_contains 'MODULES_ADD' " ${cm[*]} " ' docker '
SET_OVERRIDES=(NOSUCH_OPTION=1)
assert_false 'неизвестная опция отклоняется' runs config_load
SET_OVERRIDES=(SSH_PORT=99999)
assert_false 'невалидное значение отклоняется' runs config_load
SET_OVERRIDES=('MODULES=preflight,nosuch')
assert_false 'неизвестный модуль в MODULES' runs config_load
printf 'this is not kv\n' > "$CONF_FILE"
SET_OVERRIDES=()
assert_false 'повреждённый конфиг отклоняется' runs config_load
rm -f "$CONF_FILE"
OPT_PROFILE=nosuch
assert_false 'нет такого профиля' runs config_load
OPT_PROFILE=''
config_load
config_modules cm
assert_eq 'без профиля — набор по умолчанию' "${cm[*]}" "${MOD_DEFAULT_SET[*]}"
OPT_ONLY=(nginx)
modules_selected cm
assert_eq '--only добавляет зависимости и preflight' "${cm[*]}" 'preflight base nginx'
OPT_ONLY=(nginx) OPT_SKIP=(base)
modules_selected cm
assert_eq '--skip исключает' "${cm[*]}" 'preflight nginx'
OPT_ONLY=() OPT_SKIP=()
for p in minimal web docker full; do
    OPT_PROFILE=$p
    assert_true "профиль $p валиден" runs config_load
done
OPT_PROFILE=''
config_load
SELECTED_MODULES=("${MOD_ALL[@]}")

t_section 'Транзакции'
F_HAS_SYSTEMD=0
UBB_CMD='test'
tx_begin test
assert_file 'журнал создан' "$JOURNAL"
assert_eq 'статус running' "$(kv_get "$RUN_DIR/run.env" STATUS)" running
tx_module_begin config
config_save "$SANDBOX/saved.conf" preflight ssh
assert_contains 'config_save пишет MODULES' "$(cat "$SANDBOX/saved.conf")" 'MODULES=preflight,ssh'
assert_contains 'config_save пишет опции с описанием' "$(cat "$SANDBOX/saved.conf")" $'# Порт SSH (keep — не менять) (порт или keep)\nSSH_PORT=keep'
declare -A kv3=()
assert_true 'сохранённый конфиг читается' kv_load "$SANDBOX/saved.conf" kv3
tx_module_begin alpha
tf="$SANDBOX/etc/test.conf"
printf 'one\n' | file_write "$tf" 600
assert_eq 'файл записан' "$(cat "$tf")" one
assert_eq 'FILE_CHANGED=1 при создании' "$FILE_CHANGED" 1
assert_eq 'права 600' "$(stat -c %a "$tf")" 600
printf 'one\n' | file_write "$tf" 600
assert_eq 'повторная запись без изменений' "$FILE_CHANGED" 0
printf 'two\n' | file_write "$tf" 644
assert_eq 'изменение содержимого' "$FILE_CHANGED" 1
assert_eq 'права обновлены' "$(stat -c %a "$tf")" 644
bk="$(backup_path "$tf")"
assert_eq 'бэкап прежней версии' "$(cat "$bk")" one
assert_eq 'журнал: W для нового и изменённого (+ saved.conf)' "$(grep -c "^W" "$JOURNAL")" 3
undo touch "$SANDBOX/undo-ran"
tf2="$SANDBOX/etc/second.conf"
printf 'x\n' | file_write "$tf2"
file_set_block "$SANDBOX/etc/fstab" 'test block' <<< '/swapfile none swap sw 0 0'
assert_contains 'блок добавлен' "$(cat "$SANDBOX/etc/fstab")" $'# BEGIN test block\n/swapfile none swap sw 0 0\n# END test block'
printf 'other line\n' > "$SANDBOX/etc/hosts"
file_set_block "$SANDBOX/etc/hosts" 'tb' <<< 'first'
file_set_block "$SANDBOX/etc/hosts" 'tb' <<< 'second'
assert_eq 'блок заменяется, чужие строки сохраняются' "$(cat "$SANDBOX/etc/hosts")" $'other line\n# BEGIN tb\nsecond\n# END tb'
file_set_block "$SANDBOX/etc/hosts" 'tb' < /dev/null
assert_eq 'пустой блок удаляется' "$(cat "$SANDBOX/etc/hosts")" 'other line'
file_remove "$tf2"
assert_no_file 'file_remove удаляет' "$tf2"
tx_module_begin beta
printf 'beta\n' | file_write "$SANDBOX/etc/beta.conf"
# Rolling back alpha restores its files and runs its undo; beta is untouched.
assert_true 'откат alpha' tx_rollback_journal "$JOURNAL" alpha
assert_no_file 'alpha: созданный файл удалён' "$tf"
assert_file 'alpha: undo выполнен' "$SANDBOX/undo-ran"
assert_no_file 'alpha: файл, созданный и удалённый внутри модуля, отсутствует' "$tf2"
assert_file 'beta не тронут' "$SANDBOX/etc/beta.conf"
assert_true 'откат всего запуска' tx_rollback_journal "$JOURNAL"
assert_no_file 'beta откачен' "$SANDBOX/etc/beta.conf"
DRY_RUN=1
printf 'dry\n' | file_write "$SANDBOX/etc/dry.conf"
assert_no_file 'dry-run не создаёт файл' "$SANDBOX/etc/dry.conf"
assert_eq 'dry-run: FILE_CHANGED=1' "$FILE_CHANGED" 1
DRY_RUN=0
assert_eq 'redact' "$(printf 'PASSWORD=secret\nname=x\n' | redact_secrets)" $'PASSWORD=(скрыто)\nname=x'
assert_true 'run выполняет' run true
assert_false 'run возвращает код' run false
tx_set_status "done"
assert_eq 'статус done' "$(kv_get "$RUN_DIR/run.env" STATUS)" 'done'
module_state_set alpha STATUS applied
assert_eq 'состояние модуля' "$(module_state_get alpha STATUS)" applied
h1="$(module_config_hash ssh)"
CONF[SSH_PORT]=2200
assert_true 'хэш конфигурации меняется' test "$h1" != "$(module_config_hash ssh)"
unset 'CONF[SSH_PORT]'

t_section 'Отложенный откат (setsid, без systemd)'
RUN_ID_SAVED=$RUN_ID
tx_module_begin gamma
printf 'risky\n' | file_write "$SANDBOX/etc/risky.conf"
pending_arm gamma 2 'test'
assert_file 'pending.env создан' "$PENDING_FILE"
assert_eq 'pending: модуль' "$(kv_get "$PENDING_FILE" MODULE)" gamma
pending_disarm
assert_no_file 'disarm удаляет pending' "$PENDING_FILE"
assert_file 'disarm не откатывает' "$SANDBOX/etc/risky.conf"
pending_arm gamma 60 'test'
assert_true 'pending_rollback' pending_rollback manual
assert_no_file 'откат удалил файл' "$SANDBOX/etc/risky.conf"
assert_eq 'состояние rolled_back' "$(module_state_get gamma STATUS)" rolled_back
pending_arm gamma 60 'test'
pending_confirm
assert_true 'confirm фиксирует время' test -n "$(module_state_get gamma CONFIRMED_AT)"
flock -u "$LOCK_FD"

t_section 'Рендер конфигов модулей'
CONF=() CONF_SOURCE=()
module_load ssh
F_SSHD_PORTS=22
assert_not_contains 'ssh: keep не пишет Port' "$(ssh_render)" 'Port '
assert_contains 'ssh: пароли запрещены' "$(ssh_render)" $'PasswordAuthentication no\nKbdInteractiveAuthentication no'
CONF[SSH_PORT]=2222 CONF[SSH_ALLOW_USERS]='deploy,ops' CONF[SSH_PERMIT_ROOT]=no CONF[SSH_PASSWORD_AUTH]=yes
assert_contains 'ssh: Port' "$(ssh_render)" 'Port 2222'
assert_contains 'ssh: AllowUsers' "$(ssh_render)" 'AllowUsers deploy ops'
assert_not_contains 'ssh: пароли разрешены — без KbdInteractive' "$(ssh_render)" KbdInteractive
assert_eq 'ssh: целевой порт' "$(ssh_target_port)" 2222
assert_eq 'ssh: разрешённые пользователи' "$(ssh_allowed_users | tr '\n' ' ')" 'deploy ops '
CONF=()
module_load fail2ban
F_SSH_CLIENT_IP=203.0.113.7
assert_contains 'f2b: ignoreip с текущим клиентом' "$(f2b_render)" 'ignoreip = 127.0.0.1/8 ::1 203.0.113.7'
assert_contains 'f2b: journalmatch ssh.service' "$(f2b_render)" '_SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session'
CONF[F2B_IGNORE_CURRENT]=no CONF[F2B_IGNOREIP]='10.0.0.0/8'
assert_contains 'f2b: ignoreip из конфига' "$(f2b_render)" 'ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8'
CONF=()
module_load firewall
F_DEFAULT_IFACE=eth0
SELECTED_MODULES=(firewall)
F_SSH_CLIENT_IP=''
assert_eq 'fw: правила по умолчанию' "$(fw_rules | tr '\n' ';')" 'limit 22/tcp;'
CONF[FW_WEB]=yes CONF[FW_ALLOW_PORTS]='8443/tcp,51820/udp' CONF[FW_SSH_FROM]='10.0.0.0/8'
assert_eq 'fw: web, from, extra' "$(fw_rules | tr '\n' ';')" 'allow 22/tcp from 10.0.0.0/8;allow 80/tcp;allow 443/tcp;allow 443/udp;allow 8443/tcp;allow 51820/udp;'
CONF[FW_DOCKER_ALLOW_PORTS]='8080/tcp'
assert_contains 'fw: DOCKER-USER drop' "$(fw_docker_block)" '-A DOCKER-USER -i eth0 -m conntrack --ctstate NEW -j DROP'
assert_contains 'fw: DOCKER-USER исключение' "$(fw_docker_block)" '--ctorigdstport 8080'
assert_true 'cidr_contains4 внутри' cidr_contains4 10.0.0.0/8 10.200.1.1
assert_false 'cidr_contains4 снаружи' cidr_contains4 10.0.0.0/8 11.0.0.1
assert_true 'cidr_contains4 /32' cidr_contains4 203.0.113.7/32 203.0.113.7
CONF=()
module_load sysctl
assert_contains 'sysctl: syncookies' "$(sysctl_hard_render)" 'net.ipv4.tcp_syncookies = 1'
SELECTED_MODULES=(sysctl)
if has_cmd docker; then
    assert_contains 'sysctl: ip_forward сохранён при docker' "$(sysctl_hard_render)" 'ip_forward is needed'
fi
CONF[SYSCTL_IP_FORWARD]=off
assert_contains 'sysctl: ip_forward=0 по требованию' "$(sysctl_hard_render)" 'net.ipv4.ip_forward = 0'
saved_container=$F_CONTAINER
F_CONTAINER=0
# shellcheck disable=SC2329  # stubs are called by sysctl_bbr_wanted
sysctl_bbr_available() { return 0; }
assert_contains 'sysctl: bbr' "$(sysctl_perf_render)" 'tcp_congestion_control = bbr'
# shellcheck disable=SC2329
sysctl_bbr_available() { return 1; }
assert_not_contains 'sysctl: bbr недоступен в ядре — не пишется' "$(sysctl_perf_render)" bbr
sysctl_bbr_available() { return 0; }
CONF[SYSCTL_BBR]=no
assert_not_contains 'sysctl: без bbr' "$(sysctl_perf_render)" bbr
F_CONTAINER=1
CONF[SYSCTL_BBR]=yes
assert_not_contains 'sysctl: в контейнере без bbr' "$(sysctl_perf_render)" bbr
F_CONTAINER=$saved_container
CONF=()
module_load docker
assert_true 'docker: daemon.json валидный JSON' bash -c "$(declare -f docker_daemon_render cfg cfg_bool to_bool die log_error _log_file); $(declare -p OPT_TYPE OPT_DEFAULT CONF | sed 's/declare -A/declare -gA/'); OPT_QUIET=1; docker_daemon_render | jq -e . >/dev/null"
if has_cmd jq; then
    mkdir -p "$SANDBOX/docker"
    printf '{"log-driver":"journald","data-root":"/data"}\n' > "$SANDBOX/docker/daemon.json"
    merged="$(DOCKER_DAEMON_JSON="$SANDBOX/docker/daemon.json" bash -c "$(declare -f docker_daemon_render docker_daemon_merged cfg cfg_bool to_bool has_cmd die log_error _log_file); $(declare -p OPT_TYPE OPT_DEFAULT CONF | sed 's/declare -A/declare -gA/'); OPT_QUIET=1; DOCKER_DAEMON_JSON='$SANDBOX/docker/daemon.json'; docker_daemon_merged")"
    assert_eq 'docker: ключи администратора сохраняются' "$(jq -r '."data-root"' <<< "$merged")" /data
    assert_eq 'docker: наш log-driver не перебивает чужой' "$(jq -r '."log-driver"' <<< "$merged")" journald
    assert_eq 'docker: наши ключи добавлены' "$(jq -r '."live-restore"' <<< "$merged")" true
else
    t_skip 'jq не установлен — merge daemon.json'
fi
CONF=()
module_load updates
assert_contains 'updates: reboot false' "$(upd_render)" 'Automatic-Reboot "false"'
CONF[UPD_ORIGINS]=all CONF[UPD_AUTO_REBOOT]=yes
assert_contains 'updates: -updates origin' "$(upd_render)" '${distro_id}:${distro_codename}-updates'
assert_contains 'updates: reboot true' "$(upd_render)" 'Automatic-Reboot "true"'
CONF=()
module_load journald
assert_contains 'journald: persistent' "$(journald_render)" $'Storage=persistent\nCompress=yes\nSystemMaxUse=1G'
module_load limits
assert_contains 'limits: systemd' "$(limits_systemd_render)" 'DefaultLimitNOFILE=65535:524288'
module_load nginx
assert_contains 'nginx: server_tokens off' "$(nginx_tuning_render)" 'server_tokens off;'
assert_contains 'nginx: TLS 1.2+' "$(nginx_tuning_render)" 'ssl_protocols TLSv1.2 TLSv1.3;'
assert_contains 'nginx: snippet' "$(nginx_snippet_render)" 'X-Content-Type-Options'
module_load swap
F_MEM_MB=1024
assert_eq 'swap auto при 1G RAM' "$(swap_size_mb)" 2048
F_MEM_MB=16384
assert_eq 'swap auto при 16G RAM' "$(swap_size_mb)" 4096
CONF[SWAP_SIZE]=8G
assert_eq 'swap 8G' "$(swap_size_mb)" 8192
CONF[SWAP_SIZE]=0
assert_eq 'swap 0' "$(swap_size_mb)" 0
CONF=()
module_load users
CONF[ADMIN_SSH_KEYS]='ssh-ed25519 AAAA a;ssh-rsa BBBB b'
assert_eq 'users: ключи из конфига' "$(admin_keys_collect | wc -l)" 2
CONF=()

t_section 'Аудит'
AUDIT_ROWS=() AUDIT_OK=0 AUDIT_WARN=0 AUDIT_FAIL=0
check_ok 'a'; check_warn 'b' 'hint'; check_fail 'c'
assert_eq 'счётчики' "$AUDIT_OK/$AUDIT_WARN/$AUDIT_FAIL" '1/1/1'
audit_exit_code; assert_rc 'код 2 при fail' 2 $?
assert_true 'json валиден' bash -c "$(declare -f audit_json json_str); FS=\$'\\x1f'; AUDIT_OK=1 AUDIT_WARN=1 AUDIT_FAIL=1; $(declare -p AUDIT_ROWS | sed 's/declare -a/declare -ga/'); audit_json | jq -e . >/dev/null"

t_section 'CLI без root'
B="$UBB_HOME/ubuntu-bootstrap"
assert_true 'version --json' bash -c "'$B' --json version | jq -e .version >/dev/null"
assert_true 'modules --json' bash -c "'$B' --json modules | jq -e 'length == 17' >/dev/null"
assert_contains 'help перечисляет команды' "$("$B" help)" 'wizard'
assert_contains 'help команды' "$("$B" help apply)" '--reapply'
out="$("$B" nosuch 2>&1)"; assert_rc 'неизвестная команда -> 2' 2 $?
out="$("$B" --set BAD apply 2>&1)"; assert_rc '--set без = -> 2' 2 $?
out="$("$B" apply 2>&1)"; assert_rc 'apply без root -> 1' 1 $? "$out"
assert_contains 'сообщение про sudo' "$out" sudo
out="$("$B" --dry-run --profile web config validate 2>&1)"; assert_rc 'config validate dry-run без root' 0 $? "$out"
out="$("$B" --dry-run --profile web --set NOSUCH=1 config validate 2>&1)"; assert_rc 'config validate ловит опечатку' 1 $? "$out"
assert_contains 'подсказка про список опций' "$out" 'config options'
assert_contains 'profiles web' "$("$B" profiles web)" 'MODULES='
assert_true 'install.sh --help' bash -c "'$UBB_HOME/install.sh' --help >/dev/null"
assert_true 'bash -n всех файлов' bash -c "for f in '$UBB_HOME'/ubuntu-bootstrap '$UBB_HOME'/install.sh '$UBB_HOME'/lib/*.sh '$UBB_HOME'/commands/*.sh '$UBB_HOME'/modules/*.sh; do bash -n \"\$f\" || exit 1; done"

t_summary
