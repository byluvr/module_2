# NFS

Проверьте в `.env` адрес HQ-SRV, сеть HQ-CLI и пути монтирования.

## HQ-SRV

```bash
chmod +x ./*.sh
./01-hq-srv-nfs.sh
```

## HQ-CLI

```bash
./02-hq-cli-nfs.sh
```

## Проверка

```bash
exportfs -v
findmnt /mnt/nfs
ls -l /mnt/nfs/test.txt
```

Файл `/mnt/nfs/test.txt` является результатом проверки и не удаляется.
