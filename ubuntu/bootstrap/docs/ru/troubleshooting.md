# Диагностика и типичные ситуации

Первое, что стоит выполнить при любой проблеме:

```bash
sudo ubuntu-bootstrap doctor          # окружение, целостность, зависшие запуски, ожидающие подтверждения
sudo ubuntu-bootstrap status          # какие модули применены, что устарело
sudo ubuntu-bootstrap history         # запуски; history <RUN_ID> — что именно изменил запуск
sudo less /var/log/ubuntu-bootstrap/<RUN_ID>.log
journalctl -t ubuntu-bootstrap
```

## Потерял SSH-доступ после apply

Если изменение ждало подтверждения (смена порта, включение UFW), ничего делать не нужно: через `SSH_CONFIRM_TIMEOUT` / `FW_CONFIRM_TIMEOUT` секунд (по умолчанию 180) оно откатится само, и прежний доступ вернётся. Если в этом окне сервер перезагрузился, откат выполнит `ubuntu-bootstrap-recover.service` при загрузке.

Если доступа нет спустя таймаут, зайди через консоль провайдера (VNC/serial) и выполни:

```bash
sudo ubuntu-bootstrap rollback --pending      # если что-то ещё ожидает подтверждения
sudo ubuntu-bootstrap history                 # найти запуск
sudo ubuntu-bootstrap rollback --last         # или rollback <RUN_ID> [--module ssh]
```

Откат восстанавливает файлы из `/var/backups/ubuntu-bootstrap/<RUN_ID>/` и выполняет команды отката (перезапуск sshd, удаление правил UFW). Если инструмент недоступен, файлы можно скопировать из бэкапа вручную: пути внутри каталога бэкапа повторяют абсолютные пути системы.

Частые причины потери доступа, которые самопроверка на сервере не видит: security group / firewall провайдера не пропускает новый порт; клиент подключается не тем ключом или не тем пользователем, что указан в `AllowUsers`. Для таких окружений используй `SSH_CONFIRM=wait` и подтверждай доступ из новой сессии командой `confirm`.

## Код 3: остановлено предохранителем

Сообщение называет конкретную причину. Типичные:

| Сообщение | Что делать |
|---|---|
| ни у одного разрешённого пользователя нет `authorized_keys` | задать `ADMIN_SSH_KEYS` / `ADMIN_SSH_KEYS_GITHUB`, или положить ключ root (`ADMIN_COPY_ROOT_KEYS`), или временно `SSH_PASSWORD_AUTH=yes` |
| `PermitRootLogin no`: нет пользователя с ключом и работающим sudo | задать `ADMIN_SUDO_MODE=nopasswd` или пароль (`ADMIN_PASSWORD_HASH` / `passwd`), либо `SSH_PERMIT_ROOT=prohibit-password` |
| текущий пользователь не входит в `AllowUsers` | добавить его в `SSH_ALLOW_USERS` или зайти под нужным пользователем |
| порт уже занят другим сервисом | выбрать другой `SSH_PORT` |
| `FW_SSH_FROM` не включает IP текущей сессии | добавить свой адрес в список |
| DNS не готов (certbot) | исправить A-записи или `CERTBOT_DNS_CHECK=no`, если проверка ошибается (например, за NAT) |
| установлены конфликтующие пакеты (docker) | `DOCKER_REMOVE_CONFLICTS=yes` |
| `SSH_CONFIRM=none` / `FW_CONFIRM=none` | это осознанно опасный режим: `--force` |
| ОС не поддерживается | `--force` снимает проверку версии; поведение на других версиях не тестировалось |

`--force` снимает **все** предохранители сразу; подтверждения и таймер отката при этом остаются.

## Код 4: изменения откачены

Таймер подтверждения истёк, самопроверка не прошла или был дан ответ «нет». Сервер в прежнем состоянии. Причины и решения см. выше; после устранения просто повтори `apply`.

## Код 5: занято

- «ubuntu-bootstrap уже выполняется» — другой экземпляр держит блокировку; дождись его или проверь `ps aux | grep ubuntu-bootstrap`. Блокировка снимается автоматически даже после SIGKILL (flock освобождается ядром).
- «модуль … ждёт подтверждения» — сначала `sudo ubuntu-bootstrap confirm` (из новой сессии) или `rollback --pending`.
- «apt/dpkg занят» — сразу после загрузки `unattended-upgrades` может работать несколько минут; инструмент ждёт до 5 минут (preflight — 2 минуты). Проверь `ps aux | grep -E 'apt|dpkg|unattended'`.

## Код 1: ошибка модуля

Изменения модуля уже откачены. Причина — в выводе (последние строки упавшей команды) и в логе запуска. Частые случаи:

- `apt-get` не нашёл пакет или нет сети: проверь `BASE_EXTRA_PACKAGES`, `doctor` (HTTPS до `archive.ubuntu.com`).
- «не удалось скачать ключ» (docker/nginx): нет доступа к `download.docker.com` / `nginx.org`.
- «отпечаток ключа не совпал» — ключ репозитория изменился или трафик подменяется; не продолжай, пока не разберёшься.
- `sshd -t: конфиг невалиден` — конфликт с другим файлом в `sshd_config.d`; смотри вывод `sshd -t`.
- `visudo забраковал файл sudoers` — имя пользователя с недопустимыми символами.
- `jail sshd не поднялся` — `journalctl -u fail2ban`; обычно отсутствует `python3-systemd` или сломан другой jail в `jail.d`.

После исправления повтори `apply`: применённые ранее модули будут пропущены, упавший — выполнен заново.

## Запуск помечен `running` или `interrupted`

`running` после аварийного завершения (SIGKILL, падение питания) означает, что процесс не успел записать статус. Убедись, что процесса нет (`ps aux | grep ubuntu-bootstrap`), затем при необходимости `rollback <RUN_ID>`. `interrupted` — процесс получил SIGTERM/SIGINT и завершился между шагами; его изменения не откачены автоматически, это делает `rollback <RUN_ID>`.

## fail2ban забанил мой IP

```bash
sudo fail2ban-client status sshd
sudo fail2ban-client set sshd unbanip <IP>
```

Чтобы это не повторялось: `F2B_IGNOREIP=<твой IP или сеть>`; IP текущей сессии добавляется автоматически при `F2B_IGNORE_CURRENT=yes`.

## Контейнер Docker недоступен снаружи

Это защита DOCKER-USER (`FW_DOCKER_PROTECT`). Правильный путь — публиковать порты на `127.0.0.1` и проксировать через nginx. Если контейнер должен быть доступен напрямую:

```bash
sudo ubuntu-bootstrap config set FW_DOCKER_ALLOW_PORTS=8080/tcp
sudo ubuntu-bootstrap apply --only firewall
```

## Как изменить настройку после применения

```bash
sudo ubuntu-bootstrap config set SSH_PORT=2222
sudo ubuntu-bootstrap plan
sudo ubuntu-bootstrap apply
```

Переприменятся только модули, чьи опции изменились. `apply --reapply` принудительно выполняет все выбранные модули (идемпотентно).

## Как выключить модуль и убрать его настройки

Исключение модуля из набора (`MODULES_SKIP=…`) не удаляет его файлы: инструмент не делает деструктивных действий без явной команды. Чтобы вернуть систему к состоянию до модуля — `rollback <RUN_ID> --module <имя>` для запуска, который его применил (см. `history`). Файлы инструмента легко узнать по имени: `ubuntu-bootstrap` в имени файла или блок `# BEGIN ubuntu-bootstrap …` внутри чужого.

## sshd не слушает новый порт после apply

На Ubuntu 22.10+ sshd socket-активирован; инструмент перезапускает `ssh.socket` сам. Если порт всё же не поменялся: `systemctl status ssh.socket`, `ss -ltn`, `sshd -T | grep ^port`. Проверь, нет ли в `/etc/ssh/sshd_config.d/` файла с меньшим префиксом, чем `00-`, или `ListenAddress` в основном конфиге.

## certbot не выпустил сертификат

Типичные причины: DNS домена не указывает на сервер; порт 80 закрыт у провайдера; nginx не слушает 80; лимиты Let's Encrypt (5 неудач в час на набор доменов) — для отладки `CERTBOT_STAGING=yes`. Подробности в `/var/log/letsencrypt/letsencrypt.log`.

## Мастер отказывается запускаться без терминала

`wizard` интерактивен по определению. Для автоматизации: `apply --profile NAME --set KEY=VALUE ... --yes` или файл конфигурации (`config init`, затем `apply`).

## Внутри контейнера / LXC

Пропускаются swap, NTP-демон, snap (certbot из apt); sysctl применяется только для доступных ключей; UFW требует `NET_ADMIN`. `status` показывает такие модули как `n/a`.

## Где что лежит

| Что | Путь |
|---|---|
| Лог запуска | `/var/log/ubuntu-bootstrap/<RUN_ID>.log` |
| События | `journalctl -t ubuntu-bootstrap` |
| Журнал изменений | `/var/lib/ubuntu-bootstrap/runs/<RUN_ID>/journal` (`history <RUN_ID>` показывает читаемо) |
| Бэкапы | `/var/backups/ubuntu-bootstrap/<RUN_ID>/<абсолютный путь>` |
| Состояние модулей | `/var/lib/ubuntu-bootstrap/modules/<модуль>.env` |
| Ожидающее подтверждение | `/var/lib/ubuntu-bootstrap/pending.env` |
| Конфигурация | `/etc/ubuntu-bootstrap/bootstrap.conf` |
| Файлы, которые пишет инструмент | `/etc/ssh/sshd_config.d/00-ubuntu-bootstrap.conf`, `/etc/fail2ban/jail.d/ubuntu-bootstrap.local`, `/etc/sysctl.d/9[0-2]-ubuntu-bootstrap-*.conf`, `/etc/security/limits.d/90-ubuntu-bootstrap.conf`, `/etc/systemd/system.conf.d/90-ubuntu-bootstrap.conf`, `/etc/systemd/journald.conf.d/90-ubuntu-bootstrap.conf`, `/etc/apt/apt.conf.d/52ubuntu-bootstrap-unattended`, `/etc/apt/apt.conf.d/20auto-upgrades`, `/etc/sudoers.d/90-ubuntu-bootstrap-<user>`, `/etc/nginx/conf.d/00-ubuntu-bootstrap.conf`, `/etc/nginx/snippets/security-headers.conf`, `/etc/docker/daemon.json` (merge), `/etc/apt/sources.list.d/{docker,nginx}.sources`, `/etc/apt/keyrings/{docker,nginx}.asc`, блоки в `/etc/fstab`, `/etc/hosts`, `/etc/ufw/after.rules` |
