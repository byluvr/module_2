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

UPSTREAM_NTP="${UPSTREAM_NTP:?UPSTREAM_NTP is required in $ENV_FILE}"
LOCAL_STRATUM="${LOCAL_STRATUM:?LOCAL_STRATUM is required in $ENV_FILE}"
NTP_ALLOW_NETWORK="${NTP_ALLOW_NETWORK:?NTP_ALLOW_NETWORK is required in $ENV_FILE}"
CHRONY_CONFIG=/etc/chrony.conf

log() {
    printf '[ISP chrony] %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die "run this script as root"
[[ "$LOCAL_STRATUM" =~ ^([2-9]|1[0-5])$ ]] ||
    die "LOCAL_STRATUM must be from 2 to 15 when ISP uses an upstream server"
[[ -n "$UPSTREAM_NTP" && "$UPSTREAM_NTP" != *[[:space:]]* ]] ||
    die "UPSTREAM_NTP is empty or contains spaces"
[[ -n "$NTP_ALLOW_NETWORK" && "$NTP_ALLOW_NETWORK" != *[[:space:]]* ]] ||
    die "NTP_ALLOW_NETWORK is empty or contains spaces"

UPSTREAM_MINSTRATUM=$((LOCAL_STRATUM - 1))

log "Installing chrony"
apt-get update
apt-get install -y chrony

temp_config="$(mktemp)"
trap 'rm -f -- "${temp_config:-}"' EXIT
cat > "$temp_config" <<EOF
# Managed by module_2/4/01-isp-chrony-server.sh
server $UPSTREAM_NTP iburst prefer minstratum $UPSTREAM_MINSTRATUM
local stratum $LOCAL_STRATUM
allow $NTP_ALLOW_NETWORK

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

log "Current tracking state"
tracking_output="$(chronyc tracking)"
printf '%s\n' "$tracking_output"

reported_stratum="$(awk -F: '/^[[:space:]]*Stratum/ {
    gsub(/[[:space:]]/, "", $2)
    print $2
}' <<< "$tracking_output")"

if [[ "$reported_stratum" != "$LOCAL_STRATUM" ]]; then
    log "WARNING: chronyd currently reports stratum ${reported_stratum:-unknown}; expected $LOCAL_STRATUM."
    log "The upstream source may still be collecting samples. Check again with: chronyc tracking"
fi

log "Chrony server configuration completed"
chronyc sources -v
