# Configure GigaAdmin

Start with the [Docker quick start](docker.md) or the [development guide](development.md). This page explains the settings those guides ask you to supply.

GigaAdmin manages one Plex server per installation. It uses your server owner's Plex token to read server information and make the sharing changes you request. Administrators who can sign in to GigaAdmin can manage that server's shared access.

## Choose how administrators sign in

New installations use `GIGAADMIN_AUTH_MODE=auto`. With no Google OAuth credentials, GigaAdmin uses local email/password accounts. If both Google credentials are configured, `auto` uses Google sign-in, preserving existing Google installations. Set `local` or `google` explicitly if you want to pin the sign-in method; explicit Google mode does not fall back to local accounts if its credentials are missing.

For local accounts, use the Docker guide's explicit `local` SSL mode to open GigaAdmin on localhost and create the first administrator at `/setup` before exposing the app to your network. An existing HTTPS proxy with restricted access also works. Use your email address and a password of at least 12 characters. This first account is the **super administrator**, who controls access to GigaAdmin itself. Setup closes after the first account is created. The account belongs to GigaAdmin; it does not create or change a Plex account.

Only super administrators can invite or remove GigaAdmin administrators at `/admin/users`. Ordinary administrators can change their own passwords and use the Plex administration features. Password changes and invitation creation require your current password. Invitations create an email-bound, single-use link that expires after 48 hours; copy and send it to the intended administrator yourself. The recipient chooses their password. GigaAdmin does not require SMTP or send the invitation automatically. **Every administrator has full access to GigaAdmin's Plex sharing controls**, including changing library access and removing shares; the super role additionally controls who can administer GigaAdmin.

The first local account is always a super administrator. `ADMIN_USERS` can list additional super-administrator emails, separated by commas. If this list is nonempty before initial setup, the first account must use one of those emails. Adding an email to the list does not create a local account; invite that person first. Removing a later account's email from the list returns it to ordinary administrator access after the updated environment is loaded. It does not block local sign-in, and it does not remove the first account's super role.

If a local administrator forgets their password, an operator with access to the deployment can run:

```sh
docker compose run --rm --no-deps web bin/rails admin:reset_password
```

The task prompts for email and password interactively. Do not put a password in the command itself. In native development use `bin/rails admin:reset_password`.

For Google sign-in, follow the [optional Google setup](#google-sign-in-optional) below. Local invitations and password recovery apply only to local accounts.

## Connect your Plex server

Set these values in `.env.production` for Docker or `.env` for native development:

```dotenv
PLEX_TOKEN=your-server-owner-token
PLEX_MACHINE_IDENTIFIER=your-server-machine-identifier
PLEX_SERVER_BASE_URL=http://plex-server.example.com:32400
```

### Find the owner's token

Sign in to Plex Web as the account that owns the server. Open an item from one of that server's libraries, choose **Get Info**, then **View XML**, and copy the `X-Plex-Token` value from the URL. Save only the token value in your environment file. Plex documents this as a temporary token; it can become invalid and need replacing. See [Plex's token instructions](https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/).

Treat the token like an account password. Do not paste the XML URL into issues, screenshots, terminal commands, or chat. A shared user's token is insufficient for administering the server's sharing settings.

### Find the machine identifier

After saving the token and building the Docker image, run this from the checkout:

```sh
docker compose run --rm --no-deps web bin/rails runner 'Plex::Client.from_env.servers.each { |server| puts "#{server[:name]}: #{server[:machine_identifier]} (owned=#{server[:owned]})" }'
```

For native development, run the same Ruby expression with `bin/rails runner` instead of the `docker compose run --rm --no-deps web bin/rails runner` prefix.

This verifies the token against `plex.tv` and prints server names, identifiers, and ownership flags. Choose the server you own (`owned=1` or `owned=true`) and save its identifier as `PLEX_MACHINE_IDENTIFIER`. The command reads the token from the configured environment and sends it in the `X-Plex-Token` HTTP header, keeping it out of URLs, shell history, and command arguments. It does not print the full Plex response, which can contain credentials.

### Choose an address the application can reach

`PLEX_SERVER_BASE_URL` is the direct address of **Plex Media Server**, not your GigaAdmin address or `https://app.plex.tv`. It supplies playback history, current sessions, and cover artwork. The sharing features can use `plex.tv` without it, but set it for the full dashboard.

| Where Plex runs | Example address |
| --- | --- |
| Another machine on your LAN or VPN | `http://plex-server.example.com:32400` or that machine's private IP |
| The same machine as native Rails development | `http://127.0.0.1:32400` |
| The Docker Desktop host | `http://host.docker.internal:32400` |
| Another container on a shared Docker network | `http://plex:32400`, using its actual service or network alias |

Inside a container, `localhost` refers to that container. Docker Desktop provides `host.docker.internal` for host services; see [Docker Desktop networking](https://docs.docker.com/desktop/features/networking/networking-how-tos/). On native Linux Docker Engine, use the host's LAN address or add a host-gateway mapping to each GigaAdmin service that contacts Plex. For example, save this as `compose.override.yml`:

```yaml
services:
  web:
    extra_hosts:
      - "host.docker.internal:host-gateway"
  daily_refresh:
    extra_hosts:
      - "host.docker.internal:host-gateway"
  now_playing_sampler:
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

Then use `http://host.docker.internal:32400`. This requires Plex to listen on an interface reachable from Docker, and the host firewall must permit it. The mapping does not expose a service bound only to the host's loopback interface. See [Docker's host-gateway documentation](https://docs.docker.com/reference/cli/dockerd/#configure-host-gateway-ip).

Use HTTP only over a trusted private network or VPN. For HTTPS, use an address whose hostname matches Plex's certificate; GigaAdmin verifies certificates. Do not use a public HTTP URL for the Plex API.

## Google sign-in (optional)

1. Create or select a project in [Google Cloud Console](https://console.cloud.google.com/). Configure the Google Auth Platform branding and audience. Choose **External** for personal Google accounts, or **Internal** only if all administrators belong to your Google Workspace organization.
2. Under **Clients**, create an OAuth client with application type **Web application**. Add the authorized redirect URI for each address you actually use:

   | Installation | Authorized redirect URI |
   | --- | --- |
   | Docker on your own computer | `http://localhost:3010/auth/google_oauth2/callback` |
   | Native development | `http://localhost:3000/auth/google_oauth2/callback` |
   | Hosted installation | `https://gigaadmin.example.com/auth/google_oauth2/callback` |

3. Copy the client ID and secret into your environment file. Set the Google account email addresses allowed to administer GigaAdmin:

   ```dotenv
   GIGAADMIN_AUTH_MODE=google
   GOOGLE_CLIENT_ID=your-client-id.apps.googleusercontent.com
   GOOGLE_CLIENT_SECRET=your-client-secret
   ADMIN_USERS=admin@example.com,another-admin@example.com
   ```

4. Restart native Rails or recreate the Docker application services after editing the file. Use the sign-in button in GigaAdmin.

The redirect URI must match the browser-visible scheme, hostname, port, and path exactly. Google's web-client rules require HTTPS except for localhost; a private LAN IP such as `http://192.168.1.10:3010` is not a substitute for the localhost callback. For access from another computer, use the HTTPS deployment in [deploy.md](deploy.md). No authorized JavaScript origin is needed for GigaAdmin's server-side OAuth flow. See [Google's web application OAuth setup](https://developers.google.com/identity/protocols/oauth2/web-server#creatingcred).

GigaAdmin requests only `openid`, `email`, and `profile`. Google's **Testing** status ordinarily limits an application to its listed test users, but Google exempts these basic sign-in scopes from that restriction and the seven-day authorization expiry. You may list your intended administrators as test users, but **always configure `ADMIN_USERS`**: Google's testing audience is not GigaAdmin's access control. Workspace policies can still restrict sign-in. See [Google's audience rules](https://support.google.com/cloud/answer/15549945?hl=en).

The Google allowlist is checked on every authenticated request. Removing an email takes effect for existing sessions after the changed environment is loaded. These administrator emails need not match the Plex owner's email.

## Choose HTTPS handling

For Docker deployments, set `GIGAADMIN_SSL_MODE` in `.env.production`:

| Mode | Behavior |
| --- | --- |
| `proxy` (default, including when unset) | Your upstream proxy terminates HTTPS. The app serves HTTP internally with Rails `assume_ssl` and `force_ssl` enabled. |
| `letsencrypt` | Thruster obtains and renews certificates for `PLEX_HOST`. Publish ports 80/443 and preserve the storage volume. Rails enables both SSL settings. |
| `local` | Plain HTTP for private localhost setup; both Rails SSL settings are disabled. Select this explicitly. |

`scripts/setup` defaults to `proxy`; `scripts/setup --ssl-mode local` opts into
private HTTP bootstrap. The Docker entrypoint applies the selected mode to all
application services, overriding the lower-level `PLEX_ASSUME_SSL` and
`PLEX_FORCE_SSL` variables. It disables built-in TLS in proxy/local modes so an
old Thruster setting cannot unexpectedly acquire certificates. The
[HTTPS deployment guide](deploy.md#add-https-access) covers domains, published
ports, certificates, and switching from private setup. Native Rails operators
can continue setting the two lower-level Rails variables directly.

## Environment files

| File | Purpose |
| --- | --- |
| `.env` for Docker | Compose settings: project name, host bind address, and published port; generated from `.env.docker.example` by `scripts/setup` |
| `.env.production` | Runtime application settings and secrets for every Docker application service |
| `.env.postgres` | PostgreSQL's initial password; must match the application database password |
| `.env` for native development | Application settings, loaded by `dotenv-rails`; copy `.env.example` |

Use separate checkouts for Docker deployment and native development if you need both. Their `.env` files have different purposes. Production Rails reads environment variables passed by Docker; it does not load `.env` through `dotenv-rails`.

### Essential settings

| Variable | Required for | Value |
| --- | --- | --- |
| `GIGAADMIN_AUTH_MODE` | Sign-in choice | `auto` (also the default when omitted) selects Google when both OAuth credentials are present, otherwise local accounts. Set `local` or `google` to require that method. |
| `PLEX_TOKEN` | Plex integration | Server owner's account token |
| `PLEX_MACHINE_IDENTIFIER` | Plex integration | Identifier returned for your server |
| `PLEX_SERVER_BASE_URL` | History, current sessions, and covers | Address reachable from the application; see networking above |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Google mode | Web application OAuth credentials |
| `ADMIN_USERS` | Optional in local mode; required in Google mode | Comma-separated super-administrator emails. In Google mode this also controls who may sign in. The first local account remains a super administrator independently of the list. |
| `SECRET_KEY_BASE` | Production | Random application secret generated by `scripts/setup`; preserve it across upgrades |
| `PLEX_DATABASE_PASSWORD` | Docker application | Must match `POSTGRES_PASSWORD` in `.env.postgres` |
| `POSTGRES_PASSWORD` | Docker database initialization | Generated by `scripts/setup`; changing the file later does not change an existing PostgreSQL role's password |

The standard Docker deployment uses `SECRET_KEY_BASE`; it does **not** require the repository owner's `config/master.key` or `RAILS_MASTER_KEY`. Do not use the build-only `SECRET_KEY_BASE_DUMMY` setting at runtime.

### Hosting and scheduling

| Variable | New installation value | Purpose |
| --- | --- | --- |
| `COMPOSE_PROJECT_NAME` | `gigaadmin` in generated `.env` | Names Docker resources. Preserve an existing installation's value and volumes when upgrading. |
| `PLEX_ADMIN_BIND` | `127.0.0.1` in generated `.env` | Host interface serving GigaAdmin; change only as part of your proxy/network configuration |
| `PLEX_ADMIN_PORT` | `3010` | Published host port |
| `PLEX_HOST` | `localhost` | Browser-facing application hostname, without scheme or port |
| `PLEX_HOSTS` | `localhost` | Comma-separated allowed application hostnames |
| `GIGAADMIN_SSL_MODE` | `proxy` | Docker HTTPS handling: `proxy`, `letsencrypt`, or explicit private `local` mode |
| `PLEX_ASSUME_SSL` | Native Rails default `true` | Lower-level Rails setting; Docker's SSL mode controls it |
| `PLEX_FORCE_SSL` | Native Rails default `true` | Lower-level Rails setting; Docker's SSL mode controls it |
| `TZ` | `Etc/UTC` | Container system timezone used by the daily scheduler, such as `Europe/London` |
| `PLEX_DAILY_REFRESH_AT` | `04:15` | Daily refresh time in the container's `TZ`, in `HH:MM` format |
| `PLEX_DAILY_REFRESH_DAYS` | `1` | History window for scheduled refreshes |
| `RAILS_LOG_LEVEL` | `info` | Avoid `debug` on shared systems unless needed for a specific investigation |

The Docker image uses UTC unless you set `TZ`; `04:15` is therefore **04:15 UTC**, not automatically the Docker host's local time. Recreate the services after changing timezone or schedule settings.

### History, sampling, and display

| Variable | Default | Purpose |
| --- | --- | --- |
| `PLEX_API_BASE_URL` | `https://plex.tv` | Plex account/sharing API; normally leave unchanged |
| `PLEX_CLIENT_IDENTIFIER` | `gigaadmin-local` in code | Identifier for this installation's Plex API requests; production example uses `gigaadmin-production` |
| `PLEX_CLIENT_NAME` | `GigaAdmin` | Application name sent to Plex |
| `PLEX_HISTORY_PAGE_SIZE` | `1000` | Events requested per history page; clamped to 1–2,000 |
| `PLEX_HISTORY_MAX_PAGES` | `all` | Cap on pages scanned in a run, or `all` |
| `PLEX_HISTORY_DAYS` | `730` in examples and the refresh task | Lookback window in days; use `all` for full available history |
| `PLEX_HISTORY_START_PAGE` | `1` | Resume page for `plex:backfill_history` |
| `PLEX_HISTORY_RETRIES` | `8` | Retries per failed backfill page; clamped to 0–20 |
| `PLEX_NOW_PLAYING_SAMPLE_INTERVAL` | `60` | Seconds the optional sampler waits between completed samples |
| `PLEX_NOW_PLAYING_RETENTION_DAYS` | `90` | Sample retention; clamped to 1–3,650 days |
| `PLEX_OWNER_ACCOUNT_ID` | Unset | Identifies your owner account in locally stored history |
| `PLEX_OWNER_NAME`, `PLEX_OWNER_USERNAME`, `PLEX_OWNER_EMAIL` | Unset | Optional labels for that owner account |
| `ADMIN_EMAIL` | `rake` | Audit label for a command-line refresh; does not grant sign-in access |

The owner is not normally returned as a shared-library user. GigaAdmin also displays accounts found in local playback history; the `PLEX_OWNER_*` settings give the owner's history a useful label.

For custom database arrangements, production accepts `PLEX_DATABASE_USERNAME` (default `plex`), `POSTGRES_HOST` (default `localhost`), and `POSTGRES_PORT` (default `5432`). Compose supplies the database host and user automatically. The existing `plex_*` database names are intentional and do not require renaming.

## Keep administrative data private

Keep actual `.env*` files private and out of version control; the checked-in `.example` files contain placeholders only. Restrict file permissions, keep a protected copy of production secrets, and redact logs before sharing them. Avoid commands that print the full environment or expanded Compose configuration.

The Docker image disables Thruster's duplicate request log because it includes
unfiltered query strings, which can contain administrator invitation tokens.
Rails request logging remains enabled and filters token/password parameters.
Keep `THRUSTER_LOG_REQUESTS=false` and configure upstream proxy logs to omit
query strings as shown in the deployment guide.

The database contains user emails, administrative notes, access-change records, and playback history. Current-session samples can also contain device names, IP addresses, and session identifiers. Treat database backups and CSV exports as sensitive. Use HTTPS for access beyond localhost, and grant administrator access only to people trusted to change Plex sharing.
