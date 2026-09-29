# Run GigaAdmin with Docker

Docker Compose is the easiest way to run GigaAdmin. It builds the application from this repository and starts Rails, PostgreSQL, and a daily Plex refresh service. You do not need Ruby, Node.js, or PostgreSQL installed on the host, and Google sign-in is optional.

## What you need

- A working [Docker Engine with the Compose plugin](https://docs.docker.com/engine/install/) or [Docker Desktop](https://docs.docker.com/desktop/).
- Git, Bash, OpenSSL, and curl on the host.
- A Plex server you own, its owner token, and a network address reachable from Docker.

Confirm Docker is running and Compose is available:

```sh
docker version
docker compose version
```

The initial configuration serves GigaAdmin only on the Docker host's localhost address. Complete the first administrator setup privately before allowing other people to reach the application.

## 1. Download and prepare

```sh
git clone https://github.com/wjrus/GigaAdmin.git
cd GigaAdmin
./scripts/setup
```

Setup generates private environment files with fresh application and database secrets. It does not print the secrets or start containers. It refuses to overwrite any existing `.env`, `.env.production`, or `.env.postgres` file, so it cannot silently replace credentials on an existing installation.

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

For access from other computers without an SSH tunnel, set up a hostname and HTTPS reverse proxy using the [deployment guide](deploy.md). Complete that setup before distributing invitation links, so recipients receive the correct address. The [configuration guide](configuration.md#google-sign-in-optional) also covers optional Google sign-in.

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

The optional current-session sampler records device/IP information that Plex exposes for future sessions. Enable it only if you want those records:

```sh
docker compose up -d now_playing_sampler
```

The sampler belongs to the `sampling` Compose profile, so a normal `docker compose up -d` does not start it. An explicitly started sampler is updated by subsequent `scripts/deploy` runs. To stop sampling, run `docker compose stop now_playing_sampler`; start it explicitly again after stopping the entire stack. Sample retention defaults to 90 days. See [Docker's profile behavior](https://docs.docker.com/compose/how-tos/profiles/) for details.

PostgreSQL data and application storage live in named Docker volumes. Keep the installation's `COMPOSE_PROJECT_NAME` unchanged, and do not use `docker compose down -v` as an update or troubleshooting step: it deletes those volumes. See [deployment and operations](deploy.md) for backups, restoration, and production maintenance.

## Common setup problems

| Symptom | Check |
| --- | --- |
| Setup refuses to run | One of the target environment files already exists. Preserve it; use a fresh checkout for a new installation or the upgrade instructions for an existing one. |
| Browser cannot connect | Verify `docker compose ps`; for a remote host use the SSH tunnel or configured HTTPS proxy. The default bind deliberately accepts only local connections. |
| Plex refresh reports an authentication error | Replace an expired token with a current server-owner token, then recreate the application services. |
| Sharing works but sessions/history are empty | Check `PLEX_SERVER_BASE_URL` from the container's network and import playback history. A host-only loopback address is not reachable from a normal container. |
| A Google sign-in screen appears unexpectedly | `auto` selects Google when both Google credentials are filled in. Clear them or explicitly set `GIGAADMIN_AUTH_MODE=local`, then recreate services. |
| You forgot your local password | Use the interactive password reset command in [configuration.md](configuration.md#choose-how-administrators-sign-in). |

After changing `.env.production`, recreate the application services to load it; restarting an existing container does not replace its environment. See [configuration.md](configuration.md) for the full setting reference.
