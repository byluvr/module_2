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

NFS_SERVER_IP="${NFS_SERVER_IP:?NFS_SERVER_IP is required in $ENV_FILE}"
NFS_EXPORT_PATH="${NFS_EXPORT_PATH:-/raid/nfs}"
NFS_CLIENT_MOUNT="${NFS_CLIENT_MOUNT:-/mnt/nfs}"
NFS_MOUNT_OPTIONS="${NFS_MOUNT_OPTIONS:-defaults,_netdev}"
NFS_TEST_FILE="${NFS_TEST_FILE:-test.txt}"
NFS_SOURCE="${NFS_SERVER_IP}:${NFS_EXPORT_PATH}"
FSTAB=/etc/fstab

log() {
    printf '[HQ-CLI NFS] %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die "run this script as root"
[[ "$NFS_CLIENT_MOUNT" == /* ]] ||
    die "NFS_CLIENT_MOUNT must be an absolute path"
[[ "$NFS_TEST_FILE" != */* && -n "$NFS_TEST_FILE" ]] ||
    die "NFS_TEST_FILE must be a file name without slashes"

log "Installing NFS client packages"
apt-get update
apt-get install -y nfs-utils nfs-clients

log "Checking network access to the server"
ping -c 1 -W 2 "$NFS_SERVER_IP" >/dev/null ||
    die "NFS server $NFS_SERVER_IP is unreachable"

log "Checking that the export is visible"
if ! showmount -e "$NFS_SERVER_IP" |
    awk -v path="$NFS_EXPORT_PATH" '$1 == path { found = 1 } END { exit !found }'; then
    showmount -e "$NFS_SERVER_IP" >&2 || true
    die "$NFS_EXPORT_PATH is not exported by $NFS_SERVER_IP"
fi

install -d -m 0777 "$NFS_CLIENT_MOUNT"
chmod 0777 "$NFS_CLIENT_MOUNT"

temp_file="$(mktemp)"
trap 'rm -f -- "${temp_file:-}"' EXIT
awk -v source="$NFS_SOURCE" -v mount_point="$NFS_CLIENT_MOUNT" '
    /^[[:space:]]*#/ || NF == 0 {
        print
        next
    }
    $1 == source || $2 == mount_point {
        next
    }
    { print }
' "$FSTAB" > "$temp_file"

printf '%s %s nfs %s 0 0\n' \
    "$NFS_SOURCE" "$NFS_CLIENT_MOUNT" "$NFS_MOUNT_OPTIONS" >> "$temp_file"

log "Updating $FSTAB"
install -m 0644 "$temp_file" "$FSTAB"
rm -f -- "$temp_file"
trap - EXIT

if mountpoint -q "$NFS_CLIENT_MOUNT"; then
    mounted_source="$(findmnt -nro SOURCE --target "$NFS_CLIENT_MOUNT")"
    if [[ "$mounted_source" != "$NFS_SOURCE" ]]; then
        mounted_type="$(findmnt -nro FSTYPE --target "$NFS_CLIENT_MOUNT")"
        [[ "$mounted_type" == nfs || "$mounted_type" == nfs4 ]] ||
            die "$NFS_CLIENT_MOUNT is occupied by $mounted_source ($mounted_type)"
        log "Remounting after a source change"
        umount "$NFS_CLIENT_MOUNT"
        mount "$NFS_CLIENT_MOUNT"
    fi
else
    log "Mounting $NFS_CLIENT_MOUNT"
    mount "$NFS_CLIENT_MOUNT"
fi

findmnt --mountpoint "$NFS_CLIENT_MOUNT" >/dev/null ||
    die "$NFS_CLIENT_MOUNT is not mounted"

log "Checking write access"
printf 'NFS write test from %s at %s\n' \
    "$(hostname -f 2>/dev/null || hostname)" "$(date --iso-8601=seconds)" \
    > "$NFS_CLIENT_MOUNT/$NFS_TEST_FILE"

log "NFS client configuration completed"
findmnt "$NFS_CLIENT_MOUNT"
df -hT "$NFS_CLIENT_MOUNT"
ls -l "$NFS_CLIENT_MOUNT/$NFS_TEST_FILE"
