#!/usr/bin/env bash
set -euo pipefail

# --- Load config.env from the script's directory (if present) --------------
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE="$SCRIPT_DIR/config.env"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Defaults applied for anything not set by config.env or the environment.
MAX_BACKUP_AGE_DAYS="${MAX_BACKUP_AGE_DAYS:-5}"
DAILY_DIRNAME="${DAILY_DIRNAME:-daily}"
WEEKLY_DIRNAME="${WEEKLY_DIRNAME:-weekly}"
ARCHIVE_DIRNAME="${ARCHIVE_DIRNAME:-archive}"
LOGS_DIRNAME="${LOGS_DIRNAME:-logs}"
LOG_FILENAME="${LOG_FILENAME:-backups.log}"

SLACK_ENABLED="${SLACK_ENABLED:-0}"
SLACK_TOKEN="${SLACK_TOKEN:-}"
SLACK_CHANNEL="${SLACK_CHANNEL:-}"
SLACK_HTTPS_PROXY="${SLACK_HTTPS_PROXY:-}"
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $0 -d <backup_dir> [-n|--dry-run]

Options:
  -d <backup_dir>   Base directory to manage (required).
  -n, --dry-run     Show what would be done without changing anything
                    (no mkdir, no ingest, no archiving, no Slack POST,
                    no log file write).
  -h, --help        Show this help.

Configuration is read from:
  $CONFIG_FILE
EOF
}

BACKUP_DIR=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then
                echo "ERROR: -d requires a directory argument" >&2
                usage >&2
                exit 2
            fi
            BACKUP_DIR="$2"
            shift 2
            ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "$BACKUP_DIR" ]]; then
    echo "ERROR: -d <backup_dir> is required" >&2
    usage >&2
    exit 2
fi

BACKUP_DIR="${BACKUP_DIR%/}"
[[ -z "$BACKUP_DIR" ]] && BACKUP_DIR="/"

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warning_lines=()
warn() {
    echo "WARNING: $*" >&2
    warning_lines+=("$*")
}

if (( SLACK_ENABLED )); then
    if [[ -z "$SLACK_TOKEN" || -z "$SLACK_CHANNEL" ]]; then
        echo "ERROR: SLACK_ENABLED=1 requires SLACK_TOKEN and SLACK_CHANNEL (set in $CONFIG_FILE or the environment)" >&2
        exit 2
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "ERROR: SLACK_ENABLED=1 requires 'curl' to be installed" >&2
        exit 2
    fi
fi

if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "ERROR: backup directory '$BACKUP_DIR' does not exist or is not a directory" >&2
    exit 1
fi

DAILY_PATH="$BACKUP_DIR/$DAILY_DIRNAME"
WEEKLY_PATH="$BACKUP_DIR/$WEEKLY_DIRNAME"
ARCHIVE_PATH="$BACKUP_DIR/$ARCHIVE_DIRNAME"
LOGS_PATH="$BACKUP_DIR/$LOGS_DIRNAME"
LOG_FILE="$LOGS_PATH/$LOG_FILENAME"

if (( DRY_RUN )); then
    log "DRY-RUN: no changes will be made; would log to $LOG_FILE"
else
    mkdir -p "$LOGS_PATH"
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

for d in "$DAILY_PATH" "$WEEKLY_PATH" "$ARCHIVE_PATH"; do
    if [[ ! -d "$d" ]]; then
        if (( DRY_RUN )); then
            log "[dry-run] would create directory: $d"
        else
            mkdir -p "$d"
            log "created directory: $d"
        fi
    fi
done

report_lines=()
report() {
    log "$@"
    report_lines+=("$*")
}

# Portable mtime + ISO-week start (BSD/macOS vs GNU/Linux).
if stat -f '%m' /dev/null >/dev/null 2>&1; then
    mtime_of()      { stat -f '%m' "$1"; }
    start_of_week() { date -v-$(( $(date +%u) - 1 ))d -v0H -v0M -v0S +%s; }
else
    mtime_of()      { stat -c '%Y' "$1"; }
    start_of_week() { date -d "$(date +%Y-%m-%d) -$(( $(date +%u) - 1 )) days 00:00:00" +%s; }
fi

now=$(date +%s)
cutoff=$(( now - MAX_BACKUP_AGE_DAYS * 86400 ))
sow=$(start_of_week)

# Counters / state
ingested=0
archived_daily=0
promoted_weekly=0
failed=0
kept_safety=""
warning=0

# ===== Step 1: Ingest top-level entries into DAILY_PATH ====================
ingest_one() {
    local src="$1"
    local base target parent
    base=$(basename "$src")

    if [[ -d "$src" ]]; then
        target="$DAILY_PATH/${base}.tar.gz"
        if [[ -e "$target" ]]; then
            warn "ingest: target exists, skipping: $target"
            return 0
        fi
        if (( DRY_RUN )); then
            log "[dry-run] ingest: would tar+gz $src -> $target"
            ingested=$((ingested + 1))
            return 0
        fi
        parent=$(dirname "$src")
        if tar -C "$parent" -czf "$target" "$base" 2>/dev/null; then
            touch -r "$src" "$target" 2>/dev/null || true
            rm -rf -- "$src"
            log "ingest: tar+gz $src -> $target"
            ingested=$((ingested + 1))
            return 0
        else
            rm -f -- "$target"
            log "ingest: ERROR failed to tar.gz $src"
            failed=$((failed + 1))
            return 1
        fi
    else
        target="$DAILY_PATH/$base"
        if [[ -e "$target" ]]; then
            warn "ingest: target exists, skipping: $target"
            return 0
        fi
        if (( DRY_RUN )); then
            log "[dry-run] ingest: would move $src -> $target"
            ingested=$((ingested + 1))
            return 0
        fi
        if mv -- "$src" "$target"; then
            log "ingest: moved $src -> $target"
            ingested=$((ingested + 1))
            return 0
        else
            log "ingest: ERROR failed to move $src"
            failed=$((failed + 1))
            return 1
        fi
    fi
}

while IFS= read -r -d '' entry; do
    ingest_one "$entry" || true
done < <(
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 \
        ! -path "$DAILY_PATH" \
        ! -path "$WEEKLY_PATH" \
        ! -path "$ARCHIVE_PATH" \
        ! -path "$LOGS_PATH" \
        ! -name 'config.env' \
        -print0
)

# ===== Step 2: Collect dailies, split by age ==============================
dailies_sorted=$(
    [[ -d "$DAILY_PATH" ]] && find "$DAILY_PATH" -mindepth 1 -maxdepth 1 -print0 |
    while IFS= read -r -d '' entry; do
        printf '%s\t%s\n' "$(mtime_of "$entry")" "$entry"
    done | sort -rn
)

recent_dailies=()
old_dailies=()
all_dailies_sorted=()

if [[ -n "$dailies_sorted" ]]; then
    while IFS=$'\t' read -r mtime path; do
        [[ -z "${path:-}" ]] && continue
        all_dailies_sorted+=("$path")
        if (( mtime >= cutoff )); then
            recent_dailies+=("$path")
        else
            old_dailies+=("$path")
        fi
    done <<< "$dailies_sorted"
fi

# ===== Step 3: Decide which dailies to archive (with safety-keep) =========
to_archive=()
if (( ${#recent_dailies[@]} == 0 )) && (( ${#old_dailies[@]} > 0 )); then
    kept_safety="${old_dailies[0]}"
    warning=1
    if (( ${#old_dailies[@]} > 1 )); then
        to_archive=("${old_dailies[@]:1}")
    fi
    warn "no dailies newer than ${MAX_BACKUP_AGE_DAYS} day(s) in '$DAILY_PATH'."
    warn "preserving most recent daily to avoid removing the last valid one: $kept_safety"
elif (( ${#old_dailies[@]} > 0 )); then
    to_archive=("${old_dailies[@]}")
fi

# ===== Step 4: Weekly promotion (before archive so the source still exists) =
# The newest of the entries we're about to archive is copied into WEEKLY_PATH,
# but only if no weekly snapshot already covers the current ISO week.
if (( ${#to_archive[@]} > 0 )); then
    newest_pruned="${to_archive[0]}"   # to_archive is newest-first

    weekly_has_current=0
    if [[ -d "$WEEKLY_PATH" ]]; then
        while IFS= read -r -d '' entry; do
            m=$(mtime_of "$entry")
            if (( m >= sow )); then
                weekly_has_current=1
                break
            fi
        done < <(find "$WEEKLY_PATH" -mindepth 1 -maxdepth 1 -print0)
    fi

    if (( weekly_has_current )); then
        log "weekly: snapshot for current ISO week already exists, skipping"
    else
        base=$(basename "$newest_pruned")
        weekly_target="$WEEKLY_PATH/$base"
        if [[ -e "$weekly_target" ]]; then
            log "weekly: target exists, skipping promotion: $weekly_target"
        elif (( DRY_RUN )); then
            log "[dry-run] weekly: would copy $newest_pruned -> $weekly_target"
            promoted_weekly=1
        elif cp -a -- "$newest_pruned" "$weekly_target"; then
            touch -r "$newest_pruned" "$weekly_target" 2>/dev/null || true
            log "weekly: promoted $newest_pruned -> $weekly_target"
            promoted_weekly=1
        else
            log "weekly: ERROR failed to copy $newest_pruned"
            failed=$((failed + 1))
        fi
    fi
fi

# ===== Step 5: Archive the old dailies ====================================
archive_path() {
    local source="$1"
    local base target
    base=$(basename "$source")
    target="$ARCHIVE_PATH/$base"
    if [[ -e "$target" ]]; then
        target="$ARCHIVE_PATH/${base}.archived-$(date +%Y%m%d%H%M%S)"
        if [[ -e "$target" ]]; then
            target="${target}-$$"
        fi
    fi
    if (( DRY_RUN )); then
        log "[dry-run] daily: would archive $source -> $target"
        return 0
    fi
    if mv -- "$source" "$target"; then
        log "daily: archived $source -> $target"
        return 0
    else
        log "daily: ERROR failed to archive $source"
        return 1
    fi
}

for path in "${to_archive[@]}"; do
    if archive_path "$path"; then
        archived_daily=$((archived_daily + 1))
    else
        failed=$((failed + 1))
    fi
done

# ===== Step 6: Summary ====================================================
report "----- summary -----"
report "directory:           $BACKUP_DIR"
report "max daily age:       $MAX_BACKUP_AGE_DAYS day(s)"
report "ingested:            $ingested"
report "dailies:             total=${#all_dailies_sorted[@]} kept_recent=${#recent_dailies[@]} archived=$archived_daily"
report "promoted to weekly:  $promoted_weekly"
report "archive dir:         $ARCHIVE_PATH"
if [[ -n "$kept_safety" ]]; then
    report "kept (safety):       $kept_safety"
fi
if (( failed > 0 )); then
    report "failed operations:   $failed"
fi
if (( warning )); then
    report "status:              WARNING - last valid daily preserved; no recent dailies"
else
    report "status:              ok"
fi
if (( DRY_RUN )); then
    report "mode:                DRY-RUN (no changes were made)"
fi

# ===== Step 7: Slack notification =========================================
json_escape() {
    # Minimal JSON string escaper. Wraps the result in quotes.
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    printf '"%s"' "$s"
}

if (( SLACK_ENABLED )); then
    if (( warning )) || (( failed > 0 )); then
        header=":warning: Backup rotation"
    else
        header=":white_check_mark: Backup rotation"
    fi

    msg="*${header}* on \`$(hostname)\`"$'\n'"\`\`\`"
    for line in "${report_lines[@]}"; do
        msg+=$'\n'"$line"
    done
    msg+=$'\n'"\`\`\`"
    if (( ${#warning_lines[@]} > 0 )); then
        for w in "${warning_lines[@]}"; do
            msg+=$'\n'":warning: $w"
        done
    fi

    payload="{\"channel\":$(json_escape "$SLACK_CHANNEL"),\"text\":$(json_escape "$msg"),\"mrkdwn\":true}"

    if (( DRY_RUN )); then
        log "[dry-run] slack: would post notification to $SLACK_CHANNEL"
    else
        curl_args=(-sS --max-time 15 -X POST
            -H "Authorization: Bearer $SLACK_TOKEN"
            -H "Content-Type: application/json; charset=utf-8"
            --data "$payload")
        if [[ -n "$SLACK_HTTPS_PROXY" ]]; then
            curl_args+=(--proxy "$SLACK_HTTPS_PROXY")
        fi

        set +e
        response=$(curl "${curl_args[@]}" https://slack.com/api/chat.postMessage 2>&1)
        curl_status=$?
        set -e

        if (( curl_status != 0 )); then
            log "slack: ERROR curl failed (exit $curl_status): $response"
        elif [[ "$response" == *'"ok":true'* ]]; then
            log "slack: notification posted to $SLACK_CHANNEL"
        else
            log "slack: ERROR API rejected message: $response"
        fi
    fi
fi
