# Samba AD DC

Проверьте адреса, интерфейсы и пароли в `.env`.

## BR-SRV

```bash
chmod +x ./*.sh
./01-br-srv-samba-dc.sh
```

Скрипт создаёт домен, пользователей и DNS-записи стенда в Samba.

## HQ-CLI

```bash
./02-hq-cli-prepare.sh
reboot
```

Введите машину в домен через ЦУС или выполните показанную скриптом команду `system-auth`. После перезагрузки:

```bash
./03-hq-cli-finish.sh
```

Если `sudo` изначально недоступен, войдите как `root` и временно включите штатное правило `WHEEL_USERS` через `visudo`.

## Проверка

```bash
host -t SRV _ldap._tcp.au-team.irpo 192.168.3.10
host mon.au-team.irpo 192.168.3.10
getent passwd hquser1
sudo -l -U hquser1
```
