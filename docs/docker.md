# Run GigaAdmin with Docker

Docker Compose is the easiest way to run GigaAdmin. It builds the application from this repository and starts Rails, PostgreSQL, and a daily Plex refresh service. You do not need Ruby, Node.js, or PostgreSQL installed on the host, and Google sign-in is optional.

Prefer plain Docker? See [running without Compose](#run-without-compose) below. The image already includes Puma and Thruster, so nginx is not required to serve the application.

## What you need

- A working [Docker Engine with the Compose plugin](https://docs.docker.com/engine/install/) or [Docker Desktop](https://docs.docker.com/desktop/).
- Git, Bash, OpenSSL, and curl on the host.
- A Plex server you own, its owner token, and a network address reachable from Docker.

Confirm Docker is running and Compose is available:

```sh
docker version
docker compose version
```

The generated bind address accepts connections only from the Docker host. This guide explicitly selects `local` SSL mode for a private first visit over HTTP; the application default is `proxy`, which expects HTTPS termination at your existing edge proxy. Complete the first administrator setup privately before allowing other people to reach the application.

## 1. Download and prepare

```sh
git clone https://github.com/wjrus/GigaAdmin.git
cd GigaAdmin
./scripts/setup --ssl-mode local
```

Setup generates private environment files with fresh application and database secrets. It does not print the secrets or start containers. It refuses to overwrite any existing `.env`, `.env.production`, or `.env.postgres` file, so it cannot silently replace credentials on an existing installation.

The explicit `--ssl-mode local` makes the localhost HTTP steps below work. Plain `./scripts/setup` defaults to `GIGAADMIN_SSL_MODE=proxy`: Rails assumes and enforces HTTPS behind an upstream proxy. An unset SSL mode also uses that external-termination default. If your existing HTTPS proxy is already ready, use the [proxy deployment instructions](deploy.md) instead of this temporary local mode.

| File | What to edit |
| --- | --- |
| `.env.production` | Plex connection settings and optional authentication/scheduling settings |
| `.env` | Compose project name, bind address, and host port |
| `.env.postgres` | Normally nothing; setup generates the matching database password |

Keep these files and their backups private. You do not need a Rails master key. For an existing installation, keep its environment files and follow [upgrading](deploy.md) instead of running setup again.

## 2. Connect Plex

Edit `.env.production` in your text editor and supply:

```dotenv
PLEX_TOKEN=your-server-owner-token
PLEX_MACHINE_IDENTIFIER=your-server-machine-identifier
PLEX_SERVER_BASE_URL=http://plex-server.example.com:32400
```

See [finding your Plex credentials](configuration.md#connect-your-plex-server) for the token and machine identifier. If you need the documented command to discover the identifier, save your token first, run `docker compose build web`, then run the discovery command. The later deployment reuses the build cache.

Use the address where **the container** can reach Plex. For a separate LAN server, that is usually its private IP or DNS name and port `32400`. `localhost` inside Docker means the GigaAdmin container, not the host. The [networking examples](configuration.md#choose-an-address-the-application-can-reach) cover Docker Desktop and Linux host access.

Leave the Google fields blank to use local email/password accounts. The first account is always a super administrator. Optionally set `ADMIN_USERS` to your email before first setup to require that email for the initial account; this comma-separated list can also designate additional super administrators. Other settings can keep their defaults. The daily refresh is scheduled for **04:15 UTC**; set `TZ` and `PLEX_DAILY_REFRESH_AT` if you want a different time.

## 3. Start GigaAdmin

```sh
./scripts/deploy
```

The script updates the checkout, builds the application image, starts PostgreSQL, prepares the databases, starts the web and daily-refresh services, and checks application health. Initial builds take longer than later updates.

On the same computer, open **http://localhost:3010**.

If Docker runs on a remote server, keep the localhost bind and open an SSH tunnel from your own computer:

```sh
ssh -N -L 3010:127.0.0.1:3010 user@gigaadmin-host.example.com
```

Leave that terminal open, then visit **http://localhost:3010** on your computer. Replace the SSH user and host with your server's details. If port `3010` is already in use, change `PLEX_ADMIN_PORT` in `.env` and use that port in the browser and tunnel.

Create the first administrator with your email and a password of at least 12 characters. This account becomes the **super administrator**. Initial setup closes after it is created.

Open **Maintenance** and choose **Refresh from Plex**. This imports your libraries and shared users without a large history scan. For playback statistics and last-streamed dates, import the default history window separately:

```sh
docker compose exec web bin/rails plex:refresh
```

The default window is 730 days. On a large server this can take time; use the [history and refresh instructions](deploy.md) to choose a smaller window or resume a backfill.

## 4. Invite administrators or add HTTPS

Super administrators can manage GigaAdmin accounts at `/admin/users`. Invitations generate a private link to share with the recipient; no email server is required. Invited administrators can manage Plex library access, remove shares, and view playback history. They cannot invite or remove GigaAdmin administrators unless their email is also listed in `ADMIN_USERS`.

For access from other computers without an SSH tunnel, use the [deployment guide](deploy.md) to switch to `GIGAADMIN_SSL_MODE=proxy` for your existing HTTPS proxy, or `letsencrypt` for built-in certificate management. Proxy mode is the application default; nginx is not specifically required. Complete that setup before distributing invitation links, so recipients receive the correct address. The [configuration guide](configuration.md#google-sign-in-optional) also covers optional Google sign-in.

## Everyday commands

```sh
# Check container state and recent application logs.
docker compose ps
docker compose logs --tail=50 web

# Update, rebuild, migrate, and check health.
./scripts/deploy

# Stop the services while preserving data.
docker compose --profile sampling stop

# Start the normal services again.
docker compose up -d
```

Activity graphs collect automatically through the web container's Solid Queue worker, once per minute. The records contain aggregate concurrency, playback-state and delivery-mode counts, and estimated bandwidth reported by Plex; they do not contain usernames, media titles, devices, or IP addresses. Graphs start with new observations, and failed polls leave gaps. Retention defaults to 90 days, about 129,600 observations per configured server.

To disable collection, set `PLEX_ACTIVITY_ENABLED=false` in `.env.production` and recreate the web container. Adjust retention with `PLEX_ACTIVITY_RETENTION_DAYS`. An upgrade through `scripts/deploy` stops and removes an old `now_playing_sampler` container after the new web service passes health checks. Existing detailed samples stay in PostgreSQL and remain readable; the deprecated `sampling` Compose profile is only a migration compatibility placeholder.

PostgreSQL data and application storage live in named Docker volumes. Keep the installation's `COMPOSE_PROJECT_NAME` unchanged, and do not use `docker compose down -v` as an update or troubleshooting step: it deletes those volumes. See [deployment and operations](deploy.md) for backups, restoration, and production maintenance.

## Common setup problems

| Symptom | Check |
| --- | --- |
| Setup refuses to run | One of the target environment files already exists. Preserve it; use a fresh checkout for a new installation or the upgrade instructions for an existing one. |
| Browser cannot connect | Verify `docker compose ps`; for a remote host use the SSH tunnel or configured HTTPS proxy. The default bind deliberately accepts only local connections. |
| Localhost HTTP sign-in does not work | This guide requires `GIGAADMIN_SSL_MODE=local`. Plain setup and an unset mode use `proxy`, which expects browser access over HTTPS. Recreate services after changing the setting. |
| Plex refresh reports an authentication error | Replace an expired token with a current server-owner token, then recreate the application services. |
| Sharing works but sessions/history are empty | Check `PLEX_SERVER_BASE_URL` from the container's network and import playback history. A host-only loopback address is not reachable from a normal container. |
| A Google sign-in screen appears unexpectedly | `auto` selects Google when both Google credentials are filled in. Clear them or explicitly set `GIGAADMIN_AUTH_MODE=local`, then recreate services. |
| You forgot your local password | Use the interactive password reset command in [configuration.md](configuration.md#choose-how-administrators-sign-in). |

After changing `.env.production`, recreate the application services to load it; restarting an existing container does not replace its environment. See [configuration.md](configuration.md) for the full setting reference.

## Run without Compose

You can run the same image with `docker run`, using an existing PostgreSQL 18 server reachable from the container. **PostgreSQL is a separate prerequisite; the GigaAdmin image does not contain a database server.** Neither Compose nor nginx is required for this path.

### Prepare PostgreSQL and configuration

GigaAdmin needs a dedicated login role that owns these four databases: `plex_production`, `plex_production_cache`, `plex_production_queue`, and `plex_production_cable`. In an administrative `psql` session on your PostgreSQL server, create them if they do not already exist:

```sql
CREATE ROLE plex LOGIN;
\password plex
CREATE DATABASE plex_production OWNER plex;
CREATE DATABASE plex_production_cache OWNER plex;
CREATE DATABASE plex_production_queue OWNER plex;
CREATE DATABASE plex_production_cable OWNER plex;
```

The [`\password` command](https://www.postgresql.org/docs/18/app-psql.html) prompts without putting a plaintext password in SQL history. Save the same password as `PLEX_DATABASE_PASSWORD` below. The role does not need superuser privileges; owning the databases lets Rails create and migrate their tables. Configure PostgreSQL's listener, client authentication, and firewall to allow the container's connection over your private network or VPN.

For a new checkout:

```sh
git clone https://github.com/wjrus/GigaAdmin.git
cd GigaAdmin
./scripts/setup --ssl-mode local
```

The setup script requires Bash and OpenSSL, not Compose. The explicit `--ssl-mode local` enables the private HTTP bootstrap below; omitting it selects upstream HTTPS proxy mode. It generates the application secret and environment files; this deployment uses only `.env.production`. The generated `.env` and `.env.postgres` are for the Compose path and are not passed to the plain Docker container.

Edit `.env.production` with the Plex settings described above, replace its generated database password with the dedicated PostgreSQL role's password, and add:

```dotenv
POSTGRES_HOST=postgres.example.internal
POSTGRES_PORT=5432
PLEX_DATABASE_USERNAME=plex
SOLID_QUEUE_IN_PUMA=true
GIGAADMIN_SSL_MODE=local
```

`POSTGRES_HOST` must be reachable from inside the container. Use a private DNS name/IP, or a Docker network alias if the database is already containerized on a shared network. In that case, also pass `--network your-existing-network` to `docker run`. As with Plex, `localhost` inside the application container does not refer to the Docker host. Keep the explicitly selected local mode for initial setup, and use unquoted `KEY=value` entries for Docker's `--env-file` format.

### Build, run, and create your administrator

```sh
docker build --tag gigaadmin:local .
docker volume create gigaadmin_storage
docker run --detach \
  --name gigaadmin \
  --restart unless-stopped \
  --env-file .env.production \
  --publish 127.0.0.1:3010:80 \
  --mount type=volume,source=gigaadmin_storage,target=/rails/storage \
  gigaadmin:local
```

The normal image command runs `db:prepare` before starting Rails/Puma through Thruster. PostgreSQL must already be available. `SOLID_QUEUE_IN_PUMA=true` runs the worker and recurring scheduler for Maintenance actions and automatic minute-by-minute activity collection inside the web container. No separate sampling container or host timer is needed.

Check startup and readiness:

```sh
docker logs --tail=50 gigaadmin
curl --fail http://localhost:3010/up
```

Once ready, open **http://localhost:3010** and create your first administrator privately. For a remote Docker host, use the SSH tunnel described above. The first account is a super administrator; any configured `ADMIN_USERS` restrictions also apply to initial setup. Then refresh your sharing snapshot from **Maintenance**.

For HTTPS, change `GIGAADMIN_SSL_MODE` to the default `proxy` mode for an existing HTTPS proxy, or `letsencrypt` for Thruster's built-in certificate management, following [the HTTPS options in the deployment guide](deploy.md). Let's Encrypt also needs your public `PLEX_HOST`, reachable ports 80/443 published to the container, and the persistent storage mount above for certificates. Changing the environment setting alone does not republish a running container's ports; recreate it with the documented bindings. A separate nginx installation is optional.

### Refreshes and maintenance

Plain `docker run` does not start Compose's daily history refresh service. Activity graphs collect automatically with `SOLID_QUEUE_IN_PUMA=true`. Import playback history manually with:

```sh
docker exec gigaadmin ./bin/rails plex:refresh
```

To automate incremental refreshes, schedule this command with your host's scheduler:

```sh
docker exec --env PLEX_HISTORY_DAYS=1 gigaadmin ./bin/rails plex:refresh
```

Avoid overlapping refresh runs. The manual refresh defaults to 730 days; the scheduled example limits the history window to one day. History imports and the automatic activity observations serve different purposes: imported playback events cannot reconstruct past concurrent sessions or bandwidth.

`scripts/deploy` and the Compose commands elsewhere in this guide do not manage this container. For updates or changed environment values, build the new image and recreate the application container with the same database configuration and `gigaadmin_storage` volume. Back up all four PostgreSQL databases, the storage volume, and `.env.production` before upgrades; preserve that state when replacing the container. This manual path has not been exercised by the repository's Docker Compose installation smoke test.
