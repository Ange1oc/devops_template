# 🛠️ DevOps Template

Готовые решения для развертывания DevOps инфраструктуры с автоматическими бекапами.

## 📦 Включенные сервисы

- **🔧 [OneeDev](onedev/)** - Полнофункциональный Git сервер с CI/CD
- **📦 [Registry](registry/)** - Приватный Docker Registry  
- **🔧 [Gitea](gitea/)** - Легковесный Git сервер
- **💾 [Backup System](backup-system/)** - Универсальная система бекапов
- **🛡️ [ubuntu-bootstrap](ubuntu/bootstrap/)** - Подготовка Ubuntu-сервера к production одной командой: SSH, UFW, fail2ban, обновления, Docker, nginx, certbot
- **🔐 [wg-network](ubuntu/wg/README.ru.md)** - WireGuard-сеть hub + peers: установка и подключение серверов одной командой, безопасное применение с автооткатом ([English](ubuntu/wg/README.md))

## 🚀 Быстрый старт

### 0. Чистый сервер Ubuntu 22.04/24.04/26.04

```bash
curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/bootstrap/install.sh | sudo bash -s -- --run
```

Мастер создаст администратора, закроет вход по паролю, включит UFW и fail2ban, автообновления и при желании поставит Docker/nginx/certbot. Подробности — в [ubuntu/bootstrap/README.md](ubuntu/bootstrap/README.md) ([English](ubuntu/bootstrap/README.en.md)).

### 1. OneeDev с системой бекапов

```bash
# Установка и настройка
cd onedev
./install-backup.sh

# Настройка конфигурации
nano backup/config/backup.env

# Запуск с бекапами  
docker compose --profile backup up -d
```

### 2. Registry

```bash
cd registry
./install.sh
docker compose up -d
```

### 3. Gitea

```bash
cd gitea  
./install.sh
docker compose up -d
```

## 💾 Система бекапов

### Особенности
- ✅ PostgreSQL базы данных
- ✅ Docker volumes
- ✅ Отправка на удаленный сервер
- ✅ Telegram уведомления
- ✅ Автоматическая ротация
- ✅ Планировщик задач
- ✅ Dry-run режим

### Быстрая настройка для любого проекта

```bash
# Скопируйте шаблон
cp backup-system/install-template.sh your-project/install-backup.sh

# Настройте переменные
nano your-project/install-backup.sh

# Запустите установку
cd your-project
./install-backup.sh
```

### Основные команды

```bash
# Тестирование соединений
docker exec <project>-backup /app/scripts/entrypoint.sh test-connection

# Бекап в тестовом режиме  
docker exec <project>-backup /app/scripts/entrypoint.sh backup --dry-run

# Полный бекап
docker exec <project>-backup /app/scripts/entrypoint.sh backup

# Справка
docker exec <project>-backup /app/scripts/entrypoint.sh help
```

## 📋 Документация

- **[Быстрый старт](QUICK_START.md)** - Пошаговые инструкции
- **[Система бекапов](backup-system/README.md)** - Подробная документация
- **[OneeDev](onedev/)** - Настройка Git сервера
- **[Registry](registry/)** - Настройка Docker Registry

## 🔧 Требования

- Docker 20.10+
- Docker Compose 2.0+
- Linux (тестировано на Ubuntu 22.04+)

## 🛡️ Безопасность

- Все сервисы изолированы в контейнерах
- SSH ключи для доступа к бекапам
- Переменные окружения для паролей
- Nginx proxy с SSL готовностью
- Минимальные права доступа

## 📱 Мониторинг

- Telegram уведомления о статусе бекапов
- Подробные логи всех операций
- Healthcheck контейнеров
- Метрики размеров и времени выполнения

## 🔄 Автоматизация

### Планировщик бекапов (встроенный)
- **Ежедневно в 2:00** - полный бекап
- **Воскресенье в 1:00** - проверка соединений
- **1 число месяца в 3:00** - очистка старых бекапов

### Ротация бекапов
- Локальное хранение: 30 дней
- Еженедельные: 4 недели  
- Месячные: 12 месяцев

## 🆘 Поддержка

1. Проверьте [документацию](backup-system/README.md)
2. Запустите диагностику: `test-connection`
3. Проверьте логи: `docker logs <container>`
4. Используйте `--dry-run` для тестирования

## 📄 Лицензия

MIT License - используйте свободно для личных и коммерческих проектов.

---

**💡 Совет**: Начните с OneeDev для полного опыта работы с системой бекапов!
