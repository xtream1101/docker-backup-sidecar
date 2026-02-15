# Docker Backup Sidecar

A flexible, production-ready backup sidecar container for Docker Compose applications.
Backup your databases, files, and volumes using restic for incremental, deduplicated,
encrypted backups to any storage backend.

## Features

- **Simple Configuration**: Just set `BACKUP_NAME` and `RESTIC_REPOSITORY` to get started
- **Multiple Database Support**: PostgreSQL, MongoDB, Redis, SQLite
- **File & Directory Backups**: Backup any files or directories from mounted volumes
- **Restic-based Backups**: Incremental, deduplicated, content-addressed storage
- **Built-in Encryption**: AES-256 encryption via restic (no separate GPG step)
- **Flexible Storage Backends**: Local, S3, B2, SFTP, REST server, and more via restic
- **Automated Scheduling**: Cron-based scheduled backups
- **Retention Management**: Automatic cleanup via `restic forget --prune`
- **Container Management**: Stop/start containers before/after backup (essential for SQLite)
- **Health Monitoring**: Webhook notifications for success/failure
- **Easy Restore**: Snapshot-based restore with automatic database/file recovery

## Quick Start

### 1. Add backup service to your docker-compose.yml

```yaml
services:
  # Your existing services...
  app:
    image: myapp:latest
    volumes:
      - app-data:/data

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - db-data:/var/lib/postgresql/data

  # Add the backup sidecar
  backup:
    build:
      context: .
      dockerfile: Dockerfile
    # Or pull from registry:
    # image: your-registry/docker-backup-sidecar:latest
    restart: unless-stopped
    env_file:
      - .env
    environment:
      # BACKUP_NAME is required to identify your backups
      BACKUP_NAME: myapp-production
      TZ: America/New_York
    volumes:
      # Required: Docker socket for container management
      - /var/run/docker.sock:/var/run/docker.sock:ro
      # Mount data you want to backup (read-only recommended)
      - app-data:/data:ro
      # Local backup storage (restic repo)
      - ./backups:/backups-local
      # Restic cache (speeds up repeated operations)
      - restic-cache:/root/.cache/restic
    # No command needed! The entrypoint handles cron setup automatically
    # based on BACKUP_SCHEDULE environment variable

volumes:
  app-data:
  db-data:
  restic-cache:
```

### 2. Configure your .env file

```bash
# Copy the example
cp .env.example .env

# Edit with your configuration
nano .env
```

Minimum configuration:

```bash
# Backup name (REQUIRED)
BACKUP_NAME=myapp-production

# Restic repository (REQUIRED)
RESTIC_REPOSITORY=/backups-local/myapp

# Restic password (REQUIRED - store securely!)
RESTIC_PASSWORD=your-very-strong-passphrase-here

# What to backup
BACKUP_POSTGRES=postgresql://postgres:yourpassword@db:5432/myapp
BACKUP_DIRS=/data

# Schedule (daily at 2 AM) - omit for manual mode
BACKUP_SCHEDULE=0 2 * * *
```

#### Special Characters in Passwords

If your password contains special characters, you need to URL-encode them:

| Character | Encoded |
|-----------|---------|
| `@` | `%40` |
| `:` | `%3A` |
| `/` | `%2F` |
| `?` | `%3F` |
| `#` | `%23` |
| `&` | `%26` |
| `=` | `%3D` |
| `%` | `%25` |

**Example:**

```bash
# Password: my@pass:word
BACKUP_POSTGRES=postgresql://user:my%40pass%3Aword@db:5432/mydb
```

Or use an online URL encoder or the following command:

```bash
python3 -c "import urllib.parse; print(urllib.parse.quote('my@pass:word', safe=''))"
```

### 3. Start your stack

```bash
docker compose up -d
```

### 4. Test manual backup

```bash
docker compose exec backup /backup-scripts/backup-now.sh
```

## Configuration Guide

### Backup Name (Required)

Set `BACKUP_NAME` to uniquely identify your backups. This is used to tag snapshots in the restic repository.

```bash
# Required: Unique identifier for your backups
BACKUP_NAME=myapp-production
```

Examples:

- `myapp-prod` for production environment
- `website-staging` for staging environment
- `api-v2-prod` for specific services

### Restic Repository (Required)

Restic supports many storage backends natively:

#### Local Storage

```bash
RESTIC_REPOSITORY=/backups-local/myapp
```

Make sure to mount this path in docker-compose.yml:

```yaml
volumes:
  - ./backups:/backups-local
```

#### S3-compatible Storage

```bash
RESTIC_REPOSITORY=s3:s3.us-east-1.amazonaws.com/my-bucket/myapp
AWS_ACCESS_KEY_ID=your-access-key
AWS_SECRET_ACCESS_KEY=your-secret-key
```

#### Backblaze B2

```bash
RESTIC_REPOSITORY=b2:bucket-name:myapp
B2_ACCOUNT_ID=your-account-id
B2_ACCOUNT_KEY=your-account-key
```

#### SFTP

```bash
RESTIC_REPOSITORY=sftp:user@host:/backups/myapp
```

#### REST Server

```bash
RESTIC_REPOSITORY=rest:http://host:8000/myapp
```

### Database Configuration

#### PostgreSQL

PostgreSQL uses the standard connection URI format:

```bash
# Format: postgresql://[user[:password]@][host][:port][/database][?options]
BACKUP_POSTGRES=postgresql://postgres:mypassword@db:5432/mydb

# With environment variable for password
BACKUP_POSTGRES=postgresql://postgres:${DB_PASSWORD}@db:5432/myapp

# Multiple databases (one per line in your .env file)
BACKUP_POSTGRES=postgresql://postgres:pass@db:5432/db1
postgresql://postgres:pass@db:5432/db2

# With SSL options
BACKUP_POSTGRES=postgresql://user:pass@db:5432/mydb?sslmode=require
```

#### MongoDB

MongoDB uses the standard connection URI format:

```bash
# Format: mongodb://[user:password@]host[:port][/database][?options]
BACKUP_MONGODB=mongodb://root:mypassword@mongo:27017/?authSource=admin

# Backup specific database
BACKUP_MONGODB=mongodb://root:${MONGO_PASSWORD}@mongo:27017/mydb?authSource=admin

# Backup all databases (omit database name or use /)
BACKUP_MONGODB=mongodb://user:pass@mongo:27017/?authSource=admin
```

#### Redis

Redis RDB snapshots are backed up by triggering a `SAVE` command and copying the RDB file:

```bash
# Redis connection URI
BACKUP_REDIS=redis://redis:6379

# Where Redis data is mounted in the backup container (default: /redis-data)
BACKUP_REDIS_DATA_DIR=/redis-data
```

In your docker-compose.yml, mount the Redis data directory into the backup container:

```yaml
backup:
  volumes:
    - redis-data:/redis-data:ro
```

#### SQLite

SQLite databases are just files, so back them up using `BACKUP_FILES`.
Make sure to stop the container that uses the database first to avoid corruption:

```bash
# Format: /path/to/db.sqlite:name
BACKUP_FILES=/data/app.db:appdb

# MUST stop the container using the database
BACKUP_STOP_SERVICES=app
BACKUP_STOP_WAIT=10
```

### Files and Directories

#### Directories

Directories are backed up directly by restic for efficient deduplication:

```bash
# Format: /path,/path2
BACKUP_DIRS=/data,/config,/uploads
```

#### Individual Files

Files are copied to a staging area before backup. The name after the colon is used to
identify files in the backup and is required for restore to work correctly.

```bash
# Format: /path/file:name,/path2/file2:name2
BACKUP_FILES=/config/app.json:config,/secrets/api-key:apikey
```

For example, with `BACKUP_FILES=/app/config.json:app-config`, the file is stored in the
backup as `staging/files/app-config`. During restore, it is looked up by this name and
copied back to `/app/config.json`.

### Container Management

For databases like SQLite that require exclusive access:

```bash
# Stop these services before backup (comma-separated)
BACKUP_STOP_SERVICES=app,worker

# Wait time after stopping (seconds, default: 2)
# Set to 0 to skip the wait - safe for most apps!
BACKUP_STOP_WAIT=2

# Wait time after starting (seconds, default: 3)
# Recommended to ensure services are fully initialized
BACKUP_START_WAIT=3
```

The backup sidecar will:

1. Stop the specified containers
2. Wait for BACKUP_STOP_WAIT seconds (allows graceful shutdown)
3. Perform backup
4. Start the containers
5. Wait for BACKUP_START_WAIT seconds (allows services to initialize)

## Usage

### Manual Backup

```bash
docker compose exec backup /backup-scripts/backup-now.sh
```

### List Available Snapshots

```bash
docker compose exec backup /backup-scripts/list-backups.sh
```

### Restore from Snapshot

```bash
# List snapshots first to find the snapshot ID
docker compose exec backup /backup-scripts/list-backups.sh

# Restore (replace <snapshot-id> with actual ID, or use 'latest')
docker compose exec backup /backup-scripts/restore.sh <snapshot-id>
docker compose exec backup /backup-scripts/restore.sh latest
```

The restore script will:

1. Restore the snapshot to a temporary directory
2. Show a 10-second warning
3. Stop configured services
4. Restore databases, files, and directories
5. Start services

### View Logs

```bash
# View backup log
docker compose exec backup cat /var/log/backup.log

# Follow backup log
docker compose exec backup tail -f /var/log/backup.log
```

## Storage Structure

Restic uses a content-addressed storage format with deduplication:

```text
./backups/
  └── docker-backup-sidecar-test/
      ├── config          # Repository configuration
      ├── data/           # Deduplicated data packs
      ├── index/          # Index files
      ├── keys/           # Encryption keys
      ├── locks/          # Lock files
      └── snapshots/      # Snapshot metadata
```

Each snapshot contains the full backup tree. Restic handles deduplication
automatically, so unchanged data is not stored twice.

## Common Scenarios

### Scenario 1: Web App with PostgreSQL

```yaml
# docker-compose.yml
services:
  web:
    image: mywebapp:latest
    volumes:
      - uploads:/app/uploads

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - db-data:/var/lib/postgresql/data

  backup:
    # ... (backup service config)
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - uploads:/app/uploads:ro
      - ./backups:/backups-local

volumes:
  uploads:
  db-data:
```

```bash
# .env
RESTIC_REPOSITORY=/backups-local/myapp
RESTIC_PASSWORD=strong-passphrase-here
BACKUP_POSTGRES=postgresql://postgres:${DB_PASSWORD}@db:5432/myapp
BACKUP_DIRS=/app/uploads
```

### Scenario 2: App with SQLite Database

```yaml
# docker-compose.yml
services:
  app:
    image: myapp:latest
    container_name: myapp
    volumes:
      - ./data:/app/data

  backup:
    # ... (backup service config)
    environment:
      BACKUP_NAME: mywebapp-prod
      BACKUP_STOP_SERVICES: myapp
      BACKUP_STOP_WAIT: 0  # Can be 0 - safe once container is stopped
      BACKUP_START_WAIT: 2  # Brief wait to ensure app initializes
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./data:/app/data:ro
      - ./backups:/backups-local
```

```bash
# .env
RESTIC_REPOSITORY=/backups-local/mywebapp
RESTIC_PASSWORD=strong-passphrase-here
BACKUP_FILES=/app/data/app.db:database
BACKUP_DIRS=/app/data/uploads
```

Note: SQLite databases should be backed up using `BACKUP_FILES` with the container stopped via `BACKUP_STOP_SERVICES`.

### Scenario 3: Multi-DB Setup with S3

```bash
# .env
# S3 Configuration
RESTIC_REPOSITORY=s3:s3.us-east-1.amazonaws.com/my-company-backups/myapp
RESTIC_PASSWORD=strong-passphrase-here
AWS_ACCESS_KEY_ID=xxx
AWS_SECRET_ACCESS_KEY=xxx

# Multiple databases
BACKUP_POSTGRES=postgresql://postgres:${PG_PASSWORD}@postgres:5432/maindb
BACKUP_MONGODB=mongodb://root:${MONGO_PASSWORD}@mongo:27017/?authSource=admin

# Files
BACKUP_DIRS=/config,/uploads
BACKUP_FILES=/secrets/api-key.txt:apikey

# Monitoring
BACKUP_SUCCESS_WEBHOOK=https://hc-ping.com/your-uuid
BACKUP_FAILURE_WEBHOOK=https://hc-ping.com/your-uuid/fail
```

### Scenario 4: App with Redis Cache + PostgreSQL

```yaml
# docker-compose.yml
services:
  redis:
    image: redis:7-alpine
    volumes:
      - redis-data:/data
    command: redis-server --save 60 1

  backup:
    # ... (backup service config)
    volumes:
      - redis-data:/redis-data:ro
      - ./backups:/backups-local
```

```bash
# .env
RESTIC_REPOSITORY=/backups-local/myapp
RESTIC_PASSWORD=strong-passphrase-here
BACKUP_POSTGRES=postgresql://postgres:pass@db:5432/myapp
BACKUP_REDIS=redis://redis:6379
BACKUP_REDIS_DATA_DIR=/redis-data
```

## Health Monitoring

Integrate with services like [healthchecks.io](https://healthchecks.io):

1. Create a check with your backup schedule (e.g., daily at 2 AM)
2. Set grace period for backup completion (e.g., 1 hour)
3. Add webhook URLs to .env:

```bash
BACKUP_SUCCESS_WEBHOOK=https://hc-ping.com/your-uuid
BACKUP_FAILURE_WEBHOOK=https://hc-ping.com/your-uuid/fail
```

The sidecar will ping on success and failure automatically. Can be set to use any webhook.

## Security Best Practices

1. **Restic Password**
   - Use a strong, random passphrase
   - Store in a password manager
   - Never commit to git
   - Without this password, backups cannot be restored!

2. **S3 Credentials**
   - Use IAM policies to restrict bucket access
   - Consider separate IAM user for backups
   - Enable S3 bucket versioning
   - Enable S3 bucket encryption at rest

3. **File Permissions**
   - Mount volumes as read-only when possible (`:ro`), remove if you need to do a restore
   - Backup container needs docker socket access (required for stopping/starting)

4. **Network Security**
   - Backup container can be on internal network only
   - No ports need to be exposed

## Troubleshooting

### Backups not running

```bash
# Check container is running
docker compose ps backup

# Check cron is configured
docker compose exec backup crontab -l

# Check logs
docker compose logs backup
docker compose exec backup cat /var/log/backup.log
```

### Restic repository issues

```bash
# Check restic repo status
docker compose exec backup restic snapshots

# Check repo integrity
docker compose exec backup restic check

# Unlock a stale lock
docker compose exec backup restic unlock
```

### Redis backup issues

```bash
# Verify Redis data directory is mounted
docker compose exec backup ls -la /redis-data/

# Test Redis connectivity from backup container
docker compose exec backup redis-cli -u redis://redis:6379 ping

# Check if RDB file exists
docker compose exec backup ls -la /redis-data/dump.rdb
```

### Container stop/start not working

```bash
# Check docker socket is mounted
docker compose exec backup ls -la /var/run/docker.sock

# Test docker commands
docker compose exec backup docker ps

# Check BACKUP_NAME is set
docker compose exec backup env | grep BACKUP
```

## Advanced Configuration

### Custom Backup Schedule

Use standard cron format, or omit `BACKUP_SCHEDULE` entirely for manual-only mode:

```bash
# Every 6 hours
BACKUP_SCHEDULE=0 */6 * * *

# Weekly on Sunday at 3 AM
BACKUP_SCHEDULE=0 3 * * 0

# Every 15 minutes
BACKUP_SCHEDULE=*/15 * * * *

# Manual mode only (no automatic backups)
# Just comment out or don't set BACKUP_SCHEDULE
```

### Retention Policy Configuration

Restic manages retention via `restic forget --prune`:

```bash
# Defaults if not set
RESTIC_KEEP_LAST=14      # Keep the last N snapshots
RESTIC_KEEP_DAILY=7      # Keep one snapshot per day for N days
RESTIC_KEEP_WEEKLY=4     # Keep one snapshot per week for N weeks
RESTIC_KEEP_MONTHLY=0    # Keep one snapshot per month for N months (0 = disabled)
RESTIC_KEEP_YEARLY=0     # Keep one snapshot per year for N years (0 = disabled)
```

### Debug Mode

Enable verbose logging:

```bash
BACKUP_DEBUG=true
```

## Disaster Recovery

In case of complete infrastructure loss:

1. **Setup new server** with Docker and docker-compose
2. **Deploy backup container** with same .env configuration
3. **List snapshots**:

   ```bash
   docker compose exec backup /backup-scripts/list-backups.sh
   ```

4. **Restore**:

   ```bash
   # Restore latest snapshot
   docker compose exec backup /backup-scripts/restore.sh latest

   # Or restore a specific snapshot
   docker compose exec backup /backup-scripts/restore.sh abc1234
   ```

5. **Verify** application is working correctly
6. **Update** DNS/networking as needed

## Testing

This project includes comprehensive automated tests. See [TESTING.md](TESTING.md) for details.

```bash
# Run all tests
just test

# Quick smoke tests
just test-quick

# Try the example
just up
just backup
just list
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
