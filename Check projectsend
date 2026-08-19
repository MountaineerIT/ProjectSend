#!/usr/bin/env bash
#
# check-projectsend.sh — read-only health check for a ProjectSend 2.x install.
#
# Changes NOTHING. Safe to run any time, including on a live site.
#
# Checks the things that actually broke or nearly broke on this deployment:
#   * the HTTPS/mixed-content trap (blank white page)
#   * config:cache being present (silently breaks TRUSTED_PROXIES)
#   * response header size vs the proxy buffer (the intermittent 502)
#   * the master email toggle (test mail worked, nothing else did)
#   * queue worker + scheduler actually running, not just enabled
#   * backups existing and being recent
#
# Usage:  sudo ./check-projectsend.sh
#
set -uo pipefail          # deliberately NOT -e: checks are expected to fail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

APP_DIR="${APP_DIR:-/var/www/projectsend}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/projectsend}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/sites-available/projectsend.conf}"
WEB_USER="www-data"
PHP_BIN="$(command -v php8.4 || command -v php || true)"

PASS=0; WARN=0; FAIL=0
G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; N=$'\033[0m'

ok()   { printf "  ${G}[ ok ]${N} %s\n" "$*"; PASS=$((PASS+1)); }
warn() { printf "  ${Y}[warn]${N} %s\n" "$*"; WARN=$((WARN+1)); }
bad()  { printf "  ${R}[FAIL]${N} %s\n" "$*"; FAIL=$((FAIL+1)); }
head_() { printf "\n${B}%s${N}\n" "$*"; }

[[ "${EUID}" -eq 0 ]] || { echo "Run with sudo."; exit 1; }
[[ -d "${APP_DIR}" ]] || { echo "No install at ${APP_DIR}"; exit 1; }

env_get() {
    local line=""
    line="$(grep -E "^${1}=" "${APP_DIR}/.env" 2>/dev/null | head -1 || true)"
    [[ -z "${line}" ]] && { printf ''; return 0; }
    line="${line#*=}"; line="${line%\"}"; line="${line#\"}"
    line="${line%\'}"; line="${line#\'}"
    printf '%s' "${line}"
}

APP_URL="$(env_get APP_URL)"
DB_NAME="$(env_get DB_DATABASE)"
DB_USER="$(env_get DB_USERNAME)"
DB_PASS="$(env_get DB_PASSWORD)"
DB_HOST="$(env_get DB_HOST)"; DB_HOST="${DB_HOST:-127.0.0.1}"
HOSTHDR="$(printf '%s' "${APP_URL}" | sed -E 's#^https?://##; s#[:/].*$##')"
VERSION="$(grep -oE "'version'[[:space:]]*=>[[:space:]]*'[^']+'" "${APP_DIR}/config/projectsend.php" 2>/dev/null \
    | head -1 | sed -E "s/.*'([^']+)'\$/\1/" || true)"
PORT="$(grep -oE 'listen[[:space:]]+[0-9.]*:?[0-9]+' "${NGINX_CONF}" 2>/dev/null \
    | head -1 | grep -oE '[0-9]+$' || true)"; PORT="${PORT:-8080}"

echo "=================================================================="
echo " ProjectSend health check"
echo "   Install : ${APP_DIR}"
echo "   Version : ${VERSION:-unknown}"
echo "   URL     : ${APP_URL:-unset}   (nginx on :${PORT})"
echo "=================================================================="

# ---------------------------------------------------------------- services
head_ "Services"
for svc in nginx php8.4-fpm mariadb projectsend-worker; do
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
        up="$(systemctl show -p ActiveEnterTimestamp --value "${svc}" 2>/dev/null | cut -d' ' -f2-3)"
        ok "${svc} running (since ${up:-?})"
    else
        bad "${svc} is NOT running"
    fi
    systemctl is-enabled --quiet "${svc}" 2>/dev/null || warn "${svc} is not enabled at boot"
done

RESTARTS="$(systemctl show -p NRestarts --value projectsend-worker 2>/dev/null || echo 0)"
[[ "${RESTARTS:-0}" -gt 5 ]] && warn "queue worker has restarted ${RESTARTS} times — check journalctl -u projectsend-worker"

# --------------------------------------------------------------- scheduler
head_ "Scheduler"
if crontab -u "${WEB_USER}" -l 2>/dev/null | grep -q 'artisan schedule:run'; then
    ok "scheduler cron entry present for ${WEB_USER}"
else
    bad "no 'artisan schedule:run' cron for ${WEB_USER} — daily housekeeping never runs"
fi
systemctl is-active --quiet cron 2>/dev/null && ok "cron daemon running" || bad "cron daemon is NOT running"

# ------------------------------------------------------------ config / env
head_ "Configuration"
[[ -f "${APP_DIR}/.env" ]] && ok ".env present" || bad ".env MISSING"
grep -q '^APP_KEY=base64:' "${APP_DIR}/.env" 2>/dev/null \
    && ok "APP_KEY is set" || bad "APP_KEY is empty or malformed"
[[ "$(env_get APP_DEBUG)" == "false" ]] \
    && ok "APP_DEBUG=false" || bad "APP_DEBUG is NOT false — error pages will leak configuration"
[[ "${APP_URL}" == https://* ]] \
    && ok "APP_URL is https" || warn "APP_URL is not https (${APP_URL}) — email links will be wrong"
TP="$(env_get TRUSTED_PROXIES)"
if [[ -z "${TP}" ]]; then
    bad "TRUSTED_PROXIES is unset — rate limiting and the download IP log will misbehave behind a proxy"
elif [[ "${TP}" == "*" ]]; then
    warn "TRUSTED_PROXIES=* (any proxy trusted) — fine only if nothing but the proxy can reach :${PORT}"
else
    ok "TRUSTED_PROXIES=${TP}"
fi
[[ "$(env_get SESSION_SECURE_COOKIE)" == "true" ]] \
    && ok "SESSION_SECURE_COOKIE=true" || warn "SESSION_SECURE_COOKIE is not true on an https site"

# THE config:cache TRAP — presence of this file breaks TRUSTED_PROXIES silently
if [[ -f "${APP_DIR}/bootstrap/cache/config.php" ]]; then
    bad "config IS CACHED (bootstrap/cache/config.php exists) — this silently breaks TRUSTED_PROXIES."
    printf "         fix: sudo -u %s %s %s/artisan config:clear\n" "${WEB_USER}" "${PHP_BIN}" "${APP_DIR}"
else
    ok "config is NOT cached (correct for this app)"
fi
for c in routes-v7.php views packages.php; do
    [[ -e "${APP_DIR}/bootstrap/cache/${c}" ]] && ok "cache present: ${c}" >/dev/null
done

# ------------------------------------------------------------------- nginx
head_ "Web server"
if [[ -f "${NGINX_CONF}" ]]; then
    ok "vhost present: ${NGINX_CONF}"
    grep -q 'fastcgi_param HTTPS on' "${NGINX_CONF}" \
        && ok "fastcgi_param HTTPS on — mixed-content fix in place" \
        || bad "MISSING 'fastcgi_param HTTPS on' — assets will load over http:// and the page will render blank"
    grep -q 'internal;' "${NGINX_CONF}" \
        && ok "/protected-files/ is marked internal" \
        || bad "/protected-files/ is NOT internal — uploads may be directly downloadable"
    grep -qE 'root .*/public;' "${NGINX_CONF}" \
        && ok "web root points at public/" || bad "web root does not end in public/"
else
    bad "vhost not found at ${NGINX_CONF}"
fi
nginx -t >/dev/null 2>&1 && ok "nginx config test passes" || bad "nginx -t FAILS"

# -------------------------------------------------------------- filesystem
head_ "Files and permissions"
[[ -d "${APP_DIR}/storage/app/files" ]] \
    && ok "uploads dir exists ($(find "${APP_DIR}/storage/app/files" -type f 2>/dev/null | wc -l) files, $(du -sh "${APP_DIR}/storage/app/files" 2>/dev/null | cut -f1))" \
    || bad "storage/app/files is missing"
[[ -e "${APP_DIR}/public/files" ]] && bad "public/files exists — uploads may be inside the web root" \
    || ok "no uploads inside the web root"
sudo -u "${WEB_USER}" test -w "${APP_DIR}/storage" 2>/dev/null \
    && ok "storage/ writable by ${WEB_USER}" || bad "storage/ NOT writable by ${WEB_USER}"
sudo -u "${WEB_USER}" test -w "${APP_DIR}/bootstrap/cache" 2>/dev/null \
    && ok "bootstrap/cache writable" || bad "bootstrap/cache NOT writable"
ENVMODE="$(stat -c '%a' "${APP_DIR}/.env" 2>/dev/null || echo '?')"
[[ "${ENVMODE}" == "640" || "${ENVMODE}" == "600" ]] \
    && ok ".env mode ${ENVMODE}" || warn ".env mode is ${ENVMODE} — expected 640"
DISK="$(df -P "${APP_DIR}" | awk 'NR==2{print $5}' | tr -d '%')"
[[ "${DISK:-0}" -lt 85 ]] && ok "disk ${DISK}% used" || warn "disk ${DISK}% used on the uploads volume"

# --------------------------------------------------------------- database
head_ "Database"
MY="$(mktemp)"; chmod 600 "${MY}"
printf '[client]\nuser=%s\npassword=%s\nhost=%s\n' "${DB_USER}" "${DB_PASS}" "${DB_HOST}" > "${MY}"
if mysql --defaults-extra-file="${MY}" -e "USE \`${DB_NAME}\`;" >/dev/null 2>&1; then
    ok "app can authenticate to ${DB_NAME}"
    CHARSET="$(mysql --defaults-extra-file="${MY}" -N -B -e \
        "SELECT default_character_set_name FROM information_schema.schemata WHERE schema_name='${DB_NAME}';" 2>/dev/null)"
    [[ "${CHARSET}" == "utf8mb4" ]] && ok "charset utf8mb4" || bad "charset is ${CHARSET} — 2.x requires utf8mb4"
    FAILED="$(mysql --defaults-extra-file="${MY}" -N -B -e "SELECT COUNT(*) FROM \`${DB_NAME}\`.failed_jobs;" 2>/dev/null || echo '?')"
    [[ "${FAILED}" == "0" ]] && ok "0 failed queue jobs" || bad "${FAILED} FAILED queue jobs — inspect the failed_jobs table"
    PENDING="$(mysql --defaults-extra-file="${MY}" -N -B -e "SELECT COUNT(*) FROM \`${DB_NAME}\`.jobs;" 2>/dev/null || echo '?')"
    [[ "${PENDING:-0}" -lt 25 ]] && ok "${PENDING} jobs queued" || warn "${PENDING} jobs queued — worker may be stuck"
    # the email trap: test mail works while everything else is silently off
    EN="$(mysql --defaults-extra-file="${MY}" -N -B -e \
        "SELECT value FROM \`${DB_NAME}\`.settings WHERE \`key\`='email_notifications_enabled';" 2>/dev/null)"
    [[ "${EN}" == "true" || "${EN}" == "1" ]] \
        && ok "email notifications ENABLED" \
        || bad "email_notifications_enabled=${EN:-unset} — test emails will work but NO event emails will send"
    AE="$(mysql --defaults-extra-file="${MY}" -N -B -e \
        "SELECT value FROM \`${DB_NAME}\`.settings WHERE \`key\`='admin_notification_emails';" 2>/dev/null)"
    [[ -n "${AE}" && "${AE}" != "[]" ]] \
        && ok "admin notification addresses: ${AE}" \
        || bad "admin_notification_emails is empty — nobody is told about client uploads or registrations"
else
    bad "cannot authenticate to the database as ${DB_USER}"
fi
rm -f "${MY}"

if [[ -n "${PHP_BIN}" ]]; then
    PEND="$(sudo -u "${WEB_USER}" "${PHP_BIN}" "${APP_DIR}/artisan" migrate:status 2>/dev/null | grep -c 'Pending' || true)"
    [[ "${PEND:-0}" -eq 0 ]] && ok "no pending migrations" || bad "${PEND} PENDING migrations — run artisan migrate --force"
fi

# ------------------------------------------------------------ live request
head_ "Live response"
HDR="$(mktemp)"
CODE="$(curl -s -o /dev/null -D "${HDR}" -w '%{http_code}' --max-time 20 \
        -H "Host: ${HOSTHDR}" -H "X-Forwarded-Proto: https" \
        "http://127.0.0.1:${PORT}/login" 2>/dev/null || echo 000)"
BYTES="$(curl -s -o /dev/null -w '%{size_download}' --max-time 20 \
        -H "Host: ${HOSTHDR}" -H "X-Forwarded-Proto: https" \
        "http://127.0.0.1:${PORT}/login" 2>/dev/null || echo 0)"
if [[ "${CODE}" == "200" && "${BYTES}" -gt 1000 ]]; then
    ok "login page: HTTP ${CODE}, ${BYTES} bytes"
else
    bad "login page: HTTP ${CODE}, ${BYTES} bytes (expected 200 and tens of kB)"
fi

# asset URLs must be https, or the browser blocks them and the page renders blank
SCHEME="$(curl -s --max-time 20 -H "Host: ${HOSTHDR}" -H "X-Forwarded-Proto: https" \
    "http://127.0.0.1:${PORT}/login" 2>/dev/null | grep -oE 'https?://[^"]*build/assets/[^"]*\.js' | head -1 || true)"
case "${SCHEME}" in
    https://*) ok "asset URLs are https (no mixed content)" ;;
    http://*)  bad "asset URLs are http:// on an https site — browsers will block them, page renders BLANK" ;;
    *)         warn "could not sample an asset URL from the login page" ;;
esac

# header size vs proxy buffer — the cause of the intermittent 502
HSIZE="$(wc -c < "${HDR}" 2>/dev/null || echo 0)"
if   [[ "${HSIZE}" -lt 3000 ]]; then ok "response headers ${HSIZE} bytes"
elif [[ "${HSIZE}" -lt 3900 ]]; then warn "response headers ${HSIZE} bytes — close to a default 4096-byte proxy buffer"
else bad "response headers ${HSIZE} bytes — exceeds a default 4096 proxy buffer; raise proxy_buffer_size on BunkerWeb"
fi
rm -f "${HDR}"

# --------------------------------------------------------------- firewall
head_ "Firewall"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ok "ufw active"
    if ufw status 2>/dev/null | grep -E "^${PORT}/tcp" | grep -qi 'Anywhere'; then
        bad "port ${PORT} is open to Anywhere — the app is reachable bypassing the proxy"
    else
        ok "port ${PORT} restricted to specific sources"
    fi
else
    warn "ufw not active"
fi

# ---------------------------------------------------------------- backups
head_ "Backups"
if [[ -d "${BACKUP_DIR}" ]]; then
    LATEST="$(ls -1t "${BACKUP_DIR}"/*.sql.gz 2>/dev/null | head -1 || true)"
    if [[ -n "${LATEST}" ]]; then
        AGE=$(( ( $(date +%s) - $(stat -c %Y "${LATEST}") ) / 86400 ))
        [[ "${AGE}" -le 7 ]] && ok "latest DB backup ${AGE}d old ($(basename "${LATEST}"))" \
                             || warn "latest DB backup is ${AGE} days old"
    else
        bad "no database backups in ${BACKUP_DIR}"
    fi
else
    bad "no backup directory — nothing is being backed up"
fi

# ----------------------------------------------------------------- summary
echo ""
echo "=================================================================="
printf " %sPASS %d${N}   %sWARN %d${N}   %sFAIL %d${N}\n" "${G}" "${PASS}" "${Y}" "${WARN}" "${R}" "${FAIL}"
echo "=================================================================="
[[ "${FAIL}" -eq 0 ]] && echo " No failures. Warnings are worth a look but not urgent." \
                      || echo " Address the FAIL lines above."
echo ""
exit $(( FAIL > 0 ? 1 : 0 ))
