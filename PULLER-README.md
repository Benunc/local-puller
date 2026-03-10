# Pull live site to local (and optional push)

This directory contains a **non-destructive puller** that overwrites your local WordPress files and database with the live site, while **keeping** your local `wp-config.php` (database credentials, `WP_DEBUG`, local URL, etc.) so the site keeps working under Local.

## Requirements

- **Local site must be running** in Local by the time you run the pull (so the MySQL socket exists).
- SSH access to the live server (key-based auth; 1Password SSH agent is fine).
- WP-CLI on the **live** server (used to export the DB and get site URL).
- On your Mac: `wp` (WP-CLI), and either MySQL/PHP on PATH or set `MYSQL_BIN` / `PHP_BIN` to Local’s binaries (see below).

## Setup (one-time)

1. Put `.env` in the **site root** (the folder that contains `app/public`). Copy from the example and edit:
   ```bash
   cp .env.example .env
   # Edit .env: SSH_HOST, SSH_USER, REMOTE_WP_PATH, LOCAL_SITE_URL, MYSQL_SOCKET, LOCAL_DB_*.
   ```
   **Finding .env:** Both scripts look in this order: (1) **PULLER_CONFIG** (env var with full path to .env), (2) same directory as the script, (3) parent of the script directory (site root when repo is in `local-puller/`), (4) current working directory. So you can run from site root or from `local-puller/` and they find the site root `.env`. On another machine or repo, set `export PULLER_CONFIG=/absolute/path/to/site/.env` if your layout differs.
2. **MYSQL_SOCKET**: In Local, open the site → “Database” tab → copy the “Socket” path (e.g.  
   `…/Local/run/<site-id>/mysql/mysqld.sock`).
3. **LOCAL_SITE_URL**: The URL you use to open the site in Local (e.g. `http://yoursite.local`).
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

## Workflow: pull → change locally → push to live

1. **Pull** (once or when you want to resync): `./pull-from-live.sh`
2. **Make changes locally** (install theme/plugins, change theme settings, add pages like Maintenance Mode, etc.).
3. **Push files** (themes/plugins): use rsync to sync `wp-content/themes` and/or `wp-content/plugins` to the server.
4. **Push DB** so live gets new pages (e.g. Maintenance), their postmeta, and theme/plugin options: add `REMOTE_SITE_URL` to `.env`, put the post IDs to push in **push-db-post-ids.txt** (see **DB-COMPARISON-REPORT.md** for how to find them), then `./push-db-to-live.sh`.

The push script exports **wp_posts** (by ID), **wp_postmeta** for those posts, and **wp_options** (excluding names in push-db-exclude.txt), replaces local URL with live URL, and applies them on live in that order.

## Push: local → live (without Git on the server)

Git is not used on the live server. To push changes after testing locally, you can:

1. **rsync (files only)**  
   Sync specific dirs (e.g. theme/plugin) over SSH, then clear caches on the server if needed:
   ```bash
   rsync -avz --exclude='.git' -e "ssh $SSH_OPTS" ./app/public/wp-content/themes/your-theme/ "$SSH_USER@$SSH_HOST:$REMOTE_WP_PATH/wp-content/themes/your-theme/"
   ```
   Use the same `SSH_OPTS`, `SSH_USER`, `SSH_HOST`, and `REMOTE_WP_PATH` as in your `.env` (or export them before running).

### Push DB (posts + postmeta + options) to live

Use **`push-db-to-live.sh`** to push (1) selected **wp_posts** by ID, (2) their **wp_postmeta**, and (3) **wp_options** (excluding push-db-exclude.txt). Add **REMOTE_SITE_URL** to `.env`. Put the post IDs you want to push (e.g. new pages like Maintenance Mode) in **push-db-post-ids.txt** (one ID per line). To find which IDs to push, run a local-vs-live DB comparison and see **DB-COMPARISON-REPORT.md**. Edit **push-db-exclude.txt** to skip options that must stay live-only. Then run `./push-db-to-live.sh`.

### Push files (rsync)

(To push only files, use rsync; see example earlier. Push DB options with push-db-to-live.sh.)


## Troubleshooting

### "no such identity" / "Permission denied (publickey)"

The script runs `ssh USER@HOST` (with optional `SSH_OPTS` from `.env`). It does **not** read your key from anywhere else — only from `SSH_OPTS` if you set it.

- **If you don’t set `SSH_OPTS`** (like this repo’s benandjacq `.env`), the script uses your **default** SSH: same as typing `ssh USER@HOST` in a terminal (default key or `~/.ssh/config`). One key for all sites is fine.
- **If you do set `SSH_OPTS`** in a site’s `.env`, it **overrides** that default. Then the path must be your **private** key (not `.pub`), and the file must exist. A wrong or `.pub` path causes "no such identity" / "Permission denied".

**Fix:** In the site where it fails (e.g. siloam96), open that site’s `.env` and **remove or comment out `SSH_OPTS`** so the script uses the same default SSH as everywhere else. If `ssh siloam96@134.209.166.61` works in a terminal, the pull script will work with no `SSH_OPTS`.

### Running the script from Cursor (or an agent)

If you run `./local-puller/pull-from-live.sh` from Cursor’s terminal or via an AI agent, the run may be **sandboxed** and SSH can be blocked (e.g. "Operation not permitted" or connection refused). To allow SSH:

- Run the script in a **normal terminal** (outside Cursor), or  
- When an agent runs it, the run must use **network** (or full) permissions so SSH can connect. You can add a project note or Cursor rule: “When running local-puller’s pull or push scripts, use network permissions.”

## Reusing on other sites

- Use a **different `.env`** per site (or a different `PULLER_CONFIG` path).
- Do **not** commit `.env`; keep credentials and paths in that file only.
- You can commit and share `pull-from-live.sh`, `.env.example`, and this README.
