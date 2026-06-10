# Статический NAT

## HQ-RTR

```text
configure
ip nat source static tcp 192.168.1.10 80 172.16.1.4 8080
ip nat source static tcp 192.168.1.10 2026 172.16.1.4 2026
end
write memory
```

## BR-RTR

```text
configure
ip nat source static tcp 192.168.3.10 8080 172.16.2.5 8080
ip nat source static tcp 192.168.3.10 2026 172.16.2.5 2026
end
write memory
```

## Проверка с ISP

```bash
curl http://172.16.1.4:8080/
curl http://172.16.2.5:8080/
ssh -p 2026 sshuser@172.16.1.4
ssh -p 2026 sshuser@172.16.2.5
```
