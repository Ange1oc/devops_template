# Разработка

Как устроен код, как добавить команду и как проект тестируется.

- [Структура](#структура)
- [Соглашения](#соглашения)
- [Новая команда](#новая-команда)
- [Тесты](#тесты)
- [Покрытие](#покрытие)
- [CI](#ci)
- [Выпуск версии](#выпуск-версии)

## Структура

```
ubuntu/wg/
├── wg-network            точка входа: глобальные опции, поиск команды, песочница dry-run
├── install.sh            установка, обновление, откат, удаление
├── VERSION
├── lib/
│   ├── core.sh           вывод, коды выхода, подтверждения, атомарная запись, файлы KEY=VALUE
│   ├── validate.sh       предикаты is_* для всех видов входных данных
│   ├── ip.sh             IPv4/IPv6-арифметика: CIDR, вхождение, пересечение, RFC 5952
│   ├── config.sh         пути, настройки, выбор интерфейса
│   ├── state.sh          желаемое состояние, валидация, блокировка, снимки, транзакции
│   ├── render.sh         генерация конфига и хуков firewall, каноническая форма конфига
│   ├── apply.sh          план, способы применения, подтверждение, откат
│   ├── guard.sh          предохранители SSH, чужих VPN и сетей
│   ├── system.sh         пакеты, systemd, маршруты, firewall, SSH-сессии, быстрое переподключение
│   ├── node.sh           токены приглашений, клиентские конфиги, инициализация узла-peer
│   ├── runtime.sh        данные ядра (wg show dump), состояния peer, тексты итогов
│   └── migrate.sh        миграция прежних версий
├── commands/             одна команда — один файл ("peer add" -> peer-add.sh)
├── systemd/              wg-network-reresolve.{service,timer}
├── completion/           автодополнение bash
├── docs/                 эта документация (en, ru)
└── tests/
    ├── run.sh            lint | unit | e2e | systemd | distro | coverage | all
    ├── lib.sh            маленькая библиотека проверок
    ├── unit.sh           чистая логика
    ├── e2e.sh            настоящий WireGuard в network namespace
    ├── systemd.sh        настоящий systemd и OpenSSH в контейнерах
    ├── stubs/            systemctl, systemd-run, logger, timedatectl для e2e
    ├── stubs-fw/         ufw, firewall-cmd для e2e
    ├── docker/           образ узла с systemd в роли PID 1
    └── coverage/         трассировщик через BASH_ENV и report.py
```

## Соглашения

- Bash 4.4+, `set -Eeuo pipefail`, `umask 077`, сортировка независимо от локали (`LC_COLLATE=C`).
- Все библиотеки подключает точка входа; команды сами ничего не подключают.
- Сообщения — в stderr через `log_info`, `log_ok`, `log_warn`, `log_error`; stdout — только для данных.
- Ошибки завершаются через `die` (код 1), `die_usage` (код 2) или `die_code КОД`. Коды выхода — публичный контракт: см. `lib/core.sh` и [Коды выхода](commands.md#коды-выхода).
- Файлы состояния читаются через `kv_load`/`kv_get` и пишутся через `kv_save`/`write_atomic`. Никогда не делай `source` файла состояния или настроек.
- Любое внешнее значение проверяется предикатом из `lib/validate.sh` или `lib/ip.sh` до того, как попадёт в файл.
- Функции, возвращающие значение через nameref, используют локальные переменные с уникальным префиксом (`_x6_res`): область видимости в bash динамическая.
- Не пиши `cmd | grep -q` под `pipefail` (SIGPIPE даёт случайные ложные ошибки); используй `output_has PATTERN cmd...`.
- Временные каталоги: `make_tmp_dir VAR [PARENT]`, они удаляются при выходе.
- Секреты в файлах: `write_secret_file` (права 600, отказ на существующем файле и симлинке).
- Комментарии — на английском и объясняют *почему*, а не *что*. Сообщения для пользователя — на русском.
- ShellCheck должен проходить; немногие отключённые проверки перечислены с причинами в `.shellcheckrc`.

## Новая команда

Создай `commands/<имя>.sh` (из двух слов: `commands/<группа>-<имя>.sh`, вызов `wg-network <группа> <имя>`). Регистрировать ничего не нужно: `help`, диспетчер и автодополнение найдут её сами.

```bash
# shellcheck shell=bash

CMD_SUMMARY='описание в одну строку для help'
CMD_GROUP=peers          # setup | peers | apply | diag | maintenance
CMD_MUTATES=1            # меняет состояние: с --dry-run работает в песочнице

cmd_usage() {
    cat <<'EOF'
Использование: wg-network [-i IFACE] example NAME [--flag]
EOF
}

cmd_run() {
    local name=''
    while (($#)); do
        case $1 in
            -*) die_unknown_arg "$1" ;;
            *) name=$1; shift ;;
        esac
    done
    is_name "$name" || die_usage "некорректное имя: $name"
    require_managed
    st_node_load

    tx_begin example            # блокировка, восстановление, отказ при ожидающем подтверждении, снимок
    # ... изменение желаемого состояния (st_peer_save, st_node_save) ...
    apply_changes               # план, предохранители, разрешение, применение, подтверждение
    tx_commit
    log_ok "готово: $(outcome_text)"
}
```

Метаданные:

| Переменная | По умолчанию | Значение |
|---|---|---|
| `CMD_SUMMARY` | пусто | текст в `wg-network help` |
| `CMD_GROUP` | `other` | раздел справки |
| `CMD_ROOT` | 1 | нужен root |
| `CMD_IFACE` | 1 | до `cmd_run` выбирается интерфейс (`-i` или по умолчанию) |
| `CMD_MUTATES` | 0 | меняет состояние; с `--dry-run` работает на копии в песочнице |
| `CMD_READONLY` | 0 | только читает; с `--dry-run` работает как обычно |
| `CMD_MIGRATE` | 1 | сначала выполнить миграцию прежней версии |

Команда, у которой нет ни `CMD_MUTATES`, ни `CMD_READONLY`, отказывается работать с `--dry-run`. Шаблон `tx_begin` → изменение → `apply_changes` → `tx_commit` даёт новой команде снимки, восстановление после сбоя, план, предохранители, подтверждение, откат и dry-run без дополнительного кода.

## Тесты

```bash
tests/run.sh             # lint + unit + e2e
tests/run.sh lint        # ShellCheck всех скриптов, включая тесты
tests/run.sh unit        # чистая логика, без root
tests/run.sh e2e         # настоящий WireGuard в namespace
tests/run.sh systemd     # настоящий systemd + OpenSSH в docker
tests/run.sh distro      # e2e внутри контейнеров Ubuntu 22.04 и 26.04
tests/run.sh coverage    # unit + e2e (+ systemd + distro при COVERAGE_FULL=1) и отчёт
```

| Уровень | Что проверяет |
|---|---|
| lint | ShellCheck программы, установщика, автодополнения, тестов и заглушек |
| unit | IPv4/IPv6-арифметика, нормализация CIDR, валидация, включая попытки инъекций, токены, генерация конфига, каноническое сравнение, атомарная запись, защита от симлинков |
| e2e | 17 узлов в отдельных network namespace на **модуле ядра WireGuard** с настоящими `wg`/`wg-quick`; заглушки только для systemd, logger и фронтендов firewall |
| systemd | **настоящий systemd (PID 1) и OpenSSH** в контейнерах: `wg-quick@`, transient-таймер отката, откат после **настоящего перезапуска контейнера**, захардненный сервис `reresolve`, journald, `deploy` по SSH, install/uninstall с юнитами |
| distro | весь набор e2e внутри Ubuntu 22.04 и 26.04 (свои bash, iproute2, wireguard-tools) |

Сценарии e2e, среди прочего:

- hub и peer, peer↔peer через hub, IPv4/IPv6 dual-stack;
- site-to-site с хостом в LAN офиса, exit node с NAT (проверяется адрес, который видит внешний веб-сервер), full tunnel;
- DNS-endpoint и повторный резолв после «смены IP» hub;
- обрыв линка, 30% потерь пакетов (netem), роуминг peer;
- предохранитель SSH на настоящих TCP-сессиях, включая асимметричную;
- инъекция отказов в `syncconf` и `wg-quick up`, честный отчёт о неудачном откате;
- таймаут подтверждения, подтверждение из другой сессии, «перезагрузка» до подтверждения, обрыв SSH во время ожидания, интерактивный режим через pty;
- ручные правки, расхождение ядра и конфига, ротация preshared key;
- параллельные команды и блокировки, восстановление после `kill -9`, переиспользованный PID;
- нет места на диске и файловая система только для чтения;
- 250 peer;
- миграция прежних версий (успешная и неудачная), backup → destroy → restore;
- `--dry-run` с проверкой по отпечатку файлов, ядра, маршрутов и firewall для каждой изменяющей команды;
- больше 90 недопустимых командных строк (код выхода и отсутствие побочных эффектов);
- отсутствие оставшихся временных файлов.

Система хоста не меняется: e2e работает в user, mount и network namespace с overlay поверх `/etc`, `/opt`, `/usr/local/bin` и `/var/backups`; у контейнеров собственные namespace.

Требования:

- e2e: `wg` и `wg-quick` (`wireguard-tools` или каталог с ними в `WGTOOLS_DIR`), модуль `wireguard` и непривилегированные user namespace или `sudo` (Ubuntu 24.04 ограничивает user namespace через AppArmor: используй `sudo tests/run.sh e2e`);
- systemd и distro: docker.

Полезные переменные: `WGN_E2E_KEEP=1` сохраняет рабочий каталог, `WGN_SYSTEMD_BASES="ubuntu:22.04 ubuntu:24.04"` и `WGN_E2E_BASES` выбирают образы.

Наборы запускаются из копии исходников: bash читает скрипт по частям, и правка файла во время прогона сломала бы его.

## Покрытие

Покрытие измеряется, а не оценивается. `BASH_ENV` включает xtrace в отдельный файл в каждом bash-процессе тестов, включая процессы, которые запускает сам systemd в контейнерах; код при этом не меняется. `tests/coverage/report.py` считает по каждому файлу три метрики:

- **statements** — исполнимые операторы (многострочная команда считается один раз);
- **branches** — тела `if`/`elif`/`else` и каждая метка `case`;
- **guards** — проверки ошибок (`|| die`, `|| return`, `&& die`), которые реально сработали, то есть сколько негативных путей выполнялось.

```bash
tests/run.sh coverage --min-statements 88 --min-guards 55               # unit + e2e
sudo -E env COVERAGE_FULL=1 tests/run.sh coverage --uncovered           # всё, со списком непокрытых строк
```

JSON-отчёт пишется в `tests/coverage/last.json` (игнорируется git). Трассировки содержат тестовые ключи и удаляются, если не задано `WGN_COV_KEEP=1`.

## CI

`.github/workflows/wg-network.yml` запускается при изменениях в `ubuntu/wg/`:

1. lint и unit;
2. e2e от root на раннере (одноразовая ВМ);
3. набор systemd на Ubuntu 22.04 и 24.04;
4. покрытие с порогами и артефактом `last.json`.

## Выпуск версии

1. Обнови `VERSION`.
2. Запусти `tests/run.sh all`, `tests/run.sh systemd` и `tests/run.sh distro`.
3. Поставь тег на commit; пользователи фиксируют версию через `install.sh --ref <тег>` или `self-update --ref <тег>`.
