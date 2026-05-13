# backup-rotate

A single Bash script that applies a grandfather-father-son (GFS) retention
policy to a directory of daily backups, with optional Slack notifications.

It assumes the target directory contains **daily backups** (files or
directories) and manages three sibling subdirectories — `weekly/`,
`monthly/`, `yearly/` — promoting and pruning them according to per-tier
retention counts.

## What it does, in order

1. **Creates the tier subdirectories** (`weekly/`, `monthly/`, `yearly/`)
   inside the backup directory if they do not already exist.
2. **Promotes the newest daily** into each tier whose current period
   (ISO week / calendar month / calendar year) does not yet have a backup.
   - A daily that is a directory is archived to `<name>.tar.gz` in the
     tier subdir; its mtime is preserved with `touch -r`.
   - A daily that is already a file is copied as-is with `cp -a`.
3. **Deletes dailies older than `MAX_BACKUP_AGE_DAYS`** in the top of the
   backup directory. The tier subdirs are excluded from this scan.
4. **Safety-keep**: if *every* daily is older than the cutoff, the most
   recent one is preserved and a `WARNING` is printed to stderr (and
   included in the Slack message). This prevents the script from leaving
   the directory empty if no new backups arrived for a while.
5. **Prunes each tier subdir** to its retention count, keeping the
   N newest by mtime.
6. **Prints a summary** (one block at the end) and optionally posts it
   to Slack.

## Requirements

- Bash 3.2+ (works on stock macOS bash and on Linux)
- Standard Unix utilities: `find`, `sort`, `stat`, `tar`, `date`, `rm`, `cp`
- `curl` — only required when `--slack` is used

Portable on both BSD/macOS and GNU/Linux `stat`/`date`.

## Configuration

Edit the variables at the top of `rotate-backups.sh`:

| Variable                   | Default | Meaning                                              |
| -------------------------- | ------- | ---------------------------------------------------- |
| `MAX_BACKUP_AGE_DAYS`      | `5`     | Dailies older than this are deleted (with safety-keep). |
| `WEEKLY_RETENTION_WEEKS`   | `4`     | Number of weekly backups to keep.                    |
| `MONTHLY_RETENTION_MONTHS` | `12`    | Number of monthly backups to keep.                   |
| `YEARLY_RETENTION_YEARS`   | `5`     | Number of yearly backups to keep.                    |
| `WEEKLY_DIRNAME`           | `weekly`  | Subdirectory name for weekly tier.                 |
| `MONTHLY_DIRNAME`          | `monthly` | Subdirectory name for monthly tier.                |
| `YEARLY_DIRNAME`           | `yearly`  | Subdirectory name for yearly tier.                 |

Slack (env vars, used only with `--slack`):

| Variable        | Meaning                                          |
| --------------- | ------------------------------------------------ |
| `SLACK_TOKEN`   | Slack bot/user token (`xoxb-...`).               |
| `SLACK_CHANNEL` | Target channel ID or name (e.g. `C0123…` or `#backups`). |

The Slack bot needs `chat:write` scope and must be a member of the channel.

## Usage

```
./rotate-backups.sh [--slack] [BACKUP_DIR]
```

If `BACKUP_DIR` is omitted, the script uses `$BACKUP_DIR` from the
environment, or falls back to the current working directory.

### Examples

```sh
# Operate on the current directory
./rotate-backups.sh

# Explicit directory
./rotate-backups.sh /var/backups/myapp

# With Slack notifications
SLACK_TOKEN=xoxb-... SLACK_CHANNEL=#backups \
    ./rotate-backups.sh --slack /var/backups/myapp
```

### Cron example

Run every day at 03:30, posting a summary to Slack:

```cron
30 3 * * *  SLACK_TOKEN=xoxb-... SLACK_CHANNEL=#backups /usr/local/bin/rotate-backups.sh --slack /var/backups/myapp >> /var/log/backup-rotate.log 2>&1
```

## How promotion decides "current period"

For each tier the script computes the start of the current period as an
epoch and checks whether any entry in the tier subdir has an mtime at or
after that boundary:

- **weekly** — start of the current ISO week (Monday 00:00 local time)
- **monthly** — first of the current month at 00:00 local time
- **yearly** — January 1st of the current year at 00:00 local time

If the tier already contains a backup for the current period, promotion
is skipped for that tier. This makes the script safe to run multiple
times per day.

## Output

Every operation produces one timestamped log line on stdout:

```
[2026-05-12 21:00:45] weekly: promoted (tar.gz) /var/backups/myapp/backup-2026-05-12 -> /var/backups/myapp/weekly/backup-2026-05-12.tar.gz
[2026-05-12 21:00:45] daily: deleted /var/backups/myapp/backup-2026-05-03
```

The run ends with a summary block:

```
[…] ----- summary -----
[…] directory:           /var/backups/myapp
[…] max daily age:       5 day(s)
[…] weekly retention:    4 week(s)
[…] monthly retention:   12 month(s)
[…] yearly retention:    5 year(s)
[…] dailies:             total=4 kept_recent=2 deleted=2
[…] promoted:            weekly=1 monthly=1 yearly=1
[…] tier deletions:      weekly=0 monthly=0 yearly=0
[…] status:              ok
```

Warnings (such as the safety-keep) are printed to stderr with a
`WARNING:` prefix and included in the Slack notification when enabled.

## Slack message

When `--slack` is set, the script posts a single message at the end of
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

| Code | Meaning                                                          |
| ---- | ---------------------------------------------------------------- |
| 0    | Run completed (a warning was possibly logged).                   |
| 1    | `BACKUP_DIR` does not exist or is not a directory.               |
| 2    | Invalid CLI flag, or `--slack` used without `SLACK_TOKEN`/`SLACK_CHANNEL`, or `curl` not installed when `--slack` is used. |

## Notes & caveats

- Daily backups are identified by being top-level entries of the backup
  directory that are not one of the three tier subdirectories. Anything
  you drop directly in `BACKUP_DIR` is treated as a daily.
- Filenames containing newline characters are not supported (the script
  uses newline-delimited sorted output internally). Tabs are fine.
- Tier pruning is mtime-based, not name-based. If you backdate a tier
  file, retention order will follow the new mtime.
- The promoted tar.gz is created with `tar -C <parent> -czf … <basename>`,
  so the archive contains the daily's basename at its top level.
