#!/bin/bash
# Generic backup script - works for all services via configuration

set -euo pipefail

# Source common functions
# shellcheck source=scripts/common.sh
source /backup-scripts/common.sh

# Service configuration
BACKUP_DIR="/backups"
TIMESTAMP=$(get_timestamp)
BACKUP_NAME=$(get_backup_name) || send_failure "Could not determine backup name"

log_info "Starting backup for ${BACKUP_NAME} at ${TIMESTAMP}"

# Validate backup configuration
validate_backup_config

# Create temporary backup directory
TEMP_DIR="${BACKUP_DIR}/${TIMESTAMP}"
mkdir -p "$TEMP_DIR"

# Cleanup function
cleanup() {
    log_info "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Stop services if configured
stop_services

#
# BACKUP FUNCTIONS
#

# Backup PostgreSQL databases
backup_postgres() {
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

        log_info "Backing up PostgreSQL database: $database"

        # Check PostgreSQL server version
        local pg_version
        pg_version=$(psql16 "$uri" \
            --tuples-only \
            --no-align \
            --command="SHOW server_version_num;" 2>/dev/null | head -1)

        # Select appropriate pg_dump client based on server version
        # Use the closest matching or next lower version for best compatibility
        # server_version_num format: 170000 for v17, 160000 for v16, 150000 for v15, etc.
        local pg_dump_cmd="pg_dump16"  # Default fallback

        if [ -n "$pg_version" ]; then
            if [ "$pg_version" -ge 170000 ]; then
                log_debug "PostgreSQL server version $pg_version detected (>= 17), using pg_dump17 client"
                pg_dump_cmd="pg_dump17"
            elif [ "$pg_version" -ge 160000 ]; then
                log_debug "PostgreSQL server version $pg_version detected (16.x), using pg_dump16 client"
                pg_dump_cmd="pg_dump16"
            elif [ "$pg_version" -ge 150000 ]; then
                log_debug "PostgreSQL server version $pg_version detected (15.x), using pg_dump15 client"
                pg_dump_cmd="pg_dump15"
            else
                log_debug "PostgreSQL server version $pg_version detected (< 15), using pg_dump15 client for best compatibility"
                pg_dump_cmd="pg_dump15"
            fi
        fi

        # Create backup using version-matched client and connection URI
        "$pg_dump_cmd" "$uri" \
            --format=custom \
            --file="${TEMP_DIR}/postgres-${database}.dump" || send_failure "PostgreSQL backup failed for $database"
    done
}

# Backup MongoDB databases
backup_mongodb() {
    local config="$1"

    # Skip if empty
    [ -z "$config" ] && return 0

    # Parse each line: mongodb://user:password@host:port/database?authSource=admin
    echo "$config" | while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        local uri="$line"

        log_info "Backing up MongoDB database"

        # Use mongodump with --uri flag for direct URI support
        mongodump --uri="$uri" --out="${TEMP_DIR}/mongodb-dump" || send_failure "MongoDB backup failed"
    done
}

# Backup directories via tar
backup_directories() {
    local config="$1"

    # Skip if empty
    [ -z "$config" ] && return 0

    # Parse comma-separated list: /path:name,/path2:name2
    echo "$config" | tr ',' '\n' | while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        IFS=':' read -r path name <<< "$line"

        # Trim whitespace
        path=$(echo "$path" | xargs)
        name=$(echo "$name" | xargs)

        if [ -d "$path" ]; then
            log_info "Backing up directory: $path as $name"
            tar -czf "${TEMP_DIR}/${name}.tar.gz" -C "$(dirname "$path")" "$(basename "$path")" || send_failure "Directory backup failed for $path"
        else
            log_warn "Directory not found, skipping: $path"
        fi
    done
}

# Backup individual files
backup_files() {
    local config="$1"

    # Skip if empty
    [ -z "$config" ] && return 0

    # Parse comma-separated list: /path/file:name,/path2/file2:name2
    echo "$config" | tr ',' '\n' | while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        IFS=':' read -r filepath name <<< "$line"

        # Trim whitespace
        filepath=$(echo "$filepath" | xargs)
        name=$(echo "$name" | xargs)

        if [ -f "$filepath" ]; then
            log_info "Backing up file: $filepath as $name"
            cp "$filepath" "${TEMP_DIR}/${name}" || send_failure "File backup failed for $filepath"
        else
            log_warn "File not found, skipping: $filepath"
        fi
    done
}

#
# EXECUTE BACKUPS BASED ON CONFIGURATION
#

log_info "Processing backup configuration..."

# PostgreSQL backups
if [ -n "${BACKUP_POSTGRES:-}" ]; then
    backup_postgres "$BACKUP_POSTGRES"
fi

# MongoDB backups
if [ -n "${BACKUP_MONGODB:-}" ]; then
    backup_mongodb "$BACKUP_MONGODB"
fi

# Directory backups
if [ -n "${BACKUP_DIRS:-}" ]; then
    backup_directories "$BACKUP_DIRS"
fi

# File backups
if [ -n "${BACKUP_FILES:-}" ]; then
    backup_files "$BACKUP_FILES"
fi

# Check if we have anything to backup
if [ -z "$(ls -A "$TEMP_DIR")" ]; then
    send_failure "No backup data generated - check your backup configuration"
fi

# Start services if they were stopped
start_services

# Create final backup archive
log_info "Creating backup archive..."
BACKUP_FILE="${BACKUP_DIR}/${BACKUP_NAME}-${TIMESTAMP}.tar.gz"
tar -czf "$BACKUP_FILE" -C "$TEMP_DIR" . || send_failure "Archive creation failed"

# Encrypt backup
log_info "Processing backup encryption..."
ENCRYPTED_FILE=$(encrypt_file "$BACKUP_FILE")

if [ -z "$ENCRYPTED_FILE" ]; then
    send_failure "Encryption failed - no output from encrypt_file function"
fi

log_info "Backup file ready: $(basename "$ENCRYPTED_FILE")"

# Save to configured destination(s)
BACKUP_KEY="${BACKUP_NAME}/$(basename "$ENCRYPTED_FILE")"
save_backup "$ENCRYPTED_FILE" "$BACKUP_KEY"

# Cleanup old backups
cleanup_old_backups "${BACKUP_NAME}"

# Send success notification
send_success "${BACKUP_NAME} backup completed: ${TIMESTAMP}"

log_info "Backup completed successfully!"
