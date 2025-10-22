#!/bin/bash
# Entrypoint script for Docker Backup Sidecar
# Automatically configures cron based on BACKUP_SCHEDULE environment variable

set -e

# Source common functions for logging
# shellcheck source=scripts/common.sh
source /backup-scripts/common.sh

log_info "Docker Backup Sidecar starting..."

# Display backup name
BACKUP_NAME=$(get_backup_name 2>/dev/null) || BACKUP_NAME="NOT_SET"
log_info "Backup Name: ${BACKUP_NAME}"

# If BACKUP_SCHEDULE is set, configure cron
if [ -n "${BACKUP_SCHEDULE:-}" ]; then
    log_info "Configuring scheduled backups: ${BACKUP_SCHEDULE}"
    echo "${BACKUP_SCHEDULE} /backup-scripts/backup-now.sh >> /var/log/backup.log 2>&1" | crontab -

    # Display the configured cron job
    log_info "Cron job configured:"
    crontab -l | sed 's/^/  /' >&2

    log_info "Starting cron daemon..."
    # Run crond in foreground, suppress harmless setpgid warnings
    crond -f -l 2 2>&1 | grep -v "setpgid" || true
else
    log_warn "BACKUP_SCHEDULE not set - running in manual mode"
    log_info "You can run backups manually with: /backup-scripts/backup-now.sh"
    log_info "List backups with: /backup-scripts/list-backups.sh"
    log_info "Restore with: /backup-scripts/restore.sh <timestamp>"
    log_info ""
    log_info "Keeping container alive for manual operations..."
    exec tail -f /dev/null
fi
