# Pull live site to local (and optional push)

This directory contains a **non-destructive puller** that overwrites your local WordPress files and database with the live site, while **keeping** your local `wp-config.php` (database credentials, `WP_DEBUG`, local URL, etc.) so the site keeps working under Local.

## Requirements

- **Local site must be running** in Local by the time you run the pull (so the MySQL socket exists).
- SSH access to the live server (key-based auth; 1Password SSH agent is fine).
- WP-CLI on the **live** server (used to export the DB and get site URL).
- On your Mac: `wp` (WP-CLI), and either MySQL/PHP on PATH or set `MYSQL_BIN` / `PHP_BIN` to Local’s binaries (see below).

## Setup (one-time)

1. Copy the example config and edit with your values:
   ```bash
   cp .env.example .env
   # Edit .env: SSH_HOST, SSH_USER, REMOTE_WP_PATH, LOCAL_SITE_URL, MYSQL_SOCKET, LOCAL_DB_*.
   ```
2. **MYSQL_SOCKET**: In Local, open the site → “Database” tab → copy the “Socket” path (e.g.  
   `…/Local/run/<site-id>/mysql/mysqld.sock`).
3. **LOCAL_SITE_URL**: The URL you use to open the site in Local (e.g. `http://benandjacq.local`).
4. If the script can’t find MySQL or PHP, set them in `.env`:
   - **MYSQL_BIN**: Path to Local’s `mysql` (e.g. under `~/Library/Application Support/Local/lightning-services/mysql-*/bin/...`).
   - **PHP_BIN**: Path to Local’s `php` (e.g. under `~/Library/Application Support/Local/lightning-services/php-*/bin/...`).

Keep **`.env`** out of version control (it’s in `.gitignore`). You can commit `pull-from-live.sh`, `.env.example`, and this README.

## Pull: live → local

```bash
# From this site root (where pull-from-live.sh and .env live)
./pull-from-live.sh
```

What it does:

1. On **remote**: Creates a temp dir, runs `wp db export`, reads `siteurl`/`home`, tars the WP files (excluding `wp-config.php`), then removes the temp dir (no backup left on the server).
2. Downloads the SQL dump and tarball to a local temp dir.
3. **Local**: Backs up your `wp-config.php`, extracts the tarball over `app/public`, then restores your original `wp-config.php`.
4. Drops the local DB, recreates it, and imports the live dump.
5. Runs `wp search-replace` to replace the live URL with `LOCAL_SITE_URL` (so links and assets point to your local URL).
6. Cleans up local temp files.

Result: local files and DB match live; only the values needed for Local (URL, DB creds, etc.) stay as in your local `wp-config.php`.

## Push: local → live (without Git on the server)

Git is not used on the live server. To push changes after testing locally, you can:

1. **rsync (files only)**  
   Sync specific dirs (e.g. theme/plugin) over SSH, then clear caches on the server if needed:
   ```bash
   rsync -avz --exclude='.git' -e "ssh $SSH_OPTS" ./app/public/wp-content/themes/your-theme/ "$SSH_USER@$SSH_HOST:$REMOTE_WP_PATH/wp-content/themes/your-theme/"
   ```
   Use the same `SSH_OPTS`, `SSH_USER`, `SSH_HOST`, and `REMOTE_WP_PATH` as in your `.env` (or export them before running).

2. **DB changes**  
   If you changed the DB locally and need to push:
   - Export locally: `wp db export` from `app/public`.
   - Copy dump to server and run `wp db import` on the server (then run `wp search-replace` on the server to swap local URL back to live URL), **or**
   - Use a migration/backup plugin or manual SQL for specific changes.

A small **push script** could wrap rsync + optional DB steps and read the same `.env`; it’s not included here to avoid accidental overwrites. You can add one later that echoes the commands and asks for confirmation before running.

## Reusing on other sites

- Use a **different `.env`** per site (or a different `PULLER_CONFIG` path).
- Do **not** commit `.env`; keep credentials and paths in that file only.
- You can commit and share `pull-from-live.sh`, `.env.example`, and this README.
