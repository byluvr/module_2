#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root to display all block-device information." >&2
    exit 1
fi

echo "Block devices:"
lsblk -e 7 -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL

echo
echo "Unpartitioned 1 GiB disk candidates:"
while read -r name size type; do
    [[ "$type" == disk ]] || continue
    ((size >= 900000000 && size <= 1200000000)) || continue

    if [[ "$(lsblk -nr "$name" | wc -l)" -eq 1 ]]; then
        printf '  %s (%s bytes)\n' "$name" "$size"
    fi
done < <(lsblk -bdnrpo NAME,SIZE,TYPE)

echo
echo "Specify the required devices explicitly in RAID_DISKS inside .env."
