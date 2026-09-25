# GigaAdmin

Small Rails app for Plex server admins. It shows shared-library access, pending
invites, local notes, playback stats, stream history, and current sessions.

The app stores Plex API results in PostgreSQL so normal page loads do not hit
Plex. Use the Maintenance page when you need to refresh Plex data on demand.

Repository: [wjrus/GigaAdmin](https://github.com/wjrus/GigaAdmin).
The local workspace is organized as `plex/GigaAdmin`, with `plex` reserved for
related projects. Run this app's commands from the `GigaAdmin` directory.

Upgrading from Plex Shares preserves the existing `PLEX_*` settings, database
names, session cookie, and Compose project name (`plex`). The directory and app
rename does not require a database rename or migration. Keep any existing
`COMPOSE_PROJECT_NAME` override when upgrading.

## Setup

Install the Ruby version in `.ruby-version` (currently 3.4.10), PostgreSQL, and
libvips before running the local setup.

```sh
cp .env.example .env
bin/setup
bin/rails db:create db:migrate
bin/dev
```

Open `http://localhost:3000`.

## Plex configuration

Put these values in `.env`:

```sh
PLEX_TOKEN=
PLEX_MACHINE_IDENTIFIER=
ADMIN_USERS=admin@example.com,another-admin@example.com
```

`PLEX_TOKEN` is your Plex account token. One practical way to find it:

1. Open Plex Web.
2. Play or inspect any item from your server.
3. Choose "Get Info" / "View XML" for the item.
4. Copy the `X-Plex-Token` value from the XML URL.

`PLEX_MACHINE_IDENTIFIER` is the server machine identifier. You can get it with
your token:

```sh
curl "https://plex.tv/api/servers?X-Plex-Token=$PLEX_TOKEN"
```

Use the `machineIdentifier` attribute for the server you own and want to audit.

Optional `.env` values:

```sh
PLEX_API_BASE_URL=https://plex.tv
PLEX_SERVER_BASE_URL=http://127.0.0.1:32400
PLEX_HISTORY_PAGE_SIZE=1000
PLEX_HISTORY_MAX_PAGES=all
PLEX_HISTORY_DAYS=730
PLEX_HISTORY_RETRIES=8
PLEX_CLIENT_IDENTIFIER=gigaadmin-local
PLEX_CLIENT_NAME=GigaAdmin
PLEX_NOW_PLAYING_SAMPLE_INTERVAL=60
PLEX_NOW_PLAYING_RETENTION_DAYS=90
PLEX_DAILY_REFRESH_AT=04:15
PLEX_DAILY_REFRESH_DAYS=1
PLEX_OWNER_ACCOUNT_ID=
PLEX_OWNER_NAME=
PLEX_OWNER_USERNAME=
PLEX_OWNER_EMAIL=
```

`PLEX_SERVER_BASE_URL` is required for "last streamed" because playback
history comes from Plex Media Server's `/status/sessions/history/all` endpoint,
not from `plex.tv`.

Use `http://...:32400` unless you know the server presents a certificate that
matches the hostname you configured.

The optional `PLEX_OWNER_*` values label your own playback-history account in
the users and user detail views. Plex does not list the server owner as a shared
library user, so the app adds any account found in local stream history that is
not already in the share snapshot.

## Main Features

- **Access**: view and edit which libraries each shared user can access.
- **Users**: quick-glance user list with notes, status, libraries, and last
  streamed data.
- **User detail**: manage libraries, edit notes, cancel pending invites, remove
  access, review stream history, and inspect per-user stats.
- **Now**: current Plex sessions with cover art, player/IP data when available,
  and background refreshes 10 seconds after the previous request completes.
  Polling pauses in hidden tabs and cancels on navigation.
- **Stats**: completed-play stats for active libraries only. Stats default to
  the last 7 days and can be toggled to 30 days, past year, or all time.
- **Log**: audit trail for admin actions such as library changes, note edits,
  suppression changes, invite cancellation, and access removal.
- **Maintenance**: manual Plex refreshes, current refresh status, now-playing
  sampling, sample pruning, playback-history summary, and suppressed-user link.

Pending invites are stored in the local snapshot when Plex exposes them. If an
invite disappears from Plex but remains in the local cache, canceling it in the
app will clean up the stale local row when Plex returns `404`.

Suppressed users are local-history accounts you do not want in the default
Access or Users lists. Suppression never deletes playback history.

Access changes are serialized per Plex server. If another admin is updating
access, retry after their change finishes. Library forms opened before an access
change must be reloaded before saving; stale selections are rejected.

Successful Plex actions are logged before refreshing the local cache. An invite
can therefore succeed even if the following refresh fails; the warning will ask
you to retry the refresh from Maintenance, not resend the invitation. Local note
and suppression changes are saved in the same transaction as their audit entry.

## Refresh behavior

Access and Users render the newest `ShareSnapshot` row for the configured
machine identifier. The Maintenance page has a "Refresh from Plex" action that
queues a metadata refresh without scanning playback history, preserving existing
last-streamed data from the newest snapshot and stored stream events. The refresh panel shows whether a
refresh is queued/running, the last message, and history progress when history
is included.

For the full history-backed refresh, prefer the rake task:

```sh
bin/rails plex:refresh
```

It can take a while when `PLEX_HISTORY_MAX_PAGES=all`, but it avoids tying the
long-running Plex history scan to a browser request. By default the task scans
the past 730 days, roughly 24 months. To intentionally scan everything, run:

```sh
PLEX_HISTORY_DAYS=all bin/rails plex:refresh
```

The task persists every history page in the requested window, including owner
and non-shared accounts. It does not stop when all shared users have been found.
For one-time population of the local stream-events table, use:

```sh
bin/rails plex:backfill_history
PLEX_HISTORY_DAYS=all PLEX_HISTORY_MAX_PAGES=all bin/rails plex:backfill_history
PLEX_HISTORY_START_PAGE=179 PLEX_HISTORY_DAYS=all bin/rails plex:backfill_history
```

`PLEX_HISTORY_RETRIES` controls how many times each history page is retried
after a Plex timeout before the task stops and prints the resume page. Backfill
saves after each page. If retries are exhausted, the task marks the run failed,
exits nonzero, and prints the page to resume. Resume at that failed page, not the
page after it. Re-reading saved pages updates their metadata without duplicating
events. Normal refresh failures also remain failures rather than reporting a
successful partial refresh; pages already saved are retained.

In Docker Compose production, the `daily_refresh` service runs the same rake task
once per day with `PLEX_DAILY_REFRESH_DAYS=1`. Set `PLEX_DAILY_REFRESH_AT` in
`.env.production` to choose the daily wall-clock time, using `HH:MM`.

The `now_playing_sampler` Compose service records lightweight current-stream
samples every `PLEX_NOW_PLAYING_SAMPLE_INTERVAL` seconds. This captures future
player/IP data from the live sessions endpoint when Plex exposes it. Samples
older than `PLEX_NOW_PLAYING_RETENTION_DAYS` are pruned automatically by the
sampler and can also be pruned from the Maintenance page.

## Stats

Stats count completed video plays only, scoped to active libraries in the latest
snapshot. Audio/track history and inactive libraries are ignored for the stats
surfaces.

The default stats period is 7 days. The available toggles are `7 days`, `30
days`, `Past year`, and `All time`.

Short periods show daily activity buckets. Past-year and all-time views show
monthly buckets. User detail pages split top titles into top series and top
movies.

The selected period is applied before play deduplication. Chart grouping and
counts run in PostgreSQL without loading each history event into Rails memory.
The server/date index also supports bounded history scans.

## Security Notes

The app is intended to run behind Google OAuth and a TLS-terminating reverse
proxy. For production behind TLS, set `PLEX_ASSUME_SSL=true`. Set
`PLEX_FORCE_SSL=true` only when Rails itself should force SSL/HSTS behavior for
your deployment.

The Google admin allowlist is checked on every authenticated request. Removing
an email revokes its existing session on the next request after the updated
configuration is loaded (restart the app when changing environment variables).
Cover requests stay behind authentication and enforce a 10 MiB limit while
streaming from Plex, including responses without a Content-Length header.

Playback history and now-playing samples can include Plex metadata, device
names, IP addresses, session identifiers, and watch history. Treat database
dumps and backups as sensitive admin data.

CSV exports escape spreadsheet formula prefixes to avoid formula execution when
opened in Excel, Numbers, or Google Sheets.

## Useful commands

```sh
bin/rails test
node --experimental-vm-modules --test test/javascript/*_test.mjs
bin/rubocop
bundle exec brakeman -q --no-pager
bin/bundler-audit
bin/importmap audit
bin/rails restart
```

`bin/bundler-audit` refreshes the advisory database before checking the locked
gems. It requires network access and fails if the database cannot be updated.
JavaScript controller tests use Node's built-in test runner (Node 22 or newer),
with VM modules enabled to stub Stimulus without adding npm dependencies.

Production helper scripts:

```sh
./scripts/backfill-history
./scripts/resume-backfill 179
./scripts/sample-now-playing
./scripts/prune-samples
./scripts/deploy
./scripts/logs
```

## Deployment

See [docs/deploy.md](docs/deploy.md) for Docker Compose,
nginx reverse proxy, and development-to-production Postgres import steps.
