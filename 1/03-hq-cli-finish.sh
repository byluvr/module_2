#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
else
    echo "ERROR: $ENV_FILE not found." >&2
    exit 1
fi

DOMAIN_FQDN="${DOMAIN_FQDN:-au-team.irpo}"
HQ_GROUP="${HQ_GROUP:-hq}"
HQ_USER_PREFIX="${HQ_USER_PREFIX:-hquser}"
SUDOERS_FILE="/etc/sudoers.d/50-hq-limited"

log() {
    printf '[HQ-CLI finish] %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

disable_unrestricted_wheel_rules() {
    local file="$1"
    local line
    local changed=no
    local temp_file
    local rule_re

    rule_re='^[[:space:]]*(%wheel|WHEEL_USERS)[[:space:]]+ALL[[:space:]]*=[[:space:]]*\([^)]*\)[[:space:]]*(NOPASSWD:[[:space:]]*)?ALL[[:space:]]*(#.*)?$'
    temp_file="$(mktemp)"
    trap 'rm -f -- "${temp_file:-}"' RETURN

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $rule_re ]]; then
            printf '# Disabled by module_2/1/03-hq-cli-finish.sh\n' >> "$temp_file"
            printf '# %s\n' "$line" >> "$temp_file"
            changed=yes
        else
            printf '%s\n' "$line" >> "$temp_file"
        fi
    done < "$file"

    if [[ "$changed" == yes ]]; then
        install -m 0440 "$temp_file" "$file"
        log "Disabled an unrestricted wheel rule in $file"
    fi

    rm -f -- "$temp_file"
    trap - RETURN
}

[[ $EUID -eq 0 ]] || die "run this script as root"

log "Installing required local packages"
apt-get install -y libnss-role sudo

log "Checking that domain users are visible through NSS"
test_user="${HQ_USER_PREFIX}1"
resolved_user=""
for candidate in "$test_user" "$test_user@$DOMAIN_FQDN"; do
    if getent passwd "$candidate" >/dev/null 2>&1; then
        resolved_user="$candidate"
        break
    fi
done

[[ -n "$resolved_user" ]] ||
    die "domain user $test_user is not visible; check the domain join, SSSD and DNS"

log "Ensuring the NSS role module is enabled"
role_status="$(control libnss-role 2>/dev/null || true)"
if [[ "$role_status" != enabled ]]; then
    control libnss-role enabled
fi

role_status="$(control libnss-role 2>/dev/null || true)"
[[ "$role_status" == enabled ]] ||
    die "libnss-role status is '$role_status'; check that 'role' is last in the group line of /etc/nsswitch.conf"

resolved_group=""
for candidate in "$HQ_GROUP" "$HQ_GROUP@$DOMAIN_FQDN"; do
    if getent group "$candidate" >/dev/null 2>&1; then
        resolved_group="$candidate"
        break
    fi
done

[[ -n "$resolved_group" ]] ||
    die "domain group $HQ_GROUP is not visible through NSS"

mapping_exists=no
while IFS=: read -r role privileges; do
    if [[ "$role" == "$resolved_group" && ",${privileges//[[:space:]]/}," == *,wheel,* ]]; then
        mapping_exists=yes
        break
    fi
done < <(rolelst 2>/dev/null || true)

if [[ "$mapping_exists" != yes ]]; then
    log "Mapping domain group $resolved_group to the local wheel role"
    roleadd "$resolved_group" wheel
else
    log "Role mapping $resolved_group -> wheel already exists"
fi

log "Writing the restricted sudo rule"
install -d -m 0750 /etc/sudoers.d
cat > "$SUDOERS_FILE" <<'EOF'
Cmnd_Alias HQ_LIMITED = /bin/cat, /usr/bin/cat, /bin/grep, /usr/bin/grep, /bin/id, /usr/bin/id
%wheel ALL=(ALL:ALL) NOPASSWD: HQ_LIMITED
EOF
chmod 0440 "$SUDOERS_FILE"
visudo -cf /etc/sudoers

log "Disabling the standard unrestricted sudo rule for wheel"
if control sudowheel >/dev/null 2>&1; then
    control sudowheel disabled
elif grep -Eqi '^[[:space:]]*(WHEEL_USERS|%wheel)[[:space:]]+ALL=.*ALL[[:space:]]*$' /etc/sudoers; then
    die "an unrestricted wheel rule is active and control sudowheel is unavailable"
fi

log "Disabling unrestricted wheel rules in sudoers drop-ins"
shopt -s nullglob
for sudoers_dropin in /etc/sudoers.d/*; do
    [[ -f "$sudoers_dropin" ]] || continue
    [[ "$sudoers_dropin" == "$SUDOERS_FILE" ]] && continue
    disable_unrestricted_wheel_rules "$sudoers_dropin"
done
shopt -u nullglob

visudo -cf /etc/sudoers

log "Domain identity after role mapping"
id "$resolved_user"

log "Effective sudo policy for $resolved_user"
if ! sudo_policy="$(LC_ALL=C sudo -l -U "$resolved_user" 2>&1)"; then
    printf '%s\n' "$sudo_policy" >&2
    die "cannot read the effective sudo policy for $resolved_user"
fi
printf '%s\n' "$sudo_policy"

if grep -Eq '^[[:space:]]*\(ALL([[:space:]]*:[[:space:]]*ALL)?\)[[:space:]]+(NOPASSWD:[[:space:]]*)?ALL[[:space:]]*$' \
    <<< "$sudo_policy"; then
    die "an unrestricted sudo rule is still active for $resolved_user; inspect /etc/sudoers and /etc/sudoers.d"
fi

grep -Fq '/bin/cat' <<< "$sudo_policy" ||
    die "the restricted sudo command list is not effective for $resolved_user"

grep -Eq 'NOPASSWD:.*(/bin/cat|HQ_LIMITED)' <<< "$sudo_policy" ||
    die "NOPASSWD is not effective for the restricted command list"

cat <<EOF

Post-configuration completed.

Log out and log in as $resolved_user, then check:
  sudo /bin/cat /etc/hostname
  sudo /bin/grep PRETTY_NAME /etc/os-release
  sudo /usr/bin/id
  sudo /bin/bash

The first three commands must be allowed. The last command must be denied.
EOF
