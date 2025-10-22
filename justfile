# Docker Backup Sidecar - justfile

# Show available recipes
default:
    @just --list

# Run full test suite
test:
    ./test.sh all

# Run quick smoke tests
test-quick:
    ./test.sh environment && ./test.sh scripts

# Test backup functionality
test-backup:
    ./test.sh backup

# Test restore functionality
test-restore:
    ./test.sh restore

# Test environment setup
test-env:
    ./test.sh environment

# Build the backup container
build:
    docker compose -f docker-compose.example.yml build

# Start the test environment
up:
    docker compose -f docker-compose.example.yml up -d
    @echo "Waiting for services to be ready..."
    @sleep 5
    @docker compose -f docker-compose.example.yml ps

# Stop and clean test environment
down:
    docker compose -f docker-compose.example.yml down -v

# View backup container logs
logs:
    docker compose -f docker-compose.example.yml logs backup -f

# Full cleanup
clean:
    docker compose -f docker-compose.example.yml down -v
    rm -rf test-backups/
    @echo "Cleanup complete"

# Manual backup
backup:
    docker compose -f docker-compose.example.yml exec backup /backup-scripts/backup-now.sh

# List backups
list:
    docker compose -f docker-compose.example.yml exec backup /backup-scripts/list-backups.sh

# Interactive restore
restore:
    docker compose -f docker-compose.example.yml exec backup /backup-scripts/restore.sh
