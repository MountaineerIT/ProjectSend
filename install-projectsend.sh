#!/usr/bin/env bash
#
# install-projectsend.sh
#
# Unattended installer for ProjectSend (https://www.projectsend.org / docs: https://docs.projectsend.org)
# on Debian. Installs a full LAMP stack (Apache + MariaDB + PHP), creates the
# database/user, downloads the latest official ProjectSend release package
# (with compiled assets and vendor libraries included), writes sys.config.php,
# configures Apache, and sets permissions.
#
# Tested target: Debian 11/12/13 (bullseye/bookworm/trixie), run as root.
#
# The script prompts for the database name, database user, and database
# password up front. Prompts are read from the controlling terminal
# (/dev/tty), so they work both ways:
#
#   sudo ./install-projectsend.sh
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/install-projectsend.sh | sudo bash
#
# If there is no terminal at all (cron, CI, packer), the script falls back to
# the defaults and generates a strong random password instead of hanging.
#
# After this script finishes, ONE manual step remains: open
#   http://<server-ip-or-domain>/install
# in a browser to run ProjectSend's own installer wizard, which creates the
# database tables and your admin account. ProjectSend does not ship a
# headless/CLI installer, so this last step can't be safely faked without
# risking a broken or half-migrated database — see docs:
# https://docs.projectsend.org/about/installation/manual-installation
#
# Optional environment variables (set before running to skip the matching
# prompt entirely):
#   APP_DIR       Install directory              (default: /var/www/projectsend)
#   DB_NAME       MySQL/MariaDB database name    (default: projectsend)
#   DB_USER       MySQL/MariaDB user             (default: projectsend)
#   DB_PASS       MySQL/MariaDB password         (default: prompted, else random)
#   SITE_DOMAIN   Domain/IP for the Apache vhost (default: server's primary IP)
#   APACHE_PORT   Port for the vhost             (default: 80)
#   NONINTERACTIVE=1  Skip all prompts and use defaults/env values
#
set -euo pipefail

# Make sure sbin dirs are on PATH. If root was obtained via plain `su`
# (without `-`), the inherited PATH lacks /usr/sbin, which breaks
# a2enmod/a2ensite/a2dissite.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

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
APACHE_PORT="${APACHE_PORT:-80}"
CREDS_FILE="/root/projectsend_credentials.txt"

# Guess a local IP for the vhost / final instructions if not given.
# Deliberately avoided calling out to an external "what's my IP" service
# here - if DNS/networking on the host doesn't respond cleanly, that kind
# of call can hang well past its timeout and stall the whole script.
DETECTED_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
if [[ -z "${SITE_DOMAIN:-}" ]]; then
    SITE_DOMAIN="${DETECTED_IP:-_}"
fi

# ---------------------------------------------------------------------------
# 0a. Interactive prompt helpers
#
# When this script is run as `curl -fsSL ... | sudo bash`, stdin is the
# *script itself*, not the keyboard. A plain `read` would eat the script's
# own remaining lines (or hit EOF immediately). Reading from /dev/tty talks
# to the controlling terminal directly, which works for both the piped
# one-liner and a normal `sudo ./install-projectsend.sh` run over SSH.
# ---------------------------------------------------------------------------
INTERACTIVE=1
if [[ -n "${NONINTERACTIVE:-}" ]]; then
    INTERACTIVE=0
elif [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    INTERACTIVE=0
fi

# Character set that is safe both inside a sed replacement and inside a
# single-quoted SQL string in the heredoc below.
PASS_CHARSET_RE='^[A-Za-z0-9_.@#%^+=-]+$'
IDENT_CHARSET_RE='^[A-Za-z0-9_]+$'

say() { printf '%s\n' "$*" > /dev/tty; }

gen_password() {
    # Note: read a *finite* chunk of /dev/urandom and slice it in bash.
    # The classic `tr </dev/urandom | head` pattern gets tr killed with
    # SIGPIPE when head exits, and with `set -o pipefail` that aborts the
    # whole script with exit code 141 and no error message.
    local raw
    raw="$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
    printf '%s' "${raw:0:24}"
}

# ask <varname> <prompt text> <default>
ask() {
    local __var="$1" __text="$2" __default="$3" __reply=""
    if [[ "${INTERACTIVE}" -eq 1 ]]; then
        printf '  %s [%s]: ' "${__text}" "${__default}" > /dev/tty
        IFS= read -r __reply < /dev/tty || __reply=""
    fi
    [[ -z "${__reply}" ]] && __reply="${__default}"
    printf -v "${__var}" '%s' "${__reply}"
}

# ask_secret <varname> <prompt text>
ask_secret() {
    local __var="$1" __text="$2" __reply=""
    printf '  %s: ' "${__text}" > /dev/tty
    IFS= read -rs __reply < /dev/tty || __reply=""
    printf '\n' > /dev/tty
    printf -v "${__var}" '%s' "${__reply}"
}

# ---------------------------------------------------------------------------
# 0b. Gather settings
# ---------------------------------------------------------------------------
echo "=================================================================="
echo " ProjectSend installer"
echo "=================================================================="

if [[ "${INTERACTIVE}" -eq 1 ]]; then
    say ""
    say "Press Enter at any prompt to accept the [default] shown."
    say ""
fi

# --- database name ---------------------------------------------------------
if [[ -n "${DB_NAME:-}" ]]; then
    DB_NAME_SOURCE="environment"
else
    DB_NAME_SOURCE="default"
    while true; do
        ask DB_NAME "Database name" "projectsend"
        if [[ "${DB_NAME}" =~ ${IDENT_CHARSET_RE} && "${#DB_NAME}" -le 63 ]]; then
            break
        fi
        if [[ "${INTERACTIVE}" -eq 0 ]]; then
            echo "Invalid DB_NAME and no terminal to re-prompt; aborting." >&2
            exit 1
        fi
        say "    ! Use letters, digits and underscores only (max 63 chars)."
    done
    [[ "${DB_NAME}" != "projectsend" ]] && DB_NAME_SOURCE="entered"
fi

if [[ ! "${DB_NAME}" =~ ${IDENT_CHARSET_RE} ]]; then
    echo "DB_NAME contains unsupported characters (letters, digits, _ only)." >&2
    exit 1
fi

# --- database user ---------------------------------------------------------
if [[ -n "${DB_USER:-}" ]]; then
    DB_USER_SOURCE="environment"
else
    DB_USER_SOURCE="default"
    while true; do
        ask DB_USER "Database username" "projectsend"
        # MariaDB caps usernames at 32 characters.
        if [[ "${DB_USER}" =~ ${IDENT_CHARSET_RE} && "${#DB_USER}" -le 32 ]]; then
            break
        fi
        if [[ "${INTERACTIVE}" -eq 0 ]]; then
            echo "Invalid DB_USER and no terminal to re-prompt; aborting." >&2
            exit 1
        fi
        say "    ! Use letters, digits and underscores only (max 32 chars)."
    done
    [[ "${DB_USER}" != "projectsend" ]] && DB_USER_SOURCE="entered"
fi

if [[ ! "${DB_USER}" =~ ${IDENT_CHARSET_RE} || "${#DB_USER}" -gt 32 ]]; then
    echo "DB_USER is invalid (letters, digits, _ only; max 32 chars)." >&2
    exit 1
fi

# --- database password -----------------------------------------------------
# A user-supplied password ends up in both a sed replacement and a SQL
# heredoc, so it is restricted to characters that are safe in both contexts.
if [[ -n "${DB_PASS:-}" ]]; then
    DB_PASS_SOURCE="environment"
    if [[ ! "${DB_PASS}" =~ ${PASS_CHARSET_RE} ]]; then
        echo "DB_PASS contains unsupported characters." >&2
        echo "Allowed: letters, digits, and _ . @ # % ^ + = -" >&2
        exit 1
    fi
elif [[ "${INTERACTIVE}" -eq 0 ]]; then
    DB_PASS="$(gen_password)"
    DB_PASS_SOURCE="generated"
else
    say ""
    say "  Database password for '${DB_USER}'."
    say "  Allowed characters: letters, digits, and _ . @ # % ^ + = -"
    say "  Minimum 8 characters. Leave blank to auto-generate a strong one."
    while true; do
        ask_secret PS_PASS1 "Database password"

        if [[ -z "${PS_PASS1}" ]]; then
            DB_PASS="$(gen_password)"
            DB_PASS_SOURCE="generated"
            say "    -> Blank entry: a strong random password will be generated."
            break
        fi

        if [[ "${#PS_PASS1}" -lt 8 ]]; then
            say "    ! Too short - please use at least 8 characters."
            continue
        fi

        if [[ ! "${PS_PASS1}" =~ ${PASS_CHARSET_RE} ]]; then
            say "    ! Unsupported character. Allowed: letters, digits, _ . @ # % ^ + = -"
            continue
        fi

        ask_secret PS_PASS2 "Confirm password"
        if [[ "${PS_PASS1}" != "${PS_PASS2}" ]]; then
            say "    ! Passwords did not match - try again."
            continue
        fi

        DB_PASS="${PS_PASS1}"
        DB_PASS_SOURCE="entered"
        break
    done
    unset PS_PASS1 PS_PASS2
fi

# --- confirm ---------------------------------------------------------------
echo ""
echo "------------------------------------------------------------------"
echo " About to install with these settings:"
echo "   App directory : ${APP_DIR}"
echo "   Database name : ${DB_NAME}"
echo "   Database user : ${DB_USER}"
if [[ "${DB_PASS_SOURCE}" == "generated" ]]; then
    echo "   DB password   : (auto-generated, shown at the end)"
else
    echo "   DB password   : (${DB_PASS_SOURCE}, shown at the end)"
fi
echo "   Vhost address : ${SITE_DOMAIN}:${APACHE_PORT}"
echo "------------------------------------------------------------------"

if [[ "${INTERACTIVE}" -eq 1 ]]; then
    ask PS_CONFIRM "Continue? (y/n)" "y"
    if [[ ! "${PS_CONFIRM}" =~ ^[Yy] ]]; then
        echo "Aborted at user request."
        exit 0
    fi
    unset PS_CONFIRM
fi
echo ""

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
    unzip git

# ---------------------------------------------------------------------------
# 2. PHP - ProjectSend r2029+ requires PHP 8.2 or newer.
#    Debian 12 (bookworm) ships PHP 8.2 by default; Debian 11 (bullseye)
#    ships PHP 7.4, which is too old, so we add the Sury PHP repo when the
#    distro's own PHP is below 8.2.
# ---------------------------------------------------------------------------
NEED_SURY=0
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
-- Always (re)set the password so re-runs keep MariaDB in sync with the
-- freshly written sys.config.php even if the user already existed.
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# Verify the credentials actually work before we bake them into the config.
if ! mysql -h 127.0.0.1 -u "${DB_USER}" -p"${DB_PASS}" -e "USE \`${DB_NAME}\`;" >/dev/null 2>&1; then
    echo "WARNING: could not verify the database login over TCP." >&2
    echo "         Continuing - ProjectSend connects via localhost socket." >&2
fi

# ---------------------------------------------------------------------------
# 5. Download the latest ProjectSend release from GitHub.
#    IMPORTANT: use the built release asset (projectsend-rXXXX.zip), NOT the
#    source code archive. The source archive lacks the compiled CSS/JS assets
#    and the composer vendor/ folder, resulting in an unstyled, broken UI.
# ---------------------------------------------------------------------------
echo ">>> Looking up the latest ProjectSend release..."
RELEASE_JSON="$(curl -fsSL https://api.github.com/repos/projectsend/projectsend/releases/latest)"
LATEST_TAG="$(echo "${RELEASE_JSON}" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/')"
ZIP_URL="$(echo "${RELEASE_JSON}" | grep -m1 '"browser_download_url"' | sed -E 's/.*"browser_download_url":\s*"([^"]+)".*/\1/')"

if [[ -z "${LATEST_TAG}" || -z "${ZIP_URL}" ]]; then
    echo "Could not determine the latest ProjectSend release; aborting." >&2
    exit 1
fi

echo ">>> Latest release: ${LATEST_TAG} (${ZIP_URL})"

WORK_DIR="$(mktemp -d)"
curl -fsSL "${ZIP_URL}" -o "${WORK_DIR}/projectsend.zip"

# The built release zip extracts flat (files at the zip root, no wrapper
# directory), so extract directly into a staging folder.
mkdir -p "${WORK_DIR}/app"
unzip -q "${WORK_DIR}/projectsend.zip" -d "${WORK_DIR}/app"

# Support both layouts just in case: flat, or a single wrapper directory.
if [[ -f "${WORK_DIR}/app/index.php" ]]; then
    EXTRACTED_DIR="${WORK_DIR}/app"
else
    EXTRACTED_DIR="$(find "${WORK_DIR}/app" -maxdepth 1 -mindepth 1 -type d | head -1)"
fi

if [[ -z "${EXTRACTED_DIR}" || ! -f "${EXTRACTED_DIR}/index.php" ]]; then
    echo "Extracted ProjectSend archive doesn't look right; aborting." >&2
    exit 1
fi

mkdir -p "$(dirname "${APP_DIR}")"
BACKUP_DIR=""
if [[ -d "${APP_DIR}" ]]; then
    BACKUP_DIR="${APP_DIR}.bak.$(date +%s)"
    echo ">>> ${APP_DIR} already exists - backing it up to ${BACKUP_DIR}"
    mv "${APP_DIR}" "${BACKUP_DIR}"
fi
mv "${EXTRACTED_DIR}" "${APP_DIR}"
rm -rf "${WORK_DIR}"

# The built release ships its vendor/ folder, so no composer install is
# required. Keep composer available anyway for future maintenance.

# ---------------------------------------------------------------------------
# 6. Write sys.config.php with the database credentials
# ---------------------------------------------------------------------------
CONFIG_FILE="${APP_DIR}/includes/sys.config.php"
cp "${APP_DIR}/includes/sys.config.sample.php" "${CONFIG_FILE}"

sed -i \
    -e "s/define('DB_NAME', 'database');/define('DB_NAME', '${DB_NAME}');/" \
    -e "s/define('DB_HOST', 'localhost');/define('DB_HOST', 'localhost');/" \
    -e "s/define('DB_USER', 'username');/define('DB_USER', '${DB_USER}');/" \
    -e "s/define('DB_PASSWORD', 'password');/define('DB_PASSWORD', '${DB_PASS}');/" \
    "${CONFIG_FILE}"

# Sanity check: make sure the placeholders really were replaced. If upstream
# ever renames them, the install would otherwise fail later with a confusing
# "access denied" in the browser.
for token in "${DB_NAME}" "${DB_USER}" "${DB_PASS}"; do
    if ! grep -qF "${token}" "${CONFIG_FILE}"; then
        echo "WARNING: expected value not found in ${CONFIG_FILE}." >&2
        echo "         Check the DB settings in that file before continuing." >&2
        break
    fi
done

# ---------------------------------------------------------------------------
# 7. Ownership and permissions (per ProjectSend docs: dirs 775, files 644)
# ---------------------------------------------------------------------------
chown -R www-data:www-data "${APP_DIR}"
find "${APP_DIR}" -type d -exec chmod 775 {} \;
find "${APP_DIR}" -type f -exec chmod 644 {} \;
# The config file holds the DB password - keep it off other local accounts.
chmod 640 "${CONFIG_FILE}"

# ---------------------------------------------------------------------------
# 8. Apache vhost
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
# 9. Firewall (only if ufw is installed and active)
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow "${APACHE_PORT}/tcp" || true
fi

# ---------------------------------------------------------------------------
# 10. Save credentials and print the recap
# ---------------------------------------------------------------------------
ALL_IPS="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | paste -sd ', ' - || true)"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo 'unknown')"
if [[ "${APACHE_PORT}" == "80" ]]; then
    BASE_URL="http://${SITE_DOMAIN}"
else
    BASE_URL="http://${SITE_DOMAIN}:${APACHE_PORT}"
fi
INSTALL_URL="${BASE_URL}/install"

cat > "${CREDS_FILE}" <<EOF
ProjectSend installation summary
=================================
Generated : $(date '+%Y-%m-%d %H:%M:%S %Z')

Server
  Hostname      : ${HOSTNAME_FQDN}
  IP address(es): ${ALL_IPS:-unknown}
  Site URL      : ${BASE_URL}
  Install URL   : ${INSTALL_URL}

Application
  Release       : ${LATEST_TAG}
  App directory : ${APP_DIR}
  Config file   : ${CONFIG_FILE}
  Apache vhost  : ${VHOST_FILE}
  Apache port   : ${APACHE_PORT}

Database (MariaDB)
  Host          : localhost
  Name          : ${DB_NAME}
  Username      : ${DB_USER}
  Password      : ${DB_PASS}
  CLI login     : mysql -u ${DB_USER} -p ${DB_NAME}

Next step (required, one time):
  Open ${INSTALL_URL} in a browser and complete ProjectSend's
  installer wizard. It asks for the database details above and then
  creates the tables and your admin account.
EOF
chmod 600 "${CREDS_FILE}"

echo ""
echo "=================================================================="
echo "  ProjectSend installation complete"
echo "=================================================================="
echo ""
echo "  SERVER"
echo "    Hostname        : ${HOSTNAME_FQDN}"
echo "    IP address(es)  : ${ALL_IPS:-unknown}"
echo "    Site URL        : ${BASE_URL}"
echo "    Apache port     : ${APACHE_PORT}"
echo ""
echo "  DATABASE  (you will need these on the install page)"
echo "    Host            : localhost"
echo "    Database name   : ${DB_NAME}"
echo "    Username        : ${DB_USER}"
echo "    Password        : ${DB_PASS}"
if [[ "${DB_PASS_SOURCE}" == "generated" ]]; then
    echo "                      ^ auto-generated - copy it now"
fi
echo ""
echo "  APPLICATION"
echo "    Release         : ${LATEST_TAG}"
echo "    App directory   : ${APP_DIR}"
echo "    Config file     : ${CONFIG_FILE}"
if [[ -n "${BACKUP_DIR}" ]]; then
    echo "    Previous install: backed up to ${BACKUP_DIR}"
fi
echo ""
echo "    All of the above is also saved to ${CREDS_FILE}"
echo "    (root-only, chmod 600) - view it later with:"
echo "      sudo cat ${CREDS_FILE}"
echo ""
echo "------------------------------------------------------------------"
echo "  FINAL STEP - open this in a browser to finish setup:"
echo ""
echo "      ${INSTALL_URL}"
echo ""
echo "  Enter the database values shown above when prompted, then create"
echo "  your admin account. ProjectSend has no CLI installer, so this one"
echo "  browser step can't be skipped safely."
echo "=================================================================="
echo ""
