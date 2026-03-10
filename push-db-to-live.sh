#!/usr/bin/env bash
#
# Push local to live: (1) rsync files (themes, plugins, etc.), then (2) DB (posts, postmeta, options).
# Keeps live wp-config.php and object-cache.php unchanged. Replaces local URL with live URL in DB.
#
# Usage: ./push-db-to-live.sh [--dry-run]
#   --dry-run   Export and prepare everything, show summary; do not rsync or apply on live.
#
# Config: .env (same as pull). push-db-post-ids.txt = post IDs to push (optional).
# Set PUSH_SKIP_FILES=1 to skip rsync and only push DB.
#
set -euo pipefail

DRY_RUN=""
for arg in "$@"; do
  [[ "$arg" == --dry-run || "$arg" == -n ]] && DRY_RUN=1 && break
done

SCRIPT_DIR="${BASH_SOURCE%/*}"
[[ -d "$SCRIPT_DIR" ]] || SCRIPT_DIR="$PWD"
PULLER_ROOT="$(cd "$SCRIPT_DIR" && pwd)"
CONFIG_FILE="${PULLER_CONFIG:-$PULLER_ROOT/.env}"
# Find .env: (1) PULLER_CONFIG, (2) script dir, (3) parent of script dir, (4) cwd
SITE_ROOT="$PULLER_ROOT"
if [[ -n "${PULLER_CONFIG:-}" && -f "$CONFIG_FILE" ]]; then
  SITE_ROOT="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
elif [[ -f "$CONFIG_FILE" ]]; then
  : # script-dir .env
elif [[ -f "$PULLER_ROOT/../.env" ]]; then
  CONFIG_FILE="$PULLER_ROOT/../.env"
  SITE_ROOT="$(cd "$PULLER_ROOT/.." && pwd)"
elif [[ -f "$(pwd)/.env" ]]; then
  CONFIG_FILE="$(pwd)/.env"
  SITE_ROOT="$(pwd)"
fi

if [[ -f "$CONFIG_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  set +a
else
  echo "Error: No .env found. Set PULLER_CONFIG to your .env path, or put .env in: script dir ($PULLER_ROOT), parent ($(cd "$PULLER_ROOT/.." 2>/dev/null && pwd)), or cwd ($(pwd)). See .env.example." >&2
  exit 1
fi

: "${SSH_HOST:?Set SSH_HOST}"
: "${SSH_USER:?Set SSH_USER}"
: "${REMOTE_WP_PATH:?Set REMOTE_WP_PATH}"
: "${LOCAL_WP_PATH:?Set LOCAL_WP_PATH}"
: "${LOCAL_SITE_URL:?Set LOCAL_SITE_URL}"
: "${MYSQL_SOCKET:?Set MYSQL_SOCKET}"
: "${LOCAL_DB_NAME:?Set LOCAL_DB_NAME}"
: "${LOCAL_DB_USER:?Set LOCAL_DB_USER}"
: "${LOCAL_DB_PASSWORD:?Set LOCAL_DB_PASSWORD}"

REMOTE_SITE_URL="${REMOTE_SITE_URL:-}"
PUSH_SKIP_FILES="${PUSH_SKIP_FILES:-}"   # set to 1 to skip rsync (DB-only push)
MYSQL_BIN="${MYSQL_BIN:-}"
PHP_BIN="${PHP_BIN:-}"
WP_BIN="${WP_BIN:-wp}"
SSH_OPTS="${SSH_OPTS:-}"

SSH_CMD=(ssh)
[[ -n "$SSH_OPTS" ]] && SSH_CMD+=( $SSH_OPTS )
SSH_CMD+=("$SSH_USER@$SSH_HOST")

LOCAL_PUBLIC="$SITE_ROOT/$LOCAL_WP_PATH"
EXCLUDE_FILE="${PUSH_DB_EXCLUDE:-$PULLER_ROOT/push-db-exclude.txt}"
POST_IDS_FILE="${PUSH_DB_POST_IDS:-$PULLER_ROOT/push-db-post-ids.txt}"
REMOTE_TMP="/tmp/wp-push-db-$$"
LOCAL_TMP="$PULLER_ROOT/.push-db-tmp-$$"

abort() { echo "Error: $*" >&2; exit 1; }
cleanup() {
  if [[ -n "$DRY_RUN" ]]; then return 0; fi
  rm -rf "$LOCAL_TMP"
  "${SSH_CMD[@]}" "rm -rf $REMOTE_TMP" 2>/dev/null || true
}

resolve_mysql() {
  if [[ -n "$MYSQL_BIN" && -x "$MYSQL_BIN" ]]; then echo "$MYSQL_BIN"; return; fi
  for c in "/Users/$USER/Library/Application Support/Local/lightning-services/mysql-8.0.35+4/bin/darwin-arm64/bin/mysql" \
           "/Users/$USER/Library/Application Support/Local/lightning-services/mysql-5.7.28+6/bin/darwin/bin/mysql" \
           /usr/local/bin/mysql; do
    [[ -x "$c" ]] && { echo "$c"; return; }
  done
  command -v mysql || true
}

resolve_php() {
  if [[ -n "$PHP_BIN" && -x "$PHP_BIN" ]]; then echo "$PHP_BIN"; return; fi
  for c in "/Users/$USER/Library/Application Support/Local/lightning-services/php-8.2.27+1/bin/darwin-arm64/bin/php" \
           "/Users/$USER/Library/Application Support/Local/lightning-services/php-8.1.29+0/bin/darwin-arm64/bin/php"; do
    [[ -x "$c" ]] && { echo "$c"; return; }
  done
  command -v php || true
}

# -----------------------------------------------------------------------------
[[ -n "$DRY_RUN" ]] && echo "=== DRY RUN: will export and show summary only ==="
echo "=== Push DB to live: posts + postmeta + options ==="

[[ -d "$LOCAL_PUBLIC" ]] || abort "LOCAL_WP_PATH not found: $LOCAL_PUBLIC"
[[ -f "$EXCLUDE_FILE" ]]  || abort "Exclude file not found: $EXCLUDE_FILE"

if [[ -z "$REMOTE_SITE_URL" ]]; then
  if [[ -n "$DRY_RUN" ]]; then
    REMOTE_SITE_URL="https://example.com"
    echo "Live URL: $REMOTE_SITE_URL (placeholder for dry-run; set REMOTE_SITE_URL in .env for real replace)"
  else
    REMOTE_SITE_URL="$("${SSH_CMD[@]}" "cd $REMOTE_WP_PATH && wp option get siteurl 2>/dev/null" | tr -d '\r\n' || true)"
  fi
fi
[[ -n "$REMOTE_SITE_URL" ]] || abort "Set REMOTE_SITE_URL in .env or ensure remote has WP-CLI."
echo "Live URL: $REMOTE_SITE_URL"

MYSQL="$(resolve_mysql)"
[[ -n "$MYSQL" ]] || abort "MySQL client not found. Set MYSQL_BIN."
PHP="$(resolve_php)"
[[ -n "$PHP" ]] || abort "PHP not found. Set PHP_BIN."

trap cleanup EXIT
mkdir -p "$LOCAL_TMP"

# ----- Read post IDs to push -----
POST_IDS=()
if [[ -f "$POST_IDS_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line// /}"
    [[ -n "$line" ]] && [[ "$line" =~ ^[0-9]+$ ]] && POST_IDS+=( "$line" )
  done < "$POST_IDS_FILE"
fi

# ----- Export posts and postmeta (if any post IDs) -----
if [[ ${#POST_IDS[@]} -gt 0 ]]; then
  ID_LIST=$(IFS=,; echo "${POST_IDS[*]}")
  export MYSQL_UNIX_PORT="$MYSQL_SOCKET"
  MYSQLDUMP="${MYSQL%mysql}mysqldump"
  [[ -x "$MYSQLDUMP" ]] || MYSQLDUMP="$(command -v mysqldump 2>/dev/null)" || true
  if [[ -n "$MYSQLDUMP" && -x "$MYSQLDUMP" ]]; then
    echo "Exporting wp_posts (IDs: $ID_LIST)..."
    "$MYSQLDUMP" -u "$LOCAL_DB_USER" -p"$LOCAL_DB_PASSWORD" --no-create-info --skip-extended-insert \
      --where="ID IN ($ID_LIST)" "$LOCAL_DB_NAME" wp_posts 2>/dev/null > "$LOCAL_TMP/posts.sql" || true
    if [[ -s "$LOCAL_TMP/posts.sql" ]]; then
      echo "Exporting wp_postmeta for those posts..."
      "$MYSQLDUMP" -u "$LOCAL_DB_USER" -p"$LOCAL_DB_PASSWORD" --no-create-info --skip-extended-insert \
        --where="post_id IN ($ID_LIST)" "$LOCAL_DB_NAME" wp_postmeta 2>/dev/null > "$LOCAL_TMP/postmeta.sql" || true
    fi
  else
    echo "Warning: mysqldump not found; skipping posts/postmeta. Set MYSQL_BIN to Local mysql dir."
  fi
fi

# If we have posts/postmeta SQL, do URL replace and use REPLACE INTO so we don't fail on existing rows
for f in posts.sql postmeta.sql; do
  [[ -s "$LOCAL_TMP/$f" ]] || continue
  sed -i.bak "s|INSERT INTO|REPLACE INTO|g" "$LOCAL_TMP/$f"
  sed -i.bak "s|$LOCAL_SITE_URL|$REMOTE_SITE_URL|g" "$LOCAL_TMP/$f"
  [[ "$LOCAL_SITE_URL" == http://* ]] && sed -i.bak "s|https://${LOCAL_SITE_URL#http://}|$REMOTE_SITE_URL|g" "$LOCAL_TMP/$f"
  rm -f "$LOCAL_TMP/$f.bak"
done

# ----- Export options (same as before) -----
echo "Exporting pushable options..."
"$PHP" -d "mysqli.default_socket=$MYSQL_SOCKET" -d "pdo_mysql.default_socket=$MYSQL_SOCKET" \
  "$(command -v "$WP_BIN")" eval-file "$PULLER_ROOT/scripts/export-options.php" "$EXCLUDE_FILE" \
  --path="$LOCAL_PUBLIC" > "$LOCAL_TMP/options.json" 2>/dev/null || true
[[ -s "$LOCAL_TMP/options.json" ]] || abort "Options export produced empty file."
sed -i.bak "s|$LOCAL_SITE_URL|$REMOTE_SITE_URL|g" "$LOCAL_TMP/options.json"
[[ "$LOCAL_SITE_URL" == http://* ]] && sed -i.bak "s|https://${LOCAL_SITE_URL#http://}|$REMOTE_SITE_URL|g" "$LOCAL_TMP/options.json"
rm -f "$LOCAL_TMP/options.json.bak"

# ----- Dry-run: show summary and exit without uploading -----
if [[ -n "$DRY_RUN" ]]; then
  OPT_COUNT="?"
  [[ -s "$LOCAL_TMP/options.json" ]] && OPT_COUNT=$(grep -cE '^\s*"[^"]+":' "$LOCAL_TMP/options.json" 2>/dev/null) || true
  echo ""
  echo "--- Dry-run summary ---"
  [[ -z "${PUSH_SKIP_FILES:-}" ]] && echo "Would rsync: $LOCAL_PUBLIC/ -> $SSH_USER@$SSH_HOST:$REMOTE_WP_PATH/ (then DB)"
  [[ -n "${PUSH_SKIP_FILES:-}" ]] && echo "Would skip file push (PUSH_SKIP_FILES is set); then apply DB."
  echo "Post IDs to push: ${POST_IDS[*]:-(none)}"
  [[ -s "$LOCAL_TMP/posts.sql" ]]    && echo "  wp_posts:    $(wc -l < "$LOCAL_TMP/posts.sql") INSERTs, $(stat -f %z "$LOCAL_TMP/posts.sql" 2>/dev/null || stat -c %s "$LOCAL_TMP/posts.sql" 2>/dev/null) bytes"
  [[ -s "$LOCAL_TMP/postmeta.sql" ]] && echo "  wp_postmeta: $(wc -l < "$LOCAL_TMP/postmeta.sql") INSERTs, $(stat -f %z "$LOCAL_TMP/postmeta.sql" 2>/dev/null || stat -c %s "$LOCAL_TMP/postmeta.sql" 2>/dev/null) bytes"
  echo "  wp_options:  ~$OPT_COUNT options, $(stat -f %z "$LOCAL_TMP/options.json" 2>/dev/null || stat -c %s "$LOCAL_TMP/options.json" 2>/dev/null) bytes"
  echo ""
  echo "Temp files left in: $LOCAL_TMP"
  echo "Run without --dry-run to push files then apply DB on live."
  echo "=== Dry run complete. ==="
  exit 0
fi

# ----- 1) Push files first (rsync local -> live), then 2) upload and apply DB -----
if [[ -z "${PUSH_SKIP_FILES:-}" ]]; then
  echo "Pushing files to live (rsync)..."
  RSYNC_SSH="ssh"
  [[ -n "$SSH_OPTS" ]] && RSYNC_SSH="ssh $SSH_OPTS"
  rsync -az --delete \
    --exclude='wp-config.php' \
    --exclude='wp-content/object-cache.php' \
    --exclude='.pull-tmp-*' \
    --exclude='.push-db-tmp-*' \
    --exclude='.vscode/' \
    -e "$RSYNC_SSH" \
    "$LOCAL_PUBLIC/" \
    "$SSH_USER@$SSH_HOST:$REMOTE_WP_PATH/"
  echo "Files pushed."
fi

echo "Uploading DB artifacts to live..."
"${SSH_CMD[@]}" "mkdir -p $REMOTE_TMP"

# Upload options + apply script always; upload posts/postmeta if we have them
scp ${SSH_OPTS:+ $SSH_OPTS} "$LOCAL_TMP/options.json" "$PULLER_ROOT/scripts/apply-options.php" "$SSH_USER@$SSH_HOST:$REMOTE_TMP/"
[[ -s "$LOCAL_TMP/posts.sql" ]]    && scp ${SSH_OPTS:+ $SSH_OPTS} "$LOCAL_TMP/posts.sql" "$SSH_USER@$SSH_HOST:$REMOTE_TMP/"
[[ -s "$LOCAL_TMP/postmeta.sql" ]] && scp ${SSH_OPTS:+ $SSH_OPTS} "$LOCAL_TMP/postmeta.sql" "$SSH_USER@$SSH_HOST:$REMOTE_TMP/"

echo "Applying on live..."
if [[ -s "$LOCAL_TMP/posts.sql" ]]; then
  "${SSH_CMD[@]}" "cd $REMOTE_WP_PATH && wp db import $REMOTE_TMP/posts.sql"
fi
if [[ -s "$LOCAL_TMP/postmeta.sql" ]]; then
  "${SSH_CMD[@]}" "cd $REMOTE_WP_PATH && wp db import $REMOTE_TMP/postmeta.sql"
fi
"${SSH_CMD[@]}" "cd $REMOTE_WP_PATH && OPTIONS_JSON_PATH=$REMOTE_TMP/options.json wp eval-file $REMOTE_TMP/apply-options.php"

echo "=== Push complete (files + DB). ==="
