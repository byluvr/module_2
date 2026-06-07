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

Скрипты нужно запускать от `root`.

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

После успешной проверки DNS используйте один из вариантов.

Командная строка:

```bash
system-auth write ad au-team.irpo hq-cli AU-TEAM administrator
```

Или ЦУС: **Пользователи → Аутентификация → Active Directory**, backend
`SSSD`. После успешного ввода обязательно перезагрузите `HQ-CLI`.

### 3. HQ-CLI: роли и sudo

После перезагрузки:

```bash
./03-hq-cli-finish.sh
```

Скрипт выполняет `roleadd hq wheel`, отключает стандартное неограниченное
правило `sudo` для `wheel` и создаёт проверяемый через `visudo` файл
`/etc/sudoers.d/50-hq-limited`.

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

Если доменные пользователи не видны, сначала проверяйте DNS и время:

```bash
host -t SRV _kerberos._udp.au-team.irpo
timedatectl
systemctl status sssd
```

Между `HQ-CLI` и `BR-SRV` должны проходить стандартные протоколы AD, прежде
всего DNS, Kerberos, LDAP и SMB.
