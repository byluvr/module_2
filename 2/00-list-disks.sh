#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die "run this script as root"

if [[ ! -f "$ENV_FILE" ]]; then
    [[ -f "$ENV_EXAMPLE" ]] ||
        die "$ENV_FILE and $ENV_EXAMPLE are missing"
    cp -- "$ENV_EXAMPLE" "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
    echo "Created $ENV_FILE from .env.example"
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

EXPECTED_DISK_SIZE_GIB="${EXPECTED_DISK_SIZE_GIB:-1}"
RAID_LEVEL="${RAID_LEVEL:-0}"

[[ "$EXPECTED_DISK_SIZE_GIB" =~ ^[1-9][0-9]*$ ]] ||
    die "EXPECTED_DISK_SIZE_GIB must be a positive integer for automatic selection"
[[ "$RAID_LEVEL" =~ ^(0|1|5)$ ]] ||
    die "RAID_LEVEL must be 0, 1 or 5"

echo "Block devices:"
lsblk -e 7 -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL

echo
echo "Searching for unused disks of about ${EXPECTED_DISK_SIZE_GIB} GiB..."

expected_size=$((EXPECTED_DISK_SIZE_GIB * 1024 * 1024 * 1024))
lower_bound=$((expected_size * 90 / 100))
upper_bound=$((expected_size * 110 / 100))

declare -A system_disks=()
while read -r source; do
    [[ -n "$source" ]] || continue
    source="$(readlink -f "$source" 2>/dev/null || printf '%s' "$source")"

    parent="$source"
    while [[ -n "$parent" ]]; do
        parent_name="$(lsblk -dnro PKNAME "$parent" 2>/dev/null || true)"
        if [[ -z "$parent_name" ]]; then
            if [[ "$(lsblk -dnro TYPE "$parent" 2>/dev/null || true)" == disk ]]; then
                system_disks["$parent"]=1
            fi
            break
        fi
        parent="/dev/$parent_name"
    done
done < <(
    findmnt -rn -o SOURCE,TARGET |
        awk '$2 == "/" || $2 == "/boot" || $2 == "/boot/efi" { print $1 }' |
        sort -u
)

candidates=()
while read -r name size type; do
    [[ "$type" == disk ]] || continue
    ((size >= lower_bound && size <= upper_bound)) || continue
    [[ -z "${system_disks[$name]:-}" ]] || continue

    if lsblk -nrpo MOUNTPOINT "$name" | grep -q '[^[:space:]]'; then
        continue
    fi

    if [[ "$(lsblk -nr "$name" | wc -l)" -eq 1 ]]; then
        candidates+=("$name")
    fi
done < <(lsblk -bdnrpo NAME,SIZE,TYPE)

minimum_disks=2
if [[ "$RAID_LEVEL" == 5 ]]; then
    minimum_disks=3
fi

if (( ${#candidates[@]} < minimum_disks )); then
    die "found ${#candidates[@]} suitable disks; RAID $RAID_LEVEL requires at least $minimum_disks"
fi

printf 'Selected disks: %s\n' "${candidates[*]}"

temp_file="$(mktemp)"
awk -v disks="${candidates[*]}" '
    BEGIN {
        disks_replaced = 0
        erase_replaced = 0
    }
    /^RAID_DISKS=/ {
        print "RAID_DISKS=\"" disks "\""
        disks_replaced = 1
        next
    }
    /^ERASE_DISKS=/ {
        print "ERASE_DISKS=no"
        erase_replaced = 1
        next
    }
    { print }
    END {
        if (!disks_replaced)
            print "RAID_DISKS=\"" disks "\""
        if (!erase_replaced)
            print "ERASE_DISKS=no"
    }
' "$ENV_FILE" > "$temp_file"

install -m 0600 "$temp_file" "$ENV_FILE"
rm -f -- "$temp_file"

echo
echo "Updated RAID_DISKS in $ENV_FILE"
grep '^RAID_DISKS=' "$ENV_FILE"
echo
echo "ERASE_DISKS was reset to no. Review the selected disks before enabling erasure."
