# backup-rotate

A single Bash script that manages a directory of backups: it picks up
anything dropped at the top of the directory, files them away as dailies,
ages them out into an archive, and once per ISO week keeps a copy of the
last daily-to-be-archived in `weekly/` so a snapshot of the previous week
survives.

Nothing is ever erased — pruned dailies go to `archive/`, which the script
never touches.

## What it does, in order

Each run, against the directory passed via `-d`:

1. **Creates** `daily/`, `weekly/`, `archive/`, and `logs/` inside the
   backup directory if they don't already exist.
2. **Ingests** every top-level entry that isn't one of those four
   bookkeeping directories or a top-level `config.env` file:
   - A regular file is moved into `daily/` as-is.
   - A directory is wrapped with `tar -czf` into `daily/<name>.tar.gz`
     and then removed from the top level.
   - Mtime is preserved with `touch -r`.
3. **Splits the contents of `daily/`** by age. Anything older than
   `MAX_BACKUP_AGE_DAYS` is marked for archiving.
4. **Safety-keep**: if *every* daily is older than the cutoff, the most
   recent old daily is preserved and a `WARNING` is printed (and included
   in the Slack notification). This prevents the script from leaving
   `daily/` empty if no new backups arrived for a while.
5. **Promotes** to `weekly/`: the newest of the soon-to-be-archived
   dailies is copied into `weekly/`, but only if no entry in `weekly/`
   already covers the current ISO week. The script makes the copy
   *before* the archive move, so the source still exists.
6. **Archives** the aged-out dailies by moving them into `archive/`.
   On name collisions, the new entry is renamed with a
   `.archived-<timestamp>` suffix so prior archived entries are never
   overwritten.
7. **Prints a summary** and, when enabled, posts it to Slack.

Every line is teed to `<backup_dir>/logs/backups.log` in addition to
stdout. With `-n`/`--dry-run`, no log file is written and no filesystem
or network changes happen.

## Layout

```
<backup_dir>/
├── <incoming files / dirs at top level>   (ingested on next run)
├── daily/        <- managed by the script
├── weekly/       <- one snapshot per ISO week
├── archive/      <- everything pruned (never auto-cleaned)
├── logs/
│   └── backups.log
└── config.env    (optional override, if you choose to place one here)
```

## Requirements

- Bash 3.2+ (works on stock macOS bash and on Linux)
- Standard Unix utilities: `find`, `sort`, `stat`, `tar`, `date`, `mv`, `cp`, `tee`
- `curl` — only required when Slack notifications are enabled

Portable on both BSD/macOS and GNU/Linux `stat`/`date`.

## Configuration

All tunables live in `config.env` next to the script. It is sourced
automatically at startup; anything not set there falls back to a built-in
default. The shipped `config.env` documents every option.

| Variable                   | Default       | Meaning                                                 |
| -------------------------- | ------------- | ------------------------------------------------------- |
| `MAX_BACKUP_AGE_DAYS`      | `5`           | Dailies older than this are moved to `archive/`.        |
| `DAILY_DIRNAME`            | `daily`       | Subdirectory for dailies (ingest target).               |
| `WEEKLY_DIRNAME`           | `weekly`      | Subdirectory for the once-per-ISO-week snapshot.        |
| `ARCHIVE_DIRNAME`          | `archive`     | Subdirectory where pruned entries go (never auto-cleaned).|
| `LOGS_DIRNAME`             | `logs`        | Subdirectory for the log file.                          |
| `LOG_FILENAME`             | `backups.log` | Log file written inside `LOGS_DIRNAME`.                 |
| `SLACK_ENABLED`            | `0`           | Set to `1` to post a run summary to Slack.              |
| `SLACK_TOKEN`              | (empty)       | Slack bot/user token (`xoxb-...`).                      |
| `SLACK_CHANNEL`            | (empty)       | Target channel ID or name (e.g. `C0123…` or `#backups`).|
| `SLACK_HTTPS_PROXY`        | (empty)       | Optional HTTPS proxy for the Slack call (e.g. `http://proxy.internal:3128`). |

The Slack bot needs `chat:write` scope and must be a member of the channel.
Set `SLACK_HTTPS_PROXY` if outbound HTTPS to `slack.com` must traverse a
proxy — it is passed to `curl --proxy` for the Slack call only and does
not affect any other network activity. `config.env` is authoritative —
values set there override the same names inherited from the environment.

## Usage

```
./rotate-backups.sh -d <backup_dir> [-n|--dry-run]
```

`-d <backup_dir>` is required. `-n`/`--dry-run` previews the plan without
changing anything on disk and without posting to Slack — every line that
would mutate state is logged with a `[dry-run]` prefix, and no log file
is written either.

### Examples

```sh
# Rotate /var/backups/myapp
./rotate-backups.sh -d /var/backups/myapp

# Preview what a run would do, no changes
./rotate-backups.sh -d /var/backups/myapp --dry-run
```

### Cron example

Run every day at 03:30:

```cron
30 3 * * *  /usr/local/bin/rotate-backups.sh -d /var/backups/myapp
```

No shell redirection is needed for logging — the script already writes
`/var/backups/myapp/logs/backups.log`.

## Output

Every operation produces one timestamped log line on stdout *and* in
`<backup_dir>/logs/backups.log`:

```
[2026-05-12 21:00:45] ingest: moved /var/backups/myapp/backup-2026-05-12.dump -> /var/backups/myapp/daily/backup-2026-05-12.dump
[2026-05-12 21:00:45] weekly: promoted /var/backups/myapp/daily/backup-2026-05-06.dump -> /var/backups/myapp/weekly/backup-2026-05-06.dump
[2026-05-12 21:00:45] daily: archived /var/backups/myapp/daily/backup-2026-05-06.dump -> /var/backups/myapp/archive/backup-2026-05-06.dump
```

The run ends with a summary block:

```
[…] ----- summary -----
[…] directory:           /var/backups/myapp
[…] max daily age:       5 day(s)
[…] ingested:            1
[…] dailies:             total=4 kept_recent=3 archived=1
[…] promoted to weekly:  1
[…] archive dir:         /var/backups/myapp/archive
[…] status:              ok
```

Warnings (such as the safety-keep) are printed to stderr with a
`WARNING:` prefix, written to `backups.log`, and included in the Slack
notification when enabled.

## Slack message

When `SLACK_ENABLED=1`, the script posts a single message at the end of
the run using `chat.postMessage`. Format:

```
*:white_check_mark: Backup rotation* on `host.example.com`
```
...summary block...
```

If the run produced any warnings or failed operations, the header uses
`:warning:` and the warning lines are appended below the summary block.

A Slack API failure is logged but does not cause the script to exit
non-zero — the local rotation has already been performed.

## Exit codes

| Code | Meaning                                                                                    |
| ---- | ------------------------------------------------------------------------------------------ |
| 0    | Run completed (a warning was possibly logged; also returned for a successful `--dry-run`). |
| 1    | `<backup_dir>` does not exist or is not a directory.                                       |
| 2    | Missing/invalid CLI argument, or `SLACK_ENABLED=1` without `SLACK_TOKEN`/`SLACK_CHANNEL`, or `curl` not installed when Slack is enabled. |

## Notes & caveats

- Ingest only fires on entries at the *top* of the backup directory.
  Anything already inside `daily/`, `weekly/`, `archive/`, `logs/`, or a
  top-level file literally named `config.env` is left alone.
- If an ingest target already exists (same basename in `daily/`), the
  ingest is skipped with a warning rather than overwriting.
- `weekly/` only grows when there is something to archive in the same
  run *and* no entry in `weekly/` already covers the current ISO week.
  A quiet week (no archiving) produces no new weekly snapshot.
- `archive/` and `weekly/` grow without bound. Prune them manually when
  you're sure the entries inside are no longer needed; the script will
  never touch either.
- `backups.log` grows without bound. Rotate it externally (e.g. with
  `logrotate`) if you need bounded log size.
- Filenames containing newline characters are not supported (the script
  uses newline-delimited sorted output internally). Tabs are fine.
- Daily aging is mtime-based. If you backdate a file in `daily/`, it
  will be archived sooner.
