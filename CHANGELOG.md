# Changelog

All notable changes to docker-backup-sidecar will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)

## [Unreleased]

### Breaking Changes

- Replaced tar.gz + GPG encryption with restic backup engine
- Replaced `BACKUP_ENCRYPTION_KEY` with `RESTIC_PASSWORD`
- Replaced `BACKUP_LOCAL_PATH` and `BACKUP_S3_*` with `RESTIC_REPOSITORY`
- Replaced `BACKUP_RETENTION_*` with `RESTIC_KEEP_*`
- Restore now uses snapshot IDs instead of timestamps
- Removed aws-cli and gnupg from Docker image
- Updated PostgreSQL client versions from 15/16/17 to 16/17/18

### Added

- Restic-based incremental/deduplicated backups
- Built-in encryption via restic (AES-256)
- Support for any restic backend (S3, B2, SFTP, REST, local, etc.)
- Redis RDB snapshot backup and restore via `BACKUP_REDIS`
- `BACKUP_REDIS_DATA_DIR` env var for Redis data directory mapping
- Automatic restic repository initialization on first backup
- PostgreSQL 18 client support

### Removed

- GPG encryption (replaced by restic's built-in encryption)
- aws-cli (replaced by restic's native S3 support)
- Custom GFS retention logic (replaced by `restic forget --prune`)
- tar.gz archive creation (replaced by restic's content-addressed storage)
- PostgreSQL 15 client (no longer available in Alpine 3.23)

### Documentation

- Comprehensive README with examples and troubleshooting
- TESTING.md with test guide and development workflow
- Detailed .env.example with multiple configuration scenarios
- Inline code documentation
- Docker Compose example with sample data
