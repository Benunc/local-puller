# Local Puller

Pull a live WordPress site into a local environment (e.g. [Local](https://localwp.com/)) without overwriting local `wp-config.php` or leaving backups on the server.

- **Script:** `pull-from-live.sh` — SSH to live, export DB with WP-CLI, rsync files, import DB locally, run URL search-replace.
- **Config:** Copy `.env.example` to `.env` and fill in your SSH host, paths, local URL, and DB credentials. Do not commit `.env`.

See **[PULLER-README.md](PULLER-README.md)** for setup and usage.

## Quick start (new site)

1. Clone this repo into your Local site root (the folder that contains `app/public`):
   ```bash
   git clone https://github.com/Benunc/local-puller.git .
   # or into a subfolder and copy the files into the site root
   ```
2. Copy `.env.example` to `.env` and set your remote and local values.
3. Start your Local site, then run: `./pull-from-live.sh`
