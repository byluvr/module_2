# Модуль 2, задание 5: Ansible

Ansible настраивается на `BR-SRV`. Inventory создаётся сначала рядом со
скриптами как `hosts.ini`, затем копируется в `/etc/ansible/hosts`.

## Параметры

Перед запуском укажите актуальные адреса и порты в `.env`:

```bash
HQ_SRV_IP=192.168.1.10
HQ_CLI_IP=192.168.2.10
HQ_RTR_IP=10.10.10.1
BR_RTR_IP=192.168.3.1

LINUX_SSH_PORT=2026
ROUTER_SSH_PORT=22
```

## HQ-SRV и HQ-CLI

На обеих машинах запустите один файл:

```bash
bash 01-alt-ssh-endpoint.sh
```

Он:

- создаёт `sshuser` с паролем из `.env`;
- добавляет пользователя в `wheel`;
- создаёт отдельное правило `NOPASSWD: ALL` для Ansible;
- настраивает SSH-порт, `AllowUsers` и `MaxAuthTries`;
- проверяет конфигурацию командой `sshd -t`.

## HQ-RTR и BR-RTR

На обоих EcoRouter вручную разрешите SSH:

```text
enable
configure terminal
security none
exit
write memory
```

## BR-SRV

Запустите:

```bash
bash 02-br-srv-ansible-controller.sh
```

Скрипт:

1. Устанавливает Ansible, `sshpass`, pip и SSH-клиент.
2. Устанавливает `ansible.netcommon`, `cisco.ios`, `ansible-pylibssh`.
3. Создаёт `hosts.ini` рядом со скриптом.
4. Копирует inventory и `ansible.cfg` в `/etc/ansible`.
5. Создаёт SSH-ключ контроллера.
6. Копирует ключ на `HQ-SRV` и `HQ-CLI`.
7. Проверяет структуру inventory.

## Итоговая проверка

На `BR-SRV`:

```bash
cd /etc/ansible
ansible -m ping all
```

Либо:

```bash
bash 03-check-all.sh
```

Все четыре узла должны завершиться без предупреждений и ошибок с
результатом `pong`.

Резервные копии изменённых системных файлов сохраняются в
`/root/module_2_task_5_backups`.
