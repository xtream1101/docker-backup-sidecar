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

# ============================================================================
# Restic Functions
# ============================================================================

# Validate restic configuration
validate_restic_config() {
    if [ -z "${RESTIC_REPOSITORY:-}" ]; then
        send_failure "RESTIC_REPOSITORY is required. Example: /backups-local/myapp or s3:s3.amazonaws.com/bucket/myapp"
    fi

    if [ -z "${RESTIC_PASSWORD:-}" ]; then
        send_failure "RESTIC_PASSWORD is required for repository encryption"
    fi

    export RESTIC_REPOSITORY
    export RESTIC_PASSWORD

    log_debug "Restic repository: ${RESTIC_REPOSITORY}"
}

# Initialize restic repository if it doesn't exist
restic_init() {
    log_debug "Checking if restic repository exists..."

    if restic snapshots --json >/dev/null 2>&1; then
        log_debug "Restic repository already initialized"
        return 0
    fi

    log_info "Initializing new restic repository: ${RESTIC_REPOSITORY}"
    restic init || send_failure "Failed to initialize restic repository"
    log_info "Restic repository initialized successfully"
}

# Run restic backup with given paths
restic_backup() {
    local -a paths=("$@")

    if [ ${#paths[@]} -eq 0 ]; then
        send_failure "No paths provided to restic_backup"
    fi

    log_info "Running restic backup..."
    log_debug "Backup paths: ${paths[*]}"

    local -a cmd=(restic backup --tag "${BACKUP_NAME}")

    if [ "${BACKUP_DEBUG:-false}" = "true" ]; then
        cmd+=(--verbose)
    fi

    cmd+=("${paths[@]}")

    "${cmd[@]}" || send_failure "Restic backup failed"

    log_info "Restic backup completed successfully"
}

# Apply retention policy and prune
restic_forget_prune() {
    local keep_last="${RESTIC_KEEP_LAST:-14}"
    local keep_daily="${RESTIC_KEEP_DAILY:-7}"
    local keep_weekly="${RESTIC_KEEP_WEEKLY:-4}"
    local keep_monthly="${RESTIC_KEEP_MONTHLY:-0}"
    local keep_yearly="${RESTIC_KEEP_YEARLY:-0}"

    log_info "Applying retention policy..."
    log_debug "Retention: last=$keep_last daily=$keep_daily weekly=$keep_weekly monthly=$keep_monthly yearly=$keep_yearly"

    local -a cmd=(restic forget --prune --tag "${BACKUP_NAME}")
    cmd+=(--keep-last "$keep_last")

    [ "$keep_daily" -gt 0 ] && cmd+=(--keep-daily "$keep_daily")
    [ "$keep_weekly" -gt 0 ] && cmd+=(--keep-weekly "$keep_weekly")
    [ "$keep_monthly" -gt 0 ] && cmd+=(--keep-monthly "$keep_monthly")
    [ "$keep_yearly" -gt 0 ] && cmd+=(--keep-yearly "$keep_yearly")

    "${cmd[@]}" || log_warn "Restic forget/prune had warnings (non-fatal)"

    log_info "Retention policy applied"
}

# List snapshots
restic_snapshots() {
    restic snapshots --tag "${BACKUP_NAME}" || send_failure "Failed to list snapshots"
}

# Restore a snapshot to a target directory
restic_restore() {
    local snapshot_id="$1"
    local target_dir="$2"

    log_info "Restoring snapshot ${snapshot_id} to ${target_dir}..."

    mkdir -p "$target_dir"
    restic restore "$snapshot_id" --target "$target_dir" || send_failure "Restic restore failed for snapshot ${snapshot_id}"

    log_info "Restic restore completed successfully"
}

# ============================================================================
# Redis Functions
# ============================================================================

# Dump Redis databases via RDB snapshot
dump_redis() {
    local config="$1"
    local staging_dir="$2"

    # Skip if empty
    [ -z "$config" ] && return 0

    # BACKUP_REDIS_DATA_DIR specifies where the Redis data directory is mounted
    # in the backup container. This is needed because redis-cli CONFIG GET dir
    # returns the path inside the Redis container, not the backup container.
    local redis_data_dir="${BACKUP_REDIS_DATA_DIR:-/redis-data}"

    local db_index=0

    echo "$config" | while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        local uri="$line"
        db_index=$((db_index + 1))

        log_info "Backing up Redis database ($db_index)..."

        # Trigger SAVE to create a fresh RDB snapshot
        redis-cli -u "$uri" SAVE || {
            log_warn "Redis SAVE command failed for database $db_index"
            continue
        }

        # Get the RDB filename from Redis CONFIG
        local rdb_file
        rdb_file=$(redis-cli -u "$uri" CONFIG GET dbfilename 2>/dev/null | tail -1)

        if [ -z "$rdb_file" ]; then
            rdb_file="dump.rdb"
            log_debug "Could not determine Redis RDB filename, using default: $rdb_file"
        fi

        local rdb_path="${redis_data_dir}/${rdb_file}"
        log_debug "Redis RDB path: $rdb_path"

        # Copy the RDB file to staging
        if [ -f "$rdb_path" ]; then
            cp "$rdb_path" "${staging_dir}/redis-${db_index}.rdb" || log_warn "Failed to copy Redis RDB for database $db_index"
            log_info "Redis database $db_index backed up successfully"
        else
            log_warn "Redis RDB file not found at $rdb_path - ensure the Redis data directory is mounted at ${redis_data_dir}"
        fi
    done
}

# Restore Redis RDB files
restore_redis() {
    local config="$1"
    local restore_dir="$2"

    # Skip if empty
    [ -z "$config" ] && return 0

    local redis_data_dir="${BACKUP_REDIS_DATA_DIR:-/redis-data}"

    local db_index=0

    echo "$config" | while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        local uri="$line"
        db_index=$((db_index + 1))

        local rdb_file="${restore_dir}/redis-${db_index}.rdb"

        if [ ! -f "$rdb_file" ]; then
            log_warn "Redis RDB file not found for database $db_index, skipping"
            continue
        fi

        log_info "Restoring Redis database $db_index..."

        # Get the RDB filename from Redis CONFIG
        local rdb_filename
        rdb_filename=$(redis-cli -u "$uri" CONFIG GET dbfilename 2>/dev/null | tail -1)

        if [ -z "$rdb_filename" ]; then
            rdb_filename="dump.rdb"
        fi

        local rdb_path="${redis_data_dir}/${rdb_filename}"

        # Copy RDB file to Redis data directory
        cp "$rdb_file" "$rdb_path" || send_failure "Failed to restore Redis RDB for database $db_index"
        log_info "Redis database $db_index restored successfully (restart Redis to load)"
    done
}

# ============================================================================
# Service Management
# ============================================================================

# Find container ID for a service name
# Resolves compose service names to actual container IDs by checking:
# 1. Compose labels (finds containers in the same compose project)
# 2. Direct container name lookup (works with explicit container_name)
_find_container() {
    local service="$1"

    # Get our own compose project name from our container's labels
    local project
    project=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$(hostname)" 2>/dev/null || true)

    # Find by compose project + service labels (most reliable for compose)
    if [ -n "$project" ]; then
        local cid
        # Use -a to include stopped containers (needed for start_services)
        cid=$(docker ps -aq --filter "label=com.docker.compose.project=$project" --filter "label=com.docker.compose.service=$service" 2>/dev/null | head -1)
        if [ -n "$cid" ]; then
            echo "$cid"
            return 0
        fi
    fi

    # Fallback: try direct container name (works if container_name is set in compose)
    if docker inspect --format '{{.Id}}' "$service" >/dev/null 2>&1; then
        docker inspect --format '{{.Id}}' "$service" 2>/dev/null
        return 0
    fi

    return 1
}

# Stop services before backup
stop_services() {
    local services="${BACKUP_STOP_SERVICES:-}"

    if [ -z "$services" ]; then
        return 0
    fi

    log_info "Stopping services: $services"

    for service in ${services//,/ }; do
        local container_id
        if container_id=$(_find_container "$service"); then
            log_info "Stopping container: $service (${container_id:0:12})"
            if docker stop "$container_id" >/dev/null 2>&1; then
                log_debug "Successfully stopped $service"
            else
                log_warn "Failed to stop $service - it may not be running"
            fi
        else
            log_warn "Could not find container for service: $service"
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

    for service in ${services//,/ }; do
        local container_id
        if container_id=$(_find_container "$service"); then
            log_info "Starting container: $service (${container_id:0:12})"
            if docker start "$container_id" >/dev/null 2>&1; then
                log_debug "Successfully started $service"
            else
                log_warn "Failed to start $service"
            fi
        else
            log_warn "Could not find container for service: $service"
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

# ============================================================================
# Utility Functions
# ============================================================================

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
