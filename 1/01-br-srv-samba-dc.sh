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

DOMAIN_FQDN="${DOMAIN_FQDN:-au-team.irpo}"
DOMAIN_REALM="${DOMAIN_FQDN^^}"
DOMAIN_NETBIOS="${DOMAIN_NETBIOS:-AU-TEAM}"
DC_HOSTNAME="${DC_HOSTNAME:-br-srv}"
DC_COMPUTER_NAME="${DC_HOSTNAME%%.*}"
DC_FQDN="${DC_COMPUTER_NAME}.${DOMAIN_FQDN}"
BR_SRV_IP="${BR_SRV_IP:?BR_SRV_IP is required in $ENV_FILE}"
BR_SRV_INTERFACE="${BR_SRV_INTERFACE:?BR_SRV_INTERFACE is required in $ENV_FILE}"
DNS_FORWARDER="${DNS_FORWARDER:?DNS_FORWARDER is required in $ENV_FILE}"
DOMAIN_ADMIN_PASSWORD="${DOMAIN_ADMIN_PASSWORD:-}"
DOMAIN_ADMIN_USER="${DOMAIN_ADMIN_USER:-Administrator}"
HQ_CLI_HOSTNAME="${HQ_CLI_HOSTNAME:-hq-cli}"
HQ_SRV_IP="${HQ_SRV_IP:?HQ_SRV_IP is required in $ENV_FILE}"
HQ_CLI_IP="${HQ_CLI_IP:?HQ_CLI_IP is required in $ENV_FILE}"
HQ_RTR_IP="${HQ_RTR_IP:?HQ_RTR_IP is required in $ENV_FILE}"
BR_RTR_IP="${BR_RTR_IP:?BR_RTR_IP is required in $ENV_FILE}"
ISP_HQ_IP="${ISP_HQ_IP:?ISP_HQ_IP is required in $ENV_FILE}"
MON_HOSTNAME="${MON_HOSTNAME:-mon}"
WEB_HOSTNAME="${WEB_HOSTNAME:-web}"
DOCKER_HOSTNAME="${DOCKER_HOSTNAME:-docker}"
HQ_GROUP="${HQ_GROUP:-hq}"
HQ_USER_PREFIX="${HQ_USER_PREFIX:-hquser}"
HQ_USER_COUNT="${HQ_USER_COUNT:-5}"
HQ_USER_PASSWORD="${HQ_USER_PASSWORD:-}"
RESET_SAMBA="${RESET_SAMBA:-no}"

log() {
    printf '[BR-SRV] %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

validate_ipv4() {
    local name="$1"
    local value="$2"

    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
        die "$name is not an IPv4 address"
}

ensure_dns_a_record() {
    local name="$1"
    local address="$2"
    local credentials="${DOMAIN_ADMIN_USER}%${DOMAIN_ADMIN_PASSWORD}"
    local query_output
    local current_address
    local -a current_addresses

    query_output="$(
        samba-tool dns query 127.0.0.1 "$DOMAIN_FQDN" "$name" A \
            -U "$credentials" 2>/dev/null || true
    )"

    mapfile -t current_addresses < <(awk '/A: / { print $2 }' <<< "$query_output")

    if ((${#current_addresses[@]} == 1)) &&
        [[ "${current_addresses[0]}" == "$address" ]]; then
        log "DNS record ${name}.${DOMAIN_FQDN} already points to $address"
        return
    fi

    for current_address in "${current_addresses[@]}"; do
        [[ -n "$current_address" ]] || continue
        samba-tool dns delete 127.0.0.1 "$DOMAIN_FQDN" "$name" A \
            "$current_address" -U "$credentials"
    done

    log "Setting DNS record ${name}.${DOMAIN_FQDN} to $address"
    samba-tool dns add 127.0.0.1 "$DOMAIN_FQDN" "$name" A "$address" \
        -U "$credentials"
}

[[ $EUID -eq 0 ]] || die "run this script as root"
[[ -n "$DOMAIN_ADMIN_PASSWORD" ]] || die "DOMAIN_ADMIN_PASSWORD is empty"
[[ -n "$HQ_USER_PASSWORD" ]] || die "HQ_USER_PASSWORD is empty"
[[ "$HQ_USER_COUNT" =~ ^[1-9][0-9]*$ ]] || die "HQ_USER_COUNT must be a positive integer"
for variable_name in \
    BR_SRV_IP DNS_FORWARDER HQ_SRV_IP HQ_CLI_IP HQ_RTR_IP BR_RTR_IP ISP_HQ_IP; do
    validate_ipv4 "$variable_name" "${!variable_name}"
done

current_hostname="$(hostname -f 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
if [[ "$current_hostname" != "${DC_FQDN,,}" ]]; then
    log "WARNING: current hostname is '$current_hostname', expected '${DC_FQDN,,}'."
fi

log "Installing Samba DC and DNS diagnostic tools"
apt-get update
apt-get install -y task-samba-dc bind-utils

log "Disabling services that conflict with the Samba AD DC"
for service in smb nmb krb5kdc slapd bind; do
    systemctl disable --now "$service" >/dev/null 2>&1 || true
done

has_dc_config=no
has_domain_db=no

if [[ -s /etc/samba/smb.conf ]] &&
    grep -Eqi '^[[:space:]]*server role[[:space:]]*=[[:space:]]*active directory domain controller' \
        /etc/samba/smb.conf; then
    has_dc_config=yes
fi

if [[ -s /var/lib/samba/private/sam.ldb ]]; then
    has_domain_db=yes
fi

if [[ "$has_dc_config" == yes && "$has_domain_db" == yes && "$RESET_SAMBA" != yes ]]; then
    log "Existing Samba AD DC configuration found; keeping it"
else
    if [[ "$has_domain_db" == yes ]]; then
        [[ "$RESET_SAMBA" == yes ]] || die "Existing Samba state found. Set RESET_SAMBA=yes to delete it."
        log "RESET_SAMBA=yes: deleting the existing Samba configuration and databases"
    else
        log "Removing the package defaults or an incomplete Samba configuration"
    fi

    systemctl disable --now samba >/dev/null 2>&1 || true
    rm -f -- /etc/samba/smb.conf
    rm -rf -- /var/lib/samba /var/cache/samba
    mkdir -p /var/lib/samba/sysvol

    log "Setting the domain controller hostname to ${DC_FQDN,,}"
    hostnamectl set-hostname "${DC_FQDN,,}"

    log "Provisioning domain $DOMAIN_REALM"
    samba-tool domain provision \
        --realm="$DOMAIN_REALM" \
        --domain="$DOMAIN_NETBIOS" \
        --server-role=dc \
        --use-rfc2307 \
        --dns-backend=SAMBA_INTERNAL \
        --option="dns forwarder = $DNS_FORWARDER" \
        --adminpass="$DOMAIN_ADMIN_PASSWORD"
fi

[[ -f /var/lib/samba/private/krb5.conf ]] ||
    die "/var/lib/samba/private/krb5.conf was not created"

log "Installing the Kerberos configuration"
install -m 0644 /var/lib/samba/private/krb5.conf /etc/krb5.conf

log "Starting Samba AD DC"
systemctl enable --now samba

log "Creating Samba DNS records for the lab"
ensure_dns_a_record hq-srv "$HQ_SRV_IP"
ensure_dns_a_record "$HQ_CLI_HOSTNAME" "$HQ_CLI_IP"
ensure_dns_a_record hq-rtr "$HQ_RTR_IP"
ensure_dns_a_record br-rtr "$BR_RTR_IP"
ensure_dns_a_record "$MON_HOSTNAME" "$HQ_SRV_IP"
ensure_dns_a_record "$WEB_HOSTNAME" "$ISP_HQ_IP"
ensure_dns_a_record "$DOCKER_HOSTNAME" "$ISP_HQ_IP"

dns_config="/etc/net/ifaces/$BR_SRV_INTERFACE/resolv.conf"
if [[ -d "/etc/net/ifaces/$BR_SRV_INTERFACE" ]]; then
    log "Configuring local DNS resolver in $dns_config"
    {
        printf 'search %s\n' "$DOMAIN_FQDN"
        printf 'nameserver 127.0.0.1\n'
    } > "$dns_config"
    systemctl restart network
else
    log "WARNING: /etc/net/ifaces/$BR_SRV_INTERFACE does not exist."
    log "Configure BR-SRV DNS manually: search $DOMAIN_FQDN, nameserver 127.0.0.1"
fi

if ! samba-tool group show "$HQ_GROUP" >/dev/null 2>&1; then
    log "Creating domain group $HQ_GROUP"
    samba-tool group add "$HQ_GROUP"
else
    log "Domain group $HQ_GROUP already exists"
fi

for ((i = 1; i <= HQ_USER_COUNT; i++)); do
    username="${HQ_USER_PREFIX}${i}"

    if ! samba-tool user show "$username" >/dev/null 2>&1; then
        log "Creating domain user $username"
        samba-tool user add "$username" "$HQ_USER_PASSWORD"
    else
        log "Domain user $username already exists"
    fi

    samba-tool user setexpiry "$username" --noexpiry >/dev/null

    if ! samba-tool group listmembers "$HQ_GROUP" | grep -Fqx "$username"; then
        samba-tool group addmembers "$HQ_GROUP" "$username"
    fi
done

log "Domain information"
samba-tool domain info 127.0.0.1

log "Members of $HQ_GROUP"
samba-tool group listmembers "$HQ_GROUP"

log "Checking the LDAP DNS service record"
host -t SRV "_ldap._tcp.$DOMAIN_FQDN" 127.0.0.1
host -t A "$DC_FQDN" 127.0.0.1
host -t A "${MON_HOSTNAME}.${DOMAIN_FQDN}" 127.0.0.1
host -t A "${WEB_HOSTNAME}.${DOMAIN_FQDN}" 127.0.0.1
host -t A "${DOCKER_HOSTNAME}.${DOMAIN_FQDN}" 127.0.0.1

log "BR-SRV configuration completed"
