#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
LOCAL_INVENTORY="$SCRIPT_DIR/hosts.ini"
LOCAL_CONFIG="$SCRIPT_DIR/ansible.cfg"
ANSIBLE_DIR=/etc/ansible

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
else
    echo "ERROR: $ENV_FILE not found." >&2
    exit 1
fi

HQ_SRV_IP="${HQ_SRV_IP:-192.168.1.10}"
HQ_CLI_IP="${HQ_CLI_IP:-192.168.2.10}"
HQ_RTR_IP="${HQ_RTR_IP:-10.10.10.1}"
BR_RTR_IP="${BR_RTR_IP:-192.168.3.1}"
LINUX_SSH_USER="${LINUX_SSH_USER:-sshuser}"
LINUX_SSH_PASSWORD="${LINUX_SSH_PASSWORD:-P@ssw0rd}"
LINUX_SSH_PORT="${LINUX_SSH_PORT:-2026}"
ROUTER_SSH_USER="${ROUTER_SSH_USER:-net_admin}"
ROUTER_SSH_PASSWORD="${ROUTER_SSH_PASSWORD:-P@ssw0rd}"
ROUTER_SSH_PORT="${ROUTER_SSH_PORT:-22}"
ANSIBLE_SSH_KEY="${ANSIBLE_SSH_KEY:-/root/.ssh/id_rsa}"
BACKUP_DIR=/root/module_2_task_5_backups

log() {
    printf '[BR-SRV Ansible] %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

backup_file() {
    local file="$1"

    [[ -e "$file" ]] || return 0
    install -d -m 0700 "$BACKUP_DIR"
    cp -a -- "$file" "$BACKUP_DIR/$(basename "$file").$(date +%Y%m%d%H%M%S)"
}

validate_ipv4() {
    local name="$1"
    local value="$2"

    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
        die "$name='$value' is not an IPv4 address"
}

[[ $EUID -eq 0 ]] || die "run this script as root"
[[ -f "$LOCAL_CONFIG" ]] || die "$LOCAL_CONFIG was not found"
validate_ipv4 HQ_SRV_IP "$HQ_SRV_IP"
validate_ipv4 HQ_CLI_IP "$HQ_CLI_IP"
validate_ipv4 HQ_RTR_IP "$HQ_RTR_IP"
validate_ipv4 BR_RTR_IP "$BR_RTR_IP"

log "Installing Ansible, sshpass and Python tools"
apt-get update
apt-get install -y ansible sshpass python3-module-pip

for command_name in ssh ssh-keygen ssh-copy-id; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "$command_name is missing; BR-SRV SSH must be configured beforehand"
done

log "Installing network collections"
ansible-galaxy collection install ansible.netcommon
ansible-galaxy collection install cisco.ios

if ! python3 -c 'import ansible_pylibssh' >/dev/null 2>&1; then
    log "Installing ansible-pylibssh"
    pip3 install ansible-pylibssh
fi

log "Generating inventory in the script directory"
cat > "$LOCAL_INVENTORY" <<EOF
[Servers]
HQ-SRV ansible_host=$HQ_SRV_IP

[Routers]
HQ-RTR ansible_host=$HQ_RTR_IP
BR-RTR ansible_host=$BR_RTR_IP

[Clients]
HQ-CLI ansible_host=$HQ_CLI_IP

[Servers:vars]
ansible_user=$LINUX_SSH_USER
ansible_password=$LINUX_SSH_PASSWORD
ansible_port=$LINUX_SSH_PORT

[Routers:vars]
ansible_user=$ROUTER_SSH_USER
ansible_password=$ROUTER_SSH_PASSWORD
ansible_port=$ROUTER_SSH_PORT
ansible_connection=ansible.netcommon.network_cli
ansible_network_os=cisco.ios.ios

[Clients:vars]
ansible_user=$LINUX_SSH_USER
ansible_password=$LINUX_SSH_PASSWORD
ansible_port=$LINUX_SSH_PORT

[all:vars]
ansible_python_interpreter=/usr/bin/python3
EOF
chmod 0600 "$LOCAL_INVENTORY"

log "Installing inventory and configuration in $ANSIBLE_DIR"
install -d -m 0755 "$ANSIBLE_DIR"
backup_file "$ANSIBLE_DIR/hosts"
backup_file "$ANSIBLE_DIR/ansible.cfg"
install -m 0600 "$LOCAL_INVENTORY" "$ANSIBLE_DIR/hosts"
install -m 0644 "$LOCAL_CONFIG" "$ANSIBLE_DIR/ansible.cfg"

key_dir="$(dirname "$ANSIBLE_SSH_KEY")"
install -d -m 0700 "$key_dir"
if [[ ! -f "$ANSIBLE_SSH_KEY" ]]; then
    log "Generating the controller SSH key"
    ssh-keygen -q -t rsa -b 3072 -N '' -f "$ANSIBLE_SSH_KEY"
fi

log "Copying the SSH key to HQ-SRV and HQ-CLI"
for host_ip in "$HQ_SRV_IP" "$HQ_CLI_IP"; do
    sshpass -p "$LINUX_SSH_PASSWORD" \
        ssh-copy-id \
        -i "${ANSIBLE_SSH_KEY}.pub" \
        -p "$LINUX_SSH_PORT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$LINUX_SSH_USER@$host_ip"
done

log "Validating Ansible configuration and inventory"
cd "$ANSIBLE_DIR"
ansible-config dump --only-changed
ansible-inventory --graph

cat <<EOF

Controller configuration completed.

Before the final test, execute on HQ-RTR and BR-RTR:
  enable
  configure terminal
  security none
  exit
  write memory

Final test:
  cd /etc/ansible
  ansible -m ping all
EOF
