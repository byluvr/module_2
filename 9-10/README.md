# Модуль 2, задания 9-10: nginx и Basic Auth

Оба задания выполняются одним скриптом на маршрутизаторе `ISP` с ALT Linux.

## Параметры

Перед запуском отредактируйте `.env`:

```bash
WEB_DOMAIN=web.au-team.irpo
DOCKER_DOMAIN=docker.au-team.irpo

WEB_UPSTREAM=172.16.1.2:8080
DOCKER_UPSTREAM=172.16.2.2:8080

AUTH_USER=WEB
AUTH_PASSWORD=P@ssw0rd
AUTH_REALM=Restricted area
```

`WEB_UPSTREAM` и `DOCKER_UPSTREAM` должны содержать внешние адреса
маршрутизаторов из задания 8.

## DNS

Имена `web.au-team.irpo` и `docker.au-team.irpo` должны разрешаться в
IP-адрес `ISP`, доступный клиенту. На используемом DNS-сервере добавьте записи
для обоих имён.

Например, для `dnsmasq`, если адрес ISP со стороны HQ равен `172.16.1.1`:

```ini
address=/web.au-team.irpo/172.16.1.1
address=/docker.au-team.irpo/172.16.1.1
```

После изменения перезапустите `dnsmasq` и проверьте с `HQ-CLI`:

```bash
host web.au-team.irpo
host docker.au-team.irpo
```

## Запуск на ISP

```bash
bash 01-isp-nginx-proxy.sh
```

Скрипт:

1. Устанавливает `nginx`, `apache2-htpasswd` и `curl`.
2. Проверяет доступность обоих upstream-приложений.
3. Создаёт `/etc/nginx/.htpasswd`.
4. Настраивает два виртуальных хоста nginx.
5. Включает Basic Auth только для `web.au-team.irpo`.
6. Проверяет конфигурацию и включает nginx в автозагрузку.
7. Проверяет проксирование и запрос пароля.

Основной конфигурационный файл:

```text
/etc/nginx/sites-available.d/default.conf
```

Он подключается символической ссылкой:

```text
/etc/nginx/sites-enabled.d/default.conf
```

## Проверка с HQ-CLI

Без учётных данных сервер `web` должен вернуть `401`:

```bash
curl -I http://web.au-team.irpo/
```

С правильными учётными данными должно открыться приложение `HQ-SRV`:

```bash
curl -u 'WEB:P@ssw0rd' http://web.au-team.irpo/ | head
```

Docker-приложение доступно без Basic Auth:

```bash
curl http://docker.au-team.irpo/ | head
```

В браузере:

```text
http://web.au-team.irpo/
http://docker.au-team.irpo/
```

Для `web.au-team.irpo` браузер должен запросить логин `WEB` и пароль
`P@ssw0rd`.

Резервные копии изменённых файлов сохраняются в:

```text
/root/module_2_task_9_10_backups
```

Если подключение не происходит, попробовать записать данные строки в /etc/hosts на клиенте:
```text
isp-ip web.au-team.irpo
isp-ip docker.au-team.irpo
```