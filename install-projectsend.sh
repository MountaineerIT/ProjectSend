#!/usr/bin/env bash
#
# One-shot repo update: unpack projectsend-repo.zip over your clone, stage the
# rename of the old installer, commit, and push.
#
# Usage:
#   1. Download projectsend-repo.zip next to this script.
#   2. cd into your local clone of MountaineerIT/ProjectSend
#   3. bash UPDATE-GITHUB.sh /path/to/projectsend-repo.zip
#
set -euo pipefail

ZIP="${1:-}"
[[ -n "${ZIP}" && -f "${ZIP}" ]] || { echo "Usage: bash UPDATE-GITHUB.sh /path/to/projectsend-repo.zip" >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Run this from inside your git clone." >&2; exit 1; }

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo ">>> Repo: $(git remote get-url origin 2>/dev/null || echo '(no origin)')  branch: ${BRANCH}"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "!! You have uncommitted changes. Commit or stash them first." >&2
    git status --short >&2
    exit 1
fi

echo ">>> Pulling latest."
git pull --ff-only

# Preserve history for the old installer by renaming it rather than
# deleting-and-adding, so `git log --follow` still works.
if [[ -f install-projectsend.sh ]]; then
    echo ">>> Moving install-projectsend.sh -> legacy/install-projectsend-legacy.sh"
    mkdir -p legacy
    git mv install-projectsend.sh legacy/install-projectsend-legacy.sh
fi

echo ">>> Unpacking new files."
unzip -oq "${ZIP}" -d .

chmod +x install-projectsend2.sh legacy/install-projectsend-legacy.sh

git add -A
if git diff --cached --quiet; then
    echo ">>> Nothing changed. Already up to date."
    exit 0
fi

echo ""
echo ">>> Staged changes:"
git diff --cached --stat
echo ""

git commit -m "Add ProjectSend 2.x installer; move legacy installer to legacy/

ProjectSend 2.0 is a Laravel rewrite with different requirements:
nginx + PHP-FPM (Apache cannot serve it - downloads use X-Accel-Redirect),
PHP 8.4, utf8mb4, .env config, public/ web root, and a required queue
worker and scheduler cron.

install-projectsend2.sh provisions all of that, verifies the release
SHA-256 before extracting, selects the release asset by filename rather
than position, and is built for a reverse proxy terminating TLS in front.

The legacy LAMP installer moves to legacy/ with its known limitations
documented in its header and in the README."

echo ">>> Pushing to origin/${BRANCH}"
git push origin "${BRANCH}"
echo ""
echo ">>> Done. Verify the raw URL resolves (allow ~5 min for GitHub's raw cache):"
echo "    https://raw.githubusercontent.com/MountaineerIT/ProjectSend/${BRANCH}/install-projectsend2.sh"
