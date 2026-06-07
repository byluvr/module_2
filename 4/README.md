# Модуль 2, задание 4: chrony

ISP работает как NTP-сервер со стратумом из `.env`. Серверы и клиент ALT
Linux синхронизируются с адресом ISP своей стороны топологии.

## Параметры

Отредактируйте `.env`:

```bash
UPSTREAM_NTP=ntp0.ntp-servers.net
LOCAL_STRATUM=5
NTP_ALLOW_NETWORK=0.0.0.0/0
ISP_HQ_IP=172.16.1.1
ISP_BR_IP=172.16.2.1
```

`LOCAL_STRATUM` может быть от 2 до 15. Для upstream автоматически
вычисляется `minstratum = LOCAL_STRATUM - 1`, чтобы ISP сообщал клиентам
требуемый стратум.

## ISP

```bash
chmod +x ./*.sh
./01-isp-chrony-server.sh
```

Итоговая основная конфигурация при `LOCAL_STRATUM=5`:

```chrony
server ntp0.ntp-servers.net iburst prefer minstratum 4
local stratum 5
allow 0.0.0.0/0
```

Проверка:

```bash
chronyc tracking
chronyc sources -v
ss -lunp | grep ':123'
```

Параметры для отчёта сохраняются в:

```text
/root/module_2_task_4_chrony_report.txt
```

## Клиенты ALT Linux

Один и тот же файл `02-alt-chrony-client.sh` запускается на:

- `HQ-SRV`;
- `HQ-CLI`;
- `BR-SRV`.

```bash
./02-alt-chrony-client.sh
```

Для hostname `hq-*` выбирается `ISP_HQ_IP`, для `br-*` — `ISP_BR_IP`.
Если имя машины не соответствует формату, укажите в `.env`:

```bash
NTP_SERVER_IP_OVERRIDE=172.16.1.1
```

Проверка:

```bash
chronyc sources -v
chronyc tracking
```

Символ `^*` около адреса ISP означает, что источник выбран.

## BR-RTR

На EcoRouter настройка выполняется вручную:

```text
enable
configure terminal
ntp server 172.16.2.1
exit
write memory
```

Проверка:

```text
show ntp status
show ntp associations
```

По формулировке задания `HQ-RTR` не является обязательным NTP-клиентом.
Если он также требуется проверяющим:

```text
configure terminal
ntp server 172.16.1.1
exit
write memory
```

Резервные копии `/etc/chrony.conf` сохраняются в
`/root/module_2_task_4_backups`.
