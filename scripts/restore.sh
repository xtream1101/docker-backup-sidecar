#!/bin/bash
# Generic restore script - works for all services via configuration

set -euo pipefail

# Source common functions
# shellcheck source=scripts/common.sh
source /backup-scripts/common.sh

# Service configuration
BACKUP_DIR="/backups"
BACKUP_NAME=$(get_backup_name) || {
    log_error "Could not determine backup name"
    exit 1
}

# Check for backup timestamp argument
if [ $# -eq 0 ]; then
    log_error "Usage: $0 <backup-timestamp>"
    log_info "Available backups:"
    /backup-scripts/list-backups.sh
    exit 1
fi

BACKUP_TIMESTAMP="$1"
BACKUP_FILENAME="${BACKUP_NAME}-${BACKUP_TIMESTAMP}.tar.gz.gpg"

log_info "Starting restore for ${BACKUP_NAME} from backup: ${BACKUP_TIMESTAMP}"

# Validate backup configuration
validate_backup_config

# Create temporary restore directory
TEMP_DIR="${BACKUP_DIR}/restore-${BACKUP_TIMESTAMP}"
mkdir -p "$TEMP_DIR"

# Cleanup function
cleanup() {
    log_info "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Load backup from configured source
BACKUP_KEY="${BACKUP_NAME}/${BACKUP_FILENAME}"
ENCRYPTED_FILE="${TEMP_DIR}/${BACKUP_FILENAME}"
load_backup "$BACKUP_KEY" "$ENCRYPTED_FILE"

# Decrypt backup
BACKUP_FILE=$(decrypt_file "$ENCRYPTED_FILE")

# Extract backup archive
log_info "Extracting backup archive..."
tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR" || send_failure "Archive extraction failed"

# Confirm restore operation
log_warn "WARNING: This will overwrite existing data!"
log_info "Press Ctrl+C within 10 seconds to cancel..."
sleep 10

# Stop services
log_info "Stopping services..."
cd "/services/${BACKUP_NAME}" 2>/dev/null || cd "$(dirname "$(find /services -name docker-compose.yml -path "*/${BACKUP_NAME}/*" | head -1)")" 2>/dev/null || {
    log_warn "Could not find service directory, attempting restore anyway..."
}

# Stop all containers in the service
if [ -f "docker-compose.yml" ]; then
    docker compose stop || log_warn "Failed to stop some services"
fi

#
# RESTORE FUNCTIONS
#

# Restore PostgreSQL databases
restore_postgres() {
    local config="$1"

    # Skip if empty
    [ -z "$config" ] && return 0

    # Parse each line: postgresql://user:password@host:port/database
    echo "$config" | while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        local uri="$line"

        # Extract database name from URI for logging and filename
        local database
        database=$(echo "$uri" | sed -n 's#.*://[^/]*/\([^?]*\).*#\1#p')
        [ -z "$database" ] && database="postgres"

        local dump_file="${TEMP_DIR}/postgres-${database}.dump"

        if [ ! -f "$dump_file" ]; then
            log_warn "PostgreSQL dump not found for $database, skipping"
            continue
        fi

        log_info "Restoring PostgreSQL database: $database"

        # Start database container if needed
        if [ -f "docker-compose.yml" ]; then
            docker compose start db 2>/dev/null || true
            sleep 5
        fi

        # Check PostgreSQL server version
        local pg_version
        pg_version=$(psql16 "$uri" \
            --tuples-only \
            --no-align \
            --command="SHOW server_version_num;" 2>/dev/null | head -1)

        # Select appropriate pg_restore client based on server version
        # Use the closest matching or next lower version for best compatibility
        # server_version_num format: 170000 for v17, 160000 for v16, 150000 for v15, etc.
        local pg_restore_cmd="pg_restore16" # Default fallback

        if [ -n "$pg_version" ]; then
            if [ "$pg_version" -ge 170000 ]; then
                log_debug "PostgreSQL server version $pg_version detected (>= 17), using pg_restore17 client"
                pg_restore_cmd="pg_restore17"
            elif [ "$pg_version" -ge 160000 ]; then
                log_debug "PostgreSQL server version $pg_version detected (16.x), using pg_restore16 client"
                pg_restore_cmd="pg_restore16"
            elif [ "$pg_version" -ge 150000 ]; then
                log_debug "PostgreSQL server version $pg_version detected (15.x), using pg_restore15 client"
                pg_restore_cmd="pg_restore15"
            else
                log_debug "PostgreSQL server version $pg_version detected (< 15), using pg_restore15 client for best compatibility"
                pg_restore_cmd="pg_restore15"
            fi
        fi

        # Restore using version-matched client and connection URI
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

    # Skip if empty
    [ -z "$config" ] && return 0

    # Parse each line: mongodb://user:password@host:port/database?authSource=admin
    echo "$config" | while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        local uri="$line"

        local dump_dir="${TEMP_DIR}/mongodb-dump"

        if [ ! -d "$dump_dir" ]; then
            log_warn "MongoDB dump directory not found, skipping"
            continue
        fi

        log_info "Restoring MongoDB database"

        # Start database container if needed
        if [ -f "docker-compose.yml" ]; then
            docker compose start mongo 2>/dev/null || true
            sleep 5
        fi

        # Use mongorestore with --uri flag for direct URI support
        mongorestore --uri="$uri" --drop "$dump_dir" || send_failure "MongoDB restore failed"
    done
}

# Restore directories from tar
restore_directories() {
    local config="$1"

    # Skip if empty
    [ -z "$config" ] && return 0

    # Parse comma-separated list: /path:name,/path2:name2
    echo "$config" | tr ',' '\n' | while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        IFS=':' read -r path name <<<"$line"

        # Trim whitespace
        path=$(echo "$path" | xargs)
        name=$(echo "$name" | xargs)

        local tar_file="${TEMP_DIR}/${name}.tar.gz"

        if [ ! -f "$tar_file" ]; then
            log_warn "Tar file not found for $name, skipping: $tar_file"
            continue
        fi

        log_info "Restoring directory: $path from $name"

        # Create parent directory if needed
        mkdir -p "$(dirname "$path")"

        # Extract tar archive
        tar -xzf "$tar_file" -C "$(dirname "$path")" || send_failure "Directory restore failed for $path"
    done
}

# Restore individual files
restore_files() {
    local config="$1"

    # Skip if empty
    [ -z "$config" ] && return 0

    # Parse comma-separated list: /path/file:name,/path2/file2:name2
    echo "$config" | tr ',' '\n' | while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        IFS=':' read -r filepath name <<<"$line"

        # Trim whitespace
        filepath=$(echo "$filepath" | xargs)
        name=$(echo "$name" | xargs)

        local backup_file="${TEMP_DIR}/${name}"

        if [ ! -f "$backup_file" ]; then
            log_warn "Backup file not found for $name, skipping"
            continue
        fi

        log_info "Restoring file: $filepath from $name"

        # Create parent directory if needed
        mkdir -p "$(dirname "$filepath")"

        # Copy file
        cp "$backup_file" "$filepath" || send_failure "File restore failed for $filepath"
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

# Directory restores
if [ -n "${BACKUP_DIRS:-}" ]; then
    restore_directories "$BACKUP_DIRS"
fi

# File restores
if [ -n "${BACKUP_FILES:-}" ]; then
    restore_files "$BACKUP_FILES"
fi

# Start all services
log_info "Starting all services..."
if [ -f "docker-compose.yml" ]; then
    docker compose up -d || send_failure "Failed to start services"
fi

log_info "Restore completed successfully!"
log_info "Please verify the application is working correctly"
