#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/00-clean-common.sh"

prepare_cleanup BR-SRV
remove_artifacts \
    /root/module_2_task_4_backups \
    /root/module_2_task_5_backups
unmount_additional_iso
finish_cleanup
