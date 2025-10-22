#!/bin/bash
# Common functions for backup scripts

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    if [ "${BACKUP_DEBUG:-false}" = "true" ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1" >&2
    fi
}

# Send webhook notification
send_webhook() {
    local webhook_url="$1"
    local message="${2:-}"

    if [ -z "$webhook_url" ]; then
        return 0
    fi

    if [ -n "$message" ]; then
        curl -fsS -m 10 --retry 3 -d "$message" "$webhook_url" || true
    else
        curl -fsS -m 10 --retry 3 "$webhook_url" || true
    fi
}

# Send success notification
send_success() {
    local message="${1:-Backup completed successfully}"
    log_info "$message"

    if [ -n "${BACKUP_SUCCESS_WEBHOOK:-}" ]; then
        send_webhook "$BACKUP_SUCCESS_WEBHOOK" "$message"
    fi
}

# Send failure notification and exit
send_failure() {
    local message="${1:-Backup failed}"
    log_error "$message"

    if [ -n "${BACKUP_FAILURE_WEBHOOK:-}" ]; then
        send_webhook "$BACKUP_FAILURE_WEBHOOK" "$message"
    fi

    exit 1
}

# Determine which backup destinations are configured
# Returns: "local", "s3", or "both"
get_backup_destination() {
    local has_local=false
    local has_s3=false

    # Check if local backup is configured
    if [ -n "${BACKUP_LOCAL_PATH:-}" ]; then
        has_local=true
    fi

    # Check if S3 is configured
    if [ -n "${BACKUP_S3_BUCKET:-}" ]; then
        has_s3=true
    fi

    if [ "$has_local" = true ] && [ "$has_s3" = true ]; then
        echo "both"
    elif [ "$has_local" = true ]; then
        echo "local"
    elif [ "$has_s3" = true ]; then
        echo "s3"
    else
        echo "none"
    fi
}

# Validate backup destination configuration
validate_backup_config() {
    local destination
    destination=$(get_backup_destination)

    if [ "$destination" = "none" ]; then
        send_failure "No backup destination configured. Set BACKUP_LOCAL_PATH or BACKUP_S3_BUCKET"
    fi

    log_debug "Backup destination: $destination"
}

# Configure AWS CLI for S3
configure_s3() {
    if [ -z "${BACKUP_S3_ACCESS_KEY:-}" ] || [ -z "${BACKUP_S3_SECRET_KEY:-}" ]; then
        log_warn "S3 credentials not set, S3 operations will fail"
        return 1
    fi

    export AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY}"
    export AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_KEY}"
    export AWS_DEFAULT_REGION="${BACKUP_S3_REGION:-us-east-1}"

    # Set custom endpoint if not AWS
    if [ "${BACKUP_S3_ENDPOINT:-https://s3.amazonaws.com}" != "https://s3.amazonaws.com" ]; then
        export AWS_ENDPOINT_URL="${BACKUP_S3_ENDPOINT}"
    fi

    log_debug "S3 configured: bucket=${BACKUP_S3_BUCKET}, region=${AWS_DEFAULT_REGION}"
}

# Encrypt file with GPG
encrypt_file() {
    local input_file="$1"
    local output_file="${input_file}.gpg"

    if [ -z "${BACKUP_ENCRYPTION_KEY:-}" ]; then
        log_warn "BACKUP_ENCRYPTION_KEY not set, skipping encryption"
        echo "$input_file"
        return 0
    fi

    log_info "Encrypting backup..."

    # Check if gpg is available
    if ! command -v gpg >/dev/null 2>&1; then
        send_failure "GPG not available for encryption"
        # shellcheck disable=SC2317  # Unreachable due to send_failure exit
        return 1
    fi

    # Run GPG command
    if gpg --symmetric \
        --batch \
        --yes \
        --cipher-algo AES256 \
        --passphrase "$BACKUP_ENCRYPTION_KEY" \
        --output "$output_file" \
        "$input_file" 2>/dev/null; then

        if [ ! -f "$output_file" ]; then
            send_failure "Encryption failed - output file not created"
            # shellcheck disable=SC2317  # Unreachable due to send_failure exit
            return 1
        fi

        # Remove unencrypted file
        rm -f "$input_file"
        echo "$output_file"
        return 0
    else
        send_failure "Encryption failed"
        # shellcheck disable=SC2317  # Unreachable due to send_failure exit
        return 1
    fi
}

# Decrypt file with GPG
decrypt_file() {
    local input_file="$1"
    local output_file="${input_file%.gpg}"

    if [ -z "${BACKUP_ENCRYPTION_KEY:-}" ]; then
        send_failure "BACKUP_ENCRYPTION_KEY not set, cannot decrypt"
    fi

    log_info "Decrypting backup..."
    gpg --decrypt \
        --batch \
        --yes \
        --passphrase "$BACKUP_ENCRYPTION_KEY" \
        --output "$output_file" \
        "$input_file" || send_failure "Decryption failed"

    echo "$output_file"
}

# Save file to local backup directory
save_to_local() {
    local file_path="$1"
    local backup_key="$2"
    local dest_path="${BACKUP_LOCAL_PATH}/${backup_key}"

    log_info "Saving to local: $dest_path"

    # Create parent directory if it doesn't exist
    mkdir -p "$(dirname "$dest_path")"

    # Copy the file
    cp "$file_path" "$dest_path" || send_failure "Local save failed"

    log_info "Local save completed successfully"
}

# Load file from local backup directory
load_from_local() {
    local backup_key="$1"
    local local_path="$2"
    local source_path="${BACKUP_LOCAL_PATH}/${backup_key}"

    if [ ! -f "$source_path" ]; then
        send_failure "Backup not found: $source_path"
    fi

    log_info "Loading from local: $source_path"

    # Copy the file
    cp "$source_path" "$local_path" || send_failure "Local load failed"

    log_info "Local load completed successfully"
}

# Upload file to S3
upload_to_s3() {
    local file_path="$1"
    local s3_key="$2"
    local s3_path="s3://${BACKUP_S3_BUCKET}/${s3_key}"

    log_info "Uploading to S3: $s3_path"

    if ! configure_s3; then
        log_error "S3 upload skipped - configuration failed"
        return 1
    fi

    aws s3 cp "$file_path" "$s3_path" || {
        log_error "S3 upload failed"
        return 1
    }

    log_info "S3 upload completed successfully"
}

# Download file from S3
download_from_s3() {
    local s3_key="$1"
    local local_path="$2"
    local s3_path="s3://${BACKUP_S3_BUCKET}/${s3_key}"

    log_info "Downloading from S3: $s3_path"

    if ! configure_s3; then
        send_failure "S3 download failed - configuration error"
    fi

    aws s3 cp "$s3_path" "$local_path" || send_failure "S3 download failed"

    log_info "S3 download completed successfully"
}

save_backup() {
    local file_path="$1"
    local backup_key="$2"
    local destination
    destination=$(get_backup_destination)

    local saved_somewhere=false

    case "$destination" in
        "local")
            save_to_local "$file_path" "$backup_key"
            saved_somewhere=true
            ;;
        "s3")
            if upload_to_s3 "$file_path" "$backup_key"; then
                saved_somewhere=true
            fi
            ;;
        "both")
            save_to_local "$file_path" "$backup_key"
            saved_somewhere=true

            if ! upload_to_s3 "$file_path" "$backup_key"; then
                log_warn "S3 upload failed, but local backup succeeded"
            fi
            ;;
        *)
            send_failure "Invalid backup destination: $destination"
            ;;
    esac

    if [ "$saved_somewhere" = false ]; then
        send_failure "Backup save failed to all destinations"
    fi
}
load_backup() {
    local backup_key="$1"
    local local_path="$2"
    local destination
    destination=$(get_backup_destination)

    case "$destination" in
        "local")
            load_from_local "$backup_key" "$local_path"
            ;;
        "s3")
            download_from_s3 "$backup_key" "$local_path"
            ;;
        "both")
            # Try local first, then S3
            if [ -f "${BACKUP_LOCAL_PATH}/${backup_key}" ]; then
                load_from_local "$backup_key" "$local_path"
            else
                log_info "Backup not found locally, trying S3..."
                download_from_s3 "$backup_key" "$local_path"
            fi
            ;;
        *)
            send_failure "Invalid backup destination: $destination"
            ;;
    esac
}

# Parse timestamp from backup filename
# Expected format: backupname-YYYY-MM-DD-HHMMSS.tar.gz[.gpg]
parse_backup_timestamp() {
    local filename="$1"
    # Extract timestamp: YYYY-MM-DD-HHMMSS
    echo "$filename" | sed -n 's/.*-\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{6\}\)\.tar\.gz.*/\1/p'
}

# Convert timestamp to Unix epoch (seconds since 1970-01-01)
timestamp_to_epoch() {
    local timestamp="$1"
    # Format: YYYY-MM-DD-HHMMSS -> YYYY-MM-DD HH:MM:SS
    local date_part="${timestamp:0:10}"
    local time_part="${timestamp:11:2}:${timestamp:13:2}:${timestamp:15:2}"

    # Use date command (works with BusyBox, GNU, and BSD date)
    date -d "$date_part $time_part" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$date_part $time_part" +%s 2>/dev/null || echo "0"
}

# Get start of day/week/month/year for a given timestamp
get_period_start() {
    local epoch="$1"
    local period="$2" # day, week, month, year

    case "$period" in
        "day")
            date -d "@$epoch" +%Y-%m-%d 2>/dev/null || date -r "$epoch" +%Y-%m-%d 2>/dev/null
            ;;
        "week")
            # Get Monday of the week (ISO week)
            local dow
            dow=$(date -d "@$epoch" +%u 2>/dev/null || date -r "$epoch" +%u 2>/dev/null)
            local offset=$((dow - 1))
            local week_start=$((epoch - (offset * 86400)))
            date -d "@$week_start" +%Y-W%V 2>/dev/null || date -r "$week_start" +%Y-W%V 2>/dev/null
            ;;
        "month")
            date -d "@$epoch" +%Y-%m 2>/dev/null || date -r "$epoch" +%Y-%m 2>/dev/null
            ;;
        "year")
            date -d "@$epoch" +%Y 2>/dev/null || date -r "$epoch" +%Y 2>/dev/null
            ;;
    esac
}

# Classify backups into GFS tiers and select which to keep
# Returns list of filenames to keep (one per line)
classify_backups_gfs() {
    local backup_list="$1"
    local current_epoch
    current_epoch=$(date +%s)

    # Get retention settings (defaults match common use cases)
    local retention_recent="${BACKUP_RETENTION_RECENT:-14}"  # Keep last 14 backups
    local retention_daily="${BACKUP_RETENTION_DAILY:-7}"     # Keep 7 daily backups
    local retention_weekly="${BACKUP_RETENTION_WEEKLY:-4}"   # Keep 4 weekly backups
    local retention_monthly="${BACKUP_RETENTION_MONTHLY:-0}" # Keep 0 monthly backups (disabled by default)
    local retention_yearly="${BACKUP_RETENTION_YEARLY:-0}"   # Keep 0 yearly backups (disabled by default)

    log_debug "GFS Retention Policy: Recent=$retention_recent, Daily=$retention_daily, Weekly=$retention_weekly, Monthly=$retention_monthly, Yearly=$retention_yearly"

    # Arrays to track selected backups for each tier
    declare -A recent_backups
    declare -A daily_backups
    declare -A weekly_backups
    declare -A monthly_backups
    declare -A yearly_backups

    # Parse all backups and extract timestamps
    local -a backup_epochs
    local -a backup_files

    while IFS= read -r backup_file; do
        [ -z "$backup_file" ] && continue

        local timestamp
        timestamp=$(parse_backup_timestamp "$backup_file")

        if [ -z "$timestamp" ]; then
            log_debug "Skipping file with invalid timestamp format: $backup_file"
            continue
        fi

        local epoch
        epoch=$(timestamp_to_epoch "$timestamp")

        if [ "$epoch" = "0" ]; then
            log_debug "Could not parse timestamp for: $backup_file"
            continue
        fi

        backup_epochs+=("$epoch")
        backup_files+=("$backup_file")
    done <<<"$backup_list"

    # Sort backups by epoch (newest first)
    local -a sorted_indices
    while IFS= read -r idx; do
        sorted_indices+=("$idx")
    done < <(
        for i in "${!backup_epochs[@]}"; do
            echo "${backup_epochs[$i]} $i"
        done | sort -rn | awk '{print $2}'
    )

    # Tier 1: Recent backups (keep last N)
    local recent_count=0
    for idx in "${sorted_indices[@]}"; do
        if [ "$recent_count" -lt "$retention_recent" ]; then
            recent_backups["${backup_files[$idx]}"]=1
            ((recent_count++))
        fi
    done

    # Tier 2: Daily backups (one per day)
    for idx in "${sorted_indices[@]}"; do
        local epoch="${backup_epochs[$idx]}"
        local age_days=$(((current_epoch - epoch) / 86400))

        if [ "$age_days" -le "$retention_daily" ]; then
            local day_key
            day_key=$(get_period_start "$epoch" "day")

            if [ -z "${daily_backups[$day_key]:-}" ]; then
                daily_backups["$day_key"]="${backup_files[$idx]}"
            fi
        fi
    done

    # Tier 3: Weekly backups (one per week)
    for idx in "${sorted_indices[@]}"; do
        local epoch="${backup_epochs[$idx]}"
        local age_weeks=$(((current_epoch - epoch) / 604800))

        if [ "$age_weeks" -le "$retention_weekly" ]; then
            local week_key
            week_key=$(get_period_start "$epoch" "week")

            if [ -z "${weekly_backups[$week_key]:-}" ]; then
                weekly_backups["$week_key"]="${backup_files[$idx]}"
            fi
        fi
    done

    # Tier 4: Monthly backups (one per month)
    for idx in "${sorted_indices[@]}"; do
        local epoch="${backup_epochs[$idx]}"
        local age_months=$(((current_epoch - epoch) / 2592000))

        if [ "$age_months" -le "$retention_monthly" ]; then
            local month_key
            month_key=$(get_period_start "$epoch" "month")

            if [ -z "${monthly_backups[$month_key]:-}" ]; then
                monthly_backups["$month_key"]="${backup_files[$idx]}"
            fi
        fi
    done

    # Tier 5: Yearly backups (one per year)
    for idx in "${sorted_indices[@]}"; do
        local epoch="${backup_epochs[$idx]}"
        local age_years=$(((current_epoch - epoch) / 31536000))

        if [ "$age_years" -le "$retention_yearly" ]; then
            local year_key
            year_key=$(get_period_start "$epoch" "year")

            if [ -z "${yearly_backups[$year_key]:-}" ]; then
                yearly_backups["$year_key"]="${backup_files[$idx]}"
            fi
        fi
    done

    # Combine all backups to keep (using associative array to deduplicate)
    declare -A keep_set

    # Add recent backups
    for file in "${!recent_backups[@]}"; do
        keep_set["$file"]=1
    done

    # Add daily backups
    for file in "${daily_backups[@]}"; do
        keep_set["$file"]=1
    done

    # Add weekly backups
    for file in "${weekly_backups[@]}"; do
        keep_set["$file"]=1
    done

    # Add monthly backups
    for file in "${monthly_backups[@]}"; do
        keep_set["$file"]=1
    done

    # Add yearly backups
    for file in "${yearly_backups[@]}"; do
        keep_set["$file"]=1
    done

    # Output files to keep (one per line)
    for file in "${!keep_set[@]}"; do
        echo "$file"
    done
}

# Delete old backups from local storage using GFS policy
cleanup_old_local_backups() {
    local backup_prefix="$1"
    local backup_dir="${BACKUP_LOCAL_PATH}/${backup_prefix}"

    if [ ! -d "$backup_dir" ]; then
        log_debug "Backup directory doesn't exist: $backup_dir"
        return 0
    fi

    log_info "Applying GFS retention policy to local backups..."

    # Get list of all backup files
    local backup_list
    backup_list=$(find "$backup_dir" -type f -name "*.tar.gz*" -printf "%f\n" 2>/dev/null | sort -r)

    if [ -z "$backup_list" ]; then
        log_debug "No local backups found"
        return 0
    fi

    # Get list of backups to keep
    local keep_list
    keep_list=$(classify_backups_gfs "$backup_list")

    # Convert keep list to associative array for fast lookup
    declare -A keep_set
    while IFS= read -r file; do
        [ -n "$file" ] && keep_set["$file"]=1
    done <<<"$keep_list"

    # Delete backups not in keep list
    local deleted_count=0
    local kept_count=0

    while IFS= read -r backup_file; do
        [ -z "$backup_file" ] && continue

        if [ -z "${keep_set[$backup_file]:-}" ]; then
            log_info "Deleting old local backup: $backup_file"
            rm -f "${backup_dir}/${backup_file}" || log_warn "Failed to delete $backup_file"
            deleted_count=$((deleted_count + 1))
        else
            kept_count=$((kept_count + 1))
        fi
    done <<<"$backup_list"

    log_info "Local retention: kept $kept_count backups, deleted $deleted_count backups"
}

# Delete old backups from S3 using GFS policy
cleanup_old_s3_backups() {
    local s3_prefix="$1"

    if ! configure_s3; then
        log_warn "S3 cleanup skipped - configuration failed"
        return 0
    fi

    log_info "Applying GFS retention policy to S3 backups..."

    # Get list of all backup files from S3
    local backup_list
    backup_list=$(aws s3 ls "s3://${BACKUP_S3_BUCKET}/${s3_prefix}/" 2>/dev/null | grep -E '\.tar\.gz(\.gpg)?$' | awk '{print $4}' | sort -r)

    if [ -z "$backup_list" ]; then
        log_debug "No S3 backups found"
        return 0
    fi

    # Get list of backups to keep
    local keep_list
    keep_list=$(classify_backups_gfs "$backup_list")

    # Convert keep list to associative array for fast lookup
    declare -A keep_set
    while IFS= read -r file; do
        [ -n "$file" ] && keep_set["$file"]=1
    done <<<"$keep_list"

    # Delete backups not in keep list
    local deleted_count=0
    local kept_count=0

    while IFS= read -r backup_file; do
        [ -z "$backup_file" ] && continue

        if [ -z "${keep_set[$backup_file]:-}" ]; then
            log_info "Deleting old S3 backup: $backup_file"
            aws s3 rm "s3://${BACKUP_S3_BUCKET}/${s3_prefix}/${backup_file}" || log_warn "Failed to delete $backup_file"
            deleted_count=$((deleted_count + 1))
        else
            kept_count=$((kept_count + 1))
        fi
    done <<<"$backup_list"

    log_info "S3 retention: kept $kept_count backups, deleted $deleted_count backups"
}

# Delete old backups from configured destination(s)
cleanup_old_backups() {
    local backup_prefix="$1"
    local destination
    destination=$(get_backup_destination)

    case "$destination" in
        "local")
            cleanup_old_local_backups "$backup_prefix"
            ;;
        "s3")
            cleanup_old_s3_backups "$backup_prefix"
            ;;
        "both")
            cleanup_old_local_backups "$backup_prefix"
            cleanup_old_s3_backups "$backup_prefix"
            ;;
    esac
}

# Stop services before backup
stop_services() {
    local services="${BACKUP_STOP_SERVICES:-}"

    if [ -z "$services" ]; then
        return 0
    fi

    log_info "Stopping services: $services"

    # Try to detect if we're in a compose environment
    # Check if we can use docker compose by looking for compose project label
    local use_compose=false
    if command -v docker >/dev/null 2>&1; then
        # Try to detect compose by checking if containers have compose labels
        for service in ${services//,/ }; do
            if docker inspect "$service" 2>/dev/null | grep -q "com.docker.compose.project"; then
                use_compose=true
                break
            fi
        done
    fi

    # Stop each service
    for service in ${services//,/ }; do
        local stopped=false

        if [ "$use_compose" = true ]; then
            log_info "Stopping compose service: $service"
            # Try docker compose stop (with and without project name)
            if [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then
                docker compose -p "$COMPOSE_PROJECT_NAME" stop "$service" 2>/dev/null && stopped=true
            fi

            # Fallback to docker compose without project name
            if [ "$stopped" = false ]; then
                docker compose stop "$service" 2>/dev/null && stopped=true
            fi
        fi

        # Fallback to direct docker stop
        if [ "$stopped" = false ]; then
            log_info "Stopping container: $service"
            docker stop "$service" 2>/dev/null && stopped=true
        fi

        if [ "$stopped" = false ]; then
            log_warn "Failed to stop $service - it may not be running or not exist"
        else
            log_debug "Successfully stopped $service"
        fi
    done

    # Give containers time to stop gracefully
    # Most apps flush buffers and cleanup during shutdown, so a small delay helps
    # Default is 2 seconds, set to 0 to skip the delay
    local wait_time="${BACKUP_STOP_WAIT:-2}"
    if [ "$wait_time" -gt 0 ]; then
        log_debug "Waiting ${wait_time}s for services to stop completely..."
        sleep "$wait_time"
    fi
}

# Start services after backup
start_services() {
    local services="${BACKUP_STOP_SERVICES:-}"

    if [ -z "$services" ]; then
        return 0
    fi

    log_info "Starting services: $services"

    # Try to detect if we're in a compose environment
    local use_compose=false
    if command -v docker >/dev/null 2>&1; then
        # Try to detect compose by checking if containers have compose labels
        for service in ${services//,/ }; do
            if docker inspect "$service" 2>/dev/null | grep -q "com.docker.compose.project"; then
                use_compose=true
                break
            fi
        done
    fi

    # Start each service
    for service in ${services//,/ }; do
        local started=false

        if [ "$use_compose" = true ]; then
            log_info "Starting compose service: $service"
            # Try docker compose start (with and without project name)
            if [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then
                docker compose -p "$COMPOSE_PROJECT_NAME" start "$service" 2>/dev/null && started=true
            fi

            # Fallback to docker compose without project name
            if [ "$started" = false ]; then
                docker compose start "$service" 2>/dev/null && started=true
            fi
        fi

        # Fallback to direct docker start
        if [ "$started" = false ]; then
            log_info "Starting container: $service"
            docker start "$service" 2>/dev/null && started=true
        fi

        if [ "$started" = false ]; then
            log_warn "Failed to start $service"
        else
            log_debug "Successfully started $service"
        fi
    done

    # Give containers time to start
    # This allows apps to initialize, run health checks, and be fully ready
    # Default is 3 seconds, set to 0 to skip the delay
    local wait_time="${BACKUP_START_WAIT:-3}"
    if [ "$wait_time" -gt 0 ]; then
        log_debug "Waiting ${wait_time}s for services to start completely..."
        sleep "$wait_time"
    fi
}

# Generate timestamp for backup filename
get_timestamp() {
    date +%Y-%m-%d-%H%M%S
}

# Get backup name (required)
get_backup_name() {
    if [ -z "${BACKUP_NAME:-}" ]; then
        log_error "BACKUP_NAME environment variable is required"
        log_error "Set BACKUP_NAME to identify your backups (e.g., BACKUP_NAME=myapp-prod)"
        return 1
    fi
    echo "$BACKUP_NAME"
}
