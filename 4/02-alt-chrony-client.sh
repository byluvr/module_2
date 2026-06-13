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

ISP_HQ_IP="${ISP_HQ_IP:?ISP_HQ_IP is required in $ENV_FILE}"
ISP_BR_IP="${ISP_BR_IP:?ISP_BR_IP is required in $ENV_FILE}"
NTP_SERVER_IP_OVERRIDE="${NTP_SERVER_IP_OVERRIDE:-}"
CHRONY_CONFIG=/etc/chrony.conf

log() {
    printf '[chrony client] %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die "run this script as root"

short_hostname="$(hostname -s | tr '[:upper:]' '[:lower:]')"
if [[ -n "$NTP_SERVER_IP_OVERRIDE" ]]; then
    NTP_SERVER_IP="$NTP_SERVER_IP_OVERRIDE"
else
    case "$short_hostname" in
        hq-*)
            NTP_SERVER_IP="$ISP_HQ_IP"
            ;;
        br-*)
            NTP_SERVER_IP="$ISP_BR_IP"
            ;;
        *)
            die "cannot select the ISP address for hostname '$short_hostname'; set NTP_SERVER_IP_OVERRIDE"
            ;;
    esac
fi

[[ "$NTP_SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
    die "selected NTP server '$NTP_SERVER_IP' is not an IPv4 address"

log "Installing chrony"
apt-get update
apt-get install -y chrony

log "Checking network access to ISP ($NTP_SERVER_IP)"
ping -c 1 -W 2 "$NTP_SERVER_IP" >/dev/null ||
    die "ISP address $NTP_SERVER_IP is unreachable"

temp_config="$(mktemp)"
trap 'rm -f -- "${temp_config:-}"' EXIT
cat > "$temp_config" <<EOF
# Managed by module_2/4/02-alt-chrony-client.sh
server $NTP_SERVER_IP iburst prefer

makestep 1.0 3
rtcsync
EOF

log "Validating the chrony configuration"
chronyd -p -f "$temp_config" >/dev/null

if [[ ! -f "$CHRONY_CONFIG" ]] || ! cmp -s "$temp_config" "$CHRONY_CONFIG"; then
    install -m 0644 "$temp_config" "$CHRONY_CONFIG"
fi
rm -f -- "$temp_config"
trap - EXIT

log "Starting chronyd"
systemctl enable --now chronyd
systemctl restart chronyd

sleep 3

log "Client configuration completed"
printf 'NTP server selected for %s: %s\n' "$short_hostname" "$NTP_SERVER_IP"
chronyc sources -v
chronyc tracking
