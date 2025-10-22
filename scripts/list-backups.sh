#!/bin/bash
# List all backups from configured sources

set -euo pipefail

# Source common functions
# shellcheck source=scripts/common.sh
source /backup-scripts/common.sh

# Get service name (auto-detect from compose project)
BACKUP_NAME=$(get_backup_name) || {
    log_error "Could not determine backup name"
    exit 1
}

# Validate backup configuration
validate_backup_config

# Build backup prefix
BACKUP_PREFIX="${BACKUP_NAME}"

log_info "Listing backups for ${BACKUP_NAME}..."
echo ""

# Get backup destination
DESTINATION=$(get_backup_destination)

# List local backups
list_local_backups() {
    local backup_dir="${BACKUP_LOCAL_PATH}/${BACKUP_PREFIX}"

    if [ ! -d "$backup_dir" ]; then
        log_warn "No local backup directory found: $backup_dir"
        return 0
    fi

    log_info "Local backups in: $backup_dir"
    echo ""

    # List files with details
    find "$backup_dir" -type f -name "*.tar.gz*" -exec ls -lh {} \; | awk '{print $6, $7, $8, $9}' | sort -r || {
        log_warn "No local backups found"
    }
}

# List S3 backups
list_s3_backups() {
    if ! configure_s3; then
        log_warn "S3 not configured, skipping S3 backup listing"
        return 0
    fi

    local s3_path="s3://${BACKUP_S3_BUCKET}/${BACKUP_PREFIX}/"

    log_info "S3 backups in: $s3_path"
    echo ""

    aws s3 ls "$s3_path" 2>/dev/null | grep -E '\.tar\.gz(\.gpg)?$' | sort -r || {
        log_warn "No S3 backups found"
    }
}

# List backups based on configuration
case "$DESTINATION" in
    "local")
        list_local_backups
        ;;
    "s3")
        list_s3_backups
        ;;
    "both")
        list_local_backups
        echo ""
        echo "---"
        echo ""
        list_s3_backups
        ;;
esac
