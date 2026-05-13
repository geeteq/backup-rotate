#!/usr/bin/env bash
set -euo pipefail

# --- Load config.env from the script's directory (if present) --------------
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE="$SCRIPT_DIR/config.env"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Apply defaults for anything not provided by config.env or the environment.
MAX_BACKUP_AGE_DAYS="${MAX_BACKUP_AGE_DAYS:-5}"
WEEKLY_RETENTION_WEEKS="${WEEKLY_RETENTION_WEEKS:-4}"
MONTHLY_RETENTION_MONTHS="${MONTHLY_RETENTION_MONTHS:-12}"
YEARLY_RETENTION_YEARS="${YEARLY_RETENTION_YEARS:-5}"

WEEKLY_DIRNAME="${WEEKLY_DIRNAME:-weekly}"
MONTHLY_DIRNAME="${MONTHLY_DIRNAME:-monthly}"
YEARLY_DIRNAME="${YEARLY_DIRNAME:-yearly}"
LOGS_DIRNAME="${LOGS_DIRNAME:-logs}"
LOG_FILENAME="${LOG_FILENAME:-backups.log}"
ARCHIVE_DIRNAME="${ARCHIVE_DIRNAME:-archive}"

SLACK_ENABLED="${SLACK_ENABLED:-0}"
SLACK_TOKEN="${SLACK_TOKEN:-}"
SLACK_CHANNEL="${SLACK_CHANNEL:-}"
SLACK_HTTPS_PROXY="${SLACK_HTTPS_PROXY:-}"
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $0 -d <backup_dir>

Options:
  -d <backup_dir>   Base directory to rotate (required).
  -h, --help        Show this help.

Configuration is read from:
  $CONFIG_FILE
EOF
}

BACKUP_DIR=""
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

# Tee all subsequent stdout/stderr to a per-backup-dir log file.
LOGS_PATH="$BACKUP_DIR/$LOGS_DIRNAME"
LOG_FILE="$LOGS_PATH/$LOG_FILENAME"
mkdir -p "$LOGS_PATH"
exec > >(tee -a "$LOG_FILE") 2>&1

# Accumulator for lines that should also appear in the Slack message.
report_lines=()
report() {
    log "$@"
    report_lines+=("$*")
}

# Portable mtime + date helpers (BSD/macOS vs GNU/Linux).
if stat -f '%m' /dev/null >/dev/null 2>&1; then
    mtime_of()       { stat -f '%m' "$1"; }
    start_of_week()  { date -v-$(( $(date +%u) - 1 ))d -v0H -v0M -v0S +%s; }
    start_of_month() { date -v1d -v0H -v0M -v0S +%s; }
    start_of_year()  { date -v1m -v1d -v0H -v0M -v0S +%s; }
else
    mtime_of()       { stat -c '%Y' "$1"; }
    start_of_week()  { date -d "$(date +%Y-%m-%d) -$(( $(date +%u) - 1 )) days 00:00:00" +%s; }
    start_of_month() { date -d "$(date +%Y-%m-01) 00:00:00" +%s; }
    start_of_year()  { date -d "$(date +%Y-01-01) 00:00:00" +%s; }
fi

now=$(date +%s)
cutoff=$(( now - MAX_BACKUP_AGE_DAYS * 86400 ))

WEEKLY_PATH="$BACKUP_DIR/$WEEKLY_DIRNAME"
MONTHLY_PATH="$BACKUP_DIR/$MONTHLY_DIRNAME"
YEARLY_PATH="$BACKUP_DIR/$YEARLY_DIRNAME"
ARCHIVE_PATH="$BACKUP_DIR/$ARCHIVE_DIRNAME"

for d in "$WEEKLY_PATH" "$MONTHLY_PATH" "$YEARLY_PATH"; do
    if [[ ! -d "$d" ]]; then
        mkdir -p "$d"
        log "created tier directory: $d"
    fi
done
if [[ ! -d "$ARCHIVE_PATH" ]]; then
    mkdir -p "$ARCHIVE_PATH"
    log "created archive directory: $ARCHIVE_PATH"
fi

# Moves a path into the archive instead of deleting it. On name collision,
# appends a timestamp (and PID if still colliding) so prior archived
# entries are never overwritten.
archive_path() {
    local source="$1" label="$2"
    local base target
    base=$(basename "$source")
    target="$ARCHIVE_PATH/$base"
    if [[ -e "$target" ]]; then
        target="$ARCHIVE_PATH/${base}.archived-$(date +%Y%m%d%H%M%S)"
        if [[ -e "$target" ]]; then
            target="${target}-$$"
        fi
    fi
    if mv -- "$source" "$target"; then
        log "$label: archived $source -> $target"
        return 0
    else
        log "$label: ERROR failed to archive $source"
        return 1
    fi
}

# Counters / state
promoted_weekly=0
promoted_monthly=0
promoted_yearly=0
archived_daily=0
archived_weekly=0
archived_monthly=0
archived_yearly=0
failed=0
kept_safety=""
warning=0

# ----- Collect dailies (top-level entries excluding tier subdirs) ----------
dailies_sorted=$(
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 \
        ! -path "$WEEKLY_PATH" \
        ! -path "$MONTHLY_PATH" \
        ! -path "$YEARLY_PATH" \
        ! -path "$LOGS_PATH" \
        ! -path "$ARCHIVE_PATH" \
        ! -name 'config.env' \
        -print0 |
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

# ----- Promotion -----------------------------------------------------------
tier_has_current_backup() {
    # Returns 0 if $tier_dir contains any entry with mtime >= $period_start.
    local tier_dir="$1" period_start="$2" entry m
    while IFS= read -r -d '' entry; do
        m=$(mtime_of "$entry")
        if (( m >= period_start )); then
            return 0
        fi
    done < <(find "$tier_dir" -mindepth 1 -maxdepth 1 -print0)
    return 1
}

promote_to_tier() {
    # promote_to_tier <source> <tier_dir> <tier_label> <result_var>
    # Sets $result_var to 1 on success, 0 on no-op, -1 on failure.
    local source="$1" tier_dir="$2" tier_label="$3" result_var="$4"
    local base name target parent
    base=$(basename "$source")

    if [[ -d "$source" ]]; then
        name="${base}.tar.gz"
        target="$tier_dir/$name"
        if [[ -e "$target" ]]; then
            log "$tier_label: target exists, skipping promotion: $target"
            printf -v "$result_var" '%d' 0
            return 0
        fi
        parent=$(dirname "$source")
        if tar -C "$parent" -czf "$target" "$base" 2>/dev/null; then
            touch -r "$source" "$target" 2>/dev/null || true
            log "$tier_label: promoted (tar.gz) $source -> $target"
            printf -v "$result_var" '%d' 1
            return 0
        else
            rm -f -- "$target"
            log "$tier_label: ERROR failed to tar.gz $source"
            printf -v "$result_var" '%d' -1
            return 1
        fi
    else
        name="$base"
        target="$tier_dir/$name"
        if [[ -e "$target" ]]; then
            log "$tier_label: target exists, skipping promotion: $target"
            printf -v "$result_var" '%d' 0
            return 0
        fi
        if cp -a -- "$source" "$target"; then
            log "$tier_label: promoted (copy) $source -> $target"
            printf -v "$result_var" '%d' 1
            return 0
        else
            log "$tier_label: ERROR failed to copy $source"
            printf -v "$result_var" '%d' -1
            return 1
        fi
    fi
}

if (( ${#all_dailies_sorted[@]} > 0 )); then
    newest_daily="${all_dailies_sorted[0]}"

    sow=$(start_of_week)
    som=$(start_of_month)
    soy=$(start_of_year)

    for tier in weekly monthly yearly; do
        case "$tier" in
            weekly)  tier_path="$WEEKLY_PATH";  period_start="$sow"; counter_var=promoted_weekly  ;;
            monthly) tier_path="$MONTHLY_PATH"; period_start="$som"; counter_var=promoted_monthly ;;
            yearly)  tier_path="$YEARLY_PATH";  period_start="$soy"; counter_var=promoted_yearly  ;;
        esac
        if tier_has_current_backup "$tier_path" "$period_start"; then
            log "$tier: tier already has a backup for the current period, no promotion"
        else
            promote_to_tier "$newest_daily" "$tier_path" "$tier" "$counter_var" || \
                failed=$((failed + 1))
        fi
    done
else
    log "no dailies present, skipping promotion"
fi

# ----- Daily retention (age-based, with safety-keep) -----------------------
to_delete=()
if (( ${#recent_dailies[@]} == 0 )) && (( ${#old_dailies[@]} > 0 )); then
    kept_safety="${old_dailies[0]}"
    warning=1
    if (( ${#old_dailies[@]} > 1 )); then
        to_delete=("${old_dailies[@]:1}")
    fi
    warn "no dailies newer than ${MAX_BACKUP_AGE_DAYS} day(s) in '$BACKUP_DIR'."
    warn "preserving most recent daily to avoid removing the last valid one: $kept_safety"
elif (( ${#old_dailies[@]} > 0 )); then
    to_delete=("${old_dailies[@]}")
fi

if (( ${#to_delete[@]} > 0 )); then
    for path in "${to_delete[@]}"; do
        if archive_path "$path" "daily"; then
            archived_daily=$((archived_daily + 1))
        else
            failed=$((failed + 1))
        fi
    done
fi

# ----- Tier retention (count-based, keep N newest) -------------------------
prune_tier() {
    local tier_dir="$1" keep="$2" tier_label="$3" counter_var="$4"
    local sorted i=0 mtime path current
    sorted=$(
        find "$tier_dir" -mindepth 1 -maxdepth 1 -print0 |
        while IFS= read -r -d '' entry; do
            printf '%s\t%s\n' "$(mtime_of "$entry")" "$entry"
        done | sort -rn
    )
    [[ -z "$sorted" ]] && return 0
    while IFS=$'\t' read -r mtime path; do
        [[ -z "${path:-}" ]] && continue
        if (( i >= keep )); then
            if archive_path "$path" "$tier_label (retention)"; then
                current="${!counter_var}"
                printf -v "$counter_var" '%d' $((current + 1))
            else
                failed=$((failed + 1))
            fi
        fi
        i=$((i + 1))
    done <<< "$sorted"
}

prune_tier "$WEEKLY_PATH"  "$WEEKLY_RETENTION_WEEKS"    "weekly"  archived_weekly
prune_tier "$MONTHLY_PATH" "$MONTHLY_RETENTION_MONTHS"  "monthly" archived_monthly
prune_tier "$YEARLY_PATH"  "$YEARLY_RETENTION_YEARS"    "yearly"  archived_yearly

# ----- Summary -------------------------------------------------------------
report "----- summary -----"
report "directory:           $BACKUP_DIR"
report "max daily age:       $MAX_BACKUP_AGE_DAYS day(s)"
report "weekly retention:    $WEEKLY_RETENTION_WEEKS week(s)"
report "monthly retention:   $MONTHLY_RETENTION_MONTHS month(s)"
report "yearly retention:    $YEARLY_RETENTION_YEARS year(s)"
report "dailies:             total=${#all_dailies_sorted[@]} kept_recent=${#recent_dailies[@]} archived=$archived_daily"
report "promoted:            weekly=$promoted_weekly monthly=$promoted_monthly yearly=$promoted_yearly"
report "tier archived:       weekly=$archived_weekly monthly=$archived_monthly yearly=$archived_yearly"
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

# ----- Slack notification --------------------------------------------------
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
