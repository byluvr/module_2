#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/00-clean-common.sh"

prepare_cleanup HQ-CLI
remove_artifacts \
    /root/sudoers-backups \
    /root/module_2_task_3_backups \
    /root/module_2_task_4_backups \
    /root/module_2_task_5_backups
remove_nfs_test_file
finish_cleanup
