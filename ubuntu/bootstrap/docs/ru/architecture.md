# Архитектура

## Структура

```
ubuntu/bootstrap/
├── ubuntu-bootstrap          точка входа: глобальные опции, загрузка lib/, выбор команды
├── install.sh                установка / обновление / откат / удаление (безопасен для curl | bash)
├── VERSION                   версия (сверяется с тегом релиза в CI)
├── lib/
│   ├── core.sh               вывод и лог, коды выхода, временные файлы, атомарная запись, KEY=VALUE, списки
│   ├── validate.sh           предикаты is_* для всех входных данных
│   ├── paths.sh              пути состояния; UBB_SYSROOT переносит их в песочницу тестов
│   ├── facts.sh              факты о системе F_*, sshd -T как источник истины, пользователи, «планируемые факты»
│   ├── pkg.sh                apt с ожиданием блокировок, репозитории deb822 с проверкой отпечатка, snap
│   ├── svc.sh                systemd-юниты, drop-in, применение конфига sshd с учётом socket-активации
│   ├── tx.sh                 транзакции: журнал, бэкапы, file_write/undo, откат, таймер отката, состояние модулей
│   ├── options.sh            объявление опций (opt), сборка и валидация конфигурации, профили, сохранение
│   ├── modules.sh            реестр модулей, зависимости, топологическая сортировка
│   ├── runner.sh             цикл применения, предохранители, подтверждение рискованных изменений
│   ├── ui.sh                 диалог: терминал / --yes / без терминала, подтверждения, обратный отсчёт
│   └── audit.sh              накопитель проверок для audit и doctor
├── commands/<cmd>.sh         одна команда = один файл
├── modules/<module>.sh       один модуль = один файл
├── profiles/*.conf           наборы модулей и значения опций
├── systemd/                  ubuntu-bootstrap-recover.service
├── completion/               bash-автодополнение
├── examples/                 web.conf, docker-host.conf, cloud-init.yaml, ansible.yml
├── docs/ru, docs/en          документация
└── tests/                    run.sh, lib.sh, unit.sh, e2e.sh, coverage-merge.py, docker/Dockerfile
```

Команда — файл `commands/<имя>.sh` с переменными `CMD_SUMMARY`, `CMD_GROUP` (setup/run/inspect/maintenance), `CMD_ROOT` (1 по умолчанию) и функциями `cmd_usage`, `cmd_run`. Модуль — файл `modules/<имя>.sh` (контракт в [Расширение](extending.md)). Новый файл подхватывается автоматически: точка входа перечисляет каталоги, регистрация не нужна.

## Точка входа

1. `set -Eeuo pipefail`, `shopt -s lastpipe` (последняя команда конвейера выполняется в текущей оболочке, поэтому `render | file_write` выставляет `FILE_CHANGED`), `umask 022`, `LC_COLLATE=C`.
2. Загружаются библиотеки в фиксированном порядке: core, validate, paths, facts, pkg, svc, tx, options, modules, ui, audit, runner.
3. Ловушки: `EXIT` → `on_exit` (хуки завершения, удаление временных каталогов), `INT`/`TERM` → выход 130, `HUP` → `ui_on_hangup` (продолжить без терминала), `ERR` → `on_err` (сообщение с файлом и строкой; намеренный `return N` не считается сбоем).
4. `parse_global_args` разбирает опции до первого слова команды; `ui_init` определяет интерактивность (stdin-терминал или доступный `/dev/tty`; `--yes` отключает).
5. Загружается файл команды; при `CMD_ROOT=1` без root — отказ (с `--dry-run` только предупреждение).
6. `facts_load`, `modules_discover`, затем `cmd_run` с оставшимися аргументами.

## Поток `apply`

1. `config_load`: профиль (из `--profile` или `PROFILE=` в файле) → файл конфигурации → `--set`; каждая пара проверяется типом опции, неизвестные ключи и неверные значения — ошибка с указанием источника.
2. `runner_select` → `modules_selected`: модули из `--only` или конфига (`MODULES` / набор по умолчанию + `MODULES_ADD` − `MODULES_SKIP`), транзитивные зависимости `MOD_DEPS`, минус `--skip`, плюс `preflight` первым. Сортировка — алгоритм Кана по рёбрам `MOD_DEPS` и `MOD_AFTER` среди выбранных модулей; при равенстве приоритет у канонического порядка `MOD_CANON`, незнакомые модули идут после него по алфавиту; цикл — ошибка.
3. Если есть `pending.env` — код 5.
4. `tx_begin`: блокировка, каталог запуска, журнал, каталог бэкапов, лог, `run.env` со статусом `running`, событие в journald, регистрация хука `tx_on_exit` (помечает незавершённый запуск `interrupted`).
5. Для каждого модуля:
   - `module_load` (сбрасывает заглушки `mod_*`, загружает файл);
   - пропуск, если `MOD_CONTAINER=0` в контейнере;
   - пропуск, если состояние `applied`, хэш опций совпадает и `mod_check` проходит (кроме `MOD_ALWAYS=1` и `--reapply`);
   - `tx_module_begin` (запись `M`), `mod_apply`;
   - код 0 → `mod_verify` → `runner_mark_applied` (STATUS, CONFIG_HASH, APPLIED_AT, RUN_ID, VERSION); провал проверки → откат модуля как при ошибке;
   - код 3 (`E_REFUSED`) → откат записей модуля (обычно их нет: предохранители срабатывают до изменений), состояние `refused`, остановка (или продолжение с `--keep-going`);
   - код 4 (`E_ROLLED_BACK`) → модуль уже откатился сам (таймер/отказ), остановка;
   - другой код → `runner_fail`: снять ожидающий таймер этого модуля, откатить его записи журнала, состояние `failed`, остановка.
6. `runner_finish`: статус запуска (`done`/`failed`/`refused`/`rolled_back`), сводка (применено, пропущено, откачено, остановлено, файлы, предупреждения, ожидающее подтверждение, пути к бэкапам и логу), напоминание о перезагрузке; код выхода — первый ненулевой из ошибок/отказов/откатов.

`plan` — тот же поток с `DRY_RUN=1`. `wizard` сначала собирает конфигурацию в диалоге, сохраняет её, затем запускает тот же поток в dry-run (в подоболочке) и, после согласия, по-настоящему.

## Факты (`lib/facts.sh`)

Собираются один раз только чтением: ОС и кодовое имя из `/etc/os-release`, архитектура, ядро, наличие systemd, виртуализация и признак контейнера (`systemd-detect-virt -c`, `/.dockerenv`, `/run/.containerenv`), память, swap, CPU, свободное место, тип корневой ФС, интерфейс и IP маршрута по умолчанию, hostname, признак `reboot-required`, текущая SSH-сессия (из `SSH_CONNECTION`; под `sudo` переменная сбрасывается, тогда адрес клиента берётся из `who -m`), порты sshd из `sshd -T`.

`sshd -T` — источник истины для эффективной конфигурации sshd (учитывает все `Include` и порядок директив). При socket-активации каталог `/run/sshd` может отсутствовать до первого подключения — он создаётся перед вызовом.

«Планируемые факты» (`plan_mark user:deploy`, `keys:deploy`, `sudo:deploy`) заполняются модулями только в dry-run; `user_exists`, `user_has_keys`, `user_sudo_usable`, `human_users` их учитывают, поэтому предохранители ssh в плане видят пользователя, которого users создаст раньше в том же запуске.

## Опции и конфигурация (`lib/options.sh`)

`opt NAME TYPE DEFAULT HELP [adv]` регистрирует опцию с типом, умолчанием, описанием, модулем-владельцем и признаком «дополнительная». Опции всех модулей загружаются при `modules_discover`, поэтому валидация конфига знает весь словарь, а `modules --options` печатает его целиком. `cfg NAME` возвращает действующее значение (`CONF` или умолчание), `cfg_bool`, `cfg_list` — удобные обёртки. Хэш конфигурации модуля — SHA256 от пар `NAME=значение` всех его опций; он сохраняется при применении и сравнивается при следующем запуске.

Файлы `KEY=VALUE` читаются `kv_load` (без `source`): проверяется форма строки и имя ключа, значения берутся как есть. `kv_set` сохраняет порядок ключей файла.

## Транзакции (`lib/tx.sh`)

| Функция | Назначение |
|---|---|
| `tx_begin CMD` | блокировка, каталоги, журнал, лог, `run.env`, хук завершения |
| `file_write PATH [MODE] [OWNER]` | stdin → файл: сравнение содержимого, бэкап, запись `W`, атомарная замена; `FILE_CHANGED=1` при изменении; в dry-run — diff |
| `file_remove PATH` | бэкап, запись `D`, удаление |
| `file_snapshot PATH` | копия файла, который изменит внешняя команда (ufw, certbot) |
| `file_set_block PATH MARKER [MODE]` | заменить блок между маркерами внутри чужого файла; пустой stdin удаляет блок |
| `undo CMD...` | записать команду отката (`U`) — до изменения, которое она отменяет |
| `run CMD...` | выполнить с логированием; при ошибке — последние строки вывода на экран; в dry-run — только печать; дочерний процесс игнорирует `SIGHUP` |
| `tx_rollback_journal JOURNAL [MODULE]` | обратный проход записей: восстановление файлов, удаление созданных, выполнение команд отката; модуль загружается, чтобы команда отката могла быть его функцией |
| `pending_arm/disarm/confirm/rollback` | таймер отката и `pending.env` |
| `module_state_set/get` | `/var/lib/ubuntu-bootstrap/modules/<m>.env` |

## Выполнение и подтверждения (`lib/runner.sh`, `lib/ui.sh`)

- `guard_refuse MSG` — предохранитель: при `--force` предупреждение и продолжение, иначе ошибка и код 3.
- `confirm_danger MSG` — опасное действие: в терминале слово `yes`, `--yes` принимает, без терминала отказ; в dry-run — заметка.
- `confirm_or_rollback MODULE TIMEOUT MODE QUESTION SELFCHECK` — взвести таймер, дождаться ответа / выполнить самопроверку / вернуться (режим `wait`), затем `pending_confirm` или `pending_rollback` с кодом 4.
- `wait_confirmation` — обратный отсчёт; каждые 5 секунд проверяет, не снят ли `pending.env` извне (`confirm` из другой сессии или сработавший таймер).

Интерактивность определяется один раз: stdin — терминал, либо открывается `/dev/tty` (так мастер работает через `curl | bash`). Все вопросы через `ask_yn`, `ask_input` (с валидатором и повтором), `ask_choice`, `ask_secret` (без эха и лога). Без терминала каждый вопрос получает безопасный ответ по умолчанию и логируется.

## Состояние на диске

```
/etc/ubuntu-bootstrap/bootstrap.conf        конфигурация (600)
/etc/ubuntu-bootstrap/modules.d/*.sh        свои модули
/etc/ubuntu-bootstrap/profiles.d/*.conf     свои профили
/var/lib/ubuntu-bootstrap/.lock             блокировка flock
/var/lib/ubuntu-bootstrap/pending.env       ожидающее подтверждение (RUN_ID, MODULE, DEADLINE, MECH, TIMER, DESC)
/var/lib/ubuntu-bootstrap/runs/<RUN_ID>/run.env     STATUS, COMMAND, VERSION, STARTED_AT, DRY_RUN, USER, FINISHED_AT
/var/lib/ubuntu-bootstrap/runs/<RUN_ID>/journal     записи M/W/D/U
/var/lib/ubuntu-bootstrap/modules/<m>.env   STATUS, CONFIG_HASH, APPLIED_AT, RUN_ID, VERSION, CONFIRMED_AT, ROLLED_BACK_AT
/var/backups/ubuntu-bootstrap/<RUN_ID>/     копии файлов по абсолютным путям
/var/log/ubuntu-bootstrap/<RUN_ID>.log      лог запуска
/opt/ubuntu-bootstrap/.install              REPO, REF, COMMIT, INSTALLED_AT
```

Переменные окружения: `UBB_SYSROOT` (тесты: префикс всех путей состояния), `UBB_MODULE_PATH` (дополнительный каталог модулей), `UBB_OS_RELEASE` (тесты), `NO_COLOR`; для установщика — `UBB_REPO`, `UBB_REF`, `UBB_SIGNING_KEY_FPR`, `GITHUB_TOKEN`.

## Принятые решения и источники

| Решение | Обоснование |
|---|---|
| sshd настраивается файлом `sshd_config.d/00-…` | sshd применяет первое встреченное значение директивы; `Include` стоит в начале `sshd_config`, поэтому `00-` побеждает и cloud-init, и основной файл — `sshd_config(5)` |
| Смена порта через `daemon-reload` + `restart ssh.socket` | на Ubuntu 22.10+ sshd socket-активирован, порты читает генератор; `reload` порт не меняет — [LP#2069041](https://bugs.launchpad.net/ubuntu/+source/openssh/+bug/2069041). Сессии переживают перезапуск: `KillMode=process` |
| `sshd -T`, а не разбор файлов | учитывает все включённые файлы и `Match`-блоки; `without-password` нормализуется в `prohibit-password` |
| `PermitRootLogin no` только при администраторе с ключом и рабочим sudo | иначе сервер остаётся без административного доступа; `adduser --disabled-password` даёт пользователя с нерабочим sudo |
| Таймер отката вне сессии (`systemd-run`) и recover-сервис | обрыв сессии, зависший терминал и перезагрузка не должны оставлять сервер в неподтверждённом состоянии; у recover-юнита нет `Before=ssh.socket`, чтобы не создавать цикл задач systemd |
| Docker: deb822, ключ в `/etc/apt/keyrings`, проверка отпечатка, удаление конфликтующих пакетов | [docs.docker.com/engine/install/ubuntu](https://docs.docker.com/engine/install/ubuntu/) |
| Защита контейнеров в `DOCKER-USER` | «Docker and ufw are incompatible»; Docker пишет правила в FORWARD/nat мимо INPUT, `DOCKER-USER` проверяется первой и не очищается Docker — [Packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/). `iptables-restore` при `ufw reload` переустанавливает объявленную цепочку |
| nginx.org: отпечаток как вхождение, pinning 900 | файл ключей содержит несколько ключей; [nginx.org/en/linux_packages.html](https://nginx.org/en/linux_packages.html) |
| fail2ban `backend=systemd` с явным `journalmatch` | `auth.log` может отсутствовать на 24.04+; OpenSSH 9.8+ логирует от `sshd-session`; `python3-systemd` в 22.04 только Recommends |
| unattended-upgrades: security-pocket, без автоперезагрузки | [Ubuntu Server Guide: Automatic updates](https://ubuntu.com/server/docs/how-to/software/automatic-updates/) |
| Время: chrony на 26.04, timesyncd на старых | Ubuntu 26.04 ставит chrony с NTS; оба юнита имеют `ConditionVirtualization=!container` |
| sysctl по CIS Ubuntu Benchmark L1; `ip_forward` сохраняется при Docker/WireGuard | иначе Docker и VPN перестают маршрутизировать |
| nginx TLS по профилю Mozilla intermediate | [ssl-config.mozilla.org](https://ssl-config.mozilla.org/) |
| Ключи GitHub-пользователя и host keys GitHub по TLS | `github.com/<user>.keys`, `api.github.com/meta` — GitHub docs «SSH key fingerprints» |
| `ufw`-файлы только ASCII | ufw перезаписывает свои файлы в ASCII и падает на не-ASCII комментариях |
| Файлы `KEY=VALUE` никогда не исполняются | конфиг с правами 600 всё равно не должен быть вектором выполнения кода |
