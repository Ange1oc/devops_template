#!/usr/bin/env bash
#
# ubuntu-bootstrap.sh — интерактивный production bootstrap wizard для Ubuntu.
#
# Назначение: первичная безопасная настройка «голого» Ubuntu-сервера
# под production (Django + Docker + Nginx + TLS), с проверками состояния,
# бэкапами, валидацией конфигов и защитой от потери SSH-доступа.
#
# Поддержка: Ubuntu 22.04 / 24.04 / 26.04 LTS, amd64 / arm64.
#
# Режимы:
#   ./ubuntu-bootstrap.sh                 интерактивный мастер (все этапы)
#   ./ubuntu-bootstrap.sh --dry-run       показать план без изменений
#   ./ubuntu-bootstrap.sh --stage nginx   выполнить только один этап
#   ./ubuntu-bootstrap.sh --yes           неинтерактивно (только безопасные этапы)
#   ./ubuntu-bootstrap.sh --list          список этапов
#
# Решения опираются на: официальную документацию Ubuntu Server, OpenSSH,
# nginx.org, docs.docker.com, certbot.eff.org (EFF), Django deployment
# checklist, CIS Ubuntu Benchmark (уровень 1, выборочно).

set -uo pipefail

readonly VERSION="1.0.0"
RUN_TS="$(date +%Y%m%d-%H%M%S)"; readonly RUN_TS
readonly LOG_DIR="/var/log/server-bootstrap"
readonly BACKUP_ROOT="/var/backups/server-bootstrap"
readonly BACKUP_DIR="${BACKUP_ROOT}/${RUN_TS}"
LOG_FILE="${LOG_DIR}/bootstrap-${RUN_TS}.log"

# ---- глобальные флаги режимов ----------------------------------------------
DRY_RUN=0
ASSUME_YES=0        # неинтерактивный режим: безопасные значения по умолчанию
ONLY_STAGES=""      # список этапов через запятую

# ---- накопители для итогового отчёта ---------------------------------------
declare -a DONE_STEPS=() SKIPPED_STEPS=() WARNINGS_LIST=() CHANGED_FILES=()

# ---- данные, которыми этапы делятся между собой -----------------------------
DEPLOY_USER=""          # выбранный рабочий пользователь
SSH_PORT_CURRENT="22"   # фактический порт sshd
SSH_PORT_TARGET=""      # порт после hardening (если менялся)
NGINX_FLAVOR=""         # ubuntu | nginx.org
WANT_WEB=""             # планируется ли веб (для firewall)
PROJECT_DIR=""          # каталог проекта Django

# =============================================================================
# БАЗОВЫЕ ХЕЛПЕРЫ: вывод, логирование, вопросы, выполнение, бэкапы
# =============================================================================

C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';    C_RST=$'\033[0m'
[[ -t 1 ]] || { C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_BLD=""; C_RST=""; }

log()  { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null || true; }
info() { printf '%s\n' "${C_BLU}[i]${C_RST} $*";  log "INFO  $*"; }
ok()   { printf '%s\n' "${C_GRN}[✓]${C_RST} $*";  log "OK    $*"; }
warn() { printf '%s\n' "${C_YLW}[!]${C_RST} $*";  log "WARN  $*"; WARNINGS_LIST+=("$*"); }
err()  { printf '%s\n' "${C_RED}[✗]${C_RST} $*" >&2; log "ERROR $*"; }
die()  { err "$*"; err "Лог: $LOG_FILE  Бэкапы: $BACKUP_DIR"; exit 1; }

hr() { printf '%s\n' "------------------------------------------------------------"; }

# Вопрос да/нет. $1 — вопрос, $2 — значение по умолчанию (y|n).
# В режиме --yes возвращается значение по умолчанию без вопроса.
ask_yn() {
  local q="$1" def="${2:-y}" hint ans
  if (( ASSUME_YES )); then
    log "AUTO  ${q} -> ${def}"
    [[ "$def" == "y" ]]
    return
  fi
  [[ "$def" == "y" ]] && hint="Y/n" || hint="y/N"
  while true; do
    read -rp "${C_BLD}${q}${C_RST} [${hint}]: " ans </dev/tty
    ans="${ans:-$def}"
    case "${ans,,}" in
      y|yes|д|да) log "ASK   ${q} -> yes"; return 0 ;;
      n|no|н|нет) log "ASK   ${q} -> no";  return 1 ;;
    esac
  done
}

# Меню выбора. $1 — заголовок, $2 — номер по умолчанию, дальше — пункты.
# Результат (номер, с 1) кладётся в CHOICE.
CHOICE=""
ask_choice() {
  local title="$1" def="$2"; shift 2
  local opts=("$@") i ans
  echo "${C_BLD}${title}${C_RST}"
  for i in "${!opts[@]}"; do
    printf '  %d) %s\n' "$((i+1))" "${opts[$i]}"
  done
  if (( ASSUME_YES )); then
    CHOICE="$def"; log "AUTO  ${title} -> ${def}"; return
  fi
  while true; do
    read -rp "Выбор [${def}]: " ans </dev/tty
    ans="${ans:-$def}"
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#opts[@]} )); then
      CHOICE="$ans"; log "ASK   ${title} -> ${ans}"; return
    fi
  done
}

# Подтверждение опасного действия: нужно явно ввести слово "yes".
# В режиме --yes опасные действия НЕ выполняются.
confirm_danger() {
  local msg="$1" ans
  if (( ASSUME_YES )); then
    warn "Неинтерактивный режим: опасное действие пропущено: ${msg}"
    return 1
  fi
  echo "${C_RED}${C_BLD}ВНИМАНИЕ:${C_RST} ${msg}"
  read -rp "Введите 'yes' для подтверждения (иначе — отмена): " ans </dev/tty
  [[ "$ans" == "yes" ]]
}

# Ввод строки. $1 — приглашение, $2 — значение по умолчанию. Результат в REPLY_VAL.
REPLY_VAL=""
ask_input() {
  local prompt="$1" def="${2:-}"
  if (( ASSUME_YES )); then REPLY_VAL="$def"; return; fi
  read -rp "${prompt}${def:+ [$def]}: " REPLY_VAL </dev/tty
  REPLY_VAL="${REPLY_VAL:-$def}"
}

# Выполнение команды с логированием и поддержкой dry-run.
# ВАЖНО: никогда не передавать сюда команды с секретами в аргументах —
# командная строка попадает в лог.
run() {
  log "CMD   $*"
  if (( DRY_RUN )); then
    printf '%s\n' "${C_YLW}[dry-run]${C_RST} $*"
    return 0
  fi
  "$@" >>"$LOG_FILE" 2>&1
}

# То же, но вывод команды показывается пользователю.
run_visible() {
  log "CMD   $*"
  if (( DRY_RUN )); then
    printf '%s\n' "${C_YLW}[dry-run]${C_RST} $*"
    return 0
  fi
  "$@" 2>&1 | tee -a "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

# Бэкап файла с сохранением пути внутри BACKUP_DIR.
backup_file() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  (( DRY_RUN )) && { info "[dry-run] бэкап: $f"; return 0; }
  local dest="${BACKUP_DIR}${f}"
  mkdir -p "$(dirname "$dest")"
  cp -a "$f" "$dest"
  CHANGED_FILES+=("$f  (бэкап: $dest)")
  log "BKUP  $f -> $dest"
}

# Безопасная запись файла: бэкап + запись + права. Содержимое — через stdin.
# write_file <путь> <права> <владелец:группа>
write_file() {
  local path="$1" mode="${2:-0644}" owner="${3:-root:root}" content
  content="$(cat)"
  backup_file "$path"
  if (( DRY_RUN )); then
    info "[dry-run] запись файла: $path (mode=$mode owner=$owner)"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  chmod "$mode" "$path"
  chown "$owner" "$path"
  [[ " ${CHANGED_FILES[*]:-} " == *" $path "* ]] || CHANGED_FILES+=("$path")
  log "WRITE $path"
}

pkg_installed()  { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }
svc_active()     { systemctl is-active --quiet "$1" 2>/dev/null; }
svc_exists()     { systemctl list-unit-files "$1" 2>/dev/null | grep -q "$1"; }
port_listening() { ss -lnt "( sport = :$1 )" 2>/dev/null | tail -n +2 | grep -q .; }
cmd_exists()     { command -v "$1" >/dev/null 2>&1; }

# Проверка блокировок apt/dpkg перед установкой пакетов.
apt_ready() {
  if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
     fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
    err "apt/dpkg занят другим процессом (возможно, unattended-upgrades)."
    info "Подождите завершения или проверьте: ps aux | grep -E 'apt|dpkg'"
    return 1
  fi
  return 0
}

apt_install() {
  apt_ready || return 1
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# Есть ли у пользователя РАБОЧИЙ путь к sudo: группа + (пароль ИЛИ NOPASSWD).
# Членство в группе sudo без пароля и без NOPASSWD — бесполезно.
user_has_usable_sudo() {
  local u="$1"
  id -nG "$u" 2>/dev/null | grep -qw sudo || return 1
  [[ "$(passwd -S "$u" 2>/dev/null | awk '{print $2}')" == "P" ]] && return 0
  sudo -l -U "$u" 2>/dev/null | grep -q NOPASSWD && return 0
  return 1
}

record_done() { DONE_STEPS+=("$1"); }
record_skip() { SKIPPED_STEPS+=("$1"); }

# Начало этапа: баннер + вопрос «выполнять или пропустить».
# Возврат 1 = этап пропущен.
stage_begin() {
  local name="$1" desc="$2"
  echo; hr
  echo "${C_BLD}ЭТАП: ${name}${C_RST}"
  echo "  ${desc}"
  hr
  if ! ask_yn "Выполнить этот этап?" y; then
    record_skip "$name"
    info "Этап пропущен."
    return 1
  fi
  return 0
}

# =============================================================================
# ЭТАП 1. PREFLIGHT — проверка состояния сервера
# =============================================================================
stage_preflight() {
  stage_begin "Preflight-проверки" \
    "Проверка ОС, прав, SSH-сессии, портов, диска и установленного ПО." || return 0

  # --- ОС и архитектура ---
  local os_id="" os_ver="" arch
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"; os_ver="${VERSION_ID:-}"
  fi
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

  [[ "$os_id" == "ubuntu" ]] || die "Скрипт рассчитан на Ubuntu, обнаружено: ${os_id:-неизвестно}."
  case "$os_ver" in
    22.04|24.04|26.04) ok "Ubuntu ${os_ver} (${arch}) — поддерживается." ;;
    *) warn "Ubuntu ${os_ver} не тестировалась этим скриптом. Продолжайте на свой риск."
       ask_yn "Продолжить на неподдерживаемой версии?" n || die "Остановлено пользователем." ;;
  esac

  # --- права ---
  if (( EUID != 0 )); then
    die "Нужны root-права. Запустите: sudo $0 $*"
  fi
  ok "Права root подтверждены."

  # --- лог и бэкапы ---
  mkdir -p "$LOG_DIR" "$BACKUP_DIR"
  chmod 700 "$LOG_DIR" "$BACKUP_ROOT" "$BACKUP_DIR"
  ok "Лог: $LOG_FILE"
  ok "Каталог бэкапов: $BACKUP_DIR"

  # --- SSH-сессия и порт ---
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    ok "Подключение по SSH: ${SSH_CONNECTION%% *} -> порт ${SSH_CONNECTION##* }"
  else
    info "SSH-сессия не обнаружена (локальная консоль?). Часть SSH-защит станет менее рискованной."
  fi
  SSH_PORT_CURRENT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
  SSH_PORT_CURRENT="${SSH_PORT_CURRENT:-22}"
  info "Текущий порт sshd: ${SSH_PORT_CURRENT}"

  # --- слушающие порты ---
  echo
  info "Слушающие TCP-порты:"
  ss -lntp 2>/dev/null | awk 'NR>1 {print "    " $4 "  " $6}' | sort -u | head -25

  # --- диск ---
  local free_gb
  free_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
  if (( free_gb < 5 )); then
    warn "Свободно всего ${free_gb}G на /. Docker-образы и логи быстро займут место."
  else
    ok "Свободно на /: ${free_gb}G"
  fi

  # --- память и swap ---
  local swap_kb
  swap_kb="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
  if (( swap_kb == 0 )); then
    info "Swap отсутствует (этап Swap предложит создать)."
  else
    ok "Swap: $(( swap_kb / 1024 )) MiB"
  fi

  # --- установленное ПО ---
  echo
  info "Обнаруженное ПО:"
  local sw
  for sw in nginx docker certbot ufw fail2ban; do
    if cmd_exists "$sw"; then
      printf '    %-10s есть (%s)\n' "$sw" "$("$sw" --version 2>&1 | head -1 | cut -c1-60)"
    else
      printf '    %-10s нет\n' "$sw"
    fi
  done

  # --- сторонние apt-репозитории ---
  local extra_repos
  extra_repos="$(grep -rhE '^\s*deb ' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
                 | grep -vE 'ubuntu\.com|ubuntu\.sources' | head -5 || true)"
  if [[ -n "$extra_repos" ]]; then
    info "Сторонние apt-репозитории:"
    printf '    %s\n' "$extra_repos"
  fi

  # --- apt lock ---
  apt_ready || warn "apt сейчас занят — этапы установки пакетов могут подождать."

  echo; hr
  ask_yn "Preflight завершён. Продолжить настройку?" y || die "Остановлено пользователем."
  record_done "Preflight"
}

# =============================================================================
# ЭТАП 2. БАЗОВЫЕ ПАКЕТЫ
# =============================================================================
stage_packages() {
  stage_begin "Базовые системные пакеты" \
    "Минимальный набор утилит для дальнейшей настройки + apt update/upgrade." || return 0

  # Минимальный набор для production bootstrap: сеть, репозитории, диагностика.
  local pkgs=(ca-certificates curl gnupg lsb-release git unzip
              apt-transport-https software-properties-common
              htop iotop ncdu net-tools dnsutils jq rsync
              openssl needrestart)
  local missing=() p
  for p in "${pkgs[@]}"; do
    pkg_installed "$p" || missing+=("$p")
  done

  if ask_yn "Выполнить apt update + upgrade (обновление системы)?" y; then
    run apt-get update || { err "apt update завершился с ошибкой — см. лог."; return 1; }
    run_visible env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
      || warn "apt upgrade завершился с предупреждениями."
  fi

  if (( ${#missing[@]} == 0 )); then
    ok "Все базовые пакеты уже установлены."
  else
    info "Будут установлены: ${missing[*]}"
    if ask_yn "Установить недостающие пакеты?" y; then
      apt_install "${missing[@]}" || { err "Установка пакетов не удалась."; return 1; }
      ok "Базовые пакеты установлены."
    fi
  fi

  # Перезагрузка ядра после upgrade — только сообщаем, не перезагружаем сами.
  if [[ -f /var/run/reboot-required ]]; then
    warn "Система требует перезагрузку (обновление ядра). Сделайте её после завершения настройки."
  fi
  record_done "Базовые пакеты"
}

# Настройка sudo-аутентификации пользователя.
# adduser --disabled-password оставляет пароль заблокированным: пользователь
# может быть в группе sudo, но sudo им пользоваться НЕ сможет, пока не выбран
# один из режимов ниже. Пароль sudo — локальный; запрет паролей в SSH
# (PasswordAuthentication no) на него не влияет.
configure_sudo_auth() {
  local u="$1"
  id -nG "$u" 2>/dev/null | grep -qw sudo || return 0

  local pw_state sudoers_file="/etc/sudoers.d/90-${u}-nopasswd"
  # passwd -S: P = пароль задан, L = заблокирован, NP = отсутствует.
  pw_state="$(passwd -S "$u" 2>/dev/null | awk '{print $2}')"

  if [[ "$pw_state" == "P" ]]; then
    ok "У '$u' задан пароль — sudo будет запрашивать его (стандартный режим)."
    return 0
  fi
  if [[ -f "$sudoers_file" ]]; then
    ok "Для '$u' уже настроен sudo без пароля (${sudoers_file})."
    return 0
  fi

  warn "У '$u' НЕТ пароля: он в группе sudo, но sudo сейчас работать не будет."
  echo "  Варианты:"
  echo "    1) Задать пароль — sudo спрашивает его. Плюс: украденный SSH-ключ"
  echo "       не даёт мгновенный root. Рекомендуется для интерактивной работы."
  echo "    2) NOPASSWD — sudo без пароля. Удобно для единственного админа и"
  echo "       деплой-скриптов. Риск: компрометация ключа = сразу root."
  echo "    3) Оставить как есть — админ-задачи только под root."
  ask_choice "Режим sudo для '$u':" 1 \
    "Задать пароль (рекомендуется)" \
    "NOPASSWD — sudo без пароля" \
    "Оставить как есть (sudo не будет работать)"
  case "$CHOICE" in
    1)
      if (( DRY_RUN )); then info "[dry-run] passwd $u"; return 0; fi
      # passwd читает пароль напрямую с tty — в лог скрипта он не попадает.
      until passwd "$u" </dev/tty; do
        ask_yn "Не удалось задать пароль. Повторить?" y || return 0
      done
      ok "Пароль задан. sudo будет запрашивать его."
      ;;
    2)
      confirm_danger "'$u' сможет получать root вообще без пароля (NOPASSWD)." || return 0
      write_file "$sudoers_file" 0440 root:root <<EOF
${u} ALL=(ALL:ALL) NOPASSWD:ALL
EOF
      # Битый файл в sudoers.d ломает sudo для всех — валидация обязательна.
      if (( ! DRY_RUN )) && ! visudo -cf "$sudoers_file" >>"$LOG_FILE" 2>&1; then
        err "visudo забраковал файл — удаляю."
        rm -f "$sudoers_file"
        return 1
      fi
      ok "sudo без пароля настроен: ${sudoers_file}"
      ;;
    3)
      warn "sudo у '$u' пока не работает. НЕ запрещайте root-доступ, пока не решите это."
      ;;
  esac
}

# =============================================================================
# ЭТАП 3. ПОЛЬЗОВАТЕЛИ И ПРАВА
# =============================================================================
stage_users() {
  stage_begin "Пользователи и права" \
    "Создание/выбор deploy-пользователя, sudo, SSH-ключи." || return 0

  ask_choice "Сценарий работы с пользователем:" 1 \
    "Создать нового deploy-пользователя (рекомендуется: работа не под root)" \
    "Использовать существующего пользователя" \
    "Пропустить (продолжить под root — не рекомендуется для повседневной работы)"
  case "$CHOICE" in
    1)
      ask_input "Имя нового пользователя" "deploy"
      local u="$REPLY_VAL"
      if id "$u" &>/dev/null; then
        warn "Пользователь '$u' уже существует — использую его."
      else
        run adduser --disabled-password --gecos "" "$u" || { err "Не удалось создать пользователя."; return 1; }
        ok "Пользователь '$u' создан (вход по паролю отключён — только SSH-ключ)."
      fi
      DEPLOY_USER="$u"
      ;;
    2)
      ask_input "Имя существующего пользователя" ""
      local u="$REPLY_VAL"
      id "$u" &>/dev/null || { err "Пользователь '$u' не найден."; return 1; }
      # Системные пользователи (uid < 1000) не подходят для интерактивной работы.
      local uid; uid="$(id -u "$u")"
      if (( uid < 1000 )); then
        warn "'$u' — системный пользователь (uid=$uid). Использовать его для деплоя небезопасно."
        ask_yn "Всё равно использовать?" n || return 0
      fi
      DEPLOY_USER="$u"
      ;;
    3) record_skip "Пользователи"; return 0 ;;
  esac

  local home_dir; home_dir="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"

  # --- sudo ---
  if id -nG "$DEPLOY_USER" | grep -qw sudo; then
    ok "'$DEPLOY_USER' уже в группе sudo."
  else
    echo "  sudo-доступ: полное администрирование сервера."
    echo "  Без sudo: пользователь только деплоит код, админ-задачи — под root."
    if ask_yn "Выдать '$DEPLOY_USER' права sudo?" y; then
      run usermod -aG sudo "$DEPLOY_USER"
      ok "Добавлен в группу sudo."
    fi
  fi

  # --- КРИТИЧНО: группа sudo без пароля и без NOPASSWD не работает ---
  # (adduser --disabled-password создаёт пользователя БЕЗ пароля вообще)
  if id -nG "$DEPLOY_USER" | grep -qw sudo && ! user_has_usable_sudo "$DEPLOY_USER"; then
    echo
    warn "У '$DEPLOY_USER' нет пароля — sudo сейчас НЕ будет работать, несмотря на группу."
    echo "  Варианты подтверждения sudo:"
    echo "    Пароль: вводится при каждом sudo. SSH-вход по паролю это НЕ открывает"
    echo "      (PasswordAuthentication — отдельная настройка). Рубеж защиты при краже ключа."
    echo "    NOPASSWD: sudo без пароля, как у cloud-образов (ubuntu@AWS). Удобно,"
    echo "      но кража SSH-ключа = мгновенный root."
    ask_choice "Как '$DEPLOY_USER' будет подтверждать sudo?" 1 \
      "Задать пароль сейчас (рекомендуется)" \
      "NOPASSWD (sudo без пароля)" \
      "Настрою позже сам (SSH-этап не даст запретить root-вход до этого)"
    case "$CHOICE" in
      1)
        if (( DRY_RUN )); then
          info "[dry-run] passwd $DEPLOY_USER"
        else
          # passwd интерактивен и не пишет пароль ни в лог, ни в history.
          while ! passwd "$DEPLOY_USER" </dev/tty; do
            ask_yn "Попробовать ещё раз?" y || break
          done
        fi
        ;;
      2)
        write_file "/etc/sudoers.d/90-${DEPLOY_USER}" 0440 root:root <<EOF
${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL
EOF
        (( DRY_RUN )) || visudo -c >>"$LOG_FILE" 2>&1 \
          || { err "visudo -c не прошёл — удаляю файл."; rm -f "/etc/sudoers.d/90-${DEPLOY_USER}"; return 1; }
        ok "NOPASSWD настроен для '$DEPLOY_USER'."
        ;;
      3) warn "sudo у '$DEPLOY_USER' пока не работает — не отключайте root-доступ до настройки." ;;
    esac
    # Финальная проверка результата.
    if (( ! DRY_RUN )) && user_has_usable_sudo "$DEPLOY_USER"; then
      ok "Проверка: sudo у '$DEPLOY_USER' работоспособен."
    fi
  fi
  # Членство в группе sudo бесполезно без работающей аутентификации.
  configure_sudo_auth "$DEPLOY_USER"

  # --- SSH-ключи ---
  local ssh_dir="${home_dir}/.ssh" ak="${home_dir}/.ssh/authorized_keys"
  if [[ -s "$ak" ]]; then
    ok "authorized_keys уже существует ($(grep -c '' "$ak") ключ(ей)) — не перезаписываю."
    if ask_yn "Добавить ещё один публичный ключ?" n; then
      ask_input "Вставьте публичный ключ (ssh-ed25519/ssh-rsa ...)" ""
      [[ "$REPLY_VAL" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-) ]] || { err "Это не похоже на публичный ключ."; return 1; }
      backup_file "$ak"
      (( DRY_RUN )) || printf '%s\n' "$REPLY_VAL" >> "$ak"
      ok "Ключ добавлен."
    fi
  else
    info "У '$DEPLOY_USER' нет SSH-ключей. Без ключа вход по SSH будет невозможен после hardening."
    if ask_yn "Добавить публичный ключ сейчас?" y; then
      ask_input "Вставьте публичный ключ" ""
      if [[ "$REPLY_VAL" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-) ]]; then
        (( DRY_RUN )) || {
          mkdir -p "$ssh_dir"
          printf '%s\n' "$REPLY_VAL" >> "$ak"
        }
        ok "Ключ установлен."
      else
        err "Это не похоже на публичный ключ — пропускаю."
      fi
    elif [[ -n "${SSH_CONNECTION:-}" && -s "/root/.ssh/authorized_keys" ]]; then
      # Частый кейс: провайдер положил ключ только root'у.
      if ask_yn "Скопировать authorized_keys от root пользователю '$DEPLOY_USER'?" y; then
        (( DRY_RUN )) || { mkdir -p "$ssh_dir"; cp /root/.ssh/authorized_keys "$ak"; }
        ok "Ключи root скопированы."
      fi
    fi
  fi

  # Приведение прав в порядок (требование sshd StrictModes).
  if (( ! DRY_RUN )) && [[ -d "$ssh_dir" ]]; then
    chown -R "$DEPLOY_USER:$DEPLOY_USER" "$ssh_dir"
    chmod 700 "$ssh_dir"
    [[ -f "$ak" ]] && chmod 600 "$ak"
  fi
  ok "Права на ~/.ssh проверены."

  record_done "Пользователи (${DEPLOY_USER})"
}

# =============================================================================
# ЭТАП 4. SSH HARDENING
# =============================================================================
stage_ssh() {
  stage_begin "SSH hardening" \
    "Ключевой вход, запрет root по паролю, ограничение пользователей. С авто-откатом." || return 0

  local sshd_dir="/etc/ssh/sshd_config.d"
  local conf="${sshd_dir}/00-bootstrap-hardening.conf"
  [[ -d "$sshd_dir" ]] || { err "Нет ${sshd_dir} — слишком старая Ubuntu?"; return 1; }

  # --- проверка: у кого-то ДОЛЖЕН быть рабочий ключ, иначе запрет паролей = потеря доступа ---
  local key_user=""
  if [[ -n "$DEPLOY_USER" ]]; then
    local hd; hd="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
    [[ -s "${hd}/.ssh/authorized_keys" ]] && key_user="$DEPLOY_USER"
  fi
  [[ -z "$key_user" && -s /root/.ssh/authorized_keys ]] && key_user="root"
  if [[ -z "$key_user" ]]; then
    err "Ни у root, ни у '$DEPLOY_USER' нет authorized_keys."
    err "Запрет входа по паролю сейчас = гарантированная потеря доступа. Этап отменён."
    record_skip "SSH hardening (нет ключей)"
    return 0
  fi
  ok "Найден пользователь с SSH-ключом: ${key_user}"

  # --- порт ---
  local new_port="$SSH_PORT_CURRENT"
  echo "  Смена порта не защищает от целевых атак, но убирает ~99% фонового шума ботов."
  echo "  Риск: забыть порт / не открыть его в firewall = потеря доступа."
  if ask_yn "Сменить SSH-порт (сейчас: ${SSH_PORT_CURRENT})?" n; then
    ask_input "Новый порт (1024-65535)" "2222"
    new_port="$REPLY_VAL"
    [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 1024 && new_port <= 65535 )) \
      || { err "Некорректный порт."; return 1; }
    if port_listening "$new_port"; then
      err "Порт ${new_port} уже занят другим сервисом. Выберите другой."
      return 1
    fi
  fi

  # --- разрешённые пользователи ---
  local allow_users=""
  if ask_yn "Ограничить SSH-вход списком пользователей (AllowUsers)?" y; then
    local default_list="$key_user"
    [[ -n "$DEPLOY_USER" && "$DEPLOY_USER" != "$key_user" ]] && default_list="$key_user $DEPLOY_USER"
    ask_input "Пользователи через пробел" "$default_list"
    allow_users="$REPLY_VAL"
  fi

  # --- root-доступ ---
  local permit_root="prohibit-password"
  if [[ "$key_user" != "root" ]]; then
    # Запрещать root можно ТОЛЬКО если у key_user реально работает sudo:
    # группа sudo без пароля/NOPASSWD = потеря админ-доступа к серверу.
    if ! user_has_usable_sudo "$key_user"; then
      warn "У '$key_user' sudo НЕ работает (нет пароля и нет NOPASSWD)."
      warn "Запрет root-входа сейчас оставил бы сервер без администратора."
      info "Оставляю root-вход по ключу (prohibit-password). Исправьте sudo (этап users) и повторите."
    elif ask_yn "Полностью запретить SSH-вход под root (рекомендуется при наличии sudo-пользователя)?" y; then
      permit_root="no"
      # Root в AllowUsers быть не должен, если вход root запрещён.
      allow_users="${allow_users//root/}"
    fi
  else
    info "Ключ есть только у root — оставляю root-вход по ключу (prohibit-password)."
  fi

  # --- firewall: новый порт нужно открыть ДО перезапуска sshd ---
  if [[ "$new_port" != "$SSH_PORT_CURRENT" ]] && cmd_exists ufw && ufw status | grep -q "Status: active"; then
    info "UFW активен — открываю новый порт ${new_port} до применения конфига."
    run ufw allow "${new_port}/tcp" comment "SSH (bootstrap)"
  fi

  # --- показать и применить конфиг ---
  local plan
  plan="Port ${new_port}
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin ${permit_root}
MaxAuthTries 4
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2${allow_users:+
AllowUsers ${allow_users}}"

  echo; info "Планируемый конфиг ${conf}:"
  printf '%s\n' "$plan" | sed 's/^/    /'
  echo
  confirm_danger "Вход по паролю будет ЗАПРЕЩЁН. Убедитесь, что ключ '${key_user}' у вас на руках." \
    || { record_skip "SSH hardening (не подтверждено)"; return 0; }

  write_file "$conf" 0600 root:root <<< "$plan"

  (( DRY_RUN )) && { record_done "SSH hardening (dry-run)"; return 0; }

  # Валидация ДО перезапуска — sshd -t не трогает работающий демон.
  if ! sshd -t 2>>"$LOG_FILE"; then
    err "Новый конфиг sshd невалиден. Откатываю."
    rm -f "$conf"
    return 1
  fi
  ok "Конфиг sshd валиден."

  # --- страховка: авто-откат через 10 минут, если пользователь не подтвердит вход ---
  local guard="${BACKUP_DIR}/ssh_rollback.sh"
  cat > "$guard" <<EOF
#!/usr/bin/env bash
# Авто-откат SSH-конфига, если новый вход не был подтверждён.
rm -f "$conf"
systemctl reload ssh || systemctl reload sshd
logger -t bootstrap "SSH hardening откачен автоматически (вход не подтверждён)"
EOF
  chmod 700 "$guard"
  if cmd_exists systemd-run; then
    systemd-run --on-active=10m --unit=bootstrap-ssh-guard "$guard" >>"$LOG_FILE" 2>&1 \
      && info "Страховка: если через 10 минут вход не подтверждён — конфиг откатится сам."
  fi

  run systemctl reload ssh || run systemctl reload sshd || { err "Не удалось перезагрузить sshd."; return 1; }
  SSH_PORT_TARGET="$new_port"

  echo
  hr
  echo "${C_BLD}ПРОВЕРКА ДОСТУПА — НЕ ЗАКРЫВАЙТЕ ЭТУ СЕССИЮ!${C_RST}"
  echo "  Откройте НОВЫЙ терминал и подключитесь:"
  echo "    ssh -p ${new_port} ${key_user}@<IP-сервера>"
  hr
  if ask_yn "Вход в НОВОЙ сессии успешен?" n; then
    # Отменяем страховочный таймер.
    systemctl stop bootstrap-ssh-guard.timer 2>/dev/null || true
    systemctl reset-failed bootstrap-ssh-guard.service 2>/dev/null || true
    ok "SSH hardening применён и подтверждён."
    if [[ "$new_port" != "$SSH_PORT_CURRENT" ]] && cmd_exists ufw && ufw status | grep -q "Status: active"; then
      ask_yn "Закрыть старый SSH-порт ${SSH_PORT_CURRENT} в UFW?" y \
        && run ufw delete allow "${SSH_PORT_CURRENT}/tcp" 2>/dev/null || true
    fi
    SSH_PORT_CURRENT="$new_port"
    record_done "SSH hardening (порт ${new_port}, ключевой вход)"
  else
    warn "Вход не подтверждён — откатываю конфиг немедленно."
    bash "$guard"
    systemctl stop bootstrap-ssh-guard.timer 2>/dev/null || true
    record_skip "SSH hardening (откат: вход не подтверждён)"
  fi
}

# =============================================================================
# ЭТАП 5. FIREWALL (UFW)
# =============================================================================
stage_firewall() {
  stage_begin "Firewall (UFW)" \
    "Deny по умолчанию, разрешение SSH/HTTP/HTTPS. Учёт Docker-обхода UFW." || return 0

  pkg_installed ufw || { apt_install ufw || return 1; }

  local cur_ssh="${SSH_PORT_TARGET:-$SSH_PORT_CURRENT}"

  if ufw status | grep -q "Status: active"; then
    info "UFW уже активен. Текущие правила:"
    ufw status numbered | sed 's/^/    /'
    ask_yn "Пересмотреть правила (добавить недостающие)?" y || { record_skip "Firewall (уже настроен)"; return 0; }
  fi

  # Политики по умолчанию (CIS 3.5.x): всё входящее — запрещено.
  run ufw default deny incoming
  run ufw default allow outgoing

  # SSH — обязательно ДО включения, иначе потеря доступа.
  info "Разрешаю SSH-порт ${cur_ssh} (без этого включать UFW нельзя)."
  echo "  'ufw limit' дополнительно троттлит brute force (6 подключений / 30 сек с одного IP)."
  if ask_yn "Использовать 'ufw limit' для SSH (рекомендуется)?" y; then
    run ufw limit "${cur_ssh}/tcp" comment "SSH"
  else
    run ufw allow "${cur_ssh}/tcp" comment "SSH"
  fi

  if [[ -z "$WANT_WEB" ]]; then
    ask_yn "На сервере будет веб (Nginx, HTTP/HTTPS)?" y && WANT_WEB="yes" || WANT_WEB="no"
  fi
  if [[ "$WANT_WEB" == "yes" ]]; then
    run ufw allow 80/tcp  comment "HTTP"
    run ufw allow 443/tcp comment "HTTPS"
    # HTTP/3 (QUIC) работает по UDP 443.
    ask_yn "Открыть 443/udp для HTTP/3 (QUIC)?" y && run ufw allow 443/udp comment "HTTP/3"
  fi

  # --- ключевое предупреждение: Docker обходит UFW ---
  echo
  warn "Docker пишет правила напрямую в iptables и ОБХОДИТ UFW:"
  echo "    порт, опубликованный как '-p 8000:8000', будет доступен снаружи,"
  echo "    даже если UFW его не разрешал."
  echo "  Защита (выберите основную):"
  echo "    1) Публиковать порты только на localhost: '127.0.0.1:8000:8000'"
  echo "       (это делают шаблоны данного скрипта) — рекомендуемый способ."
  echo "    2) Дополнительно: правило в цепочке DOCKER-USER, блокирующее"
  echo "       внешний доступ к контейнерам, кроме трафика от Nginx."
  if ask_yn "Добавить страховочное правило DOCKER-USER в /etc/ufw/after.rules?" n; then
    local ext_if
    ext_if="$(ip route show default | awk '{print $5; exit}')"
    if [[ -z "$ext_if" ]]; then
      warn "Не удалось определить внешний интерфейс — правило пропущено."
    else
      backup_file /etc/ufw/after.rules
      if grep -q "BEGIN BOOTSTRAP DOCKER-USER" /etc/ufw/after.rules 2>/dev/null; then
        ok "Правило DOCKER-USER уже добавлено ранее."
      elif (( ! DRY_RUN )); then
        cat >> /etc/ufw/after.rules <<EOF

# BEGIN BOOTSTRAP DOCKER-USER
# Блокируем новые входящие соединения из внешней сети напрямую к контейнерам.
# Контейнеры остаются доступны с localhost (через Nginx) и изнутри docker-сетей.
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -i ${ext_if} -m conntrack --ctstate NEW -j DROP
-A DOCKER-USER -j RETURN
COMMIT
# END BOOTSTRAP DOCKER-USER
EOF
        CHANGED_FILES+=("/etc/ufw/after.rules")
        ok "Правило DOCKER-USER добавлено (применится при перезагрузке UFW)."
        warn "Если позже понадобится прямой доступ к порту контейнера снаружи —"
        warn "добавьте исключение в DOCKER-USER перед правилом DROP."
      fi
    fi
  fi

  # --- включение ---
  if ! ufw status | grep -q "Status: active"; then
    confirm_danger "UFW будет включён. SSH-порт ${cur_ssh} разрешён. Неверный порт = потеря доступа." \
      || { record_skip "Firewall (включение не подтверждено)"; return 0; }
    run ufw --force enable || { err "Не удалось включить UFW."; return 1; }
  else
    run ufw reload
  fi

  ok "UFW активен. Итоговые правила:"
  (( DRY_RUN )) || ufw status verbose | sed 's/^/    /'
  record_done "Firewall (UFW, SSH:${cur_ssh}${WANT_WEB:+, web})"
}

# =============================================================================
# ЭТАП 6. SWAP
# =============================================================================
stage_swap() {
  stage_begin "Swap" \
    "Страховка от OOM-killer на серверах с небольшой RAM." || return 0

  local swap_kb ram_mb
  swap_kb="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
  ram_mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"

  if (( swap_kb > 0 )); then
    ok "Swap уже настроен: $(( swap_kb / 1024 )) MiB."
    ask_yn "Оставить как есть?" y && { record_done "Swap (без изменений)"; return 0; }
  fi

  echo "  Swap полезен: страхует от внезапного OOM (например, при сборке Docker-образов)."
  echo "  Swap мешает: на дешёвых дисках может маскировать нехватку RAM деградацией скорости."
  # Практика для небольших серверов: swap ≈ RAM при RAM ≤ 4G, иначе 4G достаточно.
  local rec_gb=2
  (( ram_mb <= 2048 )) && rec_gb=2
  (( ram_mb > 2048 && ram_mb <= 4096 )) && rec_gb=4
  (( ram_mb > 4096 )) && rec_gb=4
  info "RAM: ${ram_mb} MiB. Рекомендуемый swap: ${rec_gb}G."

  ask_yn "Создать swap-файл?" y || { record_skip "Swap"; return 0; }
  ask_input "Размер swap (например 2G, 4G)" "${rec_gb}G"
  local size="$REPLY_VAL"

  [[ -f /swapfile ]] && { err "/swapfile уже существует, но не активен? Разберитесь вручную."; return 1; }
  local need_gb free_gb
  need_gb="${size%G}"
  free_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
  (( free_gb > need_gb + 2 )) || { err "Недостаточно места: свободно ${free_gb}G, нужно ${need_gb}G + запас."; return 1; }

  run fallocate -l "$size" /swapfile || run dd if=/dev/zero of=/swapfile bs=1M count=$(( need_gb * 1024 ))
  run chmod 600 /swapfile
  run mkswap /swapfile
  run swapon /swapfile

  # Персистентность через fstab + умеренный swappiness для серверов.
  if ! grep -q '^/swapfile' /etc/fstab; then
    backup_file /etc/fstab
    (( DRY_RUN )) || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    CHANGED_FILES+=("/etc/fstab")
  fi
  write_file /etc/sysctl.d/98-swap.conf 0644 root:root <<'EOF'
# Сервер: использовать swap только при реальной нехватке памяти
vm.swappiness=10
EOF
  run sysctl --system

  (( DRY_RUN )) || swapon --show | sed 's/^/    /'
  ok "Swap ${size} создан и добавлен в fstab."
  record_done "Swap (${size})"
}

# =============================================================================
# ЭТАП 7. ЛИМИТЫ И SYSCTL
# =============================================================================
stage_limits() {
  stage_begin "Системные лимиты и sysctl" \
    "Файловые дескрипторы для Nginx/Docker + минимальный сетевой hardening ядра." || return 0

  info "Текущий лимит nofile (root): $(ulimit -n)"
  echo "  Дефолтные 1024 дескриптора — узкое место для Nginx и нагруженных приложений."
  echo "  Экстремальные значения (миллионы) не нужны и маскируют утечки — берём разумные 65535."

  if ask_yn "Поднять nofile до 65535 для системных сервисов и пользователей?" y; then
    # Лимиты для интерактивных сессий (PAM).
    write_file /etc/security/limits.d/00-bootstrap.conf 0644 root:root <<'EOF'
*    soft nofile 65535
*    hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
    # Nginx под systemd читает не limits.conf, а свои LimitNOFILE.
    if svc_exists nginx.service; then
      write_file /etc/systemd/system/nginx.service.d/limits.conf 0644 root:root <<'EOF'
[Service]
LimitNOFILE=65535
EOF
      run systemctl daemon-reload
      info "Лимит для nginx применится при следующем restart (не reload) nginx."
    fi
    ok "Лимиты nofile настроены (интерактивные сессии — после перелогина)."
  fi

  if ask_yn "Применить минимальный сетевой sysctl hardening (по CIS L1)?" y; then
    write_file /etc/sysctl.d/00-bootstrap-hardening.conf 0644 root:root <<'EOF'
# Минимальный сетевой hardening (CIS Ubuntu Benchmark, уровень 1)
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
# Защита файловой системы от классических симлинк-атак
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
kernel.kptr_restrict = 1
kernel.dmesg_restrict = 1
EOF
    run sysctl --system && ok "sysctl hardening применён."
    info "Примечание: ip_forward НЕ отключаю — он нужен Docker."
  fi
  record_done "Лимиты и sysctl"
}

# =============================================================================
# ЭТАП 8. БАЗОВАЯ ЗАЩИТА (updates, fail2ban)
# =============================================================================
stage_security() {
  stage_begin "Базовая защита сервера" \
    "Автоматические security-обновления, fail2ban, аудит прав на файлы." || return 0

  # --- unattended-upgrades ---
  echo "  unattended-upgrades: автоматическая установка security-обновлений Ubuntu."
  echo "  Плюс: закрывает CVE без вашего участия. Минус: редкие ночные рестарты сервисов."
  if ask_yn "Включить автоматические security-обновления?" y; then
    apt_install unattended-upgrades || return 1
    write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 root:root <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    ok "unattended-upgrades включён (только security-канал по умолчанию Ubuntu)."
    info "Проверка: sudo unattended-upgrade --dry-run --debug"
  fi

  # --- fail2ban ---
  echo
  echo "  fail2ban: банит IP после N неудачных SSH-входов."
  echo "  Плюс: режет brute force. Минус: можно забанить себя при опечатках в пароле/ключе."
  if ask_yn "Установить и настроить fail2ban для SSH?" y; then
    apt_install fail2ban || return 1
    local cur_ssh="${SSH_PORT_TARGET:-$SSH_PORT_CURRENT}"
    # backend=systemd обязателен на Ubuntu 24.04+: auth.log может отсутствовать.
    write_file /etc/fail2ban/jail.d/sshd.local 0644 root:root <<EOF
[sshd]
enabled = true
backend = systemd
port = ${cur_ssh}
maxretry = 5
findtime = 10m
bantime = 1h
EOF
    run systemctl enable --now fail2ban
    if (( ! DRY_RUN )); then
      sleep 2
      fail2ban-client status sshd >>"$LOG_FILE" 2>&1 \
        && ok "fail2ban активен (jail: sshd, порт ${cur_ssh})." \
        || warn "fail2ban запущен, но jail sshd не поднялся — проверьте: fail2ban-client status"
    fi
    info "Откат: systemctl disable --now fail2ban; разбан: fail2ban-client unban <IP>"
  fi

  # --- быстрый аудит опасных прав ---
  if ask_yn "Проверить опасные права на файлы (world-readable секреты, .env)?" y; then
    info "Ищу world-readable .env/дампы в типовых местах (до 10 результатов):"
    local found
    found="$(find /root /home /opt /srv -maxdepth 4 \
             \( -name '*.env' -o -name '.env*' -o -name '*.sql' -o -name '*.dump' \) \
             -perm -o+r 2>/dev/null | head -10 || true)"
    if [[ -n "$found" ]]; then
      warn "Найдены файлы, доступные всем на чтение:"
      printf '    %s\n' "$found"
      info "Исправление: chmod 600 <файл>; chown <владелец> <файл>"
    else
      ok "Опасных world-readable секретов не найдено."
    fi
  fi
  record_done "Базовая защита"
}

# =============================================================================
# ЭТАП 9. NGINX
# =============================================================================
stage_nginx() {
  stage_begin "Nginx" \
    "Установка из репозитория Ubuntu или официального nginx.org (stable/mainline)." || return 0

  # --- если уже установлен ---
  if cmd_exists nginx; then
    local cur_ver; cur_ver="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
    info "Nginx уже установлен: ${cur_ver}"
    if dpkg -s nginx 2>/dev/null | grep -q "nginx.org"; then NGINX_FLAVOR="nginx.org"; else NGINX_FLAVOR="ubuntu"; fi
    ask_choice "Что сделать с существующим Nginx?" 1 \
      "Оставить как есть (только проверить конфиг)" \
      "Обновить в рамках текущего источника" \
      "Переустановить из другого источника (осторожно: разные пути конфигов)"
    case "$CHOICE" in
      1) run nginx -t && ok "Конфиг валиден." || warn "Конфиг Nginx содержит ошибки!"
         record_done "Nginx (без изменений)"; return 0 ;;
      2) apt_install --only-upgrade nginx && ok "Nginx обновлён."
         record_done "Nginx (обновлён)"; return 0 ;;
      3) warn "Пакеты Ubuntu и nginx.org используют разные структуры конфигов"
         warn "(sites-enabled против conf.d). Миграцию конфигов делайте вручную."
         confirm_danger "Существующие конфиги будут сохранены, но могут перестать подключаться." || return 0 ;;
    esac
  fi

  # --- выбор источника ---
  echo "  Источники установки:"
  echo "    Ubuntu-пакет: версия заморожена на момент релиза Ubuntu, патчи безопасности"
  echo "      бэкпортируются Canonical. Выбирайте, если важна максимальная предсказуемость."
  echo "    nginx.org stable: свежая стабильная ветка от разработчиков Nginx."
  echo "      Рекомендуется для production — новые фичи (HTTP/3) + официальная поддержка."
  echo "    nginx.org mainline: ветка активной разработки. Сами разработчики Nginx"
  echo "      рекомендуют её как основную, но обновления чаще. Для тех, кто следит за релизами."
  ask_choice "Источник установки Nginx:" 2 \
    "Ubuntu-пакет (консервативно)" \
    "nginx.org stable (рекомендуется)" \
    "nginx.org mainline (самые свежие версии)"

  local repo_url=""
  case "$CHOICE" in
    1) NGINX_FLAVOR="ubuntu" ;;
    2) NGINX_FLAVOR="nginx.org"; repo_url="http://nginx.org/packages/ubuntu" ;;
    3) NGINX_FLAVOR="nginx.org"; repo_url="http://nginx.org/packages/mainline/ubuntu" ;;
  esac

  if [[ "$NGINX_FLAVOR" == "nginx.org" ]]; then
    # Ключ и репозиторий — строго по официальной инструкции nginx.org.
    local keyring="/usr/share/keyrings/nginx-archive-keyring.gpg"
    if [[ ! -f "$keyring" ]]; then
      if (( DRY_RUN )); then
        info "[dry-run] импорт ключа nginx.org -> $keyring"
      else
        curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o "$keyring" \
          || { err "Не удалось скачать ключ nginx.org."; return 1; }
        # Сверка отпечатка ключа с официальным (docs nginx.org).
        local fpr
        fpr="$(gpg --dry-run --quiet --no-keyring --import --import-options import-show "$keyring" 2>/dev/null \
               | grep -oE '[0-9A-F]{40}' | head -1)"
        if [[ "$fpr" != "573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62" ]]; then
          err "Отпечаток ключа nginx.org не совпал с официальным! Установка прервана."
          rm -f "$keyring"
          return 1
        fi
        ok "Ключ nginx.org проверен по отпечатку."
      fi
    fi
    write_file /etc/apt/sources.list.d/nginx.list 0644 root:root <<EOF
deb [signed-by=${keyring}] ${repo_url} $(lsb_release -cs) nginx
EOF
    # Pinning: пакеты nginx.org приоритетнее Ubuntu, чтобы не было каши версий.
    write_file /etc/apt/preferences.d/99nginx 0644 root:root <<'EOF'
Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: 900
EOF
    run apt-get update || { err "apt update с репозиторием nginx.org не прошёл."; return 1; }
  fi

  # --- показать доступные версии, дать выбрать конкретную ---
  if (( ! DRY_RUN )); then
    info "Доступные версии nginx:"
    apt-cache madison nginx | head -5 | sed 's/^/    /'
  fi
  ask_input "Версия (Enter = последняя доступная, либо строка версии из списка)" ""
  local ver_arg=()
  if [[ -n "$REPLY_VAL" ]]; then
    if apt-cache madison nginx | grep -qF "$REPLY_VAL"; then
      ver_arg=("nginx=${REPLY_VAL}")
    else
      warn "Версия '${REPLY_VAL}' недоступна. Доступные показаны выше — ставлю последнюю."
    fi
  fi

  apt_install "${ver_arg[@]:-nginx}" || { err "Установка Nginx не удалась."; return 1; }
  run systemctl enable --now nginx
  ok "Nginx установлен: $(nginx -v 2>&1 || true)"

  # --- базовые security headers (общий сниппет, подключается в site-конфигах) ---
  if ask_yn "Создать сниппет с базовыми security headers (OWASP)?" y; then
    write_file /etc/nginx/snippets/security-headers.conf 0644 root:root <<'EOF'
# Базовые заголовки безопасности (OWASP Secure Headers Project).
# Подключение в server{}: include snippets/security-headers.conf;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
# CSP и HSTS сознательно не включены: их нужно настраивать под конкретный сайт.
EOF
    # У nginx.org-пакета нет каталога snippets в include по умолчанию — это ок,
    # сниппет подключается явно из server{}.
    ok "Сниппет security headers создан."
  fi

  run nginx -t || { err "Итоговый конфиг Nginx невалиден!"; return 1; }
  record_done "Nginx (${NGINX_FLAVOR})"
  WANT_WEB="yes"
}

# =============================================================================
# ЭТАП 10. CERTBOT / TLS
# =============================================================================
stage_certbot() {
  stage_begin "Certbot и TLS (Let's Encrypt)" \
    "Установка certbot, проверка DNS, выпуск сертификата, авто-продление." || return 0

  cmd_exists nginx || { warn "Nginx не установлен — сначала выполните этап nginx."; record_skip "Certbot (нет nginx)"; return 0; }

  # --- установка ---
  if ! cmd_exists certbot; then
    echo "  EFF официально рекомендует установку через snap (всегда свежая версия,"
    echo "  авто-продление из коробки). apt-версия проще, но заметно старее."
    ask_choice "Способ установки certbot:" 1 \
      "snap (официальная рекомендация EFF)" \
      "apt (python3-certbot-nginx, консервативно)"
    if [[ "$CHOICE" == "1" ]]; then
      cmd_exists snap || apt_install snapd || return 1
      run snap install core 2>/dev/null || true
      run snap install --classic certbot || { err "snap install certbot не удался."; return 1; }
      (( DRY_RUN )) || ln -sf /snap/bin/certbot /usr/bin/certbot
    else
      apt_install certbot python3-certbot-nginx || return 1
    fi
    ok "Certbot установлен."
  else
    ok "Certbot уже установлен: $(certbot --version 2>&1)"
  fi

  # --- домен и DNS ---
  ask_input "Домен(ы) через пробел (например: example.com www.example.com)" ""
  [[ -n "$REPLY_VAL" ]] || { info "Домен не указан — выпуск сертификата пропущен."; record_skip "Certbot (без домена)"; return 0; }
  local domains=() d; read -ra domains <<< "$REPLY_VAL"
  local primary="${domains[0]}"

  # Проверка: домен должен резолвиться в IP этого сервера, иначе HTTP-01 не пройдёт.
  local server_ip dns_ip dns_fail=0
  server_ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
  for d in "${domains[@]}"; do
    dns_ip="$(dig +short A "$d" 2>/dev/null | tail -1)"
    if [[ -z "$dns_ip" ]]; then
      warn "Домен ${d} не резолвится в A-запись."; dns_fail=1
    elif [[ "$dns_ip" != "$server_ip" ]]; then
      warn "Домен ${d} -> ${dns_ip}, а сервер имеет IP ${server_ip}. HTTP-01 challenge не пройдёт."
      dns_fail=1
    else
      ok "DNS: ${d} -> ${dns_ip} (совпадает с сервером)."
    fi
  done
  if (( dns_fail )); then
    ask_yn "DNS не готов. Всё равно продолжить (сертификат, скорее всего, не выпустится)?" n \
      || { record_skip "Certbot (DNS не готов)"; return 0; }
  fi

  # Порт 80 должен быть доступен для challenge.
  port_listening 80 || warn "Порт 80 никем не слушается — убедитесь, что Nginx запущен."

  # --- существующий сертификат? ---
  if [[ -d "/etc/letsencrypt/live/${primary}" ]]; then
    ok "Сертификат для ${primary} уже существует."
    ask_yn "Только проверить продление (certbot renew --dry-run)?" y && {
      run_visible certbot renew --dry-run && ok "Тест продления пройден."
      record_done "Certbot (существующий сертификат проверен)"; return 0
    }
  fi

  # --- минимальный конфиг, если для домена нет server_name ---
  if ! grep -rqs "server_name.*${primary}" /etc/nginx/ 2>/dev/null; then
    info "В Nginx нет конфига для ${primary} — создаю минимальный HTTP-конфиг для выпуска сертификата."
    local site_conf
    if [[ -d /etc/nginx/sites-available ]]; then
      site_conf="/etc/nginx/sites-available/${primary}.conf"
    else
      site_conf="/etc/nginx/conf.d/${primary}.conf"
    fi
    write_file "$site_conf" 0644 root:root <<EOF
# Минимальный конфиг для выпуска сертификата.
# После установки TLS certbot дополнит его, дальше расширяйте под приложение.
server {
    listen 80;
    listen [::]:80;
    server_name ${domains[*]};
    root /var/www/html;
    location / { return 200 "bootstrap: ok\n"; add_header Content-Type text/plain; }
}
EOF
    if [[ -d /etc/nginx/sites-enabled && ! -e "/etc/nginx/sites-enabled/${primary}.conf" ]]; then
      run ln -s "$site_conf" "/etc/nginx/sites-enabled/${primary}.conf"
    fi
    run nginx -t && run systemctl reload nginx || { err "Nginx не принял минимальный конфиг."; return 1; }
  fi

  # --- выпуск ---
  ask_choice "Действие:" 1 \
    "Выпустить сертификат сейчас (certbot --nginx)" \
    "Только подготовить (выпустить позже вручную)"
  if [[ "$CHOICE" == "1" ]]; then
    ask_input "E-mail для уведомлений Let's Encrypt" ""
    local email_arg=(--register-unsafely-without-email)
    [[ -n "$REPLY_VAL" ]] && email_arg=(-m "$REPLY_VAL")
    local dom_args=()
    for d in "${domains[@]}"; do dom_args+=(-d "$d"); done
    # --nginx сам правит конфиг и настраивает reload; --redirect включает HTTP->HTTPS.
    if run_visible certbot --nginx "${dom_args[@]}" "${email_arg[@]}" \
         --agree-tos --no-eff-email --redirect --keep-until-expiring; then
      ok "Сертификат выпущен, HTTP->HTTPS redirect включён."
    else
      err "Выпуск не удался. Частые причины: DNS, закрытый 80 порт, rate-limit Let's Encrypt."
      return 1
    fi
    # Авто-продление: snap ставит systemd-таймер сам; проверяем и тестируем.
    if (( ! DRY_RUN )); then
      systemctl list-timers 2>/dev/null | grep -q certbot \
        && ok "Таймер авто-продления активен." \
        || warn "Таймер продления не найден — проверьте: systemctl list-timers | grep certbot"
      run certbot renew --dry-run && ok "Тестовое продление прошло успешно."
    fi
  else
    info "Для выпуска позже: certbot --nginx -d ${primary} ..."
  fi
  record_done "Certbot (${primary})"
}

# =============================================================================
# ЭТАП 11. DOCKER
# =============================================================================
stage_docker() {
  stage_begin "Docker и Docker Compose" \
    "Официальный репозиторий Docker, compose-plugin, daemon.json, безопасность." || return 0

  # --- конфликтующие runtime ---
  local conflict
  for conflict in docker.io podman-docker containerd runc; do
    if pkg_installed "$conflict" && ! pkg_installed docker-ce; then
      warn "Установлен пакет '${conflict}' (не официальный Docker CE)."
      echo "  Официальная документация Docker рекомендует удалить дистрибутивные пакеты"
      echo "  перед установкой docker-ce, чтобы избежать конфликтов."
      if ask_yn "Удалить '${conflict}' перед установкой Docker CE?" y; then
        run apt-get remove -y "$conflict"
      fi
    fi
  done

  if cmd_exists docker && docker version --format '{{.Server.Version}}' &>/dev/null; then
    ok "Docker уже установлен: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
    ask_yn "Обновить Docker до последней версии из его репозитория?" n \
      && apt_install --only-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    echo "  Ставлю из официального репозитория docs.docker.com: свежие версии,"
    echo "  security-патчи напрямую от Docker, включает compose-plugin и buildx."
    echo "  Rootless Docker безопаснее, но сложнее с сетями/портами <1024 —"
    echo "  для типового single-server production обычно берут rootful + аккуратные практики."
    ask_yn "Установить Docker CE (rootful) из официального репозитория?" y || { record_skip "Docker"; return 0; }

    # Строго по официальной инструкции docs.docker.com/engine/install/ubuntu/
    local keyring="/etc/apt/keyrings/docker.asc"
    if (( ! DRY_RUN )); then
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$keyring" \
        || { err "Не удалось скачать GPG-ключ Docker."; return 1; }
      chmod a+r "$keyring"
    fi
    write_file /etc/apt/sources.list.d/docker.list 0644 root:root <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable
EOF
    run apt-get update || return 1
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
      || { err "Установка Docker не удалась."; return 1; }
    run systemctl enable --now docker
    ok "Docker установлен: $(docker --version 2>/dev/null)"
  fi

  # --- daemon.json: ротация логов и live-restore ---
  if [[ -f /etc/docker/daemon.json ]]; then
    info "/etc/docker/daemon.json уже существует — не перезаписываю."
    info "Рекомендуемые ключи: log-driver=json-file c ротацией, live-restore=true."
  elif ask_yn "Создать /etc/docker/daemon.json (ротация логов + live-restore)?" y; then
    write_file /etc/docker/daemon.json 0644 root:root <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" },
  "live-restore": true,
  "default-ulimits": { "nofile": { "Name": "nofile", "Soft": 65535, "Hard": 65535 } }
}
EOF
    # live-restore: контейнеры переживают перезапуск демона (обновления Docker).
    run systemctl restart docker || { err "Docker не поднялся с новым daemon.json!"; return 1; }
    ok "daemon.json применён (ротация логов спасает диск от переполнения)."
  fi

  # --- docker-группа ---
  if [[ -n "$DEPLOY_USER" ]]; then
    echo
    warn "Членство в группе docker = фактически root-доступ к серверу:"
    echo "    docker run -v /:/host ... даёт полный доступ к файловой системе."
    echo "  Альтернатива: работать с Docker через 'sudo docker ...' — каждый вызов"
    echo "  осознан и логируется в auth.log. Для одного доверенного админа группа"
    echo "  допустима, для многопользовательского сервера — нет."
    ask_choice "Доступ '${DEPLOY_USER}' к Docker:" 2 \
      "Добавить в группу docker (удобно, но = root)" \
      "Через sudo (безопаснее, рекомендуется)" \
      "Не решать сейчас"
    if [[ "$CHOICE" == "1" ]]; then
      confirm_danger "Пользователь '${DEPLOY_USER}' получит эквивалент root через docker-группу." \
        && { run usermod -aG docker "$DEPLOY_USER"; ok "Добавлен в группу docker (нужен перелогин)."; }
    fi
  fi

  # --- аудит существующих контейнеров ---
  if (( ! DRY_RUN )) && docker ps -q 2>/dev/null | grep -q .; then
    info "Запущенные контейнеры:"
    docker ps --format '    {{.Names}}  {{.Ports}}' | head -10
    # Привилегированные контейнеры и проброшенный docker.sock — красные флаги.
    local privileged
    privileged="$(docker ps -q | xargs -r docker inspect --format \
      '{{.Name}} privileged={{.HostConfig.Privileged}} sock={{range .Mounts}}{{if eq .Source "/var/run/docker.sock"}}yes{{end}}{{end}}' 2>/dev/null \
      | grep -E 'privileged=true|sock=yes' || true)"
    [[ -n "$privileged" ]] && { warn "Контейнеры с повышенными привилегиями / docker.sock:"; printf '    %s\n' "$privileged"; }
    # Порты, опубликованные на 0.0.0.0 — обходят UFW.
    docker ps --format '{{.Ports}}' | grep -q '0.0.0.0' \
      && warn "Есть контейнеры с портами на 0.0.0.0 — они доступны снаружи В ОБХОД UFW."
  fi

  (( ! DRY_RUN )) && run docker run --rm hello-world && ok "Тестовый контейнер отработал."
  record_done "Docker + Compose plugin"
}

# =============================================================================
# ЭТАП 12. GIT / DEPLOY ACCESS
# =============================================================================
stage_git() {
  stage_begin "Git и deploy-доступ" \
    "SSH-ключ для GitHub/GitLab/Bitbucket, known_hosts, проверка соединения." || return 0

  local u="${DEPLOY_USER:-root}"
  local hd; hd="$(getent passwd "$u" | cut -d: -f6)"

  echo "  Deploy key: отдельный ключ с доступом только к одному репозиторию (лучше"
  echo "  для сервера — компрометация сервера не отдаёт весь ваш Git-аккаунт)."
  echo "  Personal key: доступ ко всем вашим репозиториям — удобно, но шире риск."
  ask_choice "Git-провайдер:" 1 "GitHub" "GitLab" "Bitbucket" "Пропустить"
  local host=""
  case "$CHOICE" in
    1) host="github.com" ;;
    2) host="gitlab.com" ;;
    3) host="bitbucket.org" ;;
    4) record_skip "Git"; return 0 ;;
  esac

  local key="${hd}/.ssh/deploy_${host%%.*}"
  if [[ -f "$key" ]]; then
    ok "Ключ ${key} уже существует — не перезаписываю."
  else
    # ed25519 — текущая рекомендация OpenSSH: короче и стойче RSA.
    run sudo -u "$u" ssh-keygen -t ed25519 -f "$key" -N "" -C "deploy@$(hostname)-${host}" \
      || { err "Не удалось сгенерировать ключ."; return 1; }
    ok "Ключ создан: ${key}"
  fi

  # known_hosts: ssh-keyscan уязвим к MITM в момент первого скана,
  # поэтому показываем отпечатки и просим сверить с официальной документацией провайдера.
  if (( ! DRY_RUN )) && ! grep -qs "$host" "${hd}/.ssh/known_hosts" 2>/dev/null; then
    info "Добавляю ключи ${host} в known_hosts. Отпечатки для сверки с docs провайдера:"
    ssh-keyscan -t ed25519,rsa "$host" 2>/dev/null | tee -a "${hd}/.ssh/known_hosts" \
      | ssh-keygen -lf - | sed 's/^/    /'
    chown "$u:$u" "${hd}/.ssh/known_hosts"
    warn "Сверьте отпечатки: GitHub -> docs.github.com 'SSH key fingerprints' (аналогично у других)."
  fi

  # SSH-config: свой ключ для конкретного хоста.
  local sshcfg="${hd}/.ssh/config"
  if ! grep -qs "Host ${host}" "$sshcfg" 2>/dev/null; then
    backup_file "$sshcfg"
    if (( ! DRY_RUN )); then
      cat >> "$sshcfg" <<EOF

Host ${host}
    IdentityFile ${key}
    IdentitiesOnly yes
EOF
      chown "$u:$u" "$sshcfg"; chmod 600 "$sshcfg"
    fi
  fi

  echo
  info "Публичный ключ — добавьте его как Deploy key в настройках репозитория:"
  (( DRY_RUN )) || sed 's/^/    /' "${key}.pub"
  echo
  if ask_yn "Проверить соединение с ${host} сейчас (ключ уже добавлен в репозиторий)?" n; then
    # ssh -T возвращает 1 у GitHub даже при успехе — проверяем текст ответа.
    local out
    out="$(sudo -u "$u" ssh -T -o ConnectTimeout=10 "git@${host}" 2>&1 || true)"
    if grep -qiE "successfully authenticated|welcome" <<< "$out"; then
      ok "Аутентификация в ${host} успешна."
    else
      warn "Аутентификация не подтверждена. Ответ: $(head -1 <<< "$out")"
    fi
  fi
  record_done "Git deploy access (${host})"
}

# =============================================================================
# ЭТАП 13. DOCKER LOGIN
# =============================================================================
stage_registry() {
  stage_begin "Docker registry login" \
    "Вход в Docker Hub / приватный registry по токену, без пароля в history/логах." || return 0

  cmd_exists docker || { record_skip "Docker login (нет docker)"; return 0; }
  (( ASSUME_YES )) && { record_skip "Docker login (неинтерактивный режим)"; return 0; }

  ask_yn "Выполнить docker login сейчас?" n || { record_skip "Docker login"; return 0; }

  ask_input "Registry (Enter = Docker Hub)" ""
  local registry="$REPLY_VAL"
  ask_input "Логин" ""
  local login="$REPLY_VAL"
  [[ -n "$login" ]] || { err "Логин пуст."; return 1; }

  echo "  Используйте access token, а не пароль от аккаунта: токен можно отозвать,"
  echo "  и он ограничен по правам."
  warn "Credentials сохранятся в ~/.docker/config.json в base64 (НЕ шифрование):"
  warn "любой с доступом к этому файлу (root, docker-группа) сможет их прочитать."

  # Токен читается скрыто и передаётся через stdin — не попадает ни в ps, ни в history, ни в лог.
  local token
  read -rsp "Токен (ввод скрыт): " token </dev/tty; echo
  [[ -n "$token" ]] || { err "Пустой токен."; return 1; }
  if (( DRY_RUN )); then
    info "[dry-run] docker login ${registry:-docker.io} -u ${login} --password-stdin"
  elif printf '%s' "$token" | docker login ${registry:+"$registry"} -u "$login" --password-stdin >>"$LOG_FILE" 2>&1; then
    ok "Вход в registry выполнен."
  else
    err "docker login не удался — проверьте логин/токен."
  fi
  unset token
  record_done "Docker login"
}

# =============================================================================
# ЭТАП 14. DJANGO/DOCKER PRODUCTION-ШАБЛОН
# =============================================================================
stage_django() {
  stage_begin "Django/Docker production-шаблон (опционально)" \
    "Каталог проекта, compose, Dockerfile, Nginx-проксирование, secrets, deploy.sh." || return 0

  ask_input "Имя проекта (латиница, без пробелов)" "app"
  local proj="$REPLY_VAL"
  [[ "$proj" =~ ^[a-zA-Z0-9_-]+$ ]] || { err "Недопустимое имя проекта."; return 1; }
  ask_input "Каталог проекта" "/opt/${proj}"
  PROJECT_DIR="$REPLY_VAL"

  if [[ -e "${PROJECT_DIR}/docker-compose.yml" || -e "${PROJECT_DIR}/compose.yml" ]]; then
    warn "В ${PROJECT_DIR} уже есть compose-файл. Не перезаписываю существующий проект."
    ask_yn "Продолжить, создавая только недостающие файлы?" n || { record_skip "Django-шаблон"; return 0; }
  fi

  ask_input "Локальный порт приложения (только 127.0.0.1)" "8000"
  local app_port="$REPLY_VAL"
  if port_listening "$app_port"; then
    warn "Порт ${app_port} уже занят!"
    ask_input "Другой порт" "8001"; app_port="$REPLY_VAL"
    port_listening "$app_port" && { err "И этот порт занят. Освободите порт и повторите этап."; return 1; }
  fi

  local u="${DEPLOY_USER:-root}"
  echo
  echo "  Схема: наружу смотрит только Nginx (80/443). Приложение слушает"
  echo "  127.0.0.1:${app_port} — так контейнер недоступен извне даже при обходе UFW."
  echo "  Секреты живут в ${PROJECT_DIR}/secrets (chmod 700), не в git и не в образе."

  # --- структура каталогов ---
  local d
  for d in "" /app /secrets /backups /static /media; do
    run mkdir -p "${PROJECT_DIR}${d}"
  done
  (( DRY_RUN )) || {
    chown -R "$u:$u" "$PROJECT_DIR"
    chmod 700 "${PROJECT_DIR}/secrets"
  }

  # --- .env: генерация SECRET_KEY, права 600 ---
  local envfile="${PROJECT_DIR}/secrets/.env"
  if [[ ! -f "$envfile" ]]; then
    local secret
    secret="$(openssl rand -base64 48 | tr -d '\n')"
    # Секрет пишется напрямую, минуя run()/лог.
    if (( ! DRY_RUN )); then
      cat > "$envfile" <<EOF
DJANGO_SECRET_KEY=${secret}
DJANGO_DEBUG=0
DJANGO_ALLOWED_HOSTS=localhost
DATABASE_URL=postgres://app:CHANGE_ME@db:5432/app
EOF
      chmod 600 "$envfile"; chown "$u:$u" "$envfile"
      CHANGED_FILES+=("$envfile (секреты, права 600)")
    fi
    unset secret
    ok "Создан ${envfile} (SECRET_KEY сгенерирован, права 600)."
  else
    ok ".env уже существует — не трогаю."
  fi

  write_file "${PROJECT_DIR}/secrets/.env.example" 0644 "$u:$u" <<'EOF'
# Шаблон переменных окружения. Реальные значения — только в .env (не в git!)
DJANGO_SECRET_KEY=
DJANGO_DEBUG=0
DJANGO_ALLOWED_HOSTS=example.com
DATABASE_URL=postgres://app:password@db:5432/app
EOF

  # --- .gitignore / .dockerignore ---
  write_file "${PROJECT_DIR}/.gitignore" 0644 "$u:$u" <<'EOF'
secrets/
*.env
!.env.example
media/
backups/
__pycache__/
*.pyc
EOF
  write_file "${PROJECT_DIR}/.dockerignore" 0644 "$u:$u" <<'EOF'
secrets/
.git/
backups/
media/
__pycache__/
EOF

  # --- Dockerfile ---
  write_file "${PROJECT_DIR}/app/Dockerfile" 0644 "$u:$u" <<'EOF'
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /code

RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt gunicorn

COPY . .

# Приложение работает НЕ от root: контейнерный escape даёт меньше прав.
RUN useradd -m -u 1001 appuser && chown -R appuser /code
USER appuser

EXPOSE 8000
CMD ["gunicorn", "config.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "3", "--timeout", "60"]
EOF

  # --- docker-compose.yml ---
  write_file "${PROJECT_DIR}/docker-compose.yml" 0644 "$u:$u" <<EOF
services:
  web:
    build: ./app
    # ВАЖНО: порт публикуется только на localhost — снаружи доступ через Nginx.
    ports:
      - "127.0.0.1:${app_port}:8000"
    env_file:
      - ./secrets/.env
    volumes:
      - ./static:/code/staticfiles
      - ./media:/code/media
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8000/healthz/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    networks: [internal]
    depends_on:
      db:
        condition: service_healthy

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: app
      POSTGRES_USER: app
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets: [db_password]
    volumes:
      - pgdata:/var/lib/postgresql/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app"]
      interval: 10s
      retries: 5
    networks: [internal]
    # Порт БД сознательно НЕ публикуется — доступ только из docker-сети.

secrets:
  db_password:
    file: ./secrets/db_password

volumes:
  pgdata:

networks:
  internal:
    driver: bridge
EOF

  # Пароль БД как compose-секрет (файл, права 600).
  if [[ ! -f "${PROJECT_DIR}/secrets/db_password" ]] && (( ! DRY_RUN )); then
    openssl rand -base64 24 | tr -d '\n' > "${PROJECT_DIR}/secrets/db_password"
    chmod 600 "${PROJECT_DIR}/secrets/db_password"
    chown "$u:$u" "${PROJECT_DIR}/secrets/db_password"
    ok "Пароль БД сгенерирован в secrets/db_password."
  fi

  # --- deploy.sh ---
  write_file "${PROJECT_DIR}/deploy.sh" 0755 "$u:$u" <<'EOF'
#!/usr/bin/env bash
# Деплой новой версии: pull -> build -> migrate -> collectstatic -> up.
set -euo pipefail
cd "$(dirname "$0")"

git -C app pull --ff-only
docker compose build web
docker compose run --rm web python manage.py migrate --noinput
docker compose run --rm web python manage.py collectstatic --noinput
docker compose up -d
docker compose ps
echo "Логи: docker compose logs -f web"
EOF

  # --- Nginx reverse proxy ---
  if cmd_exists nginx && ask_yn "Создать Nginx-конфиг reverse proxy для проекта?" y; then
    ask_input "Домен для проекта (Enter = пропустить)" ""
    local dom="${REPLY_VAL:-_}"
    local site_conf
    if [[ -d /etc/nginx/sites-available ]]; then
      site_conf="/etc/nginx/sites-available/${proj}.conf"
    else
      site_conf="/etc/nginx/conf.d/${proj}.conf"
    fi
    if [[ -e "$site_conf" ]]; then
      warn "Конфиг ${site_conf} уже существует — не перезаписываю."
    else
      write_file "$site_conf" 0644 root:root <<EOF
# Reverse proxy для ${proj}. TLS добавит certbot --nginx.
server {
    listen 80;
    listen [::]:80;
    server_name ${dom};

    client_max_body_size 25m;

    location /static/ {
        alias ${PROJECT_DIR}/static/;
        expires 30d;
        access_log off;
    }
    location /media/ {
        alias ${PROJECT_DIR}/media/;
        expires 7d;
    }
    location / {
        proxy_pass http://127.0.0.1:${app_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }
}
EOF
      if [[ -d /etc/nginx/sites-enabled ]]; then
        run ln -sf "$site_conf" "/etc/nginx/sites-enabled/${proj}.conf"
      fi
      if run nginx -t; then
        run systemctl reload nginx && ok "Nginx проксирует ${dom} -> 127.0.0.1:${app_port}."
      else
        err "nginx -t не прошёл — конфиг создан, но не подключён к рабочему Nginx."
      fi
    fi
  fi

  echo
  info "Дальше: положите код Django в ${PROJECT_DIR}/app (git clone), проверьте"
  info "secrets/.env, затем: cd ${PROJECT_DIR} && ./deploy.sh"
  record_done "Django-шаблон (${PROJECT_DIR}, порт 127.0.0.1:${app_port})"
}

# =============================================================================
# ЭТАП 15. ИТОГОВЫЙ ОТЧЁТ
# =============================================================================
stage_report() {
  echo; hr
  echo "${C_BLD}ИТОГОВЫЙ ОТЧЁТ — bootstrap ${VERSION} (${RUN_TS})${C_RST}"
  hr

  echo "${C_GRN}Выполнено:${C_RST}"
  if (( ${#DONE_STEPS[@]} )); then printf '  ✓ %s\n' "${DONE_STEPS[@]}"; else echo "  (ничего)"; fi

  echo "${C_YLW}Пропущено:${C_RST}"
  if (( ${#SKIPPED_STEPS[@]} )); then printf '  - %s\n' "${SKIPPED_STEPS[@]}"; else echo "  (ничего)"; fi

  if (( ${#CHANGED_FILES[@]} )); then
    echo "${C_BLD}Изменённые файлы:${C_RST}"
    printf '  %s\n' "${CHANGED_FILES[@]}"
  fi

  if (( ${#WARNINGS_LIST[@]} )); then
    echo "${C_YLW}Оставшиеся предупреждения:${C_RST}"
    printf '  ! %s\n' "${WARNINGS_LIST[@]}" | sort -u
  fi

  echo
  echo "Бэкапы конфигов: ${BACKUP_DIR}"
  echo "Полный лог:      ${LOG_FILE}"

  # --- текущее состояние ---
  echo; echo "${C_BLD}Состояние сервисов:${C_RST}"
  local s
  for s in ssh nginx docker fail2ban ufw; do
    if svc_exists "${s}.service" || [[ "$s" == "ufw" ]]; then
      printf '  %-10s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo '-')"
    fi
  done
  echo; echo "${C_BLD}Слушающие порты:${C_RST}"
  ss -lntu 2>/dev/null | awk 'NR>1{print "  " $1 "  " $5}' | sort -u | head -20

  # --- post-install checklist ---
  echo; hr
  echo "${C_BLD}POST-INSTALL CHECKLIST:${C_RST}"
  cat <<EOF
  [ ] Открыть НОВУЮ SSH-сессию: ssh -p ${SSH_PORT_TARGET:-$SSH_PORT_CURRENT} ${DEPLOY_USER:-root}@<IP>
  [ ] Проверить firewall:        sudo ufw status verbose
  [ ] Проверить HTTP/HTTPS:      curl -I http://<домен> && curl -I https://<домен>
  [ ] Проверить nginx:           sudo nginx -t && systemctl status nginx
  [ ] Проверить docker:          docker ps && docker compose version
  [ ] Тест продления TLS:        sudo certbot renew --dry-run
  [ ] Проверить fail2ban:        sudo fail2ban-client status sshd
  [ ] Проверить порты снаружи:   nmap <IP> (с другой машины)
  [ ] Проверить логи:            journalctl -p err -b --no-pager | tail
  [ ] Настроить внешние бэкапы БД и media (за рамками этого скрипта!)
  [ ] Перезагрузить сервер, если требовалось (файл /var/run/reboot-required)
EOF
  hr
}

# =============================================================================
# MAIN
# =============================================================================

usage() {
  cat <<EOF
ubuntu-bootstrap.sh v${VERSION} — интерактивная production-настройка Ubuntu.

Использование:
  sudo $0 [опции]

Опции:
  --dry-run          показать план без изменений
  --yes              неинтерактивно: безопасные значения по умолчанию,
                     опасные этапы (SSH hardening, включение UFW) пропускаются
  --stage ИМЯ[,ИМЯ]  выполнить только указанные этапы
  --list             список этапов
  -h, --help         эта справка

Примеры:
  sudo $0                          # полный интерактивный мастер
  sudo $0 --dry-run                # репетиция
  sudo $0 --stage nginx,certbot    # только веб-часть
EOF
}

# Порядок этапов важен: пользователь -> SSH -> firewall (знает SSH-порт) ->
# базовая система -> веб -> docker -> доступы -> приложение -> отчёт.
readonly STAGE_ORDER=(preflight packages users ssh firewall swap limits security nginx certbot docker git registry django report)
declare -rA STAGE_FN=(
  [preflight]=stage_preflight [packages]=stage_packages [users]=stage_users
  [ssh]=stage_ssh [firewall]=stage_firewall [swap]=stage_swap
  [limits]=stage_limits [security]=stage_security [nginx]=stage_nginx
  [certbot]=stage_certbot [docker]=stage_docker [git]=stage_git
  [registry]=stage_registry [django]=stage_django [report]=stage_report
)
declare -rA STAGE_DESC=(
  [preflight]="Проверка состояния сервера"
  [packages]="Базовые пакеты + apt upgrade"
  [users]="Deploy-пользователь и SSH-ключи"
  [ssh]="SSH hardening с авто-откатом"
  [firewall]="UFW + защита от Docker-обхода"
  [swap]="Swap-файл"
  [limits]="nofile-лимиты и sysctl hardening"
  [security]="unattended-upgrades, fail2ban, аудит прав"
  [nginx]="Nginx (Ubuntu / nginx.org stable / mainline)"
  [certbot]="TLS-сертификаты Let's Encrypt"
  [docker]="Docker CE + Compose из официального репозитория"
  [git]="Deploy-ключи для Git-провайдера"
  [registry]="docker login по токену"
  [django]="Production-шаблон Django в Docker"
  [report]="Итоговый отчёт и checklist"
)

main() {
  while (( $# )); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes)     ASSUME_YES=1 ;;
      --stage)   ONLY_STAGES="${2:-}"; shift ;;
      --list)
        for s in "${STAGE_ORDER[@]}"; do printf '  %-10s %s\n' "$s" "${STAGE_DESC[$s]}"; done
        exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) err "Неизвестная опция: $1"; usage; exit 1 ;;
    esac
    shift
  done

  # Лог должен существовать даже без root (для dry-run под обычным пользователем).
  mkdir -p "$LOG_DIR" 2>/dev/null || LOG_FILE="/tmp/bootstrap-${RUN_TS}.log"
  touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"
  [[ "$LOG_FILE" != "/dev/null" ]] && chmod 600 "$LOG_FILE" 2>/dev/null

  echo "${C_BLD}Ubuntu Production Bootstrap v${VERSION}${C_RST}"
  (( DRY_RUN ))    && warn "Режим DRY-RUN: изменения НЕ применяются."
  (( ASSUME_YES )) && warn "Неинтерактивный режим: опасные этапы будут пропущены."
  log "START v${VERSION} dry_run=${DRY_RUN} yes=${ASSUME_YES} stages=${ONLY_STAGES:-all}"

  local stages_to_run=() s
  if [[ -n "$ONLY_STAGES" ]]; then
    IFS=',' read -ra stages_to_run <<< "$ONLY_STAGES"
    for s in "${stages_to_run[@]}"; do
      [[ -n "${STAGE_FN[$s]:-}" ]] || die "Неизвестный этап: '$s'. Список: $0 --list"
    done
    # Отдельные этапы почти всегда требуют root; preflight сам проверит остальное.
    if (( EUID != 0 && ! DRY_RUN )); then die "Нужен root: sudo $0 --stage $ONLY_STAGES"; fi
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    # Для одиночных этапов подтягиваем актуальный SSH-порт.
    SSH_PORT_CURRENT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')" || true
    SSH_PORT_CURRENT="${SSH_PORT_CURRENT:-22}"
  else
    stages_to_run=("${STAGE_ORDER[@]}")
  fi

  for s in "${stages_to_run[@]}"; do
    # Ошибка этапа не роняет весь мастер: сообщаем и спрашиваем, идти ли дальше.
    if ! "${STAGE_FN[$s]}"; then
      err "Этап '${s}' завершился с ошибкой. Подробности: $LOG_FILE"
      SKIPPED_STEPS+=("${s} (ошибка)")
      if [[ "$s" != "report" ]]; then
        ask_yn "Продолжить со следующего этапа?" y || { stage_report; die "Остановлено после ошибки этапа '${s}'."; }
      fi
    fi
  done

  log "FINISH"
}

main "$@"
