# Develop GigaAdmin

For running the application without installing a Ruby toolchain, use the [Docker quick start](docker.md). This guide runs Rails and PostgreSQL directly on your development machine.

## Prerequisites

- Ruby **3.4.10**, matching [`.ruby-version`](../.ruby-version), with Bundler.
- PostgreSQL **18**, matching Docker and CI, running locally.
- libvips and PostgreSQL client/development libraries for the Ruby gems.
- Node.js **22 or newer** for the JavaScript test suite. Application assets use import maps and Tailwind's Ruby tooling; there is no npm install step.
- Git and your platform's native build tools for compiling gems.

Use your Ruby version manager to select the pinned version before running commands. Verify `ruby --version` rather than using macOS's system Ruby by accident.

On macOS, Homebrew can supply PostgreSQL and libvips:

```sh
brew install postgresql@18 vips
brew services start postgresql@18
```

Ensure PostgreSQL's `bin` directory is on your `PATH`, including `pg_config` for building the `pg` gem. Configure a local PostgreSQL role matching your operating-system username with permission to create development/test databases. The default Rails configuration uses a Unix socket and that role. For a different local connection, set libpq variables such as `PGHOST`, `PGPORT`, `PGUSER`, and `PGPASSWORD` in your development environment.

## First run

```sh
git clone https://github.com/wjrus/GigaAdmin.git
cd GigaAdmin
cp .env.example .env
```

Edit `.env` with your Plex settings from [configuration.md](configuration.md). The default `GIGAADMIN_AUTH_MODE=auto` uses local administrator accounts when Google credentials are blank; fill in both Google credentials to use Google sign-in instead. Use a Plex server you are comfortable administering: library-access changes made through a development instance affect that server too.

Then run:

```sh
bin/setup
```

`bin/setup` installs missing gems, prepares the development database, clears local logs and temporary files, and **starts the development server**. Do not run a second `bin/dev` while it is already running. Open `http://localhost:3000` and create the first local administrator when using local sign-in. That account is a super administrator and can invite additional administrators. If `ADMIN_USERS` is nonempty, use one of those emails for the first account.

To prepare the environment without starting the server:

```sh
bin/setup --skip-server
bin/dev
```

`bin/dev` runs Rails plus the Tailwind watcher. Avoid `bin/setup --reset` unless you intend to erase and recreate the development database.

### Background work

Development uses Rails' in-process `AsyncAdapter` for jobs, so the Maintenance refresh runs while the web process is running. **No separate `bin/jobs` process is needed for the default development setup.** These jobs are not durable across web-process restarts.

Production uses Solid Queue with a separate queue database; Compose runs its supervisor, worker, and recurring scheduler inside Puma. Aggregate activity is sampled every minute and pruned daily through that scheduler. `bin/jobs` is the Solid Queue worker entrypoint for a deliberately configured separate worker, not a prerequisite for native development. The daily history refresh remains a separate Compose service. Neither recurring schedule starts with `bin/dev`; for a single development activity observation, run `bin/rails plex:sample_now_playing` explicitly. This compatibility task name now records aggregate activity, not the old detailed session rows.

## Work with Plex data

Use **Maintenance → Refresh from Plex** for a sharing snapshot without a full history scan. To populate history as well:

```sh
bin/rails plex:refresh
```

The task defaults to a 730-day history window and runs in the terminal so a lengthy history import does not depend on a browser request. For a smaller development dataset:

```sh
PLEX_HISTORY_DAYS=7 bin/rails plex:refresh
```

The task saves progress in PostgreSQL. Use the [operations guide](deploy.md) for full-history backfills, resuming a failed page, aggregate activity collection, and retention behavior.

## Checks

Run from the repository root with the pinned Ruby active and PostgreSQL available:

```sh
bin/rails db:test:prepare test
node --experimental-vm-modules --test test/javascript/*_test.mjs
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
```

The default test database is `plex_test`; never point test commands at development or production data. Rails tests stub Plex requests and authentication rather than requiring a live server. JavaScript tests use Node's built-in test runner and VM modules to stub Stimulus. `bin/bundler-audit` updates the advisory database and requires network access; an update failure is a failed check, not a clean audit.

CI also checks production eager loading without a database or runtime secrets:

```sh
RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 BUNDLE_WITHOUT=development:test \
  POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=1 bin/rails zeitwerk:check
```

`SECRET_KEY_BASE_DUMMY` is only for build/check commands. A running production installation needs its own persistent `SECRET_KEY_BASE`, generated by `scripts/setup`; it does not need the original author's Rails master key.

## Project map

| Location | Responsibility |
| --- | --- |
| `app/controllers/` and `app/views/` | Admin pages, authorization, forms, and exports |
| `app/services/plex/` | Plex HTTP client, sharing snapshots, refresh progress, and formatting |
| `app/models/` | Cached snapshots, stream history, aggregate activity, retained legacy samples, notes, and audit records |
| `app/jobs/` and `config/recurring.yml` | Background refreshes and recurring activity collection/retention |
| `app/javascript/controllers/` | Stimulus interactions and polling |
| `lib/tasks/plex.rake` | Refresh, backfill, sample, and pruning tasks |
| `docker/` and `compose.yml` | Production service startup and schedules |
| `scripts/` | Deployment and operator helpers |
| `test/` | Rails, JavaScript, accessibility, and script checks |

Keep credentials in ignored environment files, and use synthetic records in tests. See [configuration.md](configuration.md#keep-administrative-data-private) for the data held by the application and [deploy.md](deploy.md) for production updates and recovery.
