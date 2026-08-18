#!/usr/bin/env bash
#
# install-projectsend.sh
#
# Unattended installer for ProjectSend 2.x (the Laravel rewrite) on Debian.
#
#   Upstream install guide: https://github.com/projectsend/projectsend/blob/main/INSTALL.md
#
# This is NOT the legacy (r####) installer. ProjectSend 2.0 is a different
# application with different requirements:
#
#   * nginx + PHP-FPM. Apache CANNOT serve this app. Downloads are handed off
#     with an X-Accel-Redirect header that only nginx understands; on Apache
#     every page works but every download returns an empty response or a 404.
#   * PHP 8.4 or newer (Debian 12 ships 8.2, so the Sury repo is added there).
#   * MySQL 8.0+ / MariaDB 10.6+ with utf8mb4.
#   * Configuration lives in .env, not includes/sys.config.php.
#   * The web root is the public/ subdirectory, never the install directory.
#   * A systemd queue worker and a per-minute cron are REQUIRED, not optional:
#     without them no email is ever sent and zip downloads never finish.
#
# This build assumes a reverse proxy (BunkerWeb) terminates TLS in front of
# this host. Consequences, all handled below:
#   * No certbot here. nginx listens on plain HTTP on the private interface.
#   * TRUSTED_PROXIES is set, without which every visitor looks like the proxy:
#     the login rate limiter treats all users as one attacker and locks the
#     whole site out after five bad passwords, and the download log records
#     the proxy's IP on every row instead of the actual person.
#   * SESSION_SECURE_COOKIE=true, because the public origin is HTTPS.
#   * The firewall allows the app port only from the proxy.
#
# Deliberately NOT run: `php artisan config:cache`. Upstream is explicit that
# it breaks TRUSTED_PROXIES, which is read from the environment before the
# middleware stack exists. route:cache / view:cache / event:cache are safe and
# are run.
#
# Usage:
#   sudo ./install-projectsend.sh
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/install-projectsend.sh | sudo bash
#
# Environment overrides (each skips the matching prompt):
#   APP_DIR         Install directory        (default: /var/www/projectsend)
#   APP_URL         Public https:// URL served by the proxy
#   TRUSTED_PROXY   Proxy IP or CIDR, comma-separated
#   LISTEN_ADDR     Address nginx binds to   (default: 0.0.0.0)
#   LISTEN_PORT     Port nginx binds to      (default: 8080)
#   DB_NAME/DB_USER/DB_PASS
#   PS_VERSION      Release tag to pin       (default: latest, e.g. v2.0.0)
#   MAX_UPLOAD      Upload size limit        (default: 100M)
#   NONINTERACTIVE=1  Take defaults, generate a random DB password
#
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# ---------------------------------------------------------------------------
# 0. Pre-flight
# ---------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root (e.g. with sudo)." >&2
    exit 1
fi
if ! command -v apt-get >/dev/null 2>&1; then
    echo "This script is for Debian/apt-based systems only." >&2
    exit 1
fi

APP_DIR="${APP_DIR:-/var/www/projectsend}"
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
LISTEN_PORT="${LISTEN_PORT:-8080}"
MAX_UPLOAD="${MAX_UPLOAD:-100M}"
PHP_VER="8.4"
WEB_USER="www-data"
CREDS_FILE="/root/projectsend_credentials.txt"
GH_REPO="projectsend/projectsend"

DETECTED_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

# ---------------------------------------------------------------------------
# 0a. Prompt helpers
#
# Read from /dev/tty, not stdin: under `curl ... | sudo bash` stdin is the
# script itself, so a plain `read` would consume the script's own remaining
# lines. /dev/tty reaches the controlling terminal, which works for both the
# piped one-liner and a normal ./install-projectsend.sh over SSH.
# ---------------------------------------------------------------------------
INTERACTIVE=1
if [[ -n "${NONINTERACTIVE:-}" ]] || [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    INTERACTIVE=0
fi

IDENT_RE='^[A-Za-z0-9_]+$'
# Restricted so the value is safe unquoted in SQL and inside a .env value.
PASS_RE='^[A-Za-z0-9_.@#%^+=-]+$'

say() { if [[ "${INTERACTIVE}" -eq 1 ]]; then printf '%s\n' "$*" > /dev/tty; fi; }

gen_password() {
    local raw
    raw="$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
    printf '%s' "${raw:0:28}"
}

ask() {  # ask <var> <text> <default>
    local __var="$1" __text="$2" __default="$3" __reply=""
    if [[ "${INTERACTIVE}" -eq 1 ]]; then
        printf '  %s [%s]: ' "${__text}" "${__default}" > /dev/tty
        IFS= read -r __reply < /dev/tty || __reply=""
    fi
    [[ -z "${__reply}" ]] && __reply="${__default}"
    printf -v "${__var}" '%s' "${__reply}"
}

ask_secret() {  # ask_secret <var> <text>
    local __var="$1" __text="$2" __reply=""
    printf '  %s: ' "${__text}" > /dev/tty
    IFS= read -rs __reply < /dev/tty || __reply=""
    printf '\n' > /dev/tty
    printf -v "${__var}" '%s' "${__reply}"
}

die() { echo "ERROR: $*" >&2; exit 1; }

echo "=================================================================="
echo " ProjectSend 2.x installer  (nginx + PHP-FPM + MariaDB)"
echo "=================================================================="
say ""
say "Press Enter at any prompt to accept the [default] shown."
say ""

# --- public URL ------------------------------------------------------------
# APP_URL is what every link in every notification email is built from, so a
# wrong value here means broken links everywhere, discovered later.
if [[ -z "${APP_URL:-}" ]]; then
    ask APP_URL "Public site URL as users reach it via the proxy" "https://files.example.com"
fi
[[ "${APP_URL}" =~ ^https?://[A-Za-z0-9._~:/?#@!$\&\'\(\)*+,\;=-]+$ ]] \
    || die "APP_URL must be a full URL, e.g. https://files.example.com"
APP_URL="${APP_URL%/}"
if [[ "${APP_URL}" == http://* ]]; then
    say "    ! APP_URL is http://. Behind BunkerWeb this should normally be https://."
    SESSION_SECURE="false"
else
    SESSION_SECURE="true"
fi

# --- trusted proxy ---------------------------------------------------------
if [[ -z "${TRUSTED_PROXY:-}" ]]; then
    say ""
    say "  BunkerWeb's address, so ProjectSend can recover the real client IP."
    say "  Comma-separated IPs or CIDRs. Use * only if nothing but the proxy"
    say "  can reach this host on the app port."
    ask TRUSTED_PROXY "Trusted proxy IP/CIDR" "${DETECTED_IP:-127.0.0.1}"
fi
[[ -n "${TRUSTED_PROXY}" ]] || die "TRUSTED_PROXY cannot be empty behind a proxy."

# --- listen address / port -------------------------------------------------
if [[ "${INTERACTIVE}" -eq 1 ]]; then
    ask LISTEN_PORT "Port for nginx to listen on (proxy connects here)" "${LISTEN_PORT}"
fi
[[ "${LISTEN_PORT}" =~ ^[0-9]+$ ]] || die "LISTEN_PORT must be numeric."

# --- database --------------------------------------------------------------
if [[ -z "${DB_NAME:-}" ]]; then ask DB_NAME "Database name" "projectsend"; fi
[[ "${DB_NAME}" =~ ${IDENT_RE} && "${#DB_NAME}" -le 63 ]] || die "DB_NAME: letters, digits, _ only (max 63)."

if [[ -z "${DB_USER:-}" ]]; then ask DB_USER "Database username" "projectsend"; fi
[[ "${DB_USER}" =~ ${IDENT_RE} && "${#DB_USER}" -le 32 ]] || die "DB_USER: letters, digits, _ only (max 32)."

if [[ -n "${DB_PASS:-}" ]]; then
    DB_PASS_SOURCE="environment"
    [[ "${DB_PASS}" =~ ${PASS_RE} ]] || die "DB_PASS: allowed characters are letters, digits, and _ . @ # % ^ + = -"
elif [[ "${INTERACTIVE}" -eq 0 ]]; then
    DB_PASS="$(gen_password)"; DB_PASS_SOURCE="generated"
else
    say ""
    say "  Database password for '${DB_USER}'."
    say "  Allowed: letters, digits, and _ . @ # % ^ + = -   Minimum 12 characters."
    say "  Leave blank to auto-generate a strong one."
    while true; do
        ask_secret PS_P1 "Database password"
        if [[ -z "${PS_P1}" ]]; then
            DB_PASS="$(gen_password)"; DB_PASS_SOURCE="generated"
            say "    -> Blank entry: generating a strong random password."
            break
        fi
        if [[ "${#PS_P1}" -lt 12 ]]; then say "    ! Too short - use at least 12 characters."; continue; fi
        if [[ ! "${PS_P1}" =~ ${PASS_RE} ]]; then say "    ! Unsupported character."; continue; fi
        ask_secret PS_P2 "Confirm password"
        if [[ "${PS_P1}" != "${PS_P2}" ]]; then say "    ! Passwords did not match."; continue; fi
        DB_PASS="${PS_P1}"; DB_PASS_SOURCE="entered"; break
    done
    unset PS_P1 PS_P2
fi

echo ""
echo "------------------------------------------------------------------"
echo " About to install ProjectSend 2.x with these settings:"
echo "   Install directory : ${APP_DIR}   (web root: ${APP_DIR}/public)"
echo "   Public URL        : ${APP_URL}"
echo "   nginx listens on  : ${LISTEN_ADDR}:${LISTEN_PORT}  (plain HTTP, proxy terminates TLS)"
echo "   Trusted proxy     : ${TRUSTED_PROXY}"
echo "   Database          : ${DB_NAME} (user: ${DB_USER}, password ${DB_PASS_SOURCE})"
echo "   Max upload size   : ${MAX_UPLOAD}"
echo "------------------------------------------------------------------"
if [[ "${INTERACTIVE}" -eq 1 ]]; then
    ask PS_OK "Continue? (y/n)" "y"
    [[ "${PS_OK}" =~ ^[Yy] ]] || { echo "Aborted at user request."; exit 0; }
    unset PS_OK
fi
echo ""

# ---------------------------------------------------------------------------
# 1. Base packages
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
# Debian 12+ ships needrestart, whose whiptail dialog can silently hang a
# piped `curl | sudo bash` run with no visible output.
export NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

echo ">>> Installing base packages."
apt-get update -y
apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg2 lsb-release apt-transport-https \
    unzip cron

# ---------------------------------------------------------------------------
# 2. PHP 8.4 (Sury repo when the distro is older). ProjectSend 2.x requires
#    8.4 or newer for BOTH the CLI and FPM.
# ---------------------------------------------------------------------------
DISTRO_PHP="$(apt-cache madison php 2>/dev/null | head -1 | awk '{print $3}' | cut -d: -f2 | cut -d- -f1 || true)"
php_ge_84() {
    local v="${1:-}" major minor
    [[ -z "$v" ]] && return 1
    major="${v%%.*}"; minor="$(echo "$v" | cut -d. -f2)"
    [[ "${major}" -gt 8 ]] && return 0
    [[ "${major}" -eq 8 && "${minor}" -ge 4 ]] && return 0
    return 1
}

if ! php_ge_84 "${DISTRO_PHP}"; then
    echo ">>> Distro PHP (${DISTRO_PHP:-none}) is older than 8.4 - adding the Sury repository."
    # Scope the key to this repo only with signed-by. A key dropped into
    # /etc/apt/trusted.gpg.d would be trusted to sign packages for EVERY
    # repository on the system, including Debian's own.
    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg -o /usr/share/keyrings/sury-php.gpg
    chmod 0644 /usr/share/keyrings/sury-php.gpg
    echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
        > /etc/apt/sources.list.d/sury-php.list
    apt-get update -y
fi

echo ">>> Installing nginx, PHP ${PHP_VER}-FPM and MariaDB."
# ldap is required even if you never use LDAP: a dependency declares it and
# PHP refuses to start the app without it.
apt-get install -y --no-install-recommends \
    nginx \
    "php${PHP_VER}-fpm" "php${PHP_VER}-cli" "php${PHP_VER}-common" \
    "php${PHP_VER}-bcmath" "php${PHP_VER}-curl" "php${PHP_VER}-gd" \
    "php${PHP_VER}-intl"   "php${PHP_VER}-ldap" "php${PHP_VER}-mbstring" \
    "php${PHP_VER}-mysql"  "php${PHP_VER}-xml"  "php${PHP_VER}-zip" \
    mariadb-server mariadb-client

PHP_BIN="$(command -v "php${PHP_VER}" || command -v php)"
[[ -n "${PHP_BIN}" ]] || die "PHP binary not found after install."

INSTALLED_PHP="$("${PHP_BIN}" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
php_ge_84 "${INSTALLED_PHP}" || die "PHP ${INSTALLED_PHP} installed but ProjectSend 2.x needs 8.4+."

# Fail loudly and early on a missing extension rather than leaving a broken
# install to be discovered at first page load.
echo ">>> Verifying required PHP extensions."
MISSING=()
for ext in bcmath ctype curl dom fileinfo filter gd iconv intl json ldap \
           mbstring openssl pcntl pdo_mysql session simplexml tokenizer zip; do
    "${PHP_BIN}" -m 2>/dev/null | grep -qix "${ext}" || MISSING+=("${ext}")
done
if [[ "${#MISSING[@]}" -gt 0 ]]; then
    die "Missing required PHP extensions: ${MISSING[*]}"
fi
echo "    All 19 required extensions present."

# ---------------------------------------------------------------------------
# 3. PHP settings. Uploads arrive in 20 MB chunks, so these bound the chunk,
#    not the whole file - but the chunk still needs room.
# ---------------------------------------------------------------------------
for ini in "/etc/php/${PHP_VER}/fpm/php.ini" "/etc/php/${PHP_VER}/cli/php.ini"; do
    [[ -f "${ini}" ]] || continue
    sed -i \
        -e "s/^;*\s*memory_limit\s*=.*/memory_limit = 256M/" \
        -e "s/^;*\s*upload_max_filesize\s*=.*/upload_max_filesize = ${MAX_UPLOAD}/" \
        -e "s/^;*\s*post_max_size\s*=.*/post_max_size = ${MAX_UPLOAD}/" \
        -e "s/^;*\s*max_execution_time\s*=.*/max_execution_time = 300/" \
        -e "s/^;*\s*expose_php\s*=.*/expose_php = Off/" \
        "${ini}"
done

# ---------------------------------------------------------------------------
# 4. MariaDB: lock down, then create the utf8mb4 database
# ---------------------------------------------------------------------------
systemctl enable --now mariadb

echo ">>> Securing MariaDB and creating the database."
# The non-interactive equivalent of mysql_secure_installation. Debian's root
# uses unix_socket auth, so no root password is involved.
mysql --protocol=socket -u root <<'SQL'
DELETE FROM mysql.global_priv WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

# ProjectSend 2.x requires utf8mb4 - the legacy line used utf8/utf8_general_ci.
mysql --protocol=socket -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# Keep MariaDB off the network.
cat > /etc/mysql/mariadb.conf.d/99-projectsend-bind.cnf <<'EOF'
[mysqld]
bind-address = 127.0.0.1
EOF
systemctl restart mariadb

# Verify the credentials without putting the password in the process table -
# command-line arguments are world-readable via /proc.
MY_CNF="$(mktemp)"; chmod 600 "${MY_CNF}"
trap 'rm -f "${MY_CNF}"' EXIT
printf '[client]\nuser=%s\npassword=%s\nhost=127.0.0.1\n' "${DB_USER}" "${DB_PASS}" > "${MY_CNF}"
mysql --defaults-extra-file="${MY_CNF}" -e "USE \`${DB_NAME}\`;" >/dev/null 2>&1 \
    || die "Could not authenticate to the database as '${DB_USER}'."
rm -f "${MY_CNF}"; trap - EXIT
echo "    Database ready and credentials verified."

# ---------------------------------------------------------------------------
# 5. Download the release, VERIFY ITS CHECKSUM, and unpack
#
#    2.x releases ship projectsend-X.Y.Z.zip alongside a matching .sha256.
#    The zip is self-contained: no Composer, no Node, no npm.
# ---------------------------------------------------------------------------
echo ">>> Resolving the ProjectSend release."
if [[ -n "${PS_VERSION:-}" ]]; then
    API_URL="https://api.github.com/repos/${GH_REPO}/releases/tags/${PS_VERSION}"
else
    API_URL="https://api.github.com/repos/${GH_REPO}/releases/latest"
fi

RELEASE_JSON="$(curl -fsSL -H 'Accept: application/vnd.github+json' "${API_URL}")" \
    || die "Could not reach the GitHub release API. If you deploy many hosts from one IP, the unauthenticated rate limit (60/hour) may be the cause; pin a version with PS_VERSION instead."

LATEST_TAG="$(printf '%s' "${RELEASE_JSON}" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')"

# Select the asset by FILENAME, not by position in the assets array. Picking
# "the first browser_download_url" silently installs the wrong artifact the
# moment upstream reorders assets or adds a new one.
ZIP_URL="$(printf '%s' "${RELEASE_JSON}" \
    | grep -oE '"browser_download_url":[[:space:]]*"[^"]*projectsend-[0-9]+\.[0-9]+\.[0-9]+\.zip"' \
    | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
SHA_URL="$(printf '%s' "${RELEASE_JSON}" \
    | grep -oE '"browser_download_url":[[:space:]]*"[^"]*projectsend-[0-9]+\.[0-9]+\.[0-9]+\.zip\.sha256"' \
    | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"

[[ -n "${LATEST_TAG}" && -n "${ZIP_URL}" ]] || die "Could not find a projectsend-X.Y.Z.zip asset in release ${LATEST_TAG:-?}."
case "${LATEST_TAG}" in
    r[0-9]*) die "Release ${LATEST_TAG} is the LEGACY 1.x line, not 2.x. This script installs 2.x only; pin one with PS_VERSION=v2.0.0." ;;
esac

echo ">>> Release ${LATEST_TAG}"
echo "    ${ZIP_URL}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
ZIP_FILE="${WORK_DIR}/projectsend.zip"
curl -fsSL "${ZIP_URL}" -o "${ZIP_FILE}"

if [[ -n "${SHA_URL}" ]]; then
    echo ">>> Verifying SHA-256."
    curl -fsSL "${SHA_URL}" -o "${WORK_DIR}/projectsend.zip.sha256"
    # The published file may be a bare hash or "hash  filename".
    EXPECTED="$(tr -d '\r' < "${WORK_DIR}/projectsend.zip.sha256" | awk '{print $1}' | head -1)"
    ACTUAL="$(sha256sum "${ZIP_FILE}" | awk '{print $1}')"
    [[ -n "${EXPECTED}" ]] || die "Published checksum file was empty."
    if [[ "${EXPECTED}" != "${ACTUAL}" ]]; then
        echo "  expected: ${EXPECTED}" >&2
        echo "  actual  : ${ACTUAL}"   >&2
        die "Checksum mismatch - refusing to install. The download is corrupt or tampered with."
    fi
    echo "    OK  ${ACTUAL}"
else
    echo "    WARNING: no .sha256 asset published for ${LATEST_TAG}; integrity NOT verified." >&2
fi

mkdir -p "${WORK_DIR}/app"
unzip -q "${ZIP_FILE}" -d "${WORK_DIR}/app"
if [[ -f "${WORK_DIR}/app/artisan" ]]; then
    SRC_DIR="${WORK_DIR}/app"
else
    SRC_DIR="$(find "${WORK_DIR}/app" -maxdepth 1 -mindepth 1 -type d | head -1)"
fi
[[ -n "${SRC_DIR}" && -f "${SRC_DIR}/artisan" && -f "${SRC_DIR}/public/index.php" ]] \
    || die "The extracted archive doesn't look like ProjectSend 2.x (no artisan / public/index.php)."

mkdir -p "$(dirname "${APP_DIR}")"
BACKUP_DIR=""
if [[ -d "${APP_DIR}" ]]; then
    BACKUP_DIR="${APP_DIR}.bak.$(date +%s)"
    echo ">>> ${APP_DIR} exists - moving it to ${BACKUP_DIR}"
    mv "${APP_DIR}" "${BACKUP_DIR}"
    # The old .env holds database credentials and APP_KEY.
    chmod 700 "${BACKUP_DIR}" 2>/dev/null || true
fi
mv "${SRC_DIR}" "${APP_DIR}"

# ---------------------------------------------------------------------------
# 6. .env
# ---------------------------------------------------------------------------
echo ">>> Writing .env"
ENV_FILE="${APP_DIR}/.env"
cat > "${ENV_FILE}" <<EOF
APP_NAME="ProjectSend"
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=${APP_URL}
APP_TIMEZONE=UTC

PROJECTSEND_EDITION=community

DB_CONNECTION=mariadb
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD="${DB_PASS}"

SESSION_DRIVER=database
CACHE_STORE=database
QUEUE_CONNECTION=database

FILESYSTEM_DISK=local

# The public origin is HTTPS, terminated by the reverse proxy.
SESSION_SECURE_COOKIE=${SESSION_SECURE}

# Required behind a proxy. Without it every request appears to come from the
# proxy: the login rate limiter counts all users as one attacker and locks the
# whole site out after five wrong passwords, and every row of the download log
# records the proxy's address instead of the person who downloaded the file.
TRUSTED_PROXIES=${TRUSTED_PROXY}
EOF
chmod 640 "${ENV_FILE}"

# ---------------------------------------------------------------------------
# 7. Ownership and permissions
# ---------------------------------------------------------------------------
chown -R "${WEB_USER}:${WEB_USER}" "${APP_DIR}"
chmod -R 775 "${APP_DIR}/storage" "${APP_DIR}/bootstrap/cache"
chown "${WEB_USER}:${WEB_USER}" "${ENV_FILE}"
chmod 640 "${ENV_FILE}"

# ---------------------------------------------------------------------------
# 8. Application setup. Run as the web user so what these create is owned
#    correctly.
# ---------------------------------------------------------------------------
echo ">>> Generating the application key."
sudo -u "${WEB_USER}" "${PHP_BIN}" "${APP_DIR}/artisan" key:generate --force --no-interaction
echo ">>> Running database migrations."
sudo -u "${WEB_USER}" "${PHP_BIN}" "${APP_DIR}/artisan" migrate --force --no-interaction
echo ">>> Linking public storage."
sudo -u "${WEB_USER}" "${PHP_BIN}" "${APP_DIR}/artisan" storage:link --no-interaction || true

APP_KEY_VALUE="$(grep -m1 '^APP_KEY=' "${ENV_FILE}" | cut -d= -f2-)"

# route/view/event caches are safe and worth having.
# config:cache is deliberately NOT run: it stops TRUSTED_PROXIES from being
# read at all, which silently breaks rate limiting and the download IP log.
echo ">>> Warming safe caches (skipping config:cache by design)."
for c in route:cache view:cache event:cache; do
    sudo -u "${WEB_USER}" "${PHP_BIN}" "${APP_DIR}/artisan" "${c}" --no-interaction || true
done

# ---------------------------------------------------------------------------
# 9. nginx
# ---------------------------------------------------------------------------
echo ">>> Configuring nginx."
FPM_SOCK="/run/php/php${PHP_VER}-fpm.sock"
NGINX_SITE="/etc/nginx/sites-available/projectsend.conf"
SERVER_NAME="$(printf '%s' "${APP_URL}" | sed -E 's#^https?://##; s#[:/].*$##')"

cat > "${NGINX_SITE}" <<NGINXCONF
server {
    listen ${LISTEN_ADDR}:${LISTEN_PORT};
    server_name ${SERVER_NAME} _;

    # The web root is public/, never the install directory. Everything above
    # public/ - .env, the database credentials, storage/app/files - must stay
    # unreachable from the web.
    root ${APP_DIR}/public;
    index index.php;

    client_max_body_size ${MAX_UPLOAD};

    # TLS is terminated by the reverse proxy in front of this host, which also
    # sets its own security headers. These are kept as a backstop for the case
    # where someone reaches this port directly.
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # How downloads are served: ProjectSend checks permissions and logs the
    # download, then returns an empty response with an X-Accel-Redirect header
    # telling nginx which file to stream. "internal" is what stops anyone from
    # requesting this path directly - do not remove it.
    location /protected-files/ {
        internal;
        alias ${APP_DIR}/storage/app/files/;

        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header Content-Security-Policy "sandbox; default-src 'none'" always;
    }

    location ~ \.php\$ {
        try_files \$uri =404;

        fastcgi_pass unix:${FPM_SOCK};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffer_size 32k;
        fastcgi_buffers 8 32k;
    }

    location ~ /\.(?!well-known) {
        deny all;
    }
}
NGINXCONF

# Don't disclose the nginx version.
if ! grep -qE '^\s*server_tokens\s+off;' /etc/nginx/nginx.conf; then
    sed -i 's/^\(\s*\)\(#\s*\)\?server_tokens.*/\1server_tokens off;/' /etc/nginx/nginx.conf \
        || true
    grep -qE 'server_tokens\s+off;' /etc/nginx/nginx.conf \
        || sed -i '/http\s*{/a \\tserver_tokens off;' /etc/nginx/nginx.conf
fi

ln -sf "${NGINX_SITE}" /etc/nginx/sites-enabled/projectsend.conf
rm -f /etc/nginx/sites-enabled/default

nginx -t || die "nginx configuration test failed."
systemctl enable --now nginx
systemctl reload nginx
systemctl enable --now "php${PHP_VER}-fpm"
systemctl restart "php${PHP_VER}-fpm"

# ---------------------------------------------------------------------------
# 10. Queue worker. Without this NO EMAIL IS EVER SENT and zip downloads
#     never finish. Restart=always matters: saving mail settings restarts the
#     worker so it picks up new values, and it has to come back on its own.
# ---------------------------------------------------------------------------
echo ">>> Installing the queue worker."
cat > /etc/systemd/system/projectsend-worker.service <<UNIT
[Unit]
Description=ProjectSend queue worker
After=network.target mariadb.service

[Service]
User=${WEB_USER}
Group=${WEB_USER}
Restart=always
RestartSec=5
WorkingDirectory=${APP_DIR}
ExecStart=${PHP_BIN} ${APP_DIR}/artisan queue:work --tries=3 --backoff=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now projectsend-worker

# ---------------------------------------------------------------------------
# 11. Scheduler heartbeat. Every minute; the app decides what is actually due.
# ---------------------------------------------------------------------------
echo ">>> Installing the scheduler cron entry."
systemctl enable --now cron >/dev/null 2>&1 || true
CRON_LINE="* * * * * cd ${APP_DIR} && ${PHP_BIN} artisan schedule:run >> /dev/null 2>&1"
( crontab -u "${WEB_USER}" -l 2>/dev/null | grep -Fv "artisan schedule:run" || true; echo "${CRON_LINE}" ) \
    | crontab -u "${WEB_USER}" -

# ---------------------------------------------------------------------------
# 12. Host hardening
# ---------------------------------------------------------------------------
echo ">>> Applying host hardening."
apt-get install -y --no-install-recommends unattended-upgrades fail2ban ufw >/dev/null 2>&1 || true

if command -v unattended-upgrades >/dev/null 2>&1; then
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
fi

if command -v fail2ban-client >/dev/null 2>&1; then
    cat > /etc/fail2ban/jail.d/projectsend.local <<'EOF'
[sshd]
enabled = true
EOF
    systemctl enable --now fail2ban >/dev/null 2>&1 || true
fi

# Default deny inbound; allow SSH, and the app port only from the proxy.
if command -v ufw >/dev/null 2>&1; then
    ufw --force default deny incoming >/dev/null 2>&1 || true
    ufw --force default allow outgoing >/dev/null 2>&1 || true
    ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
    if [[ "${TRUSTED_PROXY}" == "*" ]]; then
        ufw allow "${LISTEN_PORT}/tcp" >/dev/null 2>&1 || true
        UFW_NOTE="port ${LISTEN_PORT} open to all (TRUSTED_PROXY was '*')"
    else
        IFS=',' read -ra PROXIES <<< "${TRUSTED_PROXY}"
        for p in "${PROXIES[@]}"; do
            p="$(echo "$p" | xargs)"
            [[ -n "$p" ]] && ufw allow from "$p" to any port "${LISTEN_PORT}" proto tcp >/dev/null 2>&1 || true
        done
        UFW_NOTE="port ${LISTEN_PORT} restricted to ${TRUSTED_PROXY}"
    fi
    ufw --force enable >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 13. Health checks
# ---------------------------------------------------------------------------
echo ">>> Verifying the installation."
HEALTH_OK=1
check() {  # check <label> <command...>
    if "${@:2}" >/dev/null 2>&1; then printf '    [ ok ] %s\n' "$1"
    else printf '    [FAIL] %s\n' "$1"; HEALTH_OK=0; fi
}
check "nginx running"                systemctl is-active --quiet nginx
check "php${PHP_VER}-fpm running"    systemctl is-active --quiet "php${PHP_VER}-fpm"
check "mariadb running"              systemctl is-active --quiet mariadb
check "queue worker running"         systemctl is-active --quiet projectsend-worker
check "scheduler cron installed"     bash -c "crontab -u ${WEB_USER} -l 2>/dev/null | grep -q 'artisan schedule:run'"
check "APP_KEY set"                  bash -c "grep -q '^APP_KEY=base64:' '${ENV_FILE}'"
check "storage/ writable by ${WEB_USER}" sudo -u "${WEB_USER}" test -w "${APP_DIR}/storage"
check "uploads dir outside web root" bash -c "[ ! -e '${APP_DIR}/public/files' ]"

HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Host: ${SERVER_NAME}" "http://127.0.0.1:${LISTEN_PORT}/" 2>/dev/null || echo 000)"
if [[ "${HTTP_CODE}" =~ ^(200|302)$ ]]; then
    printf '    [ ok ] app responds locally (HTTP %s)\n' "${HTTP_CODE}"
else
    printf '    [WARN] app returned HTTP %s locally\n' "${HTTP_CODE}"
fi

# ---------------------------------------------------------------------------
# 14. Credentials file and recap
# ---------------------------------------------------------------------------
ALL_IPS="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | paste -sd ', ' - || true)"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)"

cat > "${CREDS_FILE}" <<EOF
ProjectSend 2.x installation summary
====================================
Generated : $(date '+%Y-%m-%d %H:%M:%S %Z')

Server
  Hostname        : ${HOSTNAME_FQDN}
  IP address(es)  : ${ALL_IPS:-unknown}
  nginx listens   : ${LISTEN_ADDR}:${LISTEN_PORT}  (plain HTTP)
  Public URL      : ${APP_URL}   (TLS terminated by the reverse proxy)
  Trusted proxy   : ${TRUSTED_PROXY}

Application
  Release         : ${LATEST_TAG}
  Install dir     : ${APP_DIR}
  Web root        : ${APP_DIR}/public
  Uploads         : ${APP_DIR}/storage/app/files   (outside the web root)
  Config          : ${ENV_FILE}
  nginx site      : ${NGINX_SITE}
  Queue worker    : projectsend-worker.service
  Scheduler cron  : crontab -u ${WEB_USER} -l

Database (MariaDB)
  Host            : 127.0.0.1
  Name            : ${DB_NAME}
  Username        : ${DB_USER}
  Password        : ${DB_PASS}
  Charset         : utf8mb4 / utf8mb4_unicode_ci

APP_KEY (back this up - anything encrypted with it, including saved mail
server credentials, cannot be recovered without it):
  ${APP_KEY_VALUE}

Point BunkerWeb at:  http://${DETECTED_IP:-<this-server>}:${LISTEN_PORT}
  - forward X-Forwarded-For and X-Forwarded-Proto
  - allow request bodies of at least ${MAX_UPLOAD}
  - proxy read timeout long enough for large downloads

Next step: open ${APP_URL} in a browser. The first visit is the setup screen
where you create the first administrator. Or, from the shell:
  sudo -u ${WEB_USER} ${PHP_BIN} ${APP_DIR}/artisan projectsend:admin

Do NOT run 'php artisan config:cache' (or 'artisan optimize', which includes
it) on this application: it stops TRUSTED_PROXIES from being read, which
silently breaks login rate limiting and the download IP log.
EOF
chmod 600 "${CREDS_FILE}"

echo ""
echo "=================================================================="
echo "  ProjectSend ${LATEST_TAG} installed"
echo "=================================================================="
echo ""
echo "  SERVER"
echo "    Hostname        : ${HOSTNAME_FQDN}"
echo "    IP address(es)  : ${ALL_IPS:-unknown}"
echo "    nginx listens   : ${LISTEN_ADDR}:${LISTEN_PORT}  (plain HTTP)"
echo "    Public URL      : ${APP_URL}"
echo "    Trusted proxy   : ${TRUSTED_PROXY}"
echo ""
echo "  DATABASE"
echo "    Host            : 127.0.0.1"
echo "    Database name   : ${DB_NAME}"
echo "    Username        : ${DB_USER}"
echo "    Password        : ${DB_PASS}"
if [[ "${DB_PASS_SOURCE}" == "generated" ]]; then
    echo "                      ^ auto-generated - copy it now"
fi
echo "    Charset         : utf8mb4 / utf8mb4_unicode_ci"
echo ""
echo "  APPLICATION"
echo "    Release         : ${LATEST_TAG}"
echo "    Install dir     : ${APP_DIR}"
echo "    Web root        : ${APP_DIR}/public"
echo "    Uploads         : ${APP_DIR}/storage/app/files  (outside web root)"
echo "    Config          : ${ENV_FILE}"
if [[ -n "${BACKUP_DIR}" ]]; then
    echo "    Previous install: ${BACKUP_DIR} (mode 700 - contains old credentials)"
fi
if [[ -n "${UFW_NOTE:-}" ]]; then
    echo "    Firewall        : ${UFW_NOTE}"
fi
echo ""
echo "    Full details, including APP_KEY, saved to ${CREDS_FILE}"
echo "      sudo cat ${CREDS_FILE}"
echo ""
echo "------------------------------------------------------------------"
echo "  POINT BUNKERWEB AT:"
echo "      http://${DETECTED_IP:-<this-server>}:${LISTEN_PORT}"
echo "    forwarding X-Forwarded-For and X-Forwarded-Proto, allowing bodies"
echo "    of at least ${MAX_UPLOAD}, with a long proxy read timeout."
echo ""
echo "  THEN open ${APP_URL} to create the first administrator,"
echo "  or run:"
echo "      sudo -u ${WEB_USER} ${PHP_BIN} ${APP_DIR}/artisan projectsend:admin"
if [[ "${HEALTH_OK}" -ne 1 ]]; then
echo ""
echo "  !! One or more health checks FAILED above - review before going live."
fi
echo "=================================================================="
echo ""
