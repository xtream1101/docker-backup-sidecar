#!/bin/bash
# Generic backup script - works for all services via configuration

set -euo pipefail

# Source common functions
# shellcheck source=scripts/common.sh
source /backup-scripts/common.sh

# Service configuration
STAGING_DIR="/backups/staging"
BACKUP_NAME=$(get_backup_name) || send_failure "Could not determine backup name"
TIMESTAMP=$(get_timestamp)

log_info "Starting backup for ${BACKUP_NAME} at ${TIMESTAMP}"

# Validate restic configuration and init repo
validate_restic_config
restic_init

# Create staging directory for database dumps
rm -rf "$STAGING_DIR"
mkdir -p "${STAGING_DIR}/databases"

# Track whether services are stopped so cleanup can restart them
SERVICES_STOPPED=false

# Cleanup function - always restarts services and removes staging files
cleanup() {
    if [ "$SERVICES_STOPPED" = true ]; then
        start_services
        SERVICES_STOPPED=false
    fi
    log_info "Cleaning up staging files..."
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

# Stop services if configured
stop_services
SERVICES_STOPPED=true

#
# DATABASE DUMP FUNCTIONS
#

# Backup PostgreSQL databases
backup_postgres() {
    local config="$1"

    # Skip if empty
    [ -z "$config" ] && return 0

    echo "$config" | while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        local uri="$line"

        local database
        database=$(echo "$uri" | sed -n 's#.*://[^/]*/\([^?]*\).*#\1#p')
        [ -z "$database" ] && database="postgres"

        log_info "Backing up PostgreSQL database: $database"

        # Check PostgreSQL server version
        local pg_version
        pg_version=$(psql17 "$uri" \
            --tuples-only \
            --no-align \
            --command="SHOW server_version_num;" 2>/dev/null | head -1)

        local pg_dump_cmd="pg_dump17"

        if [ -n "$pg_version" ]; then
            if [ "$pg_version" -ge 180000 ]; then
                log_debug "PostgreSQL server >= 18, using pg_dump18"
                pg_dump_cmd="pg_dump18"
            elif [ "$pg_version" -ge 170000 ]; then
                log_debug "PostgreSQL server 17.x, using pg_dump17"
                pg_dump_cmd="pg_dump17"
            elif [ "$pg_version" -ge 160000 ]; then
                log_debug "PostgreSQL server 16.x, using pg_dump16"
                pg_dump_cmd="pg_dump16"
            else
                log_debug "PostgreSQL server < 16, using pg_dump16"
                pg_dump_cmd="pg_dump16"
            fi
        fi

        "$pg_dump_cmd" "$uri" \
            --format=custom \
            --file="${STAGING_DIR}/databases/postgres-${database}.dump" || send_failure "PostgreSQL backup failed for $database"
    done
}

# Backup MongoDB databases
backup_mongodb() {
    local config="$1"

    # Skip if empty
    [ -z "$config" ] && return 0

    echo "$config" | while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        local uri="$line"

        log_info "Backing up MongoDB database"
        mongodump --uri="$uri" --out="${STAGING_DIR}/databases/mongodb-dump" || send_failure "MongoDB backup failed"
    done
}

#
# EXECUTE BACKUPS BASED ON CONFIGURATION
#

log_info "Processing backup configuration..."

# Database dumps
if [ -n "${BACKUP_POSTGRES:-}" ]; then
    backup_postgres "$BACKUP_POSTGRES"
fi

if [ -n "${BACKUP_MONGODB:-}" ]; then
    backup_mongodb "$BACKUP_MONGODB"
fi

if [ -n "${BACKUP_REDIS:-}" ]; then
    dump_redis "$BACKUP_REDIS" "${STAGING_DIR}/databases"
fi

#
# BUILD RESTIC BACKUP PATHS
#

BACKUP_PATHS=()

# Always include staging dir if it has content
if [ -n "$(ls -A "${STAGING_DIR}/databases" 2>/dev/null)" ]; then
    BACKUP_PATHS+=("${STAGING_DIR}/databases")
fi

# Add directories from BACKUP_DIRS (using process substitution to avoid subshell)
if [ -n "${BACKUP_DIRS:-}" ]; then
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        path=$(echo "$line" | xargs)
        if [ -d "$path" ]; then
            log_debug "Adding directory to backup: $path"
            BACKUP_PATHS+=("$path")
        else
            log_warn "Directory not found, skipping: $path"
        fi
    done < <(echo "$BACKUP_DIRS" | tr ',' '\n')
fi

# Add files from BACKUP_FILES - copy to staging so they're captured
if [ -n "${BACKUP_FILES:-}" ]; then
    mkdir -p "${STAGING_DIR}/files"
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        IFS=':' read -r filepath name <<<"$line"
        filepath=$(echo "$filepath" | xargs)
        name=$(echo "$name" | xargs)
        if [ -f "$filepath" ]; then
            log_debug "Adding file to backup: $filepath as $name"
            cp "$filepath" "${STAGING_DIR}/files/${name}"
        else
            log_warn "File not found, skipping: $filepath"
        fi
    done < <(echo "$BACKUP_FILES" | tr ',' '\n')
    if [ -n "$(ls -A "${STAGING_DIR}/files" 2>/dev/null)" ]; then
        BACKUP_PATHS+=("${STAGING_DIR}/files")
    fi
fi

# Check if we have anything to backup
if [ ${#BACKUP_PATHS[@]} -eq 0 ]; then
    send_failure "No backup data found - check your backup configuration"
fi

# Run restic backup
restic_backup "${BACKUP_PATHS[@]}"

# Start services back up now that backup is complete
start_services
SERVICES_STOPPED=false

# Apply retention policy
restic_forget_prune

# Send success notification
send_success "${BACKUP_NAME} backup completed: ${TIMESTAMP}"

log_info "Backup completed successfully!"
