# Ansible на BR-SRV

Проверьте все адреса, SSH-порты и учётные данные в `.env`.

## HQ-CLI

```bash
chmod +x ./*.sh
./01-hq-cli-ssh-endpoint.sh
```

HQ-SRV и BR-SRV должны уже иметь настроенный SSH.

## BR-SRV

```bash
./02-br-srv-ansible-controller.sh
./03-check-all.sh
```

На обоих EcoRouter предварительно разрешите SSH:

```text
configure
security none
end
write memory
```

Проверка:

```bash
cd /etc/ansible
ansible -m ping all
```
