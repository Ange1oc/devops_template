# Модули

Модуль — файл `modules/<имя>.sh`. Он объявляет опции, умеет проверить, достигнуто ли желаемое состояние (`mod_check`), применить его идемпотентно (`mod_apply`), проверить результат (`mod_verify`) и выдать проверки для `audit` (`mod_audit`). Порядок выполнения определяется зависимостями (`MOD_DEPS` включаются автоматически) и мягким упорядочиванием (`MOD_AFTER`): `preflight → base → time → users → ssh → firewall → fail2ban → updates → sysctl → limits → swap → journald → docker → nginx → certbot → git → wg-network`.

Обозначения в таблицах опций: **adv** — опция считается дополнительной, мастер спрашивает её только в `--advanced`. Пустое умолчание показано как «—».

Все файлы, которые пишет инструмент, содержат `ubuntu-bootstrap` в имени или лежат в блоке между маркерами `# BEGIN ubuntu-bootstrap ...` / `# END ubuntu-bootstrap ...` внутри чужого файла. Чужие файлы целиком не перезаписываются.

---

## preflight — проверка сервера

Выполняется при каждом `apply` и `plan` первым (`MOD_ALWAYS=1`), даже если исключён из набора (явный `--skip preflight` отключает).

| Опция | Тип | Умолчание | Назначение |
|---|---|---|---|
| `PREFLIGHT_MIN_DISK_GB` | int | 2 | минимум свободного места на `/` в GiB (adv) |

Что делает:

- предохранители: ОС должна быть Ubuntu версии 22.04/24.04/26.04 (иначе код 3, `--force` снимает), свободного места на `/` не меньше минимума;
- предупреждения: архитектура не amd64/arm64, нет systemd, запуск внутри контейнера (swap, sysctl ядра, snap будут пропущены);
- ждёт освобождения apt/dpkg до 120 секунд (сразу после загрузки unattended-upgrades может держать блокировку);
- печатает сводку: ОС, ядро, виртуализация, CPU/RAM/swap, свободное место, интерфейс и IP, hostname, текущая SSH-сессия (пользователь, адрес клиента, порт) и порты sshd, слушающие порты с процессами, версии уже установленных nginx/docker/ufw/fail2ban/certbot/wg-network.

Ничего не меняет.

---

## base — пакеты, обновление, hostname, timezone

Зависимости: preflight.

| Опция | Тип | Умолчание | Назначение |
|---|---|---|---|
| `BASE_UPGRADE` | bool | yes | `apt-get update && apt-get upgrade` перед установкой пакетов |
| `BASE_PACKAGES` | list | ca-certificates,curl,gnupg,git,jq,rsync,unzip,htop,ncdu,bind9-dnsutils,openssl,needrestart,logrotate | базовые пакеты (adv) |
| `BASE_EXTRA_PACKAGES` | list | — | дополнительные пакеты |
| `BASE_TIMEZONE` | timezone | — | часовой пояс; пусто — не менять |
| `BASE_HOSTNAME` | hostname | — | имя хоста; пусто — не менять |
| `BASE_AUTOREMOVE` | bool | yes | после upgrade выполнить `autoremove --purge` (adv) |

Что делает:

- `apt-get upgrade` в неинтерактивном режиме (`DEBIAN_FRONTEND=noninteractive`, `--force-confdef --force-confold`: существующие конфиги пакетов не перезаписываются вопросами; `NEEDRESTART_MODE=l` — needrestart только перечисляет сервисы, не перезапускает их);
- ставит отсутствующие пакеты с `--no-install-recommends`;
- часовой пояс через `timedatectl set-timezone` (команда отката — прежний пояс);
- hostname через `hostnamectl set-hostname` (команда отката — прежнее имя) и запись `127.0.1.1 <hostname> <короткое имя>` в блоке `# BEGIN ubuntu-bootstrap hostname` файла `/etc/hosts`, иначе `sudo` жалуется на нерезолвящееся имя;
- предупреждает, если после обновления требуется перезагрузка (`/var/run/reboot-required`).

Состояние «применён»: все пакеты установлены, часовой пояс и hostname совпадают с заданными. Повторный запуск с `BASE_UPGRADE=yes` снова выполнит `apt-get upgrade` только если модуль перевыполняется (изменились опции, `--reapply` или проверка не прошла).

Аудит: установлены ли базовые пакеты, резолвится ли hostname.

---

## time — синхронизация времени

Зависимости: preflight. В контейнерах пропускается: `systemd-timesyncd` и `chrony` несут `ConditionVirtualization=!container`, время задаёт хост.

| Опция | Тип | Умолчание | Назначение |
|---|---|---|---|
| `TIME_DAEMON` | enum: auto, chrony, timesyncd | auto | `auto` оставляет уже установленную службу (Ubuntu 26.04 по умолчанию ставит chrony с NTS, старые релизы — timesyncd); если нет ни одной — timesyncd |
| `TIME_SERVERS` | list | — | свои NTP-серверы; пусто — умолчания дистрибутива или провайдера (adv) |

Что делает: ставит выбранную службу (chrony при установке заменяет timesyncd), при заданных серверах пишет `/etc/chrony/sources.d/ubuntu-bootstrap.sources` (`server X iburst`) или `/etc/systemd/timesyncd.conf.d/ubuntu-bootstrap.conf` (`[Time] NTP=...`) и перезапускает службу, включает её и выполняет `timedatectl set-ntp true`.

Состояние: нужная служба установлена и активна, `timedatectl` сообщает `NTP=yes`. Аудит: `NTPSynchronized=yes`.

---

## users — администратор

Зависимости: preflight. Модуль `ssh` выполняется после него и использует созданного пользователя в своих предохранителях.

| Опция | Тип | Умолчание | Назначение |
|---|---|---|---|
| `ADMIN_USER` | user | — | имя администратора; пусто — модуль ничего не делает |
| `ADMIN_SSH_KEYS` | keys | — | публичные ключи через `;` |
| `ADMIN_SSH_KEYS_GITHUB` | list | — | логины GitHub: ключи скачиваются с `https://github.com/<логин>.keys` по TLS и помечаются комментарием `github:<логин>` |
| `ADMIN_COPY_ROOT_KEYS` | enum: auto, yes, no | auto | скопировать `authorized_keys` root администратору; `auto` — только если других ключей не задано и у пользователя их ещё нет |
| `ADMIN_SUDO` | bool | yes | добавить в группу `sudo` |
| `ADMIN_SUDO_MODE` | enum: password, nopasswd | password | `password` — sudo спрашивает пароль пользователя; `nopasswd` — `NOPASSWD:ALL` через `/etc/sudoers.d/` (требует подтверждения) |
| `ADMIN_PASSWORD_HASH` | string | — | crypt-хэш пароля (`mkpasswd -m sha-512`) для режима `password` без терминала (adv) |
| `ADMIN_SHELL` | path | /bin/bash | оболочка (adv) |
| `ADMIN_GROUPS` | list | — | дополнительные группы; несуществующие пропускаются с предупреждением (adv) |

Что делает:

1. Если `ADMIN_SUDO_MODE=nopasswd` и файла sudoers ещё нет — запрашивает подтверждение **до любых изменений** («компрометация SSH-ключа = мгновенный root»); отказ оставляет систему нетронутой.
2. Создаёт пользователя `useradd -m -s SHELL -U` (команда отката — `userdel -r`) и блокирует пароль (`passwd -l`): вход только по ключу. Существующий пользователь не пересоздаётся; системный (UID < 1000) вызывает предупреждение.
3. Собирает ключи: явные, GitHub, при необходимости копия ключей root. Добавляет в `~/.ssh/authorized_keys` только отсутствующие (сравнение по телу ключа), существующие строки сохраняет. Права: `~/.ssh` 700, файл 600, владелец пользователь.
4. Если ключей нет — предупреждает, что после hardening вход будет невозможен (модуль `ssh` в этом случае откажется запрещать пароли).
5. Группы: `usermod -aG` с командой отката `gpasswd -d`.
6. sudo: группа `sudo`; для `nopasswd` — файл `/etc/sudoers.d/90-ubuntu-bootstrap-<user>` с правами 440, проверенный `visudo -cf` (невалидный файл — ошибка и откат). Для `password`: если пароля нет, он ставится из `ADMIN_PASSWORD_HASH` (`chpasswd -e`) или запрашивается в терминале (`passwd`); без того и другого модуль предупреждает, что sudo не заработает, и модуль `ssh` не станет запрещать вход root по ключу.

Состояние: пользователь существует, sudo работоспособен (пароль задан или NOPASSWD), при заданных ключах — у пользователя есть `authorized_keys`.

Аудит: число обычных пользователей, существование администратора, наличие ключей, работоспособность sudo, права `~/.ssh`.

Файлы: `/home/<user>/.ssh/authorized_keys`, `/etc/sudoers.d/90-ubuntu-bootstrap-<user>`.

---

## ssh — SSH hardening

Зависимости: preflight; после users. Самый ответственный модуль: все его предохранители выполняются до изменений, а применение страхуется таймером отката.

| Опция | Тип | Умолчание | Назначение |
|---|---|---|---|
| `SSH_PORT` | portkeep | keep | порт; `keep` — не менять (директива `Port` не пишется) |
| `SSH_PASSWORD_AUTH` | bool | no | разрешить вход по паролю; `no` также выключает `KbdInteractiveAuthentication` |
| `SSH_PERMIT_ROOT` | enum: auto, no, prohibit-password, yes | auto | `auto` → `no`, если есть не-root пользователь с ключом **и рабочим sudo**, иначе `prohibit-password`; `yes` требует подтверждения |
| `SSH_ALLOW_USERS` | users | — | `AllowUsers`; пусто — директива не пишется. Мастер подставляет `ADMIN_USER` |
| `SSH_CONFIRM` | enum: auto, wait, none | auto | как подтверждать доступ после применения (см. ниже); `none` только с `--force` |
| `SSH_CONFIRM_TIMEOUT` | int | 180 | секунд до автоматического отката |
| `SSH_MAX_AUTH_TRIES` | int | 4 | `MaxAuthTries` (adv) |
| `SSH_LOGIN_GRACE` | int | 30 | `LoginGraceTime` (adv) |
| `SSH_CLIENT_ALIVE_INTERVAL` | int | 300 | `ClientAliveInterval`; `ClientAliveCountMax` всегда 3 (adv) |
| `SSH_X11_FORWARDING` | bool | no | `X11Forwarding` (adv) |
| `SSH_AGENT_FORWARDING` | bool | no | `AllowAgentForwarding` (adv) |
| `SSH_TCP_FORWARDING` | bool | yes | `AllowTcpForwarding` — нужен туннелям и VS Code Remote (adv) |
| `SSH_LOG_LEVEL` | enum: INFO, VERBOSE | VERBOSE | `VERBOSE` пишет отпечатки ключей, полезно для аудита и fail2ban (adv) |
| `SSH_CLOSE_OLD_PORT` | bool | yes | после подтверждения закрыть в UFW старый порт (adv) |

Файл `/etc/ssh/sshd_config.d/00-ubuntu-bootstrap.conf` (права 600). Префикс `00-` важен: sshd применяет **первое** встреченное значение директивы, а `Include sshd_config.d/*.conf` стоит в начале `sshd_config`, поэтому наши значения побеждают и cloud-init (`50-cloud-init.conf`), и основной файл. Содержимое:

```
Port <порт>                      только если SSH_PORT != keep
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no  только при запрете паролей
PermitEmptyPasswords no
PermitRootLogin <значение>
MaxAuthTries 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 3
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
LogLevel VERBOSE
UseDNS no
AllowUsers ...                   только если задано
```

Предохранители (код 3; `--force` снимает):

- `sshd_config` должен содержать `Include /etc/ssh/sshd_config.d/*.conf`, иначе файл не будет прочитан;
- `SSH_CONFIRM=none` запрещён без `--force`;
- запрет паролей — только если хотя бы у одного разрешённого пользователя (с учётом `AllowUsers` и `PermitRootLogin`) есть `authorized_keys`;
- `PermitRootLogin no` — только если есть не-root пользователь с ключом и работающим sudo (иначе сервер останется без администратора);
- `AllowUsers` не может исключить пользователя текущей SSH-сессии (для root при `PermitRootLogin no` — предупреждение: текущая сессия продолжит работать);
- новый порт не должен быть занят другим сервисом; порт ниже 1024 вызывает предупреждение.

`PermitRootLogin yes` требует подтверждения (`confirm_danger`).

Применение:

1. Если порт меняется и UFW активен — новый порт открывается в UFW до перезапуска sshd (`limit`, если модуль firewall включён или применён с `FW_SSH_LIMIT=yes`, иначе `allow`) с комментарием `SSH (ubuntu-bootstrap)`.
2. Регистрируется команда отката (повторное применение прежнего конфига), пишется файл, выполняется `sshd -t`. Невалидный конфиг — ошибка, файл откатывается, sshd не перезапускается.
3. Перезапуск: на Ubuntu 22.10+ sshd socket-активирован, порты читает генератор при `daemon-reload`, поэтому при смене порта выполняется `systemctl daemon-reload` и `restart ssh.socket` (простой `reload` порт не меняет, Launchpad #2069041); без смены порта — `reload-or-restart ssh.service`. Существующие сессии переживают перезапуск (`KillMode=process`). Затем проверяется, что sshd слушает все ожидаемые порты, а `sshd -T` показывает заданные значения.
4. Подтверждение доступа (`confirm_or_rollback`):
   - взводится таймер отката вне SSH-сессии (`systemd-run --on-active`); файл `/var/lib/ubuntu-bootstrap/pending.env` описывает, что откатывать;
   - **интерактивно**: обратный отсчёт и вопрос «Вход в новой сессии успешен?»; выводится готовая команда `ssh -p PORT USER@IP`. Ответ `y` подтверждает, `n` или истечение времени откатывает. `confirm` из другой сессии тоже засчитывается;
   - **`auto` без терминала**: через 2 секунды самопроверка — sshd отвечает баннером `SSH-2.0` на новом порту через `127.0.0.1`, порт разрешён в UFW (если UFW активен). Успех подтверждает, провал откатывает;
   - **`wait`**: процесс завершается с кодом 0, таймер продолжает идти; `confirm` из новой сессии снимает его, иначе — откат;
   - **`none`**: без таймера (только с `--force`).
5. После подтверждения закрываются старые порты: удаляются только правила UFW с комментарием `SSH (ubuntu-bootstrap)` для портов, которые sshd больше не слушает. Об открытых портах без пометки выводится предупреждение. В режиме `wait` это делает команда `confirm` (хук `mod_confirmed`).

Откат модуля (по ошибке, таймеру, отказу или `rollback`): восстанавливается прежний файл (или удаляется созданный), заново применяется конфиг sshd с перезапуском сокета при необходимости, новый порт удаляется из UFW.

Состояние: файл совпадает с ожидаемым, `sshd -T` показывает заданные `passwordauthentication`, `permitrootlogin`, `port`, `maxauthtries`. Источник истины — `sshd -T`, а не разбор файлов, поэтому учитываются все включённые конфиги. `without-password` нормализуется в `prohibit-password`.

Аудит: пароли, root, `MaxAuthTries ≤ 4`, `X11Forwarding`, `PermitEmptyPasswords`, порты и `LogLevel`, права ключей хоста, наличие устаревшего DSA-ключа.

---

## firewall — UFW

Зависимости: preflight; после ssh и docker (чтобы знать целевой SSH-порт и наличие Docker).

| Опция | Тип | Умолчание | Назначение |
|---|---|---|---|
| `FW_SSH_LIMIT` | bool | yes | SSH через `ufw limit`: не более 6 новых соединений за 30 секунд с одного IP |
| `FW_SSH_FROM` | cidrs | — | разрешить SSH только с этих адресов; пусто — отовсюду |
| `FW_WEB` | enum: auto, yes, no | auto | открыть 80/tcp и 443/tcp; `auto` — если включён модуль nginx или nginx установлен |
| `FW_HTTP3` | bool | yes | дополнительно 443/udp (adv) |
| `FW_ALLOW_PORTS` | ports | — | дополнительные порты, например `8443/tcp,51820/udp` (без протокола — tcp) |
| `FW_DOCKER_PROTECT` | enum: auto, yes, no | auto | блокировать внешний доступ к контейнерам через цепочку `DOCKER-USER`; `auto` — если включён модуль docker или docker установлен |
| `FW_DOCKER_ALLOW_PORTS` | ports | — | порты контейнеров, доступные снаружи несмотря на защиту (adv) |
| `FW_LOGGING` | enum: off, low, medium | low | `ufw logging` (adv) |
| `FW_CONFIRM` | enum: auto, wait, none | auto | подтверждение доступа после включения UFW, как у ssh; `none` только с `--force` (adv) |
| `FW_CONFIRM_TIMEOUT` | int | 180 | секунд до отката (adv) |

Желаемые правила: SSH-порты (целевой порт модуля ssh, если он включён и меняет порт, иначе текущие порты sshd) — `limit` или `allow`, либо `allow from CIDR` для каждого адреса из `FW_SSH_FROM`; 80/443 при `FW_WEB`; 443/udp при `FW_HTTP3`; `FW_ALLOW_PORTS`. Правила помечаются комментарием `ubuntu-bootstrap` (SSH — `SSH (ubuntu-bootstrap)`), по нему модуль ssh потом отличает свои правила от чужих.

Предохранители и подтверждения (до любых изменений): `FW_SSH_FROM` обязан включать IP текущей SSH-сессии; включение неактивного UFW требует подтверждения с перечнем открываемых портов; `FW_CONFIRM=none` при удалённой сессии — только с `--force`. В контейнере без `NET_ADMIN` модуль пропускается с предупреждением.

Применение:

- регистрируется команда отката (вернуть UFW в прежнее состояние — включён/выключен — и перечитать правила), снимаются копии `user.rules`, `user6.rules`, `ufw.conf`, `after.rules`, `after6.rules`;
- `default deny incoming`, `default allow outgoing`, `logging`; добавляются только отсутствующие правила (проверка по `ufw status`), существующие чужие правила не удаляются;
- защита Docker: в `/etc/ufw/after.rules` (права 640) между маркерами `# BEGIN ubuntu-bootstrap docker` и `# END` добавляется таблица `*filter` с цепочкой `DOCKER-USER`: для внешнего интерфейса (интерфейс маршрута по умолчанию) пропускаются `RELATED,ESTABLISHED` и явно разрешённые порты (по исходному порту назначения `--ctorigdstport`, то есть до DNAT), остальные новые соединения отбрасываются; контейнеры остаются доступны с localhost и из docker-сетей. Docker не трогает чужие правила в `DOCKER-USER`, а `ufw reload` переустанавливает их. Комментарии в блоке только латиницей: ufw перезаписывает свои файлы в ASCII;
- если UFW уже был активен — `ufw reload` при изменениях, подтверждение не требуется;
- если UFW был выключен — `ufw --force enable`, вывод `ufw status verbose`; при наличии удалённой SSH-сессии — `confirm_or_rollback` с самопроверкой «UFW активен и SSH-порты разрешены»; с локальной консоли подтверждение не нужно.

Откат: файлы правил восстанавливаются из копий, UFW возвращается в прежнее состояние.

Состояние: UFW активен, все желаемые правила присутствуют, блок DOCKER-USER есть (или отсутствует) в соответствии с `FW_DOCKER_PROTECT`.

Аудит: UFW активен, политика deny incoming, SSH-порты разрешены, защита DOCKER-USER при установленном Docker, число правил.

---

## fail2ban

Зависимости: preflight; после ssh и firewall.

| Опция | Тип | Умолчание | Назначение |
|---|---|---|---|
| `F2B_MAXRETRY` | int | 5 | неудачных попыток до бана |
| `F2B_FINDTIME` | duration | 10m | окно подсчёта попыток |
| `F2B_BANTIME` | duration | 1h | длительность бана |
| `F2B_INCREMENT` | bool | yes | `bantime.increment`: повторным нарушителям бан удваивается, максимум 1 неделя (adv) |
| `F2B_IGNOREIP` | cidrs | — | никогда не банить |
| `F2B_IGNORE_CURRENT` | bool | yes | добавить IP текущей SSH-сессии в `ignoreip` (adv) |

Файл `/etc/fail2ban/jail.d/ubuntu-bootstrap.local`:

```
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 <F2B_IGNOREIP> <IP текущей сессии>
bantime, findtime, maxretry, bantime.increment, bantime.maxtime = 1w

[sshd]
enabled = true
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session
port = <порты sshd через запятую>
mode = aggressive
```

Почему так: в Ubuntu 24.04+ `auth.log` может отсутствовать, поэтому читается журнал systemd. `journalmatch` явно охватывает unit `ssh.service` (имя в Ubuntu) и процессы `sshd`/`sshd-session` (OpenSSH 9.8+ вынес обработку сессий в отдельный процесс). `backend=systemd` требует `python3-systemd`, который в 22.04 лишь рекомендуемый пакет, поэтому он ставится явно. Порт берётся из `sshd -T`: после смены SSH-порта модуль перевыполняется автоматически (меняется ожидаемое содержимое файла).

Применение: установка, запись файла, `fail2ban-client -t`, включение сервиса, ожидание ответа `fail2ban-client ping`, `reload` только для уже работавшего сервиса при изменении файла, ожидание поднятия jail `sshd`. Откат — прежний файл и `reload-or-restart`.

Аудит: сервис активен, jail поднят, число забаненных сейчас и всего, совпадает ли порт jail с портами sshd.

---

## updates — автоматические обновления

Зависимости: preflight.

| Опция | Тип | Умолчание | Назначение |
|---|---|---|---|
| `UPD_ORIGINS` | enum: security, all | security | `security` — только security-pocket (умолчание Ubuntu); `all` — добавить `-updates` |
| `UPD_AUTO_REBOOT` | bool | no | перезагружаться, если обновление того требует |
| `UPD_REBOOT_TIME` | string | 04:00 | время перезагрузки (локальное) (adv) |
| `UPD_REMOVE_UNUSED` | bool | yes | удалять ненужные зависимости и старые ядра (adv) |
| `UPD_SCHEDULE` | string | — | своё расписание `OnCalendar` для таймеров `apt-daily` и `apt-daily-upgrade`, например `Sun *-*-* 04:00`; пусто — ежедневно, как в Ubuntu (adv) |
| `UPD_MAIL` | email | — | адрес для отчётов (нужен настроенный MTA) (adv) |

Файлы:

- `/etc/apt/apt.conf.d/52ubuntu-bootstrap-unattended`: при `all` — `Allowed-Origins` с `${distro_id}:${distro_codename}-updates` (security и release уже входят в умолчания `50unattended-upgrades`); `Automatic-Reboot`, `Automatic-Reboot-WithUsers "false"`, `Automatic-Reboot-Time`, `Remove-Unused-Dependencies`, `Remove-Unused-Kernel-Packages`, `Remove-New-Unused-Dependencies "true"`, `MinimalSteps "true"`, `SyslogEnable "true"`, при `UPD_MAIL` — `Mail` и `MailReport "on-change"`;
- `/etc/apt/apt.conf.d/20auto-upgrades`: `Update-Package-Lists "1"`, `Unattended-Upgrade "1"`, `AutocleanInterval "7"`;
- при `UPD_SCHEDULE` — drop-in'ы `apt-daily.timer.d/ubuntu-bootstrap.conf` (`RandomizedDelaySec=10m`) и `apt-daily-upgrade.timer.d/ubuntu-bootstrap.conf` (`30m`); расписание проверяется `systemd-analyze calendar`. Без опции drop-in'ы удаляются.

После записи конфигурация проверяется `apt-config dump`, таймеры включаются и перезапускаются (вне контейнера).

Аудит: пакет установлен, `APT::Periodic::Unattended-Upgrade` не 0, таймер активен и когда сработает, политика перезагрузки, последняя запись лога.

---

## sysctl — параметры ядра

Зависимости: preflight.

| Опция | Тип | Умолчание | Назначение |
|---|---|---|---|
| `SYSCTL_HARDENING` | bool | yes | сетевой hardening и защита ФС/ядра |
| `SYSCTL_PERFORMANCE` | bool | yes | производительность сети и файловой системы |
| `SYSCTL_BBR` | bool | yes | TCP BBR + fq |
| `SYSCTL_IP_FORWARD` | enum: auto, on, off | auto | `auto` — выключить форвардинг, если нет Docker или WireGuard (включённого модуля docker, команд `docker`/`wg`, каталога `/etc/wireguard`) (adv) |
| `SYSCTL_IPV6` | enum: keep, disable | keep | `disable` отключает IPv6 (adv) |

Файлы:

- `/etc/sysctl.d/90-ubuntu-bootstrap-hardening.conf` (CIS Ubuntu Benchmark L1, раздел Network Parameters): `tcp_syncookies=1`, `rp_filter=1`, `accept_redirects=0`, `secure_redirects=0`, `send_redirects=0`, `accept_source_route=0`, `log_martians=1`, `icmp_echo_ignore_broadcasts=1`, `icmp_ignore_bogus_error_responses=1`, для IPv6 — `accept_redirects=0`, `accept_source_route=0`, `accept_ra=0`; `fs.protected_symlinks/hardlinks=1`, `protected_fifos/regular=2`, `fs.suid_dumpable=0`, `kernel.kptr_restrict=1`, `kernel.dmesg_restrict=1`, `kernel.randomize_va_space=2`, `kernel.yama.ptrace_scope=1`; `ip_forward=0` и `ipv6 forwarding=0`, если форвардинг не нужен; `disable_ipv6=1` при `SYSCTL_IPV6=disable`;
- `/etc/sysctl.d/91-ubuntu-bootstrap-performance.conf`: `somaxconn=4096`, `tcp_max_syn_backlog=8192`, `netdev_max_backlog=16384`, `ip_local_port_range=1024 65535`, `tcp_fin_timeout=15`, `tcp_tw_reuse=1`, keepalive 600/30/5, `tcp_slow_start_after_idle=0`, `tcp_mtu_probing=1`, буферы 16 MiB, `fs.file-max=2097152`, inotify 524288/1024, `fs.aio-max-nr`, `vm.max_map_count=262144`, `vm.swappiness=10`, `vm.dirty_ratio=20`, `vm.dirty_background_ratio=5`; при BBR — `default_qdisc=fq`, `tcp_congestion_control=bbr`;
- `/etc/modules-load.d/ubuntu-bootstrap-bbr.conf` с `tcp_bbr`.

BBR включается только если ядро его предоставляет (`tcp_available_congestion_control` или `modinfo tcp_bbr`) и запуск не в контейнере; иначе строки BBR не пишутся, выводится предупреждение. Так модуль остаётся идемпотентным на ядрах без BBR.

Файлы применяются `sysctl -p` сразу; в контейнере часть ключей read-only — ошибки отдельных ключей не фатальны (предупреждение), файл применится при загрузке. Команда отката — `sysctl --system` после восстановления файлов. При выключении опции соответствующий файл удаляется.

Аудит (вне контейнера): ключевые значения, `ip_forward` с учётом Docker/WireGuard, текущие `tcp_congestion_control` и `somaxconn`.

---

## limits — лимиты дескрипторов

Зависимости: preflight.

| Опция | Тип | Умолчание | Назначение |
|---|---|---|---|
| `LIMITS_NOFILE` | int | 65535 | soft-лимит открытых файлов; hard всегда 524288 (умолчание systemd) |
| `LIMITS_NPROC` | int | 65535 | лимит процессов (adv) |

Файлы: `/etc/systemd/system.conf.d/90-ubuntu-bootstrap.conf` (`DefaultLimitNOFILE=<soft>:524288`, `DefaultLimitNPROC`) и `/etc/security/limits.d/90-ubuntu-bootstrap.conf` (`*` и `root`, soft/hard nofile и nproc). Значения `[Manager]` читаются только при `systemctl daemon-reexec`, который выполняется при изменении файла; уже работающие сервисы получат лимиты после своего перезапуска, сессии — после нового входа.

Аудит: `DefaultLimitNOFILESoft` systemd, `LimitNOFILE` у nginx.

---

## swap

Зависимости: preflight. В контейнерах не применяется (`MOD_CONTAINER=0`).

| Опция | Тип | Умолчание | Назначение |
|---|---|---|---|
| `SWAP_SIZE` | size | auto | `auto` — 2G при RAM ≤ 2 GiB, иначе 4G; `0` — не создавать; или размер, например `8G` |
| `SWAP_FILE` | path | /swapfile | путь к файлу (adv) |
| `SWAP_SWAPPINESS` | int | 10 | `vm.swappiness` (adv) |

Логика: если swap уже есть и это не наш файл — оставляется как есть; если файл существует, но не активен как swap — ошибка (разобраться вручную); на ZFS swap-файл не поддерживается — пропуск с предупреждением; на btrfs файл создаётся с `chattr +C` и `dd` (не `fallocate`); требуется свободное место: размер + 2 GiB запаса. Создание: `fallocate` (или `dd`), права 600, `mkswap`, `swapon`; команды отката — `swapoff` и удаление файла. Запись в `/etc/fstab` в блоке `# BEGIN ubuntu-bootstrap swap`; файл `/etc/sysctl.d/92-ubuntu-bootstrap-swap.conf` (`vm.swappiness`, `vm.vfs_cache_pressure=50`).

Аудит: наличие swap, прописан ли в fstab.

---

## journald

Зависимости: preflight. Без systemd пропускается.

| Опция | Тип | Умолчание | Назначение |
|---|---|---|---|
| `JOURNALD_MAX_USE` | size | 1G | `SystemMaxUse` |
| `JOURNALD_MAX_FILE` | size | 128M | `SystemMaxFileSize` (adv) |
| `JOURNALD_RETENTION` | duration | 1month | `MaxRetentionSec` (adv) |
| `JOURNALD_FORWARD_SYSLOG` | enum: auto, yes, no | auto | `ForwardToSyslog`; `auto` — yes, если установлен rsyslog (adv) |

Файл `/etc/systemd/journald.conf.d/90-ubuntu-bootstrap.conf`: `Storage=persistent`, `Compress=yes`, лимиты, `RateLimitIntervalSec=30s`, `RateLimitBurst=10000`. Создаётся `/var/log/journal` (группа `systemd-journal`, режим 2755), journald перезапускается при изменении файла.

Аудит: журнал постоянный и сколько занимает, установлен ли logrotate.

---

## docker — Docker CE

Зависимости: preflight, base.

| Опция | Тип | Умолчание | Назначение |
|---|---|---|---|
| `DOCKER_VERSION` | string | — | версия `docker-ce` (`apt-cache madison docker-ce`); пусто — последняя (adv) |
| `DOCKER_REMOVE_CONFLICTS` | bool | yes | удалить `docker.io`, `docker-compose`, `docker-compose-v2`, `docker-doc`, `docker-buildx`, `podman-docker`, `containerd`, `runc` (рекомендация docs.docker.com); требует подтверждения |
| `DOCKER_USERS` | users | — | добавить в группу `docker` (равно root-доступу к хосту; требует подтверждения; альтернатива — `sudo docker`) |
| `DOCKER_LOG_MAX_SIZE` | size | 20M | ротация логов контейнеров: размер файла (adv) |
| `DOCKER_LOG_MAX_FILE` | int | 5 | число файлов (adv) |
| `DOCKER_LIVE_RESTORE` | bool | yes | контейнеры переживают перезапуск демона (adv) |
| `DOCKER_NO_NEW_PRIVILEGES` | bool | no | `no-new-privileges` по умолчанию (ломает образы с setuid) (adv) |
| `DOCKER_PRUNE_TIMER` | bool | no | еженедельная очистка неиспользуемых образов и build-кэша старше 7 дней (adv) |

Применение:

1. Подтверждения до изменений: удаление конфликтующих пакетов (запущенные контейнеры `docker.io` остановятся, данные в `/var/lib/docker` сохраняются); добавление каждого пользователя в группу docker. Без `DOCKER_REMOVE_CONFLICTS` установленные конфликтующие пакеты останавливают модуль предохранителем.
2. Репозиторий: ключ `https://download.docker.com/linux/ubuntu/gpg` скачивается по TLS, его отпечаток сверяется с официальным `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88` **до** записи в `/etc/apt/keyrings/docker.asc`; источник в формате deb822 `/etc/apt/sources.list.d/docker.sources` (`Suites: <codename>`, `Components: stable`, `Architectures: <arch>`, `Signed-By`). Старый `docker.list` удаляется, чтобы не дублировать источник.
3. Пакеты `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin` (с пином версии при `DOCKER_VERSION`, доступность проверяется заранее). Команда отката — `systemctl disable --now docker containerd` (пакеты не удаляются).
4. `/etc/docker/daemon.json`: `log-driver json-file`, `log-opts max-size/max-file`, `live-restore`, `no-new-privileges`, `default-ulimits nofile 65535:524288`. Существующий файл **не перезаписывается**: наши ключи добавляются только если их нет (`jq`), чужие значения, включая `data-root` и другой `log-driver`, сохраняются. При изменении — `systemctl restart docker` (с `live-restore` контейнеры продолжают работать).
5. Группа docker: `usermod -aG docker`, откат `gpasswd -d`; нужен перелогин.
6. Prune-таймер: `ubuntu-bootstrap-docker-prune.service` (`docker system prune -f --filter until=168h`, `docker builder prune`) и `.timer` (`Sun *-*-* 03:30`, `RandomizedDelaySec=30m`, `Persistent=true`).
7. Отчёт: контейнеры с `privileged` или смонтированным `docker.sock`, порты на `0.0.0.0` (снаружи доступны в обход UFW, если нет защиты DOCKER-USER).

Аудит: демон работает, пакет официальный, ротация логов, контейнеры с портами на всех интерфейсах и privileged, состав группы docker, свободное место в `/var/lib/docker`.

---

## nginx

Зависимости: preflight, base.

| Опция | Тип | Умолчание | Назначение |
|---|---|---|---|
| `NGINX_SOURCE` | enum: ubuntu, stable, mainline | stable | `ubuntu` — пакет дистрибутива (патчи Canonical, версия заморожена на релиз); `stable`/`mainline` — nginx.org |
| `NGINX_VERSION` | string | — | версия пакета; пусто — последняя (adv) |
| `NGINX_SERVER_TOKENS` | bool | no | показывать версию в заголовках и страницах ошибок (adv) |
| `NGINX_SECURITY_SNIPPET` | bool | yes | создать `snippets/security-headers.conf` |
| `NGINX_CLIENT_MAX_BODY` | size | 20M | `client_max_body_size` (adv) |
| `NGINX_DISABLE_DEFAULT_SITE` | bool | no | отключить сайт по умолчанию (`sites-enabled/default` или `conf.d/default.conf`) (adv) |

Применение:

- для nginx.org: ключ `https://nginx.org/keys/nginx_signing.key` (файл содержит несколько ключей, проверяется **вхождение** официального отпечатка `573B FD6B 3D8F BC64 1079 A6AB ABF5 BD82 7BD9 BF62`), deb822-источник `/etc/apt/sources.list.d/nginx.sources`, пин `/etc/apt/preferences.d/99nginx` с приоритетом 900 (пакеты nginx.org предпочитаются дистрибутивным);
- если nginx уже установлен из другого источника, источник не меняется (разные пути конфигов), выводится предупреждение;
- `/etc/nginx/conf.d/00-ubuntu-bootstrap.conf` (уровень `http{}`): `server_tokens`, `client_max_body_size`, таймауты клиента 30s, `keepalive_requests 1000`, TLS по профилю Mozilla intermediate (`TLSv1.2 TLSv1.3`, `ssl_prefer_server_ciphers off`, session cache/tickets), gzip, `map $http_upgrade $ubb_connection_upgrade` для WebSocket-проксирования;
- `/etc/nginx/snippets/security-headers.conf`: `X-Content-Type-Options nosniff`, `X-Frame-Options SAMEORIGIN`, `Referrer-Policy strict-origin-when-cross-origin`, `Permissions-Policy`; CSP и HSTS сознательно не задаются (сайтозависимы; HSTS добавляет certbot при `CERTBOT_HSTS`). Подключается в `server{}` строкой `include snippets/security-headers.conf;`;
- drop-in `nginx.service.d/ubuntu-bootstrap.conf` с `LimitNOFILE=65535`;
- `nginx -t` перед включением; `reload` при изменениях; команда отката — `reload`, если конфиг валиден.

Аудит: конфиг валиден, сервис активен, `server_tokens off`, нет TLSv1/1.1, число сайтов.

---

## certbot — Let's Encrypt

Зависимости: preflight; после nginx и firewall.

| Опция | Тип | Умолчание | Назначение |
|---|---|---|---|
| `CERTBOT_METHOD` | enum: auto, snap, apt | auto | snap — рекомендация EFF, всегда свежая версия; `auto` — snap, если snapd работает (не в контейнере), иначе apt |
| `CERTBOT_DOMAINS` | hostnames | — | домены; первый — основной; пусто — только установить certbot |
| `CERTBOT_EMAIL` | email | — | для уведомлений об истечении; пусто — `--register-unsafely-without-email` |
| `CERTBOT_REDIRECT` | bool | yes | редирект HTTP → HTTPS |
| `CERTBOT_HSTS` | bool | no | заголовок HSTS (adv) |
| `CERTBOT_STAGING` | bool | no | тестовый ACME-сервер без лимитов, сертификат недоверенный (adv) |
| `CERTBOT_DNS_CHECK` | bool | yes | перед выпуском проверить, что A-записи указывают на этот сервер (adv) |

Применение:

1. Установка: snap (`snapd`, `snap install core`, `snap install --classic certbot`, ссылка `/usr/bin/certbot`) или apt (`certbot python3-certbot-nginx`).
2. Без доменов — конец. Для выпуска нужен nginx (`--nginx`).
3. Если сертификат для основного домена уже есть — только `certbot renew --dry-run`.
4. Предохранитель DNS: каждый домен резолвится в публичный IP сервера (определяется через `api.ipify.org`, запасной вариант — IP интерфейса по умолчанию); иначе код 3 (`CERTBOT_DNS_CHECK=no` отключает). Предупреждение, если порт 80 никто не слушает.
5. Если в nginx нет `server_name` с основным доменом — создаётся минимальный HTTP-сайт `sites-available/<домен>.conf` (+ ссылка в `sites-enabled`) или `conf.d/<домен>.conf`, чтобы certbot мог пройти HTTP-01 и дописать TLS.
6. `certbot --nginx -d ... --agree-tos --no-eff-email --non-interactive --keep-until-expiring` с `--redirect/--no-redirect`, `--hsts`, `--staging`; затем `certbot renew --dry-run`. Снимок конфига сайта делается заранее, команда отката — `reload` nginx.

Аудит: таймер продления (`certbot.timer` или `snap.certbot.renew.timer`), срок каждого сертификата (предупреждение при < 14 дней).

---

## git — deploy-ключи

Зависимости: preflight, base; после users.

| Опция | Тип | Умолчание | Назначение |
|---|---|---|---|
| `GIT_HOSTS` | hostnames | — | `github.com`, `gitlab.com`, `bitbucket.org`, свой; пусто — модуль не нужен |
| `GIT_USER` | user | — | владелец ключей; пусто — `ADMIN_USER`, иначе root (adv) |
| `GIT_CHECK` | bool | no | после настройки проверить `ssh -T git@host` (ключ должен быть уже добавлен в репозиторий) (adv) |

Для каждого хоста: ключ `~/.ssh/deploy_<первая метка хоста>` (ed25519, без пароля, комментарий `deploy@<hostname>-<host>`), запись в `~/.ssh/known_hosts` (для GitHub — ключи из `https://api.github.com/meta`, доверие через TLS; для остальных — `ssh-keyscan` с показом отпечатков и предупреждением сверить их с документацией провайдера), блок `Host <host>` в `~/.ssh/config` с `IdentityFile` и `IdentitiesOnly yes`. Публичный ключ печатается — его нужно добавить как Deploy key.

---

## wg-network — установка wg-network

Зависимости: preflight, base.

| Опция | Тип | Умолчание | Назначение |
|---|---|---|---|
| `WG_REPO` | string | — | `owner/repo`; пусто — репозиторий, из которого установлен ubuntu-bootstrap (adv) |
| `WG_REF` | string | — | ветка/тег/commit; пусто — тот же ref (adv) |

Скачивает `ubuntu/wg/install.sh` указанного репозитория и ref по TLS, проверяет `bash -n` и запускает его с `--repo` и `--ref`. Установщик wg-network сам проверяет и атомарно ставит инструмент в `/opt/wg-network`. Настройка WireGuard-сети — отдельный слой: `sudo wg-network help` (`init-hub`, `init-peer`). Модуль sysctl не отключает `ip_forward`, если WireGuard установлен; модуль firewall не трогает UDP-порты WireGuard — их открывает сам wg-network.
