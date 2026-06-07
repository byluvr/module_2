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
HQ_CLI_COMPUTER_NAME="${HQ_CLI_HOSTNAME%%.*}"
HQ_CLI_FQDN="${HQ_CLI_COMPUTER_NAME}.${DOMAIN_FQDN}"

log() {
    printf '[HQ-CLI prepare] %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die "run this script as root"
[[ -n "$BR_SRV_IP" ]] || die "BR_SRV_IP is empty"
[[ "$HQ_CLI_INTERFACE" =~ ^[a-zA-Z0-9_.:-]+$ ]] ||
    die "HQ_CLI_INTERFACE contains unsupported characters"

log "Refreshing package metadata"
apt-get update

log "Synchronizing the split alterator-datetime packages"
apt-get install -y alterator-datetime alterator-datetime-functions

log "Installing the ALT Linux AD client, role module and DNS tools"
apt-get install -y task-auth-ad-sssd libnss-role bind-utils

hostname_changed=no
current_hostname="$(hostname -f 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
if [[ "$current_hostname" != "${HQ_CLI_FQDN,,}" ]]; then
    log "Setting hostname to ${HQ_CLI_FQDN,,}"
    hostnamectl set-hostname "${HQ_CLI_FQDN,,}"
    hostname_changed=yes
fi

dns_config="/etc/net/ifaces/$HQ_CLI_INTERFACE/resolv.conf"
[[ -d "/etc/net/ifaces/$HQ_CLI_INTERFACE" ]] ||
    die "/etc/net/ifaces/$HQ_CLI_INTERFACE does not exist; set HQ_CLI_INTERFACE correctly"

log "Using BR-SRV ($BR_SRV_IP) as the client DNS server"
{
    printf 'nameserver %s\n' "$BR_SRV_IP"
} > "$dns_config"

resolvconf_config="/etc/resolvconf.conf"
touch "$resolvconf_config"

if grep -q '^interface_order=' "$resolvconf_config"; then
    sed -i "s|^interface_order=.*|interface_order='lo lo[0-9]* lo.* $HQ_CLI_INTERFACE'|" \
        "$resolvconf_config"
else
    printf "interface_order='lo lo[0-9]* lo.* %s'\n" "$HQ_CLI_INTERFACE" \
        >> "$resolvconf_config"
fi

if grep -q '^search_domains=' "$resolvconf_config"; then
    sed -i "s|^search_domains=.*|search_domains=$DOMAIN_FQDN|" "$resolvconf_config"
else
    printf 'search_domains=%s\n' "$DOMAIN_FQDN" >> "$resolvconf_config"
fi

log "Updating the system resolver configuration"
resolvconf -u

log "Checking direct DNS access to BR-SRV"
host -t SRV "_ldap._tcp.$DOMAIN_FQDN" "$BR_SRV_IP"
host -t SRV "_kerberos._udp.$DOMAIN_FQDN" "$BR_SRV_IP"

log "Checking the system resolver used by the domain join tools"
if ! awk -v server="$BR_SRV_IP" \
    '$1 == "nameserver" && $2 == server { found = 1 } END { exit !found }' \
    /etc/resolv.conf; then
    cat /etc/resolv.conf >&2
    die "/etc/resolv.conf does not use BR-SRV as DNS"
fi

if ! awk -v domain="$DOMAIN_FQDN" \
    '$1 == "search" { for (i = 2; i <= NF; i++) if ($i == domain) found = 1 }
     END { exit !found }' /etc/resolv.conf; then
    cat /etc/resolv.conf >&2
    die "/etc/resolv.conf does not contain the domain search suffix"
fi

if ! ldap_answer="$(host -t SRV "_ldap._tcp.$DOMAIN_FQDN")"; then
    cat /etc/resolv.conf >&2
    die "the system resolver cannot find the LDAP service of $DOMAIN_FQDN"
fi
printf '%s\n' "$ldap_answer"

if ! host -t SRV "_kerberos._udp.$DOMAIN_FQDN"; then
    cat /etc/resolv.conf >&2
    die "the system resolver cannot find the Kerberos service of $DOMAIN_FQDN"
fi

dc_dns_name="$(awk '/has SRV record/ { print $NF; exit }' <<< "$ldap_answer")"
dc_dns_name="${dc_dns_name%.}"
[[ -n "$dc_dns_name" ]] ||
    die "cannot determine the domain controller name from the LDAP SRV record"

if ! host -t A "$dc_dns_name"; then
    die "the domain controller name $dc_dns_name has no resolvable A record"
fi

if [[ "$hostname_changed" == yes ]]; then
    cat <<EOF

The hostname was changed to ${HQ_CLI_FQDN,,}.
Reboot HQ-CLI before opening Control Center and joining the domain.
After reboot, verify:
  host -t SRV "_ldap._tcp.$DOMAIN_FQDN"
EOF
fi

cat <<EOF

HQ-CLI is ready to join the domain.

CLI method:
  read -rsp "Domain password: " DOMAIN_JOIN_PASSWORD; echo
  system-auth write ad "$DOMAIN_FQDN" "${HQ_CLI_COMPUTER_NAME,,}" "$DOMAIN_NETBIOS" "$DOMAIN_ADMIN_USER" "\$DOMAIN_JOIN_PASSWORD"
  unset DOMAIN_JOIN_PASSWORD

GUI method:
  Control Center -> Users -> Authentication -> Active Directory
  Domain:    $DOMAIN_FQDN
  Workgroup: $DOMAIN_NETBIOS
  Computer:  ${HQ_CLI_COMPUTER_NAME,,}
  Backend:   SSSD

After a successful join, reboot HQ-CLI and run:
  ./03-hq-cli-finish.sh
EOF
