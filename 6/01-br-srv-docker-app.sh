#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
COMPOSE_FILE="$SCRIPT_DIR/compose.yaml"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
else
    echo "ERROR: $ENV_FILE not found." >&2
    exit 1
fi

ISO_DEVICE="${ISO_DEVICE:-/dev/sr0}"
ISO_MOUNT="${ISO_MOUNT:-/mnt}"
APP_IMAGE_ARCHIVE="${APP_IMAGE_ARCHIVE:-docker/site_latest.tar}"
DB_IMAGE_ARCHIVE="${DB_IMAGE_ARCHIVE:-docker/mariadb_latest.tar}"
APP_IMAGE="${APP_IMAGE:-site:latest}"
DB_IMAGE="${DB_IMAGE:-mariadb:10.11}"
APP_CONTAINER_NAME="${APP_CONTAINER_NAME:-tespapp}"
DB_CONTAINER_NAME="${DB_CONTAINER_NAME:-db}"
APP_PORT="${APP_PORT:?APP_PORT is required in $ENV_FILE}"
APP_INTERNAL_PORT="${APP_INTERNAL_PORT:?APP_INTERNAL_PORT is required in $ENV_FILE}"
DB_PORT="${DB_PORT:?DB_PORT is required in $ENV_FILE}"
DB_NAME="${DB_NAME:-testdb}"
DB_USER="${DB_USER:-testc}"
DB_PASSWORD="${DB_PASSWORD:-P@ssw0rd}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-toor}"
DB_TYPE="${DB_TYPE:-maria}"

log() {
    printf '[BR-SRV Docker] %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

validate_port() {
    local name="$1"
    local value="$2"

    [[ "$value" =~ ^[0-9]+$ ]] &&
        (( value >= 1 && value <= 65535 )) ||
        die "$name must be from 1 to 65535"
}

validate_name() {
    local name="$1"
    local value="$2"

    [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] ||
        die "$name contains characters unsupported by Docker or MariaDB"
}

load_image() {
    local archive="$1"
    local target_image="$2"
    local load_output loaded_reference loaded_id

    [[ -f "$archive" ]] || die "image archive not found: $archive"

    log "Loading $archive"
    load_output="$(docker load --input "$archive")"
    printf '%s\n' "$load_output"

    loaded_reference="$(
        sed -n 's/^Loaded image: //p' <<< "$load_output" | tail -n 1
    )"
    loaded_id="$(
        sed -n 's/^Loaded image ID: //p' <<< "$load_output" | tail -n 1
    )"

    if [[ -n "$loaded_reference" ]]; then
        if [[ "$loaded_reference" != "$target_image" ]]; then
            log "Tagging $loaded_reference as $target_image"
            docker tag "$loaded_reference" "$target_image"
        fi
    elif [[ -n "$loaded_id" ]]; then
        log "Tagging $loaded_id as $target_image"
        docker tag "$loaded_id" "$target_image"
    elif docker image inspect "$target_image" >/dev/null 2>&1; then
        log "Image $target_image is available"
    else
        die "the archive was loaded, but image $target_image could not be identified"
    fi
}

[[ $EUID -eq 0 ]] || die "run this script as root"
[[ -f "$COMPOSE_FILE" ]] || die "$COMPOSE_FILE not found"
validate_port APP_PORT "$APP_PORT"
validate_port APP_INTERNAL_PORT "$APP_INTERNAL_PORT"
validate_port DB_PORT "$DB_PORT"
validate_name APP_CONTAINER_NAME "$APP_CONTAINER_NAME"
validate_name DB_CONTAINER_NAME "$DB_CONTAINER_NAME"
validate_name DB_NAME "$DB_NAME"
validate_name DB_USER "$DB_USER"
[[ "$APP_CONTAINER_NAME" != "$DB_CONTAINER_NAME" ]] ||
    die "APP_CONTAINER_NAME and DB_CONTAINER_NAME must be different"
[[ -n "$DB_PASSWORD" ]] || die "DB_PASSWORD must not be empty"
[[ -n "$DB_ROOT_PASSWORD" ]] || die "DB_ROOT_PASSWORD must not be empty"

log "Installing Docker and Compose"
apt-get update
apt-get install -y docker-engine docker-compose-v2

log "Enabling Docker"
systemctl enable --now docker.service
systemctl is-active --quiet docker.service || die "docker.service is not running"

install -d -m 0755 "$ISO_MOUNT"
if ! mountpoint -q "$ISO_MOUNT"; then
    [[ -b "$ISO_DEVICE" ]] || die "$ISO_DEVICE is not a block device"
    log "Mounting $ISO_DEVICE at $ISO_MOUNT"
    mount -o ro "$ISO_DEVICE" "$ISO_MOUNT"
else
    log "$ISO_MOUNT is already mounted"
fi

load_image "$ISO_MOUNT/$APP_IMAGE_ARCHIVE" "$APP_IMAGE"
load_image "$ISO_MOUNT/$DB_IMAGE_ARCHIVE" "$DB_IMAGE"

log "Validating compose.yaml"
docker compose \
    --env-file "$ENV_FILE" \
    --file "$COMPOSE_FILE" \
    config >/dev/null

log "Starting the application stack"
docker compose \
    --env-file "$ENV_FILE" \
    --file "$COMPOSE_FILE" \
    up -d

log "Container status"
docker compose \
    --env-file "$ENV_FILE" \
    --file "$COMPOSE_FILE" \
    ps

for container_name in "$APP_CONTAINER_NAME" "$DB_CONTAINER_NAME"; do
    container_state="$(
        docker inspect \
            --format '{{.State.Status}}' \
            "$container_name" 2>/dev/null || true
    )"
    [[ "$container_state" == "running" ]] ||
        die "container $container_name is not running (state: ${container_state:-missing})"
done

server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
log "Deployment completed"
printf 'Application URL: http://%s:%s/\n' "${server_ip:-BR-SRV-IP}" "$APP_PORT"
printf 'Check logs: docker compose --env-file %q -f %q logs\n' \
    "$ENV_FILE" "$COMPOSE_FILE"
