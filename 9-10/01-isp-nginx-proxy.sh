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

WEB_DOMAIN="${WEB_DOMAIN:-web.au-team.irpo}"
DOCKER_DOMAIN="${DOCKER_DOMAIN:-docker.au-team.irpo}"
WEB_UPSTREAM="${WEB_UPSTREAM:-172.16.1.2:8080}"
DOCKER_UPSTREAM="${DOCKER_UPSTREAM:-172.16.2.2:8080}"
AUTH_USER="${AUTH_USER:-WEB}"
AUTH_PASSWORD="${AUTH_PASSWORD:-P@ssw0rd}"
AUTH_REALM="${AUTH_REALM:-Restricted area}"

NGINX_AVAILABLE_DIR=/etc/nginx/sites-available.d
NGINX_ENABLED_DIR=/etc/nginx/sites-enabled.d
NGINX_SITE_CONFIG="$NGINX_AVAILABLE_DIR/default.conf"
NGINX_SITE_LINK="$NGINX_ENABLED_DIR/default.conf"
HTPASSWD_FILE=/etc/nginx/.htpasswd
BACKUP_DIR=/root/module_2_task_9_10_backups

log() {
    printf '[ISP nginx] %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

backup_file() {
    local file="$1"

    [[ -e "$file" || -L "$file" ]] || return 0
    install -d -m 0700 "$BACKUP_DIR"
    cp -a -- "$file" "$BACKUP_DIR/$(basename "$file").$(date +%Y%m%d%H%M%S)"
}

validate_domain() {
    local name="$1"
    local value="$2"

    [[ "$value" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] ||
        die "$name is not a valid domain name"
}

validate_upstream() {
    local name="$1"
    local value="$2"
    local port

    [[ "$value" =~ ^[a-zA-Z0-9.-]+:([0-9]+)$ ]] ||
        die "$name must have the form host:port"
    port="${BASH_REMATCH[1]}"
    (( port >= 1 && port <= 65535 )) ||
        die "$name contains an invalid port"
}

check_http_endpoint() {
    local name="$1"
    local endpoint="$2"

    if ! curl --silent --show-error --output /dev/null \
        --connect-timeout 5 --max-time 15 "http://$endpoint/"; then
        die "$name is unavailable at http://$endpoint/"
    fi
}

[[ $EUID -eq 0 ]] || die "run this script as root"
validate_domain WEB_DOMAIN "$WEB_DOMAIN"
validate_domain DOCKER_DOMAIN "$DOCKER_DOMAIN"
validate_upstream WEB_UPSTREAM "$WEB_UPSTREAM"
validate_upstream DOCKER_UPSTREAM "$DOCKER_UPSTREAM"
[[ "$WEB_DOMAIN" != "$DOCKER_DOMAIN" ]] ||
    die "WEB_DOMAIN and DOCKER_DOMAIN must be different"
[[ "$AUTH_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] ||
    die "AUTH_USER contains unsupported characters"
[[ -n "$AUTH_PASSWORD" && "$AUTH_PASSWORD" != *$'\n'* ]] ||
    die "AUTH_PASSWORD must not be empty or contain a newline"
[[ -n "$AUTH_REALM" && "$AUTH_REALM" != *'"'* && "$AUTH_REALM" != *$'\n'* ]] ||
    die "AUTH_REALM must not be empty or contain quotes or newlines"

log "Installing nginx and htpasswd"
apt-get update
apt-get install -y nginx apache2-htpasswd curl

log "Checking the upstream applications"
check_http_endpoint WEB_UPSTREAM "$WEB_UPSTREAM"
check_http_endpoint DOCKER_UPSTREAM "$DOCKER_UPSTREAM"

log "Creating the Basic Auth account"
backup_file "$HTPASSWD_FILE"
htpasswd -bc "$HTPASSWD_FILE" "$AUTH_USER" "$AUTH_PASSWORD"
if getent group nginx >/dev/null 2>&1; then
    chown root:nginx "$HTPASSWD_FILE"
    chmod 0640 "$HTPASSWD_FILE"
else
    chown root:root "$HTPASSWD_FILE"
    chmod 0644 "$HTPASSWD_FILE"
fi

log "Writing the reverse proxy configuration"
install -d -m 0755 "$NGINX_AVAILABLE_DIR" "$NGINX_ENABLED_DIR"
temp_config="$(mktemp)"
cat > "$temp_config" <<EOF
# Managed by module_2/9-10/01-isp-nginx-proxy.sh
server {
    listen 80;
    server_name $WEB_DOMAIN;

    location / {
        auth_basic "$AUTH_REALM";
        auth_basic_user_file $HTPASSWD_FILE;

        proxy_pass http://$WEB_UPSTREAM;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 80;
    server_name $DOCKER_DOMAIN;

    location / {
        proxy_pass http://$DOCKER_UPSTREAM;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

if [[ ! -f "$NGINX_SITE_CONFIG" ]] || ! cmp -s "$temp_config" "$NGINX_SITE_CONFIG"; then
    backup_file "$NGINX_SITE_CONFIG"
    install -m 0644 "$temp_config" "$NGINX_SITE_CONFIG"
fi
rm -f -- "$temp_config"

if [[ -e "$NGINX_SITE_LINK" && ! -L "$NGINX_SITE_LINK" ]]; then
    backup_file "$NGINX_SITE_LINK"
    rm -f -- "$NGINX_SITE_LINK"
fi
ln -sfn ../sites-available.d/default.conf "$NGINX_SITE_LINK"

log "Validating nginx"
nginx -t
nginx_dump="$(nginx -T 2>&1)"
grep -Fq "server_name $WEB_DOMAIN;" <<< "$nginx_dump" ||
    die "$WEB_DOMAIN configuration is not included by nginx"
grep -Fq "server_name $DOCKER_DOMAIN;" <<< "$nginx_dump" ||
    die "$DOCKER_DOMAIN configuration is not included by nginx"

log "Enabling and restarting nginx"
systemctl enable --now nginx
systemctl restart nginx
systemctl is-enabled --quiet nginx || die "nginx is not enabled"
systemctl is-active --quiet nginx || die "nginx is not running"

log "Checking Basic Auth and reverse proxy routing"
web_anonymous_code="$(
    curl --silent --output /dev/null --write-out '%{http_code}' \
        --header "Host: $WEB_DOMAIN" http://127.0.0.1/
)"
[[ "$web_anonymous_code" == "401" ]] ||
    die "$WEB_DOMAIN returned $web_anonymous_code without credentials; expected 401"

web_authenticated_code="$(
    curl --silent --output /dev/null --write-out '%{http_code}' \
        --user "$AUTH_USER:$AUTH_PASSWORD" \
        --header "Host: $WEB_DOMAIN" http://127.0.0.1/
)"
[[ "$web_authenticated_code" != "000" &&
    "$web_authenticated_code" != "401" &&
    "$web_authenticated_code" != "403" ]] ||
    die "$WEB_DOMAIN returned $web_authenticated_code with valid credentials"

docker_code="$(
    curl --silent --output /dev/null --write-out '%{http_code}' \
        --header "Host: $DOCKER_DOMAIN" http://127.0.0.1/
)"
[[ "$docker_code" != "000" && "$docker_code" != "401" ]] ||
    die "$DOCKER_DOMAIN returned $docker_code"

log "Configuration completed"
printf '%s: anonymous HTTP %s, authenticated HTTP %s\n' \
    "$WEB_DOMAIN" "$web_anonymous_code" "$web_authenticated_code"
printf '%s: HTTP %s\n' "$DOCKER_DOMAIN" "$docker_code"
