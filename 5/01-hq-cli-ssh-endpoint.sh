#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
else
    echo "ERROR: $ENV_FILE not found." >&2
    exit 1
fi

LINUX_SSH_USER="${LINUX_SSH_USER:-sshuser}"
LINUX_SSH_PASSWORD="${LINUX_SSH_PASSWORD:-P@ssw0rd}"
LINUX_SSH_PORT="${LINUX_SSH_PORT:?LINUX_SSH_PORT is required in $ENV_FILE}"
SSH_ALLOW_USERS="${SSH_ALLOW_USERS:-$LINUX_SSH_USER}"
SSH_MAX_AUTH_TRIES="${SSH_MAX_AUTH_TRIES:-2}"
SSHD_CONFIG=/etc/openssh/sshd_config
SUDOERS_FILE="/etc/sudoers.d/60-ansible-$LINUX_SSH_USER"

log() {
    printf '[HQ-CLI SSH] %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die "run this script as root"
[[ "$LINUX_SSH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] ||
    die "LINUX_SSH_USER contains unsupported characters"
[[ "$LINUX_SSH_PORT" =~ ^[0-9]+$ ]] &&
    (( LINUX_SSH_PORT >= 1 && LINUX_SSH_PORT <= 65535 )) ||
    die "LINUX_SSH_PORT must be from 1 to 65535"
[[ "$SSH_MAX_AUTH_TRIES" =~ ^[1-9][0-9]*$ ]] ||
    die "SSH_MAX_AUTH_TRIES must be a positive integer"

log "Installing OpenSSH server and sudo"
apt-get update
apt-get install -y openssh-server sudo

[[ -f "$SSHD_CONFIG" ]] ||
    die "$SSHD_CONFIG was not created after installing openssh-server"

log "Generating missing SSH host keys"
ssh-keygen -A
if ! find /etc/openssh -maxdepth 1 -type f \
    -name 'ssh_host_*_key' -size +0c -print -quit | grep -q .; then
    die "SSH host keys were not created in /etc/openssh"
fi

if ! id "$LINUX_SSH_USER" >/dev/null 2>&1; then
    log "Creating user $LINUX_SSH_USER"
    useradd -m -s /bin/bash "$LINUX_SSH_USER"
fi

printf '%s:%s\n' "$LINUX_SSH_USER" "$LINUX_SSH_PASSWORD" | chpasswd
usermod -aG wheel "$LINUX_SSH_USER"

log "Configuring passwordless sudo for Ansible"
install -d -m 0750 /etc/sudoers.d
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$LINUX_SSH_USER" > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"
visudo -cf /etc/sudoers

log "Configuring sshd"
temp_config="$(mktemp)"
trap 'rm -f -- "${temp_config:-}"' EXIT
awk '
    $0 == "# BEGIN MODULE_2_TASK_5" {
        in_managed_block = 1
        next
    }
    $0 == "# END MODULE_2_TASK_5" {
        in_managed_block = 0
        next
    }
    in_managed_block {
        next
    }
    /^[[:space:]]*(Port|AllowUsers|MaxAuthTries|PasswordAuthentication)[[:space:]]+/ {
        print "# Disabled by module_2 task 5: " $0
        next
    }
    { print }
' "$SSHD_CONFIG" > "$temp_config"

cat >> "$temp_config" <<EOF

# BEGIN MODULE_2_TASK_5
Port $LINUX_SSH_PORT
AllowUsers $SSH_ALLOW_USERS
MaxAuthTries $SSH_MAX_AUTH_TRIES
PasswordAuthentication yes
# END MODULE_2_TASK_5
EOF

sshd -t -f "$temp_config"
if ! cmp -s "$temp_config" "$SSHD_CONFIG"; then
    install -m 0600 "$temp_config" "$SSHD_CONFIG"
fi
rm -f -- "$temp_config"
trap - EXIT

log "Enabling and restarting sshd"
systemctl enable sshd
systemctl restart sshd
systemctl is-enabled --quiet sshd ||
    die "sshd is not enabled"
systemctl is-active --quiet sshd ||
    die "sshd is not running"

log "HQ-CLI SSH configuration completed"
printf 'User: %s\nPort: %s\nAllowed users: %s\n' \
    "$LINUX_SSH_USER" "$LINUX_SSH_PORT" "$SSH_ALLOW_USERS"
sshd -T | grep -E '^(port|allowusers|maxauthtries|passwordauthentication) '
