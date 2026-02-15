#!/bin/bash
# Generic restore script - works for all services via configuration

set -euo pipefail

# Source common functions
# shellcheck source=scripts/common.sh
source /backup-scripts/common.sh

# Service configuration
BACKUP_NAME=$(get_backup_name) || {
    log_error "Could not determine backup name"
    exit 1
}

# Check for snapshot ID argument
if [ $# -eq 0 ]; then
    log_error "Usage: $0 <snapshot-id>"
    log_info "Use 'latest' to restore the most recent snapshot"
    log_info ""
    log_info "Available snapshots:"
    validate_restic_config
    restic_snapshots
    exit 1
fi

SNAPSHOT_ID="$1"

log_info "Starting restore for ${BACKUP_NAME} from snapshot: ${SNAPSHOT_ID}"

# Validate restic configuration
validate_restic_config

# Create temporary restore directory
RESTORE_DIR="/backups/restore-$$"
mkdir -p "$RESTORE_DIR"

# Cleanup function
cleanup() {
    log_info "Cleaning up temporary files..."
    rm -rf "$RESTORE_DIR"
}
trap cleanup EXIT

# Restore snapshot
restic_restore "$SNAPSHOT_ID" "$RESTORE_DIR"

# Check if a path is writable, returns 1 if read-only
is_path_readonly() {
    local path="$1"
    local test_file="${path}/.restore-write-test-$$"
    if ! touch "$test_file" 2>/dev/null; then
        return 0  # is read-only
    fi
    rm -f "$test_file"
    return 1  # is writable
}

# Check for read-only mounts that need to be writable for restore
check_readonly_paths() {
    local ro_count=0

    # Check directories from BACKUP_DIRS
    if [ -n "${BACKUP_DIRS:-}" ]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            path=$(echo "$line" | xargs)
            if [ -d "$path" ] && is_path_readonly "$path"; then
                log_warn "READ-ONLY: $path (from BACKUP_DIRS) - restore will fail for this directory"
                ro_count=$((ro_count + 1))
            fi
        done < <(echo "$BACKUP_DIRS" | tr ',' '\n')
    fi

    # Check file paths from BACKUP_FILES
    if [ -n "${BACKUP_FILES:-}" ]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            IFS=':' read -r filepath name <<<"$line"
            filepath=$(echo "$filepath" | xargs)
            local dir
            dir=$(dirname "$filepath")
            if [ -d "$dir" ] && is_path_readonly "$dir"; then
                log_warn "READ-ONLY: $dir (parent of $filepath from BACKUP_FILES) - restore will fail for this file"
                ro_count=$((ro_count + 1))
            fi
        done < <(echo "$BACKUP_FILES" | tr ',' '\n')
    fi

    # Check Redis data directory
    if [ -n "${BACKUP_REDIS:-}" ]; then
        local redis_data_dir="${BACKUP_REDIS_DATA_DIR:-/redis-data}"
        if [ -d "$redis_data_dir" ] && is_path_readonly "$redis_data_dir"; then
            log_warn "READ-ONLY: $redis_data_dir (Redis data dir) - restore will fail for Redis"
            ro_count=$((ro_count + 1))
        fi
    fi

    if [ "$ro_count" -gt 0 ]; then
        log_error ""
        log_error "Found $ro_count read-only path(s). Cannot restore."
        log_error "Update your docker-compose.yml to remove ':ro' from the affected volume mounts,"
        log_error "then recreate the container and try again."
        exit 1
    fi
}

check_readonly_paths

# Confirm restore operation
log_warn "WARNING: This will overwrite existing data!"
log_info "Press Ctrl+C within 10 seconds to cancel..."
sleep 10

# Stop services
log_info "Stopping services..."
stop_services

#
# RESTORE FUNCTIONS
#

# Restore PostgreSQL databases
restore_postgres() {
    local config="$1"

    [ -z "$config" ] && return 0

    echo "$config" | while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        local uri="$line"

        local database
        database=$(echo "$uri" | sed -n 's#.*://[^/]*/\([^?]*\).*#\1#p')
        [ -z "$database" ] && database="postgres"

        # Find the dump file in the restore tree
        local dump_file
        dump_file=$(find "$RESTORE_DIR" -name "postgres-${database}.dump" -type f | head -1)

        if [ -z "$dump_file" ]; then
            log_warn "PostgreSQL dump not found for $database, skipping"
            continue
        fi

        log_info "Restoring PostgreSQL database: $database"

        # Check PostgreSQL server version
        local pg_version
        pg_version=$(psql17 "$uri" \
            --tuples-only \
            --no-align \
            --command="SHOW server_version_num;" 2>/dev/null | head -1)

        local pg_restore_cmd="pg_restore17"

        if [ -n "$pg_version" ]; then
            if [ "$pg_version" -ge 180000 ]; then
                log_debug "PostgreSQL server >= 18, using pg_restore18"
                pg_restore_cmd="pg_restore18"
            elif [ "$pg_version" -ge 170000 ]; then
                log_debug "PostgreSQL server 17.x, using pg_restore17"
                pg_restore_cmd="pg_restore17"
            elif [ "$pg_version" -ge 160000 ]; then
                log_debug "PostgreSQL server 16.x, using pg_restore16"
                pg_restore_cmd="pg_restore16"
            else
                log_debug "PostgreSQL server < 16, using pg_restore16"
                pg_restore_cmd="pg_restore16"
            fi
        fi

        local restore_output
        restore_output=$("$pg_restore_cmd" \
            --dbname="$uri" \
            --clean \
            --if-exists \
            "$dump_file" 2>&1) || {
            # pg_restore exits non-zero when there are non-fatal warnings
            # (e.g. inherited constraints from pgboss/partitioned tables)
            # Only fail if it's not just "errors ignored on restore"
            if echo "$restore_output" | grep -q "errors ignored on restore"; then
                local ignored_count
                ignored_count=$(echo "$restore_output" | grep -o 'errors ignored on restore: [0-9]*' | grep -o '[0-9]*$' || echo "some")
                log_info "PostgreSQL restore for $database completed ($ignored_count non-fatal warnings ignored)"
                log_debug "pg_restore warnings for $database:"
                echo "$restore_output" | grep -E "^pg_restore" | while IFS= read -r warn_line; do log_debug "  $warn_line"; done
            else
                log_error "$restore_output"
                send_failure "PostgreSQL restore failed for $database"
            fi
        }
    done
}

# Restore MongoDB databases
restore_mongodb() {
    local config="$1"

    [ -z "$config" ] && return 0

    echo "$config" | while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        local uri="$line"

        local dump_dir
        dump_dir=$(find "$RESTORE_DIR" -type d -name "mongodb-dump" | head -1)

        if [ -z "$dump_dir" ]; then
            log_warn "MongoDB dump directory not found, skipping"
            continue
        fi

        log_info "Restoring MongoDB database"
        mongorestore --uri="$uri" --drop "$dump_dir" || send_failure "MongoDB restore failed"
    done
}

# Restore directories
restore_directories() {
    local config="$1"

    [ -z "$config" ] && return 0

    echo "$config" | tr ',' '\n' | while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        path=$(echo "$line" | xargs)

        # In the restore tree, restic preserves the full path
        local restored_path="${RESTORE_DIR}${path}"

        if [ ! -d "$restored_path" ]; then
            log_warn "Restored directory not found for $path, skipping"
            continue
        fi

        log_info "Restoring directory: $path"

        mkdir -p "$path"
        # Use rsync-like copy: delete destination contents and replace with backup
        rm -rf "${path:?}/"*
        cp -a "$restored_path/." "$path/" || send_failure "Directory restore failed for $path"
    done
}

# Restore individual files
restore_files() {
    local config="$1"

    [ -z "$config" ] && return 0

    echo "$config" | tr ',' '\n' | while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        IFS=':' read -r filepath name <<<"$line"
        filepath=$(echo "$filepath" | xargs)
        name=$(echo "$name" | xargs)

        # Files are stored in staging/files/{name}
        local restored_file
        restored_file=$(find "$RESTORE_DIR" -path "*/staging/files/${name}" -type f | head -1)

        if [ -z "$restored_file" ]; then
            log_warn "Backup file not found for $name, skipping"
            continue
        fi

        log_info "Restoring file: $filepath from $name"

        mkdir -p "$(dirname "$filepath")"
        cp "$restored_file" "$filepath" || send_failure "File restore failed for $filepath"
    done
}

#
# EXECUTE RESTORES BASED ON CONFIGURATION
#

log_info "Processing restore configuration..."

# PostgreSQL restores
if [ -n "${BACKUP_POSTGRES:-}" ]; then
    restore_postgres "$BACKUP_POSTGRES"
fi

# MongoDB restores
if [ -n "${BACKUP_MONGODB:-}" ]; then
    restore_mongodb "$BACKUP_MONGODB"
fi

# Redis restores
if [ -n "${BACKUP_REDIS:-}" ]; then
    redis_db_dir=$(find "$RESTORE_DIR" -path "*/staging/databases" -type d | head -1)
    if [ -n "$redis_db_dir" ]; then
        restore_redis "$BACKUP_REDIS" "$redis_db_dir"
    fi
fi

# Directory restores
if [ -n "${BACKUP_DIRS:-}" ]; then
    restore_directories "$BACKUP_DIRS"
fi

# File restores
if [ -n "${BACKUP_FILES:-}" ]; then
    restore_files "$BACKUP_FILES"
fi

# Start services
start_services

log_info "Restore completed successfully!"
log_info "Please verify the application is working correctly"
