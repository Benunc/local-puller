# Local vs Live DB Comparison Report

Use this workflow to decide which post IDs to push and which options to exclude. Comparison is done by loading the live DB dump into a temp DB `live_ref` and querying against local.

## How to re-run the comparison

1. Export live DB: `ssh user@host "cd REMOTE_WP_PATH && wp db export /tmp/live-compare.sql"` then `scp` it down.
2. Export local DB: `mysqldump -u root -proot local > local-db-current.sql` (using Local's socket).
3. Load live into a temp DB: `mysql -e "CREATE DATABASE live_ref"` then `mysql live_ref < live-db-from-remote.sql`.
4. Run comparison queries (posts in local not in live_ref; postmeta; options differing). Update **push-db-post-ids.txt** with the post IDs you want to push (one per line).

## What to compare

- **wp_posts** — Rows in local that are not on live (new pages, revisions, attachments). List their IDs and add the ones you want on live to `push-db-post-ids.txt`.
- **wp_postmeta** — Meta for those posts will be pushed automatically by `push-db-to-live.sh` when you include the post IDs.
- **wp_options** — Many options differ (siteurl, home, transients, licenses). Use **push-db-exclude.txt** to list option names or prefixes that must never be pushed. The push script exports options and applies the exclude list before sending.

## What the push script does

1. **wp_posts** — Exports rows for the IDs in `push-db-post-ids.txt`, replaces local URL with live URL, applies on live.
2. **wp_postmeta** — Exports meta for those post IDs, URL replacement, applies on live.
3. **wp_options** — Exports options (excluding names in push-db-exclude.txt), URL replacement, applies on live.

Order of application on live: **posts first**, then **postmeta**, then **options**.
