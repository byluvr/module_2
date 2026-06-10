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

ISO_DEVICE="${ISO_DEVICE:-/dev/sr0}"
ISO_MOUNT="${ISO_MOUNT:-/mnt}"
WEB_SOURCE_DIR="${WEB_SOURCE_DIR:-web}"
WEB_ROOT="${WEB_ROOT:-/var/www/html}"
WEB_PORT="${WEB_PORT:?WEB_PORT is required in $ENV_FILE}"
DB_HOST="${DB_HOST:-localhost}"
DB_NAME="${DB_NAME:-webdb}"
DB_USER="${DB_USER:-webc}"
DB_PASSWORD="${DB_PASSWORD:-P@ssw0rd}"
RESET_DATABASE="${RESET_DATABASE:-yes}"

log() {
    printf '[HQ-SRV Web] %s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

sql_escape() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\'/\'\'}"
    printf '%s' "$value"
}

[[ $EUID -eq 0 ]] || die "run this script as root"
[[ "$DB_NAME" =~ ^[a-zA-Z0-9_]+$ ]] ||
    die "DB_NAME may contain only letters, digits and underscores"
[[ "$DB_USER" =~ ^[a-zA-Z0-9_]+$ ]] ||
    die "DB_USER may contain only letters, digits and underscores"
[[ -n "$DB_PASSWORD" && "$DB_PASSWORD" != *$'\n'* ]] ||
    die "DB_PASSWORD must not be empty or contain a newline"
[[ "$DB_HOST" == "localhost" ]] ||
    die "DB_HOST must be localhost for this local deployment"
case "$RESET_DATABASE" in
    yes | no) ;;
    *) die "RESET_DATABASE must be yes or no" ;;
esac

log "Installing Apache, PHP and MariaDB"
apt-get update
apt-get install -y lamp-server curl

log "Starting MariaDB"
systemctl enable --now mariadb
systemctl is-active --quiet mariadb || die "mariadb is not running"

install -d -m 0755 "$ISO_MOUNT"
if ! mountpoint -q "$ISO_MOUNT"; then
    [[ -b "$ISO_DEVICE" ]] || die "$ISO_DEVICE is not a block device"
    log "Mounting $ISO_DEVICE at $ISO_MOUNT"
    mount -o ro "$ISO_DEVICE" "$ISO_MOUNT"
else
    log "$ISO_MOUNT is already mounted"
fi

WEB_SOURCE="$ISO_MOUNT/$WEB_SOURCE_DIR"
SOURCE_INDEX="$WEB_SOURCE/index.php"
SOURCE_DUMP="$WEB_SOURCE/dump.sql"
TARGET_INDEX="$WEB_ROOT/index.php"

[[ -f "$SOURCE_INDEX" ]] || die "$SOURCE_INDEX not found"
[[ -f "$SOURCE_DUMP" ]] || die "$SOURCE_DUMP not found"

log "Copying the web application"
install -d -m 0755 "$WEB_ROOT"
install -m 0644 "$SOURCE_INDEX" "$TARGET_INDEX"

if [[ -d "$WEB_SOURCE/images" ]]; then
    cp -a -- "$WEB_SOURCE/images" "$WEB_ROOT/"
fi
if [[ -f "$WEB_SOURCE/logo.png" ]]; then
    install -m 0644 "$WEB_SOURCE/logo.png" "$WEB_ROOT/logo.png"
fi

log "Writing database credentials to index.php"
DB_HOST_VALUE="$DB_HOST" \
DB_USER_VALUE="$DB_USER" \
DB_PASSWORD_VALUE="$DB_PASSWORD" \
DB_NAME_VALUE="$DB_NAME" \
php -r '
$file = $argv[1];
$content = file_get_contents($file);
if ($content === false) {
    fwrite(STDERR, "Unable to read $file\n");
    exit(1);
}

$values = [
    "servername" => getenv("DB_HOST_VALUE"),
    "username" => getenv("DB_USER_VALUE"),
    "password" => getenv("DB_PASSWORD_VALUE"),
    "dbname" => getenv("DB_NAME_VALUE"),
];

foreach ($values as $variable => $value) {
    $pattern = "~^(\\s*\\$" . preg_quote($variable, "~") . "\\s*=\\s*).*(;\\s*)$~m";
    $content = preg_replace_callback(
        $pattern,
        static function ($matches) use ($value) {
            return $matches[1] . var_export($value, true) . $matches[2];
        },
        $content,
        -1,
        $count
    );
    if ($count === 0) {
        fwrite(STDERR, "PHP variable \$$variable was not found in $file\n");
        exit(1);
    }
}

if (file_put_contents($file, $content) === false) {
    fwrite(STDERR, "Unable to update $file\n");
    exit(1);
}
' "$TARGET_INDEX"
php -l "$TARGET_INDEX" >/dev/null

escaped_user="$(sql_escape "$DB_USER")"
escaped_password="$(sql_escape "$DB_PASSWORD")"

log "Creating the database and local user"
if [[ "$RESET_DATABASE" == "yes" ]]; then
    mariadb -u root <<SQL
DROP DATABASE IF EXISTS \`$DB_NAME\`;
CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '$escaped_user'@'localhost';
CREATE USER '$escaped_user'@'localhost' IDENTIFIED BY '$escaped_password';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$escaped_user'@'localhost';
FLUSH PRIVILEGES;
SQL
else
    mariadb -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$escaped_user'@'localhost' IDENTIFIED BY '$escaped_password';
ALTER USER '$escaped_user'@'localhost' IDENTIFIED BY '$escaped_password';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$escaped_user'@'localhost';
FLUSH PRIVILEGES;
SQL
fi

should_import=yes
if [[ "$RESET_DATABASE" == "no" ]]; then
    existing_table_count="$(
        mariadb -u root -Nse \
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB_NAME';"
    )"
    if [[ "$existing_table_count" =~ ^[1-9][0-9]*$ ]]; then
        should_import=no
        log "Database already has $existing_table_count table(s); skipping dump import"
    fi
fi

if [[ "$should_import" == "yes" ]]; then
    log "Importing dump.sql"
    mariadb -u root "$DB_NAME" < "$SOURCE_DUMP"
fi

log "Checking access as $DB_USER"
table_count="$(
    MYSQL_PWD="$DB_PASSWORD" mariadb \
        -u "$DB_USER" \
        -h "$DB_HOST" \
        -Nse 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE();' \
        "$DB_NAME"
)"
[[ "$table_count" =~ ^[0-9]+$ ]] ||
    die "could not verify imported tables as $DB_USER"

log "Starting Apache"
systemctl enable --now httpd2
systemctl restart httpd2
systemctl is-enabled --quiet httpd2 || die "httpd2 is not enabled"
systemctl is-active --quiet httpd2 || die "httpd2 is not running"

http_code="$(
    curl --silent --show-error \
        --output /dev/null \
        --write-out '%{http_code}' \
        "http://127.0.0.1:$WEB_PORT/"
)"
[[ "$http_code" =~ ^(2|3)[0-9][0-9]$ ]] ||
    die "Apache returned HTTP $http_code"

server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

log "Deployment completed"
printf 'Application URL: http://%s:%s/\n' "${server_ip:-HQ-SRV-IP}" "$WEB_PORT"
printf 'Imported tables: %s\n' "$table_count"
