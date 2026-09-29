# Deployment and operations

For a new installation, follow [Docker setup](docker.md). This guide covers
HTTPS access, updates, backups, recovery, and longer-running Plex imports. Run
commands from your GigaAdmin checkout unless stated otherwise.

The image includes Puma and Thruster and can serve GigaAdmin directly. **Nginx
is not required**, whether you start the container with Compose or `docker run`.
Compose coordinates the app, PostgreSQL, and refresh services; it does not
determine how HTTPS is provided. External termination at an existing HTTPS
proxy is the default, including when `GIGAADMIN_SSL_MODE` is unset. Choose
`letsencrypt` for Thruster's automatic HTTPS or explicitly choose `local` for
private HTTP setup.

## Add HTTPS access

**Create the first local super administrator privately before exposing the app.**
Use localhost or the SSH tunnel in the Docker guide. That account retains super
administrator access; emails in `ADMIN_USERS` also receive that role. Only super
administrators can invite or remove GigaAdmin administrators. All administrators
can change Plex library sharing and see playback history.

### Direct HTTPS with Thruster

The bundled Thruster supports automatic Let's Encrypt certificates, so a
dedicated Docker host does not need another proxy. This requires a public
hostname pointing to the host, inbound ports 80 and 443 reaching the container,
and outbound access for certificate issuance and renewal. If those host ports
already belong to another application or proxy, use that proxy instead or a
separate IP address.

After completing private setup, set these values in `.env.production`:

```dotenv
GIGAADMIN_SSL_MODE=letsencrypt
PLEX_HOST=gigaadmin.example.com
PLEX_HOSTS=gigaadmin.example.com
```

The Docker entrypoint configures Thruster's domain from `PLEX_HOST`, stores
certificates under `/rails/storage/thruster`, and enables both Rails
`assume_ssl` and `force_ssl`. A missing or invalid public hostname prevents
startup instead of silently serving HTTP.

When recreating a plain Docker container, replace its localhost publish option
with `--publish 80:80 --publish 443:443` and retain the same database settings and
storage volume. `/rails/storage` must remain persistent: it contains Thruster's
certificates as well as application storage. Configure DNS and the firewall
before starting this public listener, then verify login at
`https://gigaadmin.example.com` and certificate renewal in your deployment.

The default Compose file publishes only its backend HTTP port. For direct HTTPS
with Compose 2.24.4 or newer, add this to `.env`:

```dotenv
COMPOSE_FILE=compose.yml:compose.letsencrypt.yml
```

The provided override publishes host ports 80 and 443. Leave `COMPOSE_FILE`
unset for external termination or local setup. If you already use Compose
overrides, include those files explicitly as well and validate the configuration
with `docker compose config --quiet`. The SSL mode controls the
container; publishing host ports is a separate Docker setting.
See [Thruster's documentation](https://github.com/basecamp/thruster#custom-configuration)
for its TLS and storage settings. Certificate issuance requires a real domain
and has not been exercised by the local or CI installation smoke tests.

### HTTPS through an existing proxy

Choose a hostname, point its DNS at your reverse proxy, and obtain a certificate
for it. In `.env.production`, replace the example hostname with yours:

```dotenv
GIGAADMIN_SSL_MODE=proxy
PLEX_HOST=gigaadmin.example.com
PLEX_HOSTS=gigaadmin.example.com
```

This is the default when the mode is omitted. The Docker entrypoint enables
both Rails `assume_ssl` and `force_ssl`, disables Thruster certificate handling,
and serves HTTP to the upstream proxy. Rails treats the request as HTTPS and
sets secure cookies and HSTS. Keep the backend port private to your proxy and
redirect public HTTP to HTTPS at the edge. Existing deployments use this same
external-termination default without needing the new variable.

In `.env`, keep the generated loopback bind when the proxy runs directly on the
Docker host:

```dotenv
PLEX_ADMIN_BIND=127.0.0.1
PLEX_ADMIN_PORT=3010
```

For a proxy on another machine or in a separate container, bind to a reachable
private address of the Docker host and limit access to the proxy. A proxy
container's `127.0.0.1` means that container, not the Docker host. Its upstream
would be `http://<docker-host-private-ip>:3010`. Do not forward this HTTP port
from the public internet.

#### Optional nginx example

This log format and two server blocks belong in nginx's `http` context, usually
through your site's included configuration file. They assume
nginx runs directly on the Docker host. Replace the hostname and certificate
paths; **the certificate and private key must already exist**. Obtain and renew
them through your chosen certificate manager. See the
[nginx HTTPS documentation](https://nginx.org/en/docs/http/configuring_https_servers.html)
for certificate configuration.

```nginx
# Omit query strings so invitation tokens are not saved in access logs.
log_format gigaadmin '$remote_addr - $remote_user [$time_local] '
                     '"$request_method $uri $server_protocol" $status $body_bytes_sent';

server {
    listen 80;
    server_name gigaadmin.example.com;
    access_log /var/log/nginx/gigaadmin.access.log gigaadmin;
    return 301 https://gigaadmin.example.com$request_uri;
}

server {
    listen 443 ssl;
    server_name gigaadmin.example.com;
    access_log /var/log/nginx/gigaadmin.access.log gigaadmin;

    ssl_certificate /path/to/gigaadmin.example.com/fullchain.pem;
    ssl_certificate_key /path/to/gigaadmin.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:3010;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

Validate and reload nginx using your host's service manager; for a typical Linux
installation:

```sh
sudo nginx -t
sudo systemctl reload nginx
```

For Nginx Proxy Manager, configure a Proxy Host with the same hostname, forward
scheme `http`, the Docker host's reachable address, and port `3010`. Assign its
certificate and enable HTTPS redirection. Preserve the original host and
forwarded HTTPS headers as in the example. Configure proxy access logs to omit
query strings: administrator invitation URLs contain short-lived secret tokens.

Recreate the app services to load the changed environment:

```sh
docker compose up -d --force-recreate web daily_refresh
# Only if you previously enabled sampling:
docker compose up -d --force-recreate now_playing_sampler
```

If you use Google sign-in, register the new callback URL in your Google OAuth
client: `https://gigaadmin.example.com/auth/google_oauth2/callback`. See
[authentication configuration](configuration.md#choose-how-administrators-sign-in).
Confirm login, Access, and Now work at the HTTPS address before sharing admin
invitation links.

## Keep the installation identity

A new `scripts/setup` installation writes `COMPOSE_PROJECT_NAME=gigaadmin` to
`.env`. The Compose file retains `plex` as its fallback project name so older
installations keep their existing volumes. Custom project names are supported.

Keep your existing project name, `.env`, `.env.production`, and `.env.postgres`
when moving or updating the checkout. Do not run setup again on an established
installation. Changing the project name creates a separate stack with different
volumes and can look like data loss. The database names remain
`plex_production`, `plex_production_cache`, `plex_production_queue`, and
`plex_production_cable` regardless of the project name.

A legacy Plex Shares checkout can update its remote without moving any data:

```sh
git remote set-url origin https://github.com/wjrus/GigaAdmin.git
```

Existing installations with both Google credentials configured continue to use
Google under automatic authentication mode. Local accounts, invitations, and
super administrator roles use additive database migrations. Keep the existing
secrets and review [configuration](configuration.md) before changing login mode.

Never use `docker compose down -v` or volume pruning to update or repair this app.

## Update GigaAdmin

Make a backup first and review the incoming changes, especially migrations. Keep
an image tag and Git revision for the working version before rebuilding:

```sh
mkdir -p tmp
git rev-parse HEAD > tmp/pre-upgrade-revision
docker image tag gigaadmin:production gigaadmin:pre-upgrade
./scripts/deploy
```

The deploy script requires clean tracked files, pulls with `git pull --ff-only`,
validates Compose without printing its expanded secrets, builds the image,
prepares all databases, starts the app, and checks container health and `/up`
through the published host port. It also updates a sampler that was already
running. It recreates containers, so brief interruptions are possible.

A checkout lock prevents overlapping deployments. Remove `tmp/deploy.lock`
after an interrupted deployment only after confirming no deploy process is still
running. On failure, inspect logs before retrying; do not assume a failed health
check means migrations were rolled back.

Verify both the backend and the public endpoint, substituting your hostname,
bind address, and port:

```sh
docker compose ps
docker compose logs --tail=50 web
curl --connect-timeout 2 --max-time 5 -fsS \
  -H 'Host: gigaadmin.example.com' http://127.0.0.1:3010/up
curl --connect-timeout 2 --max-time 5 -fsS https://gigaadmin.example.com/up
```

Then sign in, check Status for the expected revision, and check Access, Now, and
one user profile. `/up` confirms the app boots; it does not validate your Plex
credentials, every database, or OAuth callback.

### Roll back the application image

An older image may not work with a newer database schema. Check migration
compatibility first; use a matching database backup when required. The following
changes only application images and preserves database volumes:

```sh
cat > tmp/rollback.yml <<'YAML'
services:
  web:
    image: gigaadmin:pre-upgrade
  daily_refresh:
    image: gigaadmin:pre-upgrade
  now_playing_sampler:
    image: gigaadmin:pre-upgrade
YAML
docker compose -f compose.yml -f tmp/rollback.yml up -d --no-build --no-deps web daily_refresh
# Only if sampling was enabled:
docker compose -f compose.yml -f tmp/rollback.yml up -d --no-build --no-deps now_playing_sampler
```

Repeat the health and application checks above. Keep the recorded revision and
backup until recovery is verified. A later normal deployment uses `compose.yml`
and replaces this override's running images with the newly built image.

## Backups

Back up all four databases, the environment files, and application storage.
The primary database includes admin accounts and password hashes, invitation
records, sharing snapshots, watch history, IP/device details, notes, and audit
logs. The other databases hold Rails cache, background queue, and cable state.
Environment files contain application, Plex, database, and optional Google
secrets. Store backups privately and copy them to separate protected storage.

This example briefly stops all application writers so the four dumps and storage
copy describe the same stopped application. **It causes GigaAdmin downtime, not
Plex downtime.** Wait for any one-off history imports, Rails consoles, or other
manual database writers to finish first. The commands use PostgreSQL's tools
inside the database container, avoiding host/client version mismatches.

Run the block from the checkout. It saves files outside the repository and stops
on errors; if it fails after stopping services, investigate and restart the
services explicitly when ready.

```sh
bash <<'BASH'
set -euo pipefail
umask 077
backup_dir="$HOME/gigaadmin-backups/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$backup_dir"
cp .env.production .env.postgres "$backup_dir/"
if [ -f .env ]; then cp .env "$backup_dir/"; fi
git rev-parse HEAD > "$backup_dir/git-revision"
docker compose --profile sampling ps --status running --services > "$backup_dir/running-services.txt"
docker compose stop web daily_refresh now_playing_sampler

for database in plex_production plex_production_cache plex_production_queue plex_production_cable; do
  docker compose exec -T db pg_dump --username=plex --format=custom \
    --no-owner --no-acl --dbname="$database" > "$backup_dir/$database.dump.partial"
  mv "$backup_dir/$database.dump.partial" "$backup_dir/$database.dump"
  docker compose exec -T db pg_restore --list < "$backup_dir/$database.dump" > /dev/null
done

mkdir "$backup_dir/storage"
docker compose cp web:/rails/storage/. "$backup_dir/storage/"
docker compose up -d web daily_refresh
printf 'Backup saved to %s\n' "$backup_dir"
BASH
```

If `running-services.txt` lists the sampler, start it again:

```sh
docker compose up -d now_playing_sampler
```

The archive-list checks verify readable dump catalogs; they are not a restore
test. Periodically restore into an isolated installation and check login,
history, notes, and application health. These are application database dumps,
not PostgreSQL cluster/role backups; the standard Compose database role is
recreated from the saved environment files. Custom database roles require their
own backup plan. See PostgreSQL's [dump](https://www.postgresql.org/docs/current/app-pgdump.html)
and [restore](https://www.postgresql.org/docs/current/app-pgrestore.html) references.

## Restore a backup

Prefer testing a restore in a separate checkout and Compose project first. Copy
the saved environment files privately, then choose a different
`COMPOSE_PROJECT_NAME` and host port in the recovery checkout's `.env`, keeping
its bind at `127.0.0.1`. Use the code/image revision recorded with the backup.
Do not run `scripts/setup` over restored secrets. Start only `db` initially and
wait for it to become healthy:

```sh
docker compose up -d db
docker compose ps db
```

**The block below destroys and replaces all four databases in the selected
Compose project's `db` service.** Verify you are in the intended checkout, that
its project name points to the intended volumes, and that you have a separate
backup of anything you need from that target. Stop manual writers too.

Set `backup_dir` to the absolute path of the backup you intend to restore. The
block first checks that all four dump files exist and have readable catalogs.
Recreating the target databases prevents tables introduced after the backup
from being left behind by an object-only restore.

```sh
bash <<'BASH'
set -euo pipefail
backup_dir=/absolute/path/to/your/gigaadmin-backup
for database in plex_production plex_production_cache plex_production_queue plex_production_cable; do
  test -s "$backup_dir/$database.dump"
  docker compose exec -T db pg_restore --list < "$backup_dir/$database.dump" > /dev/null
done

docker compose stop web daily_refresh now_playing_sampler
for database in plex_production plex_production_cache plex_production_queue plex_production_cable; do
  docker compose exec -T db dropdb --username=plex --if-exists --force "$database"
  docker compose exec -T db createdb --username=plex --owner=plex "$database"
  docker compose exec -T db pg_restore --username=plex --no-owner --no-acl \
    --clean --if-exists --exit-on-error --dbname="$database" < "$backup_dir/$database.dump"
done
BASH
```

For a recovery installation, create the web container without starting it, then
copy the saved storage into its volume. Docker supports
[copying files to stopped containers](https://docs.docker.com/reference/cli/docker/container/cp/).
Replace the path with the same backup directory used above:

```sh
docker compose create --no-build --no-recreate web
docker compose cp /absolute/path/to/your/gigaadmin-backup/storage/. web:/rails/storage/
docker compose run --rm --no-deps --user root web chown -R 1000:1000 /rails/storage
```

On an existing target, this copy merges files; it does not remove files created
since the backup. Use an empty recovery storage volume when an exact storage
restore is required. The ownership command gives the application, running as
UID/GID `1000`, read/write ownership of the restored storage.

Start only `web` first and check health, login, notes, and history. Its entrypoint
runs `db:prepare`, so start the matching application revision first; upgrading
before validation may migrate the restored databases.

```sh
docker compose up -d web
```

After validation, start `daily_refresh` and, if desired, the sampler. Restored
queue state may resume jobs that were pending at backup time. A recovery drill
should remain private; do not leave duplicate schedulers running afterward.

## Refresh and backfill

The Maintenance page refreshes sharing data and optionally playback history.
For large imports, use the command line. Choose a bounded window first:

```sh
# Import the most recent 30 days, plus current sharing metadata.
docker compose run --rm web env PLEX_HISTORY_DAYS=30 ./bin/rails plex:refresh

# Deliberately import all history Plex provides.
docker compose run --rm web env PLEX_HISTORY_DAYS=all PLEX_HISTORY_MAX_PAGES=all ./bin/rails plex:backfill_history

# Example: resume at the failed page printed by a previous run.
docker compose run --rm web env PLEX_HISTORY_START_PAGE=179 PLEX_HISTORY_DAYS=all ./bin/rails plex:backfill_history
```

Backfills save each page. After exhausted timeout retries they exit nonzero and
print the failed page to resume. Resume at that page, not the following one.
Saved pages remain available; re-reading them updates metadata without duplicate
events. Preserve the original page size and history window when resuming.
`PLEX_HISTORY_MAX_PAGES` limits pages in the current run: start page `179` with a
limit of `5` scans pages `179` through `183`.

The helper scripts provide the same operations:

```sh
PLEX_HISTORY_DAYS=730 ./scripts/backfill-history
./scripts/resume-backfill 179
./scripts/sample-now-playing
./scripts/prune-samples
```

The backfill/resume helpers default to **all history** unless you override their
window. The ordinary `plex:refresh` task defaults to 730 days. Daily refreshes use
`PLEX_DAILY_REFRESH_DAYS`, defaulting to one day, and preserve history for all
accounts, including the owner and former shared users.

The daily service runs at `PLEX_DAILY_REFRESH_AT` in the container's `TZ`.
Defaults are `04:15` and `Etc/UTC`; this is not automatically your host's timezone.
Change those values in `.env.production` and recreate the services to apply them.

## Optional live-session sampling

The `now_playing_sampler` service belongs to the `sampling` profile and is not
started by an ordinary first `docker compose up -d`. Start it explicitly:

```sh
docker compose up -d now_playing_sampler
```

It records live player/IP details when Plex provides them, every
`PLEX_NOW_PLAYING_SAMPLE_INTERVAL` seconds, and prunes samples older than
`PLEX_NOW_PLAYING_RETENTION_DAYS`. Defaults are 60 seconds and 90 days. Historical
imports cannot reconstruct missing old player/IP details. Stop the sampler with
`docker compose stop now_playing_sampler`; existing samples remain in the database.

## Useful commands

```sh
./scripts/logs
./scripts/logs all
docker compose ps
docker compose exec web ./bin/rails console
docker compose logs --tail=100 daily_refresh
docker compose logs --tail=100 now_playing_sampler
```

Treat logs, exports, and console output as potentially sensitive. Share only
redacted excerpts when reporting a problem.
