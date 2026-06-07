#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
else
    echo "ERROR: $ENV_FILE not found. Copy .env.example to .env and edit it." >&2
    exit 1
fi

DOMAIN_FQDN="${DOMAIN_FQDN:-au-team.irpo}"
DOMAIN_NETBIOS="${DOMAIN_NETBIOS:-AU-TEAM}"
DOMAIN_ADMIN_USER="${DOMAIN_ADMIN_USER:-administrator}"
BR_SRV_IP="${BR_SRV_IP:-192.168.0.2}"
HQ_CLI_HOSTNAME="${HQ_CLI_HOSTNAME:-hq-cli}"
HQ_CLI_INTERFACE="${HQ_CLI_INTERFACE:-ens19}"

log() {
    printf '[HQ-CLI prepare] %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die "run this script as root"
[[ -n "$BR_SRV_IP" ]] || die "BR_SRV_IP is empty"

log "Installing the ALT Linux AD client, role module and DNS tools"
apt-get update
apt-get install -y task-auth-ad-sssd libnss-role bind-utils

current_hostname="$(hostname -s | tr '[:upper:]' '[:lower:]')"
if [[ "$current_hostname" != "${HQ_CLI_HOSTNAME,,}" ]]; then
    log "Setting hostname to ${HQ_CLI_HOSTNAME,,}"
    hostnamectl set-hostname "${HQ_CLI_HOSTNAME,,}"
fi

dns_config="/etc/net/ifaces/$HQ_CLI_INTERFACE/resolv.conf"
[[ -d "/etc/net/ifaces/$HQ_CLI_INTERFACE" ]] ||
    die "/etc/net/ifaces/$HQ_CLI_INTERFACE does not exist; set HQ_CLI_INTERFACE correctly"

log "Using BR-SRV ($BR_SRV_IP) as the client DNS server"
{
    printf 'search %s\n' "$DOMAIN_FQDN"
    printf 'nameserver %s\n' "$BR_SRV_IP"
} > "$dns_config"
systemctl restart network

log "Checking the domain DNS records"
host -t SRV "_ldap._tcp.$DOMAIN_FQDN" "$BR_SRV_IP"
host -t SRV "_kerberos._udp.$DOMAIN_FQDN" "$BR_SRV_IP"

cat <<EOF

HQ-CLI is ready to join the domain.

CLI method (the password will be requested interactively):
  system-auth write ad "$DOMAIN_FQDN" "${HQ_CLI_HOSTNAME,,}" "$DOMAIN_NETBIOS" "$DOMAIN_ADMIN_USER"

GUI method:
  Control Center -> Users -> Authentication -> Active Directory
  Domain:    $DOMAIN_FQDN
  Workgroup: $DOMAIN_NETBIOS
  Computer:  ${HQ_CLI_HOSTNAME,,}
  Backend:   SSSD

After a successful join, reboot HQ-CLI and run:
  ./03-hq-cli-finish.sh
EOF

