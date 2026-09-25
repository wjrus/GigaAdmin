# Deploy GigaAdmin

Production is a small Docker Compose stack. The existing deployment stays at:

```sh
/apps/plex
```

New checkouts can live under `$HOME/apps/plex/GigaAdmin`. The checkout name is
independent of the Compose project name: `compose.yml` pins the legacy `plex`
project so existing `plex_postgres_data` and `plex_app_storage` volumes remain
attached after a move. Preserve any existing `COMPOSE_PROJECT_NAME` override.
Database names and `PLEX_*` environment variables remain compatible.

For an existing checkout, update its remote before the next deployment:

```sh
git remote set-url origin git@github.com:wjrus/GigaAdmin.git
```

It runs:

- `web`: Rails/Puma/Thruster on container port `80`
- `db`: PostgreSQL 18 with primary, cache, queue, and cable databases
- `daily_refresh`: scheduled Plex metadata/history refresh task
- `now_playing_sampler`: optional current-session sampler

The host port defaults to `3010`, bound on all host interfaces so a separate
Nginx Proxy Manager container/host can reach it. Your reverse proxy can forward
`plexadmin.example.com` to:

```text
http://<docker-host-ip>:3010
```

## First Setup

On the server:

```sh
mkdir -p "$HOME/apps/plex"
cd "$HOME/apps/plex"
git clone git@github.com:wjrus/GigaAdmin.git
cd GigaAdmin

cp .env.production.example .env.production
cp .env.postgres.example .env.postgres
```

Generate secrets:

```sh
openssl rand -hex 64
openssl rand -hex 32
```

Put the first value in `.env.production` as `SECRET_KEY_BASE`. Put the second
value in both Postgres password locations:

```sh
# .env.postgres
POSTGRES_PASSWORD=...

# .env.production
PLEX_DATABASE_PASSWORD=...
```

Fill in the remaining `.env.production` values:

```sh
PLEX_HOST=plexadmin.example.com
PLEX_HOSTS=plexadmin.example.com
PLEX_ASSUME_SSL=true
PLEX_FORCE_SSL=false
ADMIN_USERS=admin@example.com
GOOGLE_CLIENT_ID=...
GOOGLE_CLIENT_SECRET=...
PLEX_TOKEN=...
PLEX_MACHINE_IDENTIFIER=...
PLEX_SERVER_BASE_URL=http://plex.example.com:32400
PLEX_DAILY_REFRESH_AT=04:15
PLEX_DAILY_REFRESH_DAYS=1
```

Use `ADMIN_USERS` as a comma-separated list when more than one Google account
should be allowed to administer the app.

Google OAuth redirect URI:

```text
https://plexadmin.example.com/auth/google_oauth2/callback
```

Deploy:

```sh
./scripts/deploy
```

Follow logs:

```sh
./scripts/logs
./scripts/logs all
```

The deploy script runs `git pull --ff-only`, validates Compose configuration,
builds the image, prepares the databases, starts `web` and `daily_refresh`, and
verifies `/up` through the host port with bounded request timeouts. A checkout
lock prevents overlapping deployments. After an unclean shutdown, remove
`tmp/deploy.lock` only after confirming that no deploy is still running.

The `now_playing_sampler` service is opt-in; start it explicitly if you want
current-session samples. Subsequent deploys update an already-running sampler
to the new image:

```sh
docker compose up -d now_playing_sampler
```

## Dependency Updates

Ruby is pinned to 3.4.10 in both `.ruby-version` and the Dockerfile. Rebuild the
image through the normal deploy script to pick up runtime and locked gem updates.

Solid Queue 1.7 supports the existing queue schema for ordinary jobs. This app
does not use its new batch API, so the optional batch migration is not included.
The dispatcher may log a pending-migration deprecation warning; the batch tables
will be required before a future upgrade to Solid Queue 2.0.

## Nginx Reverse Proxy

Use a vhost for `plexadmin.example.com` that terminates TLS and proxies to the local
Compose port.

Plain nginx example:

```nginx
server {
  listen 443 ssl http2;
  server_name plexadmin.example.com;

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

If port `3010` conflicts with another app:

```sh
PLEX_ADMIN_PORT=3011 ./scripts/deploy
```

Then point nginx at `127.0.0.1:3011`.

If nginx runs on the same host and you want to keep the app private to
localhost only:

```sh
PLEX_ADMIN_BIND=127.0.0.1 ./scripts/deploy
```

## Import Development Data

This copies the local development database snapshots and notes into the
production primary database. It does not copy secrets; those stay in
`.env.production`.

On your development machine:

```sh
cd /path/to/plex/GigaAdmin
mkdir -p tmp
pg_dump --format=custom --no-owner --no-acl --file=tmp/plex_development.dump plex_development
scp tmp/plex_development.dump <server>:/apps/plex/tmp/plex_development.dump
```

On the server:

```sh
cd /apps/plex
./scripts/deploy
docker compose stop web
docker compose cp tmp/plex_development.dump db:/tmp/plex_development.dump
docker compose exec -T db pg_restore \
  --clean \
  --if-exists \
  --no-owner \
  --no-acl \
  --role=plex \
  --username=plex \
  --dbname=plex_production \
  /tmp/plex_development.dump
docker compose run --rm web ./bin/rails db:migrate
docker compose up -d web daily_refresh
```

Verify:

```sh
docker compose exec web ./bin/rails runner 'puts ShareSnapshot.count; puts PlexUserNote.count'
curl -fsSI -H 'Host: plexadmin.example.com' http://127.0.0.1:3010/up
```

## Refresh And Backfill

Manual Plex metadata refreshes are available from the Maintenance page. The
panel shows whether a refresh is queued/running, the last heartbeat, and history
progress when history is included.

For long history work, prefer the command line:

```sh
docker compose run --rm web ./bin/rails plex:refresh
docker compose run --rm web env PLEX_HISTORY_DAYS=all PLEX_HISTORY_MAX_PAGES=all ./bin/rails plex:backfill_history
docker compose run --rm web env PLEX_HISTORY_START_PAGE=179 PLEX_HISTORY_DAYS=all ./bin/rails plex:backfill_history
```

Or use the helper scripts:

```sh
./scripts/backfill-history
./scripts/resume-backfill 179
./scripts/sample-now-playing
./scripts/prune-samples
```

Backfill writes progress after each page. If a connection drops or Plex times
out too many times, resume from the resume page shown in the task output. When
a page exhausts its retries, that is the failed page itself, not the next one.
The task marks the run failed and exits nonzero; previously saved pages remain
available. Re-reading pages updates metadata without creating duplicate events.

Daily refreshes persist all accounts and events within their configured window,
including the owner, rather than stopping once shared users have been matched.
Plex/API failures are reported as failed runs. Metadata-only refreshes recover
last-streamed values from the latest snapshot and local event storage.

Deploy includes a concurrent PostgreSQL index migration on history server/date
columns. Allow the database preparation step to finish before restarting the
application. No extra cache service or history backfill is required for the
query improvements. Reload any library edit forms left open across deployment
before saving; stale forms are rejected.

## Useful Commands

```sh
./scripts/deploy
./scripts/logs
./scripts/logs db
docker compose ps
docker compose exec web ./bin/rails console
docker compose run --rm web ./bin/rails plex:refresh
docker compose run --rm web ./bin/rails plex:backfill_history
docker compose logs -f daily_refresh
docker compose logs -f now_playing_sampler
```

## Backups

Back up the Compose volume:

```text
plex_postgres_data
```

The app storage volume is currently only for Rails local storage; this app does
not store Plex media there.

PostgreSQL contains Plex sharing data, playback history, now-playing samples,
raw Plex metadata payloads, device names, IP addresses, and local admin notes.
Treat dumps and backups as sensitive data.
