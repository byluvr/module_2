#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || {
    echo "ERROR: run this script as root" >&2
    exit 1
}

cd /etc/ansible
ansible -m ping all

