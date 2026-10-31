# Тестирование

```
tests/run.sh lint        shellcheck -S style для всех скриптов (локальный или через docker koalaman/shellcheck)
tests/run.sh unit        tests/unit.sh — без root, сети и изменений системы
tests/run.sh e2e         tests/e2e.sh — Docker-контейнеры Ubuntu с systemd
tests/run.sh coverage    e2e + unit под kcov (Ubuntu 26.04), сводка tests/.coverage-summary.txt
tests/run.sh all         lint + unit + e2e
```

Хост при тестировании не меняется: всё, что требует root, выполняется в контейнерах.

## Lint

`shellcheck -x -S style` для точки входа, `install.sh`, `lib/*.sh`, `commands/*.sh`, `modules/*.sh`, `completion/*.bash`, `tests/*.sh`. Три предупреждения отключены глобально в `.shellcheckrc` с объяснением (SC2034 — переменные используются в других файлах через `source`; SC2153 — ключи ассоциативных массивов; SC2015 — намеренное `A && B || C`).

## Unit (`tests/unit.sh`)

Библиотеки загружаются напрямую в тестовый процесс, пути состояния переносятся в песочницу через `UBB_SYSROOT`, поэтому транзакции, состояние модулей и таймеры отката работают во временном каталоге. Около 200 проверок:

- валидаторы (порты, ключи, hostname, CIDR, размеры, интервалы, e-mail, git ref, имена пользователей);
- `KEY=VALUE`: чтение, запись с сохранением порядка ключей, отклонение мусора и ключей в нижнем регистре; списки, `join_by`, `in_list`, `json_str`;
- факты из `os-release`;
- реестр модулей: обнаружение 17 модулей, порядок, зависимости (`certbot → preflight`, `ssh docker firewall`, `fail2ban` после `ssh` и `firewall`), обнаружение цикла через свои модули, набор по умолчанию, принадлежность опций модулям, флаг adv;
- опции всех типов; приоритет профиль → файл → `--set`; `MODULES_ADD/SKIP`; отклонение неизвестной опции, невалидного значения, неизвестного модуля, повреждённого конфига, несуществующего профиля; `--only` с зависимостями и `--skip`; валидность всех встроенных профилей;
- транзакции: журнал, `config_save`, `file_write` (создание, идемпотентность, изменение, права, бэкап, записи `W`), `undo`, `file_set_block` (добавление, замена, удаление, сохранение чужих строк), `file_remove`, откат одного модуля и всего запуска, dry-run не пишет, маскирование секретов, `run`, статусы, состояние модулей, хэш конфигурации;
- отложенный откат через `setsid` (без systemd): `pending_arm/disarm/rollback/confirm`;
- рендер конфигов модулей: ssh (Port, AllowUsers, KbdInteractive), fail2ban (ignoreip, journalmatch), firewall (правила, DOCKER-USER, `cidr_contains4`), sysctl (ip_forward, BBR в зависимости от доступности в ядре и контейнера), docker (валидный JSON, merge с чужим `daemon.json`), updates, journald, limits, nginx, swap (auto-размер), users (сбор ключей);
- аудит: счётчики, коды выхода, валидный JSON;
- CLI без root: `version --json`, `modules --json`, `help`, коды выхода при ошибках использования, `config validate` с опечаткой, `install.sh --help`, `bash -n` всех файлов.

## E2E (`tests/e2e.sh`)

```
tests/e2e.sh [--version 24.04] [--only NAME[,NAME]] [--keep] [--coverage]
UBUNTU_VERSIONS="22.04 24.04 26.04" tests/e2e.sh
```

Образ `tests/docker/Dockerfile` имитирует Ubuntu Server: systemd как PID 1, `openssh-server` (с socket-активацией на 24.04+), `ufw`, `sudo`, `unattended-upgrades`, `rsyslog`, известный пароль root. Контейнеры запускаются `--privileged --cgroupns=private` (iptables, docker-in-docker), `/var/lib/docker` и `/var/lib/containerd` — отдельные volume (overlay поверх overlay не монтируется), исходники монтируются в `/src` только для чтения, порты 22/2222/2200 проброшены на `127.0.0.1`. Тесты ходят по SSH **с хоста** настоящим клиентом с ключом и проверяют, какие методы аутентификации предлагает sshd.

| Контейнер | Сценарии |
|---|---|
| A | `install` (установка, повторная установка с `.old`, `--rollback`, отклонение плохих `--ref`/`--sha256`, отказ ставить дерево с синтаксической ошибкой, `doctor`, `audit` на свежей системе) → `fresh` (`plan` без изменений в системе, `apply` minimal, реальный вход ключом и `sudo -n`, пароль не предлагается, UFW limit, fail2ban, unattended, journald, `status`, `audit`, `history`, бэкапы) → `fail2ban` (бан после настоящих неудачных входов, `journalmatch`, разбан) → `idempotent` (второй `apply` пропускает всё кроме preflight, `--reapply` не меняет файлы и не дублирует ключи) → `port` (22→2222: самопроверка, `ssh.socket`, UFW, fail2ban переприменён, старый порт закрыт) → `pending` (`SSH_CONFIRM=wait`: таймер systemd, `apply` при pending → 5, откат по таймеру, вход по старому порту; `confirm` по ssh через новый порт, старый порт закрыт после confirm) → `reboot` (`docker restart` с pending: recover-сервис откатывает, sshd/ufw/fail2ban живы) → `rollback` (`history RUN_ID`, `rollback --module`, ошибки использования) → `failures` (свой падающий модуль: откат файла и `undo`, состояние `failed`, остановка без `--keep-going`, продолжение с ним, исправленный модуль применяется, несуществующий пакет) → `interrupt` (SIGTERM: статус `interrupted`, блокировка не залипает, ручной откат; SIGKILL: `doctor` видит `running`) → `uninstall` (сервисы продолжают работать) |
| B | `guards` (без ключей → 3; `PermitRootLogin no` без администратора → 3; `auto` → prohibit-password и реальный вход root по ключу; `AllowUsers` без ключей → 3; users без пароля → предупреждение и копия ключей root; `PermitRootLogin no` при неработающем sudo → 3; пароль из хэша; затем root больше не входит, deploy входит) → `corrupt` (мусор в конфиге, невалидное значение с источником, опечатка в имени, `config get/show`) → `wg` (установка wg-network, если `ubuntu/wg/install.sh` доступен в GitHub) |
| C | `preconfigured` (cloud-init `PasswordAuthentication yes`, существующий пользователь с ключом и sudoers, UFW с чужими правилами: правила сохранены, `00-` побеждает, ключи не тронуты, бэкап `after.rules`) → `network` (REJECT 80/443: модуль nginx падает, не зависает, источник и keyring не оставлены; `doctor` после восстановления) → `services` (профиль full без git/wg/swap: Docker из deb822 с проверенным отпечатком, `daemon.json`, compose, DOCKER-USER в iptables, nginx.org, `server_tokens off`, `LimitNOFILE`, 80/443 открыты, certbot из apt, DNS-предохранитель → 3; контейнер с портом на `0.0.0.0` недоступен из соседнего контейнера, доступен после `FW_DOCKER_ALLOW_PORTS`, nginx хоста доступен) |

Опции: `--version` — одна или несколько версий через пробел; `--only` — список сценариев (`install fresh fail2ban idempotent port pending reboot rollback failures interrupt uninstall guards corrupt wg preconfigured network services`); `--keep` — не удалять контейнеры после прогона; `UBB_REBUILD=1` — пересобрать образ.

Особенности, учтённые в тестах: `ufw limit` пропускает не более 6 новых соединений за 30 секунд с одного IP, поэтому SSH-интенсивные шаги разнесены паузами; REJECT от fail2ban на уже установленном соединении — для TCP «мягкая» ошибка, и ssh-клиент зависал бы в рукопожатии, поэтому каждый вызов ssh обёрнут в `timeout`; Docker Desktop иногда не монтирует bind-каталоги с первого раза — запуск контейнера повторяется до трёх раз; `systemd-detect-virt` внутри контейнеров на WSL2 сообщает `wsl`, что считается контейнером.

Результаты последнего полного прогона: 22.04 — 205 проверок, 24.04 — 203, 26.04 — 206, провалов нет.

## Покрытие

```
tests/run.sh coverage            # UBB_COV_DIR=... переопределяет каталог отчётов
```

kcov инструментирует bash через DEBUG-ловушку. Каждый вызов `ubuntu-bootstrap` в e2e пишет отдельный отчёт `cobertura.xml`; `tests/coverage-merge.py` объединяет их по принципу «строка покрыта, если покрыта хотя бы в одном запуске» (`kcov --merge` для bash-отчётов даёт пустой результат) и печатает таблицу по файлам. kcov есть в apt Ubuntu 26.04 (в 24.04 отсутствует), поэтому покрытие измеряется там. Отчёты создаются root внутри контейнера и лежат вне дерева исходников (`$TMPDIR/ubuntu-bootstrap-coverage`), потому что `/src` смонтирован только для чтения.

Измеренное покрытие: около 35 % строк по объединению unit и e2e. Цифра занижена: таймер отката и recover-сервис выполняются отдельными процессами через `systemd-run` и не инструментируются; мастер проверяется вручную через pseudo-tty; snap-путь certbot, swap и часть sysctl недоступны в контейнерах.

## CI

`.github/workflows/ubuntu-bootstrap.yml`: при изменениях в `ubuntu/bootstrap/**` — `lint-unit`, затем e2e матрицей 22.04 / 24.04 / 26.04 (privileged-контейнеры на `ubuntu-latest`) и coverage с публикацией сводки артефактом.

`.github/workflows/ubuntu-bootstrap-release.yml`: тег `ubuntu-bootstrap-vX.Y.Z` → проверка совпадения с `VERSION`, lint и unit, воспроизводимый архив (`--owner=0 --group=0 --mtime --sort=name`), `SHA256SUMS`, подпись `SHA256SUMS.asc` при наличии секрета `UBB_GPG_PRIVATE_KEY`, GitHub Release.

## Чего тесты не проверяют

- Реальный выпуск сертификата Let's Encrypt (нужен публичный домен): проверяются установка certbot, DNS-предохранитель и логика.
- snap-установку certbot (snapd не работает в контейнерах): покрыт apt-путь.
- swap и sysctl ядра: принадлежат хосту контейнера; рендер файлов покрыт unit-тестами.
- arm64: тесты идут на amd64; специфичного кода для архитектуры нет (она подставляется в deb822).
- Интерактивный мастер: проверяется вручную.
- Системы без systemd: таймер отката через `setsid` покрыт unit-тестом, целиком такой сценарий не тестируется.
