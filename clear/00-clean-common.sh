#!/usr/bin/env bash

CLEAR_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$CLEAR_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$CLEAR_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

DELETE_PROJECT="${DELETE_PROJECT:-yes}"
UNMOUNT_ADDITIONAL_ISO="${UNMOUNT_ADDITIONAL_ISO:-yes}"
ISO_MOUNT="${ISO_MOUNT:-/mnt}"
CLEANUP_ROLE=

log() {
    printf '[%s cleanup] %s\n' "$CLEANUP_ROLE" "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

validate_yes_no() {
    local name="$1"
    local value="$2"

    [[ "$value" == yes || "$value" == no ]] ||
        die "$name must be yes or no"
}

validate_project_dir() {
    local resolved_project

    resolved_project="$(readlink -f "$PROJECT_DIR")"
    [[ -n "$resolved_project" && "$resolved_project" != / ]] ||
        die "unsafe project path: $resolved_project"
    [[ "$(basename "$resolved_project")" == module_2 ]] ||
        die "project directory must be named module_2: $resolved_project"
    [[ -d "$resolved_project/clear" && -f "$resolved_project/clear/00-clean-common.sh" ]] ||
        die "module_2 cleanup marker was not found"
    [[ ! -L "$PROJECT_DIR" ]] ||
        die "refusing to remove a symlinked project directory"
}

prepare_cleanup() {
    local current_dir

    CLEANUP_ROLE="$1"

    [[ $EUID -eq 0 ]] || die "run this script as root"
    validate_yes_no DELETE_PROJECT "$DELETE_PROJECT"
    validate_yes_no UNMOUNT_ADDITIONAL_ISO "$UNMOUNT_ADDITIONAL_ISO"
    validate_project_dir

    if [[ "$DELETE_PROJECT" == yes ]]; then
        current_dir="$(pwd -P)"
        if [[ "$current_dir" == "$PROJECT_DIR" ||
            "$current_dir" == "$PROJECT_DIR/"* ]]; then
            die "current directory is inside module_2; run from outside it, for example: cd /root"
        fi
    fi

    log "Preparing project cleanup"
}

unmount_additional_iso() {
    local source
    local filesystem

    [[ "$UNMOUNT_ADDITIONAL_ISO" == yes ]] || return 0
    [[ "$ISO_MOUNT" == /* && "$ISO_MOUNT" != / ]] ||
        die "ISO_MOUNT must be a safe absolute path"

    if ! mountpoint -q "$ISO_MOUNT"; then
        log "$ISO_MOUNT is not mounted"
        return 0
    fi

    source="$(findmnt -nro SOURCE --target "$ISO_MOUNT")"
    filesystem="$(findmnt -nro FSTYPE --target "$ISO_MOUNT")"
    if [[ "$source" == /dev/sr* || "$filesystem" == iso9660 ]]; then
        log "Unmounting Additional.iso from $ISO_MOUNT"
        umount "$ISO_MOUNT"
    else
        log "Skipping $ISO_MOUNT: mounted from $source with filesystem $filesystem"
    fi
}

finish_cleanup() {
    if [[ "$DELETE_PROJECT" == yes ]]; then
        log "Removing project directory $PROJECT_DIR"
        cd /
        rm -rf -- "$PROJECT_DIR"
        [[ ! -e "$PROJECT_DIR" ]] ||
            die "project directory could not be removed"
        printf '[%s cleanup] Completed; configured services remain active\n' "$CLEANUP_ROLE"
    else
        log "Project removal disabled by DELETE_PROJECT=no"
        log "Cleanup completed; configured services remain active"
    fi
}
