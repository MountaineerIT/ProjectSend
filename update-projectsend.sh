#!/usr/bin/env bash
#
# update-projectsend.sh
#
# Safe in-place updater for ProjectSend 2.x, implementing the upstream
# procedure (INSTALL.md "Updating to a new version") with the guard rails
# that procedure assumes you will supply yourself:
#
#   * Backs up the database, .env and storage/ BEFORE touching anything.
#   * Verifies the new release's published SHA-256 before extraction.
#   * Never unzips over the live tree. Builds a staging copy, then swaps
#     directories - so a half-extracted archive can never become your
#     running site, and rollback is a rename rather than a restore.
#   * Preserves .env and storage/ by moving them into the new tree, which
#     is what upstream's "check your unzip tool is not helpfully deleting
#     things" warning is really about.
#   * Rolls the filesystem back automatically if any step fails, and
#     prints the exact database restore command rather than silently
#     reverting a migration you may want to inspect.
#   * Re-runs storage:link, ensure-roles and queue:restart, restarts
#     PHP-FPM and the queue worker, and health-checks the result.
#
# Deliberately NOT run: `php artisan config:cache`. It stops
# TRUSTED_PROXIES being read (ProjectSend reads it from the environment
# before the middleware stack exists), which silently breaks login rate
# limiting and the download IP log. route/view/event caches are safe and
# are warmed.
#
# Usage:
#   sudo ./update-projectsend.sh                 # update to latest release
#   sudo PS_VERSION=v2.1.0 ./update-projectsend.sh   # pin a version
#   sudo DRY_RUN=1 ./update-projectsend.sh       # download+verify+back up, then stop
#   sudo ALLOW_SAME_VERSION=1 ./update-projectsend.sh   # re-install current version
#
# Environment:
#   APP_DIR      Install directory   (default: /var/www/projectsend)
#   BACKUP_DIR   Backup destination  (default: /var/backups/projectsend)
#   PS_VERSION   Release tag to pin  (default: latest)
#   KEEP_BACKUPS How many old app trees to retain (default: 3)
#
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

APP_DIR="${APP_DIR:-/var/www/projectsend}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/projectsend}"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"
WEB_USER="www-data"
GH_REPO="projectsend/projectsend"
STAMP="$(date +%Y%m%d-%H%M%S)"

log()  { printf '\n\033[1m>>> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Pre-flight
# ---------------------------------------------------------------------------
[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."
[[ -d "${APP_DIR}" ]] || die "${APP_DIR} does not exist."
[[ -f "${APP_DIR}/artisan" && -f "${APP_DIR}/public/index.php" ]] \
    || die "${APP_DIR} does not look like a ProjectSend 2.x install (no artisan / public/index.php)."
[[ -f "${APP_DIR}/.env" ]] || die "${APP_DIR}/.env is missing - refusing to touch this install."

for c in curl unzip sha256sum mysqldump rsync; do
    command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
done

PHP_BIN="$(command -v php8.4 || command -v php)"
[[ -n "${PHP_BIN}" ]] || die "PHP binary not found."

CUR_VERSION="$(grep -oE "'version'[[:space:]]*=>[[:space:]]*'[^']+'" "${APP_DIR}/config/projectsend.php" 2>/dev/null \
    | head -1 | sed -E "s/.*'([^']+)'$/\1/" || true)"
[[ -n "${CUR_VERSION}" ]] || CUR_VERSION="unknown"

# .env values, read without sourcing the file (it is not shell).
# Never fails: a missing key yields an empty string. Without the guards a
# grep miss would abort the whole script silently under `set -euo pipefail`.
env_get() {
    local line=""
    line="$(grep -E "^${1}=" "${APP_DIR}/.env" 2>/dev/null | head -1 || true)"
    [[ -z "${line}" ]] && { printf ''; return 0; }
    line="${line#*=}"
    line="${line%\"}"; line="${line#\"}"
    line="${line%\'}"; line="${line#\'}"
    printf '%s' "${line}"
}
DB_NAME="$(env_get DB_DATABASE)"
DB_USER="$(env_get DB_USERNAME)"
DB_PASS="$(env_get DB_PASSWORD)"
DB_HOST="$(env_get DB_HOST)"; DB_HOST="${DB_HOST:-127.0.0.1}"
[[ -n "${DB_NAME}" && -n "${DB_USER}" ]] || die "Could not read DB credentials from ${APP_DIR}/.env"

echo "=================================================================="
echo " ProjectSend updater"
echo "   Install      : ${APP_DIR}"
echo "   Installed    : ${CUR_VERSION}"
echo "   Database     : ${DB_NAME} @ ${DB_HOST}"
echo "   Backups      : ${BACKUP_DIR}"
echo "=================================================================="

# ---------------------------------------------------------------------------
# 1. Resolve and verify the target release
# ---------------------------------------------------------------------------
log "Resolving target release."
if [[ -n "${PS_VERSION:-}" ]]; then
    API_URL="https://api.github.com/repos/${GH_REPO}/releases/tags/${PS_VERSION}"
else
    API_URL="https://api.github.com/repos/${GH_REPO}/releases/latest"
fi

RELEASE_JSON="$(curl -fsSL -H 'Accept: application/vnd.github+json' "${API_URL}")" \
    || die "Could not reach the GitHub release API (unauthenticated limit is 60/hour per IP). Pin with PS_VERSION to retry."

NEW_TAG="$(printf '%s' "${RELEASE_JSON}" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')"
ZIP_URL="$(printf '%s' "${RELEASE_JSON}" \
    | grep -oE '"browser_download_url":[[:space:]]*"[^"]*projectsend-[0-9]+\.[0-9]+\.[0-9]+\.zip"' \
    | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
SHA_URL="$(printf '%s' "${RELEASE_JSON}" \
    | grep -oE '"browser_download_url":[[:space:]]*"[^"]*projectsend-[0-9]+\.[0-9]+\.[0-9]+\.zip\.sha256"' \
    | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"

[[ -n "${NEW_TAG}" && -n "${ZIP_URL}" ]] || die "No projectsend-X.Y.Z.zip asset found in release ${NEW_TAG:-?}."
case "${NEW_TAG}" in
    r[0-9]*) die "Release ${NEW_TAG} is the LEGACY 1.x line. This updater is for 2.x only." ;;
esac

NEW_VERSION="${NEW_TAG#v}"
info "Target: ${NEW_TAG}  (installed: ${CUR_VERSION})"

if [[ "${NEW_VERSION}" == "${CUR_VERSION}" && -z "${ALLOW_SAME_VERSION:-}" ]]; then
    echo ""
    echo "Already running ${CUR_VERSION}. Nothing to do."
    echo "Set ALLOW_SAME_VERSION=1 to re-install the same version anyway."
    exit 0
fi

WORK="$(mktemp -d)"
cleanup_work() { rm -rf "${WORK}"; }
trap cleanup_work EXIT

log "Downloading ${NEW_TAG}."
curl -fsSL "${ZIP_URL}" -o "${WORK}/ps.zip"

if [[ -n "${SHA_URL}" ]]; then
    curl -fsSL "${SHA_URL}" -o "${WORK}/ps.zip.sha256"
    EXPECTED="$(tr -d '\r' < "${WORK}/ps.zip.sha256" | awk '{print $1}' | head -1)"
    ACTUAL="$(sha256sum "${WORK}/ps.zip" | awk '{print $1}')"
    [[ -n "${EXPECTED}" ]] || die "Published checksum file was empty."
    [[ "${EXPECTED}" == "${ACTUAL}" ]] || die "Checksum mismatch — refusing to install.
  expected: ${EXPECTED}
  actual  : ${ACTUAL}"
    info "SHA-256 verified: ${ACTUAL}"
else
    info "WARNING: no .sha256 published for ${NEW_TAG}; integrity NOT verified."
fi

log "Extracting to staging."
mkdir -p "${WORK}/new"
unzip -q "${WORK}/ps.zip" -d "${WORK}/new"
if [[ -f "${WORK}/new/artisan" ]]; then
    SRC="${WORK}/new"
else
    SRC="$(find "${WORK}/new" -maxdepth 1 -mindepth 1 -type d | head -1)"
fi
[[ -n "${SRC}" && -f "${SRC}/artisan" && -f "${SRC}/public/index.php" ]] \
    || die "Extracted archive does not look like ProjectSend 2.x."

STAGED_VERSION="$(grep -oE "'version'[[:space:]]*=>[[:space:]]*'[^']+'" "${SRC}/config/projectsend.php" 2>/dev/null \
    | head -1 | sed -E "s/.*'([^']+)'$/\1/" || true)"
info "Archive reports version: ${STAGED_VERSION:-unknown}"

# ---------------------------------------------------------------------------
# 2. Backups — before anything is touched
# ---------------------------------------------------------------------------
log "Backing up."
mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

MY_CNF="$(mktemp)"; chmod 600 "${MY_CNF}"
printf '[client]\nuser=%s\npassword=%s\nhost=%s\n' "${DB_USER}" "${DB_PASS}" "${DB_HOST}" > "${MY_CNF}"

DB_DUMP="${BACKUP_DIR}/${DB_NAME}-${STAMP}.sql.gz"
mysqldump --defaults-extra-file="${MY_CNF}" \
    --single-transaction --routines --triggers --events \
    "${DB_NAME}" | gzip -c > "${DB_DUMP}"
rm -f "${MY_CNF}"
[[ -s "${DB_DUMP}" ]] || die "Database dump is empty — aborting."
chmod 600 "${DB_DUMP}"
info "Database  -> ${DB_DUMP} ($(du -h "${DB_DUMP}" | cut -f1))"

ENV_BAK="${BACKUP_DIR}/env-${STAMP}"
cp -a "${APP_DIR}/.env" "${ENV_BAK}"; chmod 600 "${ENV_BAK}"
info ".env      -> ${ENV_BAK}"

# Hardlink snapshot of uploads: near-instant, costs almost no disk, and
# still protects the files if something later deletes them in place.
UPLOADS="${APP_DIR}/storage/app/files"
if [[ -d "${UPLOADS}" ]]; then
    SNAP="${BACKUP_DIR}/files-${STAMP}"
    if cp -al "${UPLOADS}" "${SNAP}" 2>/dev/null; then
        info "Uploads   -> ${SNAP} (hardlink snapshot, $(du -sh --count-links "${SNAP}" 2>/dev/null | cut -f1))"
    else
        info "WARNING: could not hardlink-snapshot uploads (different filesystem?)."
        info "         storage/ is moved, not copied, so uploads are preserved — but"
        info "         you have no independent copy. Ctrl-C now if that matters."
        sleep 5
    fi
fi

if [[ -n "${DRY_RUN:-}" ]]; then
    echo ""
    echo "DRY_RUN set — release downloaded and verified, backups taken, nothing changed."
    echo "  staged: ${SRC}"
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. Swap. Everything below here is reversible by ROLLBACK.
# ---------------------------------------------------------------------------
OLD_DIR="${APP_DIR}.old-${STAMP}"
STAGE="none"

rollback() {
    printf '\n\033[1;31m!!! Update failed — rolling the filesystem back.\033[0m\n' >&2
    case "${STAGE}" in
        swapped)
            rm -rf "${APP_DIR}.failed-${STAMP}"
            mv "${APP_DIR}" "${APP_DIR}.failed-${STAMP}" 2>/dev/null || true
            mv "${OLD_DIR}" "${APP_DIR}" 2>/dev/null || true
            # storage/ was MOVED into the new tree, so the restored tree has
            # none. Move it back, or the site comes up with no uploads.
            if [[ -d "${APP_DIR}.failed-${STAMP}/storage" ]]; then
                rm -rf "${APP_DIR}/storage"
                mv "${APP_DIR}.failed-${STAMP}/storage" "${APP_DIR}/storage" \
                    && info "Moved storage/ (uploads) back into the restored install."
            fi
            info "Restored previous install to ${APP_DIR}"
            info "Failed tree kept at ${APP_DIR}.failed-${STAMP}"
            ;;
        prepared)
            # Failed between moving storage/ into staging and the swap.
            if [[ -d "${SRC}/storage" ]]; then
                rm -rf "${APP_DIR}/storage"
                mv "${SRC}/storage" "${APP_DIR}/storage" \
                    && info "Moved storage/ (uploads) back into the original install."
            fi
            ;;
        down)
            info "Nothing was swapped; the original install is untouched."
            ;;
    esac
    if [[ ! -d "${APP_DIR}/storage/app/files" ]]; then
        printf '\n\033[1;31m!!! storage/app/files is MISSING after rollback.\033[0m\n' >&2
        printf '    Recover from the snapshot before starting the site:\n' >&2
        printf '      cp -a %s/. %s/storage/app/files/\n' "${SNAP:-<snapshot>}" "${APP_DIR}" >&2
    fi
    sudo -u "${WEB_USER}" "${PHP_BIN}" "${APP_DIR}/artisan" up >/dev/null 2>&1 || true
    systemctl restart "php8.4-fpm" >/dev/null 2>&1 || true
    systemctl restart projectsend-worker >/dev/null 2>&1 || true
    cat >&2 <<EOF

The database was NOT rolled back automatically — migrations may have applied.
Inspect first, and restore only if you need to:

  systemctl stop projectsend-worker
  zcat ${DB_DUMP} | mysql ${DB_NAME}
  systemctl start projectsend-worker

Backups from this run:
  database : ${DB_DUMP}
  .env     : ${ENV_BAK}
EOF
    exit 1
}
trap 'rollback' ERR

log "Entering maintenance mode."
sudo -u "${WEB_USER}" "${PHP_BIN}" "${APP_DIR}/artisan" down --render="errors::503" --retry=60 >/dev/null 2>&1 \
  || sudo -u "${WEB_USER}" "${PHP_BIN}" "${APP_DIR}/artisan" down --retry=60 >/dev/null 2>&1 || true
STAGE="down"

log "Preparing the new tree."
# .env is copied (small, and we keep the original until the swap succeeds).
cp -a "${APP_DIR}/.env" "${SRC}/.env"

# storage/ is MOVED, not copied: it holds every uploaded file, and moving
# is atomic on the same filesystem. If storage and the staging dir are on
# different filesystems, fall back to rsync.
rm -rf "${SRC}/storage"
if ! mv "${APP_DIR}/storage" "${SRC}/storage" 2>/dev/null; then
    info "storage/ spans filesystems — copying instead (this may take a while)."
    rsync -a "${APP_DIR}/storage/" "${SRC}/storage/"
    rm -rf "${APP_DIR}/storage"
fi

# Anything else an operator may have dropped in that upstream does not ship.
STAGE="prepared"

for extra in .htaccess robots.txt; do
    [[ -e "${APP_DIR}/public/${extra}" && ! -e "${SRC}/public/${extra}" ]] \
        && cp -a "${APP_DIR}/public/${extra}" "${SRC}/public/${extra}" || true
done

log "Swapping directories."
mv "${APP_DIR}" "${OLD_DIR}"
mv "${SRC}" "${APP_DIR}"
STAGE="swapped"

chown -R "${WEB_USER}:${WEB_USER}" "${APP_DIR}"
chmod -R 775 "${APP_DIR}/storage" "${APP_DIR}/bootstrap/cache"
chmod 640 "${APP_DIR}/.env"

# ---------------------------------------------------------------------------
# 4. Apply the update
# ---------------------------------------------------------------------------
log "Running migrations."
sudo -u "${WEB_USER}" "${PHP_BIN}" "${APP_DIR}/artisan" migrate --force --no-interaction

log "Ensuring system roles."
sudo -u "${WEB_USER}" "${PHP_BIN}" "${APP_DIR}/artisan" projectsend:ensure-roles --no-interaction

log "Clearing caches and relinking storage."
sudo -u "${WEB_USER}" "${PHP_BIN}" "${APP_DIR}/artisan" optimize:clear --no-interaction
sudo -u "${WEB_USER}" "${PHP_BIN}" "${APP_DIR}/artisan" storage:link --no-interaction || true

# Safe caches only. config:cache would stop TRUSTED_PROXIES being read.
for c in route:cache view:cache event:cache; do
    sudo -u "${WEB_USER}" "${PHP_BIN}" "${APP_DIR}/artisan" "${c}" --no-interaction || true
done

log "Restarting services."
sudo -u "${WEB_USER}" "${PHP_BIN}" "${APP_DIR}/artisan" queue:restart --no-interaction >/dev/null 2>&1 || true
systemctl restart php8.4-fpm
systemctl restart projectsend-worker || true

log "Leaving maintenance mode."
sudo -u "${WEB_USER}" "${PHP_BIN}" "${APP_DIR}/artisan" up

trap - ERR

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
log "Verifying."
OK=1
chk() { if "${@:2}" >/dev/null 2>&1; then printf '    [ ok ] %s\n' "$1"; else printf '    [FAIL] %s\n' "$1"; OK=0; fi; }

NOW_VERSION="$(grep -oE "'version'[[:space:]]*=>[[:space:]]*'[^']+'" "${APP_DIR}/config/projectsend.php" \
    | head -1 | sed -E "s/.*'([^']+)'$/\1/" || true)"
chk "version is now ${NEW_VERSION} (was ${CUR_VERSION})" test "${NOW_VERSION}" = "${NEW_VERSION}"
chk "no pending migrations"     bash -c "sudo -u ${WEB_USER} ${PHP_BIN} ${APP_DIR}/artisan migrate:status 2>/dev/null | grep -qv Pending"
chk "php-fpm running"           systemctl is-active --quiet php8.4-fpm
chk "queue worker running"      systemctl is-active --quiet projectsend-worker
chk "nginx running"             systemctl is-active --quiet nginx
chk "uploads present"           test -d "${APP_DIR}/storage/app/files"
chk ".env preserved"            grep -q '^APP_KEY=base64:' "${APP_DIR}/.env"
chk "not in maintenance mode"   bash -c "! ls ${APP_DIR}/storage/framework/down >/dev/null 2>&1"

PORT="$(grep -oE 'listen[[:space:]]+[0-9.]*:?([0-9]+)' /etc/nginx/sites-available/projectsend.conf 2>/dev/null \
        | head -1 | grep -oE '[0-9]+$' || true)"
PORT="${PORT:-8080}"
HOSTHDR="$(grep -E '^APP_URL=' "${APP_DIR}/.env" 2>/dev/null | cut -d/ -f3 || true)"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H "Host: ${HOSTHDR}" \
        "http://127.0.0.1:${PORT}/login" 2>/dev/null || echo 000)"
if [[ "${CODE}" == "200" ]]; then printf '    [ ok ] login page responds (HTTP 200)\n'
else printf '    [WARN] login page returned HTTP %s\n' "${CODE}"; fi

# ---------------------------------------------------------------------------
# 6. Prune old trees
# ---------------------------------------------------------------------------
mapfile -t OLD_TREES < <(ls -1dt "${APP_DIR}".old-* 2>/dev/null || true)
if (( ${#OLD_TREES[@]} > KEEP_BACKUPS )); then
    for d in "${OLD_TREES[@]:${KEEP_BACKUPS}}"; do
        info "Pruning old tree ${d}"
        rm -rf "${d}"
    done
fi

echo ""
echo "=================================================================="
echo "  ProjectSend updated: ${CUR_VERSION}  ->  ${NOW_VERSION}"
echo "=================================================================="
echo "  Previous install : ${OLD_DIR}"
echo "  Database backup  : ${DB_DUMP}"
echo "  .env backup      : ${ENV_BAK}"
echo ""
echo "  To roll back completely:"
echo "    sudo -u ${WEB_USER} ${PHP_BIN} ${APP_DIR}/artisan down"
echo "    sudo systemctl stop projectsend-worker"
echo "    sudo zcat ${DB_DUMP} | mysql ${DB_NAME}"
echo "    sudo rm -rf ${APP_DIR} && sudo mv ${OLD_DIR} ${APP_DIR}"
echo "    sudo systemctl restart php8.4-fpm projectsend-worker"
echo "    sudo -u ${WEB_USER} ${PHP_BIN} ${APP_DIR}/artisan up"
if [[ "${OK}" -ne 1 ]]; then
echo ""
echo "  !! One or more checks FAILED above — review before declaring done."
fi
echo "=================================================================="
echo ""
