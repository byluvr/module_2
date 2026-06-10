# Docker-приложение на BR-SRV

Подключите `Additional.iso` и проверьте в `.env` пути образов, имена контейнеров, порты и параметры базы.

```bash
chmod +x ./01-br-srv-docker-app.sh
./01-br-srv-docker-app.sh
```

## Проверка

```bash
docker compose ps
docker logs tespapp
curl http://127.0.0.1:8080/
```
