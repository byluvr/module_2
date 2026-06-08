# Модуль 2, задание 6: Docker-приложение

Стек разворачивается на `BR-SRV` и состоит из приложения и MariaDB.

## Параметры

Перед запуском отредактируйте `.env`. Основные изменяемые значения:

```bash
APP_CONTAINER_NAME=tespapp
DB_CONTAINER_NAME=db
APP_PORT=8080
APP_INTERNAL_PORT=8000
DB_PORT=3306

DB_NAME=testdb
DB_USER=testc
DB_PASSWORD=P@ssw0rd
DB_ROOT_PASSWORD=toor
```

По формулировке задания основной контейнер по умолчанию называется `tespapp`.
Если в вашем варианте указано `testapp`, измените только
`APP_CONTAINER_NAME`.

Путь к диску и имена архивов также задаются в `.env`:

```bash
ISO_DEVICE=/dev/sr0
ISO_MOUNT=/mnt
APP_IMAGE_ARCHIVE=docker/site_latest.tar
DB_IMAGE_ARCHIVE=docker/mariadb_latest.tar
```

## Запуск

Подключите `Additional.iso` к приводу `BR-SRV`, затем выполните от `root`:

```bash
bash 01-br-srv-docker-app.sh
```

Скрипт:

1. Устанавливает `docker-engine` и `docker-compose-v2`.
2. Включает и запускает `docker.service`.
3. Монтирует `Additional.iso`.
4. Загружает `site_latest.tar` и `mariadb_latest.tar`.
5. Проверяет `compose.yaml` и запускает стек.
6. Проверяет, что оба контейнера работают.

В `compose.yaml` приложение подключается к MariaDB по имени сервиса
`database`. IP контейнера указывать не нужно.

## Проверка

```bash
docker ps
docker compose --env-file .env -f compose.yaml ps
docker compose --env-file .env -f compose.yaml logs
```

С клиента откройте:

```text
http://BR-SRV-IP:8080/
```

Если `APP_PORT` изменён в `.env`, используйте новое значение.

Данные MariaDB сохраняются в именованном Docker volume `database_data`.
