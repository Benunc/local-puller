#!/usr/bin/env bash
#
# Pull live WordPress site to local (non-destructive: keeps local wp-config.php
# DB credentials and site URL). Uses WP-CLI on remote to export DB and tarball
# files, then restores locally and runs search-replace.
#
# Config: set env vars or use a .env file (see .env.example). No credentials
# are stored in this file so it can be committed to version control.
#
set -euo pipefail

SCRIPT_DIR="${BASH_SOURCE%/*}"
[[ -d "$SCRIPT_DIR" ]] || SCRIPT_DIR="$PWD"
LOCAL_ROOT="$(cd "$SCRIPT_DIR" && pwd)"
CONFIG_FILE="${PULLER_CONFIG:-$LOCAL_ROOT/.env}"
# Find .env: (1) PULLER_CONFIG, (2) script dir, (3) parent of script dir (site root when in local-puller/), (4) current working dir
if [[ -n "${PULLER_CONFIG:-}" && -f "$CONFIG_FILE" ]]; then
  LOCAL_ROOT="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
elif [[ -f "$CONFIG_FILE" ]]; then
  : # use script-dir .env (LOCAL_ROOT already = script dir)
elif [[ -f "$LOCAL_ROOT/../.env" ]]; then
  CONFIG_FILE="$LOCAL_ROOT/../.env"
  LOCAL_ROOT="$(cd "$LOCAL_ROOT/.." && pwd)"
elif [[ -f "$(pwd)/.env" ]]; then
  CONFIG_FILE="$(pwd)/.env"
  LOCAL_ROOT="$(pwd)"
fi

# Load config from env or .env
if [[ -f "$CONFIG_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  set +a
else
  echo "Error: No .env found. Set PULLER_CONFIG to your .env path, or put .env in: script dir ($LOCAL_ROOT), parent ($(cd "$LOCAL_ROOT/.." 2>/dev/null && pwd)), or cwd ($(pwd)). See .env.example." >&2
  exit 1
fi

# Required: remote
: "${SSH_HOST:?Set SSH_HOST in .env (e.g. your-server-ip)}"
: "${SSH_USER:?Set SSH_USER in .env (e.g. your-ssh-user)}"
: "${REMOTE_WP_PATH:?Set REMOTE_WP_PATH in .env (e.g. /sites/yoursite.com/files)}"

# Required: local
: "${LOCAL_WP_PATH:?Set LOCAL_WP_PATH in .env (e.g. app/public)}"
: "${LOCAL_SITE_URL:?Set LOCAL_SITE_URL in .env (e.g. http://yoursite.local)}"
: "${MYSQL_SOCKET:?Set MYSQL_SOCKET (e.g. /path/to/mysqld.sock)}"

# Local DB (from wp-config; used for drop/import)
: "${LOCAL_DB_NAME:?Set LOCAL_DB_NAME}"
: "${LOCAL_DB_USER:?Set LOCAL_DB_USER}"
: "${LOCAL_DB_PASSWORD:?Set LOCAL_DB_PASSWORD}"

# Optional: override paths to MySQL/PHP (e.g. Local app binaries)
MYSQL_BIN="${MYSQL_BIN:-}"
PHP_BIN="${PHP_BIN:-}"
WP_BIN="${WP_BIN:-wp}"

# Optional: SSH key or other options (e.g. "-i ~/.ssh/id_ed25519")
SSH_OPTS="${SSH_OPTS:-}"

# Build SSH command (SSH_OPTS word-splits for multiple options)
SSH_CMD=(ssh)
[[ -n "$SSH_OPTS" ]] && SSH_CMD+=( $SSH_OPTS )
SSH_CMD+=("$SSH_USER@$SSH_HOST")

# -----------------------------------------------------------------------------
REMOTE_TMP="/tmp/wp-pull-$$"
LOCAL_TMP="$LOCAL_ROOT/.pull-tmp-$$"
LOCAL_PUBLIC="$LOCAL_ROOT/$LOCAL_WP_PATH"
WPCONFIG="$LOCAL_PUBLIC/wp-config.php"

abort() { echo "Error: $*" >&2; exit 1; }
cleanup_remote() {
  "${SSH_CMD[@]}" "rm -rf $REMOTE_TMP" 2>/dev/null || true
}
cleanup_local() {
  rm -rf "$LOCAL_TMP"
}

# Resolve MySQL client: prefer MYSQL_BIN, else try common Local paths
resolve_mysql() {
  if [[ -n "$MYSQL_BIN" && -x "$MYSQL_BIN" ]]; then
    echo "$MYSQL_BIN"
    return
  fi
  for candidate in \
    "/Users/$USER/Library/Application Support/Local/lightning-services/mysql-8.0.35+4/bin/darwin-arm64/bin/mysql" \
    "/Users/$USER/Library/Application Support/Local/lightning-services/mysql-5.7.28+6/bin/darwin/bin/mysql" \
    "/usr/local/bin/mysql" \
    ; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return; fi
  done
  command -v mysql || true
}

resolve_php() {
  if [[ -n "$PHP_BIN" && -x "$PHP_BIN" ]]; then
    echo "$PHP_BIN"
    return
  fi
  for candidate in \
    "/Users/$USER/Library/Application Support/Local/lightning-services/php-8.2.27+1/bin/darwin-arm64/bin/php" \
    "/Users/$USER/Library/Application Support/Local/lightning-services/php-8.1.29+0/bin/darwin-arm64/bin/php" \
    "/Users/$USER/Library/Application Support/Local/lightning-services/php-8.4.4+2/bin/darwin-arm64/bin/php" \
    ; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return; fi
  done
  command -v php || true
}

# -----------------------------------------------------------------------------
echo "=== Pull from live: $SSH_USER@$SSH_HOST ($REMOTE_WP_PATH) -> local ($LOCAL_PUBLIC) ==="

[[ -d "$LOCAL_PUBLIC" ]] || abort "LOCAL_WP_PATH dir not found: $LOCAL_PUBLIC"
[[ -f "$WPCONFIG" ]]     || abort "wp-config.php not found: $WPCONFIG"

MYSQL="$(resolve_mysql)"
[[ -n "$MYSQL" ]] || abort "MySQL client not found. Set MYSQL_BIN or ensure Local MySQL is on PATH."
PHP="$(resolve_php)"
[[ -n "$PHP" ]]   || abort "PHP not found. Set PHP_BIN (needed for wp search-replace)."

trap cleanup_remote EXIT
trap cleanup_local EXIT
mkdir -p "$LOCAL_TMP"

# ----- On remote: export DB and get live URL -----
echo "Remote: exporting DB..."
"${SSH_CMD[@]}" "mkdir -p $REMOTE_TMP && cd $REMOTE_WP_PATH && \
  wp db export $REMOTE_TMP/db.sql && \
  (wp option get siteurl 2>/dev/null || true) > $REMOTE_TMP/siteurl.txt && \
  (wp option get home 2>/dev/null || true) >> $REMOTE_TMP/home.txt"

# Fetch live URL from remote (first line of siteurl.txt)
LIVE_SITE_URL="$("${SSH_CMD[@]}" "head -1 $REMOTE_TMP/siteurl.txt" 2>/dev/null | tr -d '\r\n' || true)"
if [[ -z "$LIVE_SITE_URL" ]]; then
  echo "Warning: could not get live site URL from remote; using REMOTE_SITE_URL if set."
  LIVE_SITE_URL="${REMOTE_SITE_URL:-https://example.com}"
fi
echo "Live URL: $LIVE_SITE_URL -> Local URL: $LOCAL_SITE_URL"

# Download DB dump
echo "Downloading db.sql from remote..."
scp ${SSH_OPTS:+ $SSH_OPTS} "$SSH_USER@$SSH_HOST:$REMOTE_TMP/db.sql" "$LOCAL_TMP/"

# Remove remote temp (DB only; we'll rsync files next)
"${SSH_CMD[@]}" "rm -rf $REMOTE_TMP"

# ----- Rsync files from live to local (exclude wp-config so we keep local) -----
echo "Rsyncing files from live to local..."
# Build rsync -e "ssh ..." (optional key etc.)
RSYNC_SSH="ssh"
[[ -n "$SSH_OPTS" ]] && RSYNC_SSH="ssh $SSH_OPTS"
rsync -az --delete \
  --exclude='wp-config.php' \
  --exclude='wp-content/object-cache.php' \
  --exclude='.pull-tmp-*' \
  --exclude='.vscode/' \
  -e "$RSYNC_SSH" \
  "$SSH_USER@$SSH_HOST:$REMOTE_WP_PATH/" \
  "$LOCAL_PUBLIC/"

# ----- Local: DB reset, import, search-replace (wp-config was left intact by rsync exclude) -----
echo "Local: resetting database and importing..."
export MYSQL_UNIX_PORT="$MYSQL_SOCKET"
"$MYSQL" -u "$LOCAL_DB_USER" -p"$LOCAL_DB_PASSWORD" -e "DROP DATABASE IF EXISTS \`$LOCAL_DB_NAME\`; CREATE DATABASE \`$LOCAL_DB_NAME\`;"
"$MYSQL" -u "$LOCAL_DB_USER" -p"$LOCAL_DB_PASSWORD" "$LOCAL_DB_NAME" < "$LOCAL_TMP/db.sql"

echo "Local: running search-replace ($LIVE_SITE_URL -> $LOCAL_SITE_URL)..."
# Disable object cache (e.g. Redis) so WP-CLI can load WordPress without a cache server
OBJECT_CACHE="$LOCAL_PUBLIC/wp-content/object-cache.php"
OBJECT_CACHE_BAK=""
if [[ -f "$OBJECT_CACHE" ]]; then
  OBJECT_CACHE_BAK="${OBJECT_CACHE}.puller-bak"
  mv "$OBJECT_CACHE" "$OBJECT_CACHE_BAK"
fi
run_search_replace() {
  "$PHP" -d "mysqli.default_socket=$MYSQL_SOCKET" -d "pdo_mysql.default_socket=$MYSQL_SOCKET" \
    "$(command -v "$WP_BIN")" search-replace "$1" "$2" \
    --path="$LOCAL_PUBLIC" --all-tables --report-changed-only
}
run_search_replace "$LIVE_SITE_URL" "$LOCAL_SITE_URL"
# If live URL was http, also replace https version of same host (mixed content in DB)
if [[ "$LIVE_SITE_URL" == http://* ]]; then
  LIVE_HTTPS="https://${LIVE_SITE_URL#http://}"
  echo "Local: search-replace $LIVE_HTTPS -> $LOCAL_SITE_URL..."
  run_search_replace "$LIVE_HTTPS" "$LOCAL_SITE_URL"
fi
[[ -n "$OBJECT_CACHE_BAK" && -f "$OBJECT_CACHE_BAK" ]] && mv "$OBJECT_CACHE_BAK" "$OBJECT_CACHE"

echo "=== Pull complete. Local site at $LOCAL_SITE_URL ==="
