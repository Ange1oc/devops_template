# Установка

## Требования

| Что | Требование |
|---|---|
| ОС | Ubuntu 22.04, 24.04 или 26.04 LTS (другие версии останавливаются предохранителем, `--force` снимает только эту проверку) |
| Архитектура | amd64 или arm64 (другие дают предупреждение) |
| Права | root (`sudo`); без root работают только `help`, `version`, `modules`, `profiles`, `doctor` |
| Утилиты | bash 4.4+, `curl` или `wget`, `systemd` (без него недоступны сервисы и таймеры отката) |
| Сеть | HTTPS до `github.com` и `archive.ubuntu.com`; для Docker и nginx.org — до их репозиториев |

Контейнеры (Docker, LXC) поддерживаются частично: swap, sysctl ядра и NTP-демон принадлежат хосту и пропускаются, snap недоступен.

## Способы установки

### Одной командой

```bash
curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/bootstrap/install.sh | sudo bash
```

То же через `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/bootstrap/install.sh | sudo bash
```

Установить и сразу запустить мастер:

```bash
curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/bootstrap/install.sh | sudo bash -s -- --run
```

Аргументы после `-s --` передаются установщику.

### С проверкой целостности

| Вариант | Команда | Что проверяется |
|---|---|---|
| Релиз | `... \| sudo bash -s -- --ref ubuntu-bootstrap-v1.0.0` | SHA256 архива сверяется с файлом `SHA256SUMS` релиза. Если задан `UBB_SIGNING_KEY_FPR` или `--require-signature`, дополнительно проверяется GPG-подпись `SHA256SUMS.asc` |
| Commit | `... \| sudo bash -s -- --ref <sha>` | содержимое закреплено хэшем коммита, его нельзя подменить без смены ссылки |
| Любая ссылка | `... \| sudo bash -s -- --ref main --sha256 <hash>` | SHA256 скачанного архива должен совпасть с указанным |
| Локально | `sudo ./ubuntu/bootstrap/install.sh --local` | ничего не скачивается, ставится из текущего клона |

Проверка подписи релиза:

```bash
export UBB_SIGNING_KEY_FPR=<отпечаток ключа сопровождающего>
curl -fsSL .../install.sh | sudo -E bash -s -- --ref ubuntu-bootstrap-v1.0.0 --require-signature
```

Ключ получается с `keys.openpgp.org` во временный GnuPG-каталог; подпись должна быть именно этим ключом (`VALIDSIG`). Без заданного отпечатка подпись не проверяется, доверие строится на TLS и `SHA256SUMS`, как у `get.docker.com`.

### Приватный репозиторий или форк

```bash
sudo GITHUB_TOKEN=ghp_... bash install.sh --repo owner/repo --ref main
```

С токеном архив скачивается через GitHub API (`api.github.com/repos/<repo>/tarball/<ref>`), без токена — через `github.com/<repo>/archive/<ref>.tar.gz`, который не упирается в лимит API. Переменные `UBB_REPO` и `UBB_REF` задают умолчания для `--repo` и `--ref`; они же записываются в метаданные установки и используются `self-update`.

## Что делает установщик

1. Проверяет, что запущен от root и bash не старше 4.4; валидирует `--repo` и `--ref` (без `..`, только безопасные символы).
2. Скачивает архив только по HTTPS с TLS 1.2+, с повторами; редиректы на `http://` запрещены (`curl --proto '=https'`, `wget --https-only`).
3. Для релизного тега проверяет `SHA256SUMS` и, если задан отпечаток, подпись. Для `--sha256` сверяет хэш архива.
4. Распаковывает только папку `ubuntu/bootstrap` с `--no-same-owner --no-same-permissions`; проверяет, что внутри есть `ubuntu-bootstrap`, `lib/`, `modules/`, `commands/`.
5. Отказывается ставить дерево с символическими ссылками (кроме каталога `tests/`, который не устанавливается).
6. Копирует в `/opt/ubuntu-bootstrap.new`, выставляет `root:root`, каталоги 755, файлы 644, исполняемые 755.
7. Прогоняет `bash -n` по каждому файлу `.sh`, `.bash` и точке входа; запускает `ubuntu-bootstrap version` из staging-каталога.
8. Записывает `.install` (REPO, REF, COMMIT, INSTALLED_AT).
9. Атомарно подменяет каталог: прежняя версия становится `/opt/ubuntu-bootstrap.old`.
10. Создаёт ссылку `/usr/local/bin/ubuntu-bootstrap`, подключает bash-автодополнение, устанавливает и включает `ubuntu-bootstrap-recover.service` (откат неподтверждённых изменений после перезагрузки).

Всё тело установщика находится внутри функции `main`, которая вызывается последней строкой: оборванная на середине загрузка через `curl | bash` не выполнит ничего.

Чтобы прочитать установщик перед запуском:

```bash
curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/bootstrap/install.sh -o install.sh
less install.sh
sudo bash install.sh
```

## Что появляется на диске

| Путь | Назначение |
|---|---|
| `/opt/ubuntu-bootstrap/` | программа (точка входа, `lib/`, `commands/`, `modules/`, `profiles/`, `completion/`, `systemd/`, `install.sh`, `VERSION`, `.install`) |
| `/opt/ubuntu-bootstrap.old/` | предыдущая версия, появляется после обновления |
| `/usr/local/bin/ubuntu-bootstrap` | символическая ссылка на точку входа |
| `/etc/bash_completion.d/ubuntu-bootstrap` | автодополнение команд, модулей, профилей и опций |
| `/etc/systemd/system/ubuntu-bootstrap-recover.service` | откат при загрузке, если остался `pending.env` |

Каталоги состояния (`/etc/ubuntu-bootstrap`, `/var/lib/ubuntu-bootstrap`, `/var/backups/ubuntu-bootstrap`, `/var/log/ubuntu-bootstrap`) создаются при первом запуске команды, которая что-то меняет, с правами 700.

## Проверка после установки

```bash
ubuntu-bootstrap version      # версия, источник и время установки
ubuntu-bootstrap doctor       # окружение, целостность установки, состояние запусков
```

`doctor` возвращает 0, когда всё в порядке, 1 при предупреждениях, 2 при ошибках. Он проверяет, что `/opt/ubuntu-bootstrap` принадлежит root и не доступен на запись остальным: таймер отката и recover-сервис выполняют код оттуда от root.

## Обновление

```bash
sudo ubuntu-bootstrap self-update --check   # сравнить установленную версию с VERSION в репозитории
sudo ubuntu-bootstrap self-update           # обновить с того же repo/ref, что при установке
sudo ubuntu-bootstrap self-update --ref ubuntu-bootstrap-v1.1.0
```

`self-update` запускает `install.sh` с сохранёнными `REPO` и `REF`. Обновляется только программа: конфигурация, состояние модулей, журналы и бэкапы не трогаются. Если инструмент установлен не через `install.sh` (нет файла `.install`), `self-update` откажется и предложит установить его штатно.

## Откат обновления

```bash
sudo /opt/ubuntu-bootstrap/install.sh --rollback
```

Текущая версия и `.old` меняются местами, ссылки и recover-сервис переустанавливаются. Повторный `--rollback` возвращает всё обратно.

## Удаление

```bash
sudo /opt/ubuntu-bootstrap/install.sh --uninstall           # программа, ссылка, автодополнение, recover-сервис
sudo /opt/ubuntu-bootstrap/install.sh --uninstall --purge   # плюс конфигурация, состояние, логи и бэкапы
```

Удаление инструмента не затрагивает настроенные сервисы: sshd, UFW, fail2ban, unattended-upgrades, Docker и nginx продолжают работать со своими конфигами. Без `--purge` остаются `/etc/ubuntu-bootstrap`, `/var/lib/ubuntu-bootstrap`, `/var/backups/ubuntu-bootstrap`, `/var/log/ubuntu-bootstrap`, поэтому повторная установка увидит прежнюю конфигурацию и историю.

Если на момент удаления есть изменения, ожидающие подтверждения, сначала подтверди или откати их (`confirm` / `rollback --pending`): после удаления таймер отката уже не сработает.

## Параметры установщика

| Параметр | Назначение |
|---|---|
| `--ref REF` | ветка, тег или commit (по умолчанию `main` или `UBB_REF`) |
| `--repo OWNER/REPO` | репозиторий GitHub (по умолчанию `Ange1oc/devops_template` или `UBB_REPO`) |
| `--sha256 HASH` | ожидаемый SHA256 скачанного архива |
| `--require-signature` | требовать подпись `SHA256SUMS.asc` (нужен `UBB_SIGNING_KEY_FPR`) |
| `--run` | после установки запустить `ubuntu-bootstrap wizard` |
| `--local [DIR]` | ставить из локальной копии (по умолчанию из каталога, где лежит `install.sh`) |
| `--rollback` | вернуть предыдущую версию |
| `--uninstall [--purge]` | удалить программу (с `--purge` — и все данные) |
| `-h`, `--help` | справка |

Переменные окружения: `UBB_REPO`, `UBB_REF`, `UBB_SIGNING_KEY_FPR`, `GITHUB_TOKEN`.
