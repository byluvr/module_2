# Веб-приложение на HQ-SRV

Подключите `Additional.iso` и проверьте параметры Apache и MariaDB в `.env`.

```bash
chmod +x ./01-hq-srv-web-app.sh
./01-hq-srv-web-app.sh
```

## Проверка

```bash
systemctl status httpd2 mariadb
curl http://127.0.0.1:80/
mariadb -u root -e 'USE webdb; SHOW TABLES;'
```
