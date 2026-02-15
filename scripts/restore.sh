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

        "$pg_restore_cmd" \
            --dbname="$uri" \
            --clean \
            --if-exists \
            "$dump_file" || send_failure "PostgreSQL restore failed for $database"
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

        IFS=':' read -r path name <<<"$line"
        path=$(echo "$path" | xargs)

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
