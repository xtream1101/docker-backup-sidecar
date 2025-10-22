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

# Delete old backups from local storage
cleanup_old_local_backups() {
    local backup_prefix="$1"
    local retention_days="${BACKUP_RETENTION_DAYS:-30}"

    log_info "Cleaning up local backups older than $retention_days days..."

    local backup_dir="${BACKUP_LOCAL_PATH}/${backup_prefix}"

    if [ ! -d "$backup_dir" ]; then
        log_debug "Backup directory doesn't exist: $backup_dir"
        return 0
    fi

    # Use find to delete files older than retention period
    find "$backup_dir" -type f -mtime "+${retention_days}" -print0 | while IFS= read -r -d '' file; do
        log_info "Deleting old local backup: $(basename "$file")"
        rm -f "$file" || log_warn "Failed to delete $file"
    done
}

# Delete old backups from S3
cleanup_old_s3_backups() {
    local s3_prefix="$1"
    local retention_days="${BACKUP_RETENTION_DAYS:-30}"

    log_info "Cleaning up S3 backups older than $retention_days days..."

    if ! configure_s3; then
        log_warn "S3 cleanup skipped - configuration failed"
        return 0
    fi

    # Calculate cutoff date (works with BusyBox, GNU, and BSD date)
    local current_timestamp
    local cutoff_date
    current_timestamp=$(date +%s)
    cutoff_date=$((current_timestamp - (retention_days * 86400)))

    aws s3 ls "s3://${BACKUP_S3_BUCKET}/${s3_prefix}/" 2>/dev/null | while read -r line; do
        local backup_date
        local backup_file
        backup_date=$(echo "$line" | awk '{print $1}')
        backup_file=$(echo "$line" | awk '{print $4}')

        if [ -z "$backup_file" ]; then
            continue
        fi

        # Convert backup date to timestamp (BusyBox compatible)
        local file_timestamp
        file_timestamp=$(date -D "%Y-%m-%d" -d "$backup_date" +%s 2>/dev/null || echo "0")

        if [ "$file_timestamp" != "0" ] && [ "$file_timestamp" -lt "$cutoff_date" ]; then
            log_info "Deleting old S3 backup: $backup_file"
            aws s3 rm "s3://${BACKUP_S3_BUCKET}/${s3_prefix}/${backup_file}" || log_warn "Failed to delete $backup_file"
        fi
    done
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
