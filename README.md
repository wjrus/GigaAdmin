# GigaAdmin

**Your Plex community, at a glance.**

GigaAdmin gives Plex server owners one place to manage library access, keep track
of shared users, and see how their server is being enjoyed. Invite a friend,
adjust their libraries, check recent activity, and keep the context you need for
the next time they get in touch.

Self-host it alongside Plex or on another machine that can reach your server.
GigaAdmin keeps its own database and connects through Plex's APIs; it needs no
access to your media files or Plex's database directory.

## Spend less time keeping track

- **Know who has access.** See users, libraries, and pending invitations
  together. Grant or remove access, or update a library for several users at
  once.
- **Keep the details close.** Add private admin notes, search and filter users,
  and open a person's history and stats from their profile.
- **See what's playing.** Follow current sessions in a live dashboard with
  artwork and player details when Plex provides them.
- **Understand your audience.** Explore playback activity by user, library, and
  time period, with CSV exports for users and playback history.
- **Know what changed.** Review an audit trail of access changes, invitations,
  and local administrative actions made through GigaAdmin.

Sharing views and historical reports use locally saved Plex data, so browsing
them doesn't require a fresh Plex request on every page. Scheduled and on-demand
refreshes keep that data current.

## Make it yours

The recommended installation uses Docker Compose, which packages the app,
PostgreSQL, and background services together. You don't need to install Ruby or
PostgreSQL on the host.

You'll need Docker with Compose, a Plex server you own, and its owner account
token. The [Docker setup guide](docs/docker.md) walks through getting these ready
and connecting your first server. Use local admin accounts or connect Google
sign-in if you prefer.

```sh
git clone https://github.com/wjrus/GigaAdmin.git
cd GigaAdmin
./scripts/setup --ssl-mode local
```

This selects localhost HTTP for private first setup. Without that option, setup
defaults to HTTPS termination at your existing upstream proxy. The script
generates local configuration files and database secrets. Add
your Plex settings to `.env.production` as described in the guide, then start the
app:

```sh
./scripts/deploy
```

Open `http://localhost:3010`, create your first account, and run your first Plex
refresh. That first local account becomes a super administrator. Only super
administrators can invite or remove other GigaAdmin administrators; set
`ADMIN_USERS` to designate additional super administrators explicitly.
Complete that first visit before exposing the app to other people. For access
beyond the Docker host, select external SSL termination (the default) or built-in
Let's Encrypt using the [HTTPS guide](docs/deploy.md#add-https-access). Nginx is
optional: the image already includes the Puma web server and Thruster proxy.

**Every GigaAdmin administrator can change who has access to your Plex
libraries.** Inviting an administrator delegates sharing control through the
configured owner's token, along with access to playback history. Invite only
people you trust with that authority, and keep the token and database backups
private. By default, invited administrators can manage Plex sharing, but cannot
create or remove GigaAdmin administrator accounts.

## Go deeper

- [Using GigaAdmin](docs/features.md) — features, refresh behavior, and what the
  playback numbers mean.
- [Docker setup](docs/docker.md) — install and connect your first server.
- [Configuration](docs/configuration.md) — Plex, admin sign-in, and optional
  settings.
- [Deployment and operations](docs/deploy.md) — HTTPS, upgrades, backups, and
  history imports.
- [Local development](docs/development.md) — run from source and check changes.

Each installation manages one configured Plex server. GigaAdmin is an
independent project and is not affiliated with Plex.
