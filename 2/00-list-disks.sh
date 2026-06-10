#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die "run this script as root"

if [[ ! -f "$ENV_FILE" ]]; then
    die "$ENV_FILE is missing"
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

EXPECTED_DISK_SIZE_GIB="${EXPECTED_DISK_SIZE_GIB:-1}"
RAID_LEVEL="${RAID_LEVEL:?RAID_LEVEL is required in $ENV_FILE}"
RAID_NAME="${RAID_NAME:?RAID_NAME is required in $ENV_FILE}"
RAID_NAME="${RAID_NAME#/dev/}"
RAID_DEVICE="/dev/$RAID_NAME"

[[ "$EXPECTED_DISK_SIZE_GIB" =~ ^[1-9][0-9]*$ ]] ||
    die "EXPECTED_DISK_SIZE_GIB must be a positive integer for automatic selection"
[[ "$RAID_LEVEL" =~ ^(0|1|5)$ ]] ||
    die "RAID_LEVEL must be 0, 1 or 5"
[[ "$RAID_NAME" =~ ^md[0-9]+$ ]] ||
    die "RAID_NAME must look like md0 or md1"

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
declare -A current_members=()
if command -v mdadm >/dev/null 2>&1 &&
    mdadm --detail "$RAID_DEVICE" >/dev/null 2>&1; then
    while read -r member_candidate; do
        [[ "$member_candidate" == /dev/* ]] || continue
        member="$(readlink -f "$member_candidate" 2>/dev/null || true)"
        [[ -b "$member" ]] || continue
        [[ "$(lsblk -dnro TYPE "$member" 2>/dev/null || true)" == disk ]] ||
            continue
        current_members["$member"]=1
    done < <(
        mdadm --detail "$RAID_DEVICE" |
            awk 'NF > 1 && $NF ~ "^/dev/" { print $NF }'
    )
fi

while read -r name size type; do
    [[ "$type" == disk ]] || continue
    ((size >= lower_bound && size <= upper_bound)) || continue
    [[ -z "${system_disks[$name]:-}" ]] || continue

    if [[ -n "${current_members[$name]:-}" ]]; then
        candidates+=("$name")
        continue
    fi

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
trap 'rm -f -- "${temp_file:-}"' EXIT
awk -v disks="${candidates[*]}" '
    BEGIN { disks_replaced = 0 }
    /^RAID_DISKS=/ {
        print "RAID_DISKS=\"" disks "\""
        disks_replaced = 1
        next
    }
    { print }
    END {
        if (!disks_replaced)
            print "RAID_DISKS=\"" disks "\""
    }
' "$ENV_FILE" > "$temp_file"

install -m 0600 "$temp_file" "$ENV_FILE"
rm -f -- "$temp_file"
trap - EXIT

echo
echo "Updated RAID_DISKS in $ENV_FILE"
grep '^RAID_DISKS=' "$ENV_FILE"
echo
