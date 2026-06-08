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
REMOVE_NFS_TEST_FILE="${REMOVE_NFS_TEST_FILE:-yes}"
NFS_CLIENT_MOUNT="${NFS_CLIENT_MOUNT:-/mnt/nfs}"
NFS_TEST_FILE="${NFS_TEST_FILE:-test.txt}"
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
    validate_yes_no REMOVE_NFS_TEST_FILE "$REMOVE_NFS_TEST_FILE"
    validate_project_dir

    if [[ "$DELETE_PROJECT" == yes ]]; then
        current_dir="$(pwd -P)"
        if [[ "$current_dir" == "$PROJECT_DIR" ||
            "$current_dir" == "$PROJECT_DIR/"* ]]; then
            die "current directory is inside module_2; run from outside it, for example: cd /root"
        fi
    fi

    log "Removing generated automation artifacts only"
}

remove_artifacts() {
    local path

    for path in "$@"; do
        case "$path" in
            /root/module_2_task_* | /root/sudoers-backups)
                ;;
            *)
                die "refusing to remove an unexpected artifact path: $path"
                ;;
        esac

        if [[ -e "$path" || -L "$path" ]]; then
            log "Removing $path"
            rm -rf -- "$path"
        else
            log "Already absent: $path"
        fi
    done
}

remove_nfs_test_file() {
    local test_path

    [[ "$REMOVE_NFS_TEST_FILE" == yes ]] || return 0
    [[ "$NFS_CLIENT_MOUNT" == /* && "$NFS_CLIENT_MOUNT" != / ]] ||
        die "NFS_CLIENT_MOUNT must be a safe absolute path"
    [[ -n "$NFS_TEST_FILE" && "$NFS_TEST_FILE" != */* ]] ||
        die "NFS_TEST_FILE must be a file name without slashes"

    test_path="$NFS_CLIENT_MOUNT/$NFS_TEST_FILE"
    if mountpoint -q "$NFS_CLIENT_MOUNT"; then
        if [[ -f "$test_path" ]]; then
            log "Removing NFS test file $test_path"
            rm -f -- "$test_path"
        else
            log "NFS test file is already absent"
        fi
    else
        log "NFS is not mounted at $NFS_CLIENT_MOUNT; test file cleanup skipped"
    fi
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
