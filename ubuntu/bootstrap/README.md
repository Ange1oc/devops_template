# ubuntu-bootstrap

[English version](README.en.md)

Модульная подготовка чистого сервера Ubuntu к production одной командой: административный пользователь и SSH-ключи, SSH hardening, UFW, fail2ban, автообновления безопасности, sysctl и лимиты, swap, journald, Docker CE, nginx, certbot, deploy-ключи Git. Поддерживаются Ubuntu 22.04, 24.04 и 26.04 LTS на amd64 и arm64.

Главный принцип: **ни одно действие не должно оставить сервер без доступа и не должно сломать то, что уже настроено.** Предохранители проверяют, что после изменения останется администратор с ключом и рабочим sudo. Рискованные шаги (SSH, firewall) ставятся на таймер отката и требуют подтверждения из новой сессии. Каждый модуль идемпотентен, его изменения журналируются, бэкапятся и откатываются при ошибке.

## Быстрый старт

Установить и сразу запустить интерактивный мастер:

```bash
curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/bootstrap/install.sh | sudo bash -s -- --run
```

Без мастера, одной командой (cloud-init, Ansible, CI):

```bash
sudo ubuntu-bootstrap apply --profile web \
    --set ADMIN_USER=deploy \
    --set 'ADMIN_SSH_KEYS=ssh-ed25519 AAAA... admin@laptop' \
    --set ADMIN_SUDO_MODE=nopasswd \
    --set CERTBOT_DOMAINS=example.com --set CERTBOT_EMAIL=ops@example.com \
    --yes
```

Через файл конфигурации:

```bash
sudo ubuntu-bootstrap config init --profile docker
sudo ubuntu-bootstrap config set ADMIN_USER=deploy ADMIN_SSH_KEYS_GITHUB=mylogin DOCKER_USERS=deploy
sudo ubuntu-bootstrap plan      # показать, что изменится, ничего не меняя
sudo ubuntu-bootstrap apply
```

После смены SSH-порта или включения firewall инструмент ждёт подтверждения: зайди на сервер **новой** сессией и выполни `sudo ubuntu-bootstrap confirm`. Без подтверждения конфигурация откатится сама через 180 секунд.

## Что настраивается

| Профиль | Модули |
|---|---|
| `minimal` | preflight, base, time, users, ssh, firewall, fail2ban, updates, journald |
| `web` | minimal + sysctl, limits, swap, nginx (nginx.org stable), certbot; порты 80/443 открыты |
| `docker` | minimal + sysctl, limits, swap, docker; контейнеры защищены от обхода UFW |
| `full` | web + docker + git + wg-network |

Любой модуль включается и выключается отдельно (`--only`, `--skip`, `MODULES=` в конфиге); зависимости подтягиваются автоматически. Полный список опций: `ubuntu-bootstrap modules --options`.

## Документация

| Документ | Содержание |
|---|---|
| [Установка](docs/ru/install.md) | способы установки, проверка целостности, обновление, откат, удаление |
| [Использование](docs/ru/usage.md) | команды, глобальные опции, коды выхода, конфигурация, профили, сценарии автоматизации |
| [Модули](docs/ru/modules.md) | каждый модуль подробно: что делает, все опции, файлы, предохранители, проверки |
| [Безопасность](docs/ru/safety.md) | предохранители, подтверждение и таймер отката, транзакции, что никогда не трогается |
| [Архитектура](docs/ru/architecture.md) | структура кода, поток выполнения, состояние на диске, принятые решения и их источники |
| [Расширение](docs/ru/extending.md) | свои модули и профили, API хелперов, контракт модуля |
| [Тестирование](docs/ru/testing.md) | lint, unit, e2e в контейнерах, покрытие, CI |
| [Диагностика](docs/ru/troubleshooting.md) | что делать при потере доступа, типичные ошибки, где логи |
| [Аудит](docs/ru/audit.md) | найденные и исправленные проблемы, остающиеся риски |

## Где что лежит

```
/opt/ubuntu-bootstrap/                 программа; .old — предыдущая версия для отката
/usr/local/bin/ubuntu-bootstrap        ссылка на исполняемый файл
/etc/ubuntu-bootstrap/bootstrap.conf   конфигурация (KEY=VALUE, права 600)
/etc/ubuntu-bootstrap/modules.d/       свои модули
/etc/ubuntu-bootstrap/profiles.d/      свои профили
/var/lib/ubuntu-bootstrap/             состояние модулей, журналы запусков, pending.env
/var/backups/ubuntu-bootstrap/<run>/   копии изменённых файлов
/var/log/ubuntu-bootstrap/<run>.log    полный лог каждого запуска
```

## Тесты

```bash
ubuntu/bootstrap/tests/run.sh lint      # shellcheck
ubuntu/bootstrap/tests/run.sh unit      # ~200 проверок без root и сети
ubuntu/bootstrap/tests/run.sh e2e       # Docker-контейнеры Ubuntu с systemd, реальные sshd/ufw/fail2ban
ubuntu/bootstrap/tests/run.sh coverage  # то же под kcov
```

Хост при тестировании не меняется: всё выполняется в контейнерах.
