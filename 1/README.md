# Модуль 2, задание 1: Samba DC

Скрипты настраивают Samba AD DC на `BR-SRV`, вводят `HQ-CLI` в домен
`au-team.irpo` и ограничивают `sudo` для доменной группы `hq` командами
`cat`, `grep` и `id`.

## Файлы

- `01-br-srv-samba-dc.sh` — контроллер домена, группа и пользователи.
- `02-hq-cli-prepare.sh` — пакеты, имя хоста и DNS перед вводом в домен.
- `03-hq-cli-finish.sh` — роли и ограниченный `sudo` после ввода в домен.
- `.env.example` — изменяемые параметры стенда.

## Подготовка

На каждой машине скопируйте каталог задания и создайте рабочий файл настроек:

```bash
cp .env.example .env
chmod 600 .env
```

Проверьте в `.env` как минимум:

- `BR_SRV_IP` — адрес `BR-SRV`, доступный с `HQ-CLI`;
- `BR_SRV_INTERFACE` и `HQ_CLI_INTERFACE` — реальные имена интерфейсов;
- `DNS_FORWARDER` — внешний DNS для контроллера;
- пароли администратора домена и пользователей.

Скрипты нужно запускать от `root`. Предпочтительный вариант:

```bash
su -
cd /путь/к/module_2/1
./имя-скрипта.sh
```

Если на стенде принято запускать скрипты через `sudo`, а пользователь ещё
не имеет таких прав, сначала войдите как `root`, выполните `visudo` и вручную
раскомментируйте существующую стандартную строку ALT Linux, начинающуюся с
`WHEEL_USERS` и разрешающую выполнение `ALL`. В типовом файле она выглядит
примерно так:

```sudoers
WHEEL_USERS ALL=(ALL:ALL) ALL
```

Не добавляйте вторую копию правила: измените уже имеющуюся строку и сохраните
файл через `visudo`, чтобы проверить синтаксис.

После этого пользователь локальной группы `wheel` сможет запускать скрипты:

```bash
sudo ./02-hq-cli-prepare.sh
```

Это временное полное разрешение. На последнем этапе
`03-hq-cli-finish.sh` отключит стандартное правило `WHEEL_USERS` и оставит
доменным пользователям только `cat`, `grep` и `id`.

## Порядок выполнения

### 1. BR-SRV

```bash
chmod +x ./*.sh
./01-br-srv-samba-dc.sh
```

Существующий домен скрипт сохраняет. Для полного пересоздания домена явно
установите `RESET_SAMBA=yes` в `.env`. Это удалит конфигурацию и базы Samba.

### 2. HQ-CLI: подготовка и ввод в домен

```bash
./02-hq-cli-prepare.sh
```

Скрипт сначала синхронно обновляет пакеты `alterator-datetime` и
`alterator-datetime-functions`. Это устраняет конфликт файла
`/usr/bin/alterator-datetime-functions`, который возникает, когда новый
разделённый пакет устанавливается поверх старой монолитной версии
`alterator-datetime`.

Если предыдущий запуск уже завершился таким конфликтом, повторно запустите
обновлённый скрипт. Полное обновление системы через `dist-upgrade` для этого
не требуется.

После успешной проверки DNS используйте один из вариантов.

Если скрипт сообщил, что изменил hostname, сначала перезагрузите `HQ-CLI`.
ЦУС следует открывать заново уже после перезагрузки.

Командная строка:

```bash
read -rsp "Domain password: " DOMAIN_JOIN_PASSWORD; echo
system-auth write ad au-team.irpo hq-cli AU-TEAM Administrator "$DOMAIN_JOIN_PASSWORD"
unset DOMAIN_JOIN_PASSWORD
```

Или ЦУС: **Пользователи → Аутентификация → Active Directory**, backend
`SSSD`. Поля должны быть заполнены так:

```text
Domain:        au-team.irpo
Workgroup:     AU-TEAM
Computer name: hq-cli
```

Поле `Workgroup` нельзя оставлять пустым. В поле `Computer name` указывается
короткое имя без `.au-team.irpo`.

Если ЦУС сообщает `Unable to find specified domain`, проверьте на `HQ-CLI`:

```bash
cat /etc/resolv.conf
host -t SRV _ldap._tcp.au-team.irpo
host -t SRV _kerberos._udp.au-team.irpo
```

В `/etc/resolv.conf` должны находиться:

```text
search au-team.irpo
nameserver 192.168.3.10
```

`BR-SRV` должен быть первым DNS-сервером. Если перед ним расположен DNS
`HQ-SRV`, тот может вернуть отрицательный ответ на AD SRV-запрос, после чего
клиент не обратится ко второму серверу.

После успешного ввода обязательно перезагрузите `HQ-CLI`.

### 3. HQ-CLI: роли и sudo

После перезагрузки:

```bash
./03-hq-cli-finish.sh
```

Скрипт выполняет `roleadd hq wheel`, отключает стандартное неограниченное
правило `sudo` для `wheel` и создаёт проверяемый через `visudo` файл
`/etc/sudoers.d/50-hq-limited`.

На ALT Linux полное правило `NOPASSWD: ALL` также может находиться в
`/etc/sudoers.d/99-sudopw`. Скрипт закомментирует только неограниченные
правила для `%wheel` или `WHEEL_USERS`. Исходные файлы сохраняются в
`/root/sudoers-backups`.

Важно: ограничение относится ко всем пользователям локальной роли `wheel`,
включая локальные учётные записи. Для администрирования во время экзамена
должен оставаться доступен вход `root`.

## Проверка

На `BR-SRV`:

```bash
samba-tool domain info 127.0.0.1
samba-tool group listmembers hq
host -t SRV _ldap._tcp.au-team.irpo 127.0.0.1
```

На `HQ-CLI`:

```bash
getent passwd hquser1
id hquser1
rolelst
sudo -l -U hquser1
```

После входа как `hquser1`:

```bash
sudo /bin/cat /etc/hostname
sudo /bin/grep PRETTY_NAME /etc/os-release
sudo /usr/bin/id
sudo /bin/bash
```

Первые три команды должны выполняться, `sudo /bin/bash` — отклоняться.

Разрешённые команды выполняются без запроса пароля благодаря правилу
`NOPASSWD: HQ_LIMITED`. `NOPASSWD` применяется только к `cat`, `grep` и
`id`, а не ко всем командам.

Проверить итоговый список разрешений можно командой:

```bash
sudo -l
```

Если доменные пользователи не видны, сначала проверяйте DNS и время:

```bash
host -t SRV _kerberos._udp.au-team.irpo
timedatectl
systemctl status sssd
```

Между `HQ-CLI` и `BR-SRV` должны проходить стандартные протоколы AD, прежде
всего DNS, Kerberos, LDAP и SMB.
