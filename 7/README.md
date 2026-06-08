# Модуль 2, задание 7: Apache и MariaDB

Веб-приложение разворачивается на `HQ-SRV`.

## Параметры

Перед запуском отредактируйте `.env`:

```bash
ISO_DEVICE=/dev/sr0
ISO_MOUNT=/mnt
WEB_SOURCE_DIR=web

WEB_ROOT=/var/www/html

DB_HOST=localhost
DB_NAME=webdb
DB_USER=webc
DB_PASSWORD=P@ssw0rd
RESET_DATABASE=yes
```

Имя пользователя, пароль и имя базы можно менять. Скрипт автоматически
запишет эти значения в `index.php`.

Apache использует стандартный HTTP-порт `80`.

При `RESET_DATABASE=yes` база приложения пересоздаётся перед импортом. Это
позволяет безопасно повторно запускать сценарий без ошибок из-за уже
существующих таблиц. Для сохранения текущих данных укажите
`RESET_DATABASE=no`: если в базе уже есть таблицы, повторный импорт будет
пропущен.

## Запуск

Подключите `Additional.iso` к приводу `HQ-SRV` и выполните от `root`:

```bash
bash 01-hq-srv-web-app.sh
```

Скрипт:

1. Устанавливает `lamp-server` и `curl`.
2. Монтирует `Additional.iso`.
3. Копирует `index.php`, директорию `images` и, при наличии, `logo.png`.
4. Записывает параметры подключения к MariaDB в `index.php`.
5. Создаёт базу и пользователя, затем импортирует `dump.sql`.
6. Включает `mariadb` и `httpd2` в автозагрузку.
7. Проверяет доступ пользователя к БД и HTTP-ответ Apache.

## Проверка

На `HQ-SRV`:

```bash
systemctl status mariadb
systemctl status httpd2
mariadb -u webc -p -D webdb -e "SHOW TABLES;"
curl -I http://127.0.0.1/
```

С клиента откройте:

```text
http://HQ-SRV-IP/
```

Параметры для отчёта сохраняются в:

```text
/root/module_2_task_7_web_report.txt
```
