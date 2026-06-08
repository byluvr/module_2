#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/00-clean-common.sh"

prepare_cleanup ISP
remove_artifacts \
    /root/module_2_task_4_backups \
    /root/module_2_task_4_chrony_report.txt \
    /root/module_2_task_9_10_backups
finish_cleanup
