# Очистка module_2

Скрипты удаляют только каталог проекта и при необходимости отключают `Additional.iso`. Настроенные службы и `/mnt/nfs/test.txt` сохраняются.

В `.env` задайте `DELETE_PROJECT` и `UNMOUNT_ADDITIONAL_ISO`.

Запускайте нужный файл от `root` из каталога вне `module_2`:

```bash
cd /root
bash /путь/module_2/clear/01-hq-cli-clean.sh
bash /путь/module_2/clear/02-hq-srv-clean.sh
bash /путь/module_2/clear/03-br-srv-clean.sh
bash /путь/module_2/clear/04-isp-clean.sh
```
