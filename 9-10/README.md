# Nginx reverse proxy и Basic Auth

На ISP проверьте домены, upstream-адреса и учётные данные в `.env`.

```bash
chmod +x ./01-isp-nginx-proxy.sh
./01-isp-nginx-proxy.sh
```

DNS-записи `web.au-team.irpo` и `docker.au-team.irpo` создаёт Samba-скрипт из `module_2/1`.

## Проверка с HQ-CLI

```bash
curl -I http://web.au-team.irpo/
curl -u WEB:P@ssw0rd http://web.au-team.irpo/
curl http://docker.au-team.irpo/
```
