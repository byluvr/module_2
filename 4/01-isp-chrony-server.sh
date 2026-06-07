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

UPSTREAM_NTP="${UPSTREAM_NTP:-ntp0.ntp-servers.net}"
LOCAL_STRATUM="${LOCAL_STRATUM:-5}"
NTP_ALLOW_NETWORK="${NTP_ALLOW_NETWORK:-0.0.0.0/0}"
CHRONY_CONFIG=/etc/chrony.conf
BACKUP_DIR=/root/module_2_task_4_backups
REPORT_FILE=/root/module_2_task_4_chrony_report.txt

log() {
    printf '[ISP chrony] %s\n' "$*"
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
    backup_file "$CHRONY_CONFIG"
    install -m 0644 "$temp_config" "$CHRONY_CONFIG"
fi
rm -f -- "$temp_config"

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

log "Writing parameters for the report"
{
    printf 'Module 2, task 4 - chrony server on ISP\n'
    printf 'Upstream NTP: %s\n' "$UPSTREAM_NTP"
    printf 'Upstream minstratum: %s\n' "$UPSTREAM_MINSTRATUM"
    printf 'Local stratum: %s\n' "$LOCAL_STRATUM"
    printf 'Allowed clients: %s\n' "$NTP_ALLOW_NETWORK"
    printf '\nConfiguration:\n'
    cat "$CHRONY_CONFIG"
    printf '\nTracking:\n'
    chronyc tracking
    printf '\nSources:\n'
    chronyc sources -v
} > "$REPORT_FILE"
chmod 0600 "$REPORT_FILE"

log "Chrony server configuration completed"
printf 'Report data: %s\n' "$REPORT_FILE"
chronyc sources -v
