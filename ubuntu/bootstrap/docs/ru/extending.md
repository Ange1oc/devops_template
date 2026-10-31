# Расширение

## Свой модуль

Файл `/etc/ubuntu-bootstrap/modules.d/<имя>.sh` (на боевом сервере) или `modules/<имя>.sh` (в репозитории). Имя: строчные буквы, цифры и дефис, до 32 символов. Регистрировать не нужно — файл подхватывается при следующем запуске. Дополнительный каталог модулей можно указать переменной `UBB_MODULE_PATH`.

```bash
# shellcheck shell=bash
MOD_SUMMARY='node_exporter для Prometheus'
MOD_GROUP=services
MOD_DEPS=(base)            # hard dependencies, enabled automatically
MOD_AFTER=(firewall)       # ordering relative to other enabled modules

mod_options() {
    opt NODE_EXPORTER_PORT port 9100 'Порт node_exporter'
    opt NODE_EXPORTER_FROM cidrs '' 'Откуда разрешён доступ (пусто — отовсюду)' adv
}

mod_check() {
    svc_active prometheus-node-exporter && port_listening "$(cfg NODE_EXPORTER_PORT)"
}

mod_apply() {
    apt_install prometheus-node-exporter || return 1
    undo systemctl restart prometheus-node-exporter
    printf 'ARGS="--web.listen-address=:%s"\n' "$(cfg NODE_EXPORTER_PORT)" | file_write /etc/default/prometheus-node-exporter 644
    [[ $FILE_CHANGED == 1 ]] && { run systemctl restart prometheus-node-exporter || return 1; }
    svc_enable_now prometheus-node-exporter
}

mod_verify() { mod_check; }

mod_audit() {
    port_listening "$(cfg NODE_EXPORTER_PORT)" && check_ok 'node_exporter слушает' || check_warn 'node_exporter не слушает'
}
```

Проверка: `ubuntu-bootstrap modules node-exporter`, `ubuntu-bootstrap plan --only node-exporter`, `ubuntu-bootstrap apply --only node-exporter`.

## Контракт модуля

| Элемент | Назначение |
|---|---|
| `MOD_SUMMARY` | одна строка: что делает модуль (показывается в `modules`, мастере, сводке) |
| `MOD_GROUP` | `security`, `system`, `services`, `access` или своя группа |
| `MOD_DEPS=(…)` | жёсткие зависимости: включаются автоматически и выполняются раньше |
| `MOD_AFTER=(…)` | мягкий порядок: после перечисленных модулей, если они тоже включены |
| `MOD_DEFAULT=1` | входит в набор по умолчанию (когда профиль не задан) |
| `MOD_ALWAYS=1` | выполняется при каждом `apply`, даже если уже применён (как preflight) |
| `MOD_CONTAINER=0` | пропускается внутри контейнера |
| `mod_options` | объявление опций через `opt` |
| `mod_check` | 0 — желаемое состояние достигнуто. Используется `status` и для пропуска модуля при `apply`; не должен менять систему и ходить в сеть |
| `mod_apply` | идемпотентное применение; все изменения через `file_write`, `file_set_block`, `file_remove`, `run`, с командами отката через `undo` |
| `mod_verify` | проверка после применения; провал откатывает модуль. По умолчанию возвращает 0 |
| `mod_audit` | проверки для `audit` через `check_ok/warn/fail/info` |
| `mod_wizard` | подсказки перед вопросами мастера и умолчания через `wiz_default` (необязательно) |
| `mod_confirmed` | выполняется командой `confirm` после подтверждения рискованного изменения этого модуля (необязательно) |

Порядок модулей: сначала рёбра `MOD_DEPS` и `MOD_AFTER`, при равенстве — канонический порядок встроенных модулей, затем свои модули по алфавиту.

### Коды возврата `mod_apply`

| Код | Смысл | Что делает runner |
|---|---|---|
| 0 | применено | `mod_verify`, состояние `applied` |
| 3 (`$E_REFUSED`) | остановлено предохранителем или отказано в подтверждении | откат записей модуля, состояние `refused`, остановка запуска |
| 4 (`$E_ROLLED_BACK`) | модуль уже откатил себя (таймер/отказ в `confirm_or_rollback`) | состояние уже `rolled_back`, остановка |
| иначе | ошибка | откат записей модуля, состояние `failed`, остановка |

`--keep-going` заменяет остановку переходом к следующему модулю.

### Правила хорошего модуля

- Все предохранители (`guard_refuse`) и подтверждения (`confirm_danger`) — в начале `mod_apply`, до первого изменения.
- Каждое изменение, которое не делает `file_write`, сопровождается `undo` **до** него: `undo systemctl restart X` перед записью конфига X, `undo userdel -r u` перед `useradd`.
- Внешние команды только через `run`: это даёт лог, dry-run и защиту от SIGHUP.
- Dry-run: `file_write`, `run`, `undo`, `file_remove`, `file_set_block`, `confirm_danger`, `confirm_or_rollback` сами учитывают `DRY_RUN`; прямые вызовы (`chown`, `install -d`) оборачивай в `((DRY_RUN)) ||`.
- `mod_check` должен быть быстрым и чистым: читать файлы и состояние сервисов, не ходить в сеть.
- Содержимое файлов генерируй функцией `*_render`, чтобы `mod_check` сравнивал файл с ожидаемым (`[[ $(cat "$f") == "$(x_render)" ]]`), а unit-тесты проверяли рендер.
- Файлы, которые меняют внешние инструменты, снимай `file_snapshot` перед вызовом.
- Комментарии в файлах, которые читает `ufw`, только ASCII.

## API хелперов

### Опции и конфигурация

| Функция | Назначение |
|---|---|
| `opt NAME TYPE DEFAULT HELP [adv]` | объявить опцию (только в `mod_options`); типы: `bool int port portkeep string list enum:a,b user users path size email duration timezone hostname hostnames keys ports cidrs` |
| `cfg NAME` | действующее значение |
| `cfg_bool NAME` | 0, если значение истинно |
| `cfg_list NAME ARRAY` | список в массив (разделители: запятая, точка с запятой, пробел) |
| `wiz_default NAME VALUE` | умолчание для мастера, если опция ещё не задана (в `mod_wizard`) |
| `module_enabled NAME` | модуль входит в текущий набор |
| `module_applied NAME` | модуль в состоянии `applied` |

### Файлы и команды

| Функция | Назначение |
|---|---|
| `file_write PATH [MODE] [OWNER]` | stdin → файл атомарно с бэкапом и журналом; `FILE_CHANGED` = 1/0 |
| `file_set_block PATH MARKER [MODE]` | блок `# BEGIN MARKER … # END MARKER` внутри чужого файла; пустой stdin удаляет |
| `file_remove PATH` | удалить с бэкапом |
| `file_snapshot PATH` | бэкап файла перед внешней командой |
| `file_fix_perms PATH MODE [OWNER]` | только права и владелец |
| `run CMD...` | выполнить с логом (dry-run печатает) |
| `undo CMD...` | команда отката; может быть функцией модуля |
| `write_atomic PATH [MODE] [OWNER]` | низкоуровневая атомарная запись без журнала (для файлов вне транзакции) |
| `make_tmp_dir` | временный каталог, удаляется при выходе |

### Пакеты и сервисы

| Функция | Назначение |
|---|---|
| `apt_install PKG...` | только отсутствующие, `--no-install-recommends`, `pkg=version` для пина |
| `apt_remove PKG...` | удалить установленные |
| `apt_upgrade [--autoremove]` | `update` + `upgrade` |
| `apt_update [--force]` | один раз за запуск |
| `apt_repo_add NAME URL SUITE COMPONENTS KEY_URL FPR` | deb822-источник с проверкой отпечатка ключа |
| `apt_wait [SECONDS]` | дождаться освобождения dpkg |
| `pkg_installed PKG` | установлен ли |
| `fetch_url URL DEST` | скачать по HTTPS с повторами |
| `snap_usable`, `snap_install NAME [ARGS]` | snap |
| `svc_exists/active/enabled UNIT` | состояние юнита |
| `svc_enable_now UNIT` | `enable --now`, если ещё не |
| `svc_dropin UNIT NAME` | drop-in из stdin с `daemon-reload` при изменении |
| `svc_daemon_reload` | `systemctl daemon-reload` через `run` |
| `sshd_apply OLD_PORTS` | проверить и применить конфиг sshd с учётом socket-активации |

### Факты и пользователи

`F_OS_ID`, `F_OS_VERSION`, `F_OS_CODENAME`, `F_PRETTY`, `F_ARCH`, `F_KERNEL`, `F_HAS_SYSTEMD`, `F_VIRT`, `F_CONTAINER`, `F_MEM_MB`, `F_SWAP_MB`, `F_CPUS`, `F_DISK_FREE_GB`, `F_ROOT_FS`, `F_DEFAULT_IFACE`, `F_PRIMARY_IP`, `F_HOSTNAME`, `F_REBOOT_REQUIRED`, `F_SSH_CLIENT_IP`, `F_SSH_SERVER_PORT`, `F_SSH_USER`, `F_SSHD_PORTS`.

| Функция | Назначение |
|---|---|
| `sshd_effective KEY`, `sshd_effective_ports` | значения из `sshd -T` |
| `port_listening PORT [udp]` | кто-то слушает порт |
| `user_exists U`, `user_home U`, `user_has_keys U`, `user_in_group U G`, `user_sudo_usable U`, `user_password_state U`, `human_users` | пользователи (учитывают планируемые факты в dry-run) |
| `plan_mark user:U` / `keys:U` / `sudo:U` | отметить планируемый факт в dry-run |
| `ufw_active`, `sshd_socket_activated`, `public_ip` | окружение |

### Предохранители, подтверждения, диалог

| Функция | Назначение |
|---|---|
| `guard_refuse MSG` | предохранитель; возвращает 3 (или 0 с предупреждением при `--force`). Идиома: `guard_refuse '…' \|\| return` |
| `confirm_danger MSG` | опасное действие; 1 при отказе. Идиома: `confirm_danger '…' \|\| return "$E_REFUSED"` |
| `confirm_or_rollback MODULE TIMEOUT MODE QUESTION SELFCHECK_FN` | таймер отката и подтверждение; возвращает 0, 3 или 4 |
| `ask_yn Q [y\|n]`, `ask_input VAR PROMPT DEFAULT [VALIDATOR]`, `ask_choice VAR TITLE DEFAULT ITEM...`, `ask_secret VAR PROMPT` | вопросы (без терминала — умолчания) |
| `interactive` | есть терминал |
| `log_info/ok/warn/error/title/plain/debug` | вывод; `log_warn` попадает в итоговую сводку |
| `die MSG`, `die_code CODE MSG`, `die_usage MSG` | завершение |

### Аудит

`check_ok DESC [HINT]`, `check_warn DESC [HINT]`, `check_fail DESC [HINT]`, `check_info DESC [HINT]`. Модуль проверки подставляется автоматически.

### Валидация

`is_uint is_port is_bool is_username is_abs_path is_size is_email is_duration is_timezone is_ipv4 is_ipv6 is_ip is_cidr is_ip_or_cidr is_hostname is_port_spec is_ssh_pubkey is_name is_opt_name is_git_ref is_github_repo to_bool`, а также `in_list X LIST...`, `split_list STR ARRAY`, `join_by SEP ITEMS...`, `json_str STR`, `size_to_mb SIZE`, `sha256_str STR`.

## Свой профиль

Файл `/etc/ubuntu-bootstrap/profiles.d/<имя>.conf`:

```
# Backend-сервер: минимум + docker, без swap
MODULES=preflight,base,time,users,ssh,firewall,fail2ban,updates,journald,sysctl,limits,docker
FW_DOCKER_PROTECT=yes
SSH_PORT=2222
UPD_ORIGINS=all
```

Первая строка-комментарий — описание в `profiles` и мастере. Профиль задаёт умолчания; файл конфигурации и `--set` их переопределяют. Пользовательский профиль с именем встроенного имеет приоритет.

## Своя команда

Файл `commands/<имя>.sh`:

```bash
# shellcheck shell=bash
CMD_SUMMARY='что делает'
CMD_GROUP=inspect        # setup | run | inspect | maintenance
CMD_ROOT=0               # 1 (по умолчанию) — требовать root

cmd_usage() { echo 'Использование: ubuntu-bootstrap <имя> [аргументы]'; }

cmd_run() {
    config_load          # если нужны опции
    runner_select        # если нужен набор модулей (SELECTED_MODULES)
    ...
}
```

Команда получает все глобальные опции уже разобранными (`OPT_*`, `DRY_RUN`, `SET_OVERRIDES`) и загруженный реестр модулей (`MOD_ALL`, `MOD_*_OF`).

## Тестирование своего модуля

- Рендер и логику — в `tests/unit.sh` в песочнице (`UBB_SYSROOT`): загрузить модуль через `module_load`, задать `CONF[...]`, проверить `*_render`.
- Поведение — сценарием в `tests/e2e.sh`: контейнер с systemd, `install_tool`, `ubb "$box" apply --only <имя> --yes`, проверки через `boxq`. Сценарии `scn_failures` и `scn_interrupt` показывают, как подкладывать тестовые модули в `/etc/ubuntu-bootstrap/modules.d/`.
- `tests/run.sh lint` прогоняет shellcheck по `modules/*.sh`.
