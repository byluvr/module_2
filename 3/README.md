# Модуль 2, задание 3: NFS

Скрипты настраивают NFS-сервер на `HQ-SRV` и автоматическое монтирование
ресурса на `HQ-CLI`.

## Параметры

Перед запуском отредактируйте единственный файл `.env`:

```bash
NFS_SERVER_IP=192.168.1.10
HQ_CLI_SUBNET=192.168.2.0/24
NFS_EXPORT_PATH=/raid/nfs
NFS_CLIENT_MOUNT=/mnt/nfs
```

`HQ_CLI_SUBNET` должен содержать только сеть в сторону `HQ-CLI`. Для
топологии с VLAN 200 это `192.168.2.0/24`.

## HQ-SRV

Сначала убедитесь, что задание 2 выполнено и `/raid` смонтирован:

```bash
findmnt /raid
```

Запустите:

```bash
chmod +x ./*.sh
./01-hq-srv-nfs.sh
```

Скрипт создаёт экспорт:

```exports
/raid/nfs 192.168.2.0/24(rw,sync,no_subtree_check,no_root_squash)
```

Другие сети для `/raid/nfs` не добавляются. Повторный запуск обновляет
существующую строку без дублирования.

Параметры для отчёта сохраняются на сервере:

```text
/root/module_2_task_3_nfs_report.txt
```

## HQ-CLI

После настройки сервера:

```bash
./02-hq-cli-nfs.sh
```

В `/etc/fstab` будет создана строка:

```fstab
192.168.1.10:/raid/nfs /mnt/nfs nfs defaults,_netdev 0 0
```

Скрипт монтирует ресурс и создаёт `/mnt/nfs/test.txt`.

## Проверка

На `HQ-CLI`:

```bash
findmnt /mnt/nfs
df -hT /mnt/nfs
cat /mnt/nfs/test.txt
grep /mnt/nfs /etc/fstab
```

На `HQ-SRV`:

```bash
exportfs -v
cat /raid/nfs/test.txt
grep /raid/nfs /etc/exports
```

Для проверки автомонтирования после перезагрузки `HQ-CLI`:

```bash
reboot
findmnt /mnt/nfs
touch /mnt/nfs/after-reboot.txt
```

Резервные копии `exports` и `fstab` сохраняются в
`/root/module_2_task_3_backups`.
