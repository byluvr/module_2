# RAID на HQ-SRV

В `.env` задайте `RAID_NAME`, `RAID_LEVEL`, размер дисков и параметры монтирования. `ERASE_DISKS=yes` разрешает создание или перестройку массива.

```bash
chmod +x ./*.sh
./00-list-disks.sh
./01-hq-srv-raid.sh
```

`00-list-disks.sh` находит подходящие диски и обновляет только `RAID_DISKS` в `.env`.

## Проверка

```bash
cat /proc/mdstat
mdadm --detail /dev/md0
findmnt /raid
grep /raid /etc/fstab
```
