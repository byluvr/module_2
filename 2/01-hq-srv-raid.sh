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

RAID_NAME="${RAID_NAME:-md0}"
RAID_LEVEL="${RAID_LEVEL:-0}"
RAID_DISKS="${RAID_DISKS:-}"
EXPECTED_DISK_SIZE_GIB="${EXPECTED_DISK_SIZE_GIB:-1}"
CREATE_PARTITION="${CREATE_PARTITION:-yes}"
MOUNT_POINT="${MOUNT_POINT:-/raid}"
FILESYSTEM="${FILESYSTEM:-ext4}"
ERASE_DISKS="${ERASE_DISKS:-no}"

RAID_NAME="${RAID_NAME#/dev/}"
RAID_DEVICE="/dev/$RAID_NAME"
RAID_PARTITION="${RAID_DEVICE}p1"
MDADM_CONFIG=/etc/mdadm.conf
FSTAB=/etc/fstab

read -r -a DISKS <<< "$RAID_DISKS"

log() {
    printf '[HQ-SRV RAID] %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

backup_file() {
    local file="$1"
    local backup_dir=/root/module_2_task_2_backups

    [[ -e "$file" ]] || return 0
    install -d -m 0700 "$backup_dir"
    cp -a -- "$file" "$backup_dir/$(basename "$file").$(date +%Y%m%d%H%M%S)"
}

normalize_devices() {
    local device

    for device in "$@"; do
        readlink -f "$device"
    done | sort -u | tr '\n' ' '
}

check_disk_mounts_before_rebuild() {
    local disk
    local mount_point

    for disk in "$@"; do
        while IFS= read -r mount_point; do
            [[ -n "$mount_point" ]] || continue
            [[ "$mount_point" == "$MOUNT_POINT" ]] ||
                die "$disk is used by an unexpected mount point: $mount_point"
        done < <(lsblk -nrpo MOUNTPOINT "$disk" | awk 'NF')
    done
}

write_mdadm_config() {
    local array_line="$1"
    local temp_file
    temp_file="$(mktemp)"

    if [[ -f "$MDADM_CONFIG" ]]; then
        awk -v device="$RAID_DEVICE" '
            !(toupper($1) == "ARRAY" && $2 == device)
        ' "$MDADM_CONFIG" > "$temp_file"
    fi

    printf '%s\n' "$array_line" >> "$temp_file"
    backup_file "$MDADM_CONFIG"
    install -m 0644 "$temp_file" "$MDADM_CONFIG"
    rm -f -- "$temp_file"
}

write_fstab() {
    local uuid="$1"
    local filesystem_device="$2"
    local temp_file
    temp_file="$(mktemp)"

    awk -v mount_point="$MOUNT_POINT" \
        -v raid_device="$RAID_DEVICE" \
        -v filesystem_device="$filesystem_device" '
        /^[[:space:]]*#/ || NF == 0 {
            print
            next
        }
        $1 == raid_device || $1 == filesystem_device || $2 == mount_point {
            next
        }
        { print }
    ' "$FSTAB" > "$temp_file"

    printf 'UUID=%s %s %s defaults 0 2\n' \
        "$uuid" "$MOUNT_POINT" "$FILESYSTEM" >> "$temp_file"

    backup_file "$FSTAB"
    install -m 0644 "$temp_file" "$FSTAB"
    rm -f -- "$temp_file"
}

[[ $EUID -eq 0 ]] || die "run this script as root"
[[ "$RAID_NAME" =~ ^md[0-9]+$ ]] ||
    die "RAID_NAME must look like md0 or md1"
[[ "$RAID_LEVEL" =~ ^(0|1|5)$ ]] ||
    die "RAID_LEVEL must be 0, 1 or 5"
[[ "$CREATE_PARTITION" =~ ^(yes|no)$ ]] ||
    die "CREATE_PARTITION must be yes or no"
[[ "$FILESYSTEM" == ext4 ]] ||
    die "this task requires FILESYSTEM=ext4"
[[ "$MOUNT_POINT" == /* ]] ||
    die "MOUNT_POINT must be an absolute path"
[[ "$EXPECTED_DISK_SIZE_GIB" =~ ^[0-9]+$ ]] ||
    die "EXPECTED_DISK_SIZE_GIB must be a non-negative integer"
(( ${#DISKS[@]} >= 2 )) ||
    die "RAID_DISKS must contain at least two devices"

case "$RAID_LEVEL" in
    0|1)
        (( ${#DISKS[@]} >= 2 )) ||
            die "RAID $RAID_LEVEL requires at least two disks"
        ;;
    5)
        (( ${#DISKS[@]} >= 3 )) ||
            die "RAID 5 requires at least three disks"
        ;;
esac

declare -A seen_disks=()
for disk in "${DISKS[@]}"; do
    [[ "$disk" == /dev/* ]] ||
        die "disk '$disk' must be specified as an absolute /dev path"
    [[ -b "$disk" ]] ||
        die "$disk is not a block device"
    [[ "$(lsblk -dnro TYPE "$disk")" == disk ]] ||
        die "$disk is not a whole disk"
    [[ -z "${seen_disks[$disk]:-}" ]] ||
        die "$disk is listed more than once"
    seen_disks["$disk"]=1

    if (( EXPECTED_DISK_SIZE_GIB > 0 )); then
        disk_size="$(blockdev --getsize64 "$disk")"
        expected_size=$((EXPECTED_DISK_SIZE_GIB * 1024 * 1024 * 1024))
        lower_bound=$((expected_size * 90 / 100))
        upper_bound=$((expected_size * 110 / 100))

        if (( disk_size < lower_bound || disk_size > upper_bound )); then
            die "$disk has $disk_size bytes; expected about ${EXPECTED_DISK_SIZE_GIB} GiB"
        fi
    fi
done

log "Installing RAID and filesystem tools"
apt-get update
apt-get install -y mdadm e2fsprogs util-linux

log "Selected configuration"
printf '  RAID device: %s\n' "$RAID_DEVICE"
printf '  RAID level:  %s\n' "$RAID_LEVEL"
printf '  Disks:       %s\n' "${DISKS[*]}"
printf '  Partition:   %s\n' "$CREATE_PARTITION"
printf '  Mount point: %s\n' "$MOUNT_POINT"

array_exists=no
rebuild_required=no
rebuild_reasons=()
current_members=()

if mdadm --detail "$RAID_DEVICE" >/dev/null 2>&1; then
    array_exists=yes
    current_level="$(mdadm --detail "$RAID_DEVICE" |
        awk -F: '/Raid Level/ { gsub(/[[:space:]]/, "", $2); sub(/^raid/, "", $2); print $2 }')"
    current_device_count="$(mdadm --detail "$RAID_DEVICE" |
        awk -F: '/Raid Devices/ { gsub(/[[:space:]]/, "", $2); print $2; exit }')"

    while read -r member; do
        [[ -n "$member" ]] || continue
        current_members+=("$(readlink -f "$member")")
    done < <(
        mdadm --detail "$RAID_DEVICE" |
            awk '$NF ~ "^/dev/" { print $NF }'
    )

    desired_members_normalized="$(normalize_devices "${DISKS[@]}")"
    current_members_normalized="$(normalize_devices "${current_members[@]}")"

    if [[ "$current_level" != "$RAID_LEVEL" ]]; then
        rebuild_required=yes
        rebuild_reasons+=("level: RAID $current_level -> RAID $RAID_LEVEL")
    fi

    if [[ "$current_device_count" != "${#DISKS[@]}" ]]; then
        rebuild_required=yes
        rebuild_reasons+=("device count: $current_device_count -> ${#DISKS[@]}")
    fi

    if [[ "$current_members_normalized" != "$desired_members_normalized" ]]; then
        rebuild_required=yes
        rebuild_reasons+=("member disks changed")
    fi

    if [[ "$CREATE_PARTITION" == yes ]]; then
        if [[ ! -b "$RAID_PARTITION" ]] &&
            [[ -n "$(blkid -o value -s TYPE "$RAID_DEVICE" 2>/dev/null || true)" ]]; then
            rebuild_required=yes
            rebuild_reasons+=("layout: filesystem on array -> partitioned array")
        fi
    elif lsblk -nrpo TYPE "$RAID_DEVICE" | grep -qx part; then
        rebuild_required=yes
        rebuild_reasons+=("layout: partitioned array -> filesystem on array")
    fi

    if [[ "$rebuild_required" == no ]]; then
        log "$RAID_DEVICE already matches .env; keeping the array and its data"
    fi
fi

if [[ "$array_exists" == no || "$rebuild_required" == yes ]]; then
    [[ "$ERASE_DISKS" == yes ]] ||
        die "creation or rebuilding is required, but ERASE_DISKS is not yes"

    if [[ "$rebuild_required" == yes ]]; then
        log "The existing array does not match .env and will be rebuilt"
        printf '  Reason: %s\n' "${rebuild_reasons[@]}"
    fi

    cleanup_disks=("${DISKS[@]}" "${current_members[@]}")
    cleanup_disks_normalized=()
    while read -r disk; do
        [[ -n "$disk" ]] || continue
        cleanup_disks_normalized+=("$disk")
    done < <(
        for disk in "${cleanup_disks[@]}"; do
            readlink -f "$disk"
        done | sort -u
    )

    check_disk_mounts_before_rebuild "${cleanup_disks_normalized[@]}"

    if mountpoint -q "$MOUNT_POINT"; then
        mounted_source="$(findmnt -nro SOURCE --target "$MOUNT_POINT")"
        if ! lsblk -s -nrpo NAME "$mounted_source" | grep -Fqx "$RAID_DEVICE"; then
            die "$MOUNT_POINT is not mounted from $RAID_DEVICE"
        fi
        log "Unmounting $MOUNT_POINT before rebuilding"
        umount "$MOUNT_POINT"
    fi

    if [[ "$array_exists" == yes ]]; then
        log "Stopping the old array"
        [[ -b "$RAID_PARTITION" ]] &&
            wipefs --all --force "$RAID_PARTITION" >/dev/null 2>&1 || true
        wipefs --all --force "$RAID_DEVICE" >/dev/null 2>&1 || true
        mdadm --stop "$RAID_DEVICE"
        udevadm settle
        array_exists=no
    fi

    log "Erasing old RAID metadata and filesystem signatures"
    for disk in "${cleanup_disks_normalized[@]}"; do
        mdadm --zero-superblock --force "$disk" >/dev/null 2>&1 || true
        wipefs --all --force "$disk"
    done

    log "Creating RAID $RAID_LEVEL on $RAID_DEVICE"
    mdadm --create --verbose "$RAID_DEVICE" \
        --level="$RAID_LEVEL" \
        --raid-devices="${#DISKS[@]}" \
        --force \
        "${DISKS[@]}"
    udevadm settle
    array_exists=yes
fi

array_line="$(mdadm --detail --brief "$RAID_DEVICE" | head -n 1)"
[[ -n "$array_line" ]] ||
    die "mdadm did not return a configuration line for $RAID_DEVICE"

log "Saving the array configuration in $MDADM_CONFIG"
write_mdadm_config "$array_line"

if [[ "$CREATE_PARTITION" == yes ]]; then
    filesystem_device="$RAID_PARTITION"

    if [[ ! -b "$filesystem_device" ]]; then
        array_filesystem="$(blkid -o value -s TYPE "$RAID_DEVICE" 2>/dev/null || true)"
        [[ -z "$array_filesystem" ]] ||
            die "$RAID_DEVICE already contains $array_filesystem directly; set CREATE_PARTITION=no"

        [[ "$ERASE_DISKS" == yes ]] ||
            die "$filesystem_device is absent and partition creation is disabled by ERASE_DISKS=no"

        log "Creating one GPT partition on $RAID_DEVICE"
        printf 'label: gpt\n, , L\n' | sfdisk "$RAID_DEVICE"
        blockdev --rereadpt "$RAID_DEVICE" || true
        udevadm settle
    else
        log "$filesystem_device already exists; keeping the partition"
    fi
else
    if lsblk -nrpo TYPE "$RAID_DEVICE" | grep -qx part; then
        die "$RAID_DEVICE already has partitions; set CREATE_PARTITION=yes"
    fi
    filesystem_device="$RAID_DEVICE"
fi

[[ -b "$filesystem_device" ]] ||
    die "filesystem device $filesystem_device was not created"

existing_filesystem="$(blkid -o value -s TYPE "$filesystem_device" 2>/dev/null || true)"
if [[ -z "$existing_filesystem" ]]; then
    [[ "$ERASE_DISKS" == yes ]] ||
        die "$filesystem_device is not formatted and ERASE_DISKS=no"
    log "Creating ext4 on $filesystem_device"
    mkfs.ext4 -F "$filesystem_device"
elif [[ "$existing_filesystem" != "$FILESYSTEM" ]]; then
    [[ "$ERASE_DISKS" == yes ]] ||
        die "$filesystem_device contains $existing_filesystem; ERASE_DISKS=yes is required to replace it"
    log "Replacing $existing_filesystem with $FILESYSTEM on $filesystem_device"
    mkfs.ext4 -F "$filesystem_device"
else
    log "$filesystem_device already contains $FILESYSTEM"
fi

filesystem_uuid="$(blkid -o value -s UUID "$filesystem_device")"
[[ -n "$filesystem_uuid" ]] ||
    die "cannot read the filesystem UUID from $filesystem_device"

log "Configuring automatic mounting"
mkdir -p "$MOUNT_POINT"
write_fstab "$filesystem_uuid" "$filesystem_device"

if mountpoint -q "$MOUNT_POINT"; then
    mounted_source="$(findmnt -nro SOURCE --target "$MOUNT_POINT")"
    [[ "$(readlink -f "$mounted_source")" == "$(readlink -f "$filesystem_device")" ]] ||
        die "$MOUNT_POINT is mounted from unexpected source $mounted_source"
else
    mount "$MOUNT_POINT"
fi

log "Verifying the result"
mdadm --detail "$RAID_DEVICE"
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINT "$RAID_DEVICE"
df -hT "$MOUNT_POINT"
findmnt --verify --verbose

log "RAID storage configuration completed"
