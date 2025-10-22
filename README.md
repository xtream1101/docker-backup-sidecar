# Docker Backup Sidecar

A flexible, production-ready backup sidecar container for Docker Compose applications.
Backup your databases, files, and volumes to local storage or S3-compatible cloud storage
with encryption, scheduling, and automatic retention management.

## Features

- **Simple Configuration**: Just set `BACKUP_NAME` to identify your backups
- **Multiple Database Support**: PostgreSQL, MongoDB, SQLite
- **File & Directory Backups**: Backup any files or directories from mounted volumes
- **Flexible Destinations**:
  - Local mounted directory
  - S3-compatible storage (AWS S3, Backblaze B2, Wasabi, MinIO, etc.)
  - Both simultaneously for redundancy
- **Security**: GPG encryption for all backups
- **Automated Scheduling**: Cron-based scheduled backups
- **Retention Management**: Automatic cleanup of old backups
- **Container Management**: Stop/start containers before/after backup (essential for SQLite)
- **Health Monitoring**: Webhook notifications for success/failure
- **Easy Restore**: Simple restore scripts with automatic destination detection

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
    image: postgres:15-alpine
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
      # Local backup storage (optional)
      - ./backups:/backups-local
    # No command needed! The entrypoint handles cron setup automatically
    # based on BACKUP_SCHEDULE environment variable

volumes:
  app-data:
  db-data:
```

### 2. Configure your .env file

```bash
# Copy the example
cp .env.example .env

# Edit with your configuration
nano .env
```

Minimum configuration for local backups:

```bash
# Backup name (REQUIRED)
BACKUP_NAME=myapp-production

# Backup destination
BACKUP_LOCAL_PATH=/backups-local

# Encryption key (IMPORTANT: Store securely!)
BACKUP_ENCRYPTION_KEY=your-very-strong-passphrase-here

# What to backup
BACKUP_POSTGRES=postgresql://postgres:yourpassword@db:5432/myapp
BACKUP_DIRS=/data:app-data

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

Set `BACKUP_NAME` to uniquely identify your backups. This is used to organize backup files in storage.

```bash
# Required: Unique identifier for your backups
BACKUP_NAME=myapp-production
```

Examples:

- `myapp-prod` for production environment
- `website-staging` for staging environment  
- `api-v2-prod` for specific services

Backup filenames will be: `${BACKUP_NAME}-2025-10-19-020000.tar.gz.gpg`

### Backup Destinations

You can configure local, S3, or both:

#### Local Only

```bash
BACKUP_LOCAL_PATH=/backups-local
```

Make sure to mount this path in docker-compose.yml:

```yaml
volumes:
  - ./backups:/backups-local
```

#### S3 Only

```bash
BACKUP_S3_BUCKET=my-backup-bucket
BACKUP_S3_ENDPOINT=https://s3.amazonaws.com
BACKUP_S3_REGION=us-east-1
BACKUP_S3_ACCESS_KEY=your-access-key
BACKUP_S3_SECRET_KEY=your-secret-key
```

#### Both (Recommended for redundancy)

```bash
# Local
BACKUP_LOCAL_PATH=/backups-local

# S3
BACKUP_S3_BUCKET=my-backup-bucket
BACKUP_S3_ACCESS_KEY=your-access-key
BACKUP_S3_SECRET_KEY=your-secret-key
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

# With additional options
BACKUP_MONGODB=mongodb://user:pass@mongo:27017/mydb?authSource=admin&ssl=true
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

```bash
# Format: /path:name,/path2:name2
BACKUP_DIRS=/data:app-data,/config:app-config,/uploads:user-uploads
```

#### Individual Files

```bash
# Format: /path/file:name,/path2/file2:name2
BACKUP_FILES=/config/app.json:config,/secrets/api-key:apikey
```

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

### List Available Backups

```bash
docker compose exec backup /backup-scripts/list-backups.sh
```

### Restore from Backup

```bash
# List backups first to find the timestamp
docker compose exec backup /backup-scripts/list-backups.sh

# Restore (replace YYYY-MM-DD-HHMMSS with actual timestamp)
docker compose exec backup /backup-scripts/restore.sh YYYY-MM-DD-HHMMSS
```

The restore script will:

1. Download/load the backup
2. Decrypt it
3. Show a 10-second warning
4. Stop all services
5. Restore databases, files, and directories
6. Start all services

### View Logs

```bash
# View backup log
docker compose exec backup cat /var/log/backup.log

# Follow backup log
docker compose exec backup tail -f /var/log/backup.log
```

## Storage Structure

Backups are organized by hostname and backup name:

### Local Storage

```text
./backups/
  └── myapp/
      ├── myapp-2025-10-19-020000.tar.gz.gpg
      ├── myapp-2025-10-18-020000.tar.gz.gpg
      └── myapp-2025-10-17-020000.tar.gz.gpg
```

### S3 Storage

```text
s3://my-backup-bucket/
  └── myapp/
      ├── myapp-2025-10-19-020000.tar.gz.gpg
      ├── myapp-2025-10-18-020000.tar.gz.gpg
      └── myapp-2025-10-17-020000.tar.gz.gpg
```

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
BACKUP_LOCAL_PATH=/backups-local
BACKUP_POSTGRES=postgresql://postgres:${DB_PASSWORD}@db:5432/myapp
BACKUP_DIRS=/app/uploads:uploads
BACKUP_ENCRYPTION_KEY=strong-passphrase-here
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
BACKUP_LOCAL_PATH=/backups-local
BACKUP_FILES=/app/data/app.db:database
BACKUP_DIRS=/app/data/uploads:uploads
BACKUP_ENCRYPTION_KEY=strong-passphrase-here
```

Note: SQLite databases should be backed up using `BACKUP_FILES` with the container stopped via `BACKUP_STOP_SERVICES`.

### Scenario 3: Multi-DB Setup with S3

```bash
# .env
# S3 Configuration
BACKUP_S3_BUCKET=my-company-backups
BACKUP_S3_ACCESS_KEY=xxx
BACKUP_S3_SECRET_KEY=xxx
BACKUP_S3_REGION=us-east-1

# Also save locally for quick restore
BACKUP_LOCAL_PATH=/backups-local

# Multiple databases
BACKUP_POSTGRES=postgresql://postgres:${PG_PASSWORD}@postgres:5432/maindb
BACKUP_MONGODB=mongodb://root:${MONGO_PASSWORD}@mongo:27017/?authSource=admin

# Files
BACKUP_DIRS=/config:config,/uploads:uploads
BACKUP_FILES=/secrets/api-key.txt:apikey

# Monitoring
BACKUP_SUCCESS_WEBHOOK=https://hc-ping.com/your-uuid
BACKUP_FAILURE_WEBHOOK=https://hc-ping.com/your-uuid/fail

# Encryption
BACKUP_ENCRYPTION_KEY=strong-passphrase-here
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

1. **Encryption Key**
   - Use a strong, random passphrase
   - Store in a password manager
   - Never commit to git
   - Without this key, backups cannot be restored!

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

### S3 upload failing

```bash
# Test S3 credentials manually
docker compose exec backup sh
aws s3 ls s3://your-bucket/

# Check AWS CLI configuration
env | grep AWS
```

### Encryption/Decryption errors

```bash
# Verify encryption key is set
docker compose exec backup sh -c 'echo $BACKUP_ENCRYPTION_KEY'

# Test encryption manually
docker compose exec backup sh
echo "test" | gpg --symmetric --batch --passphrase "your-key"
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

### Different Retention Periods

```bash
# Keep backups for 90 days
BACKUP_RETENTION_DAYS=90

# Keep backups for 7 days
BACKUP_RETENTION_DAYS=7
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
3. **List backups**:

   ```bash
   docker compose exec backup /backup-scripts/list-backups.sh
   ```

4. **Restore**:

   ```bash
   docker compose exec backup /backup-scripts/restore.sh 2025-10-19-020000
   ```

5. **Verify** application is working correctly
6. **Update** DNS/networking as needed

## Testing

This project includes comprehensive automated tests. See [TESTING.md](TESTING.md) for details.

```bash
# Run all tests
./test.sh
just test

# Quick smoke tests
just test-quick

# Try the example
docker compose -f docker-compose.example.yml up -d
just backup
just list
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
