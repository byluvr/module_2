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

NFS_SERVER_IP="${NFS_SERVER_IP:-192.168.1.10}"
HQ_CLI_SUBNET="${HQ_CLI_SUBNET:-192.168.2.0/24}"
NFS_EXPORT_PATH="${NFS_EXPORT_PATH:-/raid/nfs}"
NFS_EXPORT_OPTIONS="${NFS_EXPORT_OPTIONS:-rw,sync,no_subtree_check,no_root_squash}"
EXPORTS_FILE=/etc/exports
REPORT_FILE=/root/module_2_task_3_nfs_report.txt

log() {
    printf '[HQ-SRV NFS] %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

backup_file() {
    local file="$1"
    local backup_dir=/root/module_2_task_3_backups

    [[ -e "$file" ]] || return 0
    install -d -m 0700 "$backup_dir"
    cp -a -- "$file" "$backup_dir/$(basename "$file").$(date +%Y%m%d%H%M%S)"
}

select_nfs_service() {
    local service

    for service in nfs-server nfs; do
        if systemctl list-unit-files "${service}.service" --no-legend 2>/dev/null |
            grep -q "^${service}\.service"; then
            printf '%s\n' "$service"
            return 0
        fi
    done

    return 1
}

[[ $EUID -eq 0 ]] || die "run this script as root"
[[ "$NFS_EXPORT_PATH" == /raid/* ]] ||
    die "NFS_EXPORT_PATH must be located below /raid"
[[ "$HQ_CLI_SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] ||
    die "HQ_CLI_SUBNET must be an IPv4 network in CIDR notation"
[[ "$NFS_EXPORT_OPTIONS" != *[[:space:]]* ]] ||
    die "NFS_EXPORT_OPTIONS must not contain spaces"

log "Checking the RAID mount"
findmnt --mountpoint /raid >/dev/null ||
    die "/raid is not mounted; complete module 2 task 2 first"

log "Installing NFS server packages"
apt-get update
apt-get install -y nfs-server nfs-utils

log "Creating the export directory"
install -d -m 0777 "$NFS_EXPORT_PATH"
chmod 0777 "$NFS_EXPORT_PATH"

temp_file="$(mktemp)"
if [[ -f "$EXPORTS_FILE" ]]; then
    awk -v export_path="$NFS_EXPORT_PATH" '
        /^[[:space:]]*#/ || NF == 0 {
            print
            next
        }
        $1 == export_path {
            next
        }
        { print }
    ' "$EXPORTS_FILE" > "$temp_file"
fi

printf '%s %s(%s)\n' \
    "$NFS_EXPORT_PATH" "$HQ_CLI_SUBNET" "$NFS_EXPORT_OPTIONS" >> "$temp_file"

log "Updating $EXPORTS_FILE"
backup_file "$EXPORTS_FILE"
install -m 0644 "$temp_file" "$EXPORTS_FILE"
rm -f -- "$temp_file"

if command -v control >/dev/null 2>&1 &&
    control rpcbind >/dev/null 2>&1; then
    log "Enabling rpcbind server mode"
    control rpcbind server
fi

nfs_service="$(select_nfs_service)" ||
    die "NFS systemd service was not found after package installation"

log "Starting $nfs_service"
systemctl enable --now "$nfs_service"

log "Applying exports"
exportfs -rav

if ! exportfs -v | awk -v path="$NFS_EXPORT_PATH" -v subnet="$HQ_CLI_SUBNET" '
    $1 == path { found_path = 1 }
    found_path && index($0, subnet) { found_network = 1 }
    END { exit !(found_path && found_network) }
'; then
    exportfs -v >&2
    die "$NFS_EXPORT_PATH is not exported to $HQ_CLI_SUBNET"
fi

log "Writing parameters for the report"
{
    printf 'Module 2, task 3 - NFS server\n'
    printf 'Server: %s (%s)\n' "$(hostname -f 2>/dev/null || hostname)" "$NFS_SERVER_IP"
    printf 'Export path: %s\n' "$NFS_EXPORT_PATH"
    printf 'Allowed network: %s\n' "$HQ_CLI_SUBNET"
    printf 'Export options: %s\n' "$NFS_EXPORT_OPTIONS"
    printf 'Service: %s\n' "$nfs_service"
    printf '\n/etc/exports:\n'
    grep -F "$NFS_EXPORT_PATH" "$EXPORTS_FILE"
    printf '\nActive exports:\n'
    exportfs -v
    printf '\nFilesystem:\n'
    findmnt -T "$NFS_EXPORT_PATH"
} > "$REPORT_FILE"
chmod 0600 "$REPORT_FILE"

log "NFS server configuration completed"
printf 'Report data: %s\n' "$REPORT_FILE"
exportfs -v

