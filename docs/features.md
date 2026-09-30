# Using GigaAdmin

GigaAdmin combines Plex sharing administration with locally stored playback
history. It manages one configured Plex server per installation.

For installation, start with [Docker setup](docker.md). Credentials and optional
settings are covered in [Configuration](configuration.md); command-line tasks
are in [Deployment and operations](deploy.md).

## Access and users

**Access** shows the latest saved view of shared users, their libraries, pending
invitations, and last-streamed information. From here, send a Plex invitation by
username or email and choose the libraries to share.

**Users** adds search, filters, sorting, CSV export, and bulk library changes.
Open a user to change their libraries, edit a private admin note, review playback
history and stats, cancel a pending invite, or remove access. A library's detail
page shows its shared users and playback activity.

Sharing actions change Plex immediately. Access changes are serialized per Plex
server: if another admin is making a change, retry after it finishes. If library
access has changed since you opened an edit form, reload it before saving.

Plex does not list the server owner as a shared user. GigaAdmin also includes
accounts found in local playback history, including the owner and former shared
users. Optional `PLEX_OWNER_*` settings give the owner's history a recognizable
label.

Suppress an account to hide it from the default Access and Users lists. This is
a local display preference; it does not remove Plex access or delete playback
history. Suppressed accounts remain available through the Users filter and the
Suppressed users page linked from Maintenance.

### Invitations and audit history

Pending invitations appear when Plex exposes them. Plex may provide the number
of shared libraries without the exact library list. If an invitation has already
disappeared from Plex, canceling its stale local entry removes that entry when
Plex returns `404`.

**Log** records administrative actions made through GigaAdmin: access changes,
invitations, invite cancellation, note edits, and suppression changes. It does
not provide a complete audit of changes made directly in Plex or other tools.

Successful Plex actions are logged before refreshing the local view. If an
invitation succeeds but the refresh fails, the app asks you to refresh from
Maintenance; do not resend the invitation. Local note and suppression changes
are saved in the same database transaction as their audit entries.

## Now playing

**Now** shows current Plex sessions in tile or compact view, including artwork,
playback state, and player or IP details when available. It requests another
update 10 seconds after the preceding request finishes. Polling pauses in hidden
tabs and stops when you navigate away.

GigaAdmin's production job worker samples current sessions once per minute for
the activity graphs in **Stats**. It stores aggregate stream, playback-state,
and delivery-mode counts, plus the sum of the bandwidth estimates Plex reports.
These samples contain no usernames, IP addresses, titles, or device details.
No separate sampler container is needed.

Activity history starts when this version runs; old playback history and detailed
samples cannot reconstruct past concurrency or bandwidth. Short sessions between
observations may be missed. Missing or failed observations are gaps, not zero
usage. Plex's bandwidth figures are estimates, not measured network throughput
or monthly transfer totals.

Activity samples are kept for 90 days by default and pruned daily. Set
`PLEX_ACTIVITY_ENABLED=false` to stop collection, or change
`PLEX_ACTIVITY_RETENTION_DAYS` to adjust retention. Existing detailed samples
from older versions remain readable on user profiles; the upgrade does not
delete them or continue collecting their personal details.

## History and statistics

Data-heavy pages open with navigation and a loading indicator, then fill in
asynchronously. This applies to Access, Users, user profiles, libraries, Stats,
Now Playing, Status, Maintenance, the audit log, and suppressed users. Filters
and page navigation follow the same path. Authentication and account forms remain
immediately available. If a data request fails, retry it or use the full-page
fallback; collection and import jobs do not run just because a page is opened.

Playback history is imported from your Plex Media Server. **Stats** summarizes
movie and episode activity for libraries in the latest sharing snapshot. User
profiles show their history, activity charts, and top series and movies. Audio
history and libraries absent from the current snapshot are excluded from these
statistics.

Stats ranks the **top 10 movies**, **top 10 TV shows**, and **top 10 users** by
plays. TV rankings combine episodes by show. Choose rolling **24 hours**,
**7 days**, **30 days**, **90 days**, **180 days**, **Past year**, or **All time**.
User profiles have their own **7 days**, **30 days**, **Past year**, and
**All time** period selector. All time means all history imported into GigaAdmin,
which may be a smaller window than Plex retains.

The app's “completed plays” count includes events with at least 90% played, plus
events where Plex supplied no usable completion data. It counts the same title
for the same account at most once per calendar day in the app's time zone. This
makes it an activity summary rather than an exact count of every playback
session. The selected time period is applied before this deduplication.

User-list CSV exports follow the current user filters. A user's history export
includes all rows matching its history filters, beyond the currently displayed
page. It streams in bounded batches without rebuilding the user's dashboard
statistics. CSV values escape spreadsheet formula prefixes. Exports may still contain
sensitive watch history, device names, or IP addresses, so share them carefully.

## Refreshing data

**Maintenance → Refresh from Plex** queues a sharing and library refresh. By
default it skips playback history and retains existing last-streamed information;
check **Include playback history** to import history too. The refresh panel
reports queued or running work, progress messages, and history progress for runs
that include history.

For a history-backed refresh or an initial history import, use the command-line
tasks in [Deployment and operations](deploy.md#refresh-and-backfill). A full
refresh defaults to the past 730 days. The daily service uses its separately
configured, shorter history window. Large initial imports can take a while.

History imports save progress page by page, including accounts that no longer
have sharing access. If Plex times out after retries, the task reports failure
and prints the page to resume. Previously saved pages remain available, and
re-reading them updates events without duplicating them. Resume from the failed
page shown in the output.

**Status** shows the app revision, database connection, snapshot age, refresh
state, history coverage, and activity collection health. Check it after setup or when
data looks stale. Its next scheduled time reflects the configured daily refresh
time; the scheduler service must also be running.

## Administrative access and data

With no Google credentials configured, GigaAdmin uses local admin accounts. The
first visitor creates the initial **super administrator**, so complete setup
privately before exposing the app. Only super administrators can invite or
remove other GigaAdmin administrators. Invited accounts can administer Plex
sharing and change their own password, but cannot manage GigaAdmin accounts.
Passwords are stored as bcrypt hashes, and password changes invalidate existing
sessions.

The first local account remains a super administrator. To designate additional
super administrators, set the comma-separated `ADMIN_USERS` list; matching local
accounts gain the role. First-run setup requires an email in that list when it
is configured. Removing an email removes the role granted by the list, but does
not remove the first account's permanent role. Current super administrators
cannot be deleted through the app.

When both Google OAuth credentials are configured, the default automatic mode
uses Google sign-in and the `ADMIN_USERS` allowlist instead. You can also select
local or Google authentication explicitly. See [Configuration](configuration.md)
for the authentication mode and migration steps. In Google mode, all accounts
allowed through `ADMIN_USERS` are super administrators. Google
access is managed through configuration; local account invitations are available
in local authentication mode.

**Inviting an administrator delegates control of your Plex library sharing.**
Every administrator can grant and remove Plex access through the configured
owner account, and can view users' playback history. There are no viewer-only
roles. Invite only people you trust with this authority.

The Google allowlist is checked on every authenticated request. After changing
environment configuration, recreate the affected containers to load it; removed
administrators lose access on their next request.

GigaAdmin stores sharing snapshots, playback events, aggregate activity samples,
admin notes, and an audit log in its own PostgreSQL database. Playback history
and retained legacy samples may include account details, watch history, device
names, and IP addresses. Protect the
database and its backups as administrative data. The app connects through Plex
APIs and does not mount or edit Plex's database or media files.
