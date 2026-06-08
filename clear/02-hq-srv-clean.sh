#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/00-clean-common.sh"

prepare_cleanup HQ-SRV
remove_artifacts \
    /root/module_2_task_2_backups \
    /root/module_2_task_3_backups \
    /root/module_2_task_3_nfs_report.txt \
    /root/module_2_task_4_backups \
    /root/module_2_task_7_web_report.txt
unmount_additional_iso
finish_cleanup
