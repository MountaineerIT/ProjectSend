#!/usr/bin/env bash
#
# install-projectsend.sh
#
# Unattended installer for ProjectSend (https://www.projectsend.org / docs: https://docs.projectsend.org)
# on Debian. Installs a full LAMP stack (Apache + MariaDB + PHP), creates the
# database/user, downloads the latest ProjectSend release from GitHub, builds
# its composer dependencies, writes sys.config.php, configures Apache, and
# sets permissions.
#
# Tested target: Debian 11/12/13 (bullseye/bookworm/trixie), run as root.
#
# After this script finishes, ONE manual step remains: open
#   http://<server-ip-or-domain>/install
# in a browser to run ProjectSend's own installer wizard, which creates the
# database tables and your admin account. ProjectSend does not ship a
# headless/CLI installer, so this last step can't be safely faked without
# risking a broken or half-migrated database — see docs:
# https://docs.projectsend.org/about/installation/manual-installation
#
# Usage:
#   sudo ./install-projectsend.sh
#
# Optional environment variables (set before running to override defaults):
#   APP_DIR       Install directory            (default: /var/www/projectsend)
#   DB_NAME       MySQL/MariaDB database name   (default: projectsend)
#   DB_USER       MySQL/MariaDB user            (default: projectsend)
#   DB_PASS       MySQL/MariaDB password         (default: randomly generated)
#   SITE_DOMAIN   Domain/IP for the Apache vhost (default: server's public IP, falls back to _)
#   APACHE_PORT   Port for the vhost             (default: 80)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Pre-flight checks
# ---------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root (e.g. with sudo)." >&2
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "This script is intended for Debian/apt-based systems only." >&2
    exit 1
fi

APP_DIR="${APP_DIR:-/var/www/projectsend}"
DB_NAME="${DB_NAME:-projectsend}"
DB_USER="${DB_USER:-projectsend}"
DB_PASS="${DB_PASS:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)}"
APACHE_PORT="${APACHE_PORT:-80}"
CREDS_FILE="/root/projectsend_credentials.txt"

# Guess a local IP for the vhost / final instructions if not given.
# Deliberately avoided calling out to an external "what's my IP" service
# here - if DNS/networking on the host doesn't respond cleanly, that kind
# of call can hang well past its timeout and stall the whole script.
if [[ -z "${SITE_DOMAIN:-}" ]]; then
    SITE_DOMAIN="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ -z "${SITE_DOMAIN}" ]]; then
        SITE_DOMAIN="_"
    fi
fi

echo "=================================================================="
echo " ProjectSend installer"
echo "   App directory : ${APP_DIR}"
echo "   Database      : ${DB_NAME} (user: ${DB_USER})"
echo "   Vhost address : ${SITE_DOMAIN}:${APACHE_PORT}"
echo "=================================================================="

# ---------------------------------------------------------------------------
# 1. Base packages
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
# Debian 12+ ships "needrestart", which pops up an interactive whiptail
# dialog asking which services to restart after installing packages like
# apache2/mariadb-server/php. That dialog can silently hang a piped
# `curl | sudo bash` session with no visible output. Force it to run
# non-interactively instead.
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
apt-get update -y
apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg2 lsb-release apt-transport-https \
    software-properties-common unzip git

# ---------------------------------------------------------------------------
# 2. PHP - ProjectSend r2029+ requires PHP 8.2 or newer.
#    Debian 12 (bookworm) ships PHP 8.2 by default; Debian 11 (bullseye)
#    ships PHP 7.4, which is too old, so we add the Sury PHP repo when the
#    distro's own PHP is below 8.2.
# ---------------------------------------------------------------------------
NEED_SURY=0
if command -v php >/dev/null 2>&1; then
    CURRENT_PHP_VER="$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo 0)"
else
    CURRENT_PHP_VER=0
fi
DEFAULT_PHP_CANDIDATE="$(apt-cache madison php 2>/dev/null | head -1 | awk '{print $3}' | cut -d: -f2 | cut -d- -f1 || true)"

php_ver_ge_82() {
    # returns 0 (true) if $1 >= 8.2
    local v="$1"
    [[ -z "$v" ]] && return 1
    local major minor
    major="$(echo "$v" | cut -d. -f1)"
    minor="$(echo "$v" | cut -d. -f2)"
    [[ "$major" -gt 8 ]] && return 0
    [[ "$major" -eq 8 && "$minor" -ge 2 ]] && return 0
    return 1
}

if php_ver_ge_82 "${DEFAULT_PHP_CANDIDATE}"; then
    NEED_SURY=0
else
    NEED_SURY=1
fi

if [[ "${NEED_SURY}" -eq 1 ]]; then
    echo ">>> Distro PHP is older than 8.2 - adding the Sury PHP repository."
    curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/trusted.gpg.d/sury-php.gpg
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" \
        > /etc/apt/sources.list.d/sury-php.list
    apt-get update -y
    PHP_PKG_VER="8.3"
else
    PHP_PKG_VER=""
fi

APACHE_PKGS=(apache2)
PHP_PKGS=(
    "php${PHP_PKG_VER}"
    "php${PHP_PKG_VER}-cli"
    "php${PHP_PKG_VER}-common"
    "php${PHP_PKG_VER}-mysql"
    "php${PHP_PKG_VER}-curl"
    "php${PHP_PKG_VER}-gd"
    "php${PHP_PKG_VER}-mbstring"
    "php${PHP_PKG_VER}-xml"
    "php${PHP_PKG_VER}-zip"
    "php${PHP_PKG_VER}-bcmath"
    "php${PHP_PKG_VER}-intl"
    "libapache2-mod-php${PHP_PKG_VER}"
)
MYSQL_PKGS=(mariadb-server mariadb-client)

apt-get install -y --no-install-recommends "${APACHE_PKGS[@]}" "${MYSQL_PKGS[@]}" "${PHP_PKGS[@]}"

# Composer (for ProjectSend's PHP dependencies)
if ! command -v composer >/dev/null 2>&1; then
    echo ">>> Installing Composer."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
fi

# ---------------------------------------------------------------------------
# 3. PHP configuration (upload sizes, per ProjectSend requirements)
# ---------------------------------------------------------------------------
PHP_INI_PATHS=$(find /etc/php -name php.ini 2>/dev/null || true)
for ini in ${PHP_INI_PATHS}; do
    sed -i \
        -e "s/^memory_limit.*/memory_limit = 256M/" \
        -e "s/^upload_max_filesize.*/upload_max_filesize = 256M/" \
        -e "s/^post_max_size.*/post_max_size = 256M/" \
        -e "s/^max_execution_time.*/max_execution_time = 300/" \
        "${ini}"
done

# ---------------------------------------------------------------------------
# 4. MariaDB: start it and create the database + user
# ---------------------------------------------------------------------------
systemctl enable --now mariadb

# Debian's mariadb-server defaults root to unix_socket auth, so root@localhost
# works via sudo without a password.
mysql --protocol=socket -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# ---------------------------------------------------------------------------
# 5. Download the latest ProjectSend release from GitHub
# ---------------------------------------------------------------------------
echo ">>> Looking up the latest ProjectSend release tag..."
LATEST_TAG="$(curl -fsSL https://api.github.com/repos/projectsend/projectsend/releases/latest | \
    grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/')"

if [[ -z "${LATEST_TAG}" ]]; then
    echo "Could not determine the latest ProjectSend release tag; aborting." >&2
    exit 1
fi
echo ">>> Latest release: ${LATEST_TAG}"

WORK_DIR="$(mktemp -d)"
curl -fsSL "https://codeload.github.com/projectsend/projectsend/zip/refs/tags/${LATEST_TAG}" \
    -o "${WORK_DIR}/projectsend.zip"
unzip -q "${WORK_DIR}/projectsend.zip" -d "${WORK_DIR}"

EXTRACTED_DIR="$(find "${WORK_DIR}" -maxdepth 1 -type d -name 'projectsend-*')"

mkdir -p "$(dirname "${APP_DIR}")"
if [[ -d "${APP_DIR}" ]]; then
    echo ">>> ${APP_DIR} already exists - backing it up before overwriting."
    mv "${APP_DIR}" "${APP_DIR}.bak.$(date +%s)"
fi
mv "${EXTRACTED_DIR}" "${APP_DIR}"
rm -rf "${WORK_DIR}"

# ---------------------------------------------------------------------------
# 6. Install PHP (composer) dependencies - the GitHub source archive does
#    not ship the vendor/ folder that ProjectSend's autoloader needs.
# ---------------------------------------------------------------------------
echo ">>> Installing PHP dependencies with Composer (this can take a minute)..."
( cd "${APP_DIR}" && composer install --no-dev --optimize-autoloader --no-interaction )

# ---------------------------------------------------------------------------
# 7. Write sys.config.php with the database credentials
# ---------------------------------------------------------------------------
CONFIG_FILE="${APP_DIR}/includes/sys.config.php"
cp "${APP_DIR}/includes/sys.config.sample.php" "${CONFIG_FILE}"
sed -i \
    -e "s/define('DB_NAME', 'database');/define('DB_NAME', '${DB_NAME}');/" \
    -e "s/define('DB_HOST', 'localhost');/define('DB_HOST', 'localhost');/" \
    -e "s/define('DB_USER', 'username');/define('DB_USER', '${DB_USER}');/" \
    -e "s/define('DB_PASSWORD', 'password');/define('DB_PASSWORD', '${DB_PASS}');/" \
    "${CONFIG_FILE}"

# ---------------------------------------------------------------------------
# 8. Ownership and permissions (per ProjectSend docs: dirs 775, files 644)
# ---------------------------------------------------------------------------
chown -R www-data:www-data "${APP_DIR}"
find "${APP_DIR}" -type d -exec chmod 775 {} \;
find "${APP_DIR}" -type f -exec chmod 644 {} \;

# ---------------------------------------------------------------------------
# 9. Apache vhost
# ---------------------------------------------------------------------------
a2enmod rewrite >/dev/null

VHOST_FILE="/etc/apache2/sites-available/projectsend.conf"
cat > "${VHOST_FILE}" <<APACHECONF
<VirtualHost *:${APACHE_PORT}>
    ServerName ${SITE_DOMAIN}
    DocumentRoot ${APP_DIR}

    <Directory ${APP_DIR}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    # Block direct web access to the uploads directory's raw files;
    # ProjectSend serves downloads through download.php instead.
    <Directory ${APP_DIR}/upload>
        <FilesMatch "\.(php|phtml|php3|php4|php5|pl|py|cgi|asp)$">
            Require all denied
        </FilesMatch>
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/projectsend-error.log
    CustomLog \${APACHE_LOG_DIR}/projectsend-access.log combined
</VirtualHost>
APACHECONF

if [[ "${APACHE_PORT}" != "80" ]] && ! grep -q "Listen ${APACHE_PORT}" /etc/apache2/ports.conf; then
    echo "Listen ${APACHE_PORT}" >> /etc/apache2/ports.conf
fi

a2ensite projectsend.conf >/dev/null
a2dissite 000-default.conf >/dev/null 2>&1 || true
systemctl enable --now apache2
systemctl restart apache2

# ---------------------------------------------------------------------------
# 10. Firewall (only if ufw is installed and active)
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow "${APACHE_PORT}/tcp" || true
fi

# ---------------------------------------------------------------------------
# 11. Save credentials and print summary
# ---------------------------------------------------------------------------
cat > "${CREDS_FILE}" <<EOF
ProjectSend installation summary
=================================
Release installed : ${LATEST_TAG}
App directory      : ${APP_DIR}
Config file         : ${CONFIG_FILE}

Database
  Host     : localhost
  Name     : ${DB_NAME}
  User     : ${DB_USER}
  Password : ${DB_PASS}

Next step (required, one time):
  Open http://${SITE_DOMAIN}:${APACHE_PORT}/install in a browser and
  complete ProjectSend's installer wizard (it will create the database
  tables and your admin account).
EOF
chmod 600 "${CREDS_FILE}"

echo "=================================================================="
echo " Done. LAMP stack, database, and ProjectSend files are installed."
echo ""
echo " Database name:     ${DB_NAME}"
echo " Database user:     ${DB_USER}"
echo " Database password: ${DB_PASS}"
echo " (also saved to ${CREDS_FILE})"
echo ""
echo " FINAL STEP: open this in a browser to finish setup:"
echo "   http://${SITE_DOMAIN}:${APACHE_PORT}/install"
echo " (this creates the DB tables and your admin login - ProjectSend has"
echo "  no CLI installer, so this one browser step can't be skipped safely)"
echo "=================================================================="
