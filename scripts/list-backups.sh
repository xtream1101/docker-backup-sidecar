#!/bin/bash
# List all backup snapshots from restic repository

set -euo pipefail

# Source common functions
# shellcheck source=scripts/common.sh
source /backup-scripts/common.sh

# Get backup name
BACKUP_NAME=$(get_backup_name) || {
    log_error "Could not determine backup name"
    exit 1
}

# Validate restic configuration
validate_restic_config

log_info "Listing snapshots for ${BACKUP_NAME}..."
echo ""

restic_snapshots
