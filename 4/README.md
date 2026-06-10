# Chrony

В `.env` задайте upstream, локальный stratum и адреса ISP.

## ISP

```bash
chmod +x ./*.sh
./01-isp-chrony-server.sh
chronyc tracking
```

## HQ-SRV, HQ-CLI и BR-SRV

```bash
./02-alt-chrony-client.sh
chronyc sources -v
```

## EcoRouter

```text
configure
ntp server <адрес ISP со стороны маршрутизатора>
end
write memory
show ntp status
```
